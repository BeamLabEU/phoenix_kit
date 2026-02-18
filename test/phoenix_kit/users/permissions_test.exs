defmodule PhoenixKit.Users.PermissionsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role

  setup do
    Permissions.clear_custom_keys()
    :ok
  end

  # --- Test Helpers ---

  defp build_scope(roles) do
    %Scope{
      user: %User{id: 1, uuid: "test-uuid", email: "test@example.com"},
      authenticated?: true,
      cached_roles: roles
    }
  end

  defp build_role(name, opts \\ []) do
    %Role{
      id: Keyword.get(opts, :id, 1),
      uuid: Keyword.get(opts, :uuid, "role-uuid"),
      name: name,
      is_system_role: Keyword.get(opts, :is_system_role, name in ["Owner", "Admin", "User"])
    }
  end

  # --- Key Lists ---

  describe "core_section_keys/0" do
    test "returns expected core keys" do
      keys = Permissions.core_section_keys()
      assert is_list(keys)
      assert "dashboard" in keys
      assert "users" in keys
      assert "media" in keys
      assert "settings" in keys
      assert "modules" in keys
      assert length(keys) == 5
    end
  end

  describe "feature_module_keys/0" do
    test "returns expected feature keys" do
      keys = Permissions.feature_module_keys()
      assert is_list(keys)
      assert "billing" in keys
      assert "shop" in keys
      assert "emails" in keys
      assert "entities" in keys
      assert "ai" in keys
      assert length(keys) == 20
    end

    test "does not include core keys" do
      core = MapSet.new(Permissions.core_section_keys())
      feature = MapSet.new(Permissions.feature_module_keys())
      assert MapSet.disjoint?(core, feature)
    end
  end

  describe "all_module_keys/0" do
    test "is the union of core and feature keys" do
      all = Permissions.all_module_keys()
      expected = Permissions.core_section_keys() ++ Permissions.feature_module_keys()
      assert MapSet.new(all) == MapSet.new(expected)
    end

    test "has 25 built-in keys" do
      assert length(Permissions.all_module_keys()) == 25
    end
  end

  # --- all_module_keys with custom keys ---

  describe "all_module_keys/0 with custom keys" do
    setup do
      on_exit(fn -> Permissions.clear_custom_keys() end)
      :ok
    end

    test "includes custom keys in the list" do
      before = length(Permissions.all_module_keys())
      Permissions.register_custom_key("analytics")
      assert length(Permissions.all_module_keys()) == before + 1
      assert "analytics" in Permissions.all_module_keys()
    end

    test "custom keys are excluded after unregistration" do
      Permissions.register_custom_key("temp")
      assert "temp" in Permissions.all_module_keys()
      Permissions.unregister_custom_key("temp")
      refute "temp" in Permissions.all_module_keys()
    end
  end

  # --- Labels, Icons, Descriptions ---

  describe "module_label/1" do
    test "returns correct labels for built-in keys" do
      assert Permissions.module_label("dashboard") == "Dashboard"
      assert Permissions.module_label("users") == "Users"
      assert Permissions.module_label("shop") == "E-Commerce"
      assert Permissions.module_label("ai") == "AI"
      assert Permissions.module_label("db") == "DB"
    end

    test "capitalizes unknown keys as fallback" do
      assert Permissions.module_label("unknown_thing") == "Unknown_thing"
    end

    test "returns custom key label when registered" do
      Permissions.register_custom_key("test_label_key", label: "My Custom Label")
      assert Permissions.module_label("test_label_key") == "My Custom Label"
      Permissions.unregister_custom_key("test_label_key")
    end
  end

  describe "module_icon/1" do
    test "returns correct icons for built-in keys" do
      assert Permissions.module_icon("dashboard") == "hero-home"
      assert Permissions.module_icon("users") == "hero-users"
      assert Permissions.module_icon("ai") == "hero-sparkles"
    end

    test "returns default icon for unknown keys" do
      assert Permissions.module_icon("unknown") == "hero-squares-2x2"
    end

    test "returns custom icon when registered" do
      Permissions.register_custom_key("icontest", icon: "hero-beaker")
      assert Permissions.module_icon("icontest") == "hero-beaker"
      Permissions.unregister_custom_key("icontest")
    end
  end

  describe "module_description/1" do
    test "returns descriptions for built-in keys" do
      desc = Permissions.module_description("dashboard")
      assert is_binary(desc)
      assert desc != ""
    end

    test "returns empty string for unknown keys" do
      assert Permissions.module_description("nonexistent") == ""
    end

    test "returns custom description when registered" do
      Permissions.register_custom_key("desctest", description: "My custom module")
      assert Permissions.module_description("desctest") == "My custom module"
      Permissions.unregister_custom_key("desctest")
    end

    test "returns empty string for custom key without description" do
      Permissions.register_custom_key("nodesc")
      assert Permissions.module_description("nodesc") == ""
      Permissions.unregister_custom_key("nodesc")
    end
  end

  # --- Custom Key Registration ---

  describe "register_custom_key/2" do
    setup do
      on_exit(fn -> Permissions.clear_custom_keys() end)
      :ok
    end

    test "registers a custom key with defaults" do
      assert :ok = Permissions.register_custom_key("analytics")
      assert "analytics" in Permissions.custom_keys()
    end

    test "registers with custom metadata" do
      assert :ok =
               Permissions.register_custom_key("reports",
                 label: "Reports Dashboard",
                 icon: "hero-chart-bar",
                 description: "Access to reports"
               )

      assert Permissions.module_label("reports") == "Reports Dashboard"
      assert Permissions.module_icon("reports") == "hero-chart-bar"
      assert Permissions.module_description("reports") == "Access to reports"
    end

    test "raises on built-in key collision" do
      assert_raise ArgumentError, ~r/conflicts with built-in key/, fn ->
        Permissions.register_custom_key("dashboard")
      end

      assert_raise ArgumentError, ~r/conflicts with built-in key/, fn ->
        Permissions.register_custom_key("users")
      end
    end

    test "raises on invalid key format" do
      assert_raise ArgumentError, ~r/must match/, fn ->
        Permissions.register_custom_key("Invalid-Key")
      end

      assert_raise ArgumentError, ~r/must match/, fn ->
        Permissions.register_custom_key("123start")
      end

      assert_raise ArgumentError, ~r/must match/, fn ->
        Permissions.register_custom_key("has spaces")
      end
    end

    test "accepts valid key formats" do
      assert :ok = Permissions.register_custom_key("simple")
      assert :ok = Permissions.register_custom_key("with_underscores")
      assert :ok = Permissions.register_custom_key("has123numbers")
    end

    test "allows re-registration (override)" do
      Permissions.register_custom_key("mykey", label: "First")
      assert Permissions.module_label("mykey") == "First"

      Permissions.register_custom_key("mykey", label: "Second")
      assert Permissions.module_label("mykey") == "Second"
    end
  end

  describe "unregister_custom_key/1" do
    setup do
      on_exit(fn -> Permissions.clear_custom_keys() end)
      :ok
    end

    test "removes a registered key" do
      Permissions.register_custom_key("temp_key")
      assert "temp_key" in Permissions.custom_keys()

      Permissions.unregister_custom_key("temp_key")
      refute "temp_key" in Permissions.custom_keys()
    end

    test "is a no-op for unregistered keys" do
      assert :ok = Permissions.unregister_custom_key("nonexistent")
    end
  end

  describe "custom_keys/0" do
    setup do
      on_exit(fn -> Permissions.clear_custom_keys() end)
      :ok
    end

    test "returns empty list when no custom keys registered" do
      Permissions.clear_custom_keys()
      assert Permissions.custom_keys() == []
    end

    test "returns sorted list of registered keys" do
      Permissions.register_custom_key("zebra")
      Permissions.register_custom_key("alpha")
      Permissions.register_custom_key("middle")

      keys = Permissions.custom_keys()
      assert keys == ["alpha", "middle", "zebra"]
    end
  end

  describe "clear_custom_keys/0" do
    test "removes all custom keys" do
      Permissions.register_custom_key("key_a")
      Permissions.register_custom_key("key_b")
      assert length(Permissions.custom_keys()) == 2

      Permissions.clear_custom_keys()
      assert Permissions.custom_keys() == []
    end
  end

  describe "valid_module_key?/1" do
    test "returns true for built-in keys" do
      assert Permissions.valid_module_key?("dashboard")
      assert Permissions.valid_module_key?("billing")
    end

    test "returns true for all 25 built-in keys" do
      for key <- Permissions.core_section_keys() ++ Permissions.feature_module_keys() do
        assert Permissions.valid_module_key?(key), "Expected #{key} to be valid"
      end
    end

    test "returns true for registered custom keys" do
      Permissions.register_custom_key("custom_valid")
      assert Permissions.valid_module_key?("custom_valid")
      Permissions.unregister_custom_key("custom_valid")
    end

    test "returns false for unknown keys" do
      refute Permissions.valid_module_key?("totally_made_up")
    end

    test "returns false for non-string input" do
      refute Permissions.valid_module_key?(nil)
      refute Permissions.valid_module_key?(123)
      refute Permissions.valid_module_key?(:dashboard)
    end

    test "returns false after custom key is unregistered" do
      Permissions.register_custom_key("ephemeral")
      assert Permissions.valid_module_key?("ephemeral")
      Permissions.unregister_custom_key("ephemeral")
      refute Permissions.valid_module_key?("ephemeral")
    end
  end

  # --- Custom Keys Map ---

  describe "custom_keys_map/0" do
    setup do
      on_exit(fn -> Permissions.clear_custom_keys() end)
      :ok
    end

    test "returns empty map when no custom keys" do
      assert Permissions.custom_keys_map() == %{}
    end

    test "returns map with metadata for registered keys" do
      Permissions.register_custom_key("reports", label: "Reports", icon: "hero-chart-bar")
      map = Permissions.custom_keys_map()
      assert is_map(map)
      assert Map.has_key?(map, "reports")
      assert map["reports"][:label] == "Reports"
      assert map["reports"][:icon] == "hero-chart-bar"
    end
  end

  # --- Custom View Permission Cache ---

  describe "cache_custom_view_permission/2 and custom_view_permissions/0" do
    setup do
      on_exit(fn -> Permissions.clear_custom_keys() end)
      :ok
    end

    test "caches a view module to permission key mapping" do
      Permissions.cache_custom_view_permission(MyApp.SomeLive, "dashboard")
      perms = Permissions.custom_view_permissions()
      assert perms[MyApp.SomeLive] == "dashboard"
    end

    test "returns empty map when nothing cached" do
      assert Permissions.custom_view_permissions() == %{}
    end

    test "overwrites previous mapping for same module" do
      Permissions.cache_custom_view_permission(MyApp.TestLive, "users")
      Permissions.cache_custom_view_permission(MyApp.TestLive, "billing")
      perms = Permissions.custom_view_permissions()
      assert perms[MyApp.TestLive] == "billing"
    end

    test "supports multiple different modules" do
      Permissions.cache_custom_view_permission(MyApp.Live1, "users")
      Permissions.cache_custom_view_permission(MyApp.Live2, "billing")
      perms = Permissions.custom_view_permissions()
      assert perms[MyApp.Live1] == "users"
      assert perms[MyApp.Live2] == "billing"
    end
  end

  # --- Feature Enabled ---

  describe "feature_enabled?/1" do
    test "core section keys are always enabled" do
      for key <- Permissions.core_section_keys() do
        assert Permissions.feature_enabled?(key), "Expected core key #{key} to be enabled"
      end
    end

    test "unknown keys return false" do
      refute Permissions.feature_enabled?("totally_nonexistent")
    end

    test "custom keys are always enabled" do
      Permissions.register_custom_key("custom_enabled")
      assert Permissions.feature_enabled?("custom_enabled")
      Permissions.unregister_custom_key("custom_enabled")
    end

    test "unregistered custom keys are not enabled" do
      refute Permissions.feature_enabled?("was_never_registered")
    end
  end

  # --- Access Control: can_edit_role_permissions? ---

  describe "can_edit_role_permissions?/2" do
    test "returns error for nil scope" do
      role = build_role("User")
      assert {:error, :not_authenticated} = Permissions.can_edit_role_permissions?(nil, role)
    end

    test "blocks editing Owner role" do
      scope = build_scope(["Owner"])
      role = build_role("Owner")

      assert {:error, :owner_immutable} = Permissions.can_edit_role_permissions?(scope, role)
    end

    test "blocks editing own role for non-system roles" do
      scope = build_scope(["Editor"])
      role = build_role("Editor", is_system_role: false)

      assert {:error, :self_role} = Permissions.can_edit_role_permissions?(scope, role)
    end

    test "blocks non-Owner from editing Admin role" do
      # User with "Editor" role trying to edit Admin
      scope = build_scope(["Editor"])
      role = build_role("Admin")

      assert {:error, :admin_owner_only} = Permissions.can_edit_role_permissions?(scope, role)
    end

    test "allows Owner to edit Admin role" do
      scope = build_scope(["Owner"])
      role = build_role("Admin")

      assert :ok = Permissions.can_edit_role_permissions?(scope, role)
    end

    test "allows Owner to edit custom roles" do
      scope = build_scope(["Owner"])
      role = build_role("Editor", is_system_role: false)

      assert :ok = Permissions.can_edit_role_permissions?(scope, role)
    end

    test "allows Admin to edit custom roles" do
      scope = build_scope(["Admin"])
      role = build_role("Editor", is_system_role: false)

      assert :ok = Permissions.can_edit_role_permissions?(scope, role)
    end

    test "allows Admin to edit User role" do
      scope = build_scope(["Admin"])
      role = build_role("User")

      assert :ok = Permissions.can_edit_role_permissions?(scope, role)
    end

    test "system role user can edit roles they also hold (except Owner/Admin restrictions)" do
      # Admin who also holds Editor can still edit Editor because they have system role
      scope = build_scope(["Admin", "Editor"])
      editor_role = build_role("Editor", is_system_role: false)

      assert :ok = Permissions.can_edit_role_permissions?(scope, editor_role)
    end

    test "non-system role user blocked from editing own role" do
      # User with only custom roles can't edit their own role
      scope = build_scope(["Editor", "Support"])
      editor_role = build_role("Editor", is_system_role: false)

      assert {:error, :self_role} = Permissions.can_edit_role_permissions?(scope, editor_role)
    end

    test "Owner check takes priority over own-role check" do
      # Even if an Owner somehow had "Owner" in their roles,
      # the error should be about Owner being immutable, not about own role
      scope = build_scope(["Owner"])
      role = build_role("Owner")

      assert {:error, :owner_immutable} = Permissions.can_edit_role_permissions?(scope, role)
    end
  end
end
