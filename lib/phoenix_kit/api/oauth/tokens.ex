defmodule PhoenixKit.API.OAuth.Tokens do
  @moduledoc """
  OAuth access and refresh tokens: their format, how they are issued, and how an access
  token is verified on a request to the MCP endpoint.

  ## Format

  `pkoa_<43 base64url>` is an access token and `pkor_<43 base64url>` a refresh token: 32
  random bytes, shown once (the token endpoint returns them), and only the SHA-256 of those
  bytes is stored (`PhoenixKit.API.OAuth.Token`), taken together with the kind's prefix, so the
  same secret under `pkoa_` and under `pkor_` is two different hashes and a refresh token can
  never be looked up as an access token (the lookup also filters on the kind). The secret has
  256 bits of entropy, so a fast hash is enough. A token is found by its hash through a unique
  index; there is no prefix to look up.

  ## Verifying

  `verify/2` answers one request. In **one query** it joins the token, its grant and the
  grant's hidden key (all by index), then checks, **on every call and without a cache**:

    1. the token is an unrevoked, unexpired access token;
    2. the grant is not revoked or expired and is for this install's resource
       (`PhoenixKit.API.OAuth.Resource`), and owns this key;
    3. the key is neither revoked nor expired (`PhoenixKit.API.Keys.dead_reason/1`) and its
       owner is active and still holds `api_personal_keys` or `api`
       (`PhoenixKit.API.Keys.active_owner/1`).

  The check of the grant on every call is what ends a token the moment its grant is revoked,
  whatever else a refresh was doing at the time. The `PhoenixKit.API.Keys.Cache` is not read:
  a revocation is effective on the next request on every node.

  The actor is the hidden key's (`PhoenixKit.API.Keys.actor/3`: the rate limit, the
  confirmations and the activity of API keys work unchanged) and its scopes are

      the grant's scopes ∩ what the owner may do right now

  so taking a permission from the owner's role stops the token at the next request.
  Errors are the reasons `PhoenixKit.API.Keys.verify/2` gives, plus `:expired` for a token (or
  grant) whose time is up, which is the normal end of an access token's hour:
  `PhoenixKit.API.Auth` does not count it against the pre-authentication bucket.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.RepoHelper

  @access_prefix "pkoa_"
  @refresh_prefix "pkor_"
  @secret_bytes 32
  @pattern ~r/\A(pkoa|pkor)_([A-Za-z0-9_-]{43})\z/
  @max_token_length 64

  @type kind :: :access | :refresh

  @doc "The text every access token starts with."
  @spec access_prefix() :: String.t()
  def access_prefix, do: @access_prefix

  @doc "Whether `token` is written like an access token (`pkoa_...`); the secret is not looked at."
  @spec access_token?(term()) :: boolean()
  def access_token?(token) when is_binary(token), do: String.starts_with?(token, @access_prefix)
  def access_token?(_token), do: false

  @doc """
  A new token of `kind`: `{token, hash}`. Store the hash; give the token out once.
  """
  @spec generate(kind()) :: {token :: String.t(), hash :: binary()}
  def generate(kind) when kind in [:access, :refresh] do
    secret = :crypto.strong_rand_bytes(@secret_bytes)
    {prefix(kind) <> Base.url_encode64(secret, padding: false), hash(kind, secret)}
  end

  @doc """
  Splits a presented token into its kind and the hash of its secret; `:error` for anything
  that is not canonical (wrong length, another scheme, a secret that is not exactly 32 bytes,
  a non-canonical encoding of it).
  """
  @spec parse(term()) :: {:ok, kind(), binary()} | :error
  def parse(token) when is_binary(token) and byte_size(token) <= @max_token_length do
    with [_, scheme, secret_text] <- Regex.run(@pattern, token),
         {:ok, secret} <- Base.url_decode64(secret_text, padding: false),
         @secret_bytes <- byte_size(secret),
         true <- Base.url_encode64(secret, padding: false) == secret_text do
      kind = kind_of(scheme)
      {:ok, kind, hash(kind, secret)}
    else
      _ -> :error
    end
  end

  def parse(_token), do: :error

  @doc "SHA-256 of the kind's prefix and the raw secret bytes."
  @spec hash(kind(), binary()) :: binary()
  def hash(kind, secret) when kind in [:access, :refresh] and is_binary(secret),
    do: :crypto.hash(:sha256, [prefix(kind), secret])

  @doc """
  Issues a token of `kind` for `grant` and returns it once: `{:ok, token, row}`.

  Options: `:expires_at` (default: an access token lives `Config.oauth_access_ttl_seconds/0`, a
  refresh token as long as the grant; neither outlives the grant), `:family` (the rotation
  chain; a new one by default) and `:parent_uuid` (the refresh token this one replaced).
  """
  @spec issue(Grant.t(), kind(), keyword()) :: {:ok, String.t(), Token.t()} | {:error, term()}
  def issue(%Grant{} = grant, kind, opts \\ []) when kind in [:access, :refresh] do
    {token, hash} = generate(kind)

    row = %Token{
      token_hash: hash,
      kind: Atom.to_string(kind),
      grant_uuid: grant.uuid,
      family: Keyword.get_lazy(opts, :family, &UUIDv7.generate/0),
      parent_uuid: Keyword.get(opts, :parent_uuid),
      expires_at:
        opts |> Keyword.get_lazy(:expires_at, fn -> default_expiry(kind, grant) end) |> truncate()
    }

    case repo().insert(row) do
      {:ok, row} -> {:ok, token, row}
      {:error, _changeset} = error -> error
    end
  end

  defp default_expiry(:access, %Grant{expires_at: grant_end}) do
    ttl_end = DateTime.add(DateTime.utc_now(), Config.oauth_access_ttl_seconds(), :second)
    Enum.min([ttl_end, grant_end], DateTime)
  end

  defp default_expiry(:refresh, %Grant{expires_at: grant_end}), do: grant_end

  @doc """
  Verifies an access token presented from `ip` and returns the `PhoenixKit.API.Actor` of its
  grant's key, or the reason it is refused. Never raises on bad input.
  """
  @spec verify(term(), String.t() | nil) ::
          {:ok, Actor.t()}
          | {:error,
             :invalid_token
             | :revoked
             | :expired
             | :resource_changed
             | :owner_inactive
             | :personal_keys_not_allowed}
  def verify(token, ip) do
    with {:ok, :access, hash} <- parse(token),
         {:ok, {row, grant, key}} <- load(hash),
         :ok <- check_token(row),
         :ok <- check_grant(grant, key),
         :ok <- check_key(key),
         {:ok, actor} <- Keys.active_actor(key, ip) do
      touch_last_used(grant)
      {:ok, narrow(actor, grant)}
    else
      :error -> {:error, :invalid_token}
      {:ok, :refresh, _hash} -> {:error, :invalid_token}
      {:error, _reason} = error -> error
    end
  end

  # One query: the token, its grant and the grant's hidden key.
  defp load(hash) do
    row =
      repo().one(
        from(t in Token,
          join: g in Grant,
          on: g.uuid == t.grant_uuid,
          join: k in Key,
          on: k.uuid == g.key_uuid,
          where: t.token_hash == ^hash and t.kind == "access",
          select: {t, g, k}
        )
      )

    if row, do: {:ok, row}, else: {:error, :invalid_token}
  end

  defp check_token(%Token{revoked_at: revoked_at, expires_at: expires_at}) do
    cond do
      reached?(revoked_at) -> {:error, :revoked}
      reached?(expires_at) -> {:error, :expired}
      true -> :ok
    end
  end

  defp check_grant(%Grant{} = grant, %Key{} = key) do
    cond do
      key.oauth_grant_uuid != grant.uuid -> {:error, :invalid_token}
      reached?(grant.revoked_at) -> {:error, :revoked}
      reached?(grant.expires_at) -> {:error, :expired}
      not Resource.matches?(grant.resource) -> {:error, :resource_changed}
      true -> :ok
    end
  end

  defp check_key(%Key{} = key) do
    case Keys.dead_reason(key) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  # The key already carries the grant's scopes; the filter keeps the grant the one authority.
  defp narrow(%Actor{scopes: scopes} = actor, %Grant{scopes: granted}),
    do: %{actor | scopes: Enum.filter(scopes, &(&1 in granted))}

  # At most once a minute per grant (the window of `Keys.Cache.touch_last_used?/1`); a failed
  # write must not fail the request.
  defp touch_last_used(%Grant{uuid: uuid}) do
    if Cache.touch_last_used?(uuid) do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      repo().update_all(from(g in Grant, where: g.uuid == ^uuid), set: [last_used_at: now])
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp reached?(nil), do: false
  defp reached?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp kind_of("pkoa"), do: :access
  defp kind_of("pkor"), do: :refresh

  defp prefix(:access), do: @access_prefix
  defp prefix(:refresh), do: @refresh_prefix

  defp repo, do: RepoHelper.repo()
end
