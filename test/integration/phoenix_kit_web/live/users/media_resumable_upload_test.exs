defmodule PhoenixKitWeb.Live.Users.MediaResumableUploadTest do
  @moduledoc """
  The media browser sends files in resumable chunks (`ResumableUpload`): the
  browser's uploader moves the bytes to the plug, LiveView only hears
  progress, and the entry is consumed from the assembled file.

  `render_upload` does not run the JavaScript uploader, so the test plays its
  part by writing the assembled file where the server expects it.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.ResumableUpload

  @buckets_cache :phoenix_kit_buckets_cache
  @modified 1_600_000_000_000

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_resumable_media_#{n}")
    parts = Path.join(System.tmp_dir!(), "pk_resumable_media_parts_#{n}")
    Application.put_env(:phoenix_kit, :resumable_upload_dir, parts)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "resumable-#{n}",
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
      Application.delete_env(:phoenix_kit, :resumable_upload_dir)
      File.rm_rf(root)
      File.rm_rf(parts)
    end)

    {user, _token} = create_admin_user()
    %{user: user}
  end

  defp open(conn, user) do
    {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/admin/media"))
    view
  end

  defp entry_config(view), do: :sys.get_state(view.pid).socket.assigns.uploads.media_files

  defp stored_count(user),
    do: Repo.aggregate(from(f in Storage.File, where: f.user_uuid == ^user.uuid), :count)

  # The path the browser's chunks are assembled at for this person's file.
  defp part_for(user, name, content) do
    entry = %{
      client_name: name,
      client_size: byte_size(content),
      client_last_modified: @modified
    }

    socket = %Phoenix.LiveView.Socket{
      endpoint: PhoenixKitWeb.Endpoint,
      assigns: %{__changed__: %{}, phoenix_kit_current_user: user}
    }

    {:ok, meta, _} = ResumableUpload.external().(entry, socket)
    meta.path
  end

  test "the browser's uploads name the resumable uploader, and the manager is told", %{
    conn: conn,
    user: user
  } do
    view = open(conn, user)
    assert is_function(entry_config(view).external)
    assert render(view) =~ ~s(data-resumable="true")
  end

  test "an entry whose chunks have all arrived is stored, and its assembled file removed", %{
    conn: conn,
    user: user
  } do
    view = open(conn, user)
    content = "resumable-bytes-#{System.unique_integer()}"
    path = part_for(user, "chunked.png", content)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    input =
      file_input(view, "#folder-drop-upload-form", :media_files, [
        %{name: "chunked.png", content: content, type: "image/png", last_modified: @modified}
      ])

    render_upload(input, "chunked.png")
    Process.sleep(800)
    render(view)

    assert stored_count(user) == 1
    refute File.exists?(path)
  end

  # The browser says when an external upload is done; the server holds what
  # actually arrived. A partial file is what a client claiming a finish it did
  # not send leaves; a missing one is what a second entry of the same file
  # (the same upload) finds after the first was consumed and its file removed.
  for {label, held} <- [{"partial", :half}, {"missing", :none}] do
    test "an entry reported done with its assembled file #{label} is not stored, and the page lives on",
         %{conn: conn, user: user} do
      view = open(conn, user)
      content = "resumable-bytes-#{System.unique_integer()}"
      path = part_for(user, "early.png", content)
      File.mkdir_p!(Path.dirname(path))

      if unquote(held) == :half,
        do: File.write!(path, binary_part(content, 0, div(byte_size(content), 2)))

      input =
        file_input(view, "#folder-drop-upload-form", :media_files, [
          %{name: "early.png", content: content, type: "image/png", last_modified: @modified}
        ])

      render_upload(input, "early.png")
      Process.sleep(800)
      render(view)

      assert Process.alive?(view.pid)
      assert stored_count(user) == 0
      # A partial file is kept: the same file picked again carries on from it.
      assert File.exists?(path) == (unquote(held) == :half)
    end
  end

  test "with the setting off, the uploads are LiveView's own", %{conn: conn, user: user} do
    {:ok, _} = Settings.update_setting("storage_resumable_uploads", "false")
    view = open(conn, user)

    assert entry_config(view).external == false
    assert render(view) =~ ~s(data-resumable="false")
  end
end
