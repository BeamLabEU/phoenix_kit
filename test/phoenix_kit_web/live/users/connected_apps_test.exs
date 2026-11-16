defmodule PhoenixKitWeb.Live.Users.ConnectedAppsTest do
  @moduledoc """
  The "Connected apps" section of "My API keys" (`/profile/settings/api-keys`): the person's
  connections, ending one, forged input, a right lost in the middle of the session, a borrowed
  session, and the switch of OAuth. The section is a nested LiveComponent
  (`PhoenixKitWeb.Live.Components.ConnectedApps`) whose events go to the component itself.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth, as: AuthCtx
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/profile/settings/api-keys")
  @component "#personal-api-keys-connected-apps"
  @right "api_personal_keys"

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    enable_oauth!()

    {user, role, scope} = oauth_holder(["media"])
    %{conn: log_in_user(conn, user), user: user, role: role, scope: scope}
  end

  defp fire(view, event, params \\ %{}),
    do: view |> with_target(@component) |> render_hook(event, params)

  defp row_id(seeded), do: "#personal-api-keys-connected-apps-grant-#{seeded.grant.uuid}"

  defp drop_right_silently!(role) do
    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == @right)
      )

    :ok
  end

  defp borrowed(conn) do
    {root, _role} = KeyTestSupport.user_without_api([@right])
    root_token = AuthCtx.generate_user_session_token(root)
    active_token = Plug.Conn.get_session(conn, :user_token)
    Plug.Conn.put_session(conn, :pk_session_accounts, [root_token, active_token])
  end

  describe "the list" do
    test "shows the person's connection with the client's name and status", %{
      conn: conn,
      scope: scope
    } do
      client = client!(%{client_name: "Claude"})
      seeded = seed_grant!(scope, client: client)

      {:ok, view, html} = live(conn, @path)

      assert has_element?(view, row_id(seeded))
      assert html =~ "Claude"

      assert has_element?(
               view,
               "#personal-api-keys-connected-apps-status-#{seeded.grant.uuid}[data-status=active]"
             )

      refute has_element?(view, "#personal-api-keys-connected-apps-oauth-off")
    end

    test "a connection made for another address of the site says so", %{conn: conn, scope: scope} do
      seeded = seed_grant!(scope, resource: "https://elsewhere.example/mcp/admin")

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(
               view,
               "#personal-api-keys-connected-apps-status-#{seeded.grant.uuid}[data-status=wrong_resource]"
             )

      assert render(view) =~ "Site address changed"
    end

    test "shows when a connection was last used, and 'Never' for one that was not", %{
      conn: conn,
      scope: scope
    } do
      used = seed_grant!(scope)
      unused = seed_grant!(scope)
      at = DateTime.add(DateTime.utc_now(), -7200) |> DateTime.truncate(:second)

      Repo.update_all(from(g in Grant, where: g.uuid == ^used.grant.uuid),
        set: [last_used_at: at]
      )

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#personal-api-keys-connected-apps-used-#{used.grant.uuid}")
      refute has_element?(view, "#personal-api-keys-connected-apps-used-#{unused.grant.uuid}")
      assert has_element?(view, row_id(unused), "Never")
    end

    test "names the first three scopes and counts the rest", %{conn: conn, scope: scope} do
      seeded = seed_grant!(scope)
      scopes = ["a:1", "b:2", "c:3", "d:4", "e:5"]

      Repo.update_all(from(g in Grant, where: g.uuid == ^seeded.grant.uuid),
        set: [scopes: scopes]
      )

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, row_id(seeded), "c:3")
      refute has_element?(view, row_id(seeded), "d:4")
      assert has_element?(view, row_id(seeded), "+2")
    end

    test "does not show the connection of another person", %{conn: conn} do
      {_other, _role, other_scope} = oauth_holder(["media"])
      theirs = seed_grant!(other_scope)

      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, row_id(theirs))
    end

    test "an empty list is explained while OAuth is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#personal-api-keys-connected-apps-empty")
    end

    test "while OAuth is off there is no card for a person with nothing connected", %{conn: conn} do
      KeyTestSupport.write_setting(fn ->
        Settings.update_boolean_setting("api_oauth_enabled", false)
      end)

      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#personal-api-keys-connected-apps-card")
    end

    test "while OAuth is off a connection is still listed, with the explanation", %{
      conn: conn,
      scope: scope
    } do
      seeded = seed_grant!(scope)

      KeyTestSupport.write_setting(fn ->
        Settings.update_boolean_setting("api_oauth_enabled", false)
      end)

      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, row_id(seeded))
      assert has_element?(view, "#personal-api-keys-connected-apps-oauth-off")
    end
  end

  describe "ending a connection" do
    test "asks first, then ends the grant, its key and its tokens", %{conn: conn, scope: scope} do
      seeded = seed_grant!(scope)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#personal-api-keys-connected-apps-revoke-#{seeded.grant.uuid}")
      |> render_click()

      assert has_element?(view, "#personal-api-keys-connected-apps-revoke-confirm")
      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil

      view |> element("#personal-api-keys-connected-apps-revoke-confirm") |> render_click()

      assert %DateTime{} = Repo.get!(Grant, seeded.grant.uuid).revoked_at
      assert %DateTime{} = Repo.get!(Key, seeded.key.uuid).revoked_at
      assert {:error, _} = Tokens.verify(seeded.access, "203.0.113.9")
      refute has_element?(view, row_id(seeded))
      assert has_element?(view, "#personal-api-keys-connected-apps-message")
    end

    test "cancelling ends nothing", %{conn: conn, scope: scope} do
      seeded = seed_grant!(scope)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#personal-api-keys-connected-apps-revoke-#{seeded.grant.uuid}")
      |> render_click()

      fire(view, "cancel_revoke")
      fire(view, "confirm_revoke")

      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil
    end

    test "a forged uuid of another person's connection is not found and ends nothing", %{
      conn: conn
    } do
      {_other, _role, other_scope} = oauth_holder(["media"])
      theirs = seed_grant!(other_scope)
      {:ok, view, _html} = live(conn, @path)

      html = fire(view, "request_revoke", %{"uuid" => theirs.grant.uuid})
      assert html =~ "That connection was not found."
      refute has_element?(view, "#personal-api-keys-connected-apps-revoke-confirm")

      fire(view, "confirm_revoke")
      assert Repo.get!(Grant, theirs.grant.uuid).revoked_at == nil
    end

    test "the confirming event takes no uuid from its params", %{conn: conn, scope: scope} do
      mine = seed_grant!(scope)
      {_other, _role, other_scope} = oauth_holder(["media"])
      theirs = seed_grant!(other_scope)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#personal-api-keys-connected-apps-revoke-#{mine.grant.uuid}")
      |> render_click()

      fire(view, "confirm_revoke", %{"uuid" => theirs.grant.uuid})

      assert %DateTime{} = Repo.get!(Grant, mine.grant.uuid).revoked_at
      assert Repo.get!(Grant, theirs.grant.uuid).revoked_at == nil
    end

    test "unknown events and malformed params are refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert fire(view, "request_revoke", %{"uuid" => "nope"}) =~ "That connection was not found."
      assert fire(view, "revoke_all", %{}) =~ "That action is not available."
    end
  end

  describe "a right lost in the middle of the session" do
    test "a person who lost the right cannot end a connection from the page opened before",
         %{conn: conn, role: role, scope: scope} do
      seeded = seed_grant!(scope)
      {:ok, view, _html} = live(conn, @path)
      drop_right_silently!(role)

      # The page is still the one mounted before; the next event rereads the rights.
      assert fire(view, "request_revoke", %{"uuid" => seeded.grant.uuid}) =~
               "You are not allowed to do that."

      refute has_element?(view, "#personal-api-keys-connected-apps-revoke-confirm")
      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil
    end

    test "the list is read again with what the person holds now: no rows, no buttons", %{
      conn: conn,
      role: role,
      scope: scope
    } do
      seeded = seed_grant!(scope)
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, row_id(seeded))
      drop_right_silently!(role)

      fire(view, "request_revoke", %{"uuid" => seeded.grant.uuid})

      refute has_element?(view, row_id(seeded))
      refute has_element?(view, "#personal-api-keys-connected-apps-revoke-#{seeded.grant.uuid}")
      assert has_element?(view, "#personal-api-keys-connected-apps-message")
    end

    test "confirming after the right was lost ends nothing", %{
      conn: conn,
      role: role,
      scope: scope
    } do
      seeded = seed_grant!(scope)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#personal-api-keys-connected-apps-revoke-#{seeded.grant.uuid}")
      |> render_click()

      drop_right_silently!(role)

      assert fire(view, "confirm_revoke") =~ "You are not allowed to do that."
      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil
    end

    test "the connection stops working at the next request, and is not removed", %{
      role: role,
      scope: scope
    } do
      seeded = seed_grant!(scope)
      assert {:ok, _actor} = Tokens.verify(seeded.access, "203.0.113.9")

      drop_right_silently!(role)

      assert {:error, _} = Tokens.verify(seeded.access, "203.0.113.9")
      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil
    end
  end

  describe "a borrowed session" do
    test "lists the connection, explains, and offers no button; every event is refused", %{
      conn: conn,
      scope: scope
    } do
      seeded = seed_grant!(scope)
      {:ok, view, html} = live(borrowed(conn), @path)

      assert html =~ "You are acting in another account"
      assert has_element?(view, row_id(seeded))
      refute has_element?(view, "#personal-api-keys-connected-apps-revoke-#{seeded.grant.uuid}")

      assert fire(view, "request_revoke", %{"uuid" => seeded.grant.uuid}) =~
               "Connections cannot be changed while you act in another account."

      fire(view, "confirm_revoke")
      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil
    end
  end
end
