defmodule PhoenixKit.Module do
  @moduledoc """
  Behaviour for PhoenixKit feature modules (internal and external).

  Any module that implements this behaviour can register itself with PhoenixKit's
  tab registry, permission system, supervisor tree, and route system.

  ## Usage

      defmodule PhoenixKitHelloWorld do
        use PhoenixKit.Module

        @impl true
        def module_key, do: "hello_world"

        @impl true
        def module_name, do: "Hello World"

        @impl true
        def enabled?, do: PhoenixKit.Settings.get_boolean_setting("hello_world_enabled", false)

        @impl true
        def enable_system do
          PhoenixKit.Settings.update_boolean_setting_with_module("hello_world_enabled", true, "hello_world")
        end

        @impl true
        def disable_system do
          PhoenixKit.Settings.update_boolean_setting_with_module("hello_world_enabled", false, "hello_world")
        end

        @impl true
        def permission_metadata do
          %{
            key: "hello_world",
            label: "Hello World",
            icon: "hero-hand-raised",
            description: "A demo module"
          }
        end

        @impl true
        def admin_tabs do
          [%PhoenixKit.Dashboard.Tab{
            id: :admin_hello_world,
            label: "Hello World",
            icon: "hero-hand-raised",
            path: "/admin/hello-world",
            priority: 640,
            level: :admin,
            permission: "hello_world",
            match: :prefix,
            group: :admin_modules
          }]
        end
      end

  ## Required Callbacks

  - `module_key/0` - Unique string key (e.g., `"tickets"`, `"billing"`)
  - `module_name/0` - Human-readable display name
  - `enabled?/0` - Whether the module is currently enabled
  - `enable_system/0` - Enable the module system-wide
  - `disable_system/0` - Disable the module system-wide

  ## Optional Callbacks

  All optional callbacks have sensible defaults provided by `use PhoenixKit.Module`:

  - `get_config/0` - Module stats/config map (default: `%{enabled: enabled?()}`)
  - `permission_metadata/0` - Permission key, label, icon, description (default: `nil`)
  - `admin_tabs/0` - Admin navigation tabs (default: `[]`)
  - `settings_tabs/0` - Settings subtabs (default: `[]`)
  - `user_dashboard_tabs/0` - User-facing dashboard tabs (default: `[]`)
  - `children/0` - Supervisor child specs (default: `[]`)
  - `route_module/0` - Module providing route macros (default: `nil`)
  - `version/0` - Module version string (default: `"0.0.0"`)
  """

  @typedoc "Permission metadata for the module"
  @type permission_meta :: %{
          key: String.t(),
          label: String.t(),
          icon: String.t(),
          description: String.t()
        }

  # Required callbacks
  @callback module_key() :: String.t()
  @callback module_name() :: String.t()
  @callback enabled?() :: boolean()
  @callback enable_system() :: :ok | {:ok, term()} | {:error, term()}
  @callback disable_system() :: :ok | {:ok, term()} | {:error, term()}

  # Optional callbacks with defaults provided by __using__
  @callback get_config() :: map()
  @callback permission_metadata() :: permission_meta() | nil
  @callback admin_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  @callback settings_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  @callback user_dashboard_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  @callback children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  @callback route_module() :: module() | nil
  @callback version() :: String.t()

  @optional_callbacks [
    get_config: 0,
    permission_metadata: 0,
    admin_tabs: 0,
    settings_tabs: 0,
    user_dashboard_tabs: 0,
    children: 0,
    route_module: 0,
    version: 0
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour PhoenixKit.Module

      # Persist marker in .beam file for zero-config auto-discovery.
      # Same pattern as Elixir's protocol consolidation — scannable via :beam_lib.chunks/2
      # without loading the module.
      Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
      @phoenix_kit_module true

      @impl PhoenixKit.Module
      def get_config, do: %{enabled: enabled?()}

      @impl PhoenixKit.Module
      def permission_metadata, do: nil

      @impl PhoenixKit.Module
      def admin_tabs, do: []

      @impl PhoenixKit.Module
      def settings_tabs, do: []

      @impl PhoenixKit.Module
      def user_dashboard_tabs, do: []

      @impl PhoenixKit.Module
      def children, do: []

      @impl PhoenixKit.Module
      def route_module, do: nil

      @impl PhoenixKit.Module
      def version, do: "0.0.0"

      defoverridable get_config: 0,
                     permission_metadata: 0,
                     admin_tabs: 0,
                     settings_tabs: 0,
                     user_dashboard_tabs: 0,
                     children: 0,
                     route_module: 0,
                     version: 0
    end
  end
end
