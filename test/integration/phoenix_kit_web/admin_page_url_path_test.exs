defmodule PhoenixKitWeb.AdminPageUrlPathTest do
  @moduledoc """
  Who sets `:url_path` on an admin page.

  The kit's navigation hook does, on every `handle_params`, for every LiveView
  mounted through its on_mount chain. A host filed "every tab-routed page must
  assign `url_path` by hand" — which was false, but understandable: the kit's
  own page GENERATOR emitted `assign(:url_path, "…")` into every page it wrote.
  The hook overwrote it immediately, so the line did nothing except teach the
  wrong pattern from the most trusted place a library has.

  These tests pin both halves: the generated code does not hand-assign it, and
  a page that never assigns it still gets its sidebar entry marked active.
  """
  use PhoenixKitWeb.ConnCase, async: false

  @templates ~w(admin_category_page.ex admin_category_index_page.ex)

  describe "generated admin pages" do
    for template <- @templates do
      test "#{template} does not hand-assign :url_path" do
        source = File.read!(Path.join(["priv", "templates", unquote(template)]))

        refute source =~ "assign(:url_path",
               "the navigation hook assigns :url_path; a generated line only teaches the wrong pattern"
      end
    end
  end

  describe "the navigation hook" do
    test "assigns :url_path on a page that never assigns it", %{conn: conn} do
      {admin, _token} = create_admin_user()
      conn = log_in_user(conn, admin)

      # The Users admin LiveView assigns :page_title and never :url_path, so
      # whatever :url_path holds after mount came from the hook.
      refute File.read!("lib/phoenix_kit_web/live/users/users.ex") =~ ":url_path"

      {:ok, view, _html} = live(conn, "/phoenix_kit/admin/users")

      # The dashboard registry is not started in this suite, so the sidebar
      # renders no entries to inspect; read the assign the sidebar would use.
      %{socket: socket} = :sys.get_state(view.pid)

      assert socket.assigns.url_path == "/phoenix_kit/admin/users"
    end

    test "assigns :url_host, the host the page is served on", %{conn: conn} do
      {admin, _token} = create_admin_user()
      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, "/phoenix_kit/admin/users")
      %{socket: socket} = :sys.get_state(view.pid)

      assert socket.assigns.url_host == "www.example.com"
    end
  end
end
