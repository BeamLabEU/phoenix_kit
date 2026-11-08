defmodule PhoenixKit.Users.AvatarShapeTest do
  @moduledoc """
  The site's avatar shape (2026-11-08): chosen on Settings → Users → Avatars,
  drawn by every `user_avatar`, previewed and zoom-limited by the crop editor.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.AvatarShape
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.UserInfo

  defp admin_user do
    {:ok, user} =
      AuthCtx.register_user(%{
        email: "avatar_shape_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = AuthCtx.admin_confirm_user(user)
    Roles.assign_role(user, "Admin")
    Repo.get!(AuthCtx.User, user.uuid)
  end

  defp avatar(opts) do
    render_component(
      &UserInfo.user_avatar/1,
      Keyword.merge([user: %{email: "shape@example.com", custom_fields: %{}}, size: "sm"], opts)
    )
  end

  describe "the shapes" do
    test "a site that never chose draws circles, exactly as before" do
      assert AvatarShape.current() == "circle"
      assert avatar([]) =~ ~s(class="rounded-full overflow-hidden relative)
    end

    test "each shape has its own key, label and frame class" do
      shapes = AvatarShape.all()

      assert length(shapes) >= 10
      assert shapes |> Enum.map(& &1.key) |> Enum.uniq() |> length() == length(shapes)
      assert Enum.all?(shapes, &(&1.label != "" and &1.class != "" and &1.fit <= 1.0))
      assert AvatarShape.lowest_fit() == shapes |> Enum.map(& &1.fit) |> Enum.min()
    end

    test "a chosen shape is drawn by every avatar that names none" do
      :ok = AvatarShape.put("squircle")

      assert AvatarShape.current() == "squircle"
      html = avatar([])
      assert html =~ "mask mask-squircle"
      refute html =~ "rounded-full"

      # An avatar can still ask for a shape of its own (the settings tiles).
      assert avatar(shape: "hexagon") =~ "mask mask-hexagon"
    end

    test "an unknown shape is refused, and a stored one falls back to the circle" do
      assert {:error, :unknown_shape} = AvatarShape.put("triangle")

      {:ok, _} = Settings.update_setting(AvatarShape.setting_key(), "triangle")
      assert AvatarShape.current() == "circle"
    end
  end

  describe "Settings → Users → Avatars" do
    test "shows every shape and saves the one clicked, naming the admin", %{conn: conn} do
      admin = admin_user()

      {:ok, view, _html} =
        conn
        |> log_in_user(admin)
        |> live(Routes.path("/admin/settings/users?tab=avatars"))

      for shape <- AvatarShape.all() do
        assert has_element?(view, "#avatar-shape-#{shape.key}")
      end

      assert has_element?(view, ~s(#avatar-shape-circle[aria-pressed="true"]))

      view |> element("#avatar-shape-hexagon") |> render_click()

      assert AvatarShape.current() == "hexagon"
      assert has_element?(view, ~s(#avatar-shape-hexagon[aria-pressed="true"]))
      assert has_element?(view, ~s(#avatar-shape-circle[aria-pressed="false"]))

      entry =
        Repo.one!(
          from(e in PhoenixKit.Activity.Entry,
            where:
              e.action == "setting.changed" and
                fragment("?->>'key' = ?", e.metadata, ^AvatarShape.setting_key())
          )
        )

      assert entry.actor_uuid == admin.uuid
    end

    test "a forged shape changes nothing", %{conn: conn} do
      {:ok, view, _html} =
        conn
        |> log_in_user(admin_user())
        |> live(Routes.path("/admin/settings/users?tab=avatars"))

      render_click(view, "set_avatar_shape", %{"shape" => "<script>"})

      assert AvatarShape.current() == "circle"
    end
  end

  describe "the crop editor" do
    test "frames the picture in the site's shape and lowers the floor by its fit",
         %{conn: conn} do
      :ok = AvatarShape.put("diamond")
      admin = admin_user()

      {:ok, target} =
        AuthCtx.register_user(%{
          email: "shape_target_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, target} =
        AuthCtx.update_user_fields(target, %{
          "avatar_file_uuid" => Ecto.UUID.generate(),
          "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 1.5, "ar" => 3.0}
        })

      {:ok, view, _html} =
        conn |> log_in_user(admin) |> live(Routes.path("/admin/users/edit/#{target.uuid}"))

      view |> element("#user-form-avatar-crop-open") |> render_click()

      assert has_element?(view, "#user-form-avatar-crop-editor [data-crop-frame].mask-diamond")

      editor = view |> element("#user-form-avatar-crop-editor") |> render()
      [fit] = editor |> Floki.parse_fragment!() |> Floki.attribute("data-fit")
      assert fit == "0.7"

      [min] =
        editor
        |> Floki.parse_fragment!()
        |> Floki.find("input[type=range]")
        |> Floki.attribute("min")

      assert_in_delta String.to_float(min), 0.70 / :math.sqrt(10), 0.0001
    end
  end
end
