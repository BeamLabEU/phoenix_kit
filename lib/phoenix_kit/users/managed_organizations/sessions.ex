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

  def enter(root_token, organization_uuid, previous_token \\ nil) do
    with true <- Auth.organization_accounts_enabled?(),
         %UserToken{} = root <- token_row(root_token),
         {:ok, %{user: %User{account_type: "person", managed_by_members: false}}} <-
           SessionRef.scope_for_session(root.uuid, root.user_uuid),
         :ok <- RateLimiter.check_organization_enter_rate_limit(root.user_uuid) do
      result = enter_locked(root, organization_uuid, previous_token)
      if match?({:error, _}, result), do: log_refusal(root.user_uuid, organization_uuid)
      result
    else
      {:error, :rate_limit_exceeded} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp enter_locked(root, uuid, _previous) do
    Revocation.transaction(fn ->
      unless UUIDUtils.valid?(uuid), do: RepoHelper.repo().rollback(:forbidden)
      org = Locks.organization!(uuid)
      Locks.users!([root.user_uuid], "FOR KEY SHARE")
      lock_root!(root)
      grant = lock_grant!(org, root.user_uuid)

      require_root!(root)

      unless org.managed_by_members and org.is_active,
        do: RepoHelper.repo().rollback(:forbidden)

      reuse_or_mint(root, org, grant)
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, _} -> {:error, :forbidden}
    end
  end

  defp require_root!(root) do
    case SessionRef.scope_for_session(root.uuid, root.user_uuid) do
      {:ok, %{user: %User{account_type: "person", managed_by_members: false}}} -> :ok
      _ -> RepoHelper.repo().rollback(:forbidden)
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

  defp reuse_or_mint(root, org, grant) do
    existing = current_session(root, org, grant)
    previous = existing && existing.token
    existing = if existing, do: session_user(existing.uuid)

    case existing do
      %User{uuid: org_uuid, acting_session_uuid: parent} = user
      when org_uuid == org.uuid and parent == root.uuid ->
        delete_bound(root, previous)
        %{token: previous, user: user}

      _ ->
        mint(root, org, grant)
    end
  end

  defp mint(root, org, grant) do
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
      metadata: %{
        "acting_user_uuid" => root.user_uuid,
        "organization_name" => org.organization_name
      }
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
      _ -> RepoHelper.repo().rollback(:forbidden)
    end
  end

  defp lock_grant!(org, person_uuid) do
    RepoHelper.repo().one(
      from(m in OrganizationManager,
        where: m.organization_uuid == ^org.uuid and m.user_uuid == ^person_uuid,
        lock: "FOR KEY SHARE"
      )
    ) || RepoHelper.repo().rollback(:forbidden)
  end

  defp delete_bound(root, except) do
    query =
      from(t in UserToken, where: t.context == "session" and t.acting_session_uuid == ^root.uuid)

    query = if except, do: from(t in query, where: t.token != ^except), else: query
    Revocation.delete_all(query)
  end

  defp log_refusal(person_uuid, org_uuid) do
    Activity.log(%{
      action: "organization.enter_refused",
      module: "users",
      mode: "manual",
      actor_uuid: person_uuid,
      metadata: %{"organization_uuid" => if(UUIDUtils.valid?(org_uuid), do: org_uuid)}
    })
  end
end
