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
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Input
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @default_reason "grant_revoked"

  @doc """
  Makes a grant of `client` for the person behind `scope`, and its hidden key.

  `attrs` takes `scopes` (a list of scope names), `client_name` (the name the hidden key gets; the
  client's own name by default; text the table cannot hold - a NUL byte, bytes that are not
  UTF-8 - is refused as `:invalid_client_name`), `expires_at` (required; at most
  `PhoenixKit.API.PersonalKeysConfig.latest_expiry/0`), `resource` (default
  `PhoenixKit.API.OAuth.Resource.resource/0`) and `created_ip`. `opts` is the one of
  `PhoenixKit.API.Keys.create_oauth_key/3`: `impersonated: true | false`, with no default;
  and `ceiling: n`, how many live grants (`count_live/1`) the person may hold at most.

  The ceiling is counted inside the transaction, after the hidden key took the person's
  advisory lock (the one the personal keys use), so two consents that run together cannot both
  pass it. A person at the ceiling gets `{:error, :grant_limit}` and nothing is created.

  Returns `{:ok, grant, key}`, or the key's refusal (`:forbidden`, `:impersonated`,
  `:invalid_scopes`, `:invalid_client_name`, `:owner_inactive`, a changeset, ...), or `:client_gone` when the client was
  deleted in the meantime (nothing is created).
  """
  @spec create(Scope.t() | nil, Client.t(), map(), keyword()) ::
          {:ok, Grant.t(), Key.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create(%Scope{user: %User{}} = scope, %Client{} = client, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    client_name = Map.get(attrs, :client_name) || client.client_name || client.client_id

    if Input.valid?(client_name),
      do: create_valid(scope, client, attrs, client_name, opts),
      else: {:error, :invalid_client_name}
  end

  def create(_scope, _client, _attrs, opts) when is_list(opts), do: {:error, :forbidden}

  defp create_valid(
         %Scope{user: %User{uuid: user_uuid}} = scope,
         client,
         attrs,
         client_name,
         opts
       ) do
    {ceiling, opts} = Keyword.pop(opts, :ceiling)
    grant_uuid = UUIDv7.generate()
    expires_at = attrs |> Map.get(:expires_at) |> truncate()

    key_attrs = %{
      grant_uuid: grant_uuid,
      client_name: client_name,
      scopes: Map.get(attrs, :scopes, []),
      expires_at: expires_at
    }

    repo().transaction(fn ->
      with {:ok, key} <- Keys.create_oauth_key(scope, key_attrs, opts),
           :ok <- check_ceiling(user_uuid, ceiling),
           {:ok, grant} <-
             insert(%Grant{
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

  # A client deleted since the consent screen was shown is an answer (`:client_gone`), not a
  # constraint error: the foreign key is the one place that sees the delete, whatever the
  # earlier read of the client said.
  defp insert(%Grant{} = grant) do
    grant
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:client_uuid)
    |> repo().insert()
    |> case do
      {:ok, grant} ->
        {:ok, grant}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :client_uuid),
          do: {:error, :client_gone},
          else: {:error, changeset}
    end
  end

  # The person's advisory lock is held by now (the hidden key took it), and stays until the
  # transaction ends.
  defp check_ceiling(_user_uuid, nil), do: :ok

  defp check_ceiling(user_uuid, ceiling) when is_integer(ceiling) do
    if count_live(user_uuid) >= ceiling, do: {:error, :grant_limit}, else: :ok
  end

  @doc """
  How many grants of `user_uuid` count against the ceiling: not revoked, not expired, and either
  activated (a code was exchanged) or not yet activated with an authorization code still alive.
  A consent nobody finished stops counting when its code runs out.
  """
  @spec count_live(String.t()) :: non_neg_integer()
  def count_live(user_uuid), do: user_uuid |> live_query() |> repo().aggregate(:count)

  @doc "The grants `count_live/1` counts, with their clients, least recently used first."
  @spec list_live(String.t()) :: [Grant.t()]
  def list_live(user_uuid) do
    from(g in live_query(user_uuid),
      preload: [:client],
      order_by: [asc: fragment("COALESCE(?, ?)", g.last_used_at, g.inserted_at), asc: g.uuid]
    )
    |> repo().all()
  end

  @doc """
  How many grants of the client `client_uuid` are live in the sense of `count_live/1` (activated,
  or a consent whose authorization code is still alive; not revoked, not expired), whoever owns
  them.
  """
  @spec count_live_for_client(String.t()) :: non_neg_integer()
  def count_live_for_client(client_uuid) do
    from(g in Grant, as: :grant, where: g.client_uuid == ^client_uuid)
    |> live()
    |> repo().aggregate(:count)
  end

  @doc """
  `%{client_uuid => count}` of the live grants (in the sense of `count_live/1`) of every client
  that has one, whoever owns them: what `count_live_for_client/1` counts, for a page of clients.
  """
  @spec count_live_by_client() :: %{String.t() => pos_integer()}
  def count_live_by_client do
    from(g in Grant, as: :grant, group_by: g.client_uuid, select: {g.client_uuid, count(g.uuid)})
    |> live()
    |> repo().all()
    |> Map.new()
  end

  defp live_query(user_uuid) do
    from(g in Grant, as: :grant, where: g.user_uuid == ^user_uuid) |> live()
  end

  # `query` has the grant as its named binding `:grant`.
  defp live(query) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    from(g in query,
      where: is_nil(g.revoked_at) and g.expires_at > ^now,
      where:
        not is_nil(g.activated_at) or
          exists(
            from(c in PhoenixKit.API.OAuth.Code,
              where:
                c.grant_uuid == parent_as(:grant).uuid and is_nil(c.used_at) and
                  c.expires_at > ^now
            )
          )
    )
  end

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

  @doc """
  Runs `fun.(grant, key)` in a transaction that holds the grant's locks in the order of the
  moduledoc (the hidden key, then the grant), so it cannot cross a revoke or another exchange.
  The grant is read under the lock: `fun` sees its current state. Returns what the transaction
  returns: `{:ok, fun's value}`, `{:error, reason}` when `fun` rolls back, `{:error, :not_found}`
  when the grant or its key is gone.
  """
  @spec locked(String.t(), (Grant.t(), Key.t() -> term())) :: {:ok, term()} | {:error, term()}
  def locked(grant_uuid, fun) when is_function(fun, 2) do
    repo().transaction(fn ->
      with %Grant{key_uuid: key_uuid} <- get(grant_uuid),
           {:ok, key} <- Keys.lock_oauth_row(key_uuid),
           {:ok, grant} <- lock_grant(grant_uuid) do
        fun.(grant, key)
      else
        nil -> repo().rollback(:not_found)
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  @doc """
  Whether the grant can still be used: not revoked and not expired, and for this install's
  resource (`PhoenixKit.API.OAuth.Resource`).
  """
  @spec live?(Grant.t()) :: boolean()
  def live?(%Grant{} = grant) do
    now = DateTime.utc_now()

    is_nil(grant.revoked_at) and DateTime.compare(grant.expires_at, now) == :gt and
      Resource.matches?(grant.resource)
  end

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
      with true <- past?(cutoff),
           %Grant{key_uuid: key_uuid} <- get(grant_uuid),
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

  @doc false
  # Step of `PhoenixKit.API.OAuth.Prune`: removes a grant that is over (revoked, or past its
  # `expires_at`) before `cutoff` with its hidden key, and with it - by the tables' cascades -
  # its tokens and codes. A key that has confirmations is kept: they hang on the key with a
  # cascade, and the approval history would go with it (`Confirm.Prune` removes them on its own
  # schedule, after which the grant becomes deletable). The activity entries stay (they hold no
  # foreign key). Takes the revoke order, key then grant, and looks again under the locks.
  # `cutoff` must not be in the future. Returns `:deleted` or `:kept`.
  @spec delete_ended(String.t(), DateTime.t()) :: :deleted | :kept
  def delete_ended(grant_uuid, %DateTime{} = cutoff) do
    repo().transaction(fn ->
      with true <- past?(cutoff),
           %Grant{key_uuid: key_uuid} <- get(grant_uuid),
           {:ok, key} <- Keys.lock_oauth_row(key_uuid),
           {:ok, %Grant{} = grant} <- lock_grant(grant_uuid),
           true <- ended_before?(grant, cutoff),
           true <- key.oauth_grant_uuid == grant.uuid,
           false <- has_confirmations?(key.uuid) do
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

  defp past?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp has_confirmations?(key_uuid),
    do: repo().exists?(from(c in Confirmation, where: c.actor_key_uuid == ^key_uuid))

  defp ended_before?(%Grant{revoked_at: revoked_at, expires_at: expires_at}, cutoff) do
    Enum.any?([revoked_at, expires_at], &(&1 != nil and DateTime.compare(&1, cutoff) == :lt))
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
