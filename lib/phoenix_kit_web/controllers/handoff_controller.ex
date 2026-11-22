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

  ## Requests with no side effects

  A request that says it is a prefetch or a preview (`Sec-Purpose` or `Purpose` naming `prefetch`,
  `prerender` or `preview`) and a `HEAD` request are answered `204` and change nothing: a browser
  that warms a link, or a link-preview robot, must not burn a token or set a cookie. `HEAD` is
  recognised even when `Plug.Head` ahead of the router has already turned it into a `GET` (the
  server's adapter still holds the method it received: Bandit, Cowboy and the test adapter all keep
  it under `:method`); an adapter that does not is treated as a `GET`.

  ## Redirects

  A redirect to another domain is always `https://` and names a host taken from
  `PhoenixKit.Handoff.allowed_hosts/0`, never a header or a parameter as given.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Handoff
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitWeb.Users.Auth, as: WebAuth

  @cookie_max_age 60
  @language_pattern ~r/\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*\z/
  @side_effect_free_purposes ~w(prefetch prerender preview)

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
    hosts = Handoff.allowed_hosts()

    with lang when is_binary(lang) <- language(params["lang"]),
         canonical when is_binary(canonical) <- Routes.canonical_host(lang),
         target when is_binary(target) <- Handoff.allowed_host(canonical, hosts),
         source when is_binary(source) <- Handoff.own_host(conn.host, hosts),
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
        {:ok, nil} -> Handoff.snapshots(context(conn, nil)) != %{}
        :refused -> false
      end

    if carried? do
      conn
      |> put_handoff_cookie(Handoff.source_cookie(), Handoff.new_secret())
      |> redirect(external: external_url(target, "/handoff/prepare", return: source, to: to))
    else
      redirect(conn, external: "https://" <> target <> to)
    end
  end

  ## Step 2

  defp do_prepare(conn, params) do
    hosts = Handoff.allowed_hosts()

    with return when is_binary(return) <- Handoff.allowed_host(params["return"], hosts),
         to when is_binary(to) <- Handoff.valid_to(params["to"]),
         own when is_binary(own) <- Handoff.own_host(conn.host, hosts),
         false <- same_host?(return, own) do
      nonce = existing_secret(conn, Handoff.nonce_cookie()) || Handoff.new_secret()

      conn
      |> put_handoff_cookie(Handoff.nonce_cookie(), nonce)
      |> redirect(
        external:
          external_url(return, "/handoff/mint",
            n: Handoff.nonce_hash_param(nonce),
            h: own,
            to: to
          )
      )
    else
      _ -> fail(conn)
    end
  end

  ## Step 3

  defp do_mint(conn, params) do
    # The cookie is read, and deleted, whatever follows: it is good for one attempt.
    proof = existing_secret(conn, Handoff.source_cookie())
    conn = delete_handoff_cookie(conn, Handoff.source_cookie())
    hosts = Handoff.allowed_hosts()

    with true <- is_binary(proof),
         target when is_binary(target) <- Handoff.allowed_host(params["h"], hosts),
         source when is_binary(source) <- Handoff.own_host(conn.host, hosts),
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
             payload: Handoff.snapshots(context(conn, user_uuid)),
             browser_nonce_hash: nonce_hash,
             user_agent: user_agent(conn)
           }) do
      redirect(conn, external: external_url(target, "/handoff/" <> token, []))
    else
      _ -> fail(conn)
    end
  end

  defp mint_rate_limit(nil), do: :ok
  defp mint_rate_limit(%User{uuid: uuid}), do: RateLimiter.check_handoff_mint_rate_limit(uuid)

  ## Step 4

  defp do_redeem(conn, token) do
    nonce = existing_secret(conn, Handoff.nonce_cookie())
    conn = delete_handoff_cookie(conn, Handoff.nonce_cookie())

    with {:ok, row} <- Handoff.redeem(token, conn.host, nonce, user_agent: user_agent(conn)),
         :ok <- RateLimiter.release_handoff_redeem_slot(IpAddress.extract_from_conn(conn)),
         to when is_binary(to) <- Handoff.valid_to(row.redirect_path),
         {:ok, user} <- load_user(row.user_uuid) do
      locale = Handoff.language_for_host(conn.host)

      effects =
        Handoff.apply_payload(
          conn |> context(row.user_uuid) |> Map.merge(%{host: conn.host, locale: locale}),
          row.payload || %{}
        )

      conn
      |> put_module_cookies(effects.cookies)
      |> put_flash_line(user, effects.notices, locale)
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

  # The normal log-in path: every check, the session renewal, the login alert and the
  # live-socket id apply, and an account already signed in on this browser is replaced.
  # No `remember_me`, so no persistent cookie.
  defp land(conn, nil, to), do: redirect(conn, to: to)
  # `localize: false`: the destination was chosen for the host it lands on, so the person's saved
  # language does not turn `/x` into `/<saved>/x` there.
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

  # What the hooks are handed (see `PhoenixKit.Module.handoff_snapshot/1`).
  defp context(conn, user_uuid) do
    conn = fetch_cookies(conn)

    %{
      user_uuid: user_uuid,
      session: get_session(conn),
      cookies: Map.drop(conn.req_cookies, Handoff.cookie_names())
    }
  end

  defp guarded(conn, step, fun) do
    conn = secure(conn)

    if side_effect_free?(conn), do: send_resp(conn, 204, ""), else: limited(conn, step, fun)
  end

  # A handoff is counted once, where it starts. `prepare` writes nothing; `mint` needs a source
  # cookie only a counted `start` sets (and is limited per account on top); a `redeem` counts only
  # when it fails (`do_redeem/2` hands the slot back on success).
  defp limited(conn, :start, fun) do
    case RateLimiter.check_handoff_start_rate_limit(IpAddress.extract_from_conn(conn)) do
      :ok -> fun.(conn)
      {:error, _} -> fail(conn)
    end
  end

  defp limited(conn, :redeem, fun) do
    case RateLimiter.check_handoff_redeem_rate_limit(IpAddress.extract_from_conn(conn)) do
      :ok -> fun.(conn)
      {:error, _} -> fail(conn)
    end
  end

  defp limited(conn, _step, fun), do: fun.(conn)

  defp fail(conn), do: redirect(secure(conn), to: "/")

  defp secure(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end

  defp side_effect_free?(conn), do: head?(conn) or purpose_request?(conn)

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

  defp external_url(host, path, query) do
    base = "https://" <> host <> Routes.path(path)
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  defp user_agent(conn), do: conn |> get_req_header("user-agent") |> List.first()

  defp existing_secret(conn, name) do
    value = conn |> fetch_cookies() |> Map.get(:req_cookies) |> Map.get(name)
    if Handoff.secret?(value), do: value
  end

  # `__Host-`: https only, no `Domain`, `Path=/`: the browser refuses it from anything else,
  # a sibling subdomain included.
  @cookie_options [http_only: true, secure: true, same_site: "Lax", path: "/"]

  defp put_handoff_cookie(conn, name, value),
    do: put_resp_cookie(conn, name, value, [{:max_age, @cookie_max_age} | @cookie_options])

  defp delete_handoff_cookie(conn, name), do: delete_resp_cookie(conn, name, @cookie_options)

  defp put_module_cookies(conn, cookies) do
    Enum.reduce(cookies, conn, fn {name, value, opts}, acc ->
      put_resp_cookie(acc, name, value, opts)
    end)
  end
end
