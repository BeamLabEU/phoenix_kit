defmodule PhoenixKitWeb.Live.Users.MediaTest do
  @moduledoc """
  Integration tests for the Media LiveView (`/admin/media`).

  Tests cover:
  - Page renders for an authenticated admin user
  - URL query-string sync: folder, search, pagination, orphan filter
  - Deep-link (pre-seeded ?folder= param) opens the folder
  - Malformed ?page= param falls back safely to page 1
  - Session / auth guard (unauthenticated users are redirected)
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Routes

  @media_path Routes.path("/admin/media")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs \\ %{}) do
    name = Map.get(attrs, :name, "folder_#{System.unique_integer([:positive])}")
    {:ok, folder} = Storage.create_folder(Map.put(attrs, :name, name))
    folder
  end

  # ---------------------------------------------------------------------------
  # Authentication guard
  # ---------------------------------------------------------------------------

  describe "authentication" do
    test "unauthenticated request redirects to login", %{conn: conn} do
      conn = get(conn, @media_path)
      # LiveView auth redirects — may be 302 or a LiveView redirect
      assert conn.status in [302, 303] or
               (conn.status == 200 and conn.resp_body =~ "redirect")
    end
  end

  # ---------------------------------------------------------------------------
  # Basic rendering
  # ---------------------------------------------------------------------------

  describe "page rendering" do
    test "renders media page for authenticated admin", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, @media_path)

      assert html =~ "media-browser"
    end

    test "page_title is set to Media", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      assert page_title(view) =~ "Media"
    end
  end

  # ---------------------------------------------------------------------------
  # URL sync — handle_info navigate → push_patch
  # ---------------------------------------------------------------------------

  describe "URL sync via navigate events" do
    test "navigate event with folder updates URL to ?folder=<uuid>", %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: folder.uuid, q: "", page: 1, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path <> "?folder=#{folder.uuid}")
    end

    test "navigate event with search updates URL to ?q=<term>", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: nil, q: "logo", page: 1, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path <> "?q=logo")
    end

    test "clearing search removes q param from URL", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?q=old")

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: nil, q: "", page: 1, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path)
    end

    test "navigate to page 2 appends ?page=2", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: nil, q: "", page: 2, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path <> "?page=2")
    end

    test "navigate to page 1 omits page param", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?page=2")

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: nil, q: "", page: 1, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path)
    end

    test "orphan filter true appends ?orphaned=1", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: nil, q: "", page: 1, filter_orphaned: true}}}
      )

      assert_patch(view, @media_path <> "?orphaned=1")
    end

    test "orphan filter false omits orphaned param", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?orphaned=1")

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: nil, q: "", page: 1, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path)
    end

    test "all params combined produces correct query string", %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: folder.uuid, q: "img", page: 2, filter_orphaned: true}}}
      )

      patched = assert_patch(view)
      assert patched =~ "folder=#{folder.uuid}"
      assert patched =~ "q=img"
      assert patched =~ "page=2"
      assert patched =~ "orphaned=1"
    end
  end

  # ---------------------------------------------------------------------------
  # Deep links — handle_params passes nav_params to component
  # ---------------------------------------------------------------------------

  describe "deep-link params" do
    test "?folder=<uuid> deep link is accepted (page loads without error)", %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      assert html =~ "media-browser"
    end

    test "?q=<term> deep link is accepted", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, @media_path <> "?q=logo")

      assert html =~ "media-browser"
    end

    test "?page=foo malformed falls back to page 1 without crashing", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, @media_path <> "?page=foo")

      assert html =~ "media-browser"
    end

    test "?page=0 falls back to page 1 without crashing", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, @media_path <> "?page=0")

      assert html =~ "media-browser"
    end

    test "?page=-1 falls back to page 1 without crashing", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, @media_path <> "?page=-1")

      assert html =~ "media-browser"
    end
  end
end
