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
            description: "A demo module",
            # Optional fine-grained permissions under the base key.
            # Stored/checked as "hello_world.moderate"; only effective
            # while the module is enabled.
            sub_permissions: [
              %{
                key: "moderate",
                label: "Moderate content",
                description: "Approve or reject other users' entries"
              }
            ]
          }
        end

        @impl true
        def admin_tabs do
          [%PhoenixKit.Dashboard.Tab{
            id: :admin_hello_world,
            label: "Hello World",
            icon: "hero-hand-raised",
            path: "hello-world",
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

  - `get_config/0` - Module stats/config map (default: `%{enabled: enabled?()}`).
    The default calls `enabled?()` which may hit the database. External modules
    with expensive config should override this with a cached implementation.
  - `permission_metadata/0` - Permission key, label, icon, description (default: `nil`)
  - `admin_tabs/0` - Admin navigation tabs (default: `[]`)
  - `settings_tabs/0` - Settings subtabs (default: `[]`)
  - `user_dashboard_tabs/0` - User-facing dashboard tabs (default: `[]`)
  - `children/0` - Supervisor child specs (default: `[]`)
  - `route_module/0` - Module providing route macros (default: `nil`)
  - `version/0` - Module version string (default: `"0.0.0"`)
  - `migration_module/0` - Module implementing versioned migrations (default: `nil`).
    When set, `mix phoenix_kit.update` will automatically run this module's migrations
    alongside the core PhoenixKit migrations.
  - `required_integrations/0` - Integration provider keys this module needs (default: `[]`).
    Used by the Integrations settings page to show relevant providers.
  - `integration_providers/0` - Additional provider definitions this module contributes (default: `[]`).
  """

  @typedoc """
  A fine-grained permission a module declares under its base key.

  `:key` is the short action name (e.g. `"view_others"`); it is stored and
  checked as the composed dotted key `"<module_key>.<key>"` (e.g.
  `"calendar.view_others"`). Both parts must match `~r/^[a-z][a-z0-9_]*$/`,
  so a composed key always contains exactly one dot.
  """
  @type sub_permission :: %{
          key: String.t(),
          label: String.t(),
          description: String.t()
        }

  @typedoc """
  Permission metadata for the module.

  `:sub_permissions` (optional) declares fine-grained permissions under the
  module's base key. The base key gates access to the module's admin pages;
  sub-permissions are additive grants the module checks itself (via
  `PhoenixKit.Users.Auth.Scope.can?/2`) for specific in-module capabilities.
  A sub-permission is only effective while its parent module is enabled.
  """
  @type permission_meta :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:icon) => String.t(),
          required(:description) => String.t(),
          optional(:sub_permissions) => [sub_permission()]
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
  @callback migration_module() :: module() | nil
  @callback required_modules() :: [String.t()]
  @callback required_integrations() :: [String.t()]
  @callback integration_providers() :: [map()]

  @doc """
  Returns a list of notification types this module contributes.

  Each type is a map with:
    * `:key` — binary, stable identifier used in user prefs (e.g. `"posts"`)
    * `:label` — binary, user-facing display (e.g. `"Posts"`)
    * `:description` — binary, short explainer shown under the toggle
    * `:actions` — list of dotted action strings (`["post.liked", "post.commented"]`)
    * `:default` — boolean, the toggle's default state for users who haven't
      set a preference

  Types merge with core PhoenixKit types (`account`, `posts`, `comments`) and
  show up automatically in the UserSettings "Notifications" section. The
  filter in `PhoenixKit.Notifications.maybe_create_from_activity/1` resolves
  each action to a type via `:actions` and skips the fan-out when the user
  has muted that type.

  Headless modules (no user-facing actions) can skip this callback — the
  default is `[]`.

  ## Example

      def notification_types do
        [
          %{
            key: "reviews",
            label: "Reviews",
            description: "When someone leaves you a review",
            actions: ["review.submitted", "review.edited"],
            default: true
          }
        ]
      end
  """
  @callback notification_types() :: [map()]

  @doc """
  Declares how this module's resource types deep-link to their pages.

  Lets the activity feed, notifications, and the comments moderation admin turn
  a `(resource_type, resource_uuid)` pair from *this* module into a clickable
  link to the underlying record — with zero host configuration. Returns a map of
  `resource_type => resolver`, where a resolver is either:

    * **a module** implementing `resolve_comment_resources/1` (the same contract
      core's `"user"`/`"file"`/`"post"` handlers use) — for rich resolution with
      a title and optional thumbnail. Return `%{uuid => %{title:, path:}}` with a
      **raw** phoenix_kit path (`Routes.path/1` is applied once at render).

    * **a path-template string** — the no-code shortcut, e.g.
      `"/admin/widgets/:uuid"`. Placeholders: `:uuid` and `:metadata.<key>`
      (pulled from the activity/comment metadata). Treated as an internal
      phoenix_kit route (SPA-navigated, prefix/locale applied). Use the map form
      `%{"path" => "...", "title" => ":metadata.name"}` to set a display title.

  ## Examples

      # No-code: a raw admin route with a uuid segment
      def resource_links, do: %{"widget" => "/admin/widgets/:uuid"}

      # Titled template
      def resource_links,
        do: %{"widget" => %{"path" => "/admin/widgets/:uuid", "title" => ":metadata.name"}}

      # Rich: point at a resolver module (title + thumbnail via a DB lookup)
      def resource_links, do: %{"widget" => MyApp.WidgetLinks}

  Merges with core's built-in handlers and the host's `comment_resource_paths`
  setting via `PhoenixKit.ResourceLinks`. Modules with no linkable resources can
  skip this callback — the default is `%{}`.
  """
  @callback resource_links() :: %{optional(String.t()) => module() | String.t() | map()}

  @doc """
  Returns Tailwind CSS source roots for scanning.

  Each entry is either:

    * an atom — the OTP app name. The compiler resolves it via the parent
      app's `mix.exs` deps (`deps/<app>` for Hex, `path:` value for path deps).
    * a string — a literal path. Absolute paths (starting with `/`) emit as
      `@source "<abs>";` verbatim; relative paths emit as `@source "../../<path>";`
      (relative to `assets/css/_phoenix_kit_sources.css`). Useful when a module
      wants to add a path-dep absolute fallback alongside the OTP-app entry,
      so both Hex and path-dep installs work without parent-app toggles.

  ## Examples

      def css_sources, do: [:phoenix_kit_publishing]

      # Path-dep friendly:
      @source_root Path.expand(Path.join(__DIR__, "../.."))
      def css_sources, do: [:phoenix_kit_publishing, @source_root]

  Headless modules (no templates) can skip this callback — the default is `[]`.
  """
  @callback css_sources() :: [atom() | String.t()]

  @doc """
  Returns JavaScript hook bundles this module needs registered in the host's
  `LiveSocket`.

  A LiveView JS hook must be present in the host's single `LiveSocket` at
  construction time — a nested LiveView cannot register one at runtime. This
  callback lets a module declare a prebuilt bundle (e.g. a standalone Hex
  package's hooks) so the `:phoenix_kit_js_sources` compiler can wire it into
  the host automatically, the same way `css_sources/0` wires Tailwind sources.

  Each entry is a map:

    * `:app` — the OTP app shipping the bundle. Resolved at compile time via
      `:code.priv_dir/1`, so it works for Hex installs and path deps alike (no
      `deps/<app>` path arithmetic).
    * `:file` — path to the prebuilt bundle **inside that app's `priv/`**, e.g.
      `"static/assets/my_hooks.js"`. The file must ship in the app's `priv/`.
    * `:global` — the `window.<Name>` the bundle assigns its hooks to. The
      compiler folds it into `window.PhoenixKitHooks` (which the host already
      spreads into `LiveSocket`), so no per-module `app.js` edit is needed. Must
      be unique across all modules — two bundles sharing a global would clobber
      each other, so the compiler fails loudly on a collision.

  ## Hook names must be globally unique too

  The compiler enforces unique `:global` names, but it cannot see *inside* a
  prebuilt bundle. The final fold is `Object.assign(window.PhoenixKitHooks,
  <bundle globals…>)`, which is last-write-wins on the **hook names** each
  bundle exports. So two modules with distinct globals that happen to export a
  hook of the same name (e.g. both define `Chart`) will silently clobber one
  another — and a bundle hook whose name matches a core PhoenixKit hook (e.g.
  `RowMenu`, `SortableGrid`) overrides the core one. Namespace your hook names
  (e.g. prefix them with the module name) to keep them unique across every
  module and the core set.

  ## Example

      @impl PhoenixKit.Module
      def js_sources do
        [%{app: :phoenix_live_gantt,
           file: "static/assets/phoenix_live_gantt.js",
           global: "PhoenixLiveGanttHooks"}]
      end

  Modules with no JS hooks skip this callback — the default is `[]`.
  """
  @callback js_sources() :: [
              %{
                required(:app) => atom(),
                required(:file) => String.t(),
                required(:global) => String.t()
              }
            ]

  @doc """
  Returns sitemap source modules this module contributes.

  Each entry is a module implementing the
  `PhoenixKit.Modules.Sitemap.Sources.Source` behaviour. The sitemap
  `Generator` merges these with its built-in sources (router discovery,
  static, publishing, posts, shop) so an external module's content
  (e.g. Entities records) appears in the generated sitemap with no
  host-app configuration — the same zero-config pattern as `css_sources/0`
  and route discovery.

  Sources are collected via `PhoenixKit.ModuleRegistry.all_sitemap_sources/0`
  and appended to the base source list, deduplicated by module.

  ## Example

      @impl PhoenixKit.Module
      def sitemap_sources, do: [PhoenixKitEntities.SitemapSource]

  Headless modules (no public content) skip this callback — the default is `[]`.
  """
  @callback sitemap_sources() :: [module()]

  @doc """
  Returns top-level route path segments this module owns for its own
  LiveViews/controllers (e.g. a host app declares `live "/legal", LegalLive`
  and this module IS the "legal" feature).

  Consulted by modules that dispatch requests based on a database-driven
  path segment (e.g. Publishing's `/:language/:group/*path` catch-all, which
  treats any first segment matching a stored group slug as one of its own
  groups) so they don't swallow a route another module owns just because a
  same-named record happens to exist in their own data. Collected via
  `PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0`.

  Segments are compared literally (no leading/trailing slash, e.g. `"legal"`
  not `"/legal"`).

  ## Example

      @impl PhoenixKit.Module
      def reserved_route_prefixes, do: ["legal"]

  Modules that don't own a reserved top-level segment skip this callback —
  the default is `[]`.
  """
  @callback reserved_route_prefixes() :: [String.t()]

  @doc """
  Run any one-shot legacy data migrations this module owns.

  Two transitions every module that touches Integrations may need:

  1. **Local credentials → Integrations** — the module used to store API
     keys / OAuth tokens itself; move them into a `PhoenixKit.Integrations`
     row and point the module's records at that row by uuid.
  2. **Name-string references → uuid references** — the module already
     used Integrations but referenced rows by `provider:name` strings;
     resolve those to uuids and persist the cleaner reference.

  Implementations should:

  - Be idempotent — safe to call on every host-app boot. Use cheap
    short-circuit guards (a "completed_at" setting, "no rows need
    migration" check, etc.) so repeat runs do nothing.
  - Log activity (`PhoenixKit.Activity.log/1`) for every record actually
    migrated, with `mode: "auto"`. Operators can audit the migration
    via the activity feed.
  - Never raise — wrap risky paths in `try/rescue` and return
    `{:error, reason}` for the orchestrator to log. A failed migration
    must not crash the host app.
  - Redact PII in metadata: log uuids and resource refs, never the
    decrypted API key / OAuth tokens / etc.

  Default implementation returns `:ok` (modules that don't have legacy
  data don't need to override this).

  ## Orchestration

  Host apps call `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`
  from `Application.start/2`; that walks every registered module and
  invokes this callback. Per-module errors are caught + logged; the
  boot doesn't fail.
  """
  @callback migrate_legacy() :: :ok | {:ok, map()} | {:error, term()}

  @optional_callbacks [
    get_config: 0,
    permission_metadata: 0,
    admin_tabs: 0,
    settings_tabs: 0,
    user_dashboard_tabs: 0,
    children: 0,
    route_module: 0,
    version: 0,
    migration_module: 0,
    required_modules: 0,
    required_integrations: 0,
    integration_providers: 0,
    notification_types: 0,
    resource_links: 0,
    css_sources: 0,
    js_sources: 0,
    sitemap_sources: 0,
    reserved_route_prefixes: 0,
    migrate_legacy: 0
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

      @impl PhoenixKit.Module
      def migration_module, do: nil

      @impl PhoenixKit.Module
      def required_modules, do: []

      @impl PhoenixKit.Module
      def required_integrations, do: []

      @impl PhoenixKit.Module
      def integration_providers, do: []

      @impl PhoenixKit.Module
      def notification_types, do: []

      @impl PhoenixKit.Module
      def resource_links, do: %{}

      @impl PhoenixKit.Module
      def css_sources, do: []

      @impl PhoenixKit.Module
      def js_sources, do: []

      @impl PhoenixKit.Module
      def sitemap_sources, do: []

      @impl PhoenixKit.Module
      def reserved_route_prefixes, do: []

      @impl PhoenixKit.Module
      def migrate_legacy, do: :ok

      defoverridable get_config: 0,
                     permission_metadata: 0,
                     admin_tabs: 0,
                     settings_tabs: 0,
                     user_dashboard_tabs: 0,
                     children: 0,
                     route_module: 0,
                     version: 0,
                     migration_module: 0,
                     required_modules: 0,
                     required_integrations: 0,
                     integration_providers: 0,
                     notification_types: 0,
                     resource_links: 0,
                     css_sources: 0,
                     js_sources: 0,
                     sitemap_sources: 0,
                     reserved_route_prefixes: 0,
                     migrate_legacy: 0
    end
  end
end
