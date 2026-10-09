defmodule PhoenixKitWeb.Live.Users.MediaStorageTest do
  @moduledoc """
  A file's storage page (`/admin/media/:file_uuid/storage`) and the old address
  that now sends people to the media view: the header trail, the report, and the
  actions that need `media.manage`.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp image!(user, attrs \\ []) do
    n = System.unique_integer([:positive])

    file =
      Repo.insert!(
        struct!(
          %StorageFile{
            original_file_name: "IMG_#{n}.jpeg",
            file_name: "IMG_#{n}.jpeg",
            mime_type: "image/jpeg",
            file_type: "image",
            ext: "jpeg",
            file_checksum: "sha256:storage-#{n}",
            user_file_checksum: "user-sha256:storage-#{n}",
            size: 2048,
            width: 800,
            height: 600,
            status: "active",
            user_uuid: user.uuid
          },
          attrs
        )
      )

    Repo.insert!(%Storage.FileInstance{
      file_uuid: file.uuid,
      variant_name: "original",
      file_name: "IMG_#{n}.jpeg",
      mime_type: "image/jpeg",
      ext: "jpeg",
      checksum: "sha256:storage-#{n}",
      size: 2048,
      width: 800,
      height: 600,
      processing_status: "completed"
    })

    file
  end

  defp storage_path(file), do: Routes.path("/admin/media/#{file.uuid}/storage")

  describe "the page" do
    test "shows the file, its checksum and the renditions it should have", %{
      conn: conn,
      user: user
    } do
      file = image!(user)
      {:ok, view, html} = live(conn, storage_path(file))

      assert html =~ file.original_file_name
      assert html =~ file.file_checksum
      assert has_element?(view, "#rendition-original")
      # The Default set asks for a thumbnail this file does not have.
      assert has_element?(view, "#rendition-thumbnail")
      assert html =~ "Missing"
      assert html =~ "Open in media view"
    end

    test "the header: Media, the file in the media view, Storage", %{conn: conn, user: user} do
      file = image!(user)
      {:ok, _view, html} = live(conn, storage_path(file))

      assert html =~ ~s(href="#{Routes.path("/admin/media")}")
      assert html =~ ~s(href="#{Routes.path("/admin/media")}?file=#{file.uuid}")
      refute html =~ "Media Detail"
    end

    test "a file of another site library has its library between", %{conn: conn, user: user} do
      n = System.unique_integer([:positive])

      {:ok, library} =
        Libraries.create_system_library(%{"name" => "Holiday #{n}", "slug" => "holiday-#{n}"})

      file = image!(user, library_uuid: library.uuid)
      {:ok, _view, html} = live(conn, storage_path(file))

      assert html =~ "Holiday #{n}"
      assert html =~ ~s(href="#{Routes.path("/admin/media/library/holiday-#{n}")}")
    end

    test "a file that is not there says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, Routes.path("/admin/media/#{Ecto.UUID.generate()}/storage"))
      assert html =~ "File not found"
    end

    test "Verify reports a copy no bucket holds", %{conn: conn, user: user} do
      file = image!(user)
      {:ok, view, _html} = live(conn, storage_path(file))

      view |> element("button[phx-click=verify]") |> render_click()
      html = render_async(view)

      assert html =~ "Verification"
      assert html =~ "No copy"
    end
  end

  describe "the old address" do
    test "sends a file to the media view, keeping an annotation", %{conn: conn, user: user} do
      file = image!(user)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/media/#{file.uuid}"))

      assert to == Routes.path("/admin/media") <> "?file=#{file.uuid}"

      annotation = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/media/#{file.uuid}?annotation=#{annotation}"))

      assert to ==
               Routes.path("/admin/media") <> "?file=#{file.uuid}&annotation=#{annotation}"
    end

    test "a file that is gone lands on Media", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/media/#{Ecto.UUID.generate()}"))

      assert to == Routes.path("/admin/media")
    end
  end
end
