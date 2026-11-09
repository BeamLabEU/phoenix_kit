defmodule PhoenixKit.Integration.Users.UserDetailsLayoutTest do
  @moduledoc """
  The admin's page for one user (2026-11-08): who it is in a header every tab
  shares, the details split into tabs kept in the URL, and Permanently Delete
  moved from a button beside the "..." menu (people were afraid of hitting it
  by mistake) to the end of that menu.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Test.ManagedOrganizationFixtures
  alias PhoenixKit.Utils.Routes

  defp plain_user do
    {:ok, user} =
      AuthCtx.register_user(%{
        email: "details_layout_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = AuthCtx.admin_confirm_user(user)
    Repo.get!(AuthCtx.User, user.uuid)
  end

  defp admin_user do
    user = plain_user()
    Roles.assign_role(user, "Admin")
    Repo.get!(AuthCtx.User, user.uuid)
  end

  defp open(conn, target, query \\ "") do
    {:ok, view, _html} =
      conn
      |> log_in_user(admin_user())
      |> live(Routes.path("/admin/users/view/#{target.uuid}") <> query)

    view
  end

  test "Permanently Delete is the last item of the menu, not a button beside it",
       %{conn: conn} do
    view = open(conn, plain_user())

    assert has_element?(view, ~s(#user-detail-actions button[phx-click="show_delete_modal"]))
    refute has_element?(view, ~s(button.btn[phx-click="show_delete_modal"]))

    # Still only ever opens the confirmation.
    assert render_click(view, "show_delete_modal") =~ "Permanently Delete User"
  end

  test "Edit is at hand, outside the menu", %{conn: conn} do
    target = plain_user()
    view = open(conn, target)

    assert has_element?(
             view,
             ~s(a.btn[href="#{Routes.path("/admin/users/edit/#{target.uuid}")}?return_to=view"])
           )
  end

  test "the header shows who it is on every tab", %{conn: conn} do
    target = plain_user()

    for query <- ["", "?tab=account", "?tab=notes"] do
      view = open(conn, target, query)
      html = render(view)

      assert html =~ target.email
      assert html =~ "Registered"
      assert has_element?(view, "#user-detail-actions")
    end
  end

  test "the header's avatar is large and sits in a box pinned to the top", %{conn: conn} do
    view = open(conn, plain_user())

    assert has_element?(
             view,
             "#user-detail-avatar.self-start.shrink-0 [data-avatar-frame], #user-detail-avatar.self-start.shrink-0 .avatar > div"
           )

    assert view |> element("#user-detail-avatar") |> render() =~ "w-40 h-40"
  end

  test "Profile and Account are tabs of their own, in the URL", %{conn: conn} do
    target = plain_user()
    view = open(conn, target)

    html = render(view)
    assert html =~ "Basic Information"
    refute html =~ "Account Information"

    view |> element(~s(a[role=tab][href$="tab=account"])) |> render_click()
    assert_patch(view, Routes.path("/admin/users/view/#{target.uuid}?tab=account"))

    html = render(view)
    assert html =~ "Account Information"
    assert html =~ "Registration Details"
    refute html =~ "Basic Information"
  end

  describe "notes and comments" do
    test "a Comments tab says how to get the module when this project lacks it", %{conn: conn} do
      view = open(conn, plain_user(), "?tab=comments")

      assert has_element?(view, ~s(a[role=tab][href$="tab=comments"]))
      assert has_element?(view, "#user-comments-missing", "phoenix_kit_comments")
    end

    test "without the module the older notes stay, even empty, to write in", %{conn: conn} do
      view = open(conn, plain_user())
      assert has_element?(view, ~s(a[role=tab][href$="tab=notes"]))
    end
  end

  test "an organization's profile shows its name once, not a first and a last one",
       %{conn: conn} do
    org =
      ManagedOrganizationFixtures.organization(%{
        organization_name: "Oak Trading",
        first_name: "Stale"
      })

    view = open(conn, org)
    html = render(view)

    assert has_element?(view, "#user-info-name", "Organization Name")
    assert has_element?(view, "#user-info-name", "Oak Trading")
    assert html |> String.split("Organization Name") |> length() == 2
    refute html =~ "First Name"
    refute html =~ "Stale"
  end

  describe "Basic Information" do
    test "reads as one row per fact, at a size made for reading", %{conn: conn} do
      target = plain_user()

      {:ok, target} =
        AuthCtx.update_user_profile(target, %{
          "first_name" => "Teemu",
          "last_name" => "Korhonen",
          "username" => "teemu_korhonen",
          "country" => "AT"
        })

      view = open(conn, target)

      assert view |> element("#user-info-name dd") |> render() =~ "Teemu Korhonen"
      refute view |> element("#user-basic-info") |> render() =~ "First Name"
      assert has_element?(view, "#user-info-username dd", "@teemu_korhonen")
      assert has_element?(view, "#user-info-country dd", "🇦🇹 Austria")
      assert has_element?(view, "#user-info-email-status.badge-success", "Confirmed")
      refute view |> element("#user-basic-info") |> render() =~ "Email Confirmed"

      assert has_element?(
               view,
               ~s(#user-info-email a[href="mailto:#{target.email}"]),
               target.email
             )

      # daisyUI's card-body is 14px; the values say 16px themselves.
      assert has_element?(view, "#user-basic-info dd.text-base")
    end

    test "says when the email is not confirmed yet", %{conn: conn} do
      {:ok, target} =
        AuthCtx.register_user(%{
          email: "unconfirmed_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      view = open(conn, target)

      assert has_element?(view, "#user-info-email-status.badge-warning", "Unconfirmed")
    end
  end

  test "a link can open a tab, and one the page does not show opens Profile", %{conn: conn} do
    target = plain_user()

    assert render(open(conn, target, "?tab=account")) =~ "Account Information"
    assert render(open(conn, target, "?tab=nope")) =~ "Basic Information"
    # An organization-only tab on a person's page.
    assert render(open(conn, target, "?tab=people")) =~ "Basic Information"
  end
end
