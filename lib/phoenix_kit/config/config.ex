defmodule PhoenixKit.Config do
  @moduledoc """
  Configuration management system for PhoenixKit.

  This module provides a centralized way to manage PhoenixKit configuration
  with type-safe getter functions for different data types.

  ## Usage

      # Get all configuration
      config = PhoenixKit.Config.get_all()

      # Get specific values
      repo = PhoenixKit.Config.get(:repo)
      mailer = PhoenixKit.Config.get(:mailer, PhoenixKit.Mailer)

      # Type-safe getters
      options = PhoenixKit.Config.get_list(:options, [])
      enabled = PhoenixKit.Config.get_boolean(:enabled, false)
      host = PhoenixKit.Config.get_string(:host, "localhost")

  ## Configuration Keys

  - `:repo` - Ecto repository module (required)
  - `:mailer` - Mailer module for sending emails
  - `:host` - Application hostname
  - `:port` - Application port
  - `:layout_module` - Custom layout configuration
  - `:from_email` - Default sender email address for notifications
  - `:from_name` - Default sender name for notifications (default: "PhoenixKit")
  - `:users_module` - User schema module (default: PhoenixKit.Users.Auth.User)
  - `:project_title` - Project/application name displayed in dashboard header (default: "PhoenixKit")
  - `:project_title_suffix` - Suffix appended to title (default: "Dashboard", set to "" to remove)
  - `:project_logo` - URL or path to logo image for dashboard header (optional, use SVG with currentColor for theme support)
  - `:project_icon` - Heroicon name when no logo image (default: "hero-home")
  - `:project_logo_height` - Logo height CSS class (default: "h-8")
  - `:project_logo_class` - Additional CSS classes for logo image (optional)
  - `:project_home_url` - URL the logo links to (default: "/", use "~/" prefix for URL prefix)
  - `:show_title_with_logo` - Show title text alongside logo (default: true)
  - `:dashboard_themes` - Themes available in dashboard theme switcher (default: `:all`)
  - `:dashboard_subtab_style` - Default styling for subtabs (indent, icon_size, text_size, animation)
  - `:user_dashboard_enabled` - Enable/disable user dashboard (default: true)
  - `:user_dashboard_tabs` - List of custom tabs for the user dashboard sidebar
  - `:user_dashboard_tab_groups` - List of tab groups for organizing dashboard tabs
  - `:dashboard_presence` - Presence tracking settings for dashboard tabs
  - `:admin_dashboard_categories` - List of custom admin dashboard categories with subsections

  ## User Dashboard Tabs

  Configure custom tabs in the user dashboard sidebar:

      config :phoenix_kit, :user_dashboard_tabs, [
        %{
          id: :orders,
          label: "My Orders",
          icon: "hero-shopping-bag",
          path: "/dashboard/orders",
          priority: 100
        },
        %{
          id: :notifications,
          label: "Notifications",
          icon: "hero-bell",
          path: "/dashboard/notifications",
          priority: 200,
          badge: %{type: :count, value: 0, color: :error}
        }
      ]

  Tab options:
  - `:id` - Unique atom identifier (required)
  - `:label` - Display text (required)
  - `:icon` - Heroicon name, e.g., "hero-home" (optional)
  - `:path` - URL path (required)
  - `:priority` - Sort order, lower = higher (default: 500)
  - `:group` - Group ID for organizing (optional)
  - `:match` - Path matching: :exact, :prefix (default: :prefix)
  - `:visible` - Boolean or function(scope) -> boolean (default: true)
  - `:badge` - Badge config map (optional)
  - `:tooltip` - Hover text (optional)
  - `:attention` - Animation: :pulse, :bounce, :shake, :glow (optional)

  ## User Dashboard Tab Groups

  Organize tabs into labeled sections:

      config :phoenix_kit, :user_dashboard_tab_groups, [
        %{id: :main, label: nil, priority: 100},
        %{id: :farm, label: "Farm Management", priority: 200, icon: "hero-cube"},
        %{id: :account, label: "Account", priority: 900}
      ]

  ## Dashboard Presence

  Configure presence tracking for dashboard tabs:

      config :phoenix_kit, :dashboard_presence,
        enabled: true,
        show_user_count: true,
        show_user_names: false,
        track_anonymous: false

  ## Admin Dashboard Categories

  For detailed information about configuring custom admin dashboard categories,
  see `PhoenixKit.Config.AdminDashboardCategories`.

  ## Type-Safe Functions

  - `get_list/2` - Gets configuration values with list type validation
  - `get_boolean/2` - Gets configuration values with boolean type validation
  - `get_string/2` - Gets configuration values with string type validation

  These functions provide automatic type validation and fallback to defaults
  when the configuration value is missing or has the wrong type.
  """

  @default_config [
    parent_app_name: nil,
    parent_module: nil,
    repo: nil,
    mailer: nil,
    scheme: "http",
    host: "localhost",
    port: 4000,
    url_prefix: "/phoenix_kit",
    # Branding settings
    project_title: "PhoenixKit",
    project_title_suffix: "Dashboard",
    project_logo: nil,
    project_icon: "hero-home",
    project_logo_height: "h-8",
    project_logo_class: nil,
    project_home_url: "/",
    show_title_with_logo: true,
    # Dashboard theme settings (:all for all themes, or list of theme names)
    dashboard_themes: :all,
    layouts_module: nil,
    phoenix_version_strategy: nil,
    from_email: nil,
    from_name: "PhoenixKit",
    magic_link_for_login_expiry_minutes: 15,
    magic_link_for_registration_expiry_minutes: 30,
    # Security and authentication settings
    password_requirements: [],
    session_fingerprint_enabled: true,
    session_fingerprint_strict: false,
    secret_key_base: nil,
    oauth_base_url: nil,
    # Module-specific settings
    users_module: PhoenixKit.Users.Auth.User,
    publishing_settings_module: PhoenixKit.Settings,
    blogging_settings_module: PhoenixKit.Settings,
    # Dashboard settings
    user_dashboard_enabled: true,
    # User dashboard tabs - list of tab configs for the user dashboard sidebar
    user_dashboard_tabs: [],
    # User dashboard tab groups - list of group configs for organizing tabs
    user_dashboard_tab_groups: [],
    # Dashboard presence settings
    dashboard_presence: [
      enabled: true,
      show_user_count: true,
      show_user_names: false,
      track_anonymous: false
    ],
    # Admin dashboard categories
    admin_dashboard_categories: [],
    # Multiple context selectors (takes precedence over single selector)
    dashboard_context_selectors: nil,
    # Subtab styling defaults
    dashboard_subtab_style: [
      indent: "pl-4",
      icon_size: "w-4 h-4",
      text_size: "text-sm",
      animation: :none
    ]
  ]

  @doc """
  Gets all PhoenixKit configuration.
  """
  @spec get_all() :: Keyword.t()
  def get_all do
    app_config = Application.get_all_env(:phoenix_kit)
    Keyword.merge(@default_config, app_config)
  end

  @doc """
  Gets a specific configuration value.

  Uses direct Application.get_env lookup for performance (avoids iterating
  all config keys on every call).
  """
  @spec get(atom()) :: {:ok, any()} | :not_found
  def get(key) when is_atom(key) do
    # Use direct lookup with default config fallback for performance
    # This avoids calling get_all() which iterates the entire config
    default = Keyword.get(@default_config, key)

    case Application.get_env(:phoenix_kit, key, default) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @doc """
  Gets a specific configuration value with a default.

  ## Examples

      iex> PhoenixKit.Config.get(:mailer, PhoenixKit.Mailer)
      MyApp.Mailer

      iex> PhoenixKit.Config.get(:nonexistent, :default)
      :default
  """
  @spec get(atom(), any()) :: any()
  def get(key, default) when is_atom(key) do
    case get(key) do
      {:ok, value} -> value
      :not_found -> default
    end
  end

  @doc """
  Sets a configuration value.

  ## Examples

      iex> PhoenixKit.Config.set(:repo, MyApp.Repo)
      :ok

      iex> PhoenixKit.Config.set(:custom_option, "custom_value")
      :ok

  """
  @spec set(atom(), any()) :: :ok
  def set(key, value) when is_atom(key) do
    Application.put_env(:phoenix_kit, key, value)
    :ok
  end

  @doc """
  Gets a configuration value as a list with type validation.

  ## Examples

      iex> PhoenixKit.Config.get_list(:options, [])
      []

      iex> PhoenixKit.Config.get_list(:nonexistent, [:default])
      [:default]

  """
  @spec get_list(atom(), list()) :: list()
  def get_list(key, default \\ [])
      when is_atom(key) and is_list(default) do
    case get(key) do
      {:ok, value} when is_list(value) -> value
      {:ok, _} -> default
      :not_found -> default
    end
  end

  @doc """
  Gets a configuration value as a boolean with type validation.

  ## Examples

      iex> PhoenixKit.Config.get_boolean(:enabled, false)
      true

      iex> PhoenixKit.Config.get_boolean(:nonexistent, true)
      true

  """
  @spec get_boolean(atom(), boolean()) :: boolean()
  def get_boolean(key, default \\ false)
      when is_atom(key) and is_boolean(default) do
    case get(key) do
      {:ok, value} when is_boolean(value) -> value
      {:ok, _} -> default
      :not_found -> default
    end
  end

  @doc """
  Gets a configuration value as a string with type validation.

  ## Examples

      iex> PhoenixKit.Config.get_string(:host, "localhost")
      "example.com"

      iex> PhoenixKit.Config.get_string(:nonexistent, "default")
      "default"

  """
  @spec get_string(atom(), String.t()) :: String.t()
  def get_string(key, default \\ "")
      when is_atom(key) and is_binary(default) do
    case get(key) do
      {:ok, value} when is_binary(value) -> value
      {:ok, _} -> default
      :not_found -> default
    end
  end

  @doc """
  Gets the configured mailer module.

  Returns the configured mailer or falls back to PhoenixKit.Mailer.

  ## Examples

      iex> PhoenixKit.Config.get_mailer()
      MyApp.Mailer

  """
  @spec get_mailer() :: module()
  def get_mailer do
    case get(:mailer) do
      {:ok, mailer} when is_atom(mailer) -> mailer
      _ -> PhoenixKit.Mailer
    end
  end

  @doc """
  Checks if the configured mailer adapter is the local adapter.

  Returns true if the mailer is configured to use Swoosh.Adapters.Local,
  which is typically used for development and testing environments where
  emails are stored locally rather than being sent to actual recipients.

  ## Examples

      iex> PhoenixKit.Config.mailer_local?
      true  # when using Swoosh.Adapters.Local

      iex> PhoenixKit.Config.mailer_local?
      false  # when using a real mailer like SMTP or SendGrid

  """
  @spec mailer_local? :: boolean()
  def mailer_local? do
    case get(PhoenixKit.Mailer, nil)[:adapter] do
      Swoosh.Adapters.Local -> true
      _ -> false
    end
  end

  @doc """
  Gets configured host with an optional port or default value.
  """
  @spec get_base_url() :: String.t()
  def get_base_url do
    host = get_string(:host, "localhost")
    scheme = get_string(:scheme, "http")

    port =
      case get(:port) do
        {:ok, port} when port not in [80, 443] -> ":#{port}"
        _ -> ":4000"
      end

    "#{scheme}://#{host}#{port}"
  end

  @doc """
  Gets the base URL dynamically from the parent Phoenix Endpoint if available,
  otherwise falls back to the static configuration.

  This function automatically detects the correct URL from the running Phoenix
  application, which is especially useful in development mode where the port
  might be different from the default configuration.

  ## Examples

      iex> PhoenixKit.Config.get_dynamic_base_url()
      "http://localhost:4001"  # from Phoenix Endpoint

      iex> PhoenixKit.Config.get_dynamic_base_url()
      "http://localhost:4000"  # fallback to static config
  """
  @spec get_dynamic_base_url() :: String.t()
  def get_dynamic_base_url do
    case get_parent_endpoint_url() do
      {:ok, url} -> url
      :error -> get_base_url()
    end
  end

  @doc """
  Gets the parent Phoenix Endpoint URL if the endpoint is available and running.

  Returns `{:ok, url}` if successful, `:error` if the endpoint cannot be found
  or accessed.
  """
  @spec get_parent_endpoint_url() :: {:ok, String.t()} | :error
  def get_parent_endpoint_url do
    with {:ok, endpoint} <- get_parent_endpoint(),
         true <- function_exported?(endpoint, :url, 0) do
      try do
        url = endpoint.url()
        {:ok, url}
      rescue
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  @doc """
  Gets the parent application's Phoenix Endpoint module.

  This function attempts to detect the main application's endpoint that is using
  PhoenixKit as a dependency.

  Returns `{:ok, endpoint_module}` if found, `:error` otherwise.
  """
  @spec get_parent_endpoint() :: {:ok, module()} | :error
  def get_parent_endpoint do
    case get(:parent_module) do
      {:ok, parent_module} ->
        potential_endpoints = [
          Module.concat([String.to_atom("#{parent_module}Web"), Endpoint]),
          Module.concat([parent_module, Endpoint])
        ]

        Enum.reduce_while(potential_endpoints, :error, fn endpoint, _acc ->
          if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :url, 0) do
            {:halt, {:ok, endpoint}}
          else
            {:cont, :error}
          end
        end)

      _ ->
        :error
    end
  end

  # Cache key for URL prefix (called very frequently during tab matching)
  @url_prefix_cache_key {__MODULE__, :url_prefix}

  @doc """
  Gets configured prefix for urls or default value.

  This value is cached using :persistent_term for performance since it's
  called on every tab path match during dashboard renders.
  """
  @spec get_url_prefix() :: String.t()
  def get_url_prefix do
    case :persistent_term.get(@url_prefix_cache_key, :not_cached) do
      :not_cached ->
        value = compute_url_prefix()
        :persistent_term.put(@url_prefix_cache_key, value)
        value

      cached ->
        cached
    end
  end

  defp compute_url_prefix do
    case get_string(:url_prefix, "/phoenix_kit") do
      "" -> "/"
      value -> value
    end
  end

  @doc """
  Clears the cached URL prefix.

  Call this if you change the url_prefix config at runtime (rare).
  """
  @spec clear_url_prefix_cache() :: :ok
  def clear_url_prefix_cache do
    :persistent_term.erase(@url_prefix_cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Gets the configured users module.
  """
  @spec get_users_module() :: module()
  def get_users_module do
    case get(:users_module) do
      {:ok, users_module} when is_atom(users_module) -> users_module
      _ -> PhoenixKit.Users.Auth.User
    end
  end

  @doc """
  Gets the configured repository module.
  """
  @spec get_repo() :: module() | nil
  def get_repo do
    case get(:repo) do
      {:ok, repo} when is_atom(repo) -> repo
      _ -> nil
    end
  end

  @doc """
  Gets the configured repository module, raising an error if not found.

  ## Examples

      iex> PhoenixKit.Config.get_repo!()
      MyApp.Repo

      iex> PhoenixKit.Config.get_repo!()
      ** (ArgumentError) PhoenixKit repository not configured. Please set config :phoenix_kit, repo: YourApp.Repo

  """
  @spec get_repo!() :: module()
  def get_repo! do
    case get(:repo) do
      {:ok, repo} when is_atom(repo) ->
        repo

      _ ->
        raise ArgumentError, """
        PhoenixKit repository not configured. Please set:

            config :phoenix_kit, repo: YourApp.Repo

        in your application configuration.
        """
    end
  end

  @doc """
  Gets the configured PubSub server for broadcasting messages.

  Returns the internal PhoenixKit PubSub server or configured custom server.

  ## Examples

      iex> PhoenixKit.Config.pubsub_server()
      :phoenix_kit_internal_pubsub

  """
  @spec pubsub_server() :: atom() | nil
  def pubsub_server do
    case get(:pubsub_server) do
      {:ok, server} when is_atom(server) -> server
      _ -> :phoenix_kit_internal_pubsub
    end
  end

  @doc """
  Gets the user dashboard enabled flag.

  Returns true if the user dashboard is enabled, false otherwise.
  This can be used to conditionally show/hide dashboard routes and navigation.

  ## Examples

      iex> PhoenixKit.Config.user_dashboard_enabled?()
      true

      iex> PhoenixKit.Config.user_dashboard_enabled?()
      false

  """
  @spec user_dashboard_enabled?() :: boolean()
  def user_dashboard_enabled? do
    get_boolean(:user_dashboard_enabled, true)
  end

  @doc """
  Returns the default locale for the application.

  Parent apps can override via config:

      config :phoenix_kit,
        default_locale: "es-ES"

  Defaults to "en-US" if not configured.

  ## Examples

      iex> PhoenixKit.Config.default_locale()
      "en-US"

      # With custom config:
      iex> PhoenixKit.Config.default_locale()
      "es-ES"

  """
  @spec default_locale() :: String.t()
  def default_locale do
    get_string(:default_locale, "en-US")
  end

  @doc """
  Gets configuration from the parent application.

  This is useful for accessing parent app mailer, endpoint, or other configurations
  that PhoenixKit needs to integrate with.
  """
  @spec get_parent_app_config(atom(), any()) :: any()
  def get_parent_app_config(key, default \\ nil) do
    case get_parent_app() do
      nil -> default
      app -> Application.get_env(app, key, default)
    end
  end

  @doc """
  Gets the parent application name that is using PhoenixKit.

  This function attempts to detect the main application that has included
  PhoenixKit as a dependency.
  """
  @spec get_parent_app() :: atom() | nil
  def get_parent_app do
    case get(:parent_app_name) do
      {:ok, app_name} ->
        app_name

      _ ->
        get_parent_app_fallback()
    end
  end

  @doc """
  Validates that required configuration is present.

  Raises an exception if any required keys are missing.

  ## Examples

      PhoenixKit.Config.validate_required!([:repo, :secret_key_base])
  """
  def validate_required!(required_keys) do
    config = get_all()

    missing_keys =
      required_keys
      |> Enum.reject(&Keyword.has_key?(config, &1))

    if not Enum.empty?(missing_keys) do
      raise """
      Missing required PhoenixKit configuration keys: #{inspect(missing_keys)}

      Current configuration: #{inspect(Keyword.keys(config))}

      Please add the missing keys to your configuration:

          config :phoenix_kit,
            #{Enum.map_join(missing_keys, ",\n  ", &"#{&1}: YourValue")}
      """
    end

    :ok
  end

  # Fallback method to determine the parent application when explicit configuration is not available.
  #
  # This function implements a two-stage detection strategy:
  #
  # 1. **Primary Strategy**: Extract the application name from the configured repository module.
  #    For example, if `:repo` is configured as `MyApp.Repo`, this will return `:my_app`.
  #
  # 2. **Fallback Strategy**: Search through loaded applications to find the most likely
  #    parent application by filtering out system applications and dependencies.
  #
  # ## Detection Logic
  #
  # ### Repository-based Detection
  # - Converts repository module names like `MyApp.Repo` to application atoms like `:my_app`
  # - Uses Module.split() to break down the module name
  # - Extracts the first segment and converts it to underscore format
  #
  # ### Application Search
  # - Filters out system applications (`:kernel`, `:stdlib`, `:elixir`)
  # - Excludes PhoenixKit itself (`:phoenix_kit`)
  # - Excludes standard library applications (those starting with "ex_")
  # - Returns the first remaining application, which is typically the parent app
  #
  # ## Examples
  #
  #     # When repo is configured as MyApp.Repo
  #     # get_parent_app_fallback() -> :my_app
  #
  #     # When no repo is configured, searches loaded applications
  #     # get_parent_app_fallback() -> :my_parent_app  # First non-system application found
  #
  #     # Returns nil if no suitable application is found
  #     # get_parent_app_fallback() -> nil
  #
  # ## Return Values
  #
  # - `atom()` - The detected parent application name
  # - `nil` - No suitable parent application could be determined
  #
  # ## ⚠️ Reliability Warning
  #
  # **This function is not reliable and should not be depended upon for critical functionality.**
  #
  # The detection logic makes several assumptions that may not hold true in all environments:
  #
  # - Repository modules may not follow the `MyApp.Repo` convention
  # - Application search may return incorrect results in complex dependency trees
  # - Order of loaded applications is not guaranteed to be predictable
  # - May return dependency applications instead of the actual parent application
  #
  # **For reliable behavior, always configure `:parent_app_name` explicitly** in your application
  # configuration instead of relying on this fallback detection.
  #
  # ## Notes
  #
  # This function is used as a fallback when explicit `:parent_app_name` configuration
  # is not provided. It enables PhoenixKit to automatically integrate with parent
  # applications without requiring additional configuration in most cases.
  defp get_parent_app_fallback do
    # Get the application of the configured repo to determine parent app
    case get(:repo) do
      {:ok, repo_module} when is_atom(repo_module) ->
        # Extract app name from repo module (e.g. MyApp.Repo -> :my_app)
        repo_module
        |> Module.split()
        |> hd()
        |> Macro.underscore()
        |> String.to_atom()

      _ ->
        # Fallback: try to find the main application from the loaded applications
        Application.loaded_applications()
        |> Enum.find(fn {app, _, _} ->
          app != :phoenix_kit and
            app != :kernel and
            app != :stdlib and
            app != :elixir and
            not String.starts_with?(to_string(app), "ex_")
        end)
        |> case do
          {app, _, _} -> app
          nil -> nil
        end
    end
  end
end
