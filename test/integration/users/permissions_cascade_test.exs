defmodule PhoenixKit.Integration.Users.PermissionsCascadeTest do
  # async: false — registers a fake module in the global ModuleRegistry and
  # mutates the Admin system role's permissions (sandboxed, but the registry
  # entry itself is process-global).
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles

  defmodule FakeCalendar do
    def module_key, do: "fake_calendar"
    def module_name, do: "Fake Calendar"
    def enabled?, do: true

    def permission_metadata do
      %{
        key: "fake_calendar",
        label: "Fake Calendar",
        icon: "hero-calendar-days",
        description: "Fake module for cascade tests",
        sub_permissions: [
          %{key: "view_others", label: "View others", description: ""},
          %{key: "edit_others", label: "Edit others", description: ""}
        ]
      }
    end
  end

  @base "fake_calendar"
  @sub_view "fake_calendar.view_others"
  @sub_edit "fake_calendar.edit_others"

  setup do
    ModuleRegistry.register(FakeCalendar)
    on_exit(fn -> ModuleRegistry.unregister(FakeCalendar) end)
    :ok
  end

  defp unique_email, do: "cascade_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    user
  end

  defp get_role_uuid(role_name) do
    role = Enum.find(Roles.list_roles(), &(&1.name == role_name))
    role.uuid
  end

  describe "grant_permission/3 with sub keys" do
    test "granting a sub key auto-grants its base key" do
      role_uuid = get_role_uuid("User")

      assert {:ok, _} = Permissions.grant_permission(role_uuid, @sub_view)

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert @sub_view in perms
      assert @base in perms
    end

    test "granting a sub when the base is already held stays idempotent" do
      role_uuid = get_role_uuid("User")

      assert {:ok, _} = Permissions.grant_permission(role_uuid, @base)
      assert {:ok, _} = Permissions.grant_permission(role_uuid, @sub_view)
      assert {:ok, _} = Permissions.grant_permission(role_uuid, @sub_view)

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert Enum.sort(perms) == Enum.sort([@base, @sub_view])
    end
  end

  describe "revoke_permission/2 with sub keys" do
    test "revoking the base key cascades its sub keys off" do
      role_uuid = get_role_uuid("User")
      :ok = Permissions.set_permissions(role_uuid, [@base, @sub_view, @sub_edit])

      assert :ok = Permissions.revoke_permission(role_uuid, @base)
      assert Permissions.get_permissions_for_role(role_uuid) == []
    end

    test "revoking a sub key leaves the base key in place" do
      role_uuid = get_role_uuid("User")
      :ok = Permissions.set_permissions(role_uuid, [@base, @sub_view, @sub_edit])

      assert :ok = Permissions.revoke_permission(role_uuid, @sub_view)

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert @base in perms
      assert @sub_edit in perms
      refute @sub_view in perms
    end
  end

  describe "set_permissions/3 normalization" do
    test "a requested sub key pulls in its base key" do
      role_uuid = get_role_uuid("User")

      assert :ok = Permissions.set_permissions(role_uuid, [@sub_edit])

      perms = Permissions.get_permissions_for_role(role_uuid)
      assert @base in perms
      assert @sub_edit in perms
    end

    test "dropping base and subs from the desired set removes all of them" do
      role_uuid = get_role_uuid("User")
      :ok = Permissions.set_permissions(role_uuid, [@base, @sub_view])

      assert :ok = Permissions.set_permissions(role_uuid, ["dashboard"])
      assert Permissions.get_permissions_for_role(role_uuid) == ["dashboard"]
    end
  end

  describe "any_permissions_exist?/0" do
    test "true on a seeded install, false once all rows are gone" do
      # V53 seeded the Admin role, so the test DB starts seeded
      assert Permissions.any_permissions_exist?()

      Repo.delete_all(RolePermission)
      refute Permissions.any_permissions_exist?()
    end
  end

  describe "auto_grant_new_keys_to_admin/0" do
    test "grants unseen keys to Admin; an Owner revocation then sticks" do
      admin_uuid = get_role_uuid("Admin")

      # V53 never saw this module's keys
      refute @base in Permissions.get_permissions_for_role(admin_uuid)

      assert :ok = Permissions.auto_grant_new_keys_to_admin()

      perms = Permissions.get_permissions_for_role(admin_uuid)
      assert @base in perms
      assert @sub_view in perms
      assert @sub_edit in perms
      assert Settings.get_setting("auto_granted_perm:#{@base}") == "true"

      # Owner revokes one sub key — the flag must keep the next boot's
      # auto-grant from silently restoring it
      assert :ok = Permissions.revoke_permission(admin_uuid, @sub_edit)
      assert :ok = Permissions.auto_grant_new_keys_to_admin()

      perms = Permissions.get_permissions_for_role(admin_uuid)
      assert @sub_view in perms
      refute @sub_edit in perms
    end

    test "is idempotent — repeated runs create no duplicate rows" do
      admin_uuid = get_role_uuid("Admin")

      assert :ok = Permissions.auto_grant_new_keys_to_admin()
      count_first = Permissions.count_permissions_for_role(admin_uuid)

      assert :ok = Permissions.auto_grant_new_keys_to_admin()
      assert Permissions.count_permissions_for_role(admin_uuid) == count_first
    end
  end

  describe "Scope.for_user/1 Admin fallback scoping" do
    setup do
      _owner = create_user()
      admin_user = create_user()
      {:ok, _} = Roles.assign_role(admin_user, "Admin")
      %{admin_user: admin_user}
    end

    test "admin uses its rows on a seeded install", %{admin_user: admin_user} do
      scope = Scope.for_user(admin_user)

      # V53 seeded rows — present, but NOT the registry-wide key list
      assert Scope.has_module_access?(scope, "dashboard")
      refute MapSet.member?(Scope.accessible_modules(scope), @base)
    end

    test "revoking everything from Admin sticks on a seeded install",
         %{admin_user: admin_user} do
      admin_uuid = get_role_uuid("Admin")

      # keep the table non-empty via a role the admin user does NOT hold
      # (permissions join across ALL of a user's roles — the default "User"
      # role would leak its grants into this scope)
      {:ok, keeper} = Roles.create_role(%{name: "Keeper #{System.unique_integer([:positive])}"})
      {:ok, _} = Permissions.grant_permission(keeper.uuid, "dashboard")
      :ok = Permissions.revoke_all_permissions(admin_uuid)

      scope = Scope.for_user(admin_user)

      # the old per-user fallback would ironically restore FULL access here
      assert Scope.accessible_modules(scope) == MapSet.new()
      refute Scope.has_module_access?(scope, "dashboard")
      # still admin? (holds the role) — shell access, but every gated view denies
      assert Scope.admin?(scope)
    end

    test "genuinely unseeded install falls back to full access",
         %{admin_user: admin_user} do
      Repo.delete_all(RolePermission)

      scope = Scope.for_user(admin_user)

      assert Scope.has_module_access?(scope, "dashboard")
      assert Scope.has_module_access?(scope, @base)
      assert Scope.has_module_access?(scope, @sub_edit)
    end

    test "Owner always holds every key regardless of rows" do
      # first registered user became Owner in setup
      owner = Auth.get_user_by_email(hd(owner_emails()))
      Repo.delete_all(RolePermission)

      scope = Scope.for_user(owner)
      assert Scope.has_module_access?(scope, @base)
      assert Scope.has_module_access?(scope, @sub_view)
    end
  end

  defp owner_emails do
    Repo.all(
      from(u in PhoenixKit.Users.Auth.User,
        join: ra in PhoenixKit.Users.RoleAssignment,
        on: ra.user_uuid == u.uuid,
        join: r in PhoenixKit.Users.Role,
        on: r.uuid == ra.role_uuid,
        where: r.name == "Owner",
        select: u.email
      )
    )
  end
end
