defmodule PhoenixKit.Users.OrganizationManagers do
  @moduledoc """
  Authorized manager lifecycle shared by admin and self-service controls.

  Grant changes and person lifecycle changes share a per-person advisory lock,
  then organization row locks (`FOR NO KEY UPDATE`, uuid order), then user locks.
  Authority and eligibility are re-read while those locks are held. Manager
  additions by a manager will go through invitation acceptance, never a person
  search or this admin-only direct-add function.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.ManagedOrganizations.Locks
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Sessions.Revocation

  @doc "Loads manager controls only for a live own-account administrator or acting manager."
  def details(actor, organization_uuid) do
    Revocation.transaction(fn ->
      org = Locks.organization!(organization_uuid)
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.authorize(org.uuid) |> Locks.value!()

      grants =
        RepoHelper.repo().all(
          from(m in OrganizationManager,
            where: m.organization_uuid == ^org.uuid,
            preload: [:user],
            order_by: m.inserted_at
          )
        )

      invitations = Invitations.list_invitations(org.uuid, kind: :manager)
      %{organization: org, authority: authority, grants: grants, invitations: invitations}
    end)
  end

  def update_contact(actor, organization_uuid, attrs) do
    Revocation.transaction(fn ->
      org = Locks.organization!(organization_uuid)
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      actor |> Actor.authorize(org.uuid) |> Locks.value!()
      unless org.managed_by_members, do: RepoHelper.repo().rollback(:organization_not_managed)
      org |> User.contact_email_changeset(attrs) |> RepoHelper.repo().update() |> Locks.value!()
    end)
  end

  @doc "Admin-only person search; managers add people only by email invitation."
  def search(actor, organization_uuid, term) when is_binary(term) do
    Revocation.transaction(fn ->
      Locks.organization!(organization_uuid)
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      actor |> Actor.admin() |> Locks.value!()

      search_people(term)
    end)
  end

  def search_for_creation(actor, term) when is_binary(term) do
    Revocation.transaction(fn ->
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      actor |> Actor.admin() |> Locks.value!()
      search_people(term)
    end)
  end

  defp search_people(term) do
    pattern =
      "%" <>
        String.replace(String.trim(term), ["%", "_", "\\"], fn char -> "\\" <> char end) <> "%"

    RepoHelper.repo().all(
      from(u in User,
        where: u.account_type == "person" and u.is_active and not u.api_only,
        where:
          ilike(u.email, ^pattern) or ilike(u.first_name, ^pattern) or
            ilike(u.last_name, ^pattern),
        order_by: u.email,
        limit: 10
      )
    )
  end

  def add(actor, organization_uuid, person_uuid) do
    Revocation.transaction(fn ->
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      insert_locked(org, person_uuid, authority)
    end)
  end

  def remove(actor, organization_uuid, person_uuid, opts \\ []) do
    Revocation.transaction(fn ->
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.authorize(organization_uuid) |> Locks.value!()

      unless org.managed_by_members,
        do: RepoHelper.repo().rollback(:organization_not_managed)

      case RepoHelper.repo().get_by(OrganizationManager,
             organization_uuid: org.uuid,
             user_uuid: person_uuid
           ) do
        nil ->
          :ok

        grant ->
          ensure_can_lose!(org, person_uuid, override?(authority, opts))

          Revocation.delete_manager_grants(
            from(m in OrganizationManager, where: m.uuid == ^grant.uuid)
          )

          log_change("organization.manager_removed", org, person_uuid, authority)
          :ok
      end
    end)
  end

  @doc false
  def clear_locked(org, authority) do
    query = from(m in OrganizationManager, where: m.organization_uuid == ^org.uuid)
    grants = RepoHelper.repo().all(query)
    Revocation.delete_manager_grants(query)

    Enum.each(grants, &log_change("organization.manager_removed", org, &1.user_uuid, authority))
    :ok
  end

  @doc false
  def clear_person_locked(person, actor) do
    query = from(m in OrganizationManager, where: m.user_uuid == ^person.uuid)

    grants = RepoHelper.repo().all(from(m in query, preload: [:organization]))
    Revocation.delete_manager_grants(query)
    authority = %{kind: :admin, actor_uuid: actor.uuid}

    Enum.each(grants, fn grant ->
      log_change("organization.manager_removed", grant.organization, person.uuid, authority)
    end)

    :ok
  end

  @doc false
  def insert_locked(org, person_uuid, authority) do
    require_managed!(org)
    person = RepoHelper.repo().get(User, person_uuid)

    unless match?(%User{account_type: "person", api_only: false, is_active: true}, person),
      do: RepoHelper.repo().rollback(:manager_must_be_active_person)

    case RepoHelper.repo().get_by(OrganizationManager,
           organization_uuid: org.uuid,
           user_uuid: person_uuid
         ) do
      nil ->
        grant =
          %OrganizationManager{}
          |> OrganizationManager.changeset(%{
            organization_uuid: org.uuid,
            user_uuid: person_uuid,
            granted_by_uuid: Map.get(authority, :granted_by_uuid, authority.person_uuid)
          })
          |> RepoHelper.repo().insert()
          |> Locks.value!()

        log_change("organization.manager_added", org, person_uuid, authority)
        grant

      existing ->
        existing
    end
  end

  @doc false
  def with_user_lock(user, opts, fun) do
    Revocation.transaction(fn ->
      Locks.person!(user.uuid)
      ids = Locks.managed_organization_ids(user.uuid)
      organizations = Locks.users!(ids)
      actor = Keyword.get(opts, :manager_actor)

      Locks.users!(
        [user.uuid, Actor.person_uuid(actor)],
        Keyword.get(opts, :lock, "FOR NO KEY UPDATE")
      )

      current =
        RepoHelper.repo().get(User, user.uuid) || RepoHelper.repo().rollback(:user_not_found)

      removes_access = Keyword.get(opts, :removes_access, false)

      removes_access =
        if is_function(removes_access, 1), do: removes_access.(current), else: removes_access

      if removes_access do
        override = lifecycle_override?(actor, opts)
        Enum.each(organizations, &ensure_can_lose!(&1, current.uuid, override))
      end

      current |> fun.() |> Locks.value!()
    end)
  end

  defp lifecycle_override?(actor, opts) do
    if Keyword.get(opts, :allow_managerless, false) == true do
      authority = actor |> Actor.admin() |> Locks.value!()
      expected = Keyword.get(opts, :actor)

      case expected do
        nil -> :ok
        %User{uuid: uuid} when uuid == authority.person_uuid -> :ok
        _ -> RepoHelper.repo().rollback(:forbidden)
      end

      true
    else
      false
    end
  end

  defp override?(%{kind: :admin}, opts), do: Keyword.get(opts, :allow_managerless, false) == true
  defp override?(_, _), do: false

  defp ensure_can_lose!(%User{managed_by_members: true} = org, person_uuid, false) do
    repo = RepoHelper.repo()

    active =
      from(m in OrganizationManager,
        join: p in User,
        on: p.uuid == m.user_uuid,
        where: m.organization_uuid == ^org.uuid,
        where: p.is_active and p.account_type == "person" and not p.api_only
      )

    if repo.exists?(from([m, _p] in active, where: m.user_uuid == ^person_uuid)) and
         not repo.exists?(from([m, _p] in active, where: m.user_uuid != ^person_uuid)),
       do: repo.rollback(:cannot_remove_last_active_manager)
  end

  defp ensure_can_lose!(_org, _person, _override), do: :ok

  defp require_managed!(%User{managed_by_members: true, is_active: true}), do: :ok
  defp require_managed!(_), do: RepoHelper.repo().rollback(:organization_not_active_managed)

  defp log_change(action, org, person_uuid, authority) do
    metadata =
      if authority.kind == :manager,
        do: %{"acting_user_uuid" => authority.person_uuid},
        else: %{}

    PhoenixKit.Activity.log(%{
      action: action,
      module: "users",
      mode: "manual",
      actor_uuid: authority.actor_uuid,
      target_uuid: person_uuid,
      resource_type: "organization",
      resource_uuid: org.uuid,
      metadata: Map.put(metadata, "organization_name", org.organization_name)
    })
  end
end
