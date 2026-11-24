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
       token row bound to the target host, to that nonce hash, to the proof, which the row's
       unique index spends (one source cookie, one row), and to the session the account is signed in
       with, refusing a handoff that carries nothing (no account and no snapshot), and sends the
       browser to the target.
    4. `redeem` on the **target**: consumes the row in one statement and finds the source session
       alive (`redeem/4`), lets the modules apply their payload, signs the account in
       through the normal log-in path with that session's age, and redirects to the requested
       path.

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
  of its own, all the modules of a round at the same time under one deadline (`snapshots/3`,
  `apply_payload/4`); what a module is handed has the kit's auth material removed
  (`hook_context/4`); what it answers is validated (`apply_payload/4`). The contract is in the
  callbacks' docs and the guide.

  ## The token

  32 random bytes, base64url, never stored (only its SHA-256). It lives `ttl_seconds/0` seconds, is
  single use, and is redeemable only on the host it was minted for, by the browser whose nonce it
  was minted for, and — softly — by the same `User-Agent`. A row dies with the sessions of its
  account (`revoke_for_users/1`, called by `PhoenixKit.Users.Sessions.Revocation`), and expired
  rows are deleted (`prune_expired/1`: by `PhoenixKit.Handoff.PruneWorker` daily, and a few at every
  mint).

  ## The session it continues

  A handoff is the same sign-in on another domain, not a new one. A row for an account names the
  session it was minted from (`source_session_uuid`), and `redeem/4` looks that session up: it must
  still exist and be unexpired, or the redeem fails. The session the target signs in is built from
  it (`PhoenixKitWeb.Users.Auth.log_in_user/4`, `:inherit_session`): it has the **same
  `inserted_at`**, so every rule that reads a session's age (the passkey freshness window, the 60
  days a session lives, the sessions list) sees the sign-in that really happened, and the same
  acting role. A guest's row has no session and is exempt. The look-up is repeated by the
  controller right before it signs the visitor in, after the modules' apply hooks.
  """

  import Ecto.Query

  alias PhoenixKit.Handoff.Token
  alias PhoenixKit.HeaderWidget
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
  @source_session_keys [:user_uuid, :inserted_at, :active_role_uuid]
  @proof_index :phoenix_kit_handoff_tokens_source_proof_hash_index
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
  The members of `codes` (language codes, as `host_for_language/2` takes them) a page served on
  `current_host` (a `conn.host`: the host name, no port) can hand a visitor over to: the page's
  host is one of the site's (`start` refuses any other), and the language has a host of its own
  that is not the page's. A language that shares the page's host (a sibling dialect, or the
  page's own language) is not among them, and neither is any language while the site has only
  one host (the handoff is not `enabled?/0`).

  A map, `%{code => kind}`. `kind` says what the destination path on the language's domain must
  look like. `:host_language` when `code` is the language that domain serves without a locale
  segment: `language_for_host/2`, the first enabled language the resolver maps to that host (the
  host application must serve that one at a path with no segment). `:dialect` for any other
  language of that host (a sibling dialect, or a different language the resolver maps to the same
  host): the destination keeps `code`'s own segment to land on its page.

  The site is read once whatever the length of `codes` (`host_languages/0`), and not at all when
  `current_host` is not a binary or there is nothing to choose between: a caller with no host to
  offer asks the resolver nothing.
  """
  @spec hand_over_languages(term(), [String.t()]) :: %{String.t() => :host_language | :dialect}
  def hand_over_languages(current_host, [_, _ | _] = codes) when is_binary(current_host) do
    languages = host_languages()
    hosts = languages |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    case own_host(current_host, hosts) do
      source when is_binary(source) ->
        for code <- codes,
            host = host_for_language(code, languages),
            host_name(host) != host_name(source),
            into: %{},
            do: {code, destination_kind(code, host, languages)}

      nil ->
        %{}
    end
  end

  def hand_over_languages(_current_host, _codes), do: %{}

  defp destination_kind(code, host, languages) do
    served = language_for_host(host_name(host), languages)

    if is_binary(served) and String.downcase(served) == String.downcase(code),
      do: :host_language,
      else: :dialect
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
  (falling back to its base code when the dialect itself has no entry), in language order. Each
  distinct language needed is asked of the resolver once. `allowed_hosts/0`, `language_for_host/2`
  and `host_for_language/2` read this list; a caller that needs several asks once (`resolve/0`).
  """
  @spec host_languages() :: [{String.t(), String.t()}]
  def host_languages do
    codes = Languages.enabled_locale_codes()

    exact =
      codes
      |> Enum.uniq()
      |> Map.new(&{&1, Routes.canonical_host(&1)})

    bases =
      codes
      |> Enum.filter(&is_nil(Map.fetch!(exact, &1)))
      |> Enum.map(&DialectMapper.extract_base/1)
      |> Enum.reject(&Map.has_key?(exact, &1))
      |> Enum.uniq()
      |> Map.new(&{&1, Routes.canonical_host(&1)})

    hosts = Map.merge(bases, exact)

    for code <- codes,
        host = Map.get(exact, code) || Map.get(hosts, DialectMapper.extract_base(code)),
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

  def allowed_host(host, hosts) do
    if host = host_param(host), do: Enum.find(hosts || allowed_hosts(), &(&1 == host))
  end

  @doc """
  `host` (a request parameter, untrusted) as a candidate for `allowed_host/2`: trimmed and
  downcased, or `nil` when it is not a binary of 1 to 255 bytes. A cheap shape check that asks no
  resolver, so a request can be refused on it before the allow-list is read.
  """
  @spec host_param(term()) :: String.t() | nil
  def host_param(host) when is_binary(host) and byte_size(host) <= 255 do
    case host |> String.trim() |> String.downcase() do
      "" -> nil
      host -> host
    end
  end

  def host_param(_host), do: nil

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

  @doc """
  The allowed host that serves `lang` (an enabled language code such as `"de-DE"`, or a base code
  such as `"de"`), or `nil` (`languages` is `host_languages/0`, when already read).

  Matches an enabled code first (case-insensitively), then a bare base code against enabled
  languages sharing that base (when several dialects of that base are enabled on different hosts,
  the resolver's own answer for `lang` breaks the tie when it names one of them).
  """
  @spec host_for_language(term(), [{String.t(), String.t()}] | nil) :: String.t() | nil
  def host_for_language(lang, languages \\ nil)

  def host_for_language(lang, languages) when is_binary(lang) do
    languages = languages || host_languages()
    downcased = String.downcase(lang)

    case Enum.find_value(languages, fn {code, host} ->
           if String.downcase(code) == downcased, do: host
         end) do
      host when is_binary(host) ->
        host

      nil ->
        host_for_base_language(lang, downcased, languages)
    end
  end

  def host_for_language(_lang, _languages), do: nil

  defp host_for_base_language(lang, downcased, languages) do
    if String.contains?(downcased, "-") do
      nil
    else
      matches =
        for {code, host} <- languages,
            String.downcase(DialectMapper.extract_base(code)) == downcased,
            do: host

      case Enum.uniq(matches) do
        [] -> nil
        [host] -> host
        many -> allowed_host(Routes.canonical_host(lang), many) || hd(many)
      end
    end
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

  @doc """
  Whether a handoff row already holds the source proof `hash` (the 32 bytes
  `decode_source_proof/1` gives): an indexed existence check, which the controller asks before it
  asks any module for a snapshot, so a replay costs no snapshot round on any node. It is an
  optimisation only: the unique index `mint/1` writes under is the authority, and a database that
  cannot answer is `false`, left to the insert to refuse.
  """
  @spec source_proof_used?(term()) :: boolean()
  def source_proof_used?(hash) when is_binary(hash) and byte_size(hash) == 32 do
    RepoHelper.repo().exists?(from(t in Token, where: t.source_proof_hash == ^hash), log: false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def source_proof_used?(_hash), do: false

  @doc """
  The 32-byte hash an `s` parameter carries (what `mint/1` takes as `:source_proof_hash`), or
  `:error`. The same decoding as `decode_nonce_hash/1`.
  """
  @spec decode_source_proof(term()) :: {:ok, binary()} | :error
  def decode_source_proof(param), do: decode_nonce_hash(param)

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
  `:user_uuid`, `:payload` (a JSON-safe map), `:user_agent` (a header value, kept as a hash) and
  `:source_proof_hash` (the 32 bytes `decode_source_proof/1` gives).

  `:source_session_uuid`, the `uuid` of the session token the account is signed in with, is
  **required with `:user_uuid`** (and refused without it): the row continues that session, see
  `redeem/4`. A row with an account and no session is `{:error, :invalid_attrs}`.

  `:source_proof_hash` makes the proof of a `start` **single use**: it is stored under a unique
  index, so a second mint with a proof that already has a row is `{:error, :proof_used}` and writes
  nothing. That holds across nodes and restarts, which a counter in memory cannot promise. A mint
  that is refused before the insert (a bad path, nothing to carry) does not spend it.

  A handoff that carries nothing, no `:user_uuid` and an empty `:payload`, is refused
  (`{:error, :nothing_to_carry}`): there is nothing to hand over, and no row is written. Each
  successful mint also deletes a few rows that expired a while ago (`prune_expired/1`).

  ## Transactions

  `mint/1` may be called inside a transaction of the caller's, and does not abort it: **inside
  one** (`Repo.in_transaction?/0`) the insert, and the prune after it, run in a savepoint, so a
  duplicate proof (`{:error, :proof_used}`), any other database error (`{:error, :failed}`) and a
  failed prune roll back to the savepoint alone and the caller's transaction stays usable. A
  successful mint is **part of the caller's transaction**: the row commits or rolls back with it,
  while the token it returned was never stored anywhere else (a rollback leaves a token with no
  row, which redeems as nothing). **Outside one** it is plain statements, each its own
  transaction. The controller calls it outside any.
  """
  @spec mint(map()) :: {:ok, String.t()} | {:error, term()}
  def mint(%{target_host: host, redirect_path: path, browser_nonce_hash: nonce_hash} = attrs)
      when is_binary(host) and host != "" and is_binary(nonce_hash) and
             byte_size(nonce_hash) == 32 do
    cond do
      is_nil(valid_to(path)) -> {:error, :invalid_path}
      not valid_proof_hash?(Map.get(attrs, :source_proof_hash)) -> {:error, :invalid_attrs}
      not valid_source_session?(attrs) -> {:error, :invalid_attrs}
      nothing_to_carry?(attrs) -> {:error, :nothing_to_carry}
      true -> insert_token(attrs, host, path, nonce_hash)
    end
  end

  def mint(_attrs), do: {:error, :invalid_attrs}

  defp valid_proof_hash?(nil), do: true
  defp valid_proof_hash?(hash), do: is_binary(hash) and byte_size(hash) == 32

  # An account is carried with the session it is signed in with, and only an account has one.
  defp valid_source_session?(attrs) do
    case {Map.get(attrs, :user_uuid), Map.get(attrs, :source_session_uuid)} do
      {nil, nil} -> true
      {nil, _session} -> false
      {_user, session} -> is_binary(session) and match?({:ok, _}, Ecto.UUID.cast(session))
    end
  end

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
      source_proof_hash: Map.get(attrs, :source_proof_hash),
      source_session_uuid: Map.get(attrs, :source_session_uuid),
      expires_at: DateTime.add(now, @ttl_seconds, :second)
    }

    changeset =
      row
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:source_proof_hash, name: @proof_index)

    repo = RepoHelper.repo()

    case repo.insert(changeset, savepoint_options(repo)) do
      {:ok, _row} ->
        prune_a_few()
        {:ok, token}

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :source_proof_hash), do: {:error, :proof_used}, else: error
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

  A row for an account then needs the session it was minted from (`:source_session_uuid`) to be
  alive: `Auth.get_live_session/2` finds it (it exists, is unexpired, is that account's), and what
  `log_in_user/4` needs of it to take its age and acting role over is returned in the row's virtual
  `:source_session`: a map of `:user_uuid`, `:inserted_at` and `:active_role_uuid`, never the
  session token. Without a live session the redeem is `:error` (the token stays spent). A guest's
  row has no session and gets `source_session: nil`.

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
      {1, [row]} -> with_source_session(row)
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

  @doc false
  @spec inherited_session(map()) :: map()
  def inherited_session(%{} = session), do: Map.take(session, @source_session_keys)

  # The row is spent already: a session that is gone ends the handoff, and the token with it.
  defp with_source_session(%Token{user_uuid: nil} = row), do: {:ok, row}
  defp with_source_session(%Token{source_session_uuid: nil}), do: :error

  defp with_source_session(%Token{} = row) do
    case Auth.get_live_session(row.source_session_uuid, row.user_uuid) do
      nil -> :error
      session -> {:ok, %{row | source_session: inherited_session(session)}}
    end
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

    repo = RepoHelper.repo()
    {count, _} = repo.delete_all(query, savepoint_options(repo))
    count
  end

  @doc """
  Deletes the unused handoffs of the accounts `user_uuids`. Called, in the same transaction, by
  every deletion of a session token (`PhoenixKit.Users.Sessions.Revocation`): a handoff in flight
  must not outlive the sessions of the account it signs in. Returns how many.

  A host that runs this code before migration V236 has no table to delete from, and a session must
  end whatever the migration state: the delete then answers `0`. Postgres aborts a transaction on
  an error, so **inside a transaction** (`Repo.in_transaction?/0`, the way `Revocation` calls it)
  the delete runs in a savepoint (`mode: :savepoint`), which the error rolls back alone, and the
  surrounding transaction stays usable. **Outside one** there is nothing to abort and no
  transaction to put a savepoint in (asking for one is an error of its own), so it is a plain
  statement, with the same answer for a missing table. Any other error is raised.
  """
  @spec revoke_for_users([String.t()]) :: non_neg_integer()
  def revoke_for_users([]), do: 0

  def revoke_for_users(user_uuids) when is_list(user_uuids) do
    repo = RepoHelper.repo()
    query = from(t in Token, where: t.user_uuid in ^user_uuids and is_nil(t.used_at))

    {count, _} = repo.delete_all(query, [{:log, false} | savepoint_options(repo)])
    count
  rescue
    error in Postgrex.Error ->
      if table_missing?(error) do
        Logger.debug("[Handoff] no handoff table yet (migration V236 pending), nothing to revoke")
        0
      else
        reraise error, __STACKTRACE__
      end
  end

  # A statement of a transaction that a failure must not abort goes in a savepoint, which needs
  # a transaction to sit in: outside one it is a plain statement.
  defp savepoint_options(repo) do
    if repo.in_transaction?(), do: [mode: :savepoint], else: []
  end

  defp table_missing?(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: true
  defp table_missing?(_error), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## What a module is handed

  @doc """
  The names (strings) of the session keys a module is never handed: the keys of the cookie
  session that authentication reads (`PhoenixKit.HeaderWidget.reserved_session_keys/0`: the
  signed-in session, the multi-account stack and `phoenix_kit_session_uuid`; the one definition,
  which a header widget's session is held to as well), the website-access unlock and the CSRF
  token. The one list.
  """
  @spec auth_session_keys() :: [String.t()]
  def auth_session_keys do
    HeaderWidget.reserved_session_keys() ++
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
  sockets (a LiveView host declares one: `socket "/live", ..., connect_info: [session: opts]`,
  with `opts` a keyword list or an `{module, function, args}` that returns one). `[]` when it
  cannot be told: the endpoint declares none, or one that cannot be read. That is logged once per
  endpoint, and `hook_context/4` then hands the modules **no cookies at all**, because the
  session cookie (a signed cookie that holds `user_token`) could not be told from any other.
  """
  @spec session_cookie_names(module() | term()) :: [String.t()]
  def session_cookie_names(endpoint) when is_atom(endpoint) and not is_nil(endpoint) do
    names =
      endpoint.__sockets__()
      |> Enum.flat_map(fn {_path, _handler, opts} -> socket_session_keys(opts) end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if names == [], do: warn_session_cookie_unknown(endpoint)
    names
  rescue
    _ ->
      warn_session_cookie_unknown(endpoint)
      []
  end

  def session_cookie_names(_endpoint), do: []

  defp warn_session_cookie_unknown(endpoint) do
    key = {__MODULE__, :session_cookie_unknown, endpoint}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.warning(
        "[Handoff] the session cookie of #{inspect(endpoint)} cannot be told (none of its " <>
          "sockets declares a readable `session:` in connect_info): no cookies are handed to " <>
          "the modules' handoff hooks. Declare it, `connect_info: [session: @session_options]`, " <>
          "to hand them the cookies that are not the session's."
      )
    end

    :ok
  end

  defp warn_cookies_refused(module) do
    key = {__MODULE__, :cookies_refused, module}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.warning(
        "[Handoff] the session cookie of the endpoint cannot be told: the cookies " <>
          "#{inspect(module)} asked to set are refused. Declare the session in the endpoint's " <>
          "socket, `connect_info: [session: @session_options]`, to let modules set cookies."
      )
    end

    :ok
  end

  defp socket_session_keys(opts) when is_list(opts) do
    for transport <- [:websocket, :longpoll],
        transport_opts = Keyword.get(opts, transport),
        is_list(transport_opts),
        {:session, declared} <- List.wrap(Keyword.get(transport_opts, :connect_info)),
        session = session_options(declared),
        is_list(session),
        do: Keyword.get(session, :key)
  end

  defp socket_session_keys(_opts), do: []

  defp session_options(session) when is_list(session), do: session

  defp session_options({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    case apply(module, function, args) do
      session when is_list(session) -> session
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp session_options(_session), do: nil

  @doc """
  The context a hook is handed (`PhoenixKit.Module.handoff_snapshot/1`): `:user_uuid`, `:session`
  and `:cookies`, with every key of `auth_session_keys/0` and every name of `auth_cookie_names/1`
  removed. `opts`: `:session_cookies`, the host's session cookie names (`session_cookie_names/1`).

  **Without a session cookie name `:cookies` is empty**, whatever the request carried: the session
  cookie holds `user_token`, and a cookie that cannot be told from it must not be handed over. A
  host whose endpoint cannot be read loses its modules' cookies, not its sessions.
  """
  @spec hook_context(String.t() | nil, map(), map(), keyword()) :: context()
  def hook_context(user_uuid, session, cookies, opts \\ []) do
    %{
      user_uuid: user_uuid,
      session: Map.drop(session, auth_session_keys()),
      cookies: handed_cookies(cookies, Keyword.get(opts, :session_cookies, []))
    }
  end

  defp handed_cookies(_cookies, []), do: %{}

  defp handed_cookies(cookies, session_cookies),
    do: Map.drop(cookies, auth_cookie_names(session_cookies))

  ## Module hooks

  @doc """
  Asks every enabled module for a snapshot (`PhoenixKit.Module.handoff_snapshot/1`).

  Returns `%{module_key => snapshot}` for the modules that answered with a non-empty map that is
  JSON-safe and small enough; the snapshots are normalised the way the database returns them
  (string keys). A module that raises, exits, throws, does not answer within `:timeout` (default
  #{@snapshot_timeout_ms} ms) or answers anything else is logged and left out. The modules are
  asked **at the same time** and share that one deadline for the call, so many modules cannot add
  up; one still running at the deadline is killed. `modules` defaults to the enabled modules
  (`ModuleRegistry.enabled_modules/0`: a disabled module is never asked).
  """
  @spec snapshots(context(), [module()] | nil, keyword()) :: %{String.t() => map()}
  def snapshots(context, modules \\ nil, opts \\ []) when is_map(context) do
    timeout = Keyword.get(opts, :timeout, @snapshot_timeout_ms)

    calls =
      for module <- hook_modules(modules, :handoff_snapshot, 1),
          {:ok, key} <- [module_key(module)],
          do: {{key, module}, module, :handoff_snapshot, [context]}

    calls
    |> call_hooks(timeout)
    |> Enum.reduce(%{}, fn {{key, module}, result}, acc ->
      with {:ok, snapshot} <- result,
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
  character boundary; at most #{@max_cookies} cookies), in the order of the modules. A module that
  fails, answers with an error or does not answer within `:timeout` (default
  #{@apply_timeout_ms} ms) is logged and ignored, and so is anything invalid in what it answered.
  The modules run **at the same time** and share that one deadline, as for `snapshots/3`. This
  function does not raise.

  Options: `:timeout`, `:scheme` (`scheme/0`, default `"https"`: it decides the default of a
  cookie's `Secure` flag) and `:session_cookies`, the host's session cookie names
  (`session_cookie_names/1`), which are reserved with the rest of `auth_cookie_names/1`: a module
  may not set any of them. **Without a session cookie name (the default, and `[]`) every cookie a
  module asks for is refused**, whatever its name, and that is logged once per module: the session
  cookie could not be told from any other, and a module must not be able to set it. This is the
  write side of what `hook_context/4` does on the read side.
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
      session_cookies: Keyword.get(opts, :session_cookies, []),
      reserved: opts |> Keyword.get(:session_cookies, []) |> auth_cookie_names()
    }

    calls =
      for module <- hook_modules(modules, :handoff_apply, 2),
          {:ok, key} <- [module_key(module)],
          {:ok, snapshot} when is_map(snapshot) <- [Map.fetch(payload, key)],
          do: {module, module, :handoff_apply, [context, snapshot]}

    calls
    |> call_hooks(settings.timeout)
    |> Enum.reduce(%{notices: [], cookies: []}, fn {module, result}, acc ->
      with {:ok, result} <- result,
           {:ok, effects} <- sanitize_result(module, result, settings) do
        merge_effects(acc, effects)
      else
        _ -> acc
      end
    end)
    |> limit_effects()
  rescue
    error ->
      Logger.error("[Handoff] apply_payload failed: #{inspect(error.__struct__)}")
      %{notices: [], cookies: []}
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

  # Every hook of a call site runs in a task of its own, supervised but not linked, all started
  # at once and all given the one `timeout` (in ms) from there: a module that hangs cannot hold the
  # visitor's request, and M modules cost one deadline, not M. A task still running at the
  # deadline is killed (`Task.shutdown/2`) and logged.
  #
  # The task inherits the caller's `$callers` (so the Ecto sandbox of a test follows it) and its
  # Gettext locale. It does NOT have the rest of the request's process state: not the process
  # dictionary, so no Logger metadata (the request id), no per-request dynamic repo or prefix.
  # Only the module and the kind of failure are logged, never a message: those can carry what the
  # module was handed. The failure is caught inside the task, because an uncaught one is logged by
  # the runtime with its message.
  #
  # `calls` are `{id, module, function, args}`; the answer is `[{id, {:ok, value} | :error}]`
  # in the same order.
  defp call_hooks([], _timeout), do: []

  defp call_hooks(calls, timeout) do
    locales = {Gettext.get_locale(), Gettext.get_locale(PhoenixKitWeb.Gettext)}

    started =
      Enum.map(calls, fn {id, module, function, args} ->
        {id, module, function, start_hook(module, function, args, locales)}
      end)

    yielded =
      for({_id, _module, _function, %Task{} = task} <- started, do: task)
      |> Task.yield_many(timeout)
      |> Map.new()

    for {id, module, function, task} <- started do
      outcome =
        case task do
          :error -> :error
          %Task{} -> hook_outcome(module, function, task, Map.get(yielded, task), timeout)
        end

      {id, outcome}
    end
  end

  defp start_hook(module, function, args, {global_locale, web_locale}) do
    Task.Supervisor.async_nolink(PhoenixKit.TaskSupervisor, fn ->
      Gettext.put_locale(global_locale)
      Gettext.put_locale(PhoenixKitWeb.Gettext, web_locale)
      call_safely(module, function, args)
    end)
  catch
    :exit, _ ->
      Logger.error(
        "[Handoff] #{function} of #{inspect(module)} could not run (no task supervisor)"
      )

      :error
  end

  defp hook_outcome(module, function, task, yielded, timeout) do
    case yielded || Task.shutdown(task, :brutal_kill) do
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

  # With no session cookie name, none: the session cookie (which holds `user_token`) is among the
  # names a module could set, and nothing tells it from the others.
  defp clean_cookies(module, cookies, %{session_cookies: []}) do
    if cookies != [], do: warn_cookies_refused(module)
    []
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
