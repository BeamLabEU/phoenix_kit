defmodule PhoenixKit.ModuleDiscoveryCacheTest do
  @moduledoc """
  The runtime scan cache (`ModuleDiscovery.cached_external_modules/0`) and the
  paths that must NOT be answered from it.

  DB-free. Sync on purpose: the cache is one global `:persistent_term`, the
  registry is one named process, and the call counters are global traces —
  nothing here may interleave with another test.

  "How many times did it scan" is measured, not mocked: every scan reads each
  beam through `:beam_lib.chunks/2`, so the call count of that function is the
  amount of disk work done.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.KnownPackages
  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.TestSupport.ModuleScanFixture, as: Fixture

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
      mod = Fixture.write_dep(tmp_dir, :scan_cache_fixture_once)

      Fixture.count_beam_reads(fn reads ->
        first = ModuleDiscovery.cached_external_modules()
        scan_cost = reads.()

        assert mod in first
        assert scan_cost > 0, "the first read should have scanned the fixture's beam"

        for _ <- 1..20, do: assert(ModuleDiscovery.cached_external_modules() == first)

        assert reads.() == scan_cost
      end)
    end

    test "concurrent cold readers share one scan", %{tmp_dir: tmp_dir} do
      Fixture.write_dep(tmp_dir, :scan_cache_fixture_concurrent)
      one_scan = scan_cost()

      Fixture.count_beam_reads(fn reads ->
        results =
          1..8
          |> Enum.map(fn _ -> Task.async(&ModuleDiscovery.cached_external_modules/0) end)
          |> Task.await_many(30_000)

        assert results |> Enum.uniq() |> length() == 1
        assert reads.() == one_scan
      end)
    end

    test "keeps answering from the cache until it is cleared", %{tmp_dir: tmp_dir} do
      mod = Fixture.write_dep(tmp_dir, :scan_cache_fixture_stale)
      assert mod in ModuleDiscovery.cached_external_modules()

      Fixture.remove_dep(tmp_dir, :scan_cache_fixture_stale)

      # The honest scan sees the disk change; the cache deliberately does not.
      refute mod in ModuleDiscovery.discover_external_modules()
      assert mod in ModuleDiscovery.cached_external_modules()

      assert :ok = ModuleDiscovery.clear_cache()
      refute mod in ModuleDiscovery.cached_external_modules()
    end

    test "refresh_cache/0 rescans and replaces the cached value", %{tmp_dir: tmp_dir} do
      assert is_list(ModuleDiscovery.cached_external_modules())

      mod = Fixture.write_dep(tmp_dir, :scan_cache_fixture_refresh)
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

      mod = Fixture.write_dep(tmp_dir, :scan_cache_fixture_hash)

      assert ModuleDiscovery.module_hash() != before_hash,
             "a router recompile check answered from a stale cache would never fire"

      assert mod in ModuleDiscovery.discover_external_modules()
      assert ModuleDiscovery.cached_external_modules() == warm

      Fixture.remove_dep(tmp_dir, :scan_cache_fixture_hash)
      assert ModuleDiscovery.module_hash() == before_hash
    end

    test "module_hash/0 and discover_external_modules/0 scan on every call", %{
      tmp_dir: tmp_dir
    } do
      Fixture.write_dep(tmp_dir, :scan_cache_fixture_honest)
      ModuleDiscovery.refresh_cache()
      one_scan = scan_cost()
      assert one_scan > 0

      Fixture.count_beam_reads(fn reads ->
        ModuleDiscovery.discover_external_modules()
        ModuleDiscovery.discover_external_modules()
        ModuleDiscovery.module_hash()
        assert reads.() == one_scan * 3
      end)
    end
  end

  describe "ModuleRegistry" do
    test "rescan/0 leaves the cache warm and current", %{tmp_dir: tmp_dir} do
      assert is_list(ModuleDiscovery.cached_external_modules())

      mod = Fixture.write_dep(tmp_dir, :scan_cache_fixture_rescan)
      on_exit(fn -> ModuleRegistry.unregister(mod) end)
      refute mod in ModuleDiscovery.cached_external_modules()

      assert {:ok, new_modules} = ModuleRegistry.rescan()
      assert mod in new_modules

      # Warm: reading it costs no scan. A rescan that cleared (or never filled)
      # the cache would make the next page load pay for it.
      Fixture.count_beam_reads(fn reads ->
        assert mod in ModuleDiscovery.cached_external_modules()
        assert reads.() == 0
      end)
    end

    test "rescan/0 with nothing new also leaves the cache warm", %{tmp_dir: tmp_dir} do
      # Registered by a first rescan, so the second finds nothing new.
      mod = Fixture.write_dep(tmp_dir, :scan_cache_fixture_rescan_idle)
      on_exit(fn -> ModuleRegistry.unregister(mod) end)
      assert {:ok, [^mod]} = ModuleRegistry.rescan()

      ModuleDiscovery.clear_cache()
      assert {:ok, []} = ModuleRegistry.rescan()

      Fixture.count_beam_reads(fn reads ->
        ModuleDiscovery.cached_external_modules()
        assert reads.() == 0
      end)
    end

    test "register/1 and unregister/1 drop the cache", %{tmp_dir: tmp_dir} do
      defmodule CacheDropFixture do
        def module_key, do: "scan_cache_drop"
      end

      on_exit(fn -> ModuleRegistry.unregister(CacheDropFixture) end)

      assert is_list(ModuleDiscovery.cached_external_modules())
      mod = Fixture.write_dep(tmp_dir, :scan_cache_fixture_register)
      refute mod in ModuleDiscovery.cached_external_modules()

      ModuleRegistry.register(CacheDropFixture)
      assert mod in ModuleDiscovery.cached_external_modules()

      Fixture.remove_dep(tmp_dir, :scan_cache_fixture_register)
      ModuleRegistry.unregister(CacheDropFixture)
      refute mod in ModuleDiscovery.cached_external_modules()
    end

    test "not_installed_packages/0 scans once and computes the installed set once", %{
      tmp_dir: tmp_dir
    } do
      Fixture.write_dep(tmp_dir, :scan_cache_fixture_catalog)
      prime_catalog(for n <- 1..8, do: "phoenix_kit_scan_cache_catalog_#{n}")
      one_scan = scan_cost()
      assert one_scan > 0

      try do
        Fixture.count_calls({:application, :loaded_applications, 0}, fn installed_sets ->
          Fixture.count_beam_reads(fn reads ->
            assert length(ModuleRegistry.not_installed_packages()) == 8

            # Cold cache: exactly one scan, not one per catalog entry (8 here)…
            assert reads.() == one_scan
            # …and one installed-apps computation, not one per entry.
            assert installed_sets.() == 1

            for _ <- 1..5, do: ModuleRegistry.not_installed_packages()
            assert reads.() == one_scan
            assert installed_sets.() == 6
          end)
        end)
      after
        Application.delete_env(:phoenix_kit, :extra_known_packages)
        KnownPackages.clear_cache()
      end
    end
  end

  # What one full scan of the current code path costs, in beam reads.
  defp scan_cost do
    Fixture.count_beam_reads(fn reads ->
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
end
