defmodule PhoenixKit.ModuleDiscoveryCacheTest do
  @moduledoc """
  The runtime scan cache (`ModuleDiscovery.cached_external_modules/0`) and the
  paths that must NOT be answered from it.

  DB-free. Sync on purpose: the cache is one global `:persistent_term`, the
  registry is one named process, and the beam-file counter below is a global
  trace — nothing here may interleave with another test.

  "How many times did it scan" is measured, not mocked: every scan reads each
  beam through `:beam_lib.chunks/2`, so the call count of that function is the
  amount of disk work done.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.KnownPackages
  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry

  @moduletag :tmp_dir

  setup do
    ModuleDiscovery.clear_cache()

    on_exit(fn ->
      # Leave the cache cold so a later test never inherits a fixture.
      ModuleDiscovery.clear_cache()
    end)

    :ok
  end

  describe "cached_external_modules/0" do
    test "scans the disk once, however often it is read", %{tmp_dir: tmp_dir} do
      mod = write_fixture_dep(tmp_dir, :scan_cache_fixture_once)

      with_beam_read_counter(fn reads ->
        first = ModuleDiscovery.cached_external_modules()
        scan_cost = reads.()

        assert mod in first
        assert scan_cost > 0, "the first read should have scanned the fixture's beam"

        for _ <- 1..20, do: assert(ModuleDiscovery.cached_external_modules() == first)

        assert reads.() == scan_cost
      end)
    end

    test "keeps answering from the cache until it is cleared", %{tmp_dir: tmp_dir} do
      mod = write_fixture_dep(tmp_dir, :scan_cache_fixture_stale)
      assert mod in ModuleDiscovery.cached_external_modules()

      File.rm_rf!(Path.join(tmp_dir, "scan_cache_fixture_stale"))

      # The honest scan sees the disk change; the cache deliberately does not.
      refute mod in ModuleDiscovery.discover_external_modules()
      assert mod in ModuleDiscovery.cached_external_modules()

      assert :ok = ModuleDiscovery.clear_cache()
      refute mod in ModuleDiscovery.cached_external_modules()
    end

    test "refresh_cache/0 rescans and replaces the cached value", %{tmp_dir: tmp_dir} do
      assert is_list(ModuleDiscovery.cached_external_modules())

      mod = write_fixture_dep(tmp_dir, :scan_cache_fixture_refresh)
      refute mod in ModuleDiscovery.cached_external_modules()

      assert mod in ModuleDiscovery.refresh_cache()
      assert mod in ModuleDiscovery.cached_external_modules()
    end
  end

  describe "the compile-time path" do
    test "module_hash/0 changes when a module appears, even with a warm cache", %{
      tmp_dir: tmp_dir
    } do
      warm = ModuleDiscovery.cached_external_modules()
      before_hash = ModuleDiscovery.module_hash()

      mod = write_fixture_dep(tmp_dir, :scan_cache_fixture_hash)

      assert ModuleDiscovery.module_hash() != before_hash,
             "a router recompile check answered from a stale cache would never fire"

      assert mod in ModuleDiscovery.discover_external_modules()
      assert ModuleDiscovery.cached_external_modules() == warm

      File.rm_rf!(Path.join(tmp_dir, "scan_cache_fixture_hash"))
      assert ModuleDiscovery.module_hash() == before_hash
    end

    test "module_hash/0 and discover_external_modules/0 scan on every call", %{
      tmp_dir: tmp_dir
    } do
      write_fixture_dep(tmp_dir, :scan_cache_fixture_honest)
      ModuleDiscovery.refresh_cache()

      with_beam_read_counter(fn reads ->
        ModuleDiscovery.discover_external_modules()
        one_scan = reads.()
        assert one_scan > 0

        ModuleDiscovery.discover_external_modules()
        ModuleDiscovery.module_hash()
        assert reads.() == one_scan * 3
      end)
    end
  end

  describe "ModuleRegistry" do
    test "rescan/0 rebuilds the cache from the disk", %{tmp_dir: tmp_dir} do
      assert is_list(ModuleDiscovery.cached_external_modules())

      mod = write_fixture_dep(tmp_dir, :scan_cache_fixture_rescan)
      refute mod in ModuleDiscovery.cached_external_modules()

      assert {:ok, new_modules} = ModuleRegistry.rescan()
      assert mod in new_modules
      assert mod in ModuleDiscovery.cached_external_modules()

      ModuleRegistry.unregister(mod)
    end

    test "register/1 and unregister/1 drop the cache", %{tmp_dir: tmp_dir} do
      defmodule CacheDropFixture do
        def module_key, do: "scan_cache_drop"
      end

      assert is_list(ModuleDiscovery.cached_external_modules())
      mod = write_fixture_dep(tmp_dir, :scan_cache_fixture_register)
      refute mod in ModuleDiscovery.cached_external_modules()

      ModuleRegistry.register(CacheDropFixture)
      assert mod in ModuleDiscovery.cached_external_modules()

      File.rm_rf!(Path.join(tmp_dir, "scan_cache_fixture_register"))
      ModuleRegistry.unregister(CacheDropFixture)
      refute mod in ModuleDiscovery.cached_external_modules()
    end

    test "not_installed_packages/0 scans at most once for a whole catalog", %{tmp_dir: tmp_dir} do
      write_fixture_dep(tmp_dir, :scan_cache_fixture_catalog)
      prime_catalog(for n <- 1..8, do: "phoenix_kit_scan_cache_catalog_#{n}")
      one_scan = scan_cost()
      assert one_scan > 0

      try do
        with_beam_read_counter(fn reads ->
          assert length(ModuleRegistry.not_installed_packages()) == 8
          first_call = reads.()

          # Cold cache: exactly one scan, not one per catalog entry (8 here).
          assert first_call == one_scan

          for _ <- 1..5, do: ModuleRegistry.not_installed_packages()
          assert reads.() == first_call
        end)
      after
        Application.delete_env(:phoenix_kit, :extra_known_packages)
        KnownPackages.clear_cache()
      end
    end
  end

  # What one full scan of the current code path costs, in beam reads.
  defp scan_cost do
    with_beam_read_counter(fn reads ->
      ModuleDiscovery.discover_external_modules()
      reads.()
    end)
  end

  # Fills the Hex catalog cache with `packages` (config extras) without touching
  # the network: the plug answers the one Hex request with an empty page.
  defp prime_catalog(packages) do
    extras =
      for package <- packages do
        %{package: package, key: package, name: package, description: "fixture", icon: "x"}
      end

    Application.put_env(:phoenix_kit, :extra_known_packages, extras)
    KnownPackages.clear_cache()

    plug = fn conn -> Req.Test.json(conn, []) end
    KnownPackages.list(req_options: [plug: plug])
  end

  # Calls `fun` with a zero-arity reader of how many beam files have been read
  # since the counter started. Tracing is global, hence the sync module.
  defp with_beam_read_counter(fun) do
    mfa = {:beam_lib, :chunks, 2}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      fun.(fn ->
        {:call_count, count} = :erlang.trace_info(mfa, :call_count)
        count
      end)
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  # A fake dep ebin in `<tmp_dir>/<app>`: a `<app>.app` that depends on
  # :phoenix_kit plus one beam carrying `@phoenix_kit_module true`, put on the
  # code path (removed again on exit). The app is never loaded or started.
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
