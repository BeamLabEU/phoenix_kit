defmodule PhoenixKitWeb.HandoffControllerTest do
  @moduledoc """
  The cross-domain handoff through the real router, with two browsers' worth of cookies carried
  by hand between the four requests (`visit/4` is a browser: one cookie jar per host).

  `async: false`: the tests set the host resolver and the languages, and register stub modules in
  the module registry.

  The budgets are counted per address and in windows aligned to the clock, so every browser has an
  address of its own and no window rolls while a test runs (`RateLimitIsolation`): a test that
  takes its whole budget and expects the next request to be refused does not depend on the
  second it starts in, or on another test's address.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.API.OAuth.RequestLog
  alias PhoenixKit.Cache
  alias PhoenixKit.Handoff
  alias PhoenixKit.Handoff.Token
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.HandoffDisabledModule
  alias PhoenixKit.Test.HandoffFailingModule
  alias PhoenixKit.Test.HandoffResolver
  alias PhoenixKit.Test.HandoffScriptedModule
  alias PhoenixKit.Test.HandoffStubModule
  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKit.Test.RateLimitIsolation
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Passkeys
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: WebAuth
  alias PhoenixKitWeb.Users.MultiSession

  @source "shop.test"
  @target "shop-de.test"
  @start_cookie "__Host-pk_handoff_src"
  @nonce_cookie "__Host-pk_handoff_nonce"
  @prefix "/phoenix_kit/handoff"

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    {:ok, _} = Languages.add_language("fr-FR")
    Application.put_env(:phoenix_kit, :canonical_host_resolver, {HandoffResolver, :host})
    :ok = ModuleRegistry.register(HandoffStubModule)
    RateLimitIsolation.freeze_windows()

    # The hooks run in tasks of this supervisor (an application starts it; the suite does not).
    unless Process.whereis(PhoenixKit.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :canonical_host_resolver)
      ModuleRegistry.unregister(HandoffStubModule)
    end)

    # The first account of a fresh database becomes Owner; these must not.
    _seed = user!()
    :ok
  end

  ## A tiny browser

  defp user!(attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(
        Map.merge(
          %{
            email: "handoff_#{System.unique_integer([:positive])}@example.com",
            password: "ValidPassword123!"
          },
          attrs
        )
      )

    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  defp new_browser, do: %{peer: RateLimitIsolation.unique_peer(), jars: %{}}

  defp with_peer(conn, ip) do
    {adapter, payload} = conn.adapter
    peer = %{address: ip, port: 1, ssl_cert: nil}
    %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer)}, remote_ip: ip}
  end

  defp signed_in_session(user) do
    token = Auth.generate_user_session_token(user)
    [user_token: token, pk_session_accounts: [token]]
  end

  defp visit(browser, host, path, opts \\ []) do
    method = Keyword.get(opts, :method, "GET")

    conn =
      build_conn()
      |> with_peer(browser.peer)
      |> Phoenix.ConnTest.init_test_session(Map.new(Keyword.get(opts, :session, [])))

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {name, value}, acc ->
        put_req_header(acc, name, value)
      end)

    # Cookies the test gives a visit are in the browser from then on, as a real browser's are.
    jar = Map.merge(Map.get(browser.jars, host, %{}), Map.new(Keyword.get(opts, :cookies, [])))
    browser = %{browser | jars: Map.put(browser.jars, host, jar)}

    conn = Enum.reduce(jar, conn, fn {name, value}, acc -> put_req_cookie(acc, name, value) end)

    scheme = Keyword.get(opts, :scheme, "https")
    conn = Phoenix.ConnTest.dispatch(conn, @endpoint, method, "#{scheme}://#{host}#{path}")
    {conn, absorb(browser, host, conn)}
  end

  defp absorb(browser, host, conn) do
    jar =
      Enum.reduce(conn.resp_cookies, Map.get(browser.jars, host, %{}), fn
        {name, %{max_age: 0}}, jar -> Map.delete(jar, name)
        {name, %{value: value}}, jar -> Map.put(jar, name, value)
      end)

    %{browser | jars: Map.put(browser.jars, host, jar)}
  end

  defp follow(browser, conn, opts \\ []) do
    uri = conn |> redirected_to(302) |> URI.parse()

    visit(
      browser,
      uri.host,
      uri.path <> if(uri.query, do: "?" <> uri.query, else: ""),
      [{:scheme, uri.scheme || "https"} | opts]
    )
  end

  defp location(conn) do
    uri = conn |> redirected_to(302) |> URI.parse()

    %{
      scheme: uri.scheme,
      host: uri.host,
      path: uri.path,
      query: URI.decode_query(uri.query || "")
    }
  end

  # start (source) -> prepare (target) -> mint (source) -> redeem (target); the four conns.
  defp handoff(browser, opts) do
    source_opts = Keyword.take(opts, [:session, :headers, :cookies, :scheme])
    target_opts = Keyword.get(opts, :target_opts, [])
    redeem_opts = Keyword.get(opts, :redeem_opts, [])
    to = Keyword.get(opts, :to, "/shop")

    {start, browser} = visit(browser, @source, Handoff.start_path("de", to), source_opts)
    {prepare, browser} = follow(browser, start, target_opts)
    {mint, browser} = follow(browser, prepare, Keyword.get(opts, :mint_opts, []))
    {redeem, browser} = follow(browser, mint, redeem_opts)
    {[start, prepare, mint, redeem], browser}
  end

  # A redirect stores the flash in the session for the next request.
  # The flash is in the language of the domain it lands on: `shop-de.test` serves German.
  defp signed_in(user), do: "Sie sind als #{user.email} angemeldet."

  defp flash(conn, key), do: (get_session(conn, "phoenix_flash") || %{})[key]
  defp tokens, do: Repo.all(Token)
  defp cookie_names(conn), do: conn.resp_cookies |> Map.keys() |> Enum.sort()

  defp handoff_cookies(conn),
    do: conn.resp_cookies |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "__Host-"))

  defp assert_cookie(conn, name, attrs) do
    assert %{} = cookie = conn.resp_cookies[name]

    for {key, value} <- attrs,
        do: assert(cookie[key] == value, "#{name} #{key}: #{inspect(cookie[key])}")

    cookie
  end

  defp proof, do: Handoff.source_proof_param(Handoff.new_secret())

  # What a signed cookie of the application holds (`nil` when it is not one).
  defp signed_secret(value, name) do
    secret_key_base = @endpoint.config(:secret_key_base)

    case Plug.Crypto.verify(secret_key_base, name <> "_cookie", value, keys: Plug.Keys) do
      {:ok, secret} -> secret
      _ -> nil
    end
  end

  defp assert_deleted(conn, name), do: assert(%{max_age: 0} = conn.resp_cookies[name])

  defp assert_no_store(conn), do: assert(get_resp_header(conn, "cache-control") == ["no-store"])

  # A refusal adds no message of its own. A message the browser already held (a redirect keeps
  # the flash of the request before it) travels on, which `carried_flash: true` allows for.
  defp assert_refused(conn, opts \\ []) do
    assert redirected_to(conn, 302) == "/"
    assert_no_store(conn)

    unless opts[:carried_flash] do
      assert is_nil(flash(conn, "info")) and is_nil(flash(conn, "error"))
    end
  end

  ## The flow

  describe "a signed-in visitor" do
    test "arrives signed in on the target, with a session of its own and no remember-me cookie" do
      user = user!()
      session = signed_in_session(user)
      source_token = session[:user_token]

      {[start, prepare, mint, redeem], _browser} = handoff(new_browser(), session: session)

      # 1: start. A cookie of the source, then the target's prepare step.
      assert_cookie(start, @start_cookie,
        http_only: true,
        secure: true,
        same_site: "Lax",
        path: "/",
        max_age: 60
      )

      # The source cookie is signed by the application, and the proof of its secret travels on.
      secret = signed_secret(start.resp_cookies[@start_cookie].value, @start_cookie)
      assert Handoff.secret?(secret)

      assert %{scheme: "https", host: @target, path: @prefix <> "/prepare", query: query} =
               location(start)

      assert query == %{
               "return" => @source,
               "to" => "/shop",
               "s" => Handoff.source_proof_param(secret)
             }

      # 2: prepare. A nonce cookie of the target; its hash goes back to the source.
      nonce_cookie =
        assert_cookie(prepare, @nonce_cookie,
          http_only: true,
          secure: true,
          same_site: "Lax",
          path: "/",
          max_age: 60
        )

      assert %{scheme: "https", host: @source, path: @prefix <> "/mint", query: query} =
               location(prepare)

      assert query == %{
               "n" => Handoff.nonce_hash_param(nonce_cookie.value),
               "h" => @target,
               "to" => "/shop",
               "s" => Handoff.source_proof_param(secret)
             }

      # 3: mint. The source cookie is spent; a row binds the token to host, browser and account.
      assert_deleted(mint, @start_cookie)
      assert %{scheme: "https", host: @target, path: @prefix <> "/" <> token} = location(mint)
      assert Handoff.secret?(token)

      assert [%Token{} = row] = tokens()
      assert row.user_uuid == user.uuid
      assert row.target_host == @target
      assert row.redirect_path == "/shop"
      assert row.browser_nonce_hash == :crypto.hash(:sha256, nonce_cookie.value)
      assert row.token_hash == :crypto.hash(:sha256, token)

      # 4: redeem. Signed in through the normal path, with a session token of its own.
      assert redirected_to(redeem, 302) == "/shop"
      assert_deleted(redeem, @nonce_cookie)

      new_token = get_session(redeem, :user_token)
      assert is_binary(new_token)
      refute new_token == source_token
      assert Auth.get_user_by_session_token(new_token).uuid == user.uuid
      assert get_session(redeem, :live_socket_id) =~ "phoenix_kit_sessions:"

      remember_me = WebAuth.remember_me_cookie()
      refute match?(%{max_age: age} when age != 0, redeem.resp_cookies[remember_me])

      assert flash(redeem, "info") == signed_in(user)
      assert %DateTime{} = Repo.get!(Token, row.uuid).used_at

      for conn <- [start, prepare, mint, redeem], do: assert_no_store(conn)
    end

    test "replaces the account the target browser is already signed in as" do
      user = user!()
      other = user!()
      other_session = signed_in_session(other)

      {[_, _, _, redeem], _} =
        handoff(new_browser(),
          session: signed_in_session(user),
          target_opts: [session: other_session]
        )

      new_token = get_session(redeem, :user_token)
      refute new_token == other_session[:user_token]
      assert Auth.get_user_by_session_token(new_token).uuid == user.uuid
      assert flash(redeem, "info") == signed_in(user)
    end

    test "lands on the path the link named, not in the person's saved language" do
      {:ok, user} = Auth.update_user_locale_preference(user!(), "fr-FR")
      to = Routes.path("/admin")

      {[_, _, _, redeem], _} = handoff(new_browser(), session: signed_in_session(user), to: to)

      assert redirected_to(redeem, 302) == to
      assert get_session(redeem, :user_token)
    end

    test "a module's apply hook runs before the sign-in, and its notice joins the flash" do
      user = user!()
      session = signed_in_session(user) ++ [stub_cart: "cart-1"]

      {[_, _, _, redeem], _} = handoff(new_browser(), session: session)

      assert_received {:handoff_apply, context, %{"cart" => "cart-1"}}
      assert context.user_uuid == user.uuid
      # Before the sign-in: the session it sees is the target browser's own, with no account.
      refute Map.has_key?(context.session, "user_token")

      assert flash(redeem, "info") ==
               signed_in(user) <> " Your cart came along."
    end
  end

  describe "a visitor with nothing to carry" do
    test "is redirected straight to the target: no cookie, no row" do
      {start, _} = visit(new_browser(), @source, Handoff.start_path("de", "/shop"))

      assert redirected_to(start, 302) == "https://#{@target}/shop"
      assert handoff_cookies(start) == []
      assert tokens() == []
      assert_no_store(start)
    end
  end

  describe "a guest with a module snapshot" do
    test "has it applied on the target" do
      {[start, _, mint, redeem], _} =
        handoff(new_browser(), session: [stub_cart: "cart-1"], to: "/shop?x=1")

      assert Map.has_key?(start.resp_cookies, @start_cookie)

      # The snapshot hook: once at start (is there anything to carry?), once at mint.
      assert_received {:handoff_snapshot, at_start}
      assert_received {:handoff_snapshot, at_mint}
      assert Enum.sort(Map.keys(at_start)) == [:cookies, :session, :user_uuid]
      assert at_start.user_uuid == nil
      assert at_start.session["stub_cart"] == "cart-1"
      assert is_map(at_start.cookies)
      refute Map.has_key?(at_start.cookies, @start_cookie)
      assert at_mint.session["stub_cart"] == "cart-1"
      refute_received {:handoff_snapshot, _}

      assert [%Token{user_uuid: nil, payload: payload}] = tokens()
      assert payload == %{"handoff_stub" => %{"cart" => "cart-1", "atom_key" => "value"}}
      assert %{path: @prefix <> "/" <> _} = location(mint)

      # The apply hook, with the target's context, the payload with string keys.
      assert_received {:handoff_apply, context, payload}
      assert payload == %{"cart" => "cart-1", "atom_key" => "value"}

      assert Enum.sort(Map.keys(context)) ==
               [:cookies, :host, :locale, :session, :user_uuid]

      assert context.user_uuid == nil
      assert context.host == @target
      assert context.locale == "de-DE"
      refute Map.has_key?(context.cookies, @nonce_cookie)

      # A guest is redirected, not signed in; the notice is the flash; the cookie the module asked
      # for is set with the options the core passes on and no others.
      assert redirected_to(redeem, 302) == "/shop?x=1"
      refute get_session(redeem, :user_token)
      assert flash(redeem, "info") == "Your cart came along."

      cookie = assert_cookie(redeem, "stub_cart_id", http_only: true, max_age: 600)
      assert cookie.value == "cart-1"
      refute Map.has_key?(cookie, :unsafe_option)
    end

    test "a module that fails does not break the handoff of the others" do
      :ok = ModuleRegistry.register(HandoffFailingModule)
      on_exit(fn -> ModuleRegistry.unregister(HandoffFailingModule) end)

      log =
        capture_log(fn ->
          {[_, _, _, redeem], _} = handoff(new_browser(), session: [stub_cart: "cart-1"])
          assert flash(redeem, "info") == "Your cart came along."
        end)

      assert log =~ "HandoffFailingModule raised RuntimeError"
      refute log =~ "secret-session-value"
      assert [%Token{payload: payload}] = tokens()
      assert Map.keys(payload) == ["handoff_stub"]
    end
  end

  describe "who may sign in" do
    # One rule, `Auth.sign_in_refusal/1`: `log_in_user/3` refuses what it names, and so does the
    # handoff (at start, mint and redeem).
    defp refused_by_log_in?(user) do
      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> WebAuth.log_in_user(user)

      conn.halted and redirected_to(conn, 302) == Routes.path("/users/log-in") and
        is_nil(get_session(conn, :user_token))
    end

    test "log_in_user/3 and the handoff refuse the same accounts" do
      for attrs <- [%{is_active: false}, %{api_only: true}, %{managed_by_members: true}] do
        user = struct(Auth.User, Map.put(attrs, :uuid, Ecto.UUID.generate()))

        assert refused_by_log_in?(user), inspect(attrs)
        refute Auth.may_sign_in?(user), inspect(attrs)

        scope = struct(PhoenixKit.Users.Auth.Scope, user: user, authenticated?: true)
        assert Handoff.carried_user(scope) == :refused, inspect(attrs)
      end
    end

    test "an account log_in_user/3 refuses since the mint is not signed in at redeem" do
      for attrs <- [[is_active: false], [api_only: true]] do
        user = user!()
        {browser, _prepare, mint, _token} = minted(signed_in_session(user))
        Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid), set: attrs)

        {conn, _} = follow(browser, mint)
        assert_refused(conn)
        refute get_session(conn, :user_token), inspect(attrs)
      end
    end
  end

  ## Refusals

  describe "start" do
    test "refuses a language with no host, one with the current host, and a host that is no domain of the site" do
      for lang <- ["xx", "en", "en-US", "", "../etc", String.duplicate("a", 40)] do
        {conn, _} = visit(new_browser(), @source, "#{@prefix}/start?lang=#{lang}&to=/")
        assert_refused(conn)
        refute Map.has_key?(conn.resp_cookies, @start_cookie)
      end

      {conn, _} = visit(new_browser(), "www.example.com", Handoff.start_path("de"))
      assert_refused(conn)

      {conn, _} = visit(new_browser(), @source, "#{@prefix}/start")
      assert_refused(conn)
      assert tokens() == []
    end

    test "a target that is not a local path becomes /" do
      for to <- ["//evil.test", "https://evil.test/", "/\\evil.test", "evil", "/a\nb"] do
        query = URI.encode_query(lang: "de", to: to)
        {conn, _} = visit(new_browser(), @source, "#{@prefix}/start?" <> query)
        assert redirected_to(conn, 302) == "https://#{@target}/"
      end
    end

    test "never builds a redirect from a header" do
      {conn, _} =
        visit(new_browser(), @source, Handoff.start_path("de"),
          headers: [{"x-forwarded-host", "evil.test"}, {"origin", "https://evil.test"}]
        )

      assert redirected_to(conn, 302) == "https://#{@target}/"
    end

    test "an impersonated session carries nothing: a plain redirect, no cookie, no row" do
      {admin_session, target} = impersonation_session()
      browser = impersonate(new_browser(), admin_session, target)

      {conn, _} = visit(browser, @source, Handoff.start_path("de", "/shop"))
      assert redirected_to(conn, 302) == "https://#{@target}/shop"
      assert handoff_cookies(conn) == []
      assert tokens() == []
    end
  end

  # `start` is the one step a page can aim a visitor at (a link, a form, an image, a frame, a
  # redirect from another site): it completes a chain that signs the visitor in as the source
  # account, replacing whoever is signed in on the target. The other three steps are reached by
  # cross-site redirects by design (the browser reports `Sec-Fetch-Site: cross-site` for them), so
  # they are not checked.
  describe "start and fetch metadata" do
    defp start_with(headers, browser \\ new_browser()) do
      visit(browser, @source, Handoff.start_path("de", "/shop"),
        session: signed_in_session(user!()),
        headers: headers
      )
    end

    defp assert_refused_without_effects(conn) do
      assert_refused(conn)
      assert handoff_cookies(conn) == []
      assert tokens() == []
    end

    test "a cross-site start is refused: a 302 to /, no cookie, no row" do
      {conn, _} = start_with([{"sec-fetch-site", "cross-site"}])
      assert_refused_without_effects(conn)
    end

    test "a same-origin or user-initiated start (and one from an older browser) goes on" do
      for headers <- [
            [{"sec-fetch-site", "same-origin"}],
            [{"sec-fetch-site", "none"}],
            [],
            [{"sec-fetch-site", "same-origin"}, {"sec-fetch-dest", "document"}],
            [
              {"sec-fetch-site", "none"},
              {"sec-fetch-mode", "navigate"},
              {"sec-fetch-dest", "document"}
            ],
            [{"sec-fetch-dest", "document"}]
          ] do
        {conn, _} = start_with(headers)

        assert %{host: @target, path: @prefix <> "/prepare"} = location(conn)
        assert Map.has_key?(conn.resp_cookies, @start_cookie)
      end
    end

    # Links to `start` are always the host's own, so same-origin: a page of a SIBLING subdomain
    # (same-site: a dangling one, one a tenant controls) is not the host's own page.
    test "a start from another origin of the same site is refused" do
      for headers <- [
            [{"sec-fetch-site", "same-site"}],
            [{"sec-fetch-site", "same-site"}, {"sec-fetch-dest", "document"}],
            [{"sec-fetch-site", " Same-Site "}]
          ] do
        {conn, _} = start_with(headers)
        assert_refused_without_effects(conn)
      end
    end

    test "a start that is not a top-level navigation is refused, whatever the site says" do
      for dest <- [
            "image",
            "iframe",
            "frame",
            "embed",
            "object",
            "script",
            "style",
            "empty",
            "audio",
            "video",
            "worker"
          ],
          site <- ["same-origin", "same-site", "none", nil] do
        headers =
          [{"sec-fetch-dest", dest}] ++ if(site, do: [{"sec-fetch-site", site}], else: [])

        {conn, _} = start_with(headers)
        assert_refused_without_effects(conn)
      end
    end

    test "a value that is not one of the browser's is refused, and the case is not significant" do
      {conn, _} = start_with([{"sec-fetch-site", "somewhere"}])
      assert_refused_without_effects(conn)

      {conn, _} = start_with([{"sec-fetch-site", "Cross-Site"}])
      assert_refused_without_effects(conn)

      {conn, _} =
        start_with([{"sec-fetch-site", " Same-Origin "}, {"sec-fetch-dest", "Document"}])

      assert %{host: @target} = location(conn)
    end

    test "a refusal costs no rate-limit budget: subresource loads cannot burn the visitor's starts" do
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_start_limit)
      browser = new_browser()

      for headers <- [
            [{"sec-fetch-site", "cross-site"}, {"sec-fetch-dest", "image"}],
            [{"sec-fetch-site", "cross-site"}, {"sec-fetch-dest", "iframe"}]
          ],
          _ <- 1..limit do
        {conn, _} = start_with(headers, browser)
        assert_refused_without_effects(conn)
      end

      # The same address, a real click, still has its whole budget.
      for _ <- 1..limit do
        {conn, _} = start_with([{"sec-fetch-site", "same-origin"}], browser)
        assert %{host: @target} = location(conn)
      end

      {conn, _} = start_with([{"sec-fetch-site", "same-origin"}], browser)
      assert_refused(conn)
    end

    test "prepare, mint and redeem are reached by cross-site redirects, and complete the chain" do
      cross = [
        {"sec-fetch-site", "cross-site"},
        {"sec-fetch-mode", "navigate"},
        {"sec-fetch-dest", "document"}
      ]

      {[_, _, _, redeem], _} =
        handoff(new_browser(),
          session: signed_in_session(user!()),
          headers: [{"sec-fetch-site", "same-origin"}],
          target_opts: [headers: cross],
          mint_opts: [headers: cross],
          redeem_opts: [headers: cross]
        )

      assert redirected_to(redeem, 302) == "/shop"
      assert get_session(redeem, :user_token)
    end
  end

  describe "prepare, mint and redeem loaded as something other than a page" do
    # `<img src=".../handoff/<token>">` on another site is a cross-site subresource request: it
    # must not spend the visitor's failed-redeem budget, and none of the three steps may act on a
    # request that is not a document navigation. They are not checked for the SITE (a redirect
    # from another of the host's domains is cross-site, by design), only for what is loaded.
    @subresources ~w(image iframe frame embed object script style empty audio video worker)

    defp subresource(dest), do: [{"sec-fetch-site", "cross-site"}, {"sec-fetch-dest", dest}]

    # The handoff entries of the rate limiter that belong to this browser's address or proof.
    defp buckets(browser, s) do
      ip = browser.peer |> :inet.ntoa() |> to_string()

      RateLimiter.Backend
      |> :ets.tab2list()
      |> Enum.filter(fn {{key, _bucket}, _count, _expiry} ->
        String.starts_with?(key, "auth:handoff") and
          (String.contains?(key, ip) or String.ends_with?(key, s))
      end)
      |> Enum.sort()
    end

    test "are each refused with no effect and no budget, and the real ones still work" do
      session = signed_in_session(user!())
      {browser, s} = started(new_browser(), session)
      source_cookie = browser.jars[@source][@start_cookie]

      # prepare
      for dest <- @subresources do
        {conn, _} =
          visit(browser, @target, "#{@prefix}/prepare?return=#{@source}&to=%2Fshop&s=#{s}",
            headers: subresource(dest)
          )

        assert_refused(conn)
        assert handoff_cookies(conn) == []
      end

      {n, browser} = prepared(browser, s)

      # mint: the source cookie is not deleted, no budget is taken, no row is written
      before = buckets(browser, s)

      for dest <- @subresources do
        {conn, _} =
          visit(browser, @source, mint_path(n, s), session: session, headers: subresource(dest))

        assert_refused(conn)
        assert handoff_cookies(conn) == []
      end

      assert buckets(browser, s) == before
      assert browser.jars[@source][@start_cookie] == source_cookie
      assert tokens() == []

      # The proof's budget is one mint: had a refusal taken it, this one would be refused.
      {mint, browser} = visit(browser, @source, mint_path(n, s), session: session)
      assert %{host: @target, path: @prefix <> "/" <> token} = location(mint)
      assert [%Token{used_at: nil}] = tokens()

      # redeem: the failed-redeem budget is not touched, the token is not burnt, the nonce
      # cookie stays
      before = buckets(browser, s)
      nonce = browser.jars[@target][@nonce_cookie]

      for dest <- @subresources do
        {conn, _} = visit(browser, @target, "#{@prefix}/#{token}", headers: subresource(dest))

        assert_refused(conn)
        assert handoff_cookies(conn) == []
      end

      assert buckets(browser, s) == before
      assert browser.jars[@target][@nonce_cookie] == nonce
      assert [%Token{used_at: nil}] = tokens()

      {redeem, _} = follow(browser, mint, headers: [{"sec-fetch-dest", "document"}])
      assert redirected_to(redeem, 302) == "/shop"
      assert get_session(redeem, :user_token)
    end

    test "a flood of image loads of a redeem URL does not spend the failed-redeem budget" do
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_redeem_failure_limit)
      session = signed_in_session(user!())
      {browser, _prepare, mint, token} = minted(session)

      for _ <- 1..(limit + 5) do
        {conn, _} = visit(browser, @target, "#{@prefix}/#{token}", headers: subresource("image"))
        assert_refused(conn)
      end

      {redeem, _} = follow(browser, mint)
      assert redirected_to(redeem, 302) == "/shop"
      assert get_session(redeem, :user_token)
    end

    test "a request that names a document, or no destination, is a navigation, whatever the site" do
      session = signed_in_session(user!())

      for dest <- [[{"sec-fetch-dest", "document"}], [{"sec-fetch-dest", " Document "}], []] do
        headers = [{"sec-fetch-site", "cross-site"}] ++ dest

        {[_, _, _, redeem], _} =
          handoff(new_browser(),
            session: session,
            headers: [{"sec-fetch-site", "same-origin"}],
            target_opts: [headers: headers],
            mint_opts: [headers: headers],
            redeem_opts: [headers: headers]
          )

        assert redirected_to(redeem, 302) == "/shop"
        assert get_session(redeem, :user_token)
      end
    end
  end

  describe "prepare" do
    test "refuses a return host that is not on the allow-list, the same host, and a bad target" do
      to = "%2Fshop"
      s = Handoff.source_proof_param(Handoff.new_secret())

      for query <- [
            "return=evil.test&to=#{to}&s=#{s}",
            "return=#{@target}&to=#{to}&s=#{s}",
            "return=#{@source}&to=//evil.test&s=#{s}",
            "return=#{@source}&s=#{s}",
            "to=#{to}&s=#{s}",
            "return=https%3A%2F%2F#{@source}&to=#{to}&s=#{s}",
            "return=#{@source}:99&to=#{to}&s=#{s}",
            "return=#{@source}&to=#{to}",
            "return=#{@source}&to=#{to}&s=short",
            "return=#{@source}&to=#{to}&s=#{String.duplicate("!", 43)}"
          ] do
        {conn, _} = visit(new_browser(), @target, "#{@prefix}/prepare?" <> query)
        assert_refused(conn)
        refute Map.has_key?(conn.resp_cookies, @nonce_cookie)
      end
    end

    test "gives a browser that holds a nonce the same one again" do
      browser = new_browser()
      path = "#{@prefix}/prepare?return=#{@source}&to=%2Fshop&s=#{proof()}"

      {first, browser} = visit(browser, @target, path)
      {second, _} = visit(browser, @target, path)

      assert location(first).query["n"] == location(second).query["n"]
      assert first.resp_cookies[@nonce_cookie].value == second.resp_cookies[@nonce_cookie].value
    end

    test "ignores a nonce cookie that is not well-formed" do
      {conn, _} =
        visit(new_browser(), @target, "#{@prefix}/prepare?return=#{@source}&to=%2F&s=#{proof()}",
          headers: [{"cookie", "#{@nonce_cookie}=short"}]
        )

      assert Handoff.secret?(conn.resp_cookies[@nonce_cookie].value)
    end
  end

  describe "mint" do
    defp prepared(browser, s \\ proof()) do
      {prepare, browser} =
        visit(browser, @target, "#{@prefix}/prepare?return=#{@source}&to=%2Fshop&s=#{s}")

      {location(prepare).query["n"], browser}
    end

    defp mint_path(n, s, h \\ @target, to \\ "/shop"),
      do: "#{@prefix}/mint?" <> URI.encode_query(n: n, s: s, h: h, to: to)

    # The browser after `start`, with the proof of its source cookie.
    defp started(browser, session) do
      {start, browser} =
        visit(browser, @source, Handoff.start_path("de", "/shop"), session: session)

      assert Map.has_key?(start.resp_cookies, @start_cookie)
      {browser, location(start).query["s"]}
    end

    test "is refused for a browser that never clicked start, and writes nothing" do
      session = signed_in_session(user!())
      {n, _} = prepared(new_browser())

      {conn, _} = visit(new_browser(), @source, mint_path(n, proof()), session: session)
      assert_refused(conn)
      assert tokens() == []
    end

    test "needs the source cookie, which is good for one attempt" do
      session = signed_in_session(user!())
      {browser, s} = started(new_browser(), session)
      {n, browser} = prepared(browser, s)

      {first, browser} = visit(browser, @source, mint_path(n, s))
      assert %{host: @target} = location(first)
      assert_deleted(first, @start_cookie)
      assert length(tokens()) == 1

      {second, _} = visit(browser, @source, mint_path(n, s))
      assert_refused(second)
      assert length(tokens()) == 1
    end

    test "a request that does not carry the visitor's own proof leaves the source cookie alone" do
      session = signed_in_session(user!())
      {browser, s} = started(new_browser(), session)
      {n, browser} = prepared(browser, s)

      # What a page of another site can make the visitor's browser request: no proof at all, a
      # malformed one, the proof of somebody else's start. The browser takes each response, so a
      # deletion in any of them would take the visitor's real cookie.
      browser =
        Enum.reduce(
          ["#{@prefix}/mint?x=1", mint_path(n, "short"), mint_path(n, proof())],
          browser,
          fn
            path, browser ->
              {conn, browser} = visit(browser, @source, path, session: session)
              assert_refused(conn)
              refute Map.has_key?(conn.resp_cookies, @start_cookie)
              browser
          end
        )

      assert tokens() == []

      {mint, _} = visit(browser, @source, mint_path(n, s), session: session)
      assert %{host: @target} = location(mint)
      assert_deleted(mint, @start_cookie)
      assert length(tokens()) == 1
    end

    test "a mint refused for a reason after its proof matched spends the source cookie" do
      session = signed_in_session(user!())
      {browser, s} = started(new_browser(), session)
      {n, browser} = prepared(browser, s)

      {conn, browser} = visit(browser, @source, mint_path(n, s, "evil.test"), session: session)
      assert_refused(conn)
      assert_deleted(conn, @start_cookie)
      refute Map.has_key?(browser.jars[@source], @start_cookie)
      assert tokens() == []
    end

    # A non-browser client ignores the Set-Cookie that deletes the cookie, so the deletion is
    # worth nothing: the proof must be single use on the SERVER. `visit/4` is given the genuine
    # cookie again on every request, which is exactly a client that ignores the deletion.
    defp replay_genuine_cookie(session, times) do
      {browser, s} = started(new_browser(), session)
      cookie = browser.jars[@source][@start_cookie]

      for _ <- 1..times do
        n = Handoff.nonce_hash_param(Handoff.new_secret())

        {conn, _} =
          visit(browser, @source, mint_path(n, s),
            session: session,
            cookies: [{@start_cookie, cookie}]
          )

        conn
      end
    end

    defp minted_mints(conns),
      do: Enum.count(conns, &(&1.status == 302 and location(&1).host == @target))

    test "a genuine source cookie replayed by a client that ignores its deletion makes one row" do
      conns = replay_genuine_cookie(signed_in_session(user!()), 5)

      assert minted_mints(conns) == 1
      assert length(tokens()) == 1
      for conn <- Enum.drop(conns, 1), do: assert_refused(conn)
    end

    test "a replay is refused before the scope is built and any module is asked" do
      session = signed_in_session(user!()) ++ [stub_cart: "cart-1"]
      _ = asked_for_snapshots()

      conns = replay_genuine_cookie(session, 5)

      assert minted_mints(conns) == 1
      # Only the mint that wrote the row took a snapshot: the four replays cost no module a call.
      assert asked_for_snapshots() == 1
    end

    defp asked_for_snapshots do
      receive do
        {:handoff_snapshot, _context} -> 1 + asked_for_snapshots()
      after
        0 -> 0
      end
    end

    test "so does one replayed by a guest who has only module state to carry" do
      conns = replay_genuine_cookie([stub_cart: "cart-1"], 5)

      assert minted_mints(conns) == 1
      assert [%Token{user_uuid: nil}] = tokens()
    end

    test "the proof stays spent when the limiter has forgotten it: the database refuses the replay" do
      session = signed_in_session(user!()) ++ [stub_cart: "cart-1"]
      {browser, s} = started(new_browser(), session)
      cookie = browser.jars[@source][@start_cookie]
      n = Handoff.nonce_hash_param(Handoff.new_secret())

      {first, _} =
        visit(browser, @source, mint_path(n, s),
          session: session,
          cookies: [{@start_cookie, cookie}]
        )

      assert %{host: @target} = location(first)
      assert asked_for_snapshots() == 1

      # What a second node, or a restart, looks like: no counter, but the same database.
      :ets.match_delete(
        PhoenixKit.Users.RateLimiter.Backend,
        {{"auth:handoff_mint:proof:" <> s, :_}, :_, :_}
      )

      {second, _} =
        visit(browser, @source, mint_path(n, s),
          session: session,
          cookies: [{@start_cookie, cookie}]
        )

      assert_refused(second)
      assert length(tokens()) == 1
      # The database is asked about the proof before any module is: no snapshot round for it.
      assert asked_for_snapshots() == 0
    end

    # The cookie's 60 seconds are enforced by the SERVER, from its signature: a client that keeps
    # the cookie past its `Max-Age` (or one that ignores the deletion) gets nothing from it after
    # a minute, which is what makes the proof single use once the rows are pruned.
    defp aged_source_cookie(secret, age_seconds) do
      Plug.Crypto.sign(@endpoint.config(:secret_key_base), @start_cookie <> "_cookie", secret,
        signed_at: System.system_time(:second) - age_seconds,
        max_age: 60,
        keys: Plug.Keys
      )
    end

    defp mint_with_cookie_aged(age_seconds) do
      session = signed_in_session(user!())
      secret = Handoff.new_secret()
      s = Handoff.source_proof_param(secret)
      {n, browser} = prepared(new_browser(), s)

      {conn, _} =
        visit(browser, @source, mint_path(n, s),
          session: session,
          cookies: [{@start_cookie, aged_source_cookie(secret, age_seconds)}]
        )

      conn
    end

    test "the source cookie start sets carries a 60-second limit in its signature" do
      {browser, _s} = started(new_browser(), signed_in_session(user!()))
      [_header, payload, _signature] = String.split(browser.jars[@source][@start_cookie], ".")

      assert {_secret, signed_at_ms, 60} =
               payload |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term([:safe])

      assert abs(System.system_time(:millisecond) - signed_at_ms) < 10_000
    end

    test "a source cookie is accepted just under 60 seconds old and refused just over" do
      assert %{host: @target} = location(mint_with_cookie_aged(58))
      assert length(tokens()) == 1

      assert_refused(mint_with_cookie_aged(62))
      assert length(tokens()) == 1
    end

    test "mints are limited per address, for a guest and for a signed-in account alike" do
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_mint_ip_limit)

      for session <- [[stub_cart: "cart-1"], signed_in_session(user!())] do
        browser = new_browser()
        ip = browser.peer |> :inet.ntoa() |> to_string()
        for _ <- 1..limit, do: assert(:ok = RateLimiter.check_handoff_mint_ip_rate_limit(ip))

        {[_, _, mint, _], _} = handoff(browser, session: session)
        assert_refused(mint)
        assert tokens() == []

        # Another address is not affected.
        {[_, _, other_mint, _], _} = handoff(new_browser(), session: session)
        assert %{host: @target} = location(other_mint)
        Repo.delete_all(Token)
      end
    end

    test "a flood of guests' mints from one address stops at the address limit" do
      limit = 5
      RateLimitIsolation.put(:handoff_mint_ip_limit, limit)

      browser = new_browser()

      mints =
        for _ <- 1..(limit * 3) do
          {[_, _, mint, _], _} = handoff(browser, session: [stub_cart: "cart-1"])
          mint
        end

      assert minted_mints(mints) == limit
      assert length(tokens()) == limit
    end

    test "is refused for a source cookie the application did not issue, with a proof that matches it" do
      session = signed_in_session(user!())
      forged = Handoff.new_secret()
      {n, _} = prepared(new_browser())

      for cookie <- [forged, "SFMyNTY.forged.forged", ""] do
        {conn, _} =
          visit(new_browser(), @source, mint_path(n, Handoff.source_proof_param(forged)),
            session: session,
            cookies: [{@start_cookie, cookie}]
          )

        assert_refused(conn)
      end

      assert tokens() == []
    end

    test "is refused for a source cookie issued for another start: the proof must be its own" do
      session = signed_in_session(user!())
      {browser, _s} = started(new_browser(), session)
      {_other_browser, other_s} = started(new_browser(), session)
      {n, browser} = prepared(browser, other_s)

      # A real cookie of this browser, the proof of a different start's.
      {conn, _} = visit(browser, @source, mint_path(n, other_s))
      assert_refused(conn)
      assert tokens() == []
    end

    test "is refused without a proof, or with one that is not a hash of a secret" do
      session = signed_in_session(user!())

      for s <- [nil, "", "short", String.duplicate("!", 43), String.duplicate("a", 44)] do
        {browser, _s} = started(new_browser(), session)
        {n, browser} = prepared(browser)

        path =
          "#{@prefix}/mint?" <>
            URI.encode_query(Enum.reject([n: n, s: s, h: @target, to: "/"], &is_nil(elem(&1, 1))))

        {conn, _} = visit(browser, @source, path)
        assert_refused(conn)
      end

      assert tokens() == []
    end

    test "an anonymous visitor with nothing for any module to carry gets no row, whatever the proof" do
      # A cookie the application did issue (a guest with a cart clicked start), then the cart is
      # gone by the time of the mint: nothing to carry, no account.
      {browser, s} = started(new_browser(), stub_cart: "cart-1")
      {n, browser} = prepared(browser, s)

      # The browser lost its session (the cart with it) but kept the source cookie.
      jars = Map.update!(browser.jars, @source, &Map.delete(&1, "_phoenix_kit_key"))

      {conn, _} = visit(%{browser | jars: jars}, @source, mint_path(n, s))
      assert_refused(conn)
      assert_deleted(conn, @start_cookie)
      assert tokens() == []
    end

    test "a flood of mints from one address, with no start behind them, writes no row" do
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_mint_limit)
      browser = new_browser()
      {n, _} = prepared(new_browser())

      for _ <- 1..(limit * 3) do
        s = proof()

        {conn, _} =
          visit(browser, @source, mint_path(n, s),
            cookies: [{@start_cookie, Handoff.new_secret()}]
          )

        assert_refused(conn)
      end

      assert tokens() == []
    end

    test "is refused for a hash that is not 32 bytes of base64url, whatever else is right" do
      session = signed_in_session(user!())

      for n <- [
            "abc",
            "",
            String.duplicate("a", 44),
            String.duplicate("a", 42),
            String.duplicate("!", 43),
            String.duplicate("a", 43) <> "=="
          ] do
        {browser, s} = started(new_browser(), session)
        {conn, _} = visit(browser, @source, mint_path(n, s))
        assert_refused(conn)
      end

      assert tokens() == []
    end

    test "is refused for a host that is not on the allow-list or is its own, and a bad target" do
      session = signed_in_session(user!())

      for {h, to} <- [
            {"evil.test", "/shop"},
            {@source, "/shop"},
            {@target <> ":99", "/shop"},
            {@target, "//evil.test"},
            {@target, "https://evil.test"}
          ] do
        {browser, s} = started(new_browser(), session)
        {n, browser} = prepared(browser, s)
        {conn, _} = visit(browser, @source, mint_path(n, s, h, to))
        assert_refused(conn)
      end

      assert tokens() == []
    end

    test "is refused on a host that is no domain of the site" do
      session = signed_in_session(user!())
      {n, _} = prepared(new_browser())

      {conn, _} =
        visit(new_browser(), "www.example.com", mint_path(n, proof()),
          session: session,
          headers: [{"cookie", "#{@start_cookie}=#{Handoff.new_secret()}"}]
        )

      assert_refused(conn)
      assert tokens() == []
    end

    test "is refused for an impersonated session" do
      {admin_session, target} = impersonation_session()
      {browser, s} = started(new_browser(), admin_session)
      {n, browser} = prepared(browser, s)
      browser = impersonate(browser, [], target)

      {conn, _} = visit(browser, @source, mint_path(n, s))
      assert_refused(conn, carried_flash: true)
      assert tokens() == []
    end

    test "carries no account for one that has been deactivated, only what the modules hold" do
      user = user!()
      session = signed_in_session(user) ++ [stub_cart: "cart-1"]
      {browser, s} = started(new_browser(), session)
      {n, browser} = prepared(browser, s)

      Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid), set: [is_active: false])

      {conn, _} = visit(browser, @source, mint_path(n, s))
      assert %{host: @target} = location(conn)
      assert [%Token{user_uuid: nil}] = tokens()
    end

    test "is limited per account" do
      user = user!()
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_mint_limit)
      for _ <- 1..limit, do: assert(:ok = RateLimiter.check_handoff_mint_rate_limit(user.uuid))

      {[_, _, mint, _], _} = handoff(new_browser(), session: signed_in_session(user))
      assert_refused(mint)
      assert tokens() == []
    end
  end

  describe "redeem" do
    defp minted(session, opts \\ []) do
      {[_, prepare, mint, _], browser} =
        handoff_until_mint(new_browser(), session, opts)

      {browser, prepare, mint, location(mint).path |> String.split("/") |> List.last()}
    end

    defp handoff_until_mint(browser, session, opts) do
      {start, browser} =
        visit(browser, @source, Handoff.start_path("de", "/shop"),
          session: session,
          headers: Keyword.get(opts, :mint_headers, [])
        )

      {prepare, browser} = follow(browser, start)
      {mint, browser} = follow(browser, prepare, headers: Keyword.get(opts, :mint_headers, []))
      {[start, prepare, mint, nil], browser}
    end

    test "a second visit to the same link is refused, and says no more than an unknown token" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, token} = minted(session)

      {first, browser} = follow(browser, mint)
      assert redirected_to(first, 302) == "/shop"

      {used, _} = visit(browser, @target, "#{@prefix}/#{token}")
      {unknown, _} = visit(browser, @target, "#{@prefix}/#{Handoff.new_secret()}")

      for conn <- [used, unknown], do: assert_refused(conn, carried_flash: true)

      assert {used.status, get_resp_header(used, "location"), cookie_names(used),
              get_session(used, "phoenix_flash")} ==
               {unknown.status, get_resp_header(unknown, "location"), cookie_names(unknown),
                get_session(unknown, "phoenix_flash")}
    end

    test "a request that does not redeem leaves the nonce cookie alone" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, _token} = minted(session)

      # What a page of another site can make the visitor's browser request: a token that is no
      # row's (well formed or not). The browser takes each response, so a deletion in any of
      # them would take the nonce the visitor's real handoff needs.
      browser =
        Enum.reduce([Handoff.new_secret(), "x", "not-a-token"], browser, fn token, browser ->
          {conn, browser} = visit(browser, @target, "#{@prefix}/#{token}")
          assert_refused(conn)
          refute Map.has_key?(conn.resp_cookies, @nonce_cookie)
          browser
        end)

      assert [%Token{used_at: nil}] = tokens()

      {redeem, _} = follow(browser, mint)
      assert redirected_to(redeem, 302) == "/shop"
      assert get_session(redeem, :user_token)
      assert_deleted(redeem, @nonce_cookie)
    end

    test "another browser does not get in, and does not burn the token" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, token} = minted(session)

      # A browser that never prepared, and one that did, for itself.
      {nobody, _} = visit(new_browser(), @target, "#{@prefix}/#{token}")
      assert_refused(nobody)

      {_n, intruder} = prepared(new_browser())
      {wrong_nonce, _} = visit(intruder, @target, "#{@prefix}/#{token}")
      assert_refused(wrong_nonce)
      refute Map.has_key?(wrong_nonce.resp_cookies, @nonce_cookie)

      assert [%Token{used_at: nil}] = tokens()

      {redeem, _} = follow(browser, mint)
      assert redirected_to(redeem, 302) == "/shop"
      assert get_session(redeem, :user_token)
    end

    test "another host does not get in, and does not burn the token" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, token} = minted(session)

      # The same browser, the same nonce cookie value, another domain of the site.
      nonce = browser.jars[@target][@nonce_cookie]
      other = %{browser | jars: Map.put(browser.jars, "shop-fr.test", %{@nonce_cookie => nonce})}

      {conn, _} = visit(other, "shop-fr.test", "#{@prefix}/#{token}")
      assert_refused(conn)
      assert [%Token{used_at: nil}] = tokens()

      {redeem, _} = follow(browser, mint)
      assert redirected_to(redeem, 302) == "/shop"
    end

    test "an expired link is refused" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, _token} = minted(session)

      past = DateTime.add(DateTime.utc_now(), -5, :second)
      Repo.update_all(Token, set: [expires_at: past])

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      refute get_session(conn, :user_token)
    end

    test "a different User-Agent is refused and does not burn the token" do
      session = signed_in_session(user!())

      {browser, _prepare, mint, _token} =
        minted(session, mint_headers: [{"user-agent", "Agent A"}])

      {other, _} = follow(browser, mint, headers: [{"user-agent", "Agent B"}])
      assert_refused(other)
      assert [%Token{used_at: nil}] = tokens()

      {same, _} = follow(browser, mint, headers: [{"user-agent", "Agent A"}])
      assert redirected_to(same, 302) == "/shop"
    end

    test "a link that is not a token is refused" do
      for token <- ["start1", "x", String.duplicate("a", 43), String.duplicate("%00", 43)] do
        {conn, _} = visit(new_browser(), @target, "#{@prefix}/#{token}")
        assert_refused(conn)
      end
    end

    test "an account deactivated since the mint is not signed in" do
      user = user!()
      {browser, _prepare, mint, _token} = minted(signed_in_session(user))

      Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid), set: [is_active: false])

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      refute get_session(conn, :user_token)
    end

    test "a target that is not a local path never reaches a redirect" do
      user = user!()
      {browser, _prepare, mint, _token} = minted(signed_in_session(user))
      Repo.update_all(Token, set: [redirect_path: "//evil.test"])

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
    end
  end

  ## Requests with no side effects

  describe "prefetch, preview and HEAD" do
    test "change nothing, on all four endpoints" do
      session = signed_in_session(user!())
      {browser, _prepare, _mint, token} = minted(session)
      rows = tokens()

      requests = [
        {@source, Handoff.start_path("fr")},
        {@target, "#{@prefix}/prepare?return=#{@source}&to=%2F"},
        {@source, "#{@prefix}/mint?n=#{Handoff.new_secret()}&h=#{@target}&to=%2F"},
        {@target, "#{@prefix}/#{token}"}
      ]

      for headers <- [
            [{"sec-purpose", "prefetch"}],
            [{"sec-purpose", "prefetch;anonymous-client-ip"}],
            [{"purpose", "prefetch"}],
            [{"purpose", "preview"}],
            [{"sec-purpose", "prerender"}]
          ],
          {host, path} <- requests do
        {conn, _} = visit(browser, host, path, session: session, headers: headers)

        assert conn.status == 204
        assert conn.resp_body == ""
        assert handoff_cookies(conn) == []
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert tokens() == rows
      end
    end

    test "a HEAD request is answered 204 even after Plug.Head made it a GET, and does not burn a token" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, token} = minted(session)

      {head, _} = visit(browser, @target, "#{@prefix}/#{token}", method: "HEAD")
      assert head.status == 204
      assert [%Token{used_at: nil}] = tokens()

      {start, _} =
        visit(new_browser(), @source, Handoff.start_path("de"), session: session, method: "HEAD")

      assert start.status == 204
      assert handoff_cookies(start) == []

      {redeem, _} = follow(browser, mint)
      assert redirected_to(redeem, 302) == "/shop"
    end

    test "an ordinary navigation still works" do
      session = signed_in_session(user!())

      {[_, _, _, redeem], _} =
        handoff(new_browser(),
          session: session,
          headers: [{"sec-purpose", "navigate"}],
          target_opts: [headers: [{"purpose", "navigate"}]]
        )

      assert get_session(redeem, :user_token)
    end
  end

  ## Failure looks the same everywhere

  describe "failure" do
    test "is a redirect to / with no message and no handoff cookie, at every step" do
      failures = [
        elem(visit(new_browser(), @source, "#{@prefix}/start?lang=xx"), 0),
        elem(visit(new_browser(), @target, "#{@prefix}/prepare?return=evil.test&to=%2F"), 0),
        elem(visit(new_browser(), @source, "#{@prefix}/mint?n=abc&h=#{@target}&to=%2F"), 0),
        elem(visit(new_browser(), @target, "#{@prefix}/#{Handoff.new_secret()}"), 0)
      ]

      for conn <- failures do
        assert_refused(conn)
        assert conn.status == 302
        assert handoff_cookies(conn) == []
      end
    end

    test "starts are limited per address before anything is looked up" do
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_start_limit)
      browser = new_browser()

      for _ <- 1..limit do
        {conn, _} = visit(browser, @source, "#{@prefix}/start?lang=xx")
        assert redirected_to(conn, 302) == "/"
      end

      # Refused with a valid request and the right browser: nothing is set and nothing written.
      {conn, _} =
        visit(browser, @source, Handoff.start_path("de", "/shop"),
          session: signed_in_session(user!())
        )

      assert_refused(conn)
      assert handoff_cookies(conn) == []
      assert tokens() == []

      # Another address is not affected.
      {other, _} = visit(new_browser(), @source, Handoff.start_path("de"))
      assert redirected_to(other, 302) == "https://#{@target}/"
    end

    test "a handoff is counted once: an address makes more handoffs a minute than the old shared bucket allowed" do
      browser = new_browser()
      session = signed_in_session(user!())

      for _ <- 1..15 do
        {[_, _, _, redeem], _} = handoff(browser, session: session)
        assert redirected_to(redeem, 302) == "/shop"
      end
    end

    test "failed redeems are limited per address, and a good one is not counted" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, _token} = minted(session)
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_redeem_failure_limit)

      for _ <- 1..limit do
        {conn, _} = visit(browser, @target, "#{@prefix}/#{Handoff.new_secret()}")
        assert redirected_to(conn, 302) == "/"
      end

      # Over the limit: the valid link is refused too, and is not spent.
      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      assert [%Token{used_at: nil}] = tokens()

      # Another address redeems it fine; the success handed its slot back.
      {redeem, _} = follow(%{browser | peer: new_browser().peer}, mint)
      assert redirected_to(redeem, 302) == "/shop"
    end

    test "a refusal is logged at debug level, not as a warning" do
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_start_limit)
      browser = new_browser()

      log =
        capture_log([level: :warning], fn ->
          for _ <- 1..(limit + 3), do: visit(browser, @source, "#{@prefix}/start?lang=xx")
        end)

      refute log =~ "Rate limit exceeded"
    end
  end

  describe "what a module is handed" do
    test "the session and cookies of the request, without the kit's auth material" do
      user = user!()
      session = signed_in_session(user) ++ [stub_cart: "cart-1"]

      cookies = [
        {"_phoenix_kit_web_user_remember_me", "remember-secret"},
        {"_phoenix_kit_web_session_accounts", "accounts-secret"},
        {"_phoenix_kit_device", "device-secret"},
        {"pk_oauth_browser", "oauth-secret"},
        {"_phoenix_kit_key", "session-cookie-secret"},
        {"theme", "dark"}
      ]

      {[_, _, _, redeem], _} =
        handoff(new_browser(),
          session: session,
          cookies: cookies,
          target_opts: [cookies: [{"theme", "light"}, {"_phoenix_kit_key", "target-session"}]]
        )

      # The control: the session did hold the kit's tokens, so what is missing was removed.
      assert get_session(redeem, :user_token)
      assert [%Token{user_uuid: uuid}] = tokens()
      assert uuid == user.uuid

      # A signed-in visitor: one snapshot, at the mint.
      assert_received {:handoff_snapshot, at_mint}
      refute_received {:handoff_snapshot, _}

      for key <- Handoff.auth_session_keys(), do: refute(Map.has_key?(at_mint.session, key), key)
      assert at_mint.session["stub_cart"] == "cart-1"
      assert at_mint.cookies == %{"theme" => "dark"}
      assert Enum.sort(Map.keys(at_mint)) == [:cookies, :session, :user_uuid]

      assert_received {:handoff_apply, applied, _payload}

      for key <- Handoff.auth_session_keys(), do: refute(Map.has_key?(applied.session, key), key)
      assert applied.cookies == %{"theme" => "light"}
    end

    test "a guest's snapshot at start has none of it either" do
      session = [
        stub_cart: "cart-1",
        user_token: "stale-token",
        live_socket_id: "phoenix_kit_sessions:x",
        pk_session_accounts: ["stale-token"],
        pk_own_tokens: ["stale-token"],
        pk_impersonators: %{"stale-token" => "origin"},
        pk_organization_token: "stale-org-token",
        website_access_unlock: "unlocked"
      ]

      {[_start, _, _, _], _} = handoff(new_browser(), session: session)

      assert_received {:handoff_snapshot, at_start}

      for key <- Handoff.auth_session_keys(), do: refute(Map.has_key?(at_start.session, key), key)
      assert at_start.session["stub_cart"] == "cart-1"
    end

    test "a cookie a module sets is Secure, HttpOnly and SameSite=Lax, and has the options it passed" do
      {[_, _, _, redeem], _} = handoff(new_browser(), session: [stub_cart: "cart-1"])

      cookie =
        assert_cookie(redeem, "stub_cart_id",
          http_only: true,
          same_site: "Lax",
          secure: true,
          max_age: 600
        )

      refute Map.has_key?(cookie, :unsafe_option)
    end
  end

  describe "a module that misbehaves" do
    setup do
      :ok = ModuleRegistry.register(HandoffScriptedModule)

      on_exit(fn ->
        ModuleRegistry.unregister(HandoffScriptedModule)
        HandoffScriptedModule.clear()
      end)
    end

    # The whole flow for a signed-in account, with the script in place; the redeem conn.
    defp handoff_with(script, user \\ nil) do
      HandoffScriptedModule.script(script)
      user = user || user!()
      {[_, _, _, redeem], _} = handoff(new_browser(), session: signed_in_session(user))
      {redeem, user}
    end

    defp handed_over(redeem, user) do
      assert redirected_to(redeem, 302) == "/shop"
      assert get_session(redeem, :user_token)
      assert Auth.get_user_by_session_token(get_session(redeem, :user_token)).uuid == user.uuid
    end

    test "a cookie with a bad name is left out, and the visitor is still handed over" do
      {redeem, user} =
        handoff_with(%{apply: {:ok, %{cookies: [{"bad name;x", "v", []}, {"fine", "v", []}]}}})

      handed_over(redeem, user)
      refute Map.has_key?(redeem.resp_cookies, "bad name;x")
      assert %{value: "v"} = redeem.resp_cookies["fine"]
      assert flash(redeem, "info") == signed_in(user)
    end

    test "a cookie with a huge value is left out" do
      {redeem, user} =
        handoff_with(%{apply: {:ok, %{cookies: [{"huge", String.duplicate("a", 5000), []}]}}})

      handed_over(redeem, user)
      refute Map.has_key?(redeem.resp_cookies, "huge")
    end

    test "a cookie that tries the kit's own names is left out" do
      forged = [
        {"_phoenix_kit_web_user_remember_me", "x", []},
        {"_phoenix_kit_key", "x", []},
        {"__Host-pk_handoff_nonce", "x", []}
      ]

      {redeem, user} = handoff_with(%{apply: {:ok, %{cookies: forged}}})

      handed_over(redeem, user)
      # (The sign-in deletes the remember-me cookie itself; what matters is nobody's value.)
      for name <- ["_phoenix_kit_web_user_remember_me", "_phoenix_kit_key"] do
        refute match?(%{value: "x"}, redeem.resp_cookies[name]), name
      end
    end

    test "five long notices of four-byte characters cannot overflow the session cookie" do
      notices = for n <- 1..5, do: String.duplicate("😀", 300) <> "#{n}"
      {redeem, user} = handoff_with(%{apply: {:ok, notices}})

      handed_over(redeem, user)

      line = flash(redeem, "info")
      assert String.valid?(line)
      assert byte_size(line) <= byte_size(signed_in(user)) + 5 + 600

      [session_cookie] =
        for header <- get_resp_header(redeem, "set-cookie"),
            String.starts_with?(header, "_phoenix_kit_key="),
            do: header

      assert byte_size(session_cookie) < 4096
    end

    test "an answer that is not the contract's is ignored, and the visitor is handed over" do
      for garbage <- [:ok, {:ok, 5}, {:ok, %{cookies: :nope}}, {:weird, :tuple, 3}, nil] do
        {redeem, user} = handoff_with(%{apply: garbage})
        handed_over(redeem, user)
        assert flash(redeem, "info") == signed_in(user)
      end
    end

    test "a module that raises in apply is logged (its kind, not its message) and left out" do
      log =
        capture_log(fn ->
          {redeem, user} = handoff_with(%{apply: {:raise, "apply-secret-value"}})
          handed_over(redeem, user)
          assert flash(redeem, "info") == signed_in(user)
        end)

      assert log =~ "handoff_apply of PhoenixKit.Test.HandoffScriptedModule raised RuntimeError"
      refute log =~ "apply-secret-value"
    end

    test "the other modules' contribution still reaches the visitor" do
      HandoffScriptedModule.script(%{apply: {:raise, "x"}})
      user = user!()

      {[_, _, _, redeem], _} =
        capture_log(fn ->
          send(
            self(),
            {:flow,
             handoff(new_browser(), session: signed_in_session(user) ++ [stub_cart: "cart-1"])}
          )
        end)
        |> then(fn _log ->
          assert_received {:flow, flow}
          flow
        end)

      handed_over(redeem, user)
      assert flash(redeem, "info") == signed_in(user) <> " Your cart came along."
      assert %{value: "cart-1"} = redeem.resp_cookies["stub_cart_id"]
    end
  end

  describe "a module that is switched off" do
    setup do
      :ok = ModuleRegistry.register(HandoffDisabledModule)
      on_exit(fn -> ModuleRegistry.unregister(HandoffDisabledModule) end)
    end

    test "is neither asked for a snapshot at start or mint nor applied at redeem" do
      assert HandoffDisabledModule in ModuleRegistry.all_modules()

      # A guest: start asks the modules whether there is anything to carry.
      {[_, _, _, _redeem], _} = handoff(new_browser(), session: [stub_cart: "cart-1"])

      refute_received :disabled_snapshot_called
      refute_received :disabled_apply_called
      assert [%Token{payload: payload}] = tokens()
      assert Map.keys(payload) == ["handoff_stub"]
    end

    test "is not applied even when a payload names it" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, _token} = minted(session)

      Repo.update_all(Token,
        set: [payload: %{"handoff_disabled" => %{"secret" => "disabled"}}]
      )

      {redeem, _} = follow(browser, mint)
      assert redirected_to(redeem, 302) == "/shop"
      refute_received :disabled_apply_called
      assert flash(redeem, "info") =~ "angemeldet"
      refute flash(redeem, "info") =~ "from a disabled module"
    end
  end

  describe "the age of the session" do
    # A session that is `seconds` old, as the sessions of the pipeline see it.
    defp aged_session(user, seconds) do
      session = signed_in_session(user)
      age(session[:user_token], seconds)
      session
    end

    defp age(token, seconds) do
      at = DateTime.add(DateTime.utc_now(), -seconds, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(t in UserToken, where: t.token == ^token), set: [inserted_at: at])
      at
    end

    # Time passing: every session of the account gets `seconds` older.
    defp pass_time(user, seconds) do
      Repo.update_all(
        from(t in UserToken, where: t.user_uuid == ^user.uuid and t.context == "session"),
        set: [
          inserted_at:
            dynamic([t], fragment("? - make_interval(secs => ?)", t.inserted_at, ^seconds))
        ]
      )
    end

    defp session_row(token), do: Repo.get_by!(UserToken, token: token, context: "session")

    defp may_add_passkey(user, token),
      do: Passkeys.check_may_add(user, impersonated: false, session_token: token)

    setup do
      {:ok, _} = Settings.update_setting("passkey_login_enabled", "true")
      on_exit(fn -> Settings.update_setting("passkey_login_enabled", "false") end)
    end

    test "a session older than the passkey window is just as stale on the target" do
      user = user!()
      minutes = Passkeys.fresh_session_minutes()
      session = aged_session(user, (minutes + 15) * 60)
      source = session[:user_token]
      assert {:error, :stale_session} = may_add_passkey(user, source)

      {[_, _, _, redeem], _} = handoff(new_browser(), session: session)

      target = get_session(redeem, :user_token)
      refute target == source
      assert Auth.get_user_by_session_token(target).uuid == user.uuid
      assert {:error, :stale_session} = may_add_passkey(user, target)
      assert session_row(target).inserted_at == session_row(source).inserted_at
    end

    test "a session younger than the window is still fresh on the target, until the source is not" do
      user = user!()
      # One minute short of the window: fresh now, and stale two minutes on.
      session = aged_session(user, (Passkeys.fresh_session_minutes() - 1) * 60)
      source = session[:user_token]
      assert :ok = may_add_passkey(user, source)

      {[_, _, _, redeem], _} = handoff(new_browser(), session: session)

      target = get_session(redeem, :user_token)
      assert :ok = may_add_passkey(user, target)

      # The window closes for both at once: the target is not "two minutes old", it is as old as
      # the source.
      pass_time(user, 120)
      assert {:error, :stale_session} = may_add_passkey(user, source)
      assert {:error, :stale_session} = may_add_passkey(user, target)
    end

    test "the new session expires when the one it continues would have, not 60 days from now" do
      user = user!()
      almost = 60 * 86_400 - 300
      session = aged_session(user, almost)
      source = session[:user_token]
      assert Auth.get_user_by_session_token(source)

      {[_, _, _, redeem], _} = handoff(new_browser(), session: session)

      target = get_session(redeem, :user_token)
      assert Auth.get_user_by_session_token(target)

      # Ten minutes later the source is over its 60 days: so is the target.
      pass_time(user, 600)
      refute Auth.get_user_by_session_token(source)
      refute Auth.get_user_by_session_token(target)
    end

    test "the account's role in the session carries over" do
      user = user!()
      session = signed_in_session(user)
      role = Ecto.UUID.generate()

      Repo.update_all(from(t in UserToken, where: t.token == ^session[:user_token]),
        set: [active_role_uuid: role]
      )

      {[_, _, _, redeem], _} = handoff(new_browser(), session: session)

      assert session_row(get_session(redeem, :user_token)).active_role_uuid == role
    end

    test "a session revoked after the mint and before the redeem ends the handoff" do
      user = user!()
      session = signed_in_session(user)
      {browser, _prepare, mint, _token} = minted(session)
      assert [%Token{used_at: nil, source_session_uuid: source}] = tokens()
      assert source == session_row(session[:user_token]).uuid

      # Straight at the table, past the revocation hook: the redeem looks the session up itself.
      {1, _} = Repo.delete_all(from(t in UserToken, where: t.token == ^session[:user_token]))
      assert [%Token{used_at: nil}] = tokens()

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      refute get_session(conn, :user_token)
    end

    test "a session revoked while the modules apply their snapshots ends the handoff" do
      :ok = ModuleRegistry.register(HandoffScriptedModule)

      on_exit(fn ->
        ModuleRegistry.unregister(HandoffScriptedModule)
        HandoffScriptedModule.clear()
      end)

      user = user!()
      session = signed_in_session(user)

      # The hook is what runs between the redeem's look-up of the session and the sign-in; the
      # session goes in that window (straight at the table, past the revocation hook).
      HandoffScriptedModule.script(%{
        apply:
          {:run,
           fn ->
             Repo.delete_all(from(t in UserToken, where: t.token == ^session[:user_token]))
           end}
      })

      {[_, _, _, redeem], _} = handoff(new_browser(), session: session)

      assert_refused(redeem)
      refute get_session(redeem, :user_token)
      assert [%Token{used_at: %DateTime{}}] = tokens()

      assert Repo.aggregate(
               from(t in UserToken, where: t.user_uuid == ^user.uuid and t.context == "session"),
               :count
             ) == 0
    end

    test "a guest's handoff has no session to continue and is not affected" do
      {[_, _, _, redeem], _} = handoff(new_browser(), session: [stub_cart: "cart-1"])

      assert flash(redeem, "info") == "Your cart came along."
      assert [%Token{user_uuid: nil, source_session_uuid: nil}] = tokens()
    end

    test "a sign-in of any other kind gets the age of now, and no role" do
      user = user!()

      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> WebAuth.log_in_user(user, %{})

      token = get_session(conn, :user_token)
      assert DateTime.diff(DateTime.utc_now(), session_row(token).inserted_at) in 0..5
      assert is_nil(session_row(token).active_role_uuid)
    end
  end

  describe "revocation" do
    test "a redeem after the account's sessions were all revoked fails" do
      user = user!()
      {browser, _prepare, mint, _token} = minted(signed_in_session(user))
      assert [%Token{used_at: nil}] = tokens()

      Auth.delete_all_user_session_tokens(user)

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      refute get_session(conn, :user_token)
      assert tokens() == []
    end

    test "so does one after a password change" do
      user = user!()
      {browser, _prepare, mint, _token} = minted(signed_in_session(user))

      assert {:ok, _user} =
               Auth.update_user_password(user, "ValidPassword123!", %{
                 password: "AnotherValidPassword456!"
               })

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      refute get_session(conn, :user_token)
    end

    test "so does one after an admin revoked the account's sessions" do
      user = user!()
      {browser, _prepare, mint, _token} = minted(signed_in_session(user))
      {admin, _token} = create_admin_user()

      Sessions.revoke_user_sessions(user, actor: admin)

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      assert tokens() == []
    end

    test "so does one after the one session it was minted from was signed out" do
      user = user!()
      session = signed_in_session(user)
      {browser, _prepare, mint, _token} = minted(session)

      Auth.delete_user_session_token(session[:user_token])

      {conn, _} = follow(browser, mint)
      assert_refused(conn)
    end

    test "another account's handoff, and a guest's, are not touched" do
      user = user!()
      other = user!()
      {_browser, _prepare, _mint, _token} = minted(signed_in_session(user))
      {other_browser, _prepare, other_mint, _token} = minted(signed_in_session(other))
      {guest_browser, _prepare, guest_mint, _token} = minted(stub_cart: "cart-1")

      Auth.delete_all_user_session_tokens(user)

      assert length(tokens()) == 2
      {redeem, _} = follow(other_browser, other_mint)
      assert get_session(redeem, :user_token)
      {redeem, _} = follow(guest_browser, guest_mint)
      assert flash(redeem, "info") == "Your cart came along."
    end
  end

  describe "an http site" do
    # With the settings cache running, settings are read from it alone: the languages go in too.
    setup do
      LanguageSettings.multilingual!(languages: ["en-US", "de-DE", "fr-FR"])
      Cache.put(:settings, "site_url", "http://shop.test")
      :ok
    end

    test "gets http redirects, and plain cookie names without Secure, end to end" do
      user = user!()

      {[start, prepare, mint, redeem], _} =
        handoff(new_browser(), session: signed_in_session(user), scheme: "http")

      assert %{scheme: "http", host: @target} = location(start)
      assert %{scheme: "http", host: @source} = location(prepare)
      assert %{scheme: "http", host: @target} = location(mint)

      assert_cookie(start, "pk_handoff_src", secure: false, http_only: true, same_site: "Lax")
      assert_cookie(prepare, "pk_handoff_nonce", secure: false, http_only: true, same_site: "Lax")
      refute Map.has_key?(start.resp_cookies, @start_cookie)
      refute Map.has_key?(prepare.resp_cookies, @nonce_cookie)

      assert redirected_to(redeem, 302) == "/shop"
      assert get_session(redeem, :user_token)
      assert_deleted(redeem, "pk_handoff_nonce")
    end

    test "a visitor with nothing to carry is sent on over http" do
      {start, _} =
        visit(new_browser(), @source, Handoff.start_path("de", "/shop"), scheme: "http")

      assert redirected_to(start, 302) == "http://#{@target}/shop"
    end
  end

  describe "an https site" do
    test "never falls back to plain cookie names, whatever the connection says" do
      user = user!()

      # A proxy that terminates TLS may hand the app an http conn; the scheme of the cookies is
      # the site's (`site_url`, https by default), not the conn's.
      {[start, prepare, _mint, _redeem], _} =
        handoff(new_browser(), session: signed_in_session(user), scheme: "http")

      assert %{scheme: "https"} = location(start)
      assert %{secure: true} = start.resp_cookies[@start_cookie]
      assert %{secure: true} = prepare.resp_cookies[@nonce_cookie]
      refute Map.has_key?(start.resp_cookies, "pk_handoff_src")
    end
  end

  describe "the host resolver" do
    defp asked do
      receive do
        {:resolver_asked, language} -> [language | asked()]
      after
        0 -> []
      end
    end

    test "is asked once per language by a redeem, a prepare and a mint, not once per use" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, _token} = minted(session)
      _ = asked()

      {_redeem, _} = follow(browser, mint)
      redeem_asked = asked()

      {_prepare, _} =
        visit(new_browser(), @target, "#{@prefix}/prepare?return=#{@source}&to=%2F&s=#{proof()}")

      prepare_asked = asked()

      for questions <- [redeem_asked, prepare_asked] do
        assert questions != []

        assert Enum.all?(Enum.frequencies(questions), fn {_language, times} -> times == 1 end),
               inspect(Enum.frequencies(questions))
      end
    end
  end

  describe "the host resolver and cheap inputs" do
    test "a prepare or a mint that fails on the shape of its parameters never asks the resolver" do
      session = signed_in_session(user!())
      good_n = Handoff.nonce_hash_param(Handoff.new_secret())
      _ = asked()

      bad_prepares = [
        "return=#{@source}&to=%2Fshop&s=short",
        "return=#{@source}&to=%2Fshop",
        "return=#{@source}&to=https%3A%2F%2Fevil.test&s=#{proof()}",
        "to=%2Fshop&s=#{proof()}",
        "return=#{String.duplicate("a", 300)}&to=%2Fshop&s=#{proof()}"
      ]

      for query <- bad_prepares do
        {conn, _} = visit(new_browser(), @target, "#{@prefix}/prepare?" <> query)
        assert_refused(conn)
      end

      bad_mints = [
        "n=short&h=#{@target}&to=%2Fshop&s=#{proof()}",
        "n=#{good_n}&h=#{@target}&to=%2Fshop&s=short",
        "n=#{good_n}&h=#{@target}&to=%2F%2Fevil.test&s=#{proof()}",
        "n=#{good_n}&to=%2Fshop&s=#{proof()}",
        "n=#{good_n}&h=#{String.duplicate("a", 300)}&to=%2Fshop&s=#{proof()}",
        "n=#{good_n}&h=#{@target}&to=%2Fshop"
      ]

      for query <- bad_mints do
        {conn, _} = visit(new_browser(), @source, "#{@prefix}/mint?" <> query, session: session)
        assert_refused(conn)
      end

      assert asked() == []
    end

    test "a mint with no source cookie, or one that is not the application's, never asks it either" do
      session = signed_in_session(user!())
      n = Handoff.nonce_hash_param(Handoff.new_secret())
      _ = asked()

      {conn, _} = visit(new_browser(), @source, mint_path(n, proof()), session: session)
      assert_refused(conn)

      {conn, _} =
        visit(new_browser(), @source, mint_path(n, proof()),
          session: session,
          cookies: [{@start_cookie, Handoff.new_secret()}]
        )

      assert_refused(conn)
      assert asked() == []
    end

    test "a redeem of something that is not a token never asks it, and a start with a bad language neither" do
      _ = asked()

      {conn, _} = visit(new_browser(), @target, "#{@prefix}/not-a-token")
      assert_refused(conn)

      {conn, _} = visit(new_browser(), @source, "#{@prefix}/start?lang=../x")
      assert_refused(conn)

      assert asked() == []
    end
  end

  describe "the log" do
    test "carries the token of a full handoff in no line: not the request line, not the timer's" do
      RequestLog.install()
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      user = user!()

      {token, log} =
        with_log([level: :debug], fn ->
          {[_, _, mint, redeem], _} = handoff(new_browser(), session: signed_in_session(user))
          assert redirected_to(redeem, 302) == "/shop"
          location(mint).path |> String.split("/") |> List.last()
        end)

      assert Handoff.secret?(token)

      # The controls: the endpoint wrote a request line for the other steps, readable, so the
      # redeem line is missing its token because it was filtered, not because nothing was captured.
      assert log =~ "[info] GET #{@prefix}/prepare"
      assert log =~ "[info] GET #{@prefix}/[FILTERED]"
      assert log =~ "[RequestTimer] END GET #{@prefix}/[FILTERED]"
      assert log =~ "[RequestTimer] START GET #{@prefix}/[FILTERED]"
      refute log =~ token
    end
  end

  describe "the log, for every spelling of the redeem path" do
    # Spellings the router accepts as `redeem` (it drops empty segments and decodes the token's
    # percent-escapes): the token must reach no line of the log in any of them.
    defp spellings(token) do
      encoded = "%" <> Base.encode16(binary_part(token, 0, 1)) <> binary_part(token, 1, 42)

      for path <- [
            "#{@prefix}/#{token}",
            "#{@prefix}//#{token}",
            "#{@prefix}////#{token}",
            "#{@prefix}/#{token}/",
            "#{@prefix}/#{token}//",
            "#{@prefix}//#{token}//",
            "/phoenix_kit//handoff/#{token}",
            "//phoenix_kit/handoff//#{token}",
            "#{@prefix}/#{encoded}",
            "#{@prefix}//#{encoded}/"
          ],
          do: {path, if(String.contains?(path, "%"), do: encoded, else: token)}
    end

    test "the router takes each of them for a redeem, and the request line, the timer and redact/1 hide it" do
      RequestLog.install()
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      # Every token below has the shape of a real one and is unknown: a failed redeem is logged
      # the same as a good one, and burns nothing.
      for _ <- 1..3 do
        token = Handoff.new_secret()

        for {path, shown} <- spellings(token) do
          assert %{plug_opts: :redeem} =
                   Phoenix.Router.route_info(PhoenixKitWeb.Router, "GET", path, @target)

          refute RequestLog.redact(path) =~ shown
          refute RequestLog.redact(path) =~ token

          {_conn, log} =
            with_log([level: :debug], fn ->
              visit(new_browser(), @target, path)
            end)

          assert log =~ "[FILTERED]", "no request line was captured for #{path}"
          refute log =~ shown, "#{path} reached the log"
          refute log =~ token, "#{path} reached the log, decoded"
        end
      end
    end
  end

  describe "routes" do
    test "the endpoints have one address, whatever the language" do
      for locale <- ["en", "de", "fr"] do
        assert Routes.path("/handoff/start", locale: locale) == "#{@prefix}/start"
        assert Routes.path("/handoff/abc", locale: locale) == "#{@prefix}/abc"
      end
    end

    test "they stay out of the sitemap" do
      routes =
        for %{path: path, metadata: metadata} <- Phoenix.Router.routes(PhoenixKitWeb.Router),
            String.starts_with?(path, @prefix),
            do: {path, metadata}

      assert length(routes) == 4
      assert Enum.all?(routes, fn {_path, metadata} -> metadata[:sitemap] == false end)
    end
  end

  ## Sessions for the refusal tests

  defp impersonation_session do
    {:ok, _} = Settings.update_boolean_setting("multi_session_enabled", true)
    {_admin, token} = create_admin_user()
    {[user_token: token, pk_session_accounts: [token]], user!()}
  end

  defp impersonate(browser, session, target) do
    {conn, browser} =
      visit(browser, @source, Routes.path("/users/session/impersonate/#{target.uuid}"),
        method: "POST",
        session: session
      )

    assert MultiSession.impersonated?(get_session(conn))
    browser
  end
end
