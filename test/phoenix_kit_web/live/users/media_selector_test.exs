defmodule PhoenixKitWeb.Live.Users.MediaSelectorTest do
  @moduledoc """
  Tests for the standalone media selector page's `scope_folder` query
  param (H3, media hierarchy phase 2, plan 8, task 2): it survives
  `handle_params` round-trips on its own (it is not declared to `UrlState`)
  and, when present, new uploads are attached to it.

  `:sys.get_state/1` on the LiveView pid is the documented house technique
  for reading assigns that never reach a render (see other `*_mount_test.exs`
  files and `AGENTS.md`'s test guidelines).
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/media/selector")

  defp socket_assigns(view) do
    %{socket: socket} = :sys.get_state(view.pid)
    socket.assigns
  end

  defp create_folder!(attrs \\ %{}) do
    name = Map.get(attrs, :name, "folder_#{System.unique_integer([:positive])}")
    {:ok, folder} = Storage.create_folder(Map.put(attrs, :name, name))
    folder
  end

  defp log_in_admin(conn) do
    {user, _token} = create_admin_user()
    log_in_user(conn, user)
  end

  # ---------------------------------------------------------------------------
  # mount ?scope_folder=
  # ---------------------------------------------------------------------------

  describe "mount ?scope_folder=" do
    test "a valid folder uuid is assigned", %{conn: conn} do
      conn = log_in_admin(conn)
      folder = create_folder!()

      {:ok, view, _html} =
        live(conn, "#{@path}?return_to=%2Fadmin&scope_folder=#{folder.uuid}")

      assert socket_assigns(view).scope_folder == folder.uuid
    end

    test "no scope_folder param: assigns nil (today's behaviour)", %{conn: conn} do
      conn = log_in_admin(conn)

      {:ok, view, _html} = live(conn, "#{@path}?return_to=%2Fadmin")

      assert socket_assigns(view).scope_folder == nil
    end

    test "a malformed uuid is ignored", %{conn: conn} do
      conn = log_in_admin(conn)

      {:ok, view, _html} =
        live(conn, "#{@path}?return_to=%2Fadmin&scope_folder=not-a-uuid")

      assert socket_assigns(view).scope_folder == nil
    end

    test "a trashed folder is ignored", %{conn: conn} do
      conn = log_in_admin(conn)
      folder = create_folder!()
      {:ok, _trashed} = Storage.trash_folder(folder, nil)

      {:ok, view, _html} =
        live(conn, "#{@path}?return_to=%2Fadmin&scope_folder=#{folder.uuid}")

      assert socket_assigns(view).scope_folder == nil
    end

    test "survives a search event (undeclared UrlState params round-trip on their own)",
         %{conn: conn} do
      conn = log_in_admin(conn)
      folder = create_folder!()

      {:ok, view, _html} =
        live(conn, "#{@path}?return_to=%2Fadmin&scope_folder=#{folder.uuid}")

      render_change(view, "search", %{"search" => %{"query" => "abc"}})

      assert socket_assigns(view).scope_folder == folder.uuid
    end

    test "survives a filter_type event", %{conn: conn} do
      conn = log_in_admin(conn)
      folder = create_folder!()

      {:ok, view, _html} =
        live(conn, "#{@path}?return_to=%2Fadmin&scope_folder=#{folder.uuid}")

      render_click(view, "filter_type", %{"filter" => "image"})

      assert socket_assigns(view).scope_folder == folder.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Upload attach
  # ---------------------------------------------------------------------------

  describe "upload with scope_folder set" do
    setup do
      # LiveView's own uploader: `render_upload` sends the bytes over its channel.
      {:ok, _} = PhoenixKit.Settings.update_setting("storage_resumable_uploads", "false")

      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "pk_media_selector_upload_#{System.unique_integer([:positive])}"
        )

      {:ok, _bucket} =
        Storage.create_bucket(%{
          name: "media-selector-upload-test-#{System.unique_integer([:positive])}",
          provider: "local",
          endpoint: tmp_root,
          enabled: true,
          priority: 0
        })

      # `store_file_in_buckets/6` queues `ProcessFileJob` via `Oban.insert/3` —
      # no Oban instance runs under `mix test` otherwise. `:manual` testing
      # just inserts the job row without executing the worker.
      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      on_exit(fn -> File.rm_rf(tmp_root) end)

      :ok
    end

    test "the uploaded file is attached to the scope folder", %{conn: conn} do
      conn = log_in_admin(conn)
      folder = create_folder!()

      {:ok, view, _html} =
        live(conn, "#{@path}?return_to=%2Fadmin&scope_folder=#{folder.uuid}")

      input =
        file_input(view, "#media-selector-upload-form", :media_files, [
          %{name: "scoped.png", content: "fake png bytes", type: "image/png"}
        ])

      render_upload(input, "scoped.png")

      [file_uuid | _] = socket_assigns(view).selected_uuids
      stored = Storage.get_file(file_uuid)

      assert stored.folder_uuid == folder.uuid
    end

    test "without scope_folder, the uploaded file stays at the root", %{conn: conn} do
      conn = log_in_admin(conn)

      {:ok, view, _html} = live(conn, "#{@path}?return_to=%2Fadmin")

      input =
        file_input(view, "#media-selector-upload-form", :media_files, [
          %{name: "unscoped.png", content: "fake png bytes", type: "image/png"}
        ])

      render_upload(input, "unscoped.png")

      [file_uuid | _] = socket_assigns(view).selected_uuids
      stored = Storage.get_file(file_uuid)

      assert stored.folder_uuid == nil
    end
  end
end
