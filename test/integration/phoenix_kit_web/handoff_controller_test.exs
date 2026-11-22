defmodule PhoenixKitWeb.HandoffControllerTest do
  @moduledoc """
  The cross-domain handoff through the real router, with two browsers' worth of cookies carried
  by hand between the four requests (`visit/4` is a browser: one cookie jar per host).

  `async: false`: the tests set the host resolver and the languages, and register stub modules in
  the module registry.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Handoff
  alias PhoenixKit.Handoff.Token
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.HandoffFailingModule
  alias PhoenixKit.Test.HandoffResolver
  alias PhoenixKit.Test.HandoffStubModule
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RateLimiter
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

  defp new_browser do
    n = System.unique_integer([:positive])
    %{peer: {10, 8, rem(n, 250), 1 + rem(div(n, 250), 250)}, jars: %{}}
  end

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

    conn =
      browser.jars
      |> Map.get(host, %{})
      |> Enum.reduce(conn, fn {name, value}, acc -> put_req_cookie(acc, name, value) end)

    conn = Phoenix.ConnTest.dispatch(conn, @endpoint, method, "https://#{host}#{path}")
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
    visit(browser, uri.host, uri.path <> if(uri.query, do: "?" <> uri.query, else: ""), opts)
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
  defp handoff(browser, opts \\ []) do
    source_opts = Keyword.take(opts, [:session, :headers])
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

      assert Handoff.secret?(start.resp_cookies[@start_cookie].value)

      assert %{scheme: "https", host: @target, path: @prefix <> "/prepare", query: query} =
               location(start)

      assert query == %{"return" => @source, "to" => "/shop"}

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
               "to" => "/shop"
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

  describe "prepare" do
    test "refuses a return host that is not on the allow-list, the same host, and a bad target" do
      to = "%2Fshop"

      for query <- [
            "return=evil.test&to=#{to}",
            "return=#{@target}&to=#{to}",
            "return=#{@source}&to=//evil.test",
            "return=#{@source}",
            "to=#{to}",
            "return=https%3A%2F%2F#{@source}&to=#{to}",
            "return=#{@source}:99&to=#{to}"
          ] do
        {conn, _} = visit(new_browser(), @target, "#{@prefix}/prepare?" <> query)
        assert_refused(conn)
        refute Map.has_key?(conn.resp_cookies, @nonce_cookie)
      end
    end

    test "gives a browser that holds a nonce the same one again" do
      browser = new_browser()
      path = "#{@prefix}/prepare?return=#{@source}&to=%2Fshop"

      {first, browser} = visit(browser, @target, path)
      {second, _} = visit(browser, @target, path)

      assert location(first).query["n"] == location(second).query["n"]
      assert first.resp_cookies[@nonce_cookie].value == second.resp_cookies[@nonce_cookie].value
    end

    test "ignores a nonce cookie that is not well-formed" do
      {conn, _} =
        visit(new_browser(), @target, "#{@prefix}/prepare?return=#{@source}&to=%2F",
          headers: [{"cookie", "#{@nonce_cookie}=short"}]
        )

      assert Handoff.secret?(conn.resp_cookies[@nonce_cookie].value)
    end
  end

  describe "mint" do
    defp prepared(browser) do
      {prepare, browser} =
        visit(browser, @target, "#{@prefix}/prepare?return=#{@source}&to=%2Fshop")

      {location(prepare).query["n"], browser}
    end

    defp mint_path(n, h \\ @target, to \\ "/shop"),
      do: "#{@prefix}/mint?" <> URI.encode_query(n: n, h: h, to: to)

    defp started(browser, session) do
      {start, browser} =
        visit(browser, @source, Handoff.start_path("de", "/shop"), session: session)

      assert Map.has_key?(start.resp_cookies, @start_cookie)
      browser
    end

    test "is refused for a browser that never clicked start, and writes nothing" do
      session = signed_in_session(user!())
      {n, _} = prepared(new_browser())

      {conn, _} = visit(new_browser(), @source, mint_path(n), session: session)
      assert_refused(conn)
      assert tokens() == []
    end

    test "needs the source cookie, which is good for one attempt" do
      session = signed_in_session(user!())
      browser = started(new_browser(), session)
      {n, browser} = prepared(browser)

      {first, browser} = visit(browser, @source, mint_path(n))
      assert %{host: @target} = location(first)
      assert_deleted(first, @start_cookie)
      assert length(tokens()) == 1

      {second, _} = visit(browser, @source, mint_path(n))
      assert_refused(second)
      assert length(tokens()) == 1
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
        browser = started(new_browser(), session)
        {conn, _} = visit(browser, @source, mint_path(n))
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
        browser = started(new_browser(), session)
        {n, browser} = prepared(browser)
        {conn, _} = visit(browser, @source, mint_path(n, h, to))
        assert_refused(conn)
      end

      assert tokens() == []
    end

    test "is refused on a host that is no domain of the site" do
      session = signed_in_session(user!())
      {n, _} = prepared(new_browser())

      {conn, _} =
        visit(new_browser(), "www.example.com", mint_path(n),
          session: session,
          headers: [{"cookie", "#{@start_cookie}=#{Handoff.new_secret()}"}]
        )

      assert_refused(conn)
      assert tokens() == []
    end

    test "is refused for an impersonated session" do
      {admin_session, target} = impersonation_session()
      browser = started(new_browser(), admin_session)
      {n, browser} = prepared(browser)
      browser = impersonate(browser, [], target)

      {conn, _} = visit(browser, @source, mint_path(n))
      assert_refused(conn, carried_flash: true)
      assert tokens() == []
    end

    test "carries no account for one that has been deactivated, only what the modules hold" do
      user = user!()
      session = signed_in_session(user) ++ [stub_cart: "cart-1"]
      browser = started(new_browser(), session)
      {n, browser} = prepared(browser)

      Repo.update_all(from(u in Auth.User, where: u.uuid == ^user.uuid), set: [is_active: false])

      {conn, _} = visit(browser, @source, mint_path(n))
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

    test "another browser does not get in, and does not burn the token" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, token} = minted(session)

      # A browser that never prepared, and one that did, for itself.
      {nobody, _} = visit(new_browser(), @target, "#{@prefix}/#{token}")
      assert_refused(nobody)

      {_n, intruder} = prepared(new_browser())
      {wrong_nonce, _} = visit(intruder, @target, "#{@prefix}/#{token}")
      assert_refused(wrong_nonce)
      assert_deleted(wrong_nonce, @nonce_cookie)

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
    test "is a redirect to / with no message and no handoff cookie but a deleted one, at every step" do
      failures = [
        elem(visit(new_browser(), @source, "#{@prefix}/start?lang=xx"), 0),
        elem(visit(new_browser(), @target, "#{@prefix}/prepare?return=evil.test&to=%2F"), 0),
        elem(visit(new_browser(), @source, "#{@prefix}/mint?n=abc&h=#{@target}&to=%2F"), 0),
        elem(visit(new_browser(), @target, "#{@prefix}/#{Handoff.new_secret()}"), 0)
      ]

      for conn <- failures do
        assert_refused(conn)
        assert conn.status == 302

        assert Enum.all?(handoff_cookies(conn), &(conn.resp_cookies[&1].max_age == 0))
      end
    end

    test "is limited per address before anything is looked up" do
      session = signed_in_session(user!())
      {browser, _prepare, mint, _token} = minted(session)
      limit = Keyword.fetch!(RateLimiter.get_config(), :handoff_limit)

      # The browser has spent 3 of its requests on the flow; the rest go to nothing.
      for _ <- 1..limit do
        {conn, _} = visit(browser, @source, "#{@prefix}/start?lang=xx")
        assert redirected_to(conn, 302) == "/"
      end

      # Refused with a valid link and the right browser, and the link is not spent.
      {conn, _} = follow(browser, mint)
      assert_refused(conn)
      assert [%Token{used_at: nil}] = tokens()

      # Another address is not affected.
      {other, _} = visit(new_browser(), @source, Handoff.start_path("de"))
      assert redirected_to(other, 302) == "https://#{@target}/"
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

  defp admin_session do
    {admin, token} = create_admin_user()
    _ = admin
    [user_token: token, pk_session_accounts: [token]]
  end

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
