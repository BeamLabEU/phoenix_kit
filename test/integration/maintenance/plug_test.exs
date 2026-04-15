defmodule PhoenixKit.Integration.Maintenance.PlugTest do
  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Plugs.MaintenanceMode

  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
  defp past(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  setup do
    # Reset state
    Settings.update_boolean_setting("maintenance_enabled", false)
    Settings.update_setting("maintenance_scheduled_start", "")
    Settings.update_setting("maintenance_scheduled_end", "")
    :ok
  end

  describe "call/2 — maintenance inactive" do
    test "passes through unchanged" do
      conn = conn(:get, "/some-path")
      result = MaintenanceMode.call(conn, [])

      refute result.halted
      assert result.status == nil
    end
  end

  describe "call/2 — maintenance active, non-admin user" do
    setup do
      Maintenance.enable_system()
      :ok
    end

    test "renders 503 for regular paths" do
      conn = conn(:get, "/some-path") |> Plug.Test.init_test_session(%{})
      result = MaintenanceMode.call(conn, [])

      assert result.halted
      assert result.status == 503
      assert result.resp_body =~ "Maintenance Mode"
    end

    test "passes through static asset paths" do
      for path <- ["/assets/app.css", "/images/logo.png", "/fonts/foo.woff", "/favicon.ico"] do
        conn = conn(:get, path) |> Plug.Test.init_test_session(%{})
        result = MaintenanceMode.call(conn, [])
        refute result.halted, "#{path} should not be blocked"
      end
    end

    test "passes through auth routes" do
      for path <- [
            "/users/log-in",
            "/users/reset-password",
            "/users/confirm",
            "/users/magic-link/abc",
            "/users/auth/google"
          ] do
        conn = conn(:get, path) |> Plug.Test.init_test_session(%{})
        result = MaintenanceMode.call(conn, [])
        refute result.halted, "#{path} should not be blocked"
      end
    end

    test "does not bypass maintenance for look-alike parent-app paths" do
      # Parent-app paths that merely CONTAIN an auth route as a substring must
      # still be blocked — the skip check uses starts_with?, not contains?.
      for path <- [
            "/blog/users/log-in-to-us",
            "/shop/users/auth/callback",
            "/fake-assets/public/app.css",
            "/my/favicon-handler"
          ] do
        conn = conn(:get, path) |> Plug.Test.init_test_session(%{})
        result = MaintenanceMode.call(conn, [])
        assert result.halted, "#{path} should be blocked by maintenance"
      end
    end

    test "adds Retry-After header when scheduled end is set" do
      Maintenance.update_schedule(nil, future(3600))

      conn = conn(:get, "/some-path") |> Plug.Test.init_test_session(%{})
      result = MaintenanceMode.call(conn, [])

      [retry_after] = Plug.Conn.get_resp_header(result, "retry-after")
      assert {seconds, ""} = Integer.parse(retry_after)
      assert seconds > 0
      assert seconds <= 3600
    end

    test "does not add Retry-After header when no scheduled end" do
      conn = conn(:get, "/some-path") |> Plug.Test.init_test_session(%{})
      result = MaintenanceMode.call(conn, [])

      assert Plug.Conn.get_resp_header(result, "retry-after") == []
    end

    test "escapes HTML in header and subtext to prevent XSS" do
      Maintenance.update_header("<script>alert('xss')</script>")
      Maintenance.update_subtext("<img src=x onerror=alert(1)>")

      conn = conn(:get, "/some-path") |> Plug.Test.init_test_session(%{})
      result = MaintenanceMode.call(conn, [])

      refute result.resp_body =~ "<script>alert"
      refute result.resp_body =~ "<img src=x"
      assert result.resp_body =~ "&lt;script&gt;"
    end
  end

  describe "call/2 — cleanup of expired schedule" do
    test "auto-cleans expired schedule on request" do
      # Set an expired schedule directly, with manual toggle on
      Maintenance.enable_system()
      Settings.update_setting("maintenance_scheduled_end", DateTime.to_iso8601(past(60)))

      # Sanity check
      assert Maintenance.past_scheduled_end?()

      conn = conn(:get, "/some-path") |> Plug.Test.init_test_session(%{})
      result = MaintenanceMode.call(conn, [])

      # After cleanup, maintenance should not be active and request passes through
      refute result.halted
      refute Maintenance.manually_enabled?()
      assert Maintenance.get_scheduled_end() == nil
    end
  end
end
