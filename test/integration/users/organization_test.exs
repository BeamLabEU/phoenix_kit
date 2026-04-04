defmodule PhoenixKit.Integration.Users.OrganizationTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth

  defp unique_email, do: "org_#{System.unique_integer([:positive])}@example.com"

  defp create_person(overrides \\ %{}) do
    attrs = Map.merge(%{email: unique_email(), password: "ValidPassword123!"}, overrides)
    {:ok, user} = Auth.register_user(attrs)
    user
  end

  defp create_org(name \\ "Acme Corp") do
    {:ok, base} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})

    {:ok, org} =
      Auth.change_account_type(base, %{account_type: "organization", organization_name: name})

    org
  end

  # --- list_organizations/0 ---

  describe "list_organizations/0" do
    test "returns only organization-type users" do
      org = create_org()
      person = create_person()
      orgs = Auth.list_organizations()
      uuids = Enum.map(orgs, & &1.uuid)
      assert org.uuid in uuids
      refute person.uuid in uuids
    end

    test "returns a list" do
      assert is_list(Auth.list_organizations())
    end

    test "orders by organization_name ascending" do
      _z = create_org("Zebra Corp")
      _a = create_org("Acme Corp")
      orgs = Auth.list_organizations()

      names =
        Enum.map(orgs, & &1.organization_name)
        |> Enum.filter(&(&1 in ["Zebra Corp", "Acme Corp"]))

      assert names == Enum.sort(names)
    end
  end

  # --- list_organization_members/1 ---

  describe "list_organization_members/1" do
    test "returns members of given organization" do
      org = create_org()
      person = create_person()
      {:ok, _} = Auth.set_organization(person, org.uuid)
      members = Auth.list_organization_members(org.uuid)
      assert Enum.any?(members, &(&1.uuid == person.uuid))
    end

    test "returns empty list for org with no members" do
      org = create_org()
      assert Auth.list_organization_members(org.uuid) == []
    end

    test "does not return members of other organization" do
      org1 = create_org("Org One")
      org2 = create_org("Org Two")
      person = create_person()
      {:ok, _} = Auth.set_organization(person, org1.uuid)
      assert Auth.list_organization_members(org2.uuid) == []
    end

    test "orders results by email ascending" do
      org = create_org()
      person1 = create_person(%{email: "zzz_#{System.unique_integer([:positive])}@example.com"})
      person2 = create_person(%{email: "aaa_#{System.unique_integer([:positive])}@example.com"})
      {:ok, _} = Auth.set_organization(person1, org.uuid)
      {:ok, _} = Auth.set_organization(person2, org.uuid)
      members = Auth.list_organization_members(org.uuid)
      emails = Enum.map(members, & &1.email)
      assert emails == Enum.sort(emails)
    end
  end

  # --- set_organization/2 ---

  describe "set_organization/2" do
    test "successfully sets organization for a person user" do
      org = create_org()
      person = create_person()
      assert {:ok, updated} = Auth.set_organization(person, org.uuid)
      assert updated.organization_uuid == org.uuid
    end

    test "returns error when target user is not an organization" do
      person1 = create_person()
      person2 = create_person()
      assert {:error, message} = Auth.set_organization(person1, person2.uuid)
      assert message =~ "not an organization"
    end

    test "returns error when user is an organization type" do
      org1 = create_org("Org1")
      org2 = create_org("Org2")
      assert {:error, _reason} = Auth.set_organization(org1, org2.uuid)
    end

    test "returns error when organization uuid does not exist" do
      person = create_person()
      assert {:error, message} = Auth.set_organization(person, UUIDv7.generate())
      assert message =~ "not found"
    end

    test "returns error when user tries to reference self" do
      org = create_org()
      assert {:error, message} = Auth.set_organization(org, org.uuid)
      assert message =~ "self"
    end

    test "person can be reassigned to a different org" do
      org1 = create_org("Org1")
      org2 = create_org("Org2")
      person = create_person()
      {:ok, _} = Auth.set_organization(person, org1.uuid)
      assert {:ok, updated} = Auth.set_organization(person, org2.uuid)
      assert updated.organization_uuid == org2.uuid
    end
  end

  # --- remove_from_organization/1 ---

  describe "remove_from_organization/1" do
    test "removes user from organization" do
      org = create_org()
      person = create_person()
      {:ok, member} = Auth.set_organization(person, org.uuid)
      assert {:ok, removed} = Auth.remove_from_organization(member)
      assert is_nil(removed.organization_uuid)
    end

    test "succeeds even if user has no organization" do
      person = create_person()
      assert {:ok, updated} = Auth.remove_from_organization(person)
      assert is_nil(updated.organization_uuid)
    end
  end

  # --- change_account_type/2 ---

  describe "change_account_type/2" do
    test "changes person to organization" do
      person = create_person()

      assert {:ok, org} =
               Auth.change_account_type(person, %{
                 account_type: "organization",
                 organization_name: "Acme"
               })

      assert org.account_type == "organization"
      assert org.organization_name == "Acme"
    end

    test "changes organization to person when no members" do
      org = create_org()
      assert {:ok, person} = Auth.change_account_type(org, %{account_type: "person"})
      assert person.account_type == "person"
    end

    test "returns error changing org to person when members exist" do
      org = create_org()
      person = create_person()
      {:ok, _} = Auth.set_organization(person, org.uuid)
      assert {:error, message} = Auth.change_account_type(org, %{account_type: "person"})
      assert message =~ "members"
    end

    test "person to org requires organization_name" do
      person = create_person()

      assert {:error, changeset} =
               Auth.change_account_type(person, %{account_type: "organization"})

      assert "can't be blank" in errors_on(changeset).organization_name
    end

    test "org to org updates organization_name" do
      org = create_org("Old Name")

      assert {:ok, updated} =
               Auth.change_account_type(org, %{
                 account_type: "organization",
                 organization_name: "New Name"
               })

      assert updated.organization_name == "New Name"
    end
  end

  # --- list_available_members_for_organization/1 ---

  describe "list_available_members_for_organization/1" do
    test "returns person users with no organization" do
      org = create_org()
      person1 = create_person()
      person2 = create_person()
      available = Auth.list_available_members_for_organization(org.uuid)
      uuids = Enum.map(available, & &1.uuid)
      assert person1.uuid in uuids
      assert person2.uuid in uuids
    end

    test "excludes the organization itself" do
      org = create_org()
      available = Auth.list_available_members_for_organization(org.uuid)
      uuids = Enum.map(available, & &1.uuid)
      refute org.uuid in uuids
    end

    test "excludes users already in an organization" do
      org1 = create_org("Org1")
      org2 = create_org("Org2")
      person = create_person()
      {:ok, _} = Auth.set_organization(person, org1.uuid)
      available = Auth.list_available_members_for_organization(org2.uuid)
      uuids = Enum.map(available, & &1.uuid)
      refute person.uuid in uuids
    end

    test "excludes organization-type users" do
      org1 = create_org("Org1")
      org2 = create_org("Org2")
      available = Auth.list_available_members_for_organization(org1.uuid)
      uuids = Enum.map(available, & &1.uuid)
      refute org2.uuid in uuids
    end

    test "returns empty list when all persons are already members" do
      org = create_org()
      person = create_person()
      {:ok, _} = Auth.set_organization(person, org.uuid)
      available = Auth.list_available_members_for_organization(org.uuid)
      uuids = Enum.map(available, & &1.uuid)
      refute person.uuid in uuids
    end
  end
end
