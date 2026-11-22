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
  looked up); a `redeem` counts only when it fails, and a `mint` also per account.

  ## Failure

  Anything that goes wrong, at any step, is a `302` to `/` of the current host, which deletes the
  handoff cookie the step consumes and nothing else. No page, no message, and nothing that tells a
  used token from an unknown one or a refused host from a refused parameter.

  ## Who may start one

  `start` is the one step a page can aim a visitor at, so it refuses a request that is not a
  top-level navigation of the visitor's own (`Sec-Fetch-Site` `cross-site`, or a `Sec-Fetch-Dest`
  other than `document`: an image, a frame, a script): a `302` to `/`, before the rate limit takes a
  slot, with no side effect. The other steps are reached by cross-site redirects by design and are
  not checked this way (see `navigation?/1`).

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

  The source cookie is **signed** (`Plug.Conn.put_resp_cookie/4` with `sign: true`, so it needs the
  application's `secret_key_base`, which every domain of the site shares) and lives 60 seconds:
  `mint` accepts only a cookie the application itself issued. `start` also sends the SHA-256 of
  its secret through `prepare` to `mint` (`s`), which compares it with its own cookie: a `mint`
  request must belong to a `start` made in the same browser.
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
  @navigation_fetch_sites ~w(same-origin same-site none)

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
    site = site(conn)

    with lang when is_binary(lang) <- language(params["lang"]),
         canonical when is_binary(canonical) <- Routes.canonical_host(lang),
         target when is_binary(target) <- Handoff.allowed_host(canonical, site.hosts),
         source when is_binary(source) <- Handoff.own_host(conn.host, site.hosts),
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
    site = site(conn)

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
      redirect(conn, external: site.scheme <> "://" <> target <> to)
    end
  end

  ## Step 2

  defp do_prepare(conn, params) do
    site = site(conn)

    with return when is_binary(return) <- Handoff.allowed_host(params["return"], site.hosts),
         to when is_binary(to) <- Handoff.valid_to(params["to"]),
         true <- Handoff.secret?(params["s"]),
         own when is_binary(own) <- Handoff.own_host(conn.host, site.hosts),
         false <- same_host?(return, own) do
      name = Handoff.nonce_cookie(site.scheme)
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

  defp do_mint(conn, params) do
    site = site(conn)
    name = Handoff.source_cookie(site.scheme)

    # The cookie is read, and deleted, whatever follows: it is good for one attempt. Read as a
    # SIGNED cookie: only one this application issued (and not older than 60 seconds) counts.
    secret = signed_secret(conn, name)
    conn = delete_handoff_cookie(conn, name)

    with true <- Handoff.source_proof?(secret, params["s"]),
         target when is_binary(target) <- Handoff.allowed_host(params["h"], site.hosts),
         source when is_binary(source) <- Handoff.own_host(conn.host, site.hosts),
         false <- same_host?(target, source),
         {:ok, nonce_hash} <- Handoff.decode_nonce_hash(params["n"]),
         to when is_binary(to) <- Handoff.valid_to(params["to"]),
         conn = WebAuth.fetch_phoenix_kit_current_scope(conn, []),
         {:ok, user} <- Handoff.carried_user(conn.assigns[:phoenix_kit_current_scope]),
         :ok <- mint_rate_limit(user),
         user_uuid = user && user.uuid,
         {:ok, token} <-
           Handoff.mint(%{
             target_host: target,
             redirect_path: to,
             user_uuid: user_uuid,
             payload: Handoff.snapshots(hook_context(conn, user_uuid)),
             browser_nonce_hash: nonce_hash,
             user_agent: user_agent(conn)
           }) do
      redirect(conn, external: external_url(conn, target, "/handoff/" <> token, []))
    else
      _ -> fail(conn)
    end
  end

  defp mint_rate_limit(nil), do: :ok
  defp mint_rate_limit(%User{uuid: uuid}), do: RateLimiter.check_handoff_mint_rate_limit(uuid)

  ## Step 4

  defp do_redeem(conn, token) do
    site = site(conn)
    name = Handoff.nonce_cookie(site.scheme)
    nonce = existing_secret(conn, name)
    conn = delete_handoff_cookie(conn, name)

    with {:ok, row} <- Handoff.redeem(token, conn.host, nonce, user_agent: user_agent(conn)),
         :ok <- RateLimiter.release_handoff_redeem_slot(IpAddress.extract_from_conn(conn)),
         to when is_binary(to) <- Handoff.valid_to(row.redirect_path),
         {:ok, user} <- load_user(row.user_uuid) do
      locale = Handoff.language_for_host(conn.host, site.languages)
      session_cookies = session_cookie_names(conn)

      effects =
        conn
        |> hook_context(row.user_uuid)
        |> Map.merge(%{host: conn.host, locale: locale})
        |> Handoff.apply_payload(row.payload || %{}, nil,
          scheme: site.scheme,
          reserved_cookies: Handoff.auth_cookie_names(session_cookies)
        )

      conn
      |> put_module_effects(user, effects, locale)
      |> land(user, to)
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
  defp land(conn, nil, to), do: redirect(conn, to: to)

  defp land(conn, user, to),
    do: WebAuth.log_in_user(conn, user, %{"return_to" => to}, localize: false)

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

  # What the request needs to know about the site, read once per request.
  defp site(conn), do: conn.private.handoff_site

  defp guarded(conn, step, fun) do
    conn = secure(conn)

    if side_effect_free?(conn), do: send_resp(conn, 204, ""), else: limited(conn, step, fun)
  end

  # A handoff is counted once, where it starts. `prepare` writes nothing; `mint` needs a source
  # cookie only a counted `start` sets (and is limited per account on top); a `redeem` counts only
  # when it fails (`do_redeem/2` hands the slot back on success).
  defp limited(conn, :start, fun) do
    # Fetch metadata first: a refusal here has no side effect and takes no slot, so a page that
    # loads `start` as an image or a frame cannot spend the visitor's (or their NAT's) budget.
    with true <- navigation?(conn),
         :ok <- RateLimiter.check_handoff_start_rate_limit(IpAddress.extract_from_conn(conn)) do
      run(conn, fun)
    else
      _ -> fail(conn)
    end
  end

  defp limited(conn, :redeem, fun) do
    case RateLimiter.check_handoff_redeem_rate_limit(IpAddress.extract_from_conn(conn)) do
      :ok -> run(conn, fun)
      {:error, _} -> fail(conn)
    end
  end

  defp limited(conn, _step, fun), do: run(conn, fun)

  defp run(conn, fun), do: conn |> put_private(:handoff_site, Handoff.resolve()) |> fun.()

  defp fail(conn), do: redirect(secure(conn), to: "/")

  defp secure(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end

  defp side_effect_free?(conn), do: head?(conn) or purpose_request?(conn)

  # `start` is the one step a page of another site can aim a visitor at (a link, a form, a frame,
  # an image, a redirect), and it completes a chain that signs the visitor in as the source
  # account, replacing whoever is signed in on the target. It must be a top-level navigation the
  # visitor made themselves or a page of the site made for them: `Sec-Fetch-Site` is `same-origin`,
  # `same-site` or `none` (typed, bookmarked), or absent (a browser that does not send fetch
  # metadata: it cannot be told, and is let through), and `Sec-Fetch-Dest`, when sent, is
  # `document`. Anything else, an unknown value included, is refused.
  #
  # Only `start` is checked. `prepare`, `mint` and `redeem` are reached by REDIRECTS from another
  # of the site's domains, for which the browser reports `Sec-Fetch-Site: cross-site`, by design:
  # refusing that would refuse every handoff. They are protected by what they need: a cookie only
  # an earlier step of the same browser sets, a proof, a nonce.
  defp navigation?(conn) do
    fetch_header_values(conn, "sec-fetch-site") |> Enum.all?(&(&1 in @navigation_fetch_sites)) and
      fetch_header_values(conn, "sec-fetch-dest") |> Enum.all?(&(&1 == "document"))
  end

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
    base = site(conn).scheme <> "://" <> host <> Routes.path(path)
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

  defp cookie_options(conn), do: [{:secure, site(conn).scheme == "https"} | @cookie_options]

  defp put_handoff_cookie(conn, name, value),
    do: put_resp_cookie(conn, name, value, [{:max_age, @cookie_max_age} | cookie_options(conn)])

  defp put_source_cookie(conn, secret) do
    put_resp_cookie(
      conn,
      Handoff.source_cookie(site(conn).scheme),
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
