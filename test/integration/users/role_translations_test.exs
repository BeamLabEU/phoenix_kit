defmodule PhoenixKit.Users.RoleTranslationsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.OrganizationManagerRole
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Multilang

  defp role!(attrs \\ %{}) do
    {:ok, role} =
      Roles.create_role(Map.merge(%{name: "Buyer #{System.unique_integer([:positive])}"}, attrs))

    role
  end

  @data %{
    "_primary_language" => "en",
    "en" => %{"_name" => "Buyer", "_description" => "Buys things"},
    "de" => %{"_name" => "Käufer"}
  }

  describe "display_name/2" do
    test "reads the language, then the primary language" do
      role = role!(%{data: @data})

      assert Roles.display_name(role, "de") == "Käufer"
      assert Roles.display_name(role, "fr") == "Buyer"
    end

    test "falls back to the name, and for a system role to its gettext string" do
      assert Roles.display_name(%{name: "Custom"}, "de") == "Custom"
      assert Roles.display_name(%{name: "Custom", data: %{}}, "de") == "Custom"
      assert Roles.display_name(%{name: "Owner"}, "en") == "Owner"
    end

    test "translations win over a system role's gettext string" do
      assert Roles.display_name(%{name: "User", data: @data}, "de") == "Käufer"
    end
  end

  test "display_description/2 reads the language, then the column" do
    role = role!(%{data: @data, description: "Column"})
    assert Roles.display_description(role, "de") == "Buys things"
    assert Roles.display_description(%{role | data: %{}}, "de") == "Column"
  end

  test "display_names/1 labels every role by name" do
    role = role!(%{data: @data})
    labels = Roles.display_names("de")

    assert labels[role.name] == "Käufer"
    assert labels["Owner"]
  end

  test "the records a scope holds carry the translations" do
    role = role!(%{data: @data})
    user = Fixtures.person()
    {:ok, _} = Roles.assign_role(user, role.name)

    records = Roles.get_user_role_records(user)
    assert %{data: data} = Enum.find(records, &(&1.uuid == role.uuid))
    assert data == @data

    batch = Map.fetch!(Roles.get_role_records_for_users([user.uuid]), user.uuid)
    assert Enum.any?(batch, &(&1.data == @data))
  end

  describe "update_role/2" do
    test "writes translations, description and position" do
      role = role!()
      data = Multilang.build_text_data(%{"_name" => %{"en" => "Buyer", "de" => "Käufer"}})

      assert {:ok, updated} =
               Roles.update_role(role, %{data: data, description: "New", position: 9})

      assert Roles.display_name(updated, "de") == "Käufer"
      assert updated.description == "New"
      assert updated.position == 9
    end

    test "refuses a rename, and a blank name" do
      role = role!()

      for name <- ["Renamed", "", nil] do
        assert {:error, changeset} = Roles.update_role(role, %{name: name})
        assert Keyword.has_key?(changeset.errors, :name)
      end

      assert Repo.get(Role, role.uuid).name == role.name
    end

    test "accepts the name it already has, as a form sends it" do
      role = role!()
      assert {:ok, _} = Roles.update_role(role, %{"name" => role.name, "description" => "x"})
    end

    test "cannot turn a role into a system role" do
      role = role!()
      assert {:ok, %{is_system_role: false}} = Roles.update_role(role, %{is_system_role: true})
    end

    test "refuses a data map that would crash its readers" do
      assert {:error, changeset} = Roles.update_role(role!(), %{data: %{"_name" => 1}})
      assert Keyword.has_key?(changeset.errors, :data)
    end
  end

  describe "delete_role/2" do
    test "a role on a link is in use, though no account holds it" do
      role = role!()
      s = Fixtures.acting_session()

      Repo.insert!(%OrganizationManagerRole{
        organization_manager_uuid: s.manager.uuid,
        role_uuid: role.uuid
      })

      assert {:error, :role_in_use} = Roles.delete_role(role)
      assert Repo.get(Role, role.uuid)
    end

    test "an unused role is still deleted" do
      role = role!()
      assert {:ok, _} = Roles.delete_role(role)
      refute Repo.get(Role, role.uuid)
    end
  end
end
