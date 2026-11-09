defmodule PhoenixKitWeb.Live.Components.AvatarEditorTest.Host do
  @moduledoc false
  # Renders the component alone, for a session user loaded from a token.
  use Phoenix.LiveView

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Live.Components.AvatarEditor

  def mount(_params, %{"token" => token}, socket) do
    {:ok, assign(socket, :user, Auth.get_user_by_session_token(token))}
  end

  def render(assigns) do
    ~H"""
    <.live_component module={AvatarEditor} id="host-avatar" user={@user} />
    """
  end

  def handle_info({AvatarEditor, _id, _result}, socket), do: {:noreply, socket}
end

defmodule PhoenixKitWeb.Live.Components.AvatarEditorTest do
  @moduledoc """
  The avatar control the profile settings and the admin's user form share
  (`PhoenixKitWeb.Live.Components.AvatarEditor`).

  The admin's form used to have a picker only: no crop editor, no "Adjust
  Crop", no "Reset", and a picked file waited for "Update User"
  (2026-11-08). Both pages now render the same component. A wide picture can
  be zoomed out until it fits the circle whole.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Components.AvatarEditor

  @wide_crop %{"x" => 0.5, "y" => 0.5, "zoom" => 1.5, "ar" => 3.0}

  defp unique_email, do: "avatar_editor_#{System.unique_integer([:positive])}@example.com"

  defp plain_user do
    {:ok, user} = AuthCtx.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = AuthCtx.admin_confirm_user(user)
    Repo.get!(AuthCtx.User, user.uuid)
  end

  defp admin_user do
    user = plain_user()
    Roles.assign_role(user, "Admin")
    Repo.get!(AuthCtx.User, user.uuid)
  end

  defp with_avatar(user, crop \\ @wide_crop) do
    {:ok, user} =
      AuthCtx.update_user_fields(user, %{
        "avatar_file_uuid" => Ecto.UUID.generate(),
        "avatar_crop" => crop
      })

    user
  end

  defp custom_fields(user), do: Repo.get!(AuthCtx.User, user.uuid).custom_fields

  defp entries(user, action) do
    Repo.all(from(e in Entry, where: e.resource_uuid == ^user.uuid and e.action == ^action))
  end

  defp edit_page(conn, admin, target) do
    {:ok, view, _html} =
      conn |> log_in_user(admin) |> live(Routes.path("/admin/users/edit/#{target.uuid}"))

    view
  end

  # What the media picker sends the component on confirm. The state read
  # makes sure the LiveView has handled it before the test looks.
  defp pick(view, editor_id, file_uuid) do
    Phoenix.LiveView.send_update(view.pid, AvatarEditor,
      id: editor_id,
      media_selected: [file_uuid]
    )

    _ = :sys.get_state(view.pid)
    view
  end

  # What the AvatarCrop hook pushes at the end of a gesture.
  defp frame(view, editor_id, crop) do
    view
    |> element("##{editor_id}-crop-editor")
    |> render_hook("avatar_crop_changed", crop)
  end

  describe "the admin's user form" do
    test "has the same controls as the person's own settings", %{conn: conn} do
      view = edit_page(conn, admin_user(), with_avatar(plain_user()))

      assert has_element?(view, "#user-form-avatar-browse")
      assert has_element?(view, "#user-form-avatar-crop-open")
    end

    test "a picked picture opens the crop editor and is saved with its framing, at once",
         %{conn: conn} do
      admin = admin_user()
      target = plain_user()
      view = edit_page(conn, admin, target)
      file_uuid = Ecto.UUID.generate()

      pick(view, "user-form-avatar", file_uuid)
      assert has_element?(view, "#user-form-avatar-crop-modal")

      refute has_element?(view, "#user-form-avatar-crop-reset"),
             "nothing to reset on a fresh pick"

      frame(view, "user-form-avatar", %{"x" => 0.5, "y" => 0.5, "zoom" => 0.4, "ar" => 3.0})
      view |> element("#user-form-avatar-crop-save") |> render_click()

      # No "Update User" needed.
      assert %{"avatar_file_uuid" => ^file_uuid, "avatar_crop" => %{"zoom" => 0.4}} =
               custom_fields(target)

      refute has_element?(view, "#user-form-avatar-crop-modal")
      assert render(view) =~ "Avatar updated successfully!"

      assert [entry] = entries(target, "user.avatar_changed")
      assert entry.actor_uuid == admin.uuid
      assert entry.target_uuid == target.uuid, "the person is told"
      assert entry.metadata["actor_role"] == "admin"
    end

    test "Cancel on a fresh pick keeps the old avatar", %{conn: conn} do
      target = with_avatar(plain_user())
      before = custom_fields(target)
      view = edit_page(conn, admin_user(), target)

      pick(view, "user-form-avatar", Ecto.UUID.generate())

      view |> element("#user-form-avatar-crop-cancel") |> render_click()

      assert custom_fields(target) == before
    end

    test "Adjust Crop re-frames the current picture, and Reset drops the crop", %{conn: conn} do
      admin = admin_user()
      target = with_avatar(plain_user())
      view = edit_page(conn, admin, target)

      view |> element("#user-form-avatar-crop-open") |> render_click()
      frame(view, "user-form-avatar", %{"x" => 0.3, "y" => 0.5, "zoom" => 2.0, "ar" => 3.0})
      view |> element("#user-form-avatar-crop-save") |> render_click()

      assert %{"avatar_crop" => %{"x" => 0.3, "zoom" => 2.0}} = custom_fields(target)
      assert [entry] = entries(target, "user.avatar_crop_changed")
      assert entry.actor_uuid == admin.uuid
      assert entry.target_uuid == target.uuid

      view |> element("#user-form-avatar-crop-open") |> render_click()
      view |> element("#user-form-avatar-crop-reset") |> render_click()

      assert custom_fields(target)["avatar_crop"] == nil
    end

    test "the zoom slider goes below the cover fit for a wide picture", %{conn: conn} do
      view = edit_page(conn, admin_user(), with_avatar(plain_user()))
      view |> element("#user-form-avatar-crop-open") |> render_click()

      [min] =
        view
        |> element("#user-form-avatar-crop-editor input[type=range]")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.attribute("min")

      assert_in_delta String.to_float(min), 1 / :math.sqrt(10), 0.0001
    end

    test "a saved avatar survives the next Update User", %{conn: conn} do
      target = plain_user()
      view = edit_page(conn, admin_user(), target)
      file_uuid = Ecto.UUID.generate()

      pick(view, "user-form-avatar", file_uuid)
      frame(view, "user-form-avatar", %{"x" => 0.5, "y" => 0.5, "zoom" => 2.0, "ar" => 1.0})
      view |> element("#user-form-avatar-crop-save") |> render_click()

      view
      |> form("#user_form", %{"user" => %{"first_name" => "Renamed"}})
      |> render_submit()

      assert %{"avatar_file_uuid" => ^file_uuid, "avatar_crop" => %{"zoom" => 2.0}} =
               custom_fields(target)
    end
  end

  describe "the person's own settings" do
    test "adjusting the crop is saved, says so, and tells nobody", %{conn: conn} do
      user = with_avatar(plain_user())

      {:ok, view, _html} =
        conn |> log_in_user(user) |> live(Routes.user_settings_path())

      view |> element("[id$='-avatar-crop-open']") |> render_click()

      view
      |> element("[id$='-avatar-crop-editor']")
      |> render_hook("avatar_crop_changed", %{"x" => 0.4, "y" => 0.5, "zoom" => 0.5, "ar" => 3.0})

      view |> element("[id$='-avatar-crop-save']") |> render_click()

      assert %{"avatar_crop" => %{"x" => 0.4, "zoom" => 0.5}} = custom_fields(user)
      # The message used to be set and never shown.
      assert render(view) =~ "Avatar crop updated!"

      assert [entry] = entries(user, "user.avatar_crop_changed")
      assert entry.actor_uuid == user.uuid
      assert entry.target_uuid == nil
      assert entry.metadata["actor_role"] == "user"
    end
  end

  describe "staff acting for a company" do
    setup do
      {:ok, _} = Settings.update_boolean_setting("enable_organization_accounts", true)
      :ok
    end

    test "cannot change the company's avatar", %{conn: conn} do
      {:ok, type} =
        RelationshipTypes.create_type(%{
          key: "staff_#{System.unique_integer([:positive])}",
          name: "Staff",
          from_kind: "person",
          to_kind: "organization",
          can_act: true,
          can_manage: false
        })

      organization = Fixtures.organization() |> with_avatar()
      person = Fixtures.person()

      link =
        Fixtures.narrowed_link(organization, person, [], %{relationship_type_uuid: type.uuid})

      %{token: token} = Fixtures.enter(organization, person, link)
      before = custom_fields(organization)

      {:ok, view, _html} = live_isolated(conn, __MODULE__.Host, session: %{"token" => token})

      view |> element("#host-avatar-crop-open") |> render_click()
      refute has_element?(view, "#host-avatar-crop-modal")

      # A forged gesture and save, as if the dialog were open.
      # Forged straight at the component, as if the dialog were open.
      target = with_target(view, "#host-avatar")

      render_click(target, "avatar_crop_changed", %{
        "x" => 0.1,
        "y" => 0.5,
        "zoom" => 3,
        "ar" => 1
      })

      render_click(target, "save_avatar_crop", %{})
      render_click(target, "reset_avatar_crop", %{})

      assert custom_fields(organization) == before
    end
  end
end
