defmodule PhoenixKit.Users.RoleTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Role

  # --- changeset/2 ---

  describe "changeset/2 with valid data" do
    test "accepts valid name" do
      changeset = Role.changeset(%Role{}, %{name: "Editor"})
      assert changeset.valid?
    end

    test "accepts name with description" do
      changeset = Role.changeset(%Role{}, %{name: "Editor", description: "Can edit posts"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :description) == "Can edit posts"
    end

    test "accepts name at max length (50 chars)" do
      name = String.duplicate("a", 50)
      changeset = Role.changeset(%Role{}, %{name: name})
      assert changeset.valid?
    end

    test "accepts description at max length (500 chars)" do
      desc = String.duplicate("a", 500)
      changeset = Role.changeset(%Role{}, %{name: "Test", description: desc})
      assert changeset.valid?
    end
  end

  describe "changeset/2 with invalid data" do
    test "requires name" do
      changeset = Role.changeset(%Role{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :name)
    end

    test "rejects empty name" do
      changeset = Role.changeset(%Role{}, %{name: ""})
      refute changeset.valid?
    end

    test "rejects name over 50 characters" do
      name = String.duplicate("a", 51)
      changeset = Role.changeset(%Role{}, %{name: name})
      refute changeset.valid?
      assert has_error?(changeset, :name)
    end

    test "rejects description over 500 characters" do
      desc = String.duplicate("a", 501)
      changeset = Role.changeset(%Role{}, %{name: "Test", description: desc})
      refute changeset.valid?
      assert has_error?(changeset, :description)
    end
  end

  describe "changeset/2 updating existing role" do
    test "allows renaming a non-system role" do
      role = %Role{name: "Editor", is_system_role: false}
      changeset = Role.changeset(role, %{name: "Senior Editor"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "Senior Editor"
    end

    test "allows updating description on existing role" do
      role = %Role{name: "Editor", is_system_role: false}
      changeset = Role.changeset(role, %{description: "Updated desc"})
      assert changeset.valid?
    end

    test "no-op changeset is valid (no changes)" do
      role = %Role{name: "Editor", is_system_role: false}
      changeset = Role.changeset(role, %{})
      assert changeset.valid?
    end

    test "allows nil description" do
      changeset = Role.changeset(%Role{}, %{name: "Test", description: nil})
      assert changeset.valid?
    end
  end

  describe "changeset/2 system role protection" do
    test "blocks unsetting is_system_role on a system role" do
      role = %Role{is_system_role: true, name: "Admin"}
      changeset = Role.changeset(role, %{is_system_role: false})
      refute changeset.valid?
      assert "system roles cannot be modified" in errors_on(changeset, :is_system_role)
    end

    test "allows keeping is_system_role true" do
      role = %Role{is_system_role: true, name: "Admin"}
      changeset = Role.changeset(role, %{name: "Admin"})
      assert changeset.valid?
    end

    test "allows setting is_system_role on new role" do
      changeset = Role.changeset(%Role{}, %{name: "Custom", is_system_role: true})
      assert changeset.valid?
    end

    test "allows unsetting is_system_role on non-system role (no-op)" do
      role = %Role{is_system_role: false, name: "Editor"}
      changeset = Role.changeset(role, %{is_system_role: false})
      assert changeset.valid?
    end

    test "protection applies to all system roles" do
      for name <- ["Owner", "Admin", "User"] do
        role = %Role{is_system_role: true, name: name}
        changeset = Role.changeset(role, %{is_system_role: false})
        refute changeset.valid?, "Expected #{name} system role to be protected"
      end
    end
  end

  # --- system_roles/0 ---

  describe "system_roles/0" do
    test "returns the three system roles" do
      roles = Role.system_roles()
      assert roles.owner == "Owner"
      assert roles.admin == "Admin"
      assert roles.user == "User"
      assert map_size(roles) == 3
    end
  end

  # --- system_role?/1 ---

  describe "system_role?/1" do
    test "returns true for Owner" do
      assert Role.system_role?("Owner")
    end

    test "returns true for Admin" do
      assert Role.system_role?("Admin")
    end

    test "returns true for User" do
      assert Role.system_role?("User")
    end

    test "returns false for custom role names" do
      refute Role.system_role?("Editor")
      refute Role.system_role?("Manager")
    end

    test "is case-sensitive" do
      refute Role.system_role?("owner")
      refute Role.system_role?("ADMIN")
    end
  end

  # --- Helpers ---

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end

  defp has_error?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end
end
