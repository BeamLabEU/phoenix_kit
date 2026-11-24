defmodule PhoenixKitWeb.PersonCardTest do
  @moduledoc """
  The person drawer's card (`GET <prefix>/people/:uuid/card`): only an
  admin-area viewer gets one; the email and Open profile only with the
  `users` permission (or for oneself); everyone else, an unknown uuid and
  an inactive account get a bare 404.
  """

  use PhoenixKitWeb.ConnCase, async: false

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
