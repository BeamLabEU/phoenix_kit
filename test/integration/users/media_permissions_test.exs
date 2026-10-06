defmodule PhoenixKit.Integration.Users.MediaPermissionsTest do
  @moduledoc """
  The sub-permissions of the core `media` section (`media.view_all`,
  `media.manage`): registered like a module's, cascading from `media`, granted
  once to every role that held `media` before they existed, and the storage
  administration screens behind `media.manage` so that `media` alone (an end user
  given Media) does not open them.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @flag "media_sub_permissions_backfilled"
  @subs ~w(media.view_all media.manage)

  defp role!(keys) do
    {:ok, role} = Roles.create_role(%{name: "Media perms #{System.unique_integer([:positive])}"})
    for key <- keys, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    role
  end

  defp held(role), do: MapSet.new(Permissions.get_permissions_for_role(role.uuid))

  defp user_with(role) do
    {:ok, user} =
      Auth.register_user(%{
        email: "media-perms-#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  describe "registration" do
    test "the two sub-permissions belong to media" do
      assert Permissions.parent_key("media.view_all") == "media"
      assert Permissions.parent_key("media.manage") == "media"
      assert Enum.map(Permissions.sub_permissions_for("media"), & &1.key) == @subs
      for key <- @subs, do: assert(key in Permissions.all_module_keys())
      for key <- @subs, do: assert(Permissions.valid_module_key?(key))
      for key <- @subs, do: assert(MapSet.member?(Permissions.enabled_module_keys(), key))
      for key <- @subs, do: assert(Permissions.feature_enabled?(key))
    end

    test "a sub-permission needs media, and granting one grants it" do
      role = role!(["media.view_all"])

      assert "media" in held(role)
      assert "media.view_all" in held(role)
      refute "media.manage" in held(role)
    end

    test "revoking media takes the subs with it" do
      role = role!(["media" | @subs])
      :ok = Permissions.revoke_permission(role.uuid, "media")

      assert held(role) == MapSet.new()
    end
  end

  describe "backfill_media_sub_permissions/0" do
    setup do
      {:ok, _} = Settings.update_setting(@flag, "false")
      :ok
    end

    test "grants both to every role that holds media, and only those" do
      holder = role!(["media"])
      other = role!(["settings"])

      assert :ok = Permissions.backfill_media_sub_permissions()

      assert MapSet.subset?(MapSet.new(["media" | @subs]), held(holder))
      refute Enum.any?(@subs, &(&1 in held(other)))
    end

    test "runs once: a revoked sub is not given back, and a later role gets nothing" do
      holder = role!(["media"])
      assert :ok = Permissions.backfill_media_sub_permissions()
      assert Settings.get_setting(@flag) == "true"

      :ok = Permissions.revoke_permission(holder.uuid, "media.view_all")
      later = role!(["media"])

      assert :ok = Permissions.backfill_media_sub_permissions()

      refute "media.view_all" in held(holder)
      assert "media.manage" in held(holder)
      refute Enum.any?(@subs, &(&1 in held(later)))
    end
  end

  describe "the storage administration screens" do
    setup %{conn: conn} do
      {:ok, _} = Settings.update_setting(@flag, "true")
      %{conn: conn}
    end

    test "media alone does not open them; media.manage does", %{conn: conn} do
      plain = role!(["media"])
      manager = role!(["media", "media.manage"])

      for path <- [
            "/admin/settings/media",
            "/admin/settings/media/renditions/new/image",
            "/admin/settings/media/libraries/#{Libraries.media_uuid()}",
            "/admin/settings/media/buckets/new"
          ] do
        conn_plain = log_in_user(conn, user_with(plain))

        assert {:error, {:redirect, _}} = live(conn_plain, Routes.path(path)), path

        assert {:ok, _view, _html} =
                 live(log_in_user(conn, user_with(manager)), Routes.path(path)),
               path
      end
    end

    test "media alone still opens Media itself", %{conn: conn} do
      plain = role!(["media"])

      assert {:ok, _view, _html} =
               live(log_in_user(conn, user_with(plain)), Routes.path("/admin/media"))
    end

    test "the scope says what a holder may do" do
      scope = Scope.for_user(user_with(role!(["media", "media.view_all"])))

      assert Scope.can?(scope, "media.view_all")
      refute Scope.can?(scope, "media.manage")
    end
  end
end
