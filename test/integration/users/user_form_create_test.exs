defmodule PhoenixKit.Integration.Users.UserFormCreateTest do
  @moduledoc """
  Creating a user from the admin form.

  The form used to leave the admin on a filled-in "Create User" page whenever
  anything after the insert crashed the LiveView (form recovery refilled the
  fields, and a second submit hit "email has already been taken"). It now
  lands on the new user's page, and the user records who added them.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  defp unique_email, do: "create_#{System.unique_integer([:positive])}@example.com"

  defp confirmed_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  defp admin_user do
    user = confirmed_user()
    Roles.assign_role(user, "Admin")
    Repo.get!(Auth.User, user.uuid)
  end

  setup do
    # The first registered user becomes Owner; keep that off the actors below.
    confirmed_user()
    :ok
  end

  test "lands on the new user's page and records the admin who added them", %{conn: conn} do
    admin = admin_user()
    conn = log_in_user(conn, admin)
    email = unique_email()

    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new"))

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> form("#user_form", user: %{email: email, password: "ValidPassword123!"})
      |> render_submit()

    created = Auth.get_user_by_email(email)
    assert to == Routes.path("/admin/users/view/#{created.uuid}")
    assert created.created_by_uuid == admin.uuid
  end

  test "the details page names the admin who added the user", %{conn: conn} do
    admin =
      Repo.update!(Ecto.Changeset.change(admin_user(), first_name: "Ada", last_name: "Admin"))

    {:ok, created} =
      Auth.admin_create_user(
        %{"email" => unique_email(), "password" => "ValidPassword123!"},
        admin
      )

    {:ok, _view, html} =
      conn
      |> log_in_user(admin)
      |> live(Routes.path("/admin/users/view/#{created.uuid}?tab=account"))

    # On the Account tab since the page was split into tabs (2026-11-08).
    assert html =~ "Added By"
    assert html =~ "Ada Admin"
  end

  test "created_by_uuid cannot be set through registration params" do
    admin = admin_user()

    {:ok, user} =
      Auth.register_user(%{
        "email" => unique_email(),
        "password" => "ValidPassword123!",
        "created_by_uuid" => admin.uuid
      })

    assert Repo.get!(Auth.User, user.uuid).created_by_uuid == nil
  end

  test "deleting the admin keeps the users they added, with created_by cleared" do
    admin = admin_user()

    {:ok, created} =
      Auth.admin_create_user(
        %{"email" => unique_email(), "password" => "ValidPassword123!"},
        admin
      )

    Repo.delete!(admin)

    assert Repo.get!(Auth.User, created.uuid).created_by_uuid == nil
  end
end
