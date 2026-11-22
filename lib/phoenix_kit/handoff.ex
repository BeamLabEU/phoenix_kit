defmodule PhoenixKit.Handoff do
  @moduledoc """
  Cross-domain handoff: a visitor follows a link from one of the site's domains to another and
  arrives still signed in, with the modules' own per-session state carried along.

  One application can serve several domains on different TLDs (one per language, see
  `PhoenixKit.Utils.Routes.canonical_host/1`). Cookies are host-only, so such a visitor arrives as
  a new anonymous session. The handoff is four redirects, the endpoints of
  `PhoenixKitWeb.HandoffController`:

    1. `start` on the **source** domain: sets a short-lived source-side cookie and sends the
       browser to the target (nothing is set and no row written when the visitor is anonymous and
       no module has anything to carry: it is a plain redirect).
    2. `prepare` on the **target**: gives the browser a random nonce in a cookie of the target and
       sends the SHA-256 of it back to the source.
    3. `mint` on the **source**: asks every module for a snapshot of its state, stores a token row
       bound to the target host and to that nonce hash, and sends the browser to the target.
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
  `guides/cross-domain-handoff.md` has the rest (links, robots.txt, log scrubbing).

  ## Hooks

  Modules take part through two optional `PhoenixKit.Module` callbacks, `handoff_snapshot/1` (at
  mint) and `handoff_apply/2` (at redeem). Their context maps are documented there.

  ## The token

  32 random bytes, base64url, never stored (only its SHA-256). It lives `ttl_seconds/0` seconds, is
  single use, and is redeemable only on the host it was minted for, by the browser whose nonce it
  was minted for, and — softly — by the same `User-Agent`.
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
  alias PhoenixKit.Utils.Routes

  require Logger

  @ttl_seconds 60
  @prune_after_seconds 86_400
  @max_snapshot_bytes 65_536
  @max_notices 5
  @max_notice_length 300
  @max_to_length 2048
  @cookie_option_keys [:max_age, :http_only, :same_site, :secure, :sign, :encrypt, :path]
  @source_cookie "__Host-pk_handoff_src"
  @nonce_cookie "__Host-pk_handoff_nonce"
  @cookie_names [@source_cookie, @nonce_cookie]

  @type context :: %{required(atom()) => term()}

  @doc """
  The name of the cookie `start` sets on the source domain, which `mint` requires.
  """
  @spec source_cookie() :: String.t()
  def source_cookie, do: @source_cookie

  @doc "The name of the cookie `prepare` sets on the target domain, which `redeem` requires."
  @spec nonce_cookie() :: String.t()
  def nonce_cookie, do: @nonce_cookie

  @doc "The names of both handoff cookies."
  @spec cookie_names() :: [String.t()]
  def cookie_names, do: @cookie_names

  @doc "How long a minted token can be redeemed, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

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
  def allowed_hosts do
    Languages.enabled_locale_codes()
    |> Enum.flat_map(&[&1, DialectMapper.extract_base(&1)])
    |> Enum.uniq()
    |> Enum.map(&Routes.canonical_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  The entry of `allowed_hosts/0` (or of `hosts`, a list already read) that `host` (a request
  parameter, untrusted) names, or `nil`. This is the only way a host from a request reaches a
  redirect.
  """
  @spec allowed_host(term(), [String.t()]) :: String.t() | nil
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
  @spec own_host(String.t(), [String.t()]) :: String.t() | nil
  def own_host(request_host, hosts \\ nil) when is_binary(request_host) do
    name = String.downcase(request_host)
    Enum.find(hosts || allowed_hosts(), &(host_name(&1) == name))
  end

  @doc "The enabled language code the host `request_host` serves, or `nil`."
  @spec language_for_host(String.t()) :: String.t() | nil
  def language_for_host(request_host) when is_binary(request_host) do
    name = String.downcase(request_host)

    Enum.find(Languages.enabled_locale_codes(), fn code ->
      Enum.any?([code, DialectMapper.extract_base(code)], fn language ->
        case Routes.canonical_host(language) do
          nil -> false
          host -> host_name(host) == name
        end
      end)
    end)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
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
  """
  @spec mint(map()) :: {:ok, String.t()} | {:error, term()}
  def mint(%{target_host: host, redirect_path: path, browser_nonce_hash: nonce_hash} = attrs)
      when is_binary(host) and host != "" and is_binary(nonce_hash) and
             byte_size(nonce_hash) == 32 do
    if valid_to(path) do
      insert_token(attrs, host, path, nonce_hash)
    else
      {:error, :invalid_path}
    end
  end

  def mint(_attrs), do: {:error, :invalid_attrs}

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
      {:ok, _row} -> {:ok, token}
      {:error, _reason} = error -> error
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

  @doc "Deletes the rows that expired more than a day ago. Returns how many."
  @spec prune_expired() :: non_neg_integer()
  def prune_expired do
    cutoff = DateTime.add(now(), -@prune_after_seconds, :second)

    {count, _} =
      RepoHelper.repo().delete_all(from t in Token, where: t.expires_at < ^cutoff)

    count
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## Module hooks

  @doc """
  Asks every module for a snapshot (`PhoenixKit.Module.handoff_snapshot/1`).

  Returns `%{module_key => snapshot}` for the modules that answered with a non-empty map that is
  JSON-safe and small enough; the snapshots are normalised the way the database returns them
  (string keys). A module that raises, exits, throws or answers anything else is logged and left
  out. `modules` defaults to every registered module.
  """
  @spec snapshots(context(), [module()] | nil) :: %{String.t() => map()}
  def snapshots(context, modules \\ nil) when is_map(context) do
    modules
    |> hook_modules(:handoff_snapshot, 1)
    |> Enum.reduce(%{}, fn module, acc ->
      with {:ok, key} <- module_key(module),
           {:ok, snapshot} <- call_hook(module, :handoff_snapshot, [context]),
           {:ok, snapshot} <- json_safe(module, snapshot) do
        Map.put(acc, key, snapshot)
      else
        _ -> acc
      end
    end)
  end

  @doc """
  Lets every module that has an entry in `payload` apply it
  (`PhoenixKit.Module.handoff_apply/2`).

  Returns `%{notices: [String.t()], cookies: [{name, value, opts}]}`: what the modules asked to
  show the visitor and to set on the response. A module that fails, or answers with an error, is
  logged and ignored.
  """
  @spec apply_payload(context(), map(), [module()] | nil) :: %{
          notices: [String.t()],
          cookies: list()
        }
  def apply_payload(context, payload, modules \\ nil) when is_map(context) and is_map(payload) do
    modules
    |> hook_modules(:handoff_apply, 2)
    |> Enum.reduce(%{notices: [], cookies: []}, fn module, acc ->
      with {:ok, key} <- module_key(module),
           {:ok, snapshot} <- Map.fetch(payload, key),
           {:ok, result} <- call_hook(module, :handoff_apply, [context, snapshot]) do
        merge_effects(acc, module, result)
      else
        _ -> acc
      end
    end)
    |> then(fn %{notices: notices} = effects ->
      %{effects | notices: Enum.take(notices, @max_notices)}
    end)
  end

  defp hook_modules(modules, function, arity) do
    (modules || ModuleRegistry.all_modules())
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, function, arity)))
  end

  defp module_key(module) do
    if function_exported?(module, :module_key, 0) do
      case call_hook(module, :module_key, []) do
        {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
        _ -> :error
      end
    else
      :error
    end
  end

  # Every call is wrapped: one failing module must not break the handoff. Only the module and the
  # kind of failure are logged, never a message: those can carry what the module was handed.
  defp call_hook(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    error ->
      Logger.error(
        "[Handoff] #{function} of #{inspect(module)} raised #{inspect(error.__struct__)}"
      )

      :error
  catch
    kind, _reason ->
      Logger.error("[Handoff] #{function} of #{inspect(module)} #{kind}")
      :error
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

  defp merge_effects(acc, _module, {:ok, notices}) when is_list(notices),
    do: add_notices(acc, notices)

  defp merge_effects(acc, _module, {:ok, %{} = effects}) do
    acc
    |> add_notices(List.wrap(Map.get(effects, :notices)))
    |> add_cookies(List.wrap(Map.get(effects, :cookies)))
  end

  defp merge_effects(acc, module, {:error, _reason}) do
    Logger.error("[Handoff] handoff_apply of #{inspect(module)} returned an error")
    acc
  end

  defp merge_effects(acc, module, _other) do
    Logger.error("[Handoff] handoff_apply of #{inspect(module)} answered something else")
    acc
  end

  defp add_notices(acc, notices) do
    clean =
      for notice <- notices,
          is_binary(notice),
          text = notice |> String.trim() |> String.slice(0, @max_notice_length),
          text != "",
          do: text

    %{acc | notices: acc.notices ++ clean}
  end

  defp add_cookies(acc, cookies) do
    clean =
      for {name, value, opts} <- cookies,
          is_binary(name) and is_binary(value) and is_list(opts) and
            name not in @cookie_names,
          do: {name, value, Keyword.take(opts, @cookie_option_keys)}

    %{acc | cookies: acc.cookies ++ clean}
  end
end
