defmodule PhoenixKitWeb.HandoffController do
  @moduledoc """
  The four endpoints of the cross-domain handoff (`PhoenixKit.Handoff` has the story):

    * `GET <prefix>/handoff/start?lang=&to=` on the source domain
    * `GET <prefix>/handoff/prepare?return=&to=` on the target domain
    * `GET <prefix>/handoff/mint?n=&h=&to=` on the source domain
    * `GET <prefix>/handoff/:token` on the target domain

  None of them needs a login (the session decides what is carried), all four answer
  `Cache-Control: no-store` and are `log: false` routes: the token is a capability. A handoff is
  counted once against the rate limit, where it starts (`start`, per address, before anything is
  looked up); a `redeem` counts only when it fails, and a `mint` per address and per source
  proof, and also per account when there is one.

  ## Failure

  Anything that goes wrong, at any step, is a `302` to `/` of the current host. No page, no
  message, and nothing that tells a used token from an unknown one or a refused host from a refused
  parameter. A refusal leaves the visitor's handoff cookies as they were, with one exception: a
  `mint` whose proof matched the source cookie has spent it, whatever it was refused for after
  that (see "Redirects and cookies").

  ## Who may start one, and what may load the others

  `start` is the one step a page can aim a visitor at, so it refuses a request that is not a
  top-level navigation of the host's own or of the visitor's (`Sec-Fetch-Site` `cross-site` or
  `same-site`, that is another site or a sibling subdomain; or a `Sec-Fetch-Dest` other than
  `document`: an image, a frame, a script): a `302` to `/`, before the rate limit takes a slot, with
  no side effect. `prepare`, `mint` and `redeem` are reached by cross-site redirects by design, so
  their site is not checked, but a `Sec-Fetch-Dest` that is not `document` is refused the same way
  (a cross-site `<img>` of a redeem URL must not spend the visitor's failed-redeem budget). A
  request that sends no fetch metadata (an old browser, a proxy that strips it) is let through
  everywhere: see `fetch_allowed?/2`.

  ## Requests with no side effects

  A request that says it is a prefetch or a preview (`Sec-Purpose` or `Purpose` naming `prefetch`,
  `prerender` or `preview`) and a `HEAD` request are answered `204` and change nothing: a browser
  that warms a link, or a link-preview robot, must not burn a token or set a cookie. `HEAD` is
  recognised even when `Plug.Head` ahead of the router has already turned it into a `GET` (the
  server's adapter still holds the method it received: Bandit, Cowboy and the test adapter all keep
  it under `:method`); an adapter that does not is treated as a `GET`.

  ## Redirects and cookies

  A redirect to another domain names a host taken from `PhoenixKit.Handoff.allowed_hosts/0`, never
  a header or a parameter as given, and its scheme is `PhoenixKit.Handoff.scheme/0`: `https`,
  unless the `site_url` setting says `http` (a dev or staging site). The two handoff cookies are
  `__Host-` cookies (`Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`) on `https`, and on `http` only
  the same cookies without the prefix and without `Secure`, which the prefix would forbid.

  The source cookie is **signed** (`Plug.Conn.put_resp_cookie/4` with `sign: true`, with the
  application's `secret_key_base`; it is issued and verified on the same host) and lives 60
  seconds: `mint` accepts only a cookie the application itself issued. `start` also sends the
  SHA-256 of its secret through `prepare` to `mint` (`s`), which compares it with its own cookie: a
  `mint` request must belong to a `start` made in the same browser.

  The source cookie is deleted by the response to a `mint` whose proof matched it, and the nonce
  cookie by a `redeem` that went through, never by a request refused before that: a page of another
  site can make the visitor's browser request a `mint` or a token, and must not be able to take the
  cookies of the visitor's own handoff. The deletion is only a `Set-Cookie`, which a client that is
  not a browser ignores, so the proof is single use on the server: the row stores it under a
  unique index (`PhoenixKit.Handoff.mint/1`), which holds across nodes, and a budget of one mint
  per proof (per node) and one per address (guests too) sit in front of it to save work.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Handoff
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitWeb.Users.Auth, as: WebAuth

  require Logger

  # `__Host-` (on https): https only, no `Domain`, `Path=/`: the browser refuses it from anything
  # else, a sibling subdomain included. `secure:` is added per request (`cookie_options/1`).
  @cookie_options [http_only: true, same_site: "Lax", path: "/"]
  @cookie_max_age 60
  @language_pattern ~r/\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*\z/
  @side_effect_free_purposes ~w(prefetch prerender preview)
  # Links to `start` are always the host's own page (same-origin) or typed/bookmarked (none): a
  # sibling subdomain, which `same-site` also names, is not.
  @navigation_fetch_sites ~w(same-origin none)

  @doc "Step 1, on the source domain."
  def start(conn, params), do: guarded(conn, :start, &do_start(&1, params))

  @doc "Step 2, on the target domain."
  def prepare(conn, params), do: guarded(conn, :prepare, &do_prepare(&1, params))

  @doc "Step 3, on the source domain."
  def mint(conn, params), do: guarded(conn, :mint, &do_mint(&1, params))

  @doc "Step 4, on the target domain."
  def redeem(conn, %{"token" => token}), do: guarded(conn, :redeem, &do_redeem(&1, token))

  ## Step 1

  defp do_start(conn, params) do
    with lang when is_binary(lang) <- language(params["lang"]),
         conn = resolve_site(conn),
         canonical when is_binary(canonical) <- Routes.canonical_host(lang),
         target when is_binary(target) <- Handoff.allowed_host(canonical, site(conn).hosts),
         source when is_binary(source) <- Handoff.own_host(conn.host, site(conn).hosts),
         false <- same_host?(target, source) do
      to = Handoff.valid_to(params["to"]) || "/"
      conn = WebAuth.fetch_phoenix_kit_current_scope(conn, [])
      begin_handoff(conn, source, target, to)
    else
      _ -> fail(conn)
    end
  end

  # Nothing to carry (no signed-in account, no module with a snapshot) or nothing that may be
  # carried (an impersonated session): a plain redirect, no cookie, no row.
  defp begin_handoff(conn, source, target, to) do
    carried? =
      case Handoff.carried_user(conn.assigns[:phoenix_kit_current_scope]) do
        {:ok, %User{}} -> true
        {:ok, nil} -> Handoff.snapshots(hook_context(conn, nil)) != %{}
        :refused -> false
      end

    if carried? do
      secret = Handoff.new_secret()

      conn
      |> put_source_cookie(secret)
      |> redirect(
        external:
          external_url(conn, target, "/handoff/prepare",
            return: source,
            to: to,
            s: Handoff.source_proof_param(secret)
          )
      )
    else
      redirect(conn, external: scheme(conn) <> "://" <> target <> to)
    end
  end

  ## Step 2

  # The shape of the parameters is checked first, and only then is the host resolver asked (it
  # costs one question per enabled language, and this step is not limited).
  defp do_prepare(conn, params) do
    with true <- Handoff.secret?(params["s"]),
         to when is_binary(to) <- Handoff.valid_to(params["to"]),
         return when is_binary(return) <- Handoff.host_param(params["return"]),
         conn = resolve_site(conn),
         return when is_binary(return) <- Handoff.allowed_host(return, site(conn).hosts),
         own when is_binary(own) <- Handoff.own_host(conn.host, site(conn).hosts),
         false <- same_host?(return, own) do
      name = Handoff.nonce_cookie(scheme(conn))
      nonce = existing_secret(conn, name) || Handoff.new_secret()

      conn
      |> put_handoff_cookie(name, nonce)
      |> redirect(
        external:
          external_url(conn, return, "/handoff/mint",
            n: Handoff.nonce_hash_param(nonce),
            h: own,
            to: to,
            s: params["s"]
          )
      )
    else
      _ -> fail(conn)
    end
  end

  ## Step 3

  # Cheap checks first (the cookie, the proof, the shape of every parameter), then the budgets,
  # then ONE indexed question to the database (is the proof already spent?), then the host
  # resolver, the session and the snapshots. A request that fails a cheap check asks nothing and
  # costs nobody a slot, and a replay of a spent proof, on any node and whatever the budgets
  # remember, costs no resolver round and no snapshot round.
  defp do_mint(conn, params) do
    name = Handoff.source_cookie(scheme(conn))

    # The cookie is read as a SIGNED cookie: only one this application issued (and not older than
    # 60 seconds) counts. It is deleted once the proof in the request has matched it, and not
    # before: a page of another site can make the visitor's browser request a mint, and a request
    # that does not carry the visitor's own proof must not take their cookie. The deletion is only
    # a `Set-Cookie`, which a client that is not a browser ignores: the proof is made single use
    # on the server (the proof's budget below, and `source_proof_hash` of the row).
    secret = signed_secret(conn, name)

    if Handoff.source_proof?(secret, params["s"]) do
      conn |> delete_handoff_cookie(name) |> mint_with_proof(params)
    else
      fail(conn)
    end
  end

  defp mint_with_proof(conn, params) do
    with {:ok, proof_hash} <- Handoff.decode_source_proof(params["s"]),
         {:ok, nonce_hash} <- Handoff.decode_nonce_hash(params["n"]),
         to when is_binary(to) <- Handoff.valid_to(params["to"]),
         host when is_binary(host) <- Handoff.host_param(params["h"]),
         :ok <- RateLimiter.check_handoff_mint_proof_rate_limit(params["s"]),
         :ok <- RateLimiter.check_handoff_mint_ip_rate_limit(IpAddress.extract_from_conn(conn)),
         false <- Handoff.source_proof_used?(proof_hash),
         conn = resolve_site(conn),
         target when is_binary(target) <- Handoff.allowed_host(host, site(conn).hosts),
         source when is_binary(source) <- Handoff.own_host(conn.host, site(conn).hosts),
         false <- same_host?(target, source),
         conn = WebAuth.fetch_phoenix_kit_current_scope(conn, []),
         {:ok, user} <- Handoff.carried_user(conn.assigns[:phoenix_kit_current_scope]),
         {:ok, source_session} <- source_session(conn, user),
         :ok <- mint_rate_limit(user),
         user_uuid = user && user.uuid,
         {:ok, token} <-
           Handoff.mint(%{
             target_host: target,
             redirect_path: to,
             user_uuid: user_uuid,
             source_session_uuid: source_session,
             payload: Handoff.snapshots(hook_context(conn, user_uuid)),
             browser_nonce_hash: nonce_hash,
             source_proof_hash: proof_hash,
             user_agent: user_agent(conn)
           }) do
      redirect(conn, external: external_url(conn, target, "/handoff/" <> token, []))
    else
      _ -> fail(conn)
    end
  end

  # The session the account is signed in with, which the redeem will look up again: its row's
  # uuid. A guest has none. An account whose session cannot be found (it went between the
  # pipeline and here) is not carried.
  defp source_session(_conn, nil), do: {:ok, nil}

  defp source_session(conn, %User{uuid: uuid}) do
    with token when is_binary(token) <- get_session(conn, :user_token),
         %{uuid: session, user_uuid: ^uuid} <- Auth.get_session_token_record(token) do
      {:ok, session}
    else
      _ -> :error
    end
  end

  # The address's budget is taken before this (for a guest too); an account has its own on top.
  defp mint_rate_limit(nil), do: :ok
  defp mint_rate_limit(%User{uuid: uuid}), do: RateLimiter.check_handoff_mint_rate_limit(uuid)

  ## Step 4

  # The host resolver is asked only once the token is spent: redeeming needs no host list.
  defp do_redeem(conn, token) do
    name = Handoff.nonce_cookie(scheme(conn))
    nonce = existing_secret(conn, name)

    with {:ok, row} <- Handoff.redeem(token, conn.host, nonce, user_agent: user_agent(conn)),
         :ok <- RateLimiter.release_handoff_redeem_slot(IpAddress.extract_from_conn(conn)),
         to when is_binary(to) <- Handoff.valid_to(row.redirect_path),
         {:ok, user} <- load_user(row.user_uuid) do
      # The nonce cookie is deleted by a redeem that went through, and by nothing else: a page of
      # another site can make the visitor's browser request any token, and a refused request must
      # not take the nonce their own handoff needs.
      conn = conn |> delete_handoff_cookie(name) |> resolve_site()
      locale = Handoff.language_for_host(conn.host, site(conn).languages)
      session_cookies = session_cookie_names(conn)

      effects =
        conn
        |> hook_context(row.user_uuid)
        |> Map.merge(%{host: conn.host, locale: locale})
        |> Handoff.apply_payload(row.payload || %{}, nil,
          scheme: scheme(conn),
          session_cookies: session_cookies
        )

      conn
      |> put_module_effects(user, effects, locale)
      |> land(user, to, row.source_session)
    else
      _ -> fail(conn)
    end
  end

  defp load_user(nil), do: {:ok, nil}

  defp load_user(uuid) do
    case Auth.get_user(uuid) do
      %User{} = user -> if Auth.may_sign_in?(user), do: {:ok, user}, else: :error
      nil -> :error
    end
  end

  # What the modules answered is validated and capped by `Handoff.apply_payload/4`; this is the
  # last net. Whatever goes wrong putting it on the response, the visitor is handed over without
  # it (`conn` here is still the one without any of it).
  defp put_module_effects(conn, user, effects, locale) do
    conn
    |> put_module_cookies(effects.cookies)
    |> put_flash_line(user, effects.notices, locale)
  rescue
    error ->
      Logger.error(
        "[Handoff] the cookies and notices of the modules could not be set: " <>
          inspect(error.__struct__)
      )

      put_flash_line(conn, user, [], locale)
  end

  # The normal log-in path: every check, the session renewal, the login alert and the
  # live-socket id apply, and an account already signed in on this browser is replaced.
  # No `remember_me`, so no persistent cookie.
  #
  # `localize: false`: the destination was chosen for the host it lands on, so the person's saved
  # language does not turn `/x` into `/<saved>/x` there.
  #
  # `inherit_session`: this is the same sign-in continued, so the new session has the source
  # session's age (`PhoenixKit.Handoff`, "The session it continues").
  defp land(conn, nil, to, _source_session), do: redirect(conn, to: to)

  defp land(conn, user, to, source_session) do
    WebAuth.log_in_user(conn, user, %{"return_to" => to},
      localize: false,
      inherit_session: source_session
    )
  end

  defp put_flash_line(conn, user, notices, locale) do
    line =
      [signed_in_line(user, locale) | notices]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    if line == "", do: conn, else: put_flash(conn, :info, line)
  end

  defp signed_in_line(nil, _locale), do: nil

  defp signed_in_line(%User{} = user, locale) do
    in_locale(locale, fn ->
      gettext("You are signed in as %{email}.", email: User.delivery_email(user))
    end)
  end

  defp in_locale(nil, fun), do: fun.()

  defp in_locale(code, fun) do
    base = DialectMapper.extract_base(code)
    Gettext.with_locale(PhoenixKitWeb.Gettext, base, fun)
  end

  ## Shared

  # What the hooks are handed (see `PhoenixKit.Module.handoff_snapshot/1`): the session and the
  # cookies of the request with the kit's own auth material removed.
  defp hook_context(conn, user_uuid) do
    conn = fetch_cookies(conn)

    Handoff.hook_context(user_uuid, get_session(conn), conn.req_cookies,
      session_cookies: session_cookie_names(conn)
    )
  end

  defp session_cookie_names(conn),
    do: conn |> Phoenix.Controller.endpoint_module() |> Handoff.session_cookie_names()

  # The scheme is a cheap read, set on every request; the hosts and the languages cost one
  # question of the host resolver per enabled language, so a request asks (`resolve_site/1`) only
  # when it got past the checks that need no host, and once.
  defp scheme(conn), do: conn.private.handoff_scheme

  defp resolve_site(conn), do: put_private(conn, :handoff_site, Handoff.resolve())

  defp site(conn), do: conn.private.handoff_site

  defp guarded(conn, step, fun) do
    conn = secure(conn)

    cond do
      side_effect_free?(conn) -> send_resp(conn, 204, "")
      not fetch_allowed?(conn, step) -> fail(conn)
      true -> limited(conn, step, fun)
    end
  end

  # A handoff is counted once, where it starts. `prepare` writes nothing; `mint` needs a source
  # cookie only a counted `start` sets (and is limited per account on top); a `redeem` counts only
  # when it fails (`do_redeem/2` hands the slot back on success).
  defp limited(conn, :start, fun) do
    case RateLimiter.check_handoff_start_rate_limit(IpAddress.extract_from_conn(conn)) do
      :ok -> run(conn, fun)
      {:error, _} -> fail(conn)
    end
  end

  defp limited(conn, :redeem, fun) do
    case RateLimiter.check_handoff_redeem_rate_limit(IpAddress.extract_from_conn(conn)) do
      :ok -> run(conn, fun)
      {:error, _} -> fail(conn)
    end
  end

  defp limited(conn, _step, fun), do: run(conn, fun)

  defp run(conn, fun), do: conn |> put_private(:handoff_scheme, Handoff.scheme()) |> fun.()

  defp fail(conn), do: redirect(secure(conn), to: "/")

  defp secure(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end

  defp side_effect_free?(conn), do: head?(conn) or purpose_request?(conn)

  # Fetch metadata, checked BEFORE the rate limit and before anything is read or written: a
  # refusal has no side effect and takes no slot, so a page that loads one of these URLs as an
  # image or a frame cannot spend the visitor's (or their NAT's) budget, set or delete a cookie, or
  # reach a database.
  #
  # `start` is the one step a page of another site can aim a visitor at (a link, a form, a frame,
  # an image, a redirect), and it completes a chain that signs the visitor in as the source
  # account, replacing whoever is signed in on the target. It must be a top-level navigation the
  # visitor made themselves or a page of the host itself made for them: `Sec-Fetch-Site` is
  # `same-origin` or `none` (typed, bookmarked), or absent (a browser that does not send fetch
  # metadata: it cannot be told, and is let through), and `Sec-Fetch-Dest`, when sent, is
  # `document`. `same-site` is refused: it is a sibling subdomain (a dangling one, one a tenant
  # controls), and links to `start` are always the host's own. Anything else, an unknown value
  # included, is refused.
  #
  # `prepare`, `mint` and `redeem` are reached by REDIRECTS from another of the site's domains, for
  # which the browser reports `Sec-Fetch-Site: cross-site`, by design: the site is not checked, or
  # every handoff would be refused. Only what is loaded is: `Sec-Fetch-Dest`, when sent, must be
  # `document`, so a cross-site `<img src=".../handoff/<token>">` or a frame costs nobody a failed
  # redeem. They are protected, beyond that, by what they need: a cookie only an earlier step of
  # the same browser sets, a proof, a nonce.
  defp fetch_allowed?(conn, :start),
    do:
      fetch_header_values(conn, "sec-fetch-site") |> Enum.all?(&(&1 in @navigation_fetch_sites)) and
        document?(conn)

  defp fetch_allowed?(conn, _step), do: document?(conn)

  defp document?(conn),
    do: fetch_header_values(conn, "sec-fetch-dest") |> Enum.all?(&(&1 == "document"))

  defp fetch_header_values(conn, header) do
    conn |> get_req_header(header) |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  defp head?(%Plug.Conn{method: "HEAD"}), do: true
  defp head?(%Plug.Conn{adapter: {_adapter, %{method: "HEAD"}}}), do: true
  defp head?(_conn), do: false

  defp purpose_request?(conn) do
    Enum.any?(["sec-purpose", "purpose"], fn header ->
      conn
      |> get_req_header(header)
      |> Enum.flat_map(&String.split(String.downcase(&1), [";", ",", " "], trim: true))
      |> Enum.any?(&(&1 in @side_effect_free_purposes))
    end)
  end

  defp language(lang) when is_binary(lang) and byte_size(lang) <= 35 do
    if Regex.match?(@language_pattern, lang), do: lang
  end

  defp language(_lang), do: nil

  defp same_host?(a, b), do: Handoff.host_name(a) == Handoff.host_name(b)

  defp external_url(conn, host, path, query) do
    base = scheme(conn) <> "://" <> host <> Routes.path(path)
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  defp user_agent(conn), do: conn |> get_req_header("user-agent") |> List.first()

  defp existing_secret(conn, name) do
    value = conn |> fetch_cookies() |> Map.get(:req_cookies) |> Map.get(name)
    if Handoff.secret?(value), do: value
  end

  # The value of a signed cookie this application issued, when it is the shape of a secret.
  defp signed_secret(conn, name) do
    value = conn |> fetch_cookies(signed: [name]) |> Map.get(:cookies) |> Map.get(name)
    if Handoff.secret?(value), do: value
  end

  defp cookie_options(conn), do: [{:secure, scheme(conn) == "https"} | @cookie_options]

  defp put_handoff_cookie(conn, name, value),
    do: put_resp_cookie(conn, name, value, [{:max_age, @cookie_max_age} | cookie_options(conn)])

  defp put_source_cookie(conn, secret) do
    put_resp_cookie(
      conn,
      Handoff.source_cookie(scheme(conn)),
      secret,
      [{:sign, true}, {:max_age, @cookie_max_age} | cookie_options(conn)]
    )
  end

  defp delete_handoff_cookie(conn, name),
    do: delete_resp_cookie(conn, name, cookie_options(conn))

  defp put_module_cookies(conn, cookies) do
    Enum.reduce(cookies, conn, fn {name, value, opts}, acc ->
      put_resp_cookie(acc, name, value, opts)
    end)
  end
end
