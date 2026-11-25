defmodule PhoenixKitWeb.PersonCardTest do
  @moduledoc """
  The person drawer's card (`GET <prefix>/people/:uuid/card`): only an
  admin-area viewer gets one; the email and Open profile only with the
  `users` permission (or for oneself); everyone else, an unknown uuid and
  an inactive account get a bare 404.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  defp user!(attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(
        Map.merge(
          %{
            "email" => "card-#{System.unique_integer([:positive])}@example.com",
            "password" => "ValidPassword123!"
          },
          attrs
        )
      )

    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  defp card_path(uuid), do: Routes.path("/people/#{uuid}/card")

  # An account that reaches the admin area through one permission only, not `users`.
  defp narrow_viewer! do
    viewer = user!()
    {:ok, role} = Roles.create_role(%{name: "Card viewer #{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "media")
    {:ok, _} = Roles.assign_role(viewer, role.name)
    viewer
  end

  setup do
    # The first account of a fresh database becomes Owner.
    _seed = user!()
    :ok
  end

  test "an admin with the users permission sees the email and Open profile", %{conn: conn} do
    {admin, _token} = create_admin_user()
    person = user!(%{"username" => "ada_card"})

    html = conn |> log_in_user(admin) |> get(card_path(person.uuid)) |> html_response(200)

    assert html =~ "@ada_card"
    assert html =~ person.email
    assert html =~ "Open profile"
    assert html =~ Routes.path("/admin/users/view/#{person.uuid}")
  end

  test "another admin-area viewer sees the name, without the email or the profile", %{conn: conn} do
    viewer = narrow_viewer!()
    person = user!(%{"username" => "bo_card"})

    html = conn |> log_in_user(viewer) |> get(card_path(person.uuid)) |> html_response(200)

    assert html =~ "@bo_card"
    refute html =~ person.email
    refute html =~ "Open profile"
  end

  test "the card speaks the page's language when it is an enabled one", %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    {admin, _token} = create_admin_user()
    person = user!()
    conn = log_in_user(conn, admin)
    # Built first: ConnTest runs the controller in this process, so the
    # German locale it sets would put `/de` into a path built after it.
    path = card_path(person.uuid)

    # `<html lang="de">` names the base; the enabled dialect is used.
    assert conn |> get(path <> "?lang=de") |> html_response(200) =~
             "Profil öffnen"

    # A language that is not enabled leaves the default.
    html = build_conn() |> log_in_user(admin) |> get(path <> "?lang=fr")
    assert html_response(html, 200) =~ "Open profile"
  end

  test "an unconfirmed admin gets no card while confirmation is required", %{conn: conn} do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("require_email_confirmation", true)
    person = user!()

    {:ok, admin} =
      Auth.register_user(%{
        "email" => "unconfirmed-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _} = Roles.assign_role(admin, "Admin")
    admin = Repo.get!(Auth.User, admin.uuid)

    assert conn |> log_in_user(admin) |> get(card_path(person.uuid)) |> response(404) == ""
  end

  test "nobody else gets a card, and nothing tells them why", %{conn: conn} do
    person = user!()
    plain = user!()

    assert conn |> get(card_path(person.uuid)) |> response(404) == ""

    assert build_conn() |> log_in_user(plain) |> get(card_path(person.uuid)) |> response(404) ==
             ""

    {admin, _token} = create_admin_user()
    admin_conn = log_in_user(build_conn(), admin)
    assert admin_conn |> get(card_path(Ecto.UUID.generate())) |> response(404) == ""
    assert admin_conn |> get(card_path("not-a-uuid")) |> response(404) == ""

    {:ok, gone} = Auth.update_user_status(person, %{"is_active" => false})
    assert log_in_user(build_conn(), admin) |> get(card_path(gone.uuid)) |> response(404) == ""
  end
end
