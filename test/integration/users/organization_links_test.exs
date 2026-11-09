defmodule PhoenixKit.Users.OrganizationLinksTest do
  @moduledoc """
  Writing links: who may manage an organization, who may hand out which role, what a
  change does to open sessions, invitations that carry a link, and the host's reads.
  What a link then gives a session is `ActingLinkScopeTest`.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations.Invitations, as: ManagerInvitations
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagerRole
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.ScopeNotifier

  setup do
    {:ok, _} = Settings.update_boolean_setting("enable_organization_accounts", true)
    :ok
  end

  defp staff_type(overrides \\ %{}) do
    {:ok, type} =
      RelationshipTypes.create_type(
        Map.merge(
          %{
            key: "staff_#{System.unique_integer([:positive])}",
            name: "Staff",
            from_kind: "person",
            to_kind: "organization",
            can_act: true,
            can_manage: false
          },
          overrides
        )
      )

    type
  end

  # A company holding Buyer (`users`) and Supplier (`media`).
  defp company do
    organization = Fixtures.organization()
    buyer = Fixtures.role(["users"], organization)
    supplier = Fixtures.role(["media"], organization)
    %{organization: organization, buyer: buyer, supplier: supplier}
  end

  defp manager_session(organization, roles \\ :all) do
    person = Fixtures.person()

    link =
      case roles do
        :all -> Fixtures.manager(organization, person)
        roles -> Fixtures.narrowed_link(organization, person, roles)
      end

    session = Fixtures.enter(organization, person, link)
    Map.put(session, :actor, Fixtures.acting_actor(session))
  end

  defp staff_session(organization, type, roles \\ []) do
    person = Fixtures.person()

    link =
      Fixtures.narrowed_link(organization, person, roles, %{relationship_type_uuid: type.uuid})

    session = Fixtures.enter(organization, person, link)
    Map.put(session, :actor, Fixtures.acting_actor(session))
  end

  defp link_of(organization, person) do
    OrganizationManager
    |> Repo.get_by!(organization_uuid: organization.uuid, user_uuid: person.uuid)
    |> Repo.preload([:relationship_type, role_links: :role])
  end

  defp role_names(link), do: link.role_links |> Enum.map(& &1.role.name) |> Enum.sort()

  defp host, do: Fixtures.person()

  describe "who may manage" do
    test "a manager link passes every door" do
      %{organization: organization} = company()
      s = manager_session(organization)
      other = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:ok, %{grants: [_, _]}} = OrganizationManagers.details(s.actor, organization.uuid)

      assert {:ok, _} =
               OrganizationManagers.update_contact(s.actor, organization.uuid, %{
                 contact_email: "new@example.com"
               })

      assert {:ok, invitation, _token} =
               Invitations.create_invitation(organization, "invited@example.com", s.actor,
                 kind: :manager
               )

      assert {:ok, _} =
               ManagerInvitations.cancel(
                 s.actor,
                 organization.uuid,
                 invitation.uuid
               )

      assert :ok =
               unwrap(OrganizationManagers.remove(s.actor, organization.uuid, other.user_uuid))
    end

    test "a link without can_manage is refused at every door" do
      %{organization: organization} = company()
      keeper = manager_session(organization)
      s = staff_session(organization, staff_type())

      {:ok, invitation, _} =
        Invitations.create_invitation(organization, "pending@example.com", keeper.actor,
          kind: :manager
        )

      assert {:error, :forbidden} = OrganizationManagers.details(s.actor, organization.uuid)

      assert {:error, :forbidden} =
               OrganizationManagers.update_contact(s.actor, organization.uuid, %{
                 contact_email: "new@example.com"
               })

      assert {:error, :forbidden} =
               Invitations.create_invitation(organization, "other@example.com", s.actor,
                 kind: :manager
               )

      assert {:error, :forbidden} =
               ManagerInvitations.cancel(
                 s.actor,
                 organization.uuid,
                 invitation.uuid
               )

      assert {:error, :forbidden} =
               OrganizationManagers.remove(s.actor, organization.uuid, keeper.person.uuid)

      assert {:error, :forbidden} =
               OrganizationManagers.update(s.actor, organization.uuid, keeper.person.uuid,
                 roles: []
               )
    end

    test "a custom type with can_manage manages" do
      %{organization: organization} = company()
      s = staff_session(organization, staff_type(%{can_manage: true}))

      assert {:ok, _} = OrganizationManagers.details(s.actor, organization.uuid)
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(other), do: other

  describe "the last-manager rule counts can_manage links" do
    test "a staff link does not keep an organization managed" do
      %{organization: organization} = company()
      manager = manager_session(organization)
      staff_session(organization, staff_type())

      assert {:error, :cannot_remove_last_active_manager} =
               OrganizationManagers.host_remove(organization.uuid, manager.person.uuid, host())
    end

    test "a staff link can go, whoever is left" do
      %{organization: organization} = company()
      manager_session(organization)
      s = staff_session(organization, staff_type())

      assert {:ok, :ok} =
               OrganizationManagers.host_remove(organization.uuid, s.person.uuid, host())
    end

    test "the last manager cannot be moved to a staff type" do
      %{organization: organization} = company()
      manager = manager_session(organization)
      type = staff_type()

      assert {:error, :cannot_remove_last_active_manager} =
               OrganizationManagers.host_update(
                 organization.uuid,
                 manager.person.uuid,
                 [type: type],
                 host()
               )

      other = manager_session(organization)

      assert {:ok, %{relationship_type_uuid: uuid}} =
               OrganizationManagers.host_update(
                 organization.uuid,
                 other.person.uuid,
                 [type: type],
                 host()
               )

      assert uuid == type.uuid
    end
  end

  describe "handing out roles, for someone acting" do
    test "a manager gives roles they hold" do
      %{organization: organization, buyer: buyer} = company()
      s = manager_session(organization, [buyer])
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:ok, _} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 roles: [buyer]
               )

      assert role_names(link_of(organization, %{uuid: peter.user_uuid})) == [buyer.name]
    end

    test "not a role above their own" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      s = manager_session(organization, [buyer])
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:error, :not_permitted} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 roles: [buyer, supplier]
               )

      assert role_names(link_of(organization, %{uuid: peter.user_uuid})) == []
    end

    test "not a role the company lacks" do
      %{organization: organization} = company()
      s = manager_session(organization)
      elsewhere = Fixtures.role(["sitemap"])
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:error, :role_not_held} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 roles: [elsewhere]
               )
    end

    test "a narrowed manager cannot set all roles, an empty list included" do
      %{organization: organization, buyer: buyer} = company()
      s = manager_session(organization, [buyer])
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:error, :not_permitted} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 all_roles: true
               )

      assert {:error, :not_permitted} =
               Invitations.create_invitation(organization, "a@example.com", s.actor,
                 kind: :manager
               )

      assert {:ok, %OrganizationInvitation{all_roles: false, role_uuids: []}, _} =
               Invitations.create_invitation(organization, "a@example.com", s.actor,
                 kind: :manager,
                 roles: []
               )
    end

    test "a manager with all roles can give all roles" do
      %{organization: organization} = company()
      s = manager_session(organization)
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:ok, %{all_roles: true}} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 all_roles: true
               )
    end

    test "is judged on the whole link, not the role switched to" do
      {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      s = manager_session(organization, [buyer, supplier])
      {:ok, _} = ActiveRole.switch(s.user, s.token, buyer.uuid)
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:ok, _} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 roles: [supplier]
               )
    end

    test "nobody changes their own link" do
      %{organization: organization, buyer: buyer} = company()
      s = manager_session(organization)

      assert {:error, :cannot_modify_own_roles} =
               OrganizationManagers.update(s.actor, organization.uuid, s.person.uuid,
                 roles: [buyer]
               )
    end

    test "removing a link checks the roles it takes away" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      s = manager_session(organization, [buyer])
      other = Fixtures.narrowed_link(organization, Fixtures.person(), [supplier])

      assert {:error, :not_permitted} =
               OrganizationManagers.remove(s.actor, organization.uuid, other.user_uuid)

      assert Repo.get(OrganizationManager, other.uuid)

      full = Fixtures.manager(organization, Fixtures.person())

      assert {:error, :not_permitted} =
               OrganizationManagers.remove(s.actor, organization.uuid, full.user_uuid)

      assert Repo.get(OrganizationManager, full.uuid)

      allowed = Fixtures.narrowed_link(organization, Fixtures.person(), [buyer])

      assert {:ok, :ok} =
               OrganizationManagers.remove(s.actor, organization.uuid, allowed.user_uuid)
    end

    test "removing one's own link is refused even when another manager remains" do
      %{organization: organization} = company()
      s = manager_session(organization)
      manager_session(organization)

      assert {:error, :cannot_modify_own_roles} =
               OrganizationManagers.remove(s.actor, organization.uuid, s.person.uuid)

      assert Repo.get(OrganizationManager, s.manager.uuid)
    end

    test "a role they may not hand out stays on someone's link, untouched" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      s = manager_session(organization, [buyer])
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [supplier])

      assert {:ok, _} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 roles: [buyer, supplier]
               )

      assert role_names(link_of(organization, %{uuid: peter.user_uuid})) ==
               Enum.sort([buyer.name, supplier.name])

      assert {:error, :not_permitted} =
               OrganizationManagers.update(s.actor, organization.uuid, peter.user_uuid,
                 roles: [buyer]
               )
    end
  end

  describe "handing out roles, for an admin" do
    test "an Admin needs the keys of what they give" do
      %{organization: organization} = company()
      manager_session(organization)
      restricted = Fixtures.role(["storage"], organization)
      {actor, admin} = Fixtures.admin_actor()
      :ok = Permissions.revoke_permission(admin_role_uuid(), "storage")
      person = Fixtures.person()

      assert {:error, :not_permitted} =
               OrganizationManagers.add(actor, organization.uuid, person.uuid,
                 roles: [restricted]
               )

      assert {:error, :not_permitted} =
               OrganizationManagers.add(actor, organization.uuid, person.uuid)

      assert admin.uuid
    end

    test "an Admin changes other people's links, and not their own" do
      %{organization: organization, buyer: buyer} = company()
      manager_session(organization)
      {actor, admin} = Fixtures.admin_actor()
      own = Fixtures.narrowed_link(organization, admin, [])
      peter = Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert {:ok, _} =
               OrganizationManagers.update(actor, organization.uuid, peter.user_uuid,
                 roles: [buyer]
               )

      assert {:error, :cannot_modify_own_roles} =
               OrganizationManagers.update(actor, organization.uuid, own.user_uuid,
                 roles: [buyer]
               )
    end
  end

  defp admin_role_uuid, do: Roles.get_role_by_name("Admin").uuid

  describe "host calls" do
    test "take no rank, but still refuse a role the company lacks" do
      %{organization: organization, buyer: buyer} = company()
      elsewhere = Fixtures.role(["sitemap"])
      person = Fixtures.person()

      assert {:error, :role_not_held} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(),
                 roles: [elsewhere]
               )

      assert {:ok, link} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(),
                 type: staff_type(),
                 roles: [buyer.name],
                 metadata: %{"source" => "import"}
               )

      assert %{all_roles: false, metadata: %{"source" => "import"}} = link
      assert role_names(link_of(organization, person)) == [buyer.name]
    end

    test "host_add/3 stays idempotent and never changes a link" do
      %{organization: organization, buyer: buyer} = company()
      person = Fixtures.person()

      {:ok, first} =
        OrganizationManagers.host_add(organization.uuid, person.uuid, host(), roles: [buyer])

      assert {:ok, again} = OrganizationManagers.host_add(organization.uuid, person.uuid, host())
      assert again.uuid == first.uuid
      assert role_names(link_of(organization, person)) == [buyer.name]
    end

    test "a second link is refused when it differs, and returned when it matches" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      person = Fixtures.person()

      {:ok, first} =
        OrganizationManagers.host_add(organization.uuid, person.uuid, host(), roles: [buyer])

      assert {:ok, same} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(),
                 roles: [buyer]
               )

      assert same.uuid == first.uuid

      assert {:error, :already_linked} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(),
                 roles: [supplier]
               )
    end

    test "refuse an unknown or archived type, and contradictory options" do
      %{organization: organization, buyer: buyer} = company()
      person = Fixtures.person()
      {:ok, archived} = RelationshipTypes.archive_type(staff_type())

      assert {:error, :relationship_type_not_found} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(), type: "nope")

      assert {:error, :relationship_type_archived} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(),
                 type: archived
               )

      assert {:error, :role_not_found} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(),
                 roles: ["No such role"]
               )

      assert {:error, :invalid_roles} =
               OrganizationManagers.host_add(organization.uuid, person.uuid, host(),
                 all_roles: true,
                 roles: [buyer]
               )
    end

    test "host_update/4 answers for a missing link" do
      %{organization: organization} = company()

      assert {:error, :not_found} =
               OrganizationManagers.host_update(
                 organization.uuid,
                 Fixtures.person().uuid,
                 [roles: []],
                 host()
               )
    end
  end

  describe "changing a link" do
    test "keeps who gave the roles that stay" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      first = host()
      second = host()
      person = Fixtures.person()

      {:ok, _} =
        OrganizationManagers.host_add(organization.uuid, person.uuid, first, roles: [buyer])

      {:ok, _} =
        OrganizationManagers.host_update(
          organization.uuid,
          person.uuid,
          [roles: [buyer, supplier]],
          second
        )

      by_role =
        Map.new(link_of(organization, person).role_links, &{&1.role_uuid, &1.assigned_by_uuid})

      assert by_role[buyer.uuid] == first.uuid
      assert by_role[supplier.uuid] == second.uuid
    end

    test "moving from a list to all roles clears the list, and back narrows again" do
      %{organization: organization, buyer: buyer} = company()
      person = Fixtures.person()

      {:ok, _} =
        OrganizationManagers.host_add(organization.uuid, person.uuid, host(), roles: [buyer])

      assert {:ok, %{all_roles: true}} =
               OrganizationManagers.host_update(
                 organization.uuid,
                 person.uuid,
                 [all_roles: true],
                 host()
               )

      assert link_of(organization, person).role_links == []

      assert {:ok, %{all_roles: false}} =
               OrganizationManagers.host_update(
                 organization.uuid,
                 person.uuid,
                 [all_roles: false],
                 host()
               )

      assert link_of(organization, person).role_links == []
    end

    test "unticking the last role leaves none, never every role" do
      %{organization: organization, buyer: buyer} = company()
      s = staff_session(organization, staff_type(), [buyer])

      {:ok, _} =
        OrganizationManagers.host_update(organization.uuid, s.person.uuid, [roles: []], host())

      scope = s.token |> Auth.get_user_by_session_token() |> Scope.for_user()
      assert Scope.user_roles(scope) == ["User"]
    end

    test "an archived type stays on the links it has" do
      %{organization: organization, buyer: buyer} = company()
      type = staff_type()
      s = staff_session(organization, type)
      {:ok, _} = RelationshipTypes.archive_type(type)

      assert Auth.get_user_by_session_token(s.token)

      assert {:ok, _} =
               OrganizationManagers.host_update(
                 organization.uuid,
                 s.person.uuid,
                 [roles: [buyer]],
                 host()
               )
    end

    test "refreshes open pages, after the change is committed" do
      %{organization: organization, buyer: buyer} = company()
      s = staff_session(organization, staff_type())
      :ok = ScopeNotifier.subscribe(organization.uuid)
      uuid = organization.uuid

      {:ok, _} =
        OrganizationManagers.host_update(uuid, s.person.uuid, [roles: [buyer]], host())

      assert_receive {:phoenix_kit_scope_roles_updated, ^uuid}
    end

    test "signs out only the sessions of this link acting as a role that left it" do
      {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      type = staff_type()
      leaving = staff_session(organization, type, [buyer, supplier])
      staying = staff_session(organization, type, [buyer, supplier])
      default = staff_session(organization, type, [buyer, supplier])

      {:ok, _} = ActiveRole.switch(leaving.user, leaving.token, supplier.uuid)
      {:ok, _} = ActiveRole.switch(staying.user, staying.token, supplier.uuid)

      {:ok, _} =
        OrganizationManagers.host_update(
          organization.uuid,
          leaving.person.uuid,
          [roles: [buyer]],
          host()
        )

      refute Auth.get_user_by_session_token(leaving.token)
      assert Auth.get_user_by_session_token(staying.token)
      assert Auth.get_user_by_session_token(default.token)

      {:ok, _} =
        OrganizationManagers.host_update(
          organization.uuid,
          default.person.uuid,
          [roles: [buyer]],
          host()
        )

      assert Auth.get_user_by_session_token(default.token)
    end

    test "going from all roles to a list signs out a session acting as a lost role" do
      {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      manager_session(organization)
      s = manager_session(organization)
      {:ok, _} = ActiveRole.switch(s.user, s.token, supplier.uuid)

      {:ok, _} =
        OrganizationManagers.host_update(
          organization.uuid,
          s.person.uuid,
          [roles: [buyer]],
          host()
        )

      refute Auth.get_user_by_session_token(s.token)
    end
  end

  describe "the activity log" do
    defp entries(action, organization) do
      Repo.all(
        from(e in Entry,
          where: e.action == ^action and e.resource_uuid == ^organization.uuid,
          order_by: e.inserted_at
        )
      )
    end

    test "records the type and roles on add, change and remove" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      manager_session(organization)
      type = staff_type()
      person = Fixtures.person()
      created_by = host()

      {:ok, _} =
        OrganizationManagers.host_add(organization.uuid, person.uuid, created_by,
          type: type,
          roles: [buyer]
        )

      {:ok, _} =
        OrganizationManagers.host_update(
          organization.uuid,
          person.uuid,
          [roles: [supplier]],
          created_by
        )

      {:ok, _} = OrganizationManagers.host_remove(organization.uuid, person.uuid, created_by)

      added_roles = [buyer.name]
      changed_roles = [supplier.name]
      key = type.key

      assert [%{metadata: %{"relationship_type" => ^key, "roles" => ^added_roles}}] =
               entries("organization.manager_added", organization)
               |> Enum.filter(&(&1.target_uuid == person.uuid))

      assert [
               %{
                 actor_uuid: actor,
                 metadata: %{
                   "relationship_type" => ^key,
                   "all_roles" => false,
                   "roles" => ^changed_roles,
                   "via" => "host"
                 }
               }
             ] = entries("organization.manager_changed", organization)

      assert actor == created_by.uuid

      assert [%{metadata: %{"relationship_type" => ^key, "roles" => ^changed_roles}}] =
               entries("organization.manager_removed", organization)
    end
  end

  describe "invitations carry the link" do
    defp accept(invitation, person) do
      Invitations.accept_invitation_by_uuid(invitation.uuid, person)
    end

    test "acceptance creates that link" do
      %{organization: organization, buyer: buyer} = company()
      s = manager_session(organization)
      type = staff_type()
      person = Fixtures.person()

      {:ok, invitation, _} =
        Invitations.create_invitation(organization, person.email, s.actor,
          kind: :manager,
          type: type,
          roles: [buyer]
        )

      assert {:ok, _} = accept(invitation, person)

      link = link_of(organization, person)
      assert link.relationship_type_uuid == type.uuid
      assert link.all_roles == false
      assert role_names(link) == [buyer.name]
      assert link.granted_by_uuid == s.person.uuid
    end

    test "with no options it is a manager with all roles, as before" do
      %{organization: organization} = company()
      s = manager_session(organization)
      person = Fixtures.person()

      {:ok, invitation, _} =
        Invitations.create_invitation(organization, person.email, s.actor, kind: :manager)

      assert invitation.relationship_type_uuid == RelationshipType.manager_uuid()
      assert invitation.all_roles

      {:ok, _} = accept(invitation, person)

      assert %{all_roles: true, relationship_type: %{key: "manager"}} =
               link_of(organization, person)
    end

    test "inviting again with other values is refused, with the same values is the same" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      s = manager_session(organization)
      email = "again@example.com"
      opts = [kind: :manager, roles: [buyer]]

      {:ok, first, token} = Invitations.create_invitation(organization, email, s.actor, opts)
      assert token

      assert {:ok, same, nil} = Invitations.create_invitation(organization, email, s.actor, opts)
      assert same.uuid == first.uuid

      assert {:error, :invitation_pending} =
               Invitations.create_invitation(organization, email, s.actor,
                 kind: :manager,
                 roles: [supplier]
               )
    end

    test "a role deleted meanwhile leaves the person with less, never more" do
      %{organization: organization, buyer: buyer} = company()
      s = manager_session(organization)
      gone = Fixtures.role(["sitemap"], organization)
      {:ok, _} = Permissions.grant_permission(buyer.uuid, "sitemap")
      person = Fixtures.person()

      {:ok, invitation, _} =
        Invitations.create_invitation(organization, person.email, s.actor,
          kind: :manager,
          roles: [gone]
        )

      {:ok, _} = Roles.remove_role(organization, gone.name)
      {:ok, _} = Roles.delete_role(gone)

      {:ok, _} = accept(invitation, person)
      assert %{all_roles: false, role_links: []} = link_of(organization, person)
    end

    test "an archived type cannot be accepted" do
      %{organization: organization} = company()
      s = manager_session(organization)
      type = staff_type()
      person = Fixtures.person()

      {:ok, invitation, _} =
        Invitations.create_invitation(organization, person.email, s.actor,
          kind: :manager,
          type: type,
          roles: []
        )

      {:ok, _} = RelationshipTypes.archive_type(type)

      assert {:error, :relationship_type_archived} = accept(invitation, person)
    end

    test "an address already linked gets the usual answer, and its link stands" do
      %{organization: organization, buyer: buyer} = company()
      s = manager_session(organization)
      person = Fixtures.person()
      Fixtures.narrowed_link(organization, person, [buyer])

      assert {:ok, invitation, _} =
               Invitations.create_invitation(organization, person.email, s.actor,
                 kind: :manager,
                 roles: []
               )

      assert {:ok, _} = accept(invitation, person)
      assert role_names(link_of(organization, person)) == [buyer.name]
    end

    test "a staff invitation says so, a manager invitation keeps its copy" do
      %{organization: organization} = company()
      s = manager_session(organization)

      {:ok, _, _} =
        Invitations.create_invitation(organization, "staff@example.com", s.actor,
          kind: :manager,
          type: staff_type(%{name: "Warehouse hand"}),
          roles: []
        )

      assert_received {:email, %{subject: subject, text_body: body}}
      refute subject =~ "manage"
      assert body =~ "Warehouse hand"
    end
  end

  describe "reads for a host" do
    test "people_of/2 lists active people, by type" do
      %{organization: organization, buyer: buyer} = company()
      type = staff_type()
      manager = manager_session(organization)
      staff = staff_session(organization, type, [buyer])
      gone = staff_session(organization, type)

      Repo.update_all(from(u in User, where: u.uuid == ^gone.person.uuid),
        set: [is_active: false]
      )

      people = OrganizationManagers.people_of(organization.uuid)

      assert Enum.sort(Enum.map(people, & &1.person.uuid)) ==
               Enum.sort([manager.person.uuid, staff.person.uuid])

      assert [%{person: %{uuid: uuid}, all_roles?: false}] =
               OrganizationManagers.people_of(organization.uuid, type: type.key)

      assert uuid == staff.person.uuid
      assert [_] = OrganizationManagers.people_of(organization.uuid, type: type)
      assert [_] = OrganizationManagers.people_of(organization.uuid, type: "manager")
    end

    test "organizations_of/1 lists each company with what the link gives" do
      first = company()
      second = company()
      person = Fixtures.person()
      Fixtures.narrowed_link(first.organization, person, [first.buyer])
      Fixtures.manager(second.organization, person)
      closed = Fixtures.organization()
      Fixtures.manager(closed, person)
      Repo.update_all(from(u in User, where: u.uuid == ^closed.uuid), set: [is_active: false])

      by_company =
        Map.new(OrganizationManagers.organizations_of(person.uuid), &{&1.organization.uuid, &1})

      assert map_size(by_company) == 2

      narrowed = by_company[first.organization.uuid]
      assert %{all_roles?: false, type: %{key: "manager"}} = narrowed

      assert Enum.sort(Enum.map(narrowed.roles, & &1.name)) ==
               Enum.sort([first.buyer.name, "User"])

      full = by_company[second.organization.uuid]
      assert full.all_roles?
      assert second.supplier.name in Enum.map(full.roles, & &1.name)
    end
  end

  test "removing a link removes its role rows and ends the session" do
    %{organization: organization, buyer: buyer} = company()
    manager_session(organization)
    s = staff_session(organization, staff_type(), [buyer])
    uuid = s.manager.uuid

    {:ok, :ok} = OrganizationManagers.host_remove(organization.uuid, s.person.uuid, host())

    refute Auth.get_user_by_session_token(s.token)

    refute Repo.exists?(
             from(r in OrganizationManagerRole, where: r.organization_manager_uuid == ^uuid)
           )
  end
end
