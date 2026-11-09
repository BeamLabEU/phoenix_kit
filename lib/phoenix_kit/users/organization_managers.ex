defmodule PhoenixKit.Users.OrganizationManagers do
  @moduledoc """
  Authorized link lifecycle shared by admin and self-service controls.

  A link says that a person may act for a managed organization: its type, and either
  all the organization's roles or a list of them (`PhoenixKit.Users.ActingLink`).

  Grant changes and person lifecycle changes share a per-person advisory lock,
  then organization row locks (`FOR NO KEY UPDATE`, uuid order), then user locks.
  Authority and eligibility are re-read while those locks are held. Link
  additions by a manager will go through invitation acceptance, never a person
  search or this admin-only direct-add function.

  ## Link options

  `add/4`, `update/4`, their `host_*` forms and `Invitations.create/4` take:

    * `:type` — a `PhoenixKit.Users.RelationshipType` or its key. Default the built-in
      `manager`
    * `:roles` — role names or `%Role{}`s, which the organization must hold. Giving a
      list narrows the link to it; `[]` means no roles, never all of them
    * `:all_roles` — `true` for every role the organization holds, the default when
      `:roles` is not given
    * `:metadata` — a map, stored on the link

  ## Who may hand out what

  Nobody gives a role above their own (`Roles.can_manage_role?/2`). Someone acting
  is judged on their whole link, whichever role they have switched to, and only a
  person whose own link has `all_roles` may set it. An Admin needs it for every role
  the organization holds, and an Owner always passes. A non-Owner never changes their
  own link. Changing a link judges the roles it adds and removes, so a role the person
  may not hand out can stay on someone's link, untouched.

  ## Host application calls

  `host_add/4`, `host_update/4`, `host_remove/3` and `host_update_contact/3` do the same
  for a host application with its own screens or API, which has no browser session to
  build an `Actor` from. **The host checks who may do this; the core does
  not**, so the rank rules above do not apply; a role the organization does not hold
  is still refused. `created_by` is the person on whose behalf the host acts: the core
  only records it (as the granting person and as the actor of the activity entries;
  the `organization.manager_added`, `organization.manager_changed` and
  `organization.manager_removed` entries carry `"via" => "host"`, while
  `host_update_contact/3` logs nothing), the way
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
  `{:ok, _}`, the rows disappear and the event has already been sent. The same goes
  for the scope refresh `host_update/4` broadcasts.

  ## Reads for a host

  `people_of/2` and `organizations_of/1` need no `Actor`: the caller decides who sees
  what. Never answer a request with them unchecked.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.ActingLink
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.ManagedOrganizations.Locks
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagerRole
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.ScopeNotifier
  alias PhoenixKit.Users.Sessions
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
            preload: [:user, :granted_by, :relationship_type, role_links: :role],
            order_by: m.inserted_at
          )
        )

      invitations = Invitations.list_invitations(org.uuid, kind: :manager)

      %{
        organization: org,
        authority: authority,
        grants: grants,
        invitations: invitations,
        types: RelationshipTypes.list_types(),
        organization_roles: assignable_roles(org),
        manageable_roles: Roles.manageable_role_names(rank_scope(authority)),
        may_give_all?: may_give_all?(org, authority)
      }
    end)
  end

  # What a link can list: the organization's roles, past the ceiling. `User` always
  # stays through narrowing, so it is nothing to tick.
  defp assignable_roles(org) do
    base = Role.system_roles().user

    RepoHelper.repo().all(
      from(a in RoleAssignment,
        join: role in assoc(a, :role),
        where: a.user_uuid == ^org.uuid and role.name != ^base,
        order_by: [role.position, role.name],
        select: role
      )
    )
    |> Enum.reject(&Scope.managed_ceiling_role?(&1.name))
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

  @doc """
  Adds a link. With no options it is the built-in `manager` with all roles, and an
  existing link is returned untouched. With options, an existing link that differs is
  `{:error, :already_linked}`: `update/4` changes a link.
  """
  def add(actor, organization_uuid, person_uuid, opts \\ []) do
    Revocation.transaction(fn ->
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      insert_locked(org, person_uuid, authority, new_link!(org, authority, opts))
    end)
  end

  @doc "Host-application form of `add/4`; see the module documentation."
  def host_add(organization_uuid, person_uuid, created_by, opts \\ []) do
    Revocation.transaction(fn ->
      Locks.accounts_enabled!()
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      authority = Actor.host!(created_by)
      insert_locked(org, person_uuid, authority, new_link!(org, authority, opts))
    end)
  end

  @doc """
  Changes a link: any of the link options. A person's open pages refresh, and a session
  acting as a role that left the link is signed out.

  `{:error, :not_found}` when there is no link, and
  `{:error, :cannot_remove_last_active_manager}` when this takes the organization's last
  manager away.
  """
  def update(actor, organization_uuid, person_uuid, changes) do
    Revocation.transaction(fn ->
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.authorize(organization_uuid) |> Locks.value!()
      update_locked(org, person_uuid, authority, changes)
    end)
    |> refresh_scopes(organization_uuid)
  end

  @doc "Host-application form of `update/4`; see the module documentation."
  def host_update(organization_uuid, person_uuid, changes, created_by) do
    Revocation.transaction(fn ->
      Locks.person!(person_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([person_uuid])
      authority = Actor.host!(created_by)
      update_locked(org, person_uuid, authority, changes)
    end)
    |> refresh_scopes(organization_uuid)
  end

  # Every open page of the organization rebuilds from its own session token, so only
  # the person whose link changed actually changes.
  defp refresh_scopes({:ok, _link} = result, organization_uuid) do
    ScopeNotifier.broadcast_roles_updated(organization_uuid)
    result
  end

  defp refresh_scopes(error, _organization_uuid), do: error

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
        facts = link_facts(grant)

        Revocation.delete_manager_grants(
          from(m in OrganizationManager, where: m.uuid == ^grant.uuid)
        )

        log_change("organization.manager_removed", org, person_uuid, authority, facts)
        :ok
    end
  end

  @doc false
  def clear_locked(org, authority) do
    query = from(m in OrganizationManager, where: m.organization_uuid == ^org.uuid)
    grants = query |> RepoHelper.repo().all() |> Enum.map(&{&1.user_uuid, link_facts(&1)})
    Revocation.delete_manager_grants(query)

    Enum.each(grants, fn {person_uuid, facts} ->
      log_change("organization.manager_removed", org, person_uuid, authority, facts)
    end)

    :ok
  end

  @doc false
  def clear_person_locked(person, actor) do
    query = from(m in OrganizationManager, where: m.user_uuid == ^person.uuid)

    grants =
      RepoHelper.repo().all(from(m in query, preload: [:organization]))
      |> Enum.map(&{&1.organization, link_facts(&1)})

    Revocation.delete_manager_grants(query)
    authority = %{kind: :admin, actor_uuid: actor.uuid}

    Enum.each(grants, fn {organization, facts} ->
      log_change("organization.manager_removed", organization, person.uuid, authority, facts)
    end)

    :ok
  end

  @doc false
  # `link` comes from `new_link!/3`, or `keep_link/1` for a caller that has no rank to
  # check. A first manager takes the default: the built-in `manager` with all roles.
  def insert_locked(org, person_uuid, authority, link \\ default_link()) do
    require_managed!(org)
    person = RepoHelper.repo().get(User, person_uuid)

    unless match?(%User{account_type: "person", api_only: false, is_active: true}, person),
      do: RepoHelper.repo().rollback(:manager_must_be_active_person)

    case RepoHelper.repo().get_by(OrganizationManager,
           organization_uuid: org.uuid,
           user_uuid: person_uuid
         ) do
      nil -> insert_link(org, person_uuid, authority, link)
      existing -> existing_link!(existing, link)
    end
  end

  defp insert_link(org, person_uuid, authority, link) do
    granted_by = Map.get(authority, :granted_by_uuid, authority.person_uuid)

    grant =
      %OrganizationManager{}
      |> OrganizationManager.changeset(%{
        organization_uuid: org.uuid,
        user_uuid: person_uuid,
        granted_by_uuid: granted_by,
        relationship_type_uuid: link.type.uuid,
        all_roles: link.all_roles,
        metadata: link.metadata
      })
      |> RepoHelper.repo().insert()
      |> Locks.value!()

    insert_roles(grant, link.roles, granted_by)
    log_change("organization.manager_added", org, person_uuid, authority, facts(link))
    grant
  end

  defp insert_roles(_grant, [], _assigned_by), do: :ok

  defp insert_roles(grant, roles, assigned_by) do
    rows =
      for role <- roles do
        %{
          organization_manager_uuid: grant.uuid,
          role_uuid: role.uuid,
          assigned_by_uuid: assigned_by
        }
      end

    RepoHelper.repo().insert_all(OrganizationManagerRole, rows)
    :ok
  end

  defp existing_link!(existing, %{on_existing: :keep}), do: existing

  defp existing_link!(existing, link) do
    existing = RepoHelper.repo().preload(existing, :role_links)

    same? =
      existing.relationship_type_uuid == link.type.uuid and
        existing.all_roles == link.all_roles and existing.metadata == link.metadata and
        Enum.sort(Enum.map(existing.role_links, & &1.role_uuid)) ==
          Enum.sort(Enum.map(link.roles, & &1.uuid))

    if same?, do: existing, else: RepoHelper.repo().rollback(:already_linked)
  end

  defp update_locked(org, person_uuid, authority, changes) do
    require_managed!(org)

    link =
      RepoHelper.repo().one(
        from(m in OrganizationManager,
          where: m.organization_uuid == ^org.uuid and m.user_uuid == ^person_uuid,
          preload: [:relationship_type, role_links: :role]
        )
      ) || RepoHelper.repo().rollback(:not_found)

    before = %{
      type: link.relationship_type,
      all_roles: link.all_roles,
      roles: Enum.map(link.role_links, & &1.role),
      metadata: link.metadata
    }

    target = changed_link!(before, changes)

    require_own_link_untouched!(authority, person_uuid)
    require_active_type_if_changed!(before, target)
    require_change_allowed!(org, authority, before, target)

    if before.type.can_manage and not target.type.can_manage,
      do: ensure_can_lose!(org, person_uuid, false)

    write_link(link, before, target, authority, org)
  end

  defp write_link(link, before, target, authority, org) do
    assigned_by = Map.get(authority, :granted_by_uuid, authority.person_uuid)

    updated =
      link
      |> Ecto.Changeset.change(
        relationship_type_uuid: target.type.uuid,
        all_roles: target.all_roles,
        metadata: target.metadata
      )
      |> RepoHelper.repo().update()
      |> Locks.value!()

    added = roles_without(target.roles, before.roles)
    dropped = roles_without(before.roles, target.roles)

    delete_roles(link, dropped)
    insert_roles(link, added, assigned_by)
    Sessions.revoke_link_sessions_in_roles(link.uuid, lost_role_uuids(org, before, target))

    log_change("organization.manager_changed", org, link.user_uuid, authority, facts(target))
    updated
  end

  defp roles_without(roles, others) do
    gone = MapSet.new(others, & &1.uuid)
    Enum.reject(roles, &MapSet.member?(gone, &1.uuid))
  end

  defp delete_roles(_link, []), do: :ok

  defp delete_roles(link, roles) do
    uuids = Enum.map(roles, & &1.uuid)

    RepoHelper.repo().delete_all(
      from(r in OrganizationManagerRole,
        where: r.organization_manager_uuid == ^link.uuid and r.role_uuid in ^uuids
      )
    )

    :ok
  end

  # What the person could act as before and cannot now.
  defp lost_role_uuids(org, before, target) do
    held = Roles.get_user_role_records(org)
    allowed = fn link -> held |> ActingLink.narrow(narrow_view(link)) |> MapSet.new(& &1.uuid) end

    allowed.(before) |> MapSet.difference(allowed.(target)) |> MapSet.to_list()
  end

  defp narrow_view(link) do
    %{all_roles?: link.all_roles, role_uuids: Enum.map(link.roles, & &1.uuid)}
  end

  @doc false
  # Resolves and checks the link options of a new link, inside the caller's transaction.
  # With no options an existing link is kept, as `add/3` always did.
  def new_link!(org, authority, opts) do
    type = resolve_type!(Keyword.get(opts, :type))
    {all_roles, roles} = resolve_roles!(opts, {true, []})

    require_active_type!(type)
    require_held!(org, roles)
    require_rank!(org, authority, all_roles, roles)

    %{
      type: type,
      all_roles: all_roles,
      roles: roles,
      metadata: Keyword.get(opts, :metadata, %{}),
      on_existing: if(opts == [], do: :keep, else: :refuse)
    }
  end

  @doc false
  # A link already authorized when it was asked for: an invitation being accepted.
  # The rows of an existing link stand.
  def keep_link(link), do: Map.put(link, :on_existing, :keep)

  defp default_link do
    %{
      type: RelationshipTypes.manager_type(),
      all_roles: true,
      roles: [],
      metadata: %{},
      on_existing: :keep
    }
  end

  defp changed_link!(before, changes) do
    type =
      if Keyword.has_key?(changes, :type),
        do: resolve_type!(changes[:type]),
        else: before.type

    {all_roles, roles} = resolve_roles!(changes, {before.all_roles, before.roles})

    %{
      type: type,
      all_roles: all_roles,
      roles: roles,
      metadata: Keyword.get(changes, :metadata, before.metadata)
    }
  end

  defp resolve_type!(nil), do: RelationshipTypes.manager_type()

  defp resolve_type!(%RelationshipType{uuid: uuid}) do
    RelationshipTypes.get_type(uuid) || RepoHelper.repo().rollback(:relationship_type_not_found)
  end

  defp resolve_type!(key) do
    RelationshipTypes.get_type_by_key(key) ||
      RepoHelper.repo().rollback(:relationship_type_not_found)
  end

  defp resolve_roles!(opts, {current_all, current_roles}) do
    case {Keyword.fetch(opts, :all_roles), Keyword.fetch(opts, :roles)} do
      {{:ok, true}, {:ok, [_ | _]}} -> RepoHelper.repo().rollback(:invalid_roles)
      {{:ok, true}, _roles} -> {true, []}
      {_all, {:ok, roles}} -> {false, fetch_roles!(roles)}
      {{:ok, false}, :error} -> {false, current_roles}
      {:error, :error} -> {current_all, current_roles}
    end
  end

  defp fetch_roles!(roles) when is_list(roles) do
    names = roles |> Enum.map(&role_name/1) |> Enum.uniq()
    found = RepoHelper.repo().all(from(r in Role, where: r.name in ^names))

    if length(found) == length(names),
      do: found,
      else: RepoHelper.repo().rollback(:role_not_found)
  end

  defp fetch_roles!(_roles), do: RepoHelper.repo().rollback(:invalid_roles)

  defp role_name(%Role{name: name}), do: name
  defp role_name(name) when is_binary(name), do: name
  defp role_name(_role), do: RepoHelper.repo().rollback(:invalid_roles)

  defp require_active_type!(%RelationshipType{status: "active", can_act: true}), do: :ok

  defp require_active_type!(%RelationshipType{}),
    do: RepoHelper.repo().rollback(:relationship_type_archived)

  defp require_active_type_if_changed!(%{type: %{uuid: uuid}}, %{type: %{uuid: uuid}}), do: :ok
  defp require_active_type_if_changed!(_before, %{type: type}), do: require_active_type!(type)

  defp require_held!(_org, []), do: :ok

  defp require_held!(org, roles) do
    held = org |> Roles.get_user_role_records() |> MapSet.new(& &1.uuid)

    unless Enum.all?(roles, &MapSet.member?(held, &1.uuid)),
      do: RepoHelper.repo().rollback(:role_not_held)
  end

  defp require_own_link_untouched!(%{kind: :host}, _person_uuid), do: :ok

  defp require_own_link_untouched!(%{person_uuid: person_uuid} = authority, person_uuid) do
    unless owner?(authority), do: RepoHelper.repo().rollback(:cannot_modify_own_roles)
  end

  defp require_own_link_untouched!(_authority, _person_uuid), do: :ok

  defp owner?(%{kind: :admin, scope: scope}), do: Scope.owner?(scope)
  defp owner?(_authority), do: false

  # Everything a new link gives.
  defp require_rank!(_org, %{kind: :host}, _all_roles, _roles), do: :ok

  defp require_rank!(org, authority, true, _roles), do: require_may_give_all!(org, authority)

  defp require_rank!(_org, authority, false, roles), do: require_manageable!(authority, roles)

  # Only what a change adds and removes: a role the person may not hand out can stay on
  # someone's link, and the form carries it back untouched.
  defp require_change_allowed!(org, authority, before, target) do
    added = roles_without(target.roles, before.roles)
    dropped = roles_without(before.roles, target.roles)

    require_held!(org, added)

    unless authority.kind == :host do
      if before.all_roles != target.all_roles, do: require_may_give_all!(org, authority)
      require_manageable!(authority, added ++ dropped)
    end

    :ok
  end

  defp require_may_give_all!(org, authority) do
    unless may_give_all?(org, authority), do: not_permitted!()
    :ok
  end

  defp may_give_all?(_org, %{kind: :manager, link: %{all_roles: all_roles}}), do: all_roles

  defp may_give_all?(org, %{kind: :admin} = authority) do
    org |> Roles.get_user_role_records() |> Enum.map(& &1.name) |> manageable?(authority)
  end

  defp require_manageable!(authority, roles) do
    unless manageable?(roles, authority), do: not_permitted!()
    :ok
  end

  defp manageable?(roles, authority) do
    scope = rank_scope(authority)
    Enum.all?(roles, &Roles.can_manage_role?(scope, &1))
  end

  defp not_permitted!, do: RepoHelper.repo().rollback(:not_permitted)

  # Someone acting is judged on their whole link, not the role they switched to: a
  # manager with Buyer and Supplier acting as Buyer can still hand out Supplier.
  defp rank_scope(%{kind: :manager, scope: scope}), do: Scope.for_user(scope.user, narrow: false)
  defp rank_scope(%{scope: scope}), do: scope

  @doc "How many people are linked to an organization."
  @spec count_of(String.t()) :: non_neg_integer()
  def count_of(organization_uuid) do
    RepoHelper.repo().aggregate(
      from(m in OrganizationManager, where: m.organization_uuid == ^organization_uuid),
      :count
    )
  end

  @doc """
  Active people linked to an organization, for a host's own use (who gets its emails).
  See `organizations_of/1` for the shape, with `:person` in place of `:organization`.

  ## Options

    * `:type` — only links of this type: a `RelationshipType` or its key
  """
  @spec people_of(String.t(), keyword()) :: [map()]
  def people_of(organization_uuid, opts \\ []) do
    links =
      from(m in OrganizationManager,
        join: person in assoc(m, :user),
        where: m.organization_uuid == ^organization_uuid,
        where: person.is_active and person.account_type == "person" and not person.api_only,
        order_by: m.inserted_at,
        preload: [:relationship_type, :role_links, user: person]
      )
      |> of_type(Keyword.get(opts, :type))
      |> RepoHelper.repo().all()

    held = Map.get(Roles.get_role_records_for_users([organization_uuid]), organization_uuid, [])
    Enum.map(links, &link_read(&1, :person, &1.user, held))
  end

  @doc """
  Every active managed organization a person is linked to, for a host's own use (a
  company picker). Each entry has `:uuid`, `:organization`, `:type`, `:all_roles?`,
  `:roles` (the role records in effect through the link, the base role included),
  `:metadata`, `:granted_by_uuid` and `:inserted_at`.
  """
  @spec organizations_of(String.t()) :: [map()]
  def organizations_of(person_uuid) do
    links =
      RepoHelper.repo().all(
        from(m in OrganizationManager,
          join: org in assoc(m, :organization),
          where: m.user_uuid == ^person_uuid and org.managed_by_members and org.is_active,
          order_by: [org.organization_name, org.uuid],
          preload: [:relationship_type, :role_links, organization: org]
        )
      )

    held = links |> Enum.map(& &1.organization_uuid) |> Roles.get_role_records_for_users()

    Enum.map(links, fn link ->
      link_read(link, :organization, link.organization, Map.get(held, link.organization_uuid, []))
    end)
  end

  defp of_type(query, nil), do: query

  defp of_type(query, %RelationshipType{uuid: uuid}),
    do: from(m in query, where: m.relationship_type_uuid == ^uuid)

  defp of_type(query, key) when is_binary(key) do
    from(m in query,
      join: type in assoc(m, :relationship_type),
      where: type.key == ^key
    )
  end

  defp link_read(link, side, account, held) do
    allowed = %{
      all_roles?: link.all_roles,
      role_uuids: Enum.map(link.role_links, & &1.role_uuid)
    }

    roles =
      held |> Enum.reject(&Scope.managed_ceiling_role?(&1.name)) |> ActingLink.narrow(allowed)

    Map.put(
      %{
        uuid: link.uuid,
        type: link.relationship_type,
        all_roles?: link.all_roles,
        roles: roles,
        metadata: link.metadata,
        granted_by_uuid: link.granted_by_uuid,
        inserted_at: link.inserted_at
      },
      side,
      account
    )
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
        join: t in assoc(m, :relationship_type),
        where: m.organization_uuid == ^org.uuid,
        where: p.is_active and p.account_type == "person" and not p.api_only,
        where: t.can_manage
      )

    if repo.exists?(from([m, _p, _t] in active, where: m.user_uuid == ^person_uuid)) and
         not repo.exists?(from([m, _p, _t] in active, where: m.user_uuid != ^person_uuid)),
       do: repo.rollback(:cannot_remove_last_active_manager)
  end

  defp ensure_can_lose!(_org, _person, _override), do: :ok

  defp require_managed!(%User{managed_by_members: true, is_active: true}), do: :ok
  defp require_managed!(_), do: RepoHelper.repo().rollback(:organization_not_active_managed)

  defp facts(link) do
    %{
      "relationship_type" => link.type.key,
      "all_roles" => link.all_roles,
      "roles" => Enum.map(link.roles, & &1.name)
    }
  end

  defp link_facts(%OrganizationManager{} = grant) do
    grant = RepoHelper.repo().preload(grant, [:relationship_type, role_links: :role])

    facts(%{
      type: grant.relationship_type,
      all_roles: grant.all_roles,
      roles: Enum.map(grant.role_links, & &1.role)
    })
  end

  defp log_change(action, org, person_uuid, authority, facts) do
    metadata =
      case authority.kind do
        :manager -> %{"acting_user_uuid" => authority.person_uuid}
        :host -> %{"via" => "host"}
        _ -> %{}
      end

    metadata = Map.merge(metadata, facts)

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
