defmodule PhoenixKitWeb.Live.Users.MediaLibraryUploadTest do
  @moduledoc """
  Uploading, into a second library, bytes this person already stored in
  Media. Dedup is per library since V203, so the second library gets its
  own copy — the page reports an ordinary upload, never a missing bucket
  or a file that stayed somewhere else.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    # LiveView's own uploader: `render_upload` sends the bytes over its channel.
    {:ok, _} = PhoenixKit.Settings.update_setting("storage_resumable_uploads", "false")
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_media_lib_upload_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "media-lib-upload-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    :ok
  end

  test "bytes already in Media are stored again in the other library", %{
    conn: conn
  } do
    {user, _token} = create_admin_user()
    content = "already-in-media-#{System.unique_integer([:positive])}"

    source =
      Path.join(System.tmp_dir!(), "pk_media_lib_src_#{System.unique_integer([:positive])}.png")

    File.write!(source, content)
    hash = Auth.calculate_file_hash(source)

    {:ok, existing} =
      Storage.store_file_in_buckets(source, "image", user.uuid, hash, "png", "photo.png",
        mime_type: "image/png"
      )

    on_exit(fn -> File.rm(source) end)

    {:ok, library} = Libraries.create_system_library(%{name: "Brand #{System.unique_integer()}"})

    {:ok, view, _html} =
      live(log_in_user(conn, user), Routes.path("/admin/media/library/#{library.slug}"))

    input =
      file_input(view, "#folder-drop-upload-form", :media_files, [
        %{name: "photo.png", content: content, type: "image/png"}
      ])

    render_upload(input, "photo.png")
    # The browser stores, then waits out its batch window before the flash.
    Process.sleep(800)
    html = render(view)

    refute html =~ "another library"
    refute html =~ "storage bucket"
    assert Storage.get_file(existing.uuid).library_uuid == Libraries.media_uuid()

    assert [copy] =
             Repo.all(
               from(f in Storage.File,
                 where: f.library_uuid == ^library.uuid and f.file_checksum == ^hash
               )
             )

    assert copy.uuid != existing.uuid
  end
end
