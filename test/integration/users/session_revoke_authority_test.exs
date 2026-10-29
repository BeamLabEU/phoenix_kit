defmodule PhoenixKit.Integration.Users.SessionRevokeAuthorityTest do
  @moduledoc """
  Ending someone else's sessions takes the rank rule of changing their status
  (`Sessions.can_revoke_sessions_of?/2`): nobody but an Owner ends an Owner's
  sessions, an Admin's need an Owner, and a role holding only `users` ends
  nobody's but its own. Checked in the context and on the Sessions page.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.{Auth, Permissions, Sessions}
  alias PhoenixKit.Utils.Routes

  defp user!(role_names) do
    {:ok, user} =
      Auth.register_user(%{
        email: "srv-#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    for name <- role_names, do: {:ok, _} = Roles.assign_role(user, name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp users_role! do
    {:ok, role} = Roles.create_role(%{name: "Srv #{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "users")
    role.name
  end

  defp owner, do: Auth.get_user_by_email("seed-owner@phoenixkit.test")

  defp token_uuid(user) do
    _ = Auth.generate_user_session_token(user)
    [session | _] = Sessions.list_user_sessions(user)
    session.token_uuid
  end

  describe "the context" do
    test "nobody but an Owner ends an Owner's sessions" do
      admin = user!(["Admin"])
      target = owner()
      token = token_uuid(target)

      refute Sessions.can_revoke_sessions_of?(target, admin)
      assert {:error, :not_permitted} = Sessions.revoke_user_sessions(target, actor: admin)
      assert {:error, :not_permitted} = Sessions.revoke_session(token, actor: admin)
      assert Enum.any?(Sessions.list_user_sessions(target), &(&1.token_uuid == token))
    end

    test "an Admin's sessions need an Owner" do
      admin = user!(["Admin"])
      other_admin = user!(["Admin"])
      _ = token_uuid(other_admin)

      assert {:error, :not_permitted} = Sessions.revoke_user_sessions(other_admin, actor: admin)
      assert Sessions.revoke_user_sessions(other_admin, actor: owner()) >= 1
    end

    test "a users-only role ends nobody's sessions but its own" do
      editor = user!([users_role!()])
      target = user!([])
      _ = token_uuid(target)

      assert {:error, :not_permitted} = Sessions.revoke_user_sessions(target, actor: editor)
      _ = token_uuid(editor)
      assert Sessions.revoke_user_sessions(editor, actor: editor) >= 1
    end

    test "an Admin ends an ordinary user's sessions" do
      admin = user!(["Admin"])
      target = user!([])
      token = token_uuid(target)

      assert :ok = Sessions.revoke_session(token, actor: admin)
    end

    test "a preloaded target promoted after the dialog opens keeps their sessions" do
      admin = user!(["Admin"])
      target = user!([])
      token = token_uuid(target)
      stale_target = Auth.get_user_with_roles(target.uuid)
      {:ok, _} = Roles.assign_role(target, "Admin")

      assert {:error, :not_permitted} = Sessions.revoke_user_sessions(stale_target, actor: admin)
      assert Enum.any?(Sessions.list_user_sessions(target), &(&1.token_uuid == token))
    end

    test "an actor whose preloaded Admin role was revoked may end nobody else's sessions" do
      admin = user!(["Admin"])
      stale_admin = Auth.get_user_with_roles(admin.uuid)
      target = user!([])
      token = token_uuid(target)
      {:ok, _} = Roles.remove_role(admin, "Admin")

      assert {:error, :not_permitted} = Sessions.revoke_session(token, actor: stale_admin)
      assert {:error, :not_permitted} = Sessions.revoke_user_sessions(target, actor: stale_admin)
      assert Enum.any?(Sessions.list_user_sessions(target), &(&1.token_uuid == token))
    end

    test "system callers are unchecked" do
      target = owner()
      _ = token_uuid(target)
      assert Sessions.revoke_user_sessions(target) >= 1
    end
  end

  describe "the Sessions page" do
    # The dialog opens for an ordinary user; the target is then made an Admin
    # (outranking a non-Owner actor), so only the check at confirm time — the
    # context's `actor:` — stops the revoke.
    test "re-checks at confirm: a target who now outranks the actor keeps their sessions", %{
      conn: conn
    } do
      admin = user!(["Admin"])
      target = user!([])
      token = token_uuid(target)

      {:ok, view, _} = live(log_in_user(conn, admin), Routes.path("/admin/users/sessions"))

      render_click(view, "show_revoke_user_sessions", %{"user_uuid" => target.uuid})
      {:ok, _} = Roles.assign_role(target, "Admin")
      html = render_click(view, "confirm_revoke_session", %{})

      assert html =~ "You are not allowed to end this person"
      assert Enum.any?(Sessions.list_user_sessions(target), &(&1.token_uuid == token))

      other = user!([])
      other_token = token_uuid(other)
      render_click(view, "show_revoke_session", %{"token_uuid" => other_token})
      {:ok, _} = Roles.assign_role(other, "Admin")
      html = render_click(view, "confirm_revoke_session", %{})

      assert html =~ "You are not allowed to end this person"
      assert Enum.any?(Sessions.list_user_sessions(other), &(&1.token_uuid == other_token))
    end

    test "refuses to open or confirm a revoke of an Owner's sessions", %{conn: conn} do
      admin = user!(["Admin"])
      target = owner()
      token = token_uuid(target)

      {:ok, view, _} = live(log_in_user(conn, admin), Routes.path("/admin/users/sessions"))

      html = render_click(view, "show_revoke_user_sessions", %{"user_uuid" => target.uuid})
      assert html =~ "You are not allowed to end this person"

      html = render_click(view, "show_revoke_session", %{"token_uuid" => token})
      assert html =~ "You are not allowed to end this person"

      render_click(view, "confirm_revoke_session", %{})
      assert Enum.any?(Sessions.list_user_sessions(target), &(&1.token_uuid == token))
    end
  end
end
