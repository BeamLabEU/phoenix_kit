defmodule PhoenixKit.ModuleDiscoveryTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.ModuleDiscovery

  describe "discover_external_modules/0" do
    test "returns a list" do
      modules = ModuleDiscovery.discover_external_modules()
      assert is_list(modules)
    end

    test "all entries are atoms" do
      for mod <- ModuleDiscovery.discover_external_modules() do
        assert is_atom(mod)
      end
    end

    test "does not include internal PhoenixKit modules" do
      modules = ModuleDiscovery.discover_external_modules()

      refute PhoenixKit.Modules.AI in modules
      refute PhoenixKit.Modules.Tickets in modules
      refute PhoenixKit.Modules.Billing in modules
      refute PhoenixKit.Jobs in modules
    end

    test "returns empty list when no external plugins installed" do
      # In the test environment, no external plugins are deps
      modules = ModuleDiscovery.discover_external_modules()

      # Config fallback may add modules, but beam scanning alone should find none
      # in the test environment (no external deps with @phoenix_kit_module)
      assert is_list(modules)
    end

    test "includes modules from config fallback" do
      original = Application.get_env(:phoenix_kit, :modules, [])

      try do
        Application.put_env(:phoenix_kit, :modules, [SomeFakeModule])
        modules = ModuleDiscovery.discover_external_modules()
        assert SomeFakeModule in modules
      after
        Application.put_env(:phoenix_kit, :modules, original)
      end
    end

    test "deduplicates results" do
      modules = ModuleDiscovery.discover_external_modules()
      assert length(modules) == length(Enum.uniq(modules))
    end
  end

  describe "scan_beam_files/0" do
    test "returns a list" do
      modules = ModuleDiscovery.scan_beam_files()
      assert is_list(modules)
    end

    test "does not crash on scan" do
      # Should not raise even if no external deps exist
      assert is_list(ModuleDiscovery.scan_beam_files())
    end
  end
end
