defmodule PhoenixKitWeb.ModulesPageScanTest do
  @moduledoc """
  The admin Modules page must not scan the disk for external modules on every
  mount and toggle: the scan reads every beam of every phoenix_kit-dependent dep
  (seconds on a busy disk) and its result only changes with a rebuild.

  Sync: the beam-read counter is a global trace and the scan cache is global.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.KnownPackages
  alias PhoenixKit.ModuleDiscovery

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: tmp_dir} do
    {admin, _token} = create_admin_user()

    # Core's own test env has no phoenix_kit-dependent deps, so a scan would
    # read no beams and the counters below could never fail. One fixture dep
    # makes every scan visible.
    write_fixture_dep(tmp_dir, :modules_page_scan_fixture)

    # The page reads the Hex catalog; answer it from an empty page, no network.
    KnownPackages.clear_cache()
    plug = fn conn -> Req.Test.json(conn, []) end
    KnownPackages.list(req_options: [plug: plug])

    ModuleDiscovery.refresh_cache()
    on_exit(fn -> ModuleDiscovery.clear_cache() end)

    {:ok, conn: log_in_user(conn, admin)}
  end

  test "a scan is visible to the counter (guards the assertions below)" do
    mfa = {:beam_lib, :chunks, 2}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      ModuleDiscovery.discover_external_modules()
      assert {:call_count, n} = :erlang.trace_info(mfa, :call_count)
      assert n > 0
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "renders, and mounting and switching tabs never rescan the disk", %{conn: conn} do
    mfa = {:beam_lib, :chunks, 2}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      {:ok, view, html} = live(conn, "/phoenix_kit/admin/modules")
      assert html =~ "Not Installed"

      for tab <- ~w(disabled not_installed active) do
        view |> element(~s(button[phx-value-tab="#{tab}"])) |> render_click()
      end

      assert {:call_count, 0} = :erlang.trace_info(mfa, :call_count)
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "a cold cache is filled by the first mount, then left alone", %{conn: conn} do
    ModuleDiscovery.clear_cache()

    {:ok, _view, _html} = live(conn, "/phoenix_kit/admin/modules")

    mfa = {:beam_lib, :chunks, 2}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      {:ok, _view, _html} = live(conn, "/phoenix_kit/admin/modules")
      assert {:call_count, 0} = :erlang.trace_info(mfa, :call_count)
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  # A fake dep ebin: a `<app>.app` depending on :phoenix_kit plus one beam
  # carrying `@phoenix_kit_module true`, on the code path until the test ends.
  defp write_fixture_dep(tmp_dir, app) do
    dir = Path.join(tmp_dir, to_string(app))
    File.mkdir_p!(dir)
    module = Module.concat([Macro.camelize(to_string(app))])

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
        @phoenix_kit_module true
      end
      """)

    File.write!(Path.join(dir, "#{module}.beam"), binary)

    File.write!(Path.join(dir, "#{app}.app"), """
    {application, #{app}, [
      {description, "fixture"},
      {vsn, "0.1.0"},
      {modules, ['#{module}']},
      {applications, [kernel, stdlib, phoenix_kit]}
    ]}.
    """)

    Code.append_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)
    module
  end
end
