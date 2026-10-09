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

    test "names the library and both profiles, and whether the file is up to date", %{
      conn: conn,
      user: user
    } do
      file = image!(user)
      {:ok, view, _html} = live(conn, storage_path(file))

      assert has_element?(view, "#placement-library", "Media")
      assert has_element?(view, "#placement-profile", "Default")
      assert has_element?(view, "#placement-set", "Default")
      # Never placed (no stamps) is the Default at revision 1.
      assert has_element?(view, "#placement-profile .badge-success", "Up to date")

      Repo.update_all(
        from(f in StorageFile, where: f.uuid == ^file.uuid),
        set: [placed_revision: 0]
      )

      {:ok, view, _html} = live(conn, storage_path(file))
      assert has_element?(view, "#placement-profile .badge-warning", "Not up to date")
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
      assert html =~ "Not stored anywhere"
      assert html =~ "No copy"
      assert html =~ "Verify renditions"
    end
  end

  describe "verification_groups/2" do
    alias PhoenixKitWeb.Live.Users.MediaStorage

    defp result(name, bucket, result),
      do: %{name: name, bucket: bucket, path: "k/#{name}", result: result}

    test "groups by bucket, problems first, and names a profile bucket that holds nothing" do
      good = %{uuid: "b-good", name: "Local", provider: "local"}
      bad = %{uuid: "b-bad", name: "Cloud", provider: "s3"}

      groups =
        MediaStorage.verification_groups(
          [
            result("original", good, :ok),
            result("thumbnail", good, :ok),
            result("original", bad, :ok),
            result("thumbnail", bad, {:mismatch, "a", "b"}),
            result("medium", nil, :no_copy)
          ],
          [%{uuid: "b-good", name: "Local"}, %{uuid: "b-idle", name: "Spare"}]
        )

      assert [
               %{bucket: %{name: "Cloud"}, state: :problem, ok: 1, total: 2},
               %{bucket: %{name: "Local"}, state: :ok, ok: 2, total: 2},
               %{bucket: %{name: "Spare"}, state: :empty, total: 0},
               %{bucket: nil, state: :problem, total: 1}
             ] = groups

      # Within a group the problem comes before what is fine.
      assert [%{result: {:mismatch, _, _}}, %{result: :ok}] = hd(groups).rows
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
