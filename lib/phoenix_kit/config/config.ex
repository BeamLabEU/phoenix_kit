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
  - `:admin_path` - Top-level URL segment for the admin area (default: "/admin").
    See `get_admin_path/0` — compile-time, `config.exs` only.
  - `:admin_panel_label` - What the admin area is called in the admin header and
    the account menu. A preset atom (translated in every locale) or a string
    (verbatim). Unset derives it from `:admin_path`. See `admin_panel_label/0`
    and `admin_label_presets/0`.
  - `:user_dashboard_enabled` - Enable/disable the deprecated user dashboard
    (`/dashboard`). **Default: `false`.** See `user_dashboard_enabled?/0`.
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
          path: "orders",
          priority: 100
        },
        %{
          id: :notifications,
          label: "Notifications",
          icon: "hero-bell",
          path: "notifications",
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

  require Logger

  @default_config [
    parent_app_name: nil,
    parent_module: nil,
    repo: nil,
    mailer: nil,
    scheme: "http",
    host: "localhost",
    port: 4000,
    url_prefix: "/phoenix_kit",
    admin_path: "/admin",
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
    integrations_encryption_key: nil,
    integrations_key_store: nil,
    oauth_base_url: nil,
    sync_site_url_to_endpoint: false,
    # Module-specific settings
    users_module: PhoenixKit.Users.Auth.User,
    publishing_settings_module: PhoenixKit.Settings,
    # Dashboard settings
    user_dashboard_enabled: false,
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
  Checks whether outgoing mail will actually land in the local dev mailbox.

  True iff the send path `deliver_email/2` would take resolves to
  `Swoosh.Adapters.Local`. Resolution order (via
  `PhoenixKit.Mailer.resolved_send_path/0`): the operator's default send
  integration, then the delegated host mailer (`config :phoenix_kit, :mailer`,
  adapter read from the parent app's env), then the built-in mailer's own
  config. A raw read of `config :phoenix_kit, PhoenixKit.Mailer` answered for
  a mailer that may not be the one sending — false negative under delegation,
  false positive when the installer-written Local block coexists with a real
  delegated mailer (issue #687).

  This renders on public pages, so a dead database (the integration lookup
  reads Settings) means `false`, never a raise or exit.

  ## Examples

      iex> PhoenixKit.Config.mailer_local?
      true  # when the resolved send path uses Swoosh.Adapters.Local

      iex> PhoenixKit.Config.mailer_local?
      false  # when a send integration or a real adapter (SMTP, SES, ...) sends

  """
  @spec mailer_local? :: boolean()
  def mailer_local? do
    match?({:mailer, _, Swoosh.Adapters.Local}, PhoenixKit.Mailer.resolved_send_path())
  rescue
    _ -> false
  catch
    :exit, _ -> false
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

  # Cache key for the admin segment. Read on every admin link build and on
  # every tab path match, same hot path as the URL prefix above.
  @admin_path_cache_key {__MODULE__, :admin_path}

  # Top-level segments core already declares under the mount prefix. The admin
  # segment may not be any of them: the router would carry two different route
  # trees under one path and whichever is declared first would silently win,
  # which surfaces as "half my admin pages 404" rather than as a config error.
  @admin_path_collisions ~w(users profile dashboard api mcp webhooks assets static
                            files images fonts js css sitemap oauth)

  @doc """
  The top-level URL segment for the admin area — `"/admin"` unless configured.

      config :phoenix_kit, admin_path: "/backoffice"

  This renames the segment *inside* the mount prefix, so the example above
  serves the admin area at `/phoenix_kit/backoffice/...`. It is independent of
  `:url_prefix`, which names the mount itself.

  ## `/admin` stays the canonical name in code

  Nothing in core (or in a module package) is written against the configured
  value. Call sites keep saying `Routes.path("/admin/users")`; the substitution
  happens in exactly two places, and they are inverses:

    * **emitting** a URL — `PhoenixKit.Utils.Routes.apply_admin_segment/1`,
      reached from `Routes.path/2` and `Routes.admin_path/2`, and from the
      router's own route table via `PhoenixKitWeb.Integration`
    * **reading** one back — `PhoenixKit.Utils.Routes.canonical_admin_path/1`,
      used wherever a real request path is matched against a canonical one
      (tab active state, the admin nav, the language switcher)

  So a module package needs no changes to honour a renamed admin area, and a
  grep for `"/admin"` in core stays meaningful.

  ## Compile-time

  Read while the host router is compiled, so it belongs in `config.exs` —
  **never** `runtime.exs`. `phoenix_kit_routes()` folds it into
  `__mix_recompile__?/0`, so changing it re-expands the host router rather than
  leaving it serving the old segment.

  ## Validation

  Exactly one path segment, lowercase `[a-z0-9]` plus `_` and `-`, and not one
  of the segments core already owns. A bad value raises here rather than
  producing a router that compiles and then 404s.
  """
  @spec get_admin_path() :: String.t()
  def get_admin_path do
    case :persistent_term.get(@admin_path_cache_key, :not_cached) do
      :not_cached ->
        value = compute_admin_path()
        :persistent_term.put(@admin_path_cache_key, value)
        value

      cached ->
        cached
    end
  end

  defp compute_admin_path do
    case :admin_path |> get_string("/admin") |> String.trim() do
      "" -> "/admin"
      value -> "/" <> validated_admin_segment(value)
    end
  end

  # Segments the admin area cannot be renamed onto, because core already
  # declares a route tree there.
  #
  # `dashboard` is conditional: it is only taken while the deprecated user
  # dashboard is actually routed. With `user_dashboard_enabled: false` — the
  # default since the dashboard was retired from core's defaults — nothing
  # occupies `/dashboard`, so a host is free to move the admin area onto it.
  # Turning the dashboard back on afterwards puts the segment back in this
  # list, and the next compile raises rather than silently letting whichever
  # tree the router declared first win.
  defp admin_path_collisions do
    if user_dashboard_enabled?() do
      @admin_path_collisions
    else
      @admin_path_collisions -- ["dashboard"]
    end
  end

  defp validated_admin_segment(value) do
    segment = value |> String.trim_leading("/") |> String.trim_trailing("/")

    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, segment) ->
        raise ArgumentError, """
        Invalid `config :phoenix_kit, admin_path: #{inspect(value)}`.

        It must be a single lowercase path segment — letters, digits, `_` and
        `-`, starting with a letter or digit — optionally written with a
        leading slash. For example: "/backoffice", "/console", "/my_account".

        Nested paths ("/a/b") are not supported: the redirect-loop guard in
        `PhoenixKit.Utils.Routes` compares admin URLs one segment at a time.
        """

      segment in admin_path_collisions() ->
        raise ArgumentError, """
        Invalid `config :phoenix_kit, admin_path: #{inspect(value)}`.

        PhoenixKit already declares `/#{segment}` under the mount prefix, so
        the admin area cannot also live there — the two route trees would
        overlap and whichever the router declared first would win.

        Reserved: #{Enum.join(admin_path_collisions(), ", ")}
        """

      true ->
        segment
    end
  end

  @doc """
  Clears the cached admin segment.

  Call this if you change the `admin_path` config at runtime (rare, and it does
  NOT move the routes — those were compiled into the host router).
  """
  @spec clear_admin_path_cache() :: :ok
  def clear_admin_path_cache do
    :persistent_term.erase(@admin_path_cache_key)
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

  # The curated names an admin area can go by, each paired with the URL segment
  # it naturally reads as. Order is the documentation order.
  #
  # A CLOSED set on purpose: every entry is a `gettext/1` msgid in
  # `PhoenixKitWeb.Components.Core.AdminLabel`, translated in every shipped
  # locale, which is the whole point — a host picks a name and every visitor
  # still reads it in their own language. Adding one means adding the msgid
  # there and translating it, not just extending this list.
  @unknown_admin_panel_label_key {__MODULE__, :unknown_admin_panel_label_warned}

  @admin_label_presets [
    admin_panel: "admin",
    dashboard: "dashboard",
    backoffice: "backoffice",
    console: "console",
    control_panel: "control_panel",
    workspace: "workspace",
    portal: "portal",
    my_account: "my_account",
    management: "management",
    studio: "studio"
  ]

  @doc """
  The preset names the admin area can be called by, as `{preset, url_segment}`.

  | Preset | Reads as | Pairs with |
  |---|---|---|
  | `:admin_panel` | Admin Panel *(default)* | `admin_path: "/admin"` |
  | `:dashboard` | Dashboard | `admin_path: "/dashboard"` |
  | `:backoffice` | Backoffice | `admin_path: "/backoffice"` |
  | `:console` | Console | `admin_path: "/console"` |
  | `:control_panel` | Control Panel | `admin_path: "/control_panel"` |
  | `:workspace` | Workspace | `admin_path: "/workspace"` |
  | `:portal` | Portal | `admin_path: "/portal"` |
  | `:my_account` | My Account | `admin_path: "/my_account"` |
  | `:management` | Management | `admin_path: "/management"` |
  | `:studio` | Studio | `admin_path: "/studio"` |

  "Reads as" is the ENGLISH rendering. Each is a `gettext/1` msgid translated
  in every shipped locale — that is the point of the list being closed, and
  what a free-typed string cannot do. Rendered by
  `PhoenixKitWeb.Components.Core.AdminLabel.preset_text/1`.

  `mix phoenix_kit.install` and `mix phoenix_kit.update` write this same list
  into the host's `config/config.exs` as a comment block
  (`PhoenixKit.Install.AdminLabelConfig`), so it is in front of a developer at
  the moment they go to change it.

      iex> PhoenixKit.Config.admin_label_presets() |> Keyword.keys() |> Enum.take(3)
      [:admin_panel, :dashboard, :backoffice]

  """
  @spec admin_label_presets() :: keyword(String.t())
  def admin_label_presets, do: @admin_label_presets

  @doc """
  What the admin area is called — a translated preset, or a host's own string.

  Returns `{:preset, atom}` (rendered through `gettext/1`, so every visitor
  reads it in their own language) or `{:custom, binary}` (shown verbatim to
  everyone). Never `nil`: the fallback is `{:preset, :admin_panel}`.

  ## Resolution order

  1. `config :phoenix_kit, admin_panel_label: :console` — an explicit preset
     from `admin_label_presets/0`.
  2. `config :phoenix_kit, admin_panel_label: "Acme HQ"` — free text. The
     escape hatch for a brand name no preset covers. ⚠️ **Not translated**:
     one string, shown to every visitor whatever their language.
  3. Unset — **derived from `:admin_path`**, so the URL and the wording stay
     aligned by construction rather than by the host remembering to set two
     keys:

         config :phoenix_kit, admin_path: "/backoffice"
         #=> {:preset, :backoffice} — URL /backoffice, header "Backoffice"

     `-` and `_` are equivalent in the segment (`/control-panel` and
     `/control_panel` both derive `:control_panel`).

  A segment that matches no preset — `/x7q`, or any deliberately obscure
  rename — derives `{:preset, :admin_panel}` rather than inventing a label
  from the URL.

  ## Unrecognised values fall back, they do not raise

  Unlike `get_admin_path/0`, a bad value here is cosmetic: a typo must not take
  the admin area down in production. An unknown atom, a blank string or a
  non-string, non-atom value falls through to the derivation in step 3.

  ## Examples

      iex> PhoenixKit.Config.admin_panel_label()
      {:preset, :admin_panel}

      # With `config :phoenix_kit, admin_panel_label: :console`:
      iex> PhoenixKit.Config.admin_panel_label()
      {:preset, :console}

  """
  @spec admin_panel_label() :: {:preset, atom()} | {:custom, String.t()}
  def admin_panel_label do
    case Application.get_env(:phoenix_kit, :admin_panel_label) do
      nil ->
        derived_admin_panel_label()

      preset when is_atom(preset) ->
        if Keyword.has_key?(@admin_label_presets, preset) do
          {:preset, preset}
        else
          warn_unknown_admin_panel_label(preset)
          derived_admin_panel_label()
        end

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> derived_admin_panel_label()
          trimmed -> {:custom, trimmed}
        end

      other ->
        warn_unknown_admin_panel_label(other)
        derived_admin_panel_label()
    end
  end

  # Falling back silently would leave a typo with NO discovery path at all —
  # the header just quietly stays "Admin Panel". Warn, and name the vocabulary
  # while we are at it, since not being able to guess it is the whole problem.
  #
  # ONCE. This is reached from a render path, so warning per call would turn a
  # one-character mistake into a flooded log.
  defp warn_unknown_admin_panel_label(value) do
    if :persistent_term.get(@unknown_admin_panel_label_key, false) == false do
      :persistent_term.put(@unknown_admin_panel_label_key, true)

      Logger.warning("""
      Unrecognised `config :phoenix_kit, admin_panel_label: #{inspect(value)}`.

      Falling back to the name derived from `:admin_path`. Expected one of:

        #{@admin_label_presets |> Keyword.keys() |> Enum.map_join(", ", &inspect/1)}

      ...or a plain string for a name no preset covers (not translated —
      one string, shown to every visitor in every language).
      """)
    end

    :ok
  end

  defp derived_admin_panel_label do
    segment =
      get_admin_path()
      |> String.trim_leading("/")
      |> String.replace("-", "_")

    case Enum.find(@admin_label_presets, fn {_preset, seg} -> seg == segment end) do
      {preset, _segment} -> {:preset, preset}
      nil -> {:preset, :admin_panel}
    end
  end

  @doc """
  Whether the deprecated user dashboard (`/dashboard`) is routed.

  **Defaults to `false`.** The user dashboard is deprecated — its job has moved
  into the unified admin panel at `/admin`, which shows each visitor the
  sections their permissions allow (and greets a permission-less visitor rather
  than bouncing them, see `PhoenixKitWeb.Users.Auth.landing_view?/1`). Core
  therefore stopped routing it by default; nothing in core links to it any more.

  It is **not deleted**. A host that still wants it turns it back on:

      config :phoenix_kit, user_dashboard_enabled: true

  and gets `/dashboard`, `/dashboard/settings` and the confirm-email compat
  redirects back, exactly as before.

  Read at macro-expansion time by the route macros in
  `PhoenixKitWeb.Integration`, so it is compile-time config — `config.exs`,
  never `runtime.exs`. `phoenix_kit_routes/0` folds it into
  `__mix_recompile__?/0`, so flipping it re-expands the host router instead of
  leaving it serving the old route table.

  ## Examples

      iex> PhoenixKit.Config.user_dashboard_enabled?()
      false

      # With `config :phoenix_kit, user_dashboard_enabled: true`:
      iex> PhoenixKit.Config.user_dashboard_enabled?()
      true

  """
  @spec user_dashboard_enabled?() :: boolean()
  def user_dashboard_enabled? do
    get_boolean(:user_dashboard_enabled, false)
  end

  @doc """
  Whether the host has said anything at all about `:user_dashboard_enabled`.

  Distinguishes "took the new default" from "explicitly chose `false`", which
  `user_dashboard_enabled?/0` cannot: both answer `false`. `mix phoenix_kit.update`
  uses it to tell an upgrading host that the default flipped under them — a
  host that already wrote the key made a choice and needs no notice.
  """
  @spec user_dashboard_configured?() :: boolean()
  def user_dashboard_configured? do
    Application.get_env(:phoenix_kit, :user_dashboard_enabled) != nil
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
