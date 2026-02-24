defmodule PhoenixKit.ModuleRegistryTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleRegistry

  # The registry is started in test_helper.exs with all 21 internal modules loaded.

  describe "all_modules/0" do
    test "returns a non-empty list" do
      modules = ModuleRegistry.all_modules()
      assert is_list(modules)
      assert modules != []
    end

    test "contains all 21 internal modules" do
      modules = ModuleRegistry.all_modules()
      assert length(modules) >= 21
    end

    test "all entries are atoms" do
      for mod <- ModuleRegistry.all_modules() do
        assert is_atom(mod), "Expected atom, got #{inspect(mod)}"
      end
    end

    test "contains known internal modules" do
      modules = ModuleRegistry.all_modules()
      assert PhoenixKit.Modules.AI in modules
      assert PhoenixKit.Modules.Tickets in modules
      assert PhoenixKit.Modules.Billing in modules
      assert PhoenixKit.Modules.Entities in modules
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
      assert ModuleRegistry.get_by_key("ai") == PhoenixKit.Modules.AI
      assert ModuleRegistry.get_by_key("tickets") == PhoenixKit.Modules.Tickets
      assert ModuleRegistry.get_by_key("billing") == PhoenixKit.Modules.Billing
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

      assert :admin_tickets in tab_ids
      assert :admin_billing in tab_ids
      assert :admin_entities in tab_ids
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
      assert length(metadata) >= 20

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
      assert "tickets" in keys
      assert "billing" in keys
      assert "ai" in keys
      assert "entities" in keys
      assert "shop" in keys
    end
  end

  describe "all_feature_keys/0" do
    test "returns sorted list of 20 feature keys" do
      keys = ModuleRegistry.all_feature_keys()
      assert is_list(keys)
      assert length(keys) == 20
      assert keys == Enum.sort(keys)
    end

    test "contains expected keys" do
      keys = ModuleRegistry.all_feature_keys()
      assert "ai" in keys
      assert "billing" in keys
      assert "shop" in keys
      assert "tickets" in keys
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
      assert map_size(checks) >= 20

      for {key, {mod, fun}} <- checks do
        assert is_binary(key)
        assert is_atom(mod)
        assert fun == :enabled?
      end
    end

    test "maps known keys to correct modules" do
      checks = ModuleRegistry.feature_enabled_checks()
      assert checks["tickets"] == {PhoenixKit.Modules.Tickets, :enabled?}
      assert checks["ai"] == {PhoenixKit.Modules.AI, :enabled?}
      assert checks["billing"] == {PhoenixKit.Modules.Billing, :enabled?}
    end
  end

  describe "permission_labels/0" do
    test "returns a map of key => label" do
      labels = ModuleRegistry.permission_labels()
      assert is_map(labels)
      assert labels["tickets"] == "Tickets"
      assert labels["ai"] == "AI"
      assert labels["shop"] == "E-Commerce"
    end
  end

  describe "permission_icons/0" do
    test "returns a map of key => icon" do
      icons = ModuleRegistry.permission_icons()
      assert is_map(icons)
      assert is_binary(icons["tickets"])
      assert String.starts_with?(icons["tickets"], "hero-")
    end
  end

  describe "permission_descriptions/0" do
    test "returns a map of key => description" do
      descriptions = ModuleRegistry.permission_descriptions()
      assert is_map(descriptions)
      assert is_binary(descriptions["tickets"])
      assert String.length(descriptions["tickets"]) > 0
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
end
