defmodule PhoenixKit.Users.ManagedOrganizations.Sessions do
  @moduledoc false

  import Ecto.Query

  alias PhoenixKit.Activity
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations.Locks
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @typedoc """
  Why entering was refused: organization accounts are off, the session to enter from is
  gone or its email is not confirmed while that is required, too many entries, the person has no link to it (a company that does not exist
  answers the same, so the reason never tells one apart), or it is not managed by its
  people or is deactivated (told only to someone linked to it).
  """
  @type refusal ::
          :organization_accounts_disabled
          | :session_gone
          | :unconfirmed
          | :rate_limit_exceeded
          | :no_link
          | :organization_not_managed
          | :organization_inactive

  @doc """
  Enters `organization_uuid` from the person session `root_token`. `opts`:
  `:impersonated_by` — the uuid of whoever signed in as that person, recorded on the
  `organization.entered` and `organization.enter_refused` entries.
  """
  @spec enter(String.t(), term(), String.t() | nil, keyword()) ::
          {:ok, %{token: binary(), user: User.t()}} | {:error, refusal()}
  def enter(root_token, organization_uuid, previous_token \\ nil, opts \\ []) do
    with :ok <- accounts_on(),
         {:ok, root} <- person_session(root_token),
         :ok <- RateLimiter.check_organization_enter_rate_limit(root.user_uuid) do
      result = enter_locked(root, organization_uuid, previous_token, opts)

      with {:error, reason} <- result,
           do: log_refusal(root.user_uuid, organization_uuid, reason, opts)

      result
    end
  end

  defp accounts_on do
    if Auth.organization_accounts_enabled?(),
      do: :ok,
      else: {:error, :organization_accounts_disabled}
  end

  defp person_session(token) do
    with %UserToken{} = root <- token_row(token),
         {:ok, %{user: %User{account_type: "person", managed_by_members: false}}} <-
           SessionRef.scope_for_session(root.uuid, root.user_uuid) do
      {:ok, root}
    else
      {:error, :unconfirmed} -> {:error, :unconfirmed}
      _ -> {:error, :session_gone}
    end
  end

  defp enter_locked(root, uuid, _previous, opts) do
    Revocation.transaction(fn ->
      unless UUIDUtils.valid?(uuid), do: RepoHelper.repo().rollback(:no_link)

      org =
        case Locks.users!([uuid]) do
          [%User{account_type: "organization"} = org] -> org
          _ -> RepoHelper.repo().rollback(:no_link)
        end

      Locks.users!([root.user_uuid], "FOR KEY SHARE")
      lock_root!(root)
      grant = lock_grant!(org, root.user_uuid)

      require_root!(root)

      unless org.managed_by_members, do: RepoHelper.repo().rollback(:organization_not_managed)
      unless org.is_active, do: RepoHelper.repo().rollback(:organization_inactive)

      reuse_or_mint(root, org, grant, opts)
    end)
  end

  defp require_root!(root) do
    case SessionRef.scope_for_session(root.uuid, root.user_uuid) do
      {:ok, %{user: %User{account_type: "person", managed_by_members: false}}} -> :ok
      _ -> RepoHelper.repo().rollback(:session_gone)
    end
  end

  defp current_session(root, org, grant) do
    RepoHelper.repo().one(
      from(t in UserToken,
        where:
          t.acting_session_uuid == ^root.uuid and t.user_uuid == ^org.uuid and
            t.organization_manager_uuid == ^grant.uuid and t.context == "session",
        where: t.inserted_at > ago(60, "day"),
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      log: false
    )
  end

  defp reuse_or_mint(root, org, grant, opts) do
    existing = current_session(root, org, grant)
    previous = existing && existing.token
    existing = if existing, do: session_user(existing.uuid)

    case existing do
      %User{uuid: org_uuid, acting_session_uuid: parent} = user
      when org_uuid == org.uuid and parent == root.uuid ->
        delete_bound(root, previous)
        %{token: previous, user: user}

      _ ->
        mint(root, org, grant, opts)
    end
  end

  defp mint(root, org, grant, opts) do
    delete_bound(root, nil)
    {token, row} = UserToken.build_session_token(org)

    stored =
      row
      |> Ecto.Changeset.change(
        acting_session_uuid: root.uuid,
        organization_manager_uuid: grant.uuid,
        ip_address: root.ip_address,
        user_agent_hash: root.user_agent_hash,
        browser: root.browser,
        os: root.os
      )
      |> RepoHelper.repo().insert!(log: false)

    Activity.log(%{
      action: "organization.entered",
      module: "users",
      mode: "manual",
      actor_uuid: org.uuid,
      resource_type: "organization",
      resource_uuid: org.uuid,
      metadata:
        with_impersonator(
          %{
            "acting_user_uuid" => root.user_uuid,
            "organization_name" => org.organization_name
          },
          opts
        )
    })

    user = session_user(stored.uuid) || RepoHelper.repo().rollback(:forbidden)
    %{token: token, user: user}
  end

  def leave(root_token, _organization_token) do
    Revocation.transaction(fn ->
      if root = token_row(root_token) do
        lock_root!(root)
        delete_bound(root, nil)
      end

      :ok
    end)
  end

  def list_for(person_uuid) do
    RepoHelper.repo().all(
      from(m in OrganizationManager,
        join: org in User,
        on: org.uuid == m.organization_uuid,
        where: m.user_uuid == ^person_uuid and org.managed_by_members and org.is_active,
        order_by: [org.organization_name, org.uuid],
        select: %{uuid: org.uuid, name: org.organization_name}
      )
    )
  end

  defp token_row(token) when is_binary(token) do
    RepoHelper.repo().one(
      from(t in UserToken, where: t.token == ^token and t.context == "session"),
      log: false
    )
  end

  defp token_row(_), do: nil

  defp session_user(uuid) do
    {:ok, query} = UserToken.verify_session_token_uuid_query(uuid)
    RepoHelper.repo().one(query, log: false)
  end

  defp lock_root!(root) do
    case RepoHelper.repo().one(
           from(t in UserToken, where: t.uuid == ^root.uuid, lock: "FOR NO KEY UPDATE"),
           log: false
         ) do
      %UserToken{acting_session_uuid: nil, organization_manager_uuid: nil} -> :ok
      _ -> RepoHelper.repo().rollback(:session_gone)
    end
  end

  defp lock_grant!(org, person_uuid) do
    RepoHelper.repo().one(
      from(m in OrganizationManager,
        where: m.organization_uuid == ^org.uuid and m.user_uuid == ^person_uuid,
        lock: "FOR KEY SHARE"
      )
    ) || RepoHelper.repo().rollback(:no_link)
  end

  defp delete_bound(root, except) do
    query =
      from(t in UserToken, where: t.context == "session" and t.acting_session_uuid == ^root.uuid)

    query = if except, do: from(t in query, where: t.token != ^except), else: query
    Revocation.delete_all(query)
  end

  defp log_refusal(person_uuid, org_uuid, reason, opts) do
    Activity.log(%{
      action: "organization.enter_refused",
      module: "users",
      mode: "manual",
      actor_uuid: person_uuid,
      metadata:
        with_impersonator(
          %{
            "organization_uuid" => if(UUIDUtils.valid?(org_uuid), do: org_uuid),
            "reason" => Atom.to_string(reason)
          },
          opts
        )
    })
  end

  defp with_impersonator(metadata, opts) do
    case Keyword.get(opts, :impersonated_by) do
      uuid when is_binary(uuid) -> Map.put(metadata, "impersonated_by_uuid", uuid)
      _ -> metadata
    end
  end
end
