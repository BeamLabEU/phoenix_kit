defmodule PhoenixKit.Users.Auth.ScopeTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  # --- Test Helpers ---

  defp build_user(opts \\ []) do
    %User{
      id: Keyword.get(opts, :id, 1),
      uuid: Keyword.get(opts, :uuid, "user-uuid-123"),
      email: Keyword.get(opts, :email, "test@example.com"),
      first_name: Keyword.get(opts, :first_name, "Test"),
      last_name: Keyword.get(opts, :last_name, "User")
    }
  end

  defp build_scope(roles, opts \\ []) do
    perms = Keyword.get(opts, :permissions, nil)

    %Scope{
      user: Keyword.get(opts, :user, build_user()),
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: perms
    }
  end

  # --- owner?/1 ---

  describe "owner?/1" do
    test "returns true when user has Owner role" do
      scope = build_scope(["Owner"])
      assert Scope.owner?(scope)
    end

    test "returns true when user has Owner among multiple roles" do
      scope = build_scope(["Admin", "Owner"])
      assert Scope.owner?(scope)
    end

    test "returns false when user does not have Owner role" do
      scope = build_scope(["Admin"])
      refute Scope.owner?(scope)
    end

    test "returns false when user has no roles" do
      scope = build_scope([])
      refute Scope.owner?(scope)
    end

    test "returns false for nil user" do
      scope = %Scope{user: nil, authenticated?: false}
      refute Scope.owner?(scope)
    end
  end

  # --- admin?/1 ---

  describe "admin?/1" do
    test "returns true for Owner" do
      scope = build_scope(["Owner"])
      assert Scope.admin?(scope)
    end

    test "returns true for Admin" do
      scope = build_scope(["Admin"])
      assert Scope.admin?(scope)
    end

    test "returns false for User role without permissions" do
      scope = build_scope(["User"])
      refute Scope.admin?(scope)
    end

    test "returns true for custom role WITH permissions" do
      scope = build_scope(["Editor"], permissions: MapSet.new(["dashboard"]))
      assert Scope.admin?(scope)
    end

    test "returns false for custom role with empty permissions" do
      scope = build_scope(["Editor"], permissions: MapSet.new())
      refute Scope.admin?(scope)
    end

    test "returns false for nil user" do
      scope = %Scope{user: nil, authenticated?: false}
      refute Scope.admin?(scope)
    end
  end

  # --- system_role?/1 ---

  describe "system_role?/1" do
    test "returns true for Owner" do
      assert Scope.system_role?(build_scope(["Owner"]))
    end

    test "returns true for Admin" do
      assert Scope.system_role?(build_scope(["Admin"]))
    end

    test "returns false for User role" do
      refute Scope.system_role?(build_scope(["User"]))
    end

    test "returns false for custom roles" do
      refute Scope.system_role?(build_scope(["Editor"]))
    end

    test "returns false for nil user" do
      refute Scope.system_role?(%Scope{user: nil, authenticated?: false})
    end
  end

  # --- user_roles/1 ---

  describe "user_roles/1" do
    test "returns cached roles list" do
      scope = build_scope(["Admin", "Editor"])
      assert Scope.user_roles(scope) == ["Admin", "Editor"]
    end

    test "returns empty list for nil user" do
      scope = %Scope{user: nil, authenticated?: false}
      assert Scope.user_roles(scope) == []
    end
  end

  # --- has_module_access?/2 ---

  describe "has_module_access?/2" do
    test "returns true when permission is granted" do
      scope = build_scope(["Editor"], permissions: MapSet.new(["dashboard", "posts"]))
      assert Scope.has_module_access?(scope, "dashboard")
      assert Scope.has_module_access?(scope, "posts")
    end

    test "returns false when permission is not granted" do
      scope = build_scope(["Editor"], permissions: MapSet.new(["dashboard"]))
      refute Scope.has_module_access?(scope, "users")
    end

    test "returns false when permissions is nil" do
      scope = build_scope(["Admin"])
      refute Scope.has_module_access?(scope, "dashboard")
    end

    test "returns false for nil scope" do
      refute Scope.has_module_access?(nil, "dashboard")
    end
  end

  # --- has_any_module_access?/2 ---

  describe "has_any_module_access?/2" do
    test "returns true when at least one key matches" do
      scope = build_scope(["Editor"], permissions: MapSet.new(["posts"]))
      assert Scope.has_any_module_access?(scope, ["users", "posts"])
    end

    test "returns false when no keys match" do
      scope = build_scope(["Editor"], permissions: MapSet.new(["posts"]))
      refute Scope.has_any_module_access?(scope, ["users", "billing"])
    end

    test "returns false for nil scope" do
      refute Scope.has_any_module_access?(nil, ["dashboard"])
    end
  end

  # --- has_all_module_access?/2 ---

  describe "has_all_module_access?/2" do
    test "returns true when all keys match" do
      scope = build_scope(["Admin"], permissions: MapSet.new(["users", "billing"]))
      assert Scope.has_all_module_access?(scope, ["users", "billing"])
    end

    test "returns false when only some keys match" do
      scope = build_scope(["Admin"], permissions: MapSet.new(["users"]))
      refute Scope.has_all_module_access?(scope, ["users", "billing"])
    end

    test "returns false for nil scope" do
      refute Scope.has_all_module_access?(nil, ["dashboard"])
    end
  end

  # --- accessible_modules/1 ---

  describe "accessible_modules/1" do
    test "returns the permissions MapSet" do
      perms = MapSet.new(["dashboard", "users", "posts"])
      scope = build_scope(["Admin"], permissions: perms)
      assert Scope.accessible_modules(scope) == perms
    end

    test "returns empty MapSet when permissions is nil" do
      scope = build_scope(["Admin"])
      assert Scope.accessible_modules(scope) == MapSet.new()
    end
  end

  # --- permission_count/1 ---

  describe "permission_count/1" do
    test "returns count of granted permissions" do
      scope = build_scope(["Admin"], permissions: MapSet.new(["dashboard", "users", "posts"]))
      assert Scope.permission_count(scope) == 3
    end

    test "returns 0 when permissions is nil" do
      scope = build_scope(["Admin"])
      assert Scope.permission_count(scope) == 0
    end

    test "returns 0 for empty permissions" do
      scope = build_scope(["Admin"], permissions: MapSet.new())
      assert Scope.permission_count(scope) == 0
    end
  end

  # --- user_id/1 ---

  describe "user_id/1" do
    test "returns the user's integer id" do
      scope = build_scope(["User"], user: build_user(id: 42))
      assert Scope.user_id(scope) == 42
    end

    test "returns nil for nil user" do
      scope = %Scope{user: nil, authenticated?: false}
      assert Scope.user_id(scope) == nil
    end
  end
end
