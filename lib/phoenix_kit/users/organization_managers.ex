defmodule PhoenixKit.Users.OrganizationManagers do
  @moduledoc """
  Authorized manager lifecycle shared by admin and self-service controls.

  Grant changes and person lifecycle changes share a per-person advisory lock,
  then organization row locks (`FOR NO KEY UPDATE`, uuid order), then user locks.
  Authority and eligibility are re-read while those locks are held. Manager
  additions by a manager will go through invitation acceptance, never a person
  search or this admin-only direct-add function.

  ## Host application calls

  `host_add/3`, `host_remove/3` and `host_update_contact/3` do the same for a
  host application with its own screens or API, which has no browser session to
  build an `Actor` from. **The host checks who may do this; the core does
  not.** `created_by` is the person on whose behalf the host acts: the core only
  records it (as the granting person and as the actor of the activity entries;
  the `organization.manager_added` and `organization.manager_removed` entries
  carry `"via" => "host"`, while `host_update_contact/3` logs nothing), the way
  `PhoenixKit.Users.Auth.admin_create_user/2` does. It is re-read under
  `FOR KEY SHARE` (excluding a concurrent delete or key change; `is_active` is
  as of the read) and must be an active person that is neither a managed
  organization nor a service user, else the call fails with
  `{:error, :forbidden}` (so does `nil` or anything that is not a `%User{}`).
  The organization is looked up before `created_by`, so an unknown one is
  `{:error, :organization_not_found}` even when `created_by` is unfit. Never
  pass a value taken from request parameters.

  The locks, the organization and person checks, the notification to the
  person (not sent when the person is `created_by` itself) and the last-manager
  rule are those of `add/3`, `remove/4` and `update_contact/3`. `host_remove/3`
  has no override: removing the last active manager is
  `{:error, :cannot_remove_last_active_manager}`. `host_add/3`
  answers `{:error, :organization_accounts_disabled}` while the
  `enable_organization_accounts` setting is off. They join an outer
  `Repo.transaction/1` of the host, and an error rolls that transaction back too.
  ⚠️ The activity entry is inserted in that transaction, but its PubSub
  broadcast and the notification to the person go out when `Activity.log/1`
  runs, not at the outer commit: if the host rolls back after the core returned
  `{:ok, _}`, the rows disappear and the event has already been sent.
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
      change_contact!(org, attrs)
    end)
  end

  @doc "Host-application form of `update_contact/3`; see the module documentation."
  def host_update_contact(organization_uuid, attrs, created_by) do
    Revocation.transaction(fn ->
      org = Locks.organization!(organization_uuid)
      Actor.host!(created_by)
      change_contact!(org, attrs)
    end)
  end

  defp change_contact!(org, attrs) do
    unless org.managed_by_members, do: RepoHelper.repo().rollback(:organization_not_managed)
    org |> User.contact_email_changeset(attrs) |> RepoHelper.repo().update() |> Locks.value!()
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
          ilike(u.email, ^pattern) or ilike(u.username, ^pattern) or
            ilike(fragment("concat_ws(' ', ?, ?)", u.first_name, u.last_name), ^pattern),
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

  @doc "Host-application form of `add/3`; see the module documentation."
  def host_add(organization_uuid, person_uuid, created_by) do
    Revocation.transaction(fn ->
      Locks.accounts_enabled!()
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      authority = Actor.host!(created_by)
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
      remove_locked(org, person_uuid, authority, opts)
    end)
  end

  @doc "Host-application form of `remove/4` without an override; see the module documentation."
  def host_remove(organization_uuid, person_uuid, created_by) do
    Revocation.transaction(fn ->
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      authority = Actor.host!(created_by)
      remove_locked(org, person_uuid, authority, [])
    end)
  end

  defp remove_locked(org, person_uuid, authority, opts) do
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
      case authority.kind do
        :manager -> %{"acting_user_uuid" => authority.person_uuid}
        :host -> %{"via" => "host"}
        _ -> %{}
      end

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
