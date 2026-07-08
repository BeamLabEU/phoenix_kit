defmodule PhoenixKit.Users.PermissionsSubKeysTest do
  # async: false — registers fake modules in the global ModuleRegistry.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission

  defmodule FakeCalendar do
    def module_key, do: "fake_calendar"
    def module_name, do: "Fake Calendar"
    def enabled?, do: true

    def permission_metadata do
      %{
        key: "fake_calendar",
        label: "Fake Calendar",
        icon: "hero-calendar-days",
        description: "Fake module for sub-permission tests",
        sub_permissions: [
          %{key: "view_others", label: "View others' calendars", description: "Read-only"},
          %{key: "edit_others", label: "Edit others' calendars", description: "Write"}
        ]
      }
    end
  end

  defmodule FakeDisabled do
    def module_key, do: "fake_disabled"
    def module_name, do: "Fake Disabled"
    def enabled?, do: false

    def permission_metadata do
      %{
        key: "fake_disabled",
        label: "Fake Disabled",
        icon: "hero-no-symbol",
        description: "Disabled module with a sub-permission",
        sub_permissions: [
          %{key: "manage", label: "Manage", description: ""}
        ]
      }
    end
  end

  defmodule FakeMalformedSubs do
    def module_key, do: "fake_malformed"
    def module_name, do: "Fake Malformed"
    def enabled?, do: true

    def permission_metadata do
      %{
        key: "fake_malformed",
        label: "Fake Malformed",
        icon: "hero-bug-ant",
        description: "Declares invalid sub-permissions",
        sub_permissions: [
          # dot in the sub part — must be dropped (would compose a 2-dot key)
          %{key: "bad.key", label: "Bad"},
          # uppercase — fails the key regex
          %{key: "BadCase", label: "Bad case"},
          # missing :label — malformed shape
          %{key: "no_label"},
          # valid — must survive
          %{key: "ok_sub", label: "OK sub", description: "Valid"}
        ]
      }
    end
  end

  setup do
    ModuleRegistry.register(FakeCalendar)
    ModuleRegistry.register(FakeDisabled)

    on_exit(fn ->
      ModuleRegistry.unregister(FakeCalendar)
      ModuleRegistry.unregister(FakeDisabled)
      ModuleRegistry.unregister(FakeMalformedSubs)
    end)

    :ok
  end

  defp scope_with(perms) do
    %Scope{
      user: %User{uuid: "0193a5e4-0000-7000-8000-000000000001", email: "sub@example.com"},
      authenticated?: true,
      cached_roles: ["SomeCustomRole"],
      cached_permissions: MapSet.new(perms)
    }
  end

  describe "registry sub_permission_map/0" do
    test "collects composed keys with metadata" do
      map = ModuleRegistry.sub_permission_map()

      assert [edit, view] = Enum.sort_by(map["fake_calendar"], & &1.key)
      assert edit.key == "fake_calendar.edit_others"
      assert view.key == "fake_calendar.view_others"
      assert view.label == "View others' calendars"
      assert view.description == "Read-only"
    end

    test "drops malformed sub-permissions with a warning, keeps valid ones" do
      log =
        capture_log(fn ->
          ModuleRegistry.register(FakeMalformedSubs)
          map = ModuleRegistry.sub_permission_map()

          assert [%{key: "fake_malformed.ok_sub"}] = map["fake_malformed"]
        end)

      assert log =~ "bad.key"
      assert log =~ "BadCase"
      assert log =~ "no_label"
    end

    test "modules without sub_permissions don't appear in the map" do
      refute Map.has_key?(ModuleRegistry.sub_permission_map(), "fake_no_subs")
    end
  end

  describe "sub-permission key lists" do
    test "sub_permission_keys/0 returns composed keys" do
      keys = Permissions.sub_permission_keys()
      assert "fake_calendar.view_others" in keys
      assert "fake_calendar.edit_others" in keys
    end

    test "all_module_keys/0 includes sub keys alongside base keys" do
      keys = Permissions.all_module_keys()
      assert "fake_calendar" in keys
      assert "fake_calendar.view_others" in keys
    end

    test "feature_module_keys/0 does NOT include sub keys" do
      keys = Permissions.feature_module_keys()
      assert "fake_calendar" in keys
      refute Enum.any?(keys, &String.contains?(&1, "."))
    end

    test "sub_permissions_for/1 returns [] for keys without subs" do
      assert Permissions.sub_permissions_for("dashboard") == []
      assert Permissions.sub_permissions_for("nonexistent") == []
    end
  end

  describe "parent_key/1" do
    test "resolves a composed key to its base" do
      assert Permissions.parent_key("fake_calendar.view_others") == "fake_calendar"
    end

    test "returns nil for base keys, unknown dotted keys, and non-binaries" do
      assert Permissions.parent_key("fake_calendar") == nil
      assert Permissions.parent_key("fake_calendar.nonexistent") == nil
      assert Permissions.parent_key("unknown.sub") == nil
      assert Permissions.parent_key(nil) == nil
    end
  end

  describe "expand_with_parents/1" do
    test "adds the base key implied by a sub key" do
      assert Permissions.expand_with_parents(["fake_calendar.view_others"]) ==
               MapSet.new(["fake_calendar.view_others", "fake_calendar"])
    end

    test "leaves base keys and unknown keys untouched" do
      keys = ["dashboard", "unknown.sub"]
      assert Permissions.expand_with_parents(keys) == MapSet.new(keys)
    end
  end

  describe "valid_module_key?/1 with sub keys" do
    test "accepts registered sub keys, rejects unknown dotted keys" do
      assert Permissions.valid_module_key?("fake_calendar.view_others")
      refute Permissions.valid_module_key?("fake_calendar.nonexistent")
      refute Permissions.valid_module_key?("nonexistent.view_others")
    end
  end

  describe "sub-key metadata resolution" do
    test "module_label/1 resolves the sub's own label" do
      assert Permissions.module_label("fake_calendar.view_others") ==
               "View others' calendars"
    end

    test "module_description/1 resolves the sub's own description" do
      assert Permissions.module_description("fake_calendar.edit_others") == "Write"
    end

    test "module_icon/1 inherits the parent module's icon" do
      assert Permissions.module_icon("fake_calendar.view_others") == "hero-calendar-days"
    end
  end

  describe "feature_enabled?/1 with sub keys" do
    test "sub key follows the parent module's enabled state" do
      assert Permissions.feature_enabled?("fake_calendar.view_others")
      refute Permissions.feature_enabled?("fake_disabled.manage")
    end

    test "unknown dotted keys are not enabled" do
      refute Permissions.feature_enabled?("unknown.sub")
    end
  end

  describe "enabled_module_keys/0 with sub keys" do
    test "includes subs of enabled modules, excludes subs of disabled ones" do
      enabled = Permissions.enabled_module_keys()
      assert MapSet.member?(enabled, "fake_calendar.view_others")
      refute MapSet.member?(enabled, "fake_disabled.manage")
      # the disabled base key is excluded as before
      refute MapSet.member?(enabled, "fake_disabled")
    end
  end

  describe "RolePermission.changeset/2 with sub keys" do
    test "accepts a registered sub key" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: UUIDv7.generate(),
          module_key: "fake_calendar.view_others"
        })

      assert changeset.valid?
    end

    test "rejects an unregistered dotted key" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: UUIDv7.generate(),
          module_key: "fake_calendar.nonexistent"
        })

      refute changeset.valid?
    end
  end

  describe "Scope.can?/2" do
    test "true when the key is held and its parent module is enabled" do
      scope = scope_with(["fake_calendar", "fake_calendar.view_others"])
      assert Scope.can?(scope, "fake_calendar.view_others")
      assert Scope.can?(scope, "fake_calendar")
    end

    test "false when the key is not held" do
      scope = scope_with(["fake_calendar"])
      refute Scope.can?(scope, "fake_calendar.view_others")
    end

    test "false when the parent module is disabled, even if the key is cached" do
      # a scope snapshotted before the module was disabled must not keep
      # authorizing its actions
      scope = scope_with(["fake_disabled", "fake_disabled.manage"])
      refute Scope.can?(scope, "fake_disabled.manage")
      refute Scope.can?(scope, "fake_disabled")
    end

    test "false for anonymous scope" do
      refute Scope.can?(Scope.for_user(nil), "fake_calendar.view_others")
    end
  end
end
