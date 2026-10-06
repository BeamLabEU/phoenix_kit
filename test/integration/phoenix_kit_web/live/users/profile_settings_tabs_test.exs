defmodule PhoenixKitWeb.Live.Users.ProfileSettingsTabsTest do
  @moduledoc """
  `/profile/settings/<tab>`: one URL per tab, each showing only its own
  sections, and the integrations tab only for holders of its permission.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        email: "tabs_#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user())}
  end

  test "the bare path opens the account tab", %{conn: conn} do
    {:ok, _view, html} = live(conn, Routes.path("/profile/settings"))

    assert html =~ "Email Address"
    refute html =~ "Active Sessions"
    refute html =~ "Annotation tools"
  end

  test "each tab shows only its own sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, Routes.path("/profile/settings/sessions"))
    assert html =~ "Active Sessions"
    refute html =~ "Annotation tools"

    {:ok, _view, html} = live(conn, Routes.path("/profile/settings/security"))
    refute html =~ "Active Sessions"
    refute html =~ "Annotation tools"
  end

  test "the media tab holds the annotation tools, for a user with no storage access", %{
    conn: conn
  } do
    # The tab is offered to everyone because this section is on it; the
    # libraries card inside keeps its own storage gate, so a plain user
    # sees the annotation tools and nothing about libraries.
    {:ok, _view, html} = live(conn, Routes.path("/profile/settings/media"))

    assert html =~ "Annotation tools"
    assert html =~ "Open media ready to annotate"
    refute html =~ "My libraries"
    refute html =~ "Active Sessions"
  end

  test "switching tabs patches and swaps the sections", %{conn: conn} do
    {:ok, view, _html} = live(conn, Routes.path("/profile/settings/account"))

    html = render_patch(view, Routes.path("/profile/settings/sessions"))

    assert html =~ "Active Sessions"
    refute html =~ "Annotation tools"
  end

  test "an unknown tab goes to the first one", %{conn: conn} do
    # A patch while the page first loads arrives as a redirect.
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, Routes.path("/profile/settings/nope"))

    assert to == Routes.path("/profile/settings/account")
  end

  test "the integrations tab is offered only with the integrations permission", %{conn: conn} do
    {:ok, _view, html} = live(conn, Routes.path("/profile/settings"))

    refute html =~ ~s(href="#{Routes.path("/profile/settings/integrations")}")
  end

  test "a holder of the integrations permission is offered its tab" do
    {admin, _token} = create_admin_user()
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations")

    {:ok, _view, html} =
      live(log_in_user(Phoenix.ConnTest.build_conn(), admin), Routes.path("/profile/settings"))

    assert html =~ ~s(href="#{Routes.path("/profile/settings/integrations")}")

    {:ok, _view, html} =
      live(
        log_in_user(Phoenix.ConnTest.build_conn(), admin),
        Routes.path("/profile/settings/integrations")
      )

    # The integrations page carries the same tab strip, back to the others.
    assert html =~ ~s(href="#{Routes.path("/profile/settings/sessions")}")
  end
end
