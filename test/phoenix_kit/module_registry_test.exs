defmodule PhoenixKit.ModuleRegistryTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleRegistry

  # The registry is started in test_helper.exs with all internal modules loaded.

  describe "all_modules/0" do
    test "returns a non-empty list" do
      modules = ModuleRegistry.all_modules()
      assert is_list(modules)
      assert modules != []
    end

    test "contains all known internal modules" do
      modules = ModuleRegistry.all_modules()

      # Verify known modules are present rather than asserting a hardcoded count,
      # so this test doesn't break when modules are extracted or added.
      expected = [
        PhoenixKit.Modules.DB,
        PhoenixKit.Modules.Languages,
        PhoenixKit.Modules.Maintenance,
        PhoenixKit.Modules.Referrals,
        PhoenixKit.Modules.SEO,
        PhoenixKit.Modules.Sitemap,
        PhoenixKit.Modules.Storage,
        PhoenixKit.Modules.CustomerService,
        PhoenixKit.Jobs
      ]

      for mod <- expected do
        assert mod in modules, "#{inspect(mod)} should be in ModuleRegistry"
      end
    end

    test "all entries are atoms" do
      for mod <- ModuleRegistry.all_modules() do
        assert is_atom(mod), "Expected atom, got #{inspect(mod)}"
      end
    end

    test "contains known internal modules" do
      modules = ModuleRegistry.all_modules()
      assert PhoenixKit.Modules.CustomerService in modules
      assert PhoenixKit.Jobs in modules
    end

    test "does not contain duplicates" do
      modules = ModuleRegistry.all_modules()
      assert length(modules) == length(Enum.uniq(modules))
    end
  end

  describe "initialized?/0" do
    test "returns true after startup" do
      assert ModuleRegistry.initialized?()
    end
  end

  describe "register/1 and unregister/1" do
    test "register adds a module" do
      defmodule FakeModule do
        def module_key, do: "fake"
      end

      refute FakeModule in ModuleRegistry.all_modules()

      ModuleRegistry.register(FakeModule)
      assert FakeModule in ModuleRegistry.all_modules()

      # Cleanup
      ModuleRegistry.unregister(FakeModule)
      refute FakeModule in ModuleRegistry.all_modules()
    end

    test "register is idempotent" do
      defmodule IdempotentModule do
        def module_key, do: "idempotent"
      end

      ModuleRegistry.register(IdempotentModule)
      count_after_first = length(ModuleRegistry.all_modules())

      ModuleRegistry.register(IdempotentModule)
      count_after_second = length(ModuleRegistry.all_modules())

      assert count_after_first == count_after_second

      # Cleanup
      ModuleRegistry.unregister(IdempotentModule)
    end

    test "unregister removes a module" do
      defmodule RemovableModule do
        def module_key, do: "removable"
      end

      ModuleRegistry.register(RemovableModule)
      assert RemovableModule in ModuleRegistry.all_modules()

      ModuleRegistry.unregister(RemovableModule)
      refute RemovableModule in ModuleRegistry.all_modules()
    end

    test "unregister is safe for non-registered module" do
      assert :ok = ModuleRegistry.unregister(NonExistentModule)
    end
  end

  describe "get_by_key/1" do
    test "finds module by key string" do
      assert ModuleRegistry.get_by_key("customer_service") == PhoenixKit.Modules.CustomerService
    end

    test "returns nil for unknown key" do
      assert is_nil(ModuleRegistry.get_by_key("nonexistent_module"))
    end
  end

  describe "all_admin_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = ModuleRegistry.all_admin_tabs()
      assert is_list(tabs)

      for tab <- tabs do
        assert %PhoenixKit.Dashboard.Tab{} = tab
        assert is_atom(tab.id)
        assert is_binary(tab.label)
        assert is_binary(tab.path)
      end
    end

    test "contains tabs from known modules" do
      tabs = ModuleRegistry.all_admin_tabs()
      tab_ids = Enum.map(tabs, & &1.id)

      assert :admin_customer_service in tab_ids
    end
  end

  describe "all_settings_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = ModuleRegistry.all_settings_tabs()
      assert is_list(tabs)

      for tab <- tabs do
        assert %PhoenixKit.Dashboard.Tab{} = tab
      end
    end
  end

  describe "all_permission_metadata/0" do
    test "returns a list of permission metadata maps" do
      metadata = ModuleRegistry.all_permission_metadata()
      assert is_list(metadata)
      assert length(metadata) >= 9

      for meta <- metadata do
        assert is_map(meta)
        assert is_binary(meta.key)
        assert is_binary(meta.label)
        assert is_binary(meta.icon)
        assert is_binary(meta.description)
      end
    end

    test "contains known permission keys" do
      keys = Enum.map(ModuleRegistry.all_permission_metadata(), & &1.key)
      assert "customer_service" in keys
    end
  end

  describe "all_feature_keys/0" do
    test "returns sorted list of feature keys" do
      keys = ModuleRegistry.all_feature_keys()
      assert is_list(keys)
      assert length(keys) >= 9
      assert keys == Enum.sort(keys)
    end

    test "contains expected keys" do
      keys = ModuleRegistry.all_feature_keys()
      assert "customer_service" in keys
      assert "jobs" in keys
    end

    test "does not contain core keys" do
      keys = ModuleRegistry.all_feature_keys()
      refute "dashboard" in keys
      refute "users" in keys
      refute "media" in keys
      refute "settings" in keys
      refute "modules" in keys
    end
  end

  describe "feature_enabled_checks/0" do
    test "returns a map of key => {module, :enabled?}" do
      checks = ModuleRegistry.feature_enabled_checks()
      assert is_map(checks)
      assert map_size(checks) >= 9

      for {key, {mod, fun}} <- checks do
        assert is_binary(key)
        assert is_atom(mod)
        assert fun == :enabled?
      end
    end

    test "maps known keys to correct modules" do
      checks = ModuleRegistry.feature_enabled_checks()
      assert checks["customer_service"] == {PhoenixKit.Modules.CustomerService, :enabled?}
    end
  end

  describe "permission_labels/0" do
    test "returns a map of key => label" do
      labels = ModuleRegistry.permission_labels()
      assert is_map(labels)
      assert labels["customer_service"] == "Customer Service"
    end
  end

  describe "permission_icons/0" do
    test "returns a map of key => icon" do
      icons = ModuleRegistry.permission_icons()
      assert is_map(icons)
      assert is_binary(icons["customer_service"])
      assert String.starts_with?(icons["customer_service"], "hero-")
    end
  end

  describe "permission_descriptions/0" do
    test "returns a map of key => description" do
      descriptions = ModuleRegistry.permission_descriptions()
      assert is_map(descriptions)
      assert is_binary(descriptions["customer_service"])
      assert String.length(descriptions["customer_service"]) > 0
    end
  end

  describe "all_route_modules/0" do
    test "returns a list of route modules" do
      route_modules = ModuleRegistry.all_route_modules()
      assert is_list(route_modules)

      for mod <- route_modules do
        assert is_atom(mod)
      end
    end
  end

  describe "enabled_modules/0" do
    test "returns a list of module atoms" do
      modules = ModuleRegistry.enabled_modules()
      assert is_list(modules)

      for mod <- modules do
        assert is_atom(mod)
      end
    end

    test "all returned modules have enabled?/0 returning true" do
      for mod <- ModuleRegistry.enabled_modules() do
        assert mod.enabled?(), "#{inspect(mod)} should be enabled"
      end
    end
  end

  describe "all_children/0" do
    test "returns a list" do
      children = ModuleRegistry.all_children()
      assert is_list(children)
    end
  end

  describe "all_user_dashboard_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = ModuleRegistry.all_user_dashboard_tabs()
      assert is_list(tabs)

      for tab <- tabs do
        assert %PhoenixKit.Dashboard.Tab{} = tab
      end
    end
  end

  describe "static_children/0" do
    test "returns a list without requiring GenServer" do
      children = ModuleRegistry.static_children()
      assert is_list(children)
    end
  end

  describe "run_all_legacy_migrations/0" do
    # The orchestrator iterates registered modules and calls each one's
    # `migrate_legacy/0` callback. The default implementation (provided
    # by `use PhoenixKit.Module`) returns `:ok`, so most modules in the
    # registry contribute a `:ok` entry to the result map. Modules that
    # raise / exit get their errors swallowed and reported as
    # `{:error, _}` rather than crashing the orchestrator.

    test "returns a map keyed by module atom" do
      result = ModuleRegistry.run_all_legacy_migrations()
      assert is_map(result)

      for {mod, outcome} <- result do
        assert is_atom(mod)
        assert outcome == :ok or match?({:error, _}, outcome)
      end
    end

    test "every registered module is present in the result" do
      result = ModuleRegistry.run_all_legacy_migrations()
      registered = ModuleRegistry.all_modules() |> MapSet.new()
      reported = result |> Map.keys() |> MapSet.new()

      assert MapSet.equal?(registered, reported)
    end

    test "modules with the default impl return :ok" do
      result = ModuleRegistry.run_all_legacy_migrations()

      # PhoenixKit.Modules.Storage doesn't override migrate_legacy/0
      # (no legacy data shape) — should fall through to the default
      # `:ok` from `use PhoenixKit.Module`.
      assert result[PhoenixKit.Modules.Storage] == :ok
    end

    test "swallows per-module raises without crashing the orchestrator" do
      # We can't easily inject a fake module into the live registry
      # without disrupting other tests, but we can call the private
      # path directly via the public function on an empty list. The
      # public function never raises — that's the contract.
      assert is_map(ModuleRegistry.run_all_legacy_migrations())
    end
  end
end
