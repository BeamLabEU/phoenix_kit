defmodule PhoenixKit.Integration.Users.PermissionsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  defp unique_email, do: "perms_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    user
  end

  defp create_standard_user do
    _owner = create_user()
    create_user()
  end

  defp get_role_uuid(role_name) do
    role = Enum.find(Roles.list_roles(), &(&1.name == role_name))
    role.uuid
  end

  describe "grant_permission/3" do
    test "grants permission to role" do
      role_uuid = get_role_uuid("User")

      assert {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert "dashboard" in perms
    end

    test "is idempotent" do
      role_uuid = get_role_uuid("User")

      assert {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")
      assert {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")
    end
  end

  describe "revoke_permission/2" do
    test "removes granted permission" do
      role_uuid = get_role_uuid("User")

      {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")
      assert :ok = Permissions.revoke_permission(role_uuid, "dashboard")

      perms = Permissions.get_permissions_for_role(role_uuid)
      refute "dashboard" in perms
    end

    test "returns error for non-existent permission" do
      role_uuid = get_role_uuid("User")

      assert {:error, :not_found} = Permissions.revoke_permission(role_uuid, "nonexistent_key")
    end
  end

  describe "set_permissions/3" do
    test "syncs role to desired permission set" do
      role_uuid = get_role_uuid("User")

      {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")
      {:ok, _} = Permissions.grant_permission(role_uuid, "users")

      Permissions.set_permissions(role_uuid, ["dashboard", "settings"])

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert "dashboard" in perms
      assert "settings" in perms
      refute "users" in perms
    end

    test "empty list revokes all permissions" do
      role_uuid = get_role_uuid("User")

      {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")
      {:ok, _} = Permissions.grant_permission(role_uuid, "users")

      Permissions.set_permissions(role_uuid, [])

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert perms == []
    end

    test "invalid keys are filtered out" do
      role_uuid = get_role_uuid("User")

      Permissions.set_permissions(role_uuid, ["dashboard", "totally_fake_key_xyz"])

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert "dashboard" in perms
      refute "totally_fake_key_xyz" in perms
    end
  end

  describe "role_has_permission?/2" do
    test "returns true when permission is granted" do
      role_uuid = get_role_uuid("User")
      {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")

      assert Permissions.role_has_permission?(role_uuid, "dashboard")
    end

    test "returns false when permission is not granted" do
      role_uuid = get_role_uuid("User")

      # Clear permissions first
      Permissions.set_permissions(role_uuid, [])

      refute Permissions.role_has_permission?(role_uuid, "dashboard")
    end
  end

  describe "grant_all_permissions/2" do
    test "grants all available module permissions to a role" do
      role_uuid = get_role_uuid("User")

      # Clear first
      Permissions.set_permissions(role_uuid, [])

      Permissions.grant_all_permissions(role_uuid)

      perms = Permissions.get_permissions_for_role(role_uuid)
      all_keys = Permissions.all_module_keys()

      Enum.each(all_keys, fn key ->
        assert key in perms, "Expected permission #{key} to be granted"
      end)
    end
  end

  describe "copy_permissions/3" do
    test "copies all permissions from source to target role" do
      source_uuid = get_role_uuid("Admin")
      {:ok, target_role} = Roles.create_role(%{name: "CopyTarget"})

      Permissions.set_permissions(source_uuid, ["dashboard", "users", "settings"])

      Permissions.copy_permissions(source_uuid, target_role.uuid)

      target_perms = Permissions.get_permissions_for_role(target_role.uuid)
      assert "dashboard" in target_perms
      assert "users" in target_perms
      assert "settings" in target_perms
    end
  end

  describe "count_permissions_for_role/1" do
    test "returns correct count" do
      role_uuid = get_role_uuid("User")

      Permissions.set_permissions(role_uuid, ["dashboard", "users"])

      assert Permissions.count_permissions_for_role(role_uuid) == 2
    end

    test "returns 0 when no permissions" do
      {:ok, role} = Roles.create_role(%{name: "NoPerm"})

      assert Permissions.count_permissions_for_role(role.uuid) == 0
    end
  end

  describe "get_permissions_for_user/1" do
    test "returns permissions from user's roles" do
      user = create_standard_user()
      role_uuid = get_role_uuid("User")

      {:ok, _} = Permissions.grant_permission(role_uuid, "dashboard")

      perms = Permissions.get_permissions_for_user(user)
      assert "dashboard" in perms
    end

    test "returns empty list for nil user" do
      assert Permissions.get_permissions_for_user(nil) == []
    end
  end

  describe "multiple roles merge permissions" do
    test "user with two roles gets union of permissions" do
      user = create_standard_user()
      user_role_uuid = get_role_uuid("User")
      admin_role_uuid = get_role_uuid("Admin")

      Permissions.set_permissions(user_role_uuid, ["dashboard"])
      Permissions.set_permissions(admin_role_uuid, ["users", "settings"])

      {:ok, _} = Roles.assign_role(user, "Admin")

      perms = Permissions.get_permissions_for_user(user)
      assert "dashboard" in perms
      assert "users" in perms
      assert "settings" in perms
    end
  end

  describe "Scope integration with permissions" do
    test "Owner scope has all permissions" do
      # First user gets Owner
      owner = create_user()

      scope = Scope.for_user(owner)
      assert Scope.owner?(scope)
      assert Scope.has_module_access?(scope, "dashboard")
      assert Scope.has_module_access?(scope, "users")
      assert Scope.has_module_access?(scope, "settings")
    end

    test "User scope reflects granted permissions" do
      Permissions.register_custom_key("posts")
      user = create_standard_user()
      role_uuid = get_role_uuid("User")

      Permissions.set_permissions(role_uuid, ["dashboard", "posts"])

      scope = Scope.for_user(user)
      assert Scope.has_module_access?(scope, "dashboard")
      assert Scope.has_module_access?(scope, "posts")
      refute Scope.has_module_access?(scope, "settings")
      Permissions.unregister_custom_key("posts")
    end

    test "Admin scope with explicit permissions" do
      user = create_standard_user()
      {:ok, _} = Roles.assign_role(user, "Admin")

      admin_uuid = get_role_uuid("Admin")
      Permissions.set_permissions(admin_uuid, ["dashboard", "users", "settings"])

      scope = Scope.for_user(user)
      assert Scope.admin?(scope)
      assert Scope.has_module_access?(scope, "dashboard")
      assert Scope.has_module_access?(scope, "users")
    end

    test "has_any_module_access?/2 checks multiple keys" do
      user = create_standard_user()
      role_uuid = get_role_uuid("User")
      Permissions.set_permissions(role_uuid, ["dashboard"])

      scope = Scope.for_user(user)
      assert Scope.has_any_module_access?(scope, ["dashboard", "settings"])
      refute Scope.has_any_module_access?(scope, ["billing", "shop"])
    end

    test "has_all_module_access?/2 requires all keys" do
      user = create_standard_user()
      role_uuid = get_role_uuid("User")
      Permissions.set_permissions(role_uuid, ["dashboard", "users"])

      scope = Scope.for_user(user)
      assert Scope.has_all_module_access?(scope, ["dashboard", "users"])
      refute Scope.has_all_module_access?(scope, ["dashboard", "users", "settings"])
    end
  end

  describe "Scope.for_user/1" do
    test "nil user creates anonymous scope" do
      scope = Scope.for_user(nil)

      refute Scope.authenticated?(scope)
      refute Scope.owner?(scope)
      refute Scope.admin?(scope)
      assert Scope.user_roles(scope) == []
      assert Scope.accessible_modules(scope) == MapSet.new()
      assert Scope.permission_count(scope) == 0
    end

    test "authenticated? returns true for real user" do
      user = create_user()

      scope = Scope.for_user(user)
      assert Scope.authenticated?(scope)
    end
  end

  describe "Scope.system_role?/1" do
    test "returns true for Owner" do
      owner = create_user()

      scope = Scope.for_user(owner)
      assert Scope.system_role?(scope)
    end

    test "returns true for Admin" do
      user = create_standard_user()
      {:ok, _} = Roles.assign_role(user, "Admin")

      scope = Scope.for_user(user)
      assert Scope.system_role?(scope)
    end

    test "returns false for User-only role" do
      user = create_standard_user()

      scope = Scope.for_user(user)
      refute Scope.system_role?(scope)
    end

    test "returns false for anonymous" do
      scope = Scope.for_user(nil)
      refute Scope.system_role?(scope)
    end
  end

  describe "Scope.user_roles/1" do
    test "returns cached role names" do
      user = create_standard_user()
      {:ok, _} = Roles.assign_role(user, "Admin")

      scope = Scope.for_user(user)
      roles = Scope.user_roles(scope)

      assert "User" in roles
      assert "Admin" in roles
    end
  end

  describe "Scope.accessible_modules/1" do
    test "returns MapSet of granted permissions" do
      user = create_standard_user()
      role_uuid = get_role_uuid("User")
      Permissions.set_permissions(role_uuid, ["dashboard", "users"])

      scope = Scope.for_user(user)
      modules = Scope.accessible_modules(scope)

      assert MapSet.member?(modules, "dashboard")
      assert MapSet.member?(modules, "users")
    end

    test "returns empty MapSet for anonymous" do
      scope = Scope.for_user(nil)
      assert Scope.accessible_modules(scope) == MapSet.new()
    end
  end

  describe "Scope.permission_count/1" do
    test "returns count of granted permissions" do
      user = create_standard_user()
      role_uuid = get_role_uuid("User")
      Permissions.set_permissions(role_uuid, ["dashboard", "users", "settings"])

      scope = Scope.for_user(user)
      assert Scope.permission_count(scope) == 3
    end

    test "returns 0 for anonymous" do
      scope = Scope.for_user(nil)
      assert Scope.permission_count(scope) == 0
    end
  end
end
