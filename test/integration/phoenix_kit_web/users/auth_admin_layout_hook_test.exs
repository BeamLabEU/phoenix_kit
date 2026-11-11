defmodule PhoenixKitWeb.Users.AuthAdminLayoutHookTest do
  @moduledoc """
  `:phoenix_kit_admin_layout` stacked with the hooks around it.

  The hook is fail-open (layout only), so a host pairs it with
  `{:phoenix_kit_require, {:module, key}}`. Pinned here: the pair works in the
  documented order, the require still halts what the layout hook let through,
  stacking on a mounted scope does not raise, and — as the control — the
  `:phoenix_kit_ensure_admin` hook turns the same non-Owner admin away from the
  same view, which is the reason this hook exists.
  """
  use PhoenixKit.DataCase, async: true

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias PhoenixKit.Users.Auth, as: AuthCtx
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  # In the `PhoenixKitWeb.*` namespace and absent from the permission map: the
  # shape `:phoenix_kit_ensure_admin` rejects for a non-Owner admin.
  @view PhoenixKitWeb.Test.AdminLayoutProbeLive

  defp socket(path \\ Routes.path("/admin/__test/admin-layout-probe")) do
    %Socket{
      view: @view,
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{
        connect_params: %{},
        connect_info: %{uri: URI.parse("http://localhost" <> path)},
        lifecycle: %Lifecycle{},
        live_temp: %{}
      },
      router: PhoenixKitWeb.Router
    }
  end

  defp user(role) do
    {:ok, user} =
      AuthCtx.register_user(%{
        email: "layout_hook_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = AuthCtx.admin_confirm_user(user)
    if role, do: {:ok, _} = Roles.assign_role(user, role)
    user
  end

  defp session_for(user), do: %{"user_token" => AuthCtx.generate_user_session_token(user)}

  defp mount(hooks, session, socket) do
    Enum.reduce_while(hooks, {:cont, socket}, fn hook, {:cont, socket} ->
      case Auth.on_mount(hook, %{}, session, socket) do
        {:cont, socket} -> {:cont, {:cont, socket}}
        {:halt, socket} -> {:halt, {:halt, socket}}
      end
    end)
  end

  defp current_page_hooks(socket) do
    socket.private.lifecycle.handle_params
    |> Enum.count(&(&1.id == :current_page))
  end

  defp layout(socket), do: socket.private[:live_layout]

  describe "stacking" do
    test "layout, then a module requirement: an admin holding the key gets both" do
      admin = user("Admin")

      assert {:cont, socket} =
               mount(
                 [:phoenix_kit_admin_layout, {:phoenix_kit_require, {:module, "dashboard"}}],
                 session_for(admin),
                 socket()
               )

      assert layout(socket) == {PhoenixKitWeb.Layouts, :admin}
      assert current_page_hooks(socket) == 1
    end

    test "the requirement still halts a signed-in non-admin the layout hook let through" do
      plain = user(nil)
      session = session_for(plain)

      assert {:halt, socket} =
               mount(
                 [:phoenix_kit_admin_layout, {:phoenix_kit_require, {:module, "dashboard"}}],
                 session,
                 socket()
               )

      assert {:redirect, _} = socket.redirected
      refute layout(socket) == {PhoenixKitWeb.Layouts, :admin}
    end

    test "layout alone lets a non-admin through, bare" do
      assert {:cont, socket} =
               mount([:phoenix_kit_admin_layout], session_for(user(nil)), socket())

      assert socket.redirected == nil
      refute layout(socket) == {PhoenixKitWeb.Layouts, :admin}
    end

    test "on a live_session that already mounted the scope it does not raise" do
      admin = user("Admin")

      assert {:cont, socket} =
               mount(
                 [:phoenix_kit_mount_current_scope, :phoenix_kit_admin_layout],
                 session_for(admin),
                 socket()
               )

      assert layout(socket) == {PhoenixKitWeb.Layouts, :admin}
      assert current_page_hooks(socket) == 1
    end

    test "an admin whose email is unconfirmed does not get the layout, and is not halted" do
      {:ok, unconfirmed} =
        AuthCtx.register_user(%{
          email: "layout_hook_unconfirmed_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = Roles.assign_role(unconfirmed, "Admin")

      assert {:cont, socket} =
               mount([:phoenix_kit_admin_layout], session_for(unconfirmed), socket())

      assert socket.redirected == nil
      refute layout(socket) == {PhoenixKitWeb.Layouts, :admin}
    end
  end

  describe "against :phoenix_kit_ensure_admin, on the same unmapped view" do
    test "ensure_admin turns the non-Owner admin away; the layout hook does not" do
      admin = user("Admin")

      # An Admin holding every operator key is Owner-equivalent and passes an
      # unmapped view (`Scope.holds_all_enabled_permissions?/1`). Whether the
      # Admin role has those rows depends on the database the suite runs
      # against, so take one away here: this Admin is short of a key either way.
      admin_role = Roles.get_role_by_name("Admin")
      Permissions.revoke_permission(admin_role.uuid, "dashboard")

      session = session_for(admin)

      assert {:halt, rejected} = mount([:phoenix_kit_ensure_admin], session, socket())
      assert {:redirect, _} = rejected.redirected

      assert {:cont, admitted} = mount([:phoenix_kit_admin_layout], session, socket())
      assert admitted.redirected == nil
      assert layout(admitted) == {PhoenixKitWeb.Layouts, :admin}
    end
  end
end
