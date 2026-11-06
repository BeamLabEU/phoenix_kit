defmodule PhoenixKit.Integration.Users.ModuleOptInSubPermissionTest do
  # async: false — registers a fake module in the global ModuleRegistry and
  # mutates the Admin system role's permissions.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  defmodule FakeChat do
    def module_key, do: "fake_chat"
    def module_name, do: "Fake Chat"
    def enabled?, do: true

    def permission_metadata do
      %{
        key: "fake_chat",
        label: "Fake Chat",
        icon: "hero-chat-bubble-left",
        description: "Fake module with an opt-in sub-permission",
        sub_permissions: [
          %{key: "plain", label: "Plain", description: "Granted to Admin like any other"},
          %{key: "outside", label: "Outside", description: "Only when granted", opt_in: true},
          %{key: "explicit_off", label: "Off", description: "", opt_in: false}
        ]
      }
    end
  end

  @base "fake_chat"
  @plain "fake_chat.plain"
  @opt_in "fake_chat.outside"
  @explicit_off "fake_chat.explicit_off"

  setup do
    ModuleRegistry.register(FakeChat)
    on_exit(fn -> ModuleRegistry.unregister(FakeChat) end)
    :ok
  end

  defp admin_uuid, do: Enum.find(Roles.list_roles(), &(&1.name == "Admin")).uuid

  describe "registry" do
    test "keeps the opt_in flag of a declared sub-permission" do
      subs = ModuleRegistry.sub_permission_map()[@base] |> Map.new(&{&1.key, &1})

      assert subs[@opt_in].opt_in == true
      assert subs[@plain].opt_in == false
      assert subs[@explicit_off].opt_in == false
    end
  end

  describe "opt_in_admin_keys/0 and admin_baseline_exclusions/0" do
    test "include a module's opt-in sub-permission, and still the core ones" do
      assert @opt_in in Permissions.opt_in_admin_keys()
      assert @opt_in in Permissions.admin_baseline_exclusions()
      assert "api" in Permissions.opt_in_admin_keys()
      assert "integrations" in Permissions.admin_baseline_exclusions()
    end

    test "do not include a sub-permission that is not opt-in" do
      refute @plain in Permissions.opt_in_admin_keys()
      refute @plain in Permissions.admin_baseline_exclusions()
      refute @explicit_off in Permissions.opt_in_admin_keys()
      refute @base in Permissions.opt_in_admin_keys()
    end

    test "forget the key when the module is gone" do
      ModuleRegistry.unregister(FakeChat)

      refute @opt_in in Permissions.opt_in_admin_keys()
      refute @opt_in in Permissions.admin_baseline_exclusions()
    end
  end

  describe "boot-time grants to Admin" do
    test "the sweep grants the module and its plain sub-permission, not the opt-in one" do
      assert :ok = Permissions.auto_grant_new_keys_to_admin()

      perms = Permissions.get_permissions_for_role(admin_uuid())
      assert @base in perms
      assert @plain in perms
      assert @explicit_off in perms
      refute @opt_in in perms
      refute Settings.get_setting("auto_granted_perm:#{@opt_in}") == "true"
    end

    test "the single-key chokepoint is a no-op for the opt-in key" do
      assert :ok = Permissions.auto_grant_to_admin_roles(@opt_in)

      refute @opt_in in Permissions.get_permissions_for_role(admin_uuid())
    end

    test "an Owner can still grant the opt-in key to Admin by hand" do
      assert :ok = Permissions.auto_grant_new_keys_to_admin()
      assert {:ok, _} = Permissions.grant_permission(admin_uuid(), @opt_in)

      assert @opt_in in Permissions.get_permissions_for_role(admin_uuid())
    end
  end

  describe "holds_all_enabled_permissions?/1" do
    test "a default Admin (everything swept to it, no opt-in key) still passes" do
      assert :ok = Permissions.auto_grant_new_keys_to_admin()
      perms = MapSet.new(Permissions.get_permissions_for_role(admin_uuid()))

      assert MapSet.member?(Permissions.enabled_module_keys(), @opt_in)
      refute MapSet.member?(perms, @opt_in)
      assert Scope.holds_all_enabled_permissions?(%Scope{cached_permissions: perms})
    end

    test "a role missing the module's plain sub-permission does not pass" do
      assert :ok = Permissions.auto_grant_new_keys_to_admin()

      perms =
        admin_uuid()
        |> Permissions.get_permissions_for_role()
        |> MapSet.new()
        |> MapSet.delete(@plain)

      refute Scope.holds_all_enabled_permissions?(%Scope{cached_permissions: perms})
    end
  end

  describe "Owner" do
    test "holds the opt-in key through the wildcard" do
      owner = %Scope{cached_permissions: MapSet.new(["*"])}

      assert Scope.can?(owner, @opt_in)
      assert Scope.holds_all_enabled_permissions?(owner)
    end

    test "a default Admin does not hold it" do
      assert :ok = Permissions.auto_grant_new_keys_to_admin()

      admin = %Scope{
        cached_permissions: MapSet.new(Permissions.get_permissions_for_role(admin_uuid()))
      }

      refute Scope.can?(admin, @opt_in)
      assert Scope.can?(admin, @plain)
    end
  end
end
