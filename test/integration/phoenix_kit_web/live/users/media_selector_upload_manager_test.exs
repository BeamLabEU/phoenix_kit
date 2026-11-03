defmodule PhoenixKitWeb.Live.Users.MediaSelectorUploadManagerTest do
  @moduledoc """
  The media selector page sends its uploads through the upload manager, like
  the media browser: a few files at a time, each with its own controls, and
  the manager's cancel button answered by the page.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Utils.Routes

  setup do
    {user, _token} = create_admin_user()
    %{user: user}
  end

  test "the page carries the upload manager, capped by the site's setting", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = PhoenixKit.Settings.update_setting("storage_max_concurrent_uploads", "3")
    on_exit(fn -> PhoenixKit.Cache.invalidate(:settings, "storage_max_concurrent_uploads") end)

    {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/admin/media/selector"))

    assert html =~ ~s(phx-hook="UploadManager")
    assert html =~ ~s(data-max="3")
    assert html =~ ~s(data-cancel-event="pk_upload_cancel")
    # The page's own upload input is the only one.
    assert length(Regex.scan(~r/data-phx-upload-ref=/, html)) == 1
  end

  test "the page answers the manager's cancel for an entry that is not there", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/admin/media/selector"))

    render_hook(view, "pk_upload_cancel", %{"ref" => "42", "name" => "media_files"})

    # Still alive and rendering.
    assert render(view) =~ "UploadManager"
  end

  test "the page holds files to the site's size limit, not LiveView's 8 MB default", %{
    conn: conn,
    user: user
  } do
    on_exit(fn -> PhoenixKit.Cache.invalidate(:settings, "storage_max_upload_size_mb") end)

    {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/admin/media/selector"))
    config = :sys.get_state(view.pid).socket.assigns.uploads.media_files
    assert config.max_file_size == 500 * 1_000_000

    {:ok, _} = PhoenixKit.Settings.update_setting("storage_max_upload_size_mb", "1200")
    PhoenixKit.Cache.invalidate(:settings, "storage_max_upload_size_mb")

    {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/admin/media/selector"))
    config = :sys.get_state(view.pid).socket.assigns.uploads.media_files
    assert config.max_file_size == 1200 * 1_000_000
  end
end
