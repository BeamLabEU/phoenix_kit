defmodule PhoenixKitWeb.ModulesPageScanTest do
  @moduledoc """
  The admin Modules page must not scan the disk for external modules on mount,
  on a toggle, or when another admin's toggle reaches it over PubSub: the scan
  reads every beam of every phoenix_kit-dependent dep (seconds on a busy disk)
  and its result only changes with a rebuild.

  Sync: the beam-read counter is a global trace and the scan cache is global.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.KnownPackages
  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.TestSupport.ModuleScanFixture, as: Fixture

  @moduletag :tmp_dir

  # Registered so the page's toggle finds a module by key; it is not a dep on
  # disk, so it never shows up in the scan itself.
  defmodule ToggleFixture do
    def module_key, do: "modules_page_scan_toggle"
    def module_name, do: "Modules page scan toggle"
    def enabled?, do: false
    def get_config, do: %{enabled: false}
    def enable_system, do: :ok
    def disable_system, do: :ok
  end

  setup %{conn: conn, tmp_dir: tmp_dir} do
    {admin, _token} = create_admin_user()

    # Core's own test env has no phoenix_kit-dependent deps, so a scan would
    # read no beams and the counters below could never fail. One fixture dep
    # makes every scan visible.
    Fixture.write_dep(tmp_dir, :"modules_page_scan_fixture_#{System.unique_integer([:positive])}")

    ModuleRegistry.register(ToggleFixture)
    on_exit(fn -> ModuleRegistry.unregister(ToggleFixture) end)

    # The page reads the Hex catalog; answer it from an empty page, no network.
    KnownPackages.clear_cache()
    plug = fn conn -> Req.Test.json(conn, []) end
    KnownPackages.list(req_options: [plug: plug])

    # After register/1, which drops the cache: warm it the way boot does.
    ModuleDiscovery.refresh_cache()
    on_exit(fn -> ModuleDiscovery.clear_cache() end)

    {:ok, conn: log_in_user(conn, admin)}
  end

  test "a scan is visible to the counter (guards the assertions below)" do
    Fixture.count_beam_reads(fn reads ->
      ModuleDiscovery.discover_external_modules()
      assert reads.() > 0
    end)
  end

  test "renders, and a warm mount reads no beam", %{conn: conn} do
    Fixture.count_beam_reads(fn reads ->
      {:ok, view, html} = live(conn, "/phoenix_kit/admin/modules")
      assert html =~ "Not Installed"
      assert has_element?(view, ~s(button[phx-value-tab="not_installed"]))

      assert reads.() == 0
    end)
  end

  test "a cold cache is filled by the first mount, then left alone", %{conn: conn} do
    ModuleDiscovery.clear_cache()

    {:ok, _view, _html} = live(conn, "/phoenix_kit/admin/modules")

    Fixture.count_beam_reads(fn reads ->
      {:ok, _view, _html} = live(conn, "/phoenix_kit/admin/modules")
      assert reads.() == 0
    end)
  end

  test "toggling a module reads no beam", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/phoenix_kit/admin/modules")

    Fixture.count_beam_reads(fn reads ->
      render_hook(view, "toggle_module", %{"key" => ToggleFixture.module_key()})

      # The toggle really ran (a flash proves it did not bail out early).
      assert render(view) =~ "Modules page scan toggle enabled"
      assert reads.() == 0
    end)
  end

  test "another admin's toggle arriving over PubSub reads no beam", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/phoenix_kit/admin/modules")

    Fixture.count_beam_reads(fn reads ->
      Events.broadcast_module_enabled(ToggleFixture.module_key())

      # `render/1` round-trips through the LiveView, so the broadcast has been
      # handled by the time it returns.
      render(view)
      assert reads.() == 0
    end)
  end
end
