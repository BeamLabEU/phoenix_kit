defmodule PhoenixKit.API.OAuth.Grants do
  @moduledoc """
  Consents: making a grant (and the hidden API key it owns) and ending one.

  ## Making

  `create/4` runs in one transaction: it makes the hidden key
  (`PhoenixKit.API.Keys.create_oauth_key/3`, under the owner's locks, with the key's expiry
  equal to the grant's) and then the grant under the key's uuid. The grant's uuid is generated
  first and written on the key, so the two point at each other without a cycle in the schema.

  ## Ending

  `revoke/2` is the only way a grant ends, and it is also where
  `PhoenixKit.API.Keys.revoke/2` of the hidden key goes. In one transaction it locks, in this
  order and no other (the order of everything that touches these rows, so two paths never wait
  for each other in a circle):

      key (FOR UPDATE)  ->  grant (FOR UPDATE)  ->  tokens

  then marks every token of the grant revoked, the grant, and the key. It does not go through
  `Keys.revoke/2` (that would call back here): `Keys.revoke_oauth_row/2` is the internal step.
  Only `oauth.grant_revoked` is written to the activity feed; the key's own
  `api.key_revoked` is suppressed.

  The refresh and the verification of a token re-read the grant, so a token inserted after the
  revoking statement is dead the moment it is used.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @default_reason "grant_revoked"

  @doc """
  Makes a grant of `client` for the person behind `scope`, and its hidden key.

  `attrs` takes `scopes` (a list of scope names), `expires_at` (required; at most
  `PhoenixKit.API.PersonalKeysConfig.latest_expiry/0`), `resource` (default
  `PhoenixKit.API.OAuth.Resource.resource/0`) and `created_ip`. `opts` is the one of
  `PhoenixKit.API.Keys.create_oauth_key/3`: `impersonated: true | false`, with no default.

  Returns `{:ok, grant, key}`, or the key's refusal (`:forbidden`, `:impersonated`,
  `:invalid_scopes`, `:owner_inactive`, a changeset, ...).
  """
  @spec create(Scope.t() | nil, Client.t(), map(), keyword()) ::
          {:ok, Grant.t(), Key.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create(%Scope{user: %User{uuid: user_uuid}} = scope, %Client{} = client, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    grant_uuid = UUIDv7.generate()
    expires_at = attrs |> Map.get(:expires_at) |> truncate()

    key_attrs = %{
      grant_uuid: grant_uuid,
      client_name: client.client_name || client.client_id,
      scopes: Map.get(attrs, :scopes, []),
      expires_at: expires_at
    }

    repo().transaction(fn ->
      with {:ok, key} <- Keys.create_oauth_key(scope, key_attrs, opts),
           {:ok, grant} <-
             repo().insert(%Grant{
               uuid: grant_uuid,
               user_uuid: user_uuid,
               client_uuid: client.uuid,
               key_uuid: key.uuid,
               resource: Map.get(attrs, :resource) || Resource.resource(),
               scopes: key.scopes,
               expires_at: key.expires_at,
               created_ip: attrs |> Map.get(:created_ip) |> ip_column()
             }) do
        {grant, key}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> case do
      {:ok, {grant, key}} -> {:ok, grant, key}
      {:error, _reason} = error -> error
    end
  end

  def create(_scope, _client, _attrs, opts) when is_list(opts), do: {:error, :forbidden}

  # The column is `varchar(45)` (the longest IPv6 text); a longer value must not abort the
  # consent's transaction with a database error.
  defp ip_column(ip) when is_binary(ip), do: String.slice(ip, 0, 45)
  defp ip_column(_ip), do: nil

  @doc "A grant by its row uuid; `nil` for an unknown or malformed uuid."
  @spec get(term()) :: Grant.t() | nil
  def get(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid), do: repo().get(Grant, uuid), else: nil
  end

  def get(_uuid), do: nil

  @doc """
  Ends a grant (a `Grant` or its uuid): its tokens, the grant and its hidden key, in one
  transaction and in the lock order of the moduledoc. Ending an ended grant changes nothing and
  writes nothing.

  Options: `:actor_uuid` (for the activity entry) and `:reason` (stored on the tokens, default
  `"grant_revoked"`; `"refresh_reuse"` when a stolen refresh token was caught).

  Nothing here authorizes: the caller decides who may end whose grant.
  """
  @spec revoke(Grant.t() | String.t(), keyword()) ::
          {:ok, Grant.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke(grant_or_uuid, opts \\ [])

  def revoke(%Grant{uuid: uuid}, opts), do: revoke(uuid, opts)

  def revoke(uuid, opts) when is_binary(uuid) do
    case get(uuid) do
      %Grant{} = grant -> end_grant(grant, opts)
      nil -> {:error, :not_found}
    end
  end

  def revoke(_grant, _opts), do: {:error, :not_found}

  defp end_grant(%Grant{key_uuid: key_uuid, uuid: uuid}, opts) do
    reason = Keyword.get(opts, :reason, @default_reason)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    repo().transaction(fn ->
      with {:ok, key} <- Keys.lock_oauth_row(key_uuid),
           {:ok, locked} <- lock_grant(uuid),
           :ok <- revoke_tokens(uuid, reason, now),
           {:ok, ended, changed?} <- end_locked(locked, now),
           {:ok, _key} <- Keys.revoke_oauth_row(key, now) do
        {ended, key, changed?}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> case do
      {:ok, {ended, key, changed?}} ->
        Cache.invalidate(key.prefix)
        if changed?, do: log_revoked(ended, key, reason, Keyword.get(opts, :actor_uuid))
        {:ok, ended}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  # Step of `PhoenixKit.API.OAuth.Prune`: removes a consent nobody finished, with its hidden key
  # (which has no history: no token was ever issued). Takes the revoke order, key then grant, and
  # looks again under the locks: a code exchanged a moment ago makes the grant `activated_at`,
  # a code whose life reaches past `cutoff` is not yet abandoned, and a grant with any token is
  # kept. Returns `:deleted` or `:kept`.
  @spec delete_unactivated(String.t(), DateTime.t()) :: :deleted | :kept
  def delete_unactivated(grant_uuid, %DateTime{} = cutoff) do
    repo().transaction(fn ->
      with %Grant{key_uuid: key_uuid} <- get(grant_uuid),
           {:ok, key} <- Keys.lock_oauth_row(key_uuid),
           {:ok, %Grant{activated_at: nil}} <- lock_grant(grant_uuid),
           false <- live_code?(grant_uuid, cutoff),
           false <- has_tokens?(grant_uuid) do
        repo().delete_all(from(k in Key, where: k.uuid == ^key.uuid))
        {:deleted, key.prefix}
      else
        _ -> :kept
      end
    end)
    |> case do
      {:ok, {:deleted, prefix}} ->
        Cache.invalidate(prefix)
        :deleted

      _ ->
        :kept
    end
  end

  # A grant that has issued a token is not abandoned, whatever `activated_at` says: deleting it
  # would take the tokens (and the key their history hangs on) with it.
  defp has_tokens?(grant_uuid),
    do: repo().exists?(from(t in Token, where: t.grant_uuid == ^grant_uuid))

  defp live_code?(grant_uuid, cutoff) do
    repo().exists?(
      from(c in PhoenixKit.API.OAuth.Code,
        where: c.grant_uuid == ^grant_uuid and c.expires_at > ^cutoff
      )
    )
  end

  defp lock_grant(uuid) do
    case repo().one(from(g in Grant, where: g.uuid == ^uuid, lock: "FOR UPDATE")) do
      %Grant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
    end
  end

  # Every token of the grant that is still alive; a token ended earlier keeps its own reason
  # (`retry_superseded`).
  defp revoke_tokens(grant_uuid, reason, now) do
    repo().update_all(
      from(t in Token, where: t.grant_uuid == ^grant_uuid and is_nil(t.revoked_at)),
      set: [revoked_at: now, revoke_reason: reason]
    )

    :ok
  end

  defp end_locked(%Grant{revoked_at: nil} = grant, now) do
    case grant |> Ecto.Changeset.change(revoked_at: now) |> repo().update() do
      {:ok, ended} -> {:ok, ended, true}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp end_locked(%Grant{} = grant, _now), do: {:ok, grant, false}

  # Metadata never holds a token, a hash or a redirect.
  defp log_revoked(%Grant{} = grant, %Key{} = key, reason, actor_uuid) do
    Activity.log("api", "oauth.grant_revoked",
      actor_uuid: actor_uuid,
      resource_type: "oauth_grant",
      resource_uuid: grant.uuid,
      permanent: true,
      metadata: %{
        "client_uuid" => grant.client_uuid,
        "owner_uuid" => grant.user_uuid,
        "key_prefix" => key.prefix,
        "reason" => reason
      }
    )
  end

  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp truncate(other), do: other

  defp repo, do: RepoHelper.repo()
end
