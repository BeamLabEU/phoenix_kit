defmodule PhoenixKit.Handoff do
  @moduledoc """
  Cross-domain handoff: a visitor follows a link from one of the site's domains to another and
  arrives still signed in, with the modules' own per-session state carried along.

  One application can serve several domains on different TLDs (one per language, see
  `PhoenixKit.Utils.Routes.canonical_host/1`). Cookies are host-only, so such a visitor arrives as
  a new anonymous session. The handoff is four redirects, the endpoints of
  `PhoenixKitWeb.HandoffController`:

    1. `start` on the **source** domain: sets a short-lived, signed source-side cookie and sends
       the browser to the target, with the SHA-256 of the cookie's secret (nothing is set and no
       row written when the visitor is anonymous and no module has anything to carry: it is a
       plain redirect).
    2. `prepare` on the **target**: gives the browser a random nonce in a cookie of the target and
       sends the SHA-256 of it back to the source, with the proof it was given unchanged.
    3. `mint` on the **source**: checks that its signed cookie is one this application issued and
       that the proof is its hash, asks every enabled module for a snapshot of its state, stores a
       token row bound to the target host and to that nonce hash (refusing a handoff that carries
       nothing: no account and no snapshot), and sends the browser to the target.
    4. `redeem` on the **target**: consumes the row in one statement (`redeem/4`), lets the modules
       apply their payload, signs the account in through the normal log-in path and redirects to the
       requested path.

  Only a browser that took part in steps 1 and 2 can complete step 4: the nonce cookie never leaves
  the target browser, only its hash travels, so a copied handoff link is useless in any other
  browser. Every failure, at every step, is a `302` to `/` with nothing to tell "used" from
  "unknown".

  ## What a host has to configure

  `config :phoenix_kit, :canonical_host_resolver, {Mod, :fun}` (see
  `PhoenixKit.Utils.Routes.canonical_host/1`) — the hosts the resolver answers for the enabled
  languages are the only hosts a handoff may start from, go to or return to (`allowed_hosts/0`).
  `guides/cross-domain-handoff.md` has the rest (links, session cookie, robots.txt, log scrubbing).

  ## Hooks

  Modules take part through two optional `PhoenixKit.Module` callbacks, `handoff_snapshot/1` (at
  mint) and `handoff_apply/2` (at redeem). Only enabled modules are asked; each call runs in a task
  of its own with a time limit; what a module is handed has the kit's auth material removed
  (`hook_context/4`); what it answers is validated (`apply_payload/4`). The contract is in the
  callbacks' docs and the guide.

  ## The token

  32 random bytes, base64url, never stored (only its SHA-256). It lives `ttl_seconds/0` seconds, is
  single use, and is redeemable only on the host it was minted for, by the browser whose nonce it
  was minted for, and — softly — by the same `User-Agent`. A row dies with the sessions of its
  account (`revoke_for_users/1`, called by `PhoenixKit.Users.Sessions.Revocation`), and expired
  rows are deleted (`prune_expired/1`: by `PhoenixKit.Handoff.PruneWorker` daily, and a few at every
  mint).
  """

  import Ecto.Query

  alias PhoenixKit.Handoff.Token
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.LoginAlerts
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess.Gate
  alias PhoenixKitWeb.OAuth.Responses, as: OAuthResponses
  alias PhoenixKitWeb.Plugs.WebsiteAccess, as: WebsiteAccessPlug
  alias PhoenixKitWeb.Users.Auth, as: WebAuth
  alias PhoenixKitWeb.Users.MultiSession

  require Logger

  @ttl_seconds 60
  @prune_after_seconds 86_400
  @mint_prune_after_seconds 300
  @mint_prune_batch 20
  @max_snapshot_bytes 65_536
  @max_notices 5
  @max_notice_bytes 300
  @max_notices_total_bytes 600
  @max_cookies_per_module 5
  @max_cookies 10
  @max_cookie_name_bytes 64
  @max_cookie_value_bytes 2048
  @max_cookie_path_bytes 256
  @max_cookie_max_age 34_560_000
  @snapshot_timeout_ms 2_000
  @apply_timeout_ms 5_000
  @max_to_length 2048
  @cookie_option_keys [:max_age, :http_only, :same_site, :secure, :sign, :encrypt, :path]
  @same_site_values ["Lax", "Strict", "None"]
  @source_cookie "pk_handoff_src"
  @nonce_cookie "pk_handoff_nonce"
  # RFC 6265: a cookie name is an RFC 2616 token; a value is cookie-octets (printable ASCII but
  # space, `"`, `,`, `;` and `\`).
  @cookie_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @cookie_value ~r/\A[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*\z/

  @type context :: %{required(atom()) => term()}

  @doc """
  The name of the cookie `start` sets on the source domain, which `mint` requires. `scheme` is
  `scheme/0`: on `"https"` the name carries the `__Host-` prefix (the browser then insists on
  `Secure`, no `Domain` and `Path=/`), on `"http"` (dev and test only) it cannot, as the prefix
  requires `Secure`.
  """
  @spec source_cookie(String.t()) :: String.t()
  def source_cookie(scheme), do: cookie_name(@source_cookie, scheme)

  @doc "The name of the cookie `prepare` sets on the target domain, which `redeem` requires."
  @spec nonce_cookie(String.t()) :: String.t()
  def nonce_cookie(scheme), do: cookie_name(@nonce_cookie, scheme)

  defp cookie_name(name, "https"), do: "__Host-" <> name
  defp cookie_name(name, _scheme), do: name

  @doc "The names of the handoff cookies, with and without the `__Host-` prefix."
  @spec cookie_names() :: [String.t()]
  def cookie_names do
    for scheme <- ["https", "http"], name <- [@source_cookie, @nonce_cookie] do
      cookie_name(name, scheme)
    end
  end

  @doc "How long a minted token can be redeemed, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  The scheme of the redirect URLs and of the cookies: `Routes.canonical_scheme/0`, the one the
  site's other absolute URLs use (`"https"` unless the `site_url` setting says `http`).
  """
  @spec scheme() :: String.t()
  def scheme do
    case Routes.canonical_scheme() do
      "http" -> "http"
      _ -> "https"
    end
  rescue
    _ -> "https"
  catch
    :exit, _ -> "https"
  end

  @doc """
  Whether a handoff can happen on this site: the host's `:canonical_host_resolver` names at least
  two hosts for the enabled languages. A host keeps plain links when this is `false`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: match?([_, _ | _], allowed_hosts())

  @doc """
  The path (with the PhoenixKit URL prefix, no locale segment) of the `start` endpoint for a link
  to `to`, a local path on the domain of language `lang`. A `to` that is not a local path becomes
  `/`.

      PhoenixKit.Handoff.start_path("de", "/shop")
      #=> "/phoenix_kit/handoff/start?lang=de&to=%2Fshop"
  """
  @spec start_path(String.t(), String.t()) :: String.t()
  def start_path(lang, to \\ "/") when is_binary(lang) do
    Routes.path("/handoff/start") <> "?" <> URI.encode_query(lang: lang, to: valid_to(to) || "/")
  end

  @doc """
  The hosts (`host` or `host:port`, as the resolver answers them) a handoff may involve: what
  `Routes.canonical_host/1` returns for each enabled language, its base code included. A failing
  lookup is no host.
  """
  @spec allowed_hosts() :: [String.t()]
  def allowed_hosts, do: host_languages() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  @doc """
  `[{language_code, host}]`: every enabled language code with the host the resolver answers for it
  (or for its base code), in language order. The resolver is asked once per distinct language.
  `allowed_hosts/0` and `language_for_host/2` read this list; a caller that needs both asks once
  (`resolve/0`).
  """
  @spec host_languages() :: [{String.t(), String.t()}]
  def host_languages do
    codes = Languages.enabled_locale_codes()

    hosts =
      codes
      |> Enum.flat_map(&[&1, DialectMapper.extract_base(&1)])
      |> Enum.uniq()
      |> Map.new(&{&1, Routes.canonical_host(&1)})

    for code <- codes,
        language <- Enum.uniq([code, DialectMapper.extract_base(code)]),
        host = Map.fetch!(hosts, language),
        is_binary(host),
        do: {code, host}
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  What a request needs to know about the site, read once: the allowed `:hosts`, the
  `:languages` (`host_languages/0`) and the `:scheme` (`scheme/0`).
  """
  @spec resolve() :: %{
          hosts: [String.t()],
          languages: [{String.t(), String.t()}],
          scheme: String.t()
        }
  def resolve do
    languages = host_languages()

    %{
      hosts: languages |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      languages: languages,
      scheme: scheme()
    }
  end

  @doc """
  The entry of `allowed_hosts/0` (or of `hosts`, a list already read) that `host` (a request
  parameter, untrusted) names, or `nil`. This is the only way a host from a request reaches a
  redirect.
  """
  @spec allowed_host(term(), [String.t()] | nil) :: String.t() | nil
  def allowed_host(host, hosts \\ nil)

  def allowed_host(host, hosts) when is_binary(host) and byte_size(host) <= 255 do
    host = host |> String.trim() |> String.downcase()
    if host != "", do: Enum.find(hosts || allowed_hosts(), &(&1 == host))
  end

  def allowed_host(_host, _hosts), do: nil

  @doc "The host name of an allow-list entry, without its port."
  @spec host_name(String.t()) :: String.t()
  def host_name(host) when is_binary(host), do: Regex.replace(~r/:\d+\z/, host, "")

  @doc """
  The entry of `allowed_hosts/0` (or of `hosts`) whose host name is `request_host` (a
  `conn.host`), or `nil`.
  """
  @spec own_host(String.t(), [String.t()] | nil) :: String.t() | nil
  def own_host(request_host, hosts \\ nil) when is_binary(request_host) do
    name = String.downcase(request_host)
    Enum.find(hosts || allowed_hosts(), &(host_name(&1) == name))
  end

  @doc """
  The enabled language code the host `request_host` serves, or `nil` (`languages` is
  `host_languages/0`, when already read).
  """
  @spec language_for_host(String.t(), [{String.t(), String.t()}] | nil) :: String.t() | nil
  def language_for_host(request_host, languages \\ nil) when is_binary(request_host) do
    name = String.downcase(request_host)

    Enum.find_value(languages || host_languages(), fn {code, host} ->
      if host_name(host) == name, do: code
    end)
  end

  @doc "`to` when it is a local path (`Routes.local_path?/1`) of a sane length, else `nil`."
  @spec valid_to(term()) :: String.t() | nil
  def valid_to(to) when is_binary(to) and byte_size(to) <= @max_to_length do
    if Routes.local_path?(to), do: to
  end

  def valid_to(_to), do: nil

  @doc """
  The account a scope may carry: `{:ok, user}` for a signed-in account, `{:ok, nil}` for a
  visitor, `:refused` for a session that must not be handed over (an impersonated session, one
  acting for an organization, an account `Auth.sign_in_refusal/1` names).
  """
  @spec carried_user(term()) :: {:ok, User.t() | nil} | :refused
  def carried_user(%Scope{authenticated?: true, user: %User{} = user} = scope) do
    cond do
      not is_nil(scope.impersonated_by_uuid) -> :refused
      not is_nil(scope.acting_person) -> :refused
      not is_nil(Scope.acting_link(scope)) -> :refused
      not is_nil(Scope.acting_user_uuid(scope)) -> :refused
      not Auth.may_sign_in?(user) -> :refused
      true -> {:ok, user}
    end
  end

  def carried_user(_scope), do: {:ok, nil}

  ## Tokens and nonces

  @doc "A fresh secret (32 random bytes, base64url, 43 characters): a token, a nonce, a cookie value."
  @spec new_secret() :: String.t()
  def new_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Whether `value` has the shape of `new_secret/0`'s answers."
  @spec secret?(term()) :: boolean()
  def secret?(value) when is_binary(value) and byte_size(value) == 43 do
    match?({:ok, <<_::binary-size(32)>>}, Base.url_decode64(value, padding: false))
  end

  def secret?(_value), do: false

  @doc "The SHA-256 of a nonce, base64url (what `prepare` sends to the source as `n`)."
  @spec nonce_hash_param(String.t()) :: String.t()
  def nonce_hash_param(nonce) when is_binary(nonce),
    do: nonce |> sha256() |> Base.url_encode64(padding: false)

  @doc """
  The SHA-256 of a source secret, base64url (what `start` sends through `prepare` to `mint` as
  `s`). The same function as `nonce_hash_param/1`.
  """
  @spec source_proof_param(String.t()) :: String.t()
  def source_proof_param(secret), do: nonce_hash_param(secret)

  @doc """
  Whether `param` (the `s` of a mint request) is the proof of `secret` (what `mint` read, and
  verified, from its source cookie). A constant-time comparison.
  """
  @spec source_proof?(term(), term()) :: boolean()
  def source_proof?(secret, param) when is_binary(secret) and is_binary(param) do
    secret?(secret) and secret?(param) and
      Plug.Crypto.secure_compare(source_proof_param(secret), param)
  end

  def source_proof?(_secret, _param), do: false

  @doc "The 32-byte hash a `n` parameter carries, or `:error`."
  @spec decode_nonce_hash(term()) :: {:ok, binary()} | :error
  def decode_nonce_hash(param) do
    with true <- secret?(param),
         {:ok, hash} <- Base.url_decode64(param, padding: false) do
      {:ok, hash}
    else
      _ -> :error
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value)

  @doc """
  Stores a handoff and returns its raw token, which is stored nowhere.

  `attrs`: `:target_host` (the host it is redeemable on, a port is dropped), `:redirect_path` (a
  local path), `:browser_nonce_hash` (the 32 bytes `decode_nonce_hash/1` gives), and optionally
  `:user_uuid`, `:payload` (a JSON-safe map) and `:user_agent` (a header value, kept as a hash).

  A handoff that carries nothing, no `:user_uuid` and an empty `:payload`, is refused
  (`{:error, :nothing_to_carry}`): there is nothing to hand over, and no row is written. Each
  successful mint also deletes a few rows that expired a while ago (`prune_expired/1`).
  """
  @spec mint(map()) :: {:ok, String.t()} | {:error, term()}
  def mint(%{target_host: host, redirect_path: path, browser_nonce_hash: nonce_hash} = attrs)
      when is_binary(host) and host != "" and is_binary(nonce_hash) and
             byte_size(nonce_hash) == 32 do
    cond do
      is_nil(valid_to(path)) -> {:error, :invalid_path}
      nothing_to_carry?(attrs) -> {:error, :nothing_to_carry}
      true -> insert_token(attrs, host, path, nonce_hash)
    end
  end

  def mint(_attrs), do: {:error, :invalid_attrs}

  defp nothing_to_carry?(attrs) do
    is_nil(Map.get(attrs, :user_uuid)) and Map.get(attrs, :payload) in [nil, %{}]
  end

  defp insert_token(attrs, host, path, nonce_hash) do
    token = new_secret()
    now = now()

    row = %Token{
      token_hash: sha256(token),
      target_host: host |> host_name() |> String.downcase(),
      redirect_path: path,
      user_uuid: Map.get(attrs, :user_uuid),
      payload: Map.get(attrs, :payload) || %{},
      browser_nonce_hash: nonce_hash,
      user_agent_hash: user_agent_hash(Map.get(attrs, :user_agent)),
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    case RepoHelper.repo().insert(row) do
      {:ok, _row} ->
        prune_a_few()
        {:ok, token}

      {:error, _reason} = error ->
        error
    end
  rescue
    error ->
      Logger.error("[Handoff] mint failed: #{inspect(error.__struct__)}")
      {:error, :failed}
  catch
    :exit, _ ->
      Logger.error("[Handoff] mint failed: database unavailable")
      {:error, :failed}
  end

  # Bounded and index-backed (`expires_at`): a handful of rows that expired minutes ago. Never
  # fails the mint that triggered it.
  defp prune_a_few do
    prune_expired(older_than: @mint_prune_after_seconds, limit: @mint_prune_batch)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc """
  Consumes the handoff `token` on `host` for the browser holding `nonce`.

  One `UPDATE ... RETURNING` sets `used_at` where the token's hash, the host, the nonce's hash and
  (when the row has one) the `User-Agent` hash (`user_agent:` option) all match, the row is unused
  and not expired. A request that fails any of them touches nothing, so a wrong host, browser or
  `User-Agent` does not burn the token; two requests racing for it, exactly one wins.

  `{:ok, token_row}` or `:error`, which says nothing about why.
  """
  @spec redeem(term(), term(), term(), keyword()) :: {:ok, Token.t()} | :error
  def redeem(token, host, nonce, opts \\ [])

  def redeem(token, host, nonce, opts) when is_binary(host) and host != "" do
    if secret?(token) and secret?(nonce) do
      consume(token, String.downcase(host), nonce, Keyword.get(opts, :user_agent))
    else
      :error
    end
  end

  def redeem(_token, _host, _nonce, _opts), do: :error

  defp consume(token, host, nonce, user_agent) do
    now = now()

    query =
      from t in Token,
        where: t.token_hash == ^sha256(token),
        where: t.target_host == ^host,
        where: t.browser_nonce_hash == ^sha256(nonce),
        where: is_nil(t.used_at),
        where: t.expires_at > ^now,
        where: ^user_agent_matches(user_agent),
        select: t

    case RepoHelper.repo().update_all(query, set: [used_at: now]) do
      {1, [row]} -> {:ok, row}
      _ -> :error
    end
  rescue
    error ->
      Logger.error("[Handoff] redeem failed: #{inspect(error.__struct__)}")
      :error
  catch
    :exit, _ ->
      Logger.error("[Handoff] redeem failed: database unavailable")
      :error
  end

  defp user_agent_matches(user_agent) do
    case user_agent_hash(user_agent) do
      nil -> dynamic([t], is_nil(t.user_agent_hash))
      hash -> dynamic([t], is_nil(t.user_agent_hash) or t.user_agent_hash == ^hash)
    end
  end

  defp user_agent_hash(user_agent) when is_binary(user_agent) and user_agent != "",
    do: sha256(user_agent)

  defp user_agent_hash(_user_agent), do: nil

  @doc """
  Deletes the rows that expired more than `older_than:` seconds ago (default a day; what
  `PhoenixKit.Handoff.PruneWorker` runs daily), at most `limit:` of them (default all). Returns how
  many.
  """
  @spec prune_expired(keyword()) :: non_neg_integer()
  def prune_expired(opts \\ []) do
    cutoff = DateTime.add(now(), -Keyword.get(opts, :older_than, @prune_after_seconds), :second)
    expired = from t in Token, where: t.expires_at < ^cutoff

    query =
      case Keyword.get(opts, :limit) do
        nil ->
          expired

        limit ->
          from t in Token,
            where: t.uuid in subquery(from(e in expired, select: e.uuid, limit: ^limit))
      end

    {count, _} = RepoHelper.repo().delete_all(query)
    count
  end

  @doc """
  Deletes the unused handoffs of the accounts `user_uuids`. Called, in the same transaction, by
  every deletion of a session token (`PhoenixKit.Users.Sessions.Revocation`): a handoff in flight
  must not outlive the sessions of the account it signs in. Returns how many.
  """
  @spec revoke_for_users([String.t()]) :: non_neg_integer()
  def revoke_for_users([]), do: 0

  def revoke_for_users(user_uuids) when is_list(user_uuids) do
    {count, _} =
      RepoHelper.repo().delete_all(
        from(t in Token, where: t.user_uuid in ^user_uuids and is_nil(t.used_at)),
        log: false
      )

    count
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## What a module is handed

  @doc """
  The names (strings) of the session keys a module is never handed: the signed-in session
  (`PhoenixKitWeb.Users.Auth.session_keys/0`), the multi-account stack
  (`PhoenixKitWeb.Users.MultiSession.session_keys/0`), the website-access unlock and the CSRF
  token. The one list.
  """
  @spec auth_session_keys() :: [String.t()]
  def auth_session_keys do
    WebAuth.session_keys() ++
      MultiSession.session_keys() ++
      [
        Atom.to_string(Gate.session_key()),
        Atom.to_string(WebsiteAccessPlug.allowed_session_key()),
        "_csrf_token"
      ]
  end

  @doc """
  The names of the cookies a module is never handed, and may never set: the remember-me cookie,
  the multi-account mirror, the new-device cookie, the OAuth browser cookie, the handoff cookies,
  and `session_cookies`, the name of the host's session cookie (`session_cookie_names/1`). The
  one list.
  """
  @spec auth_cookie_names([String.t()]) :: [String.t()]
  def auth_cookie_names(session_cookies \\ []) do
    Enum.uniq(
      [
        WebAuth.remember_me_cookie(),
        MultiSession.accounts_cookie(),
        LoginAlerts.device_cookie(),
        OAuthResponses.browser_cookie()
      ] ++ cookie_names() ++ session_cookies
    )
  end

  @doc """
  The name(s) of the session cookie of `endpoint`, read from the `session:` connect info of its
  sockets (a LiveView host declares one: `socket "/live", ..., connect_info: [session: opts]`).
  `[]` when the endpoint declares none, in which case that cookie is not recognised as the
  session's.
  """
  @spec session_cookie_names(module() | term()) :: [String.t()]
  def session_cookie_names(endpoint) when is_atom(endpoint) and not is_nil(endpoint) do
    endpoint.__sockets__()
    |> Enum.flat_map(fn {_path, _handler, opts} -> socket_session_keys(opts) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  def session_cookie_names(_endpoint), do: []

  defp socket_session_keys(opts) when is_list(opts) do
    for transport <- [:websocket, :longpoll],
        transport_opts = Keyword.get(opts, transport),
        is_list(transport_opts),
        {:session, session} <- List.wrap(Keyword.get(transport_opts, :connect_info)),
        is_list(session),
        do: Keyword.get(session, :key)
  end

  defp socket_session_keys(_opts), do: []

  @doc """
  The context a hook is handed (`PhoenixKit.Module.handoff_snapshot/1`): `:user_uuid`, `:session`
  and `:cookies`, with every key of `auth_session_keys/0` and every name of `auth_cookie_names/1`
  removed. `opts`: `:session_cookies`, the host's session cookie names.
  """
  @spec hook_context(String.t() | nil, map(), map(), keyword()) :: context()
  def hook_context(user_uuid, session, cookies, opts \\ []) do
    %{
      user_uuid: user_uuid,
      session: Map.drop(session, auth_session_keys()),
      cookies: Map.drop(cookies, auth_cookie_names(Keyword.get(opts, :session_cookies, [])))
    }
  end

  ## Module hooks

  @doc """
  Asks every enabled module for a snapshot (`PhoenixKit.Module.handoff_snapshot/1`).

  Returns `%{module_key => snapshot}` for the modules that answered with a non-empty map that is
  JSON-safe and small enough; the snapshots are normalised the way the database returns them
  (string keys). A module that raises, exits, throws, takes longer than `:timeout` (default
  #{@snapshot_timeout_ms} ms) or answers anything else is logged and left out. `modules` defaults to
  the enabled modules (`ModuleRegistry.enabled_modules/0`: a disabled module is never asked).
  """
  @spec snapshots(context(), [module()] | nil, keyword()) :: %{String.t() => map()}
  def snapshots(context, modules \\ nil, opts \\ []) when is_map(context) do
    timeout = Keyword.get(opts, :timeout, @snapshot_timeout_ms)

    modules
    |> hook_modules(:handoff_snapshot, 1)
    |> Enum.reduce(%{}, fn module, acc ->
      with {:ok, key} <- module_key(module),
           {:ok, snapshot} <- call_hook(module, :handoff_snapshot, [context], timeout),
           {:ok, snapshot} <- json_safe(module, snapshot) do
        Map.put(acc, key, snapshot)
      else
        _ -> acc
      end
    end)
  end

  @doc """
  Lets every enabled module that has an entry in `payload` apply it
  (`PhoenixKit.Module.handoff_apply/2`).

  Returns `%{notices: [String.t()], cookies: [{name, value, opts}]}`: what the modules asked to
  show the visitor and to set on the response, validated and capped (at most #{@max_notices}
  notices of #{@max_notice_bytes} bytes and #{@max_notices_total_bytes} bytes in all, cut on a
  character boundary; at most #{@max_cookies} cookies). A module that fails, answers with an error
  or takes longer than `:timeout` (default #{@apply_timeout_ms} ms) is logged and ignored, and so
  is anything invalid in what it answered. This function does not raise.

  Options: `:timeout`, `:scheme` (`scheme/0`, default `"https"`: it decides the default of a
  cookie's `Secure` flag) and `:reserved_cookies` (names a module may not set, default
  `auth_cookie_names/1`).
  """
  @spec apply_payload(context(), map(), [module()] | nil, keyword()) :: %{
          notices: [String.t()],
          cookies: list()
        }
  def apply_payload(context, payload, modules \\ nil, opts \\ [])
      when is_map(context) and is_map(payload) do
    settings = %{
      timeout: Keyword.get(opts, :timeout, @apply_timeout_ms),
      scheme: Keyword.get(opts, :scheme, "https"),
      reserved: Keyword.get_lazy(opts, :reserved_cookies, &auth_cookie_names/0)
    }

    modules
    |> hook_modules(:handoff_apply, 2)
    |> Enum.reduce(%{notices: [], cookies: []}, fn module, acc ->
      case apply_one(module, context, payload, settings) do
        {:ok, effects} -> merge_effects(acc, effects)
        :error -> acc
      end
    end)
    |> limit_effects()
  rescue
    error ->
      Logger.error("[Handoff] apply_payload failed: #{inspect(error.__struct__)}")
      %{notices: [], cookies: []}
  end

  defp apply_one(module, context, payload, settings) do
    with {:ok, key} <- module_key(module),
         {:ok, snapshot} when is_map(snapshot) <- Map.fetch(payload, key),
         {:ok, result} <- call_hook(module, :handoff_apply, [context, snapshot], settings.timeout) do
      sanitize_result(module, result, settings)
    else
      _ -> :error
    end
  end

  defp hook_modules(modules, function, arity) do
    (modules || ModuleRegistry.enabled_modules())
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, function, arity)))
  end

  defp module_key(module) do
    if function_exported?(module, :module_key, 0) do
      case call_safely(module, :module_key, []) do
        {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
        _ -> :error
      end
    else
      :error
    end
  end

  # The hook runs in a task of its own, supervised but not linked, and is given `timeout` ms:
  # a module that hangs cannot hold the visitor's request. The task inherits the caller's
  # `$callers` (so the Ecto sandbox of a test and the logger metadata of a request follow it) and
  # its Gettext locale. Only the module and the kind of failure are logged, never a message:
  # those can carry what the module was handed. The failure is caught inside the task, because
  # an uncaught one is logged by the runtime with its message.
  defp call_hook(module, function, args, timeout) do
    locale = Gettext.get_locale()

    task =
      Task.Supervisor.async_nolink(PhoenixKit.TaskSupervisor, fn ->
        Gettext.put_locale(locale)
        call_safely(module, function, args)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _value} = ok} ->
        ok

      {:ok, {:error, message}} ->
        Logger.error("[Handoff] #{function} of #{inspect(module)} #{message}")
        :error

      {:exit, _reason} ->
        Logger.error("[Handoff] #{function} of #{inspect(module)} exit")
        :error

      nil ->
        Logger.error("[Handoff] #{function} of #{inspect(module)} timed out after #{timeout} ms")
        :error
    end
  catch
    :exit, _ ->
      Logger.error(
        "[Handoff] #{function} of #{inspect(module)} could not run (no task supervisor)"
      )

      :error
  end

  defp call_safely(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    error -> {:error, "raised #{inspect(error.__struct__)}"}
  catch
    kind, _reason -> {:error, "#{kind}"}
  end

  defp json_safe(_module, nil), do: :skip
  defp json_safe(_module, snapshot) when snapshot == %{}, do: :skip

  defp json_safe(module, snapshot) when is_map(snapshot) do
    encoded = JSON.encode!(snapshot)

    if byte_size(encoded) <= @max_snapshot_bytes do
      {:ok, JSON.decode!(encoded)}
    else
      Logger.error("[Handoff] handoff_snapshot of #{inspect(module)} is too large, left out")
      :skip
    end
  rescue
    _ ->
      Logger.error("[Handoff] handoff_snapshot of #{inspect(module)} is not JSON-safe, left out")
      :skip
  end

  defp json_safe(module, _other) do
    Logger.error("[Handoff] handoff_snapshot of #{inspect(module)} answered something else")
    :skip
  end

  ## What a module answers to apply

  defp sanitize_result(_module, {:ok, notices}, _settings) when is_list(notices),
    do: {:ok, %{notices: clean_notices(notices), cookies: []}}

  defp sanitize_result(module, {:ok, %{} = effects}, settings) do
    {:ok,
     %{
       notices: clean_notices(list_of(Map.get(effects, :notices))),
       cookies: clean_cookies(module, list_of(Map.get(effects, :cookies)), settings)
     }}
  end

  defp sanitize_result(module, {:error, _reason}, _settings) do
    Logger.error("[Handoff] handoff_apply of #{inspect(module)} returned an error")
    :error
  end

  defp sanitize_result(module, _other, _settings) do
    Logger.error("[Handoff] handoff_apply of #{inspect(module)} answered something else")
    :error
  end

  defp list_of(value) when is_list(value), do: value
  defp list_of(_value), do: []

  defp clean_notices(notices) do
    for notice <- notices,
        is_binary(notice),
        String.valid?(notice),
        text = notice |> String.trim() |> truncate_bytes(@max_notice_bytes),
        text != "",
        do: text
  end

  # At most `max` bytes of `text` (valid UTF-8), cut on a character boundary.
  defp truncate_bytes(text, max) when byte_size(text) <= max, do: text

  defp truncate_bytes(text, max) do
    text |> binary_part(0, max) |> drop_partial_character()
  end

  defp drop_partial_character(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: drop_partial_character(binary_part(bytes, 0, byte_size(bytes) - 1))
  end

  defp clean_cookies(module, cookies, settings) do
    cookies
    |> Enum.flat_map(fn cookie ->
      case valid_cookie(cookie, settings) do
        {:ok, valid} ->
          [valid]

        :error ->
          Logger.error(
            "[Handoff] handoff_apply of #{inspect(module)} gave an invalid cookie, left out"
          )

          []
      end
    end)
    |> Enum.take(@max_cookies_per_module)
  end

  defp valid_cookie({name, value, opts}, settings) when is_binary(name) and is_binary(value) do
    with true <- Keyword.keyword?(opts),
         true <- valid_cookie_name?(name, settings.reserved),
         opts = cookie_options(opts, settings.scheme),
         true <- valid_cookie_value?(value, opts),
         true <- valid_cookie_options?(opts) do
      {:ok, {name, value, opts}}
    else
      _ -> :error
    end
  end

  defp valid_cookie(_cookie, _settings), do: :error

  defp valid_cookie_name?(name, reserved) do
    byte_size(name) in 1..@max_cookie_name_bytes and Regex.match?(@cookie_name, name) and
      name not in reserved
  end

  # A signed or encrypted value is sent as the base64 of what Plug makes of it; a plain one
  # goes into the header as it is.
  defp valid_cookie_value?(value, opts) do
    byte_size(value) <= @max_cookie_value_bytes and
      (Keyword.get(opts, :sign) == true or Keyword.get(opts, :encrypt) == true or
         Regex.match?(@cookie_value, value))
  end

  # The kit's defaults, then what the module passed: its own choice wins. Only whitelisted keys,
  # the first of a repeated one.
  defp cookie_options(opts, scheme) do
    given =
      opts
      |> Enum.filter(fn {key, _value} -> key in @cookie_option_keys end)
      |> Enum.uniq_by(&elem(&1, 0))

    [secure: scheme == "https", http_only: true, same_site: "Lax"]
    |> Keyword.merge(given)
  end

  defp valid_cookie_options?(opts) do
    Enum.all?(opts, fn
      {:max_age, value} -> is_integer(value) and value in 0..@max_cookie_max_age
      {key, value} when key in [:http_only, :secure, :sign, :encrypt] -> is_boolean(value)
      {:same_site, value} -> value in @same_site_values
      {:path, value} -> valid_cookie_path?(value)
    end) and
      not (Keyword.get(opts, :sign) == true and Keyword.get(opts, :encrypt) == true) and
      not (Keyword.get(opts, :same_site) == "None" and Keyword.get(opts, :secure) != true)
  end

  defp valid_cookie_path?(path) do
    is_binary(path) and byte_size(path) <= @max_cookie_path_bytes and
      Regex.match?(~r/\A\/[\x21\x23-\x3A\x3C-\x7E]*\z/, path)
  end

  defp merge_effects(acc, effects) do
    %{acc | notices: acc.notices ++ effects.notices, cookies: acc.cookies ++ effects.cookies}
  end

  defp limit_effects(%{notices: notices, cookies: cookies}) do
    %{notices: limit_notices(notices), cookies: Enum.take(cookies, @max_cookies)}
  end

  # At most `@max_notices` notices and `@max_notices_total_bytes` bytes between them: the flash
  # lives in the cookie session, whose cookie must stay under the browser's 4 KB.
  defp limit_notices(notices) do
    {kept, _left} =
      notices
      |> Enum.take(@max_notices)
      |> Enum.reduce_while({[], @max_notices_total_bytes}, fn notice, {kept, left} ->
        text = truncate_bytes(notice, left)

        if text == "",
          do: {:halt, {kept, left}},
          else: {:cont, {[text | kept], left - byte_size(text)}}
      end)

    Enum.reverse(kept)
  end
end
