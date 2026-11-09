defmodule PhoenixKit.Integration.Users.ActingLinkScopeTest do
  @moduledoc """
  What a person may do while acting for an organization: the organization's roles,
  narrowed by their link. `Scope.for_user/2`, the role switcher and the session lists
  must all agree, and no way of building a scope may come out wider than the session.

  Settings writes stay in each test's sandbox transaction; synchronous because
  `active_role_scope_test.exs` shows role order rows conflict across sandboxes.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage.LibraryOperations
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.ActingLink
  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions

  defp switcher_on, do: Settings.update_boolean_setting("role_switcher_enabled", true)

  # A company holding Buyer (`users`) and Supplier (`media`).
  defp company do
    organization = Fixtures.organization()
    buyer = Fixtures.role(["users"], organization)
    supplier = Fixtures.role(["media"], organization)
    %{organization: organization, buyer: buyer, supplier: supplier}
  end

  defp acting(organization, roles) do
    person = Fixtures.person()
    link = Fixtures.narrowed_link(organization, person, roles)
    Fixtures.enter(organization, person, link)
  end

  describe "a link with all roles" do
    test "behaves exactly as a grant did: every role the company holds" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      person = Fixtures.person()
      link = Fixtures.manager(organization, person)

      scope = Scope.for_user(Fixtures.enter(organization, person, link).user)

      assert Enum.sort(Scope.user_roles(scope)) == Enum.sort([buyer.name, supplier.name, "User"])
      assert Scope.has_module_access?(scope, "users")
      assert Scope.has_module_access?(scope, "media")

      assert %{
               type_key: "manager",
               can_manage?: true,
               all_roles?: true,
               role_uuids: []
             } = Scope.acting_link(scope)

      assert Scope.can_manage_organization?(scope)
    end

    test "gets the switcher when the company holds two roles" do
      switcher_on()
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      person = Fixtures.person()
      link = Fixtures.manager(organization, person)

      scope = Scope.for_user(Fixtures.enter(organization, person, link).user)

      assert Enum.sort(Enum.map(scope.switchable_roles, & &1.name)) ==
               Enum.sort([buyer.name, supplier.name])
    end
  end

  describe "a narrowed link" do
    test "gives only its roles' permissions, and no switcher for one role" do
      switcher_on()
      %{organization: organization, buyer: buyer} = company()

      scope = Scope.for_user(acting(organization, [buyer]).user)

      assert Enum.sort(Scope.user_roles(scope)) == Enum.sort([buyer.name, "User"])
      assert Scope.has_module_access?(scope, "users")
      refute Scope.has_module_access?(scope, "media")
      assert scope.switchable_roles == []
      assert Scope.active_role(scope) == nil
      assert %{all_roles?: false} = Scope.acting_link(scope)
      assert Scope.acting_link(scope).role_uuids == [buyer.uuid]
    end

    test "with both roles gets the switcher, and acts as one" do
      switcher_on()
      %{organization: organization, buyer: buyer, supplier: supplier} = company()

      scope = Scope.for_user(acting(organization, [buyer, supplier]).user)

      assert length(scope.switchable_roles) == 2
      assert %{uuid: _} = Scope.active_role(scope)
    end

    test "a role the company does not hold has no effect" do
      %{organization: organization, buyer: buyer} = company()
      elsewhere = Fixtures.role(["sitemap"])

      scope = Scope.for_user(acting(organization, [buyer, elsewhere]).user)

      refute elsewhere.name in Scope.user_roles(scope)
      refute Scope.has_module_access?(scope, "sitemap")
      assert Scope.has_module_access?(scope, "users")
    end

    test "with no roles gives nothing beyond the base role, never every role" do
      %{organization: organization} = company()

      scope = Scope.for_user(acting(organization, []).user)

      assert Scope.user_roles(scope) == ["User"]
      refute Scope.has_module_access?(scope, "users")
      refute Scope.has_module_access?(scope, "media")
    end

    test "gives back a role when the company regains it, and not before" do
      %{organization: organization, supplier: supplier} = company()
      s = acting(organization, [supplier])

      assert {:ok, _} = Roles.remove_role(organization, supplier.name)
      refute Scope.has_module_access?(Scope.for_user(s.user), "media")

      assert {:ok, _} = Roles.assign_role(organization, supplier.name)
      assert Scope.has_module_access?(Scope.for_user(s.user), "media")
    end

    test "the managed ceiling still applies on top" do
      %{organization: organization, buyer: buyer} = company()
      {:ok, _} = Permissions.grant_permission(buyer.uuid, "api")

      scope = Scope.for_user(acting(organization, [buyer]).user)

      assert Scope.has_module_access?(scope, "users")
      refute Scope.has_module_access?(scope, "api")
    end

    test "narrow: false widens past the switcher, never past the link" do
      switcher_on()
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      third = Fixtures.role(["sitemap"], organization)

      user = acting(organization, [buyer, supplier]).user
      scope = Scope.for_user(user, narrow: false)

      assert Scope.has_module_access?(scope, "users")
      assert Scope.has_module_access?(scope, "media")
      refute third.name in Scope.user_roles(scope)
      refute Scope.has_module_access?(scope, "sitemap")
    end
  end

  test "one person gets each company's link, in separate sessions" do
    first = company()
    second = company()
    person = Fixtures.person()

    in_first =
      Fixtures.enter(
        first.organization,
        person,
        Fixtures.narrowed_link(first.organization, person, [first.buyer])
      )

    in_second =
      Fixtures.enter(
        second.organization,
        person,
        Fixtures.narrowed_link(second.organization, person, [second.supplier])
      )

    assert Scope.has_module_access?(Scope.for_user(in_first.user), "users")
    refute Scope.has_module_access?(Scope.for_user(in_first.user), "media")

    assert Scope.has_module_access?(Scope.for_user(in_second.user), "media")
    refute Scope.has_module_access?(Scope.for_user(in_second.user), "users")
  end

  describe "the scope and the role switcher agree" do
    test "on the roles in effect" do
      %{organization: organization, buyer: buyer} = company()
      user = acting(organization, [buyer]).user

      assert Enum.sort(ActiveRole.effective_role_names(user)) ==
               Enum.sort(Scope.user_roles(Scope.for_user(user)))
    end

    test "switching refuses a role outside the link, and accepts one on it" do
      switcher_on()
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      third = Fixtures.role(["sitemap"], organization)

      s = acting(organization, [buyer, supplier])

      assert {:error, :not_switchable} = ActiveRole.switch(s.user, s.token, third.uuid)
      assert {:ok, %{uuid: uuid}} = ActiveRole.switch(s.user, s.token, supplier.uuid)
      assert uuid == supplier.uuid

      scope = s.token |> Auth.get_user_by_session_token() |> Scope.for_user()
      assert Scope.active_role(scope).uuid == supplier.uuid
      assert Scope.has_module_access?(scope, "media")
      refute Scope.has_module_access?(scope, "users")
    end

    test "switching is refused with one role on the link" do
      switcher_on()
      %{organization: organization, buyer: buyer} = company()
      s = acting(organization, [buyer])

      assert {:error, :not_switchable} = ActiveRole.switch(s.user, s.token, buyer.uuid)
    end

    test "the session lists show the role acted as, within the link" do
      switcher_on()
      %{organization: organization, buyer: buyer, supplier: supplier} = company()

      narrowed = acting(organization, [buyer])
      both = acting(organization, [buyer, supplier])
      {:ok, _} = ActiveRole.switch(both.user, both.token, supplier.uuid)

      names =
        Map.new(Sessions.list_active_sessions(), fn session ->
          {session.token_uuid, session.active_role}
        end)

      assert Map.fetch!(names, narrowed.row.uuid) == nil
      assert Map.fetch!(names, both.row.uuid) == supplier.name
    end
  end

  describe "held_roles/1 is the company's, and says nothing about the person" do
    test "the case WoodMatrix met: only Supplier on the link at a company holding both" do
      switcher_on()
      %{organization: organization, buyer: buyer, supplier: supplier} = company()

      scope = Scope.for_user(acting(organization, [supplier]).user)

      assert Enum.sort(Scope.user_roles(scope)) == Enum.sort([supplier.name, "User"])
      assert Scope.active_role(scope) == nil
      assert buyer.name in Scope.held_roles(scope)
      refute Scope.has_module_access?(scope, "users")
    end

    test "so nobody edits a role of the company they act for" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      {:ok, _} = Permissions.grant_permission(supplier.uuid, "users")

      scope = Scope.for_user(acting(organization, [supplier]).user)

      assert {:error, :self_role} = Permissions.can_edit_role_permissions?(scope, buyer)
    end
  end

  describe "a scope is never wider than a session could be" do
    defp outside_session(organization), do: Repo.get!(User, organization.uuid) |> Scope.for_user()

    test "outside a session a company with nobody narrowed keeps every role, as it always did" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      Fixtures.manager(organization, Fixtures.person())
      Fixtures.manager(organization, Fixtures.person())

      for user <- [organization, Repo.get!(User, organization.uuid)] do
        scope = Scope.for_user(user)

        assert Enum.sort(Scope.user_roles(scope)) ==
                 Enum.sort([buyer.name, supplier.name, "User"])

        assert Scope.has_module_access?(scope, "users")
        assert Scope.acting_link(scope) == nil
        refute Scope.can_manage_organization?(scope)
      end
    end

    test "outside a session a company with no links keeps its roles" do
      %{organization: organization, buyer: buyer} = company()
      assert buyer.name in Scope.user_roles(outside_session(organization))
    end

    test "once someone is narrowed, it is never wider than their session" do
      %{organization: organization, buyer: buyer} = company()
      Fixtures.manager(organization, Fixtures.person())
      Fixtures.narrowed_link(organization, Fixtures.person(), [buyer])

      scope = outside_session(organization)

      assert Enum.sort(Scope.user_roles(scope)) == Enum.sort([buyer.name, "User"])
      assert Scope.has_module_access?(scope, "users")
      refute Scope.has_module_access?(scope, "media")
    end

    test "with people narrowed differently it keeps only what they share" do
      %{organization: organization, buyer: buyer, supplier: supplier} = company()
      Fixtures.narrowed_link(organization, Fixtures.person(), [buyer, supplier])
      Fixtures.narrowed_link(organization, Fixtures.person(), [supplier])

      assert Enum.sort(Scope.user_roles(outside_session(organization))) ==
               Enum.sort([supplier.name, "User"])

      Fixtures.narrowed_link(organization, Fixtures.person(), [buyer])
      assert Scope.user_roles(outside_session(organization)) == ["User"]
    end

    test "someone with no roles on their link leaves nothing beyond the base role" do
      %{organization: organization} = company()
      Fixtures.manager(organization, Fixtures.person())
      Fixtures.narrowed_link(organization, Fixtures.person(), [])

      assert Scope.user_roles(outside_session(organization)) == ["User"]
    end

    test "a link that is gone, or belongs to another company, gives nothing" do
      %{organization: organization, buyer: buyer} = company()
      other = company()
      s = acting(organization, [buyer])

      assert Scope.user_roles(
               Scope.for_user(%{s.user | organization_manager_uuid: UUIDv7.generate()})
             ) == []

      foreign = %{other.organization | organization_manager_uuid: s.manager.uuid}
      assert Scope.user_roles(Scope.for_user(foreign)) == []
    end

    test "an ordinary account is untouched and has no link" do
      person = Fixtures.person()
      scope = Scope.for_user(person)

      assert Scope.user_roles(scope) == ["User"]
      assert Scope.acting_link(scope) == nil
      assert ActingLink.for_user(person) == nil
    end

    test "a reload by uuid inside library operations stays the same session" do
      Settings.update_boolean_setting("storage_user_libraries_enabled", true)
      %{organization: organization} = company()
      storage = Fixtures.role(["storage"], organization)

      allowed = Scope.for_user(acting(organization, [storage]).user)
      refused = Scope.for_user(acting(organization, []).user)

      assert Scope.has_module_access?(allowed, "storage")
      assert LibraryOperations.libraries(allowed) == []
      assert LibraryOperations.libraries(refused) == []
    end
  end

  test "User.put_session_fields/2 carries every session-only field" do
    s = Fixtures.acting_session()
    user = Auth.get_user_by_session_token(s.token)
    reloaded = Repo.get!(User, user.uuid)

    assert reloaded.organization_manager_uuid == nil

    carried = User.put_session_fields(reloaded, user)
    assert carried.organization_manager_uuid == s.manager.uuid
    assert carried.acting_session_uuid == s.root.uuid
    assert carried.acting_user_uuid == s.person.uuid
  end

  test "a link's type is read through to the scope" do
    %{organization: organization} = company()
    {:ok, staff} = staff_type()
    person = Fixtures.person()

    link =
      Fixtures.narrowed_link(organization, person, [], %{relationship_type_uuid: staff.uuid})

    scope = Scope.for_user(Fixtures.enter(organization, person, link).user)

    assert %{type_key: key, can_manage?: false} = Scope.acting_link(scope)
    assert key == staff.key
    refute Scope.can_manage_organization?(scope)
    assert staff.uuid != RelationshipType.manager_uuid()
  end

  defp staff_type do
    RelationshipTypes.create_type(%{
      key: "staff_#{System.unique_integer([:positive])}",
      name: "Staff",
      from_kind: "person",
      to_kind: "organization",
      can_act: true,
      can_manage: false
    })
  end
end
