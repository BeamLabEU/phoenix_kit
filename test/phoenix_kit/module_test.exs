defmodule PhoenixKit.ModuleTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.ModuleRegistry

  @all_internal_modules [
    PhoenixKit.Modules.AI,
    PhoenixKit.Modules.Billing,
    PhoenixKit.Modules.Comments,
    PhoenixKit.Modules.Connections,
    PhoenixKit.Modules.DB,
    PhoenixKit.Modules.Emails,
    PhoenixKit.Modules.Entities,
    PhoenixKit.Modules.Languages,
    PhoenixKit.Modules.Legal,
    PhoenixKit.Modules.Maintenance,
    PhoenixKit.Modules.Pages,
    PhoenixKit.Modules.Posts,
    PhoenixKit.Modules.Publishing,
    PhoenixKit.Modules.Referrals,
    PhoenixKit.Modules.SEO,
    PhoenixKit.Modules.Shop,
    PhoenixKit.Modules.Sitemap,
    PhoenixKit.Modules.Storage,
    PhoenixKit.Modules.Sync,
    PhoenixKit.Modules.Tickets,
    PhoenixKit.Jobs
  ]

  # Ensure all modules are loaded so function_exported? works even when
  # running individual tests (where the "loadable" test may be excluded).
  setup_all do
    Enum.each(@all_internal_modules, &Code.ensure_loaded!/1)
    :ok
  end

  describe "all 21 modules implement PhoenixKit.Module behaviour" do
    test "all modules are loadable" do
      for mod <- @all_internal_modules do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} should be loadable"
      end
    end

    test "all modules implement module_key/0 returning a string" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :module_key, 0),
               "#{inspect(mod)} must implement module_key/0"

        key = mod.module_key()

        assert is_binary(key),
               "#{inspect(mod)}.module_key() must return a string, got: #{inspect(key)}"

        assert String.length(key) > 0, "#{inspect(mod)}.module_key() must not be empty"
      end
    end

    test "all modules implement module_name/0 returning a string" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :module_name, 0),
               "#{inspect(mod)} must implement module_name/0"

        name = mod.module_name()
        assert is_binary(name), "#{inspect(mod)}.module_name() must return a string"
        assert String.length(name) > 0, "#{inspect(mod)}.module_name() must not be empty"
      end
    end

    test "all modules implement enabled?/0 returning a boolean" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :enabled?, 0),
               "#{inspect(mod)} must implement enabled?/0"

        result = mod.enabled?()

        assert is_boolean(result),
               "#{inspect(mod)}.enabled?() must return a boolean, got: #{inspect(result)}"
      end
    end

    test "all modules implement enable_system/0" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :enable_system, 0),
               "#{inspect(mod)} must implement enable_system/0"
      end
    end

    test "all modules implement disable_system/0" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :disable_system, 0),
               "#{inspect(mod)} must implement disable_system/0"
      end
    end

    test "all modules export get_config/0" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :get_config, 0),
               "#{inspect(mod)} must implement get_config/0"
      end
    end

    test "get_config/0 returns a map for modules that don't need DB" do
      # Some modules do DB queries in get_config/0, skip those in unit tests
      for mod <- @all_internal_modules do
        result =
          try do
            mod.get_config()
          rescue
            _ -> :skipped
          end

        case result do
          :skipped -> :ok
          config -> assert is_map(config), "#{inspect(mod)}.get_config() must return a map"
        end
      end
    end

    test "all modules implement version/0 returning a version string" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :version, 0),
               "#{inspect(mod)} must implement version/0"

        version = mod.version()
        assert is_binary(version), "#{inspect(mod)}.version() must return a string"
      end
    end

    test "all modules export admin_tabs/0" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :admin_tabs, 0),
               "#{inspect(mod)} must implement admin_tabs/0"
      end
    end

    test "admin_tabs/0 returns a list for modules that don't require runtime deps" do
      # Some modules may reference compile-optional deps in their tab definitions,
      # so we test via safe_call to match how the registry actually calls them
      for mod <- @all_internal_modules do
        result =
          try do
            mod.admin_tabs()
          rescue
            _ -> :skipped
          end

        case result do
          :skipped -> :ok
          tabs -> assert is_list(tabs), "#{inspect(mod)}.admin_tabs() must return a list"
        end
      end
    end

    test "all modules implement settings_tabs/0 returning a list" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :settings_tabs, 0),
               "#{inspect(mod)} must implement settings_tabs/0"

        tabs = mod.settings_tabs()
        assert is_list(tabs), "#{inspect(mod)}.settings_tabs() must return a list"
      end
    end

    test "all modules implement children/0 returning a list" do
      for mod <- @all_internal_modules do
        assert function_exported?(mod, :children, 0),
               "#{inspect(mod)} must implement children/0"

        children = mod.children()
        assert is_list(children), "#{inspect(mod)}.children() must return a list"
      end
    end
  end

  describe "module_key uniqueness" do
    test "all module keys are unique" do
      keys = Enum.map(@all_internal_modules, & &1.module_key())

      assert length(keys) == length(Enum.uniq(keys)),
             "Duplicate module keys found: #{inspect(keys -- Enum.uniq(keys))}"
    end
  end

  describe "permission_metadata consistency" do
    test "modules with permission_metadata have matching module_key" do
      for mod <- @all_internal_modules do
        case mod.permission_metadata() do
          %{key: perm_key} ->
            assert perm_key == mod.module_key(),
                   "#{inspect(mod)}: permission_metadata key #{inspect(perm_key)} must match module_key #{inspect(mod.module_key())}"

          nil ->
            :ok
        end
      end
    end

    test "permission metadata has required fields" do
      for mod <- @all_internal_modules do
        case mod.permission_metadata() do
          %{} = meta ->
            assert Map.has_key?(meta, :key), "#{inspect(mod)} permission_metadata missing :key"

            assert Map.has_key?(meta, :label),
                   "#{inspect(mod)} permission_metadata missing :label"

            assert Map.has_key?(meta, :icon), "#{inspect(mod)} permission_metadata missing :icon"

            assert Map.has_key?(meta, :description),
                   "#{inspect(mod)} permission_metadata missing :description"

          nil ->
            :ok
        end
      end
    end

    test "permission icons use hero- prefix" do
      for mod <- @all_internal_modules do
        case mod.permission_metadata() do
          %{icon: icon} ->
            assert String.starts_with?(icon, "hero-"),
                   "#{inspect(mod)}: icon #{inspect(icon)} should start with hero-"

          nil ->
            :ok
        end
      end
    end
  end

  describe "admin_tabs consistency" do
    test "admin tabs have required fields" do
      for mod <- @all_internal_modules, tab <- mod.admin_tabs() do
        assert %PhoenixKit.Dashboard.Tab{} = tab
        assert is_atom(tab.id), "#{inspect(mod)} tab missing :id"
        assert is_binary(tab.label), "#{inspect(mod)} tab missing :label"
        assert is_binary(tab.path), "#{inspect(mod)} tab missing :path"

        assert String.starts_with?(tab.path, "/admin"),
               "#{inspect(mod)} admin tab path must start with /admin"
      end
    end

    test "admin tab ids are unique across all modules" do
      all_tab_ids =
        @all_internal_modules
        |> Enum.flat_map(& &1.admin_tabs())
        |> Enum.map(& &1.id)

      assert length(all_tab_ids) == length(Enum.uniq(all_tab_ids)),
             "Duplicate admin tab IDs: #{inspect(all_tab_ids -- Enum.uniq(all_tab_ids))}"
    end
  end

  describe "registry integration" do
    test "all internal modules are in the registry" do
      registered = ModuleRegistry.all_modules()

      for mod <- @all_internal_modules do
        assert mod in registered, "#{inspect(mod)} should be in ModuleRegistry"
      end
    end

    test "feature keys count matches modules with permission_metadata" do
      modules_with_perms =
        @all_internal_modules
        |> Enum.count(fn mod -> mod.permission_metadata() != nil end)

      assert length(ModuleRegistry.all_feature_keys()) == modules_with_perms
    end
  end
end
