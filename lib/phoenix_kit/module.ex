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
  - `required_modules/0` - Keys of the modules this one needs enabled (default: `[]`)
  - `required_integrations/0` - Integration provider keys this module needs (default: `[]`).
    Used by the Integrations settings page to show relevant providers.
  - `integration_providers/0` - Additional provider definitions this module contributes (default: `[]`).
    A provider can bring its own connection check: `PhoenixKit.Integrations.Validator`.
  - `notification_types/0` - Notification types this module contributes (default: `[]`)
  - `notification_channels/0` - Modules implementing `PhoenixKit.Notifications.Channel`
    this module contributes (default: `[]`)
  - `before_user_delete/1` - Hook called before a user row is deleted. No default:
    it is called only on a module that defines it.
  - `resource_links/0` - How this module's resource types deep-link to their pages
    (default: `%{}`). See `PhoenixKit.ResourceLinks`.
  - `css_sources/0` - Tailwind CSS source roots to scan (default: `[]`)
  - `js_sources/0` - JavaScript hook bundles for the host's `LiveSocket` (default: `[]`)
  - `sitemap_sources/0` - Sitemap source modules this module contributes (default: `[]`)
  - `oban_queues/0` - Oban queues this module's jobs run in (default: `[]`)
  - `reserved_route_prefixes/0` - Top-level route segments this module owns (default: `[]`)
  - `migrate_legacy/0` - One-shot legacy data migrations this module owns (default: `:ok`)
  - `email_settings_sections/0` - Sections this module contributes to the core Emails
    Transactional settings page (default: `[]`).
  - `email_templates/0` - Emails this module sends, for the admin email preview
    (default: `[]`).
  - `oban_crons/0` - Scheduled Oban workers as `{cron, worker}` pairs, written into the
    host's crontab by `mix phoenix_kit.install` / `mix phoenix_kit.update` (default: `[]`).
  - `media_reorganizer/0` - Module implementing
    `PhoenixKit.Modules.Storage.Reorganizer.Source` for this module's own
    records (default: `nil`).
  - `job_kinds/0` - Kinds of job run this module contributes (modules
    implementing `PhoenixKit.Jobs.Kind`), for the admin Jobs page
    (default: `[]`).
  - `api_tools/0` - `PhoenixKit.API.Tool` structs this module offers through the
    public and admin machine API (default: `[]`).
  - `api_problems/0` - Error codes this module's API tools answer with beyond core's own
    (default: `%{}`).
  - `header_widgets/0` - Sticky LiveViews this module puts into the admin header, before
    the notifications bell. No default: it is called only on a module that defines it.
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

  `:gettext_backend` / `:gettext_domain` (optional) let the module's
  permission label render translated in the admin permissions matrix, the
  same way `PhoenixKit.Dashboard.Tab` translates sidebar labels: the label
  string is used as the msgid against the given backend (domain defaults to
  `"default"`). Sub-permission labels inherit the module's backend. Without
  a backend the label falls back to the library's own `PhoenixKitWeb.Gettext`
  lookup, which resolves for core-shipped modules and is a no-op msgid
  fallback for everyone else.
  """
  @type permission_meta :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:icon) => String.t(),
          required(:description) => String.t(),
          optional(:sub_permissions) => [sub_permission()],
          optional(:gettext_backend) => module(),
          optional(:gettext_domain) => String.t()
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

  @doc """
  Lifecycle hook: called for every discovered module BEFORE a user row is
  deleted (while the user's related rows — memberships, assignments —
  still exist). Modules use it for remediation the DB cascades can't do:
  succession, audit trails, orphan warnings. Best-effort — a raising
  hook is logged and never aborts the deletion.
  """
  @callback before_user_delete(user_uuid :: String.t()) :: any()
  @callback version() :: String.t()
  @callback migration_module() :: module() | nil
  @callback required_modules() :: [String.t()]
  @callback required_integrations() :: [String.t()]
  @callback integration_providers() :: [map()]

  @doc """
  Returns a list of notification types this module contributes.

  Each type is a map with:
    * `:key` — binary, stable identifier used in user prefs (e.g. `"posts"`).
      Must not contain a `.` (the sub-type separator).
    * `:label` — binary, user-facing display (e.g. `"Posts"`)
    * `:description` — binary, short explainer shown under the toggle
    * `:actions` — list of dotted action strings (`["post.liked", "post.commented"]`)
    * `:default` — boolean, the toggle's default state for users who haven't
      set a preference
    * `:sub_types` — OPTIONAL list of finer-grained toggles under this type, each
      the same shape (`:key` bare + `.`-free, `:label`, `:description`, `:actions`,
      `:default`). Sub keys are composed to `"<type>.<sub>"` at registration.

  When a type declares sub-types the base becomes a **master switch** (resolution
  time only): base off ⇒ every sub muted; base on ⇒ each sub follows its own
  toggle. This is the OPPOSITE of the permission sub-key cascade — nothing is
  stored-normalized, so a user's per-sub choices survive toggling the master.
  When a type is fully split, leave its own `:actions` empty so every action is
  owned by exactly one sub. Each action should be claimed by exactly one type or
  sub-type; a duplicate claim is resolved first-declared-wins with a warning.
  **Note:** a NEW sub with `default: false` actively mutes that action for existing
  users under an already-on master — pick defaults deliberately.

  Types merge with core PhoenixKit types (`account`, `posts`, `comments`,
  `security`) and show up automatically on the Notification Settings page. The
  filter in `PhoenixKit.Notifications.maybe_create_from_activity/1` resolves each
  action to its most-specific type/sub-type via `PhoenixKit.Notifications.Types`
  and skips the fan-out when the user has muted it. Labels/descriptions are
  runtime data — `mix gettext.extract` won't see them — so register each in
  your module's backend with `gettext_noop/1` and name that backend as
  `gettext_backend:` on the type: the settings pages show them through it in
  the reader's locale, the sub-types included
  (`PhoenixKit.Notifications.Types.translate/2`).

  Headless modules (no user-facing actions) can skip this callback — the
  default is `[]`.

  ## Example

      def notification_types do
        [
          %{
            key: "reviews",
            label: gettext_noop("Reviews"),
            description: gettext_noop("Reviews people leave you"),
            gettext_backend: MyModule.Gettext,
            actions: [],
            default: true,
            sub_types: [
              %{key: "new", label: "New reviews", actions: ["review.submitted"], default: true},
              %{key: "edited", label: "Edited reviews", actions: ["review.edited"], default: false}
            ]
          }
        ]
      end
  """
  @callback notification_types() :: [map()]

  @doc """
  Declares extra notification delivery channels this module contributes.

  Returns a list of modules implementing the `PhoenixKit.Notifications.Channel`
  behaviour. They are merged with the core channels by
  `PhoenixKit.Notifications.Channels.list/0` (core first, module extras after,
  duplicate keys rejected), exactly like `notification_types/0` merges types.

  A channel is a delivery destination for a user's notifications (Telegram,
  email, …); the default is `[]`.

  ## Example

      def notification_channels, do: [MyApp.Notifications.Channels.Slack]
  """
  @callback notification_channels() :: [module()]

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

  ## Bundles only the admin area uses

  Every public entry is part of `phoenix_kit_modules.js`, which every page
  loads. A bundle whose hooks only admin pages mount can stay out of it:

    * `:scope` — `:public` (the default) or `:admin`.
    * `:hooks` — required with `scope: :admin`: the name of every hook the
      bundle exports, as strings.

  The bundle then rides in the admin bundle (`phoenix_kit_admin.js`), which a
  page fetches the first time one of those hooks mounts. The compiler cannot see
  inside a prebuilt file, and a host's `LiveSocket` needs every hook *name*
  when it is built, so the page gets a small stub under each name you list; it
  loads the admin bundle, takes your hook's callbacks onto the LiveView's own
  hook instance, and calls `mounted`. A hook you export but do not list can
  never be mounted. The bundle must still export through its `:global`
  (`window.<Global> = %{HookName: {...}}`), as for a public one.

  What a stubbed hook can rely on: it mounts once the bundle has arrived, so
  `updated`/`beforeUpdate`/`disconnected`/`reconnected` calls that reach it
  before that are dropped and `mounted` reads the DOM as it is then; a
  `push_event` to its `handleEvent` that the server sends in that window is not
  replayed. Keep hooks that must see the very first event out of `scope:
  :admin`. An entry without `:scope` behaves exactly as before, and a core that
  predates `:scope` ignores the extra keys and loads the bundle with the rest.

  ## Example

      @impl PhoenixKit.Module
      def js_sources do
        [%{app: :phoenix_live_gantt,
           file: "static/assets/phoenix_live_gantt.js",
           global: "PhoenixLiveGanttHooks"},
         %{app: :my_module,
           file: "static/assets/my_module_admin.js",
           global: "MyModuleAdminHooks",
           scope: :admin,
           hooks: ["MyModuleGrid", "MyModuleEditor"]}]
      end

  Modules with no JS hooks skip this callback — the default is `[]`.
  """
  @callback js_sources() :: [
              %{
                required(:app) => atom(),
                required(:file) => String.t(),
                required(:global) => String.t(),
                optional(:scope) => :public | :admin,
                optional(:hooks) => [String.t()]
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
  Returns the Oban queues this module's jobs run in.

  A keyword list of `name: limit` or `name: [limit: n, kind: :interactive |
  :batch]`. `mix phoenix_kit.install` and `mix phoenix_kit.update` write the
  queues a host's Oban config is missing — never changing a limit the host
  already set — and `mix phoenix_kit.doctor` and a boot-time log line report
  any that are still absent. Without a queue, Oban never runs the jobs
  inserted into it. Details: `PhoenixKit.ObanQueues`.

  Split by kind of work, not one queue per module: interactive work someone is
  waiting for deserves its own small queue, so a long batch cannot hold it up.
  The limit is per node.

  ## Example

      @impl PhoenixKit.Module
      def oban_queues, do: [image_generation: [limit: 3, kind: :interactive], image_import: 2]

  Modules whose workers use an existing core queue (`default`,
  `file_processing`, …) skip this callback — the default is `[]`.
  """
  @callback oban_queues() :: keyword(pos_integer() | keyword())

  @doc """
  Returns the Oban cron jobs this module needs, as `{cron, worker}` pairs.

  `mix phoenix_kit.install` and `mix phoenix_kit.update` write the entries a host's Oban
  crontab is missing, the way they do for core's own workers. Details:
  `PhoenixKit.ObanCrons`.

    * `cron` - a five-field cron expression (`"0 3 * * *"`) or a nickname such as
      `"@hourly"`.
    * `worker` - an `Oban.Worker` module of this package.

  **One entry per worker.** The installer decides whether an entry is already there by the
  worker's name, so a worker has one schedule and no `args`.

  The entry goes into the host's config whether or not the module is enabled; the worker
  itself should do nothing while its module is off. The worker's queue must exist: use a
  core queue (`default`, ...) or declare it in `c:oban_queues/0`, otherwise
  `mix phoenix_kit.doctor` warns. A schedule the host wrote is never changed, and an entry
  the host commented out of its crontab is left out.

  ## Example

      @impl PhoenixKit.Module
      def oban_crons, do: [{"0 3 * * *", MyModule.Workers.NightlyRebuild}]

  Modules with no scheduled jobs skip this callback — the default is `[]`.
  """
  @callback oban_crons() :: [{String.t(), module()}]

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
  - Log activity (`PhoenixKit.Activity.log/3`) for every record actually
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

  `PhoenixKit.boot/1` (piped from the host's `Application.start/2`) calls
  `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`, which walks
  every registered module and invokes this callback. Per-module errors
  are caught + logged; the boot doesn't fail. It does not run with
  `update_mode` on (`mix phoenix_kit.update` / `mix phoenix_kit.doctor`),
  where `PhoenixKit.Settings` reads answer nil — so a guard read through
  them must not be the only thing keeping a one-shot step from repeating.
  """
  @callback migrate_legacy() :: :ok | {:ok, map()} | {:error, term()}

  @typedoc """
  A module-contributed section on the core Emails Transactional settings page
  (`/admin/settings/email-sending`).

    * `:id` — unique atom, used as the `live_component` DOM id.
    * `:title` — section heading rendered above the component.
    * `:permission` — module permission key gating visibility, checked the
      same way admin tab permissions are (via
      `PhoenixKit.Users.Auth.Scope.has_module_access?/2`); `nil` renders the
      section unconditionally to any admin who can reach the page.
    * `:component` — a `Phoenix.LiveComponent` module. The core page mounts
      it as `<.live_component module={component} id={id} />` — the section
      owns its own `mount/update/handle_event`, so the core page needs no
      knowledge of what's inside.
    * `:link` (optional) — a button beside "Preview emails" on the page's
      Branding tab, shown to whoever may see the section. `%{label: label}`
      opens the section's own tab (`?tab=module_<id>`); `%{label: label,
      path: path}` leads to `path`, a canonical `/admin/...`-style path that
      the core prefixes (`PhoenixKit.Utils.Routes.path/1`). The button is
      not rendered when the label is not a string, or the path is not a
      string starting with a single `/` (a relative path, `//host/...` or
      `/\\host/...`) — it does not fall back to the tab. Its icon is fixed.
  """
  @type email_settings_section :: %{
          required(:id) => atom(),
          required(:title) => String.t(),
          required(:permission) => String.t() | nil,
          required(:component) => module(),
          optional(:link) => %{
            required(:label) => String.t(),
            optional(:path) => String.t()
          }
        }

  @doc """
  Returns module-contributed sections to render on the core Emails
  Transactional settings page (`/admin/settings/email-sending`), below the core sections
  (sender identity, transport, default integration, test send).

  Lets a module (e.g. an emails or newsletters package) add its own
  settings UI to the shared page without the core page needing to know it
  exists — the same zero-config pattern as `settings_tabs/0`, but for
  composing INTO one page instead of adding a new tab. Collected via
  `PhoenixKit.ModuleRegistry.all_email_settings_sections/0`, which only
  consults **enabled** modules — a disabled module must not inject a
  live_component that assumes its own supervised state is running.

  ## Example

      @impl PhoenixKit.Module
      def email_settings_sections do
        [%{
          id: :emails_queue_pacing,
          title: "Queue & Pacing",
          permission: "emails",
          component: PhoenixKit.Modules.Emails.Web.SettingsSection
        }]
      end

  Modules with nothing to add here skip this callback — the default is `[]`.
  """
  @callback email_settings_sections() :: [email_settings_section()]

  @doc """
  Returns the emails this module sends, so the admin email preview
  (`/admin/settings/email-sending/preview`) can list them next to core's.

  Each entry is a `t:PhoenixKit.Email.Catalog.entry/0`: the template `name`
  the module passes to `PhoenixKit.Mailer.send_from_template/4`, a `label`,
  and — so the preview renders what a real send would — the same `defaults`
  function the send uses, sample `variables`, and the `layout` option the
  send passes. Collected via `PhoenixKit.ModuleRegistry.all_email_templates/0`
  from **enabled** modules only; a name core already lists is ignored.

  ## Example

      @impl PhoenixKit.Module
      def email_templates do
        [%{
          name: "billing_invoice",
          label: gettext("Invoice"),
          defaults: &MyModule.Emails.invoice_defaults/0,
          variables: fn -> %{"invoice_number" => "INV-0001"} end,
          layout: "billing"
        }]
      end

  Modules that send no email skip this callback — the default is `[]`.
  A module that must still compile against an older core, where the callback
  does not exist, defines it without `@impl` (with `@impl` that compile warns).
  """
  @callback email_templates() :: [PhoenixKit.Email.Catalog.entry()]

  @doc """
  Returns the module implementing
  `PhoenixKit.Modules.Storage.Reorganizer.Source` for this module's own
  records, or `nil` if it has nothing to contribute.

  Collected from **enabled** modules by
  `PhoenixKit.ModuleRegistry.all_media_reorganizers/0` — same rationale as
  `sitemap_sources/0`: a disabled module's records must not be touched.

  ## Example

      @impl PhoenixKit.Module
      def media_reorganizer, do: PhoenixKitCatalogue.MediaReorganizer

  Modules with no media of their own skip this callback — the default is `nil`.
  """
  @callback media_reorganizer() :: module() | nil

  @doc """
  The places in this module's own tables that point at a stored file, so the
  orphan check of `PhoenixKit.Modules.Storage` does not take a file the module
  uses for an orphan.

  Returns `{table, condition}` pairs. `condition` is an `Ecto.Query.dynamic/2`
  over the file (`f`) that is true when **this table does not reference the
  file**, normally a `NOT EXISTS` — the same shape as an entry of the host's
  `:file_reference_sources` config, and ANDed onto the orphan query the same way. The
  table name is what core checks first: a pair whose table does not exist in
  the database is left out, so a module whose tables are not migrated yet
  cannot break the check.

  Collected from **all** modules, enabled or not
  (`PhoenixKit.ModuleRegistry.all_file_references/0`): a disabled
  module's data still holds its files. Fails closed: if this function raises,
  or returns anything but a list of such pairs, no file is treated as orphaned
  until it is fixed.

  ## Example

      import Ecto.Query, only: [dynamic: 2]

      @impl PhoenixKit.Module
      def file_references do
        [
          {"phoenix_kit_post_media",
           dynamic(
             [f],
             fragment(
               "NOT EXISTS (SELECT 1 FROM phoenix_kit_post_media pm WHERE pm.file_uuid = ?)",
               f.uuid
             )
           )}
        ]
      end

  **Replaces core's list for this module's tables.** Until core 3.0 core keeps
  its own built-in checks for the tables it created for modules, and skips one
  only when the module that owns the table implements this callback, so a
  module must return *every* table of its own that holds a file reference, not
  only the new ones. A module whose tables hold no file reference skips the
  callback; one that must compile against an older core defines it without
  `@impl`.
  """
  @callback file_references() :: [{String.t(), Ecto.Query.dynamic_expr()}]

  @doc """
  The manifest of this module's own tables, so `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor` can check and repair them.

  Returns a module implementing `PhoenixKit.Migrations.ExpectedSchema.Behaviour`
  (the same contract as core's own manifest), or `nil`. It describes the
  tables the module's own migration chain builds, **as that chain leaves them
  at its current version**, and is generated from that chain, never written by
  hand (`dev_docs/squash/generate_module_manifest.exs` in core).

  Repair checks the module only while the database is at the chain's current
  version (`migration_module/0`'s `migrated_version/1` equals
  `current_version/0`): a module that is behind, or was never migrated, is
  reported as such, not healed against a shape it is not supposed to have yet.
  Like all of repair it is additive: it creates what is missing and reports the
  rest, and never drops, alters or rewrites anything.

  Collected from all modules, enabled or not
  (`PhoenixKit.ModuleRegistry.all_expected_schemas/0`). A module that must
  compile against a core that lacks this callback defines it without `@impl`.

  ## Example

      def expected_schema, do: PhoenixKitCustomerSupport.ExpectedSchema
  """
  @callback expected_schema() :: module() | nil

  @doc """
  The kinds of job run this module contributes — modules implementing
  `PhoenixKit.Jobs.Kind`.

  A *run* is a durable record of one logical piece of long background work (an
  import, a broadcast, a backfill) that an admin can watch, pause, resume and
  cancel from **Admin → Jobs**; Oban executes it batch by batch. Declaring a
  kind here is what makes `PhoenixKit.Jobs.start/4` accept it and the Jobs page
  describe it. Collected from **enabled** modules by
  `PhoenixKit.ModuleRegistry.all_job_kinds/0`: a run whose module was disabled
  fails with "kind unavailable" rather than looping, and can be retried once the
  module is back.

  ## Example

      @impl PhoenixKit.Module
      def job_kinds, do: [MyModule.Jobs.ImportRows]

  A module with no long-running work skips this callback — the default is `[]`.
  """
  @callback job_kinds() :: [module()]

  @doc """
  Returns the API tools this module offers (`PhoenixKit.API.Tool`).

  A tool is one operation (`"ecommerce.set_prices"`): its audience (`:admin` needs a key,
  `:public` needs none), the scope and role permission it requires, a JSON Schema for its
  input and a `{module, function}` handler. Core builds the REST surface (and later MCP)
  from them, so validation, permission checks, rate limits and the shape of the response
  are done once, in core. Details: `PhoenixKit.API.Tool`, `PhoenixKit.API.Registry`.

  Collected from **enabled** modules by `PhoenixKit.ModuleRegistry.all_api_tools/1`: a
  disabled module's tools cannot be called, and neither can those of a module whose API the
  install has switched off (its `module_key/0` in the `api_disabled_modules` setting).
  `PhoenixKit.ModuleRegistry.disabled_api_tool?/3` asks the switched-off modules, so the API
  can answer "module disabled" instead of "no such tool".

  Build every tool with `PhoenixKit.API.Tool.new!/1`. A tool that fails
  `PhoenixKit.API.Tool.validate/1` is ignored, with one warning per module. So is a tool
  named `system.*`: that namespace is core's own and skips the scope and permission checks.

  ## Example

      @impl PhoenixKit.Module
      def api_tools do
        [
          PhoenixKit.API.Tool.new!(
            name: "catalogue.list_products",
            audience: :admin,
            scope: "catalogue.products:read",
            permission: "catalogue",
            title: "List products",
            handler: {MyModule.API, :list_products},
            annotations: %{read_only: true}
          )
        ]
      end

  A module that must also compile against an older core, which has no such callback,
  defines `api_tools/0` without `@impl` (with `@impl` that compile warns).

  Modules with no API skip this callback — the default is `[]`.
  """
  @callback api_tools() :: [PhoenixKit.API.Tool.t()]

  @doc """
  Returns the error codes this module's API tools answer with, beyond the ones core defines.

  A tool handler fails with `{:error, code, message, context}` (`PhoenixKit.API.Executor`),
  and `code` is what an agent branches on. Core knows its own codes (`not_found`,
  `validation_failed`, ...); a code of the module's own, such as `quota_spent`, answers
  `500` and is logged unless the module declares it here, with the HTTP `status` (400..599),
  a `title` for the problem document, and the `advice` an MCP client reads after the error
  (`nil` for the generic sentence). The values on the wire (`code`, `status`, `title`) are a
  contract with clients: change them like an API.

  Collected from **enabled** modules by `PhoenixKit.ModuleRegistry.all_api_problems/0`, and
  only when an error is answered, so a successful call pays nothing. A code of core cannot
  be overridden: such a declaration, an invalid entry, and a code a module before this one
  already declared are each dropped with one warning.

  ## Example

      @impl PhoenixKit.Module
      def api_problems do
        %{
          quota_spent: %{
            status: 422,
            title: "Quota spent",
            advice: "Wait for the next hour, then repeat."
          }
        }
      end

  A module that must also compile against an older core, which has no such callback,
  defines `api_problems/0` without `@impl` (with `@impl` that compile warns).

  Modules that answer with core's codes only skip this callback - the default is `%{}`.
  """
  @callback api_problems() :: %{
              atom() => %{
                status: 400..599,
                title: String.t(),
                advice: String.t() | nil
              }
            }

  @doc """
  Returns the sticky LiveViews this module puts into the admin header, before the
  notifications bell (`PhoenixKit.HeaderWidget`).

  Each entry is `{live_view, id, session_fun}`, or `{live_view, id, session_fun, opts}` with
  `opts = [dock: true]` for a widget that uses the dock column (see below):

    * `live_view` - the LiveView module.
    * `id` - the DOM id of the nested LiveView. Keep it stable: it is what lets the widget
      survive admin navigation (`sticky: true`) with its state and subscriptions.
    * `session_fun` - `(layout_assigns -> session | nil)`. It gets the assigns of the admin
      layout (`:socket`, `:phoenix_kit_current_scope`, `:phoenix_kit_current_user`,
      `:current_locale`, `:impersonating?`, ...) and returns the session map of the nested
      LiveView: **string** keys, values that can be signed into the page (ids and strings,
      not structs). `nil` means "no widget for this user": nothing is rendered, no dock, no
      warning. The keys `user_token`, `pk_session_accounts`, `live_socket_id` and
      `phoenix_kit_session_uuid` are reserved (they belong to the cookie session, which a
      nested LiveView's session would otherwise hide): they are dropped from the map, with
      one warning per module and widget.

  Collected from **enabled** modules by `PhoenixKit.ModuleRegistry.all_header_widgets/0`.
  The admin layout renders a widget only when it has the parent LiveView's socket and a
  signed-in user, with `Phoenix.Component.live_render/3`, `sticky: true`; a widget whose
  session function raises is skipped (one warning per module and widget id), and so is an
  invalid entry (one warning per module).
  The callback runs on every render of the layout, so keep it a cheap list of literals. The
  user dashboard has its own header and does not render widgets.

  ## Who may see the widget

  Core decides only whether the widget can be shown at all (enabled module, socket, signed-in
  user); who of the users may see it, the module does, in `session_fun`: it gets the scope
  and returns `nil` for a user who may not, so that no process is started for him. A nested
  sticky LiveView does **not** go through the `live_session`'s `on_mount` hooks and gets no
  `current_scope`: it starts from nothing but its session map. And `session_fun` runs for
  **every** signed-in user of a page with the admin layout, including a user with no admin
  permission at all who lands on the `/admin` page. So check the permission there, and check
  it again in `mount/3` (rebuilding the user from the session the way the notifications bell
  does with its `user_uuid`), which is what holds when the session was made for someone else.
  Put only server-derived ids and strings into the session, never a value that came from the
  browser. The session is signed, not encrypted: whoever has the page can read it, so no
  secret and no token in it.

  `:impersonating?` in the assigns is `true` while the session acts as an account other than
  the root of the browser's multi-session stack (`PhoenixKit.HeaderWidget.impersonating?/1`:
  an operator's "log in as this user" looks like that, and so does an account the user added
  with a password). A widget that must not run for a borrowed session returns `nil` then.

  `session_fun` gets the layout's assigns and does **not** get the cookie session or the
  session token. `:impersonating?` is a hint for rendering, not a guarantee: it reads
  `scope.multi_session_accounts` and is always `false` while multi_session is off. A widget
  that needs the session reference or a reliable impersonation check does it in its own
  connected `mount/3`: LiveView merges the cookie session from `connect_info` into the
  session of any LiveView, so `PhoenixKit.Users.Auth.SessionRef.from_session/1` and
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1` work on the `session` argument there
  (they arrive with the agent-execute PR, not with this one). Never put a secret in the
  session map: a nested LiveView's session is signed, not encrypted.

  ## The dock column

  A widget may need room beside the page: a chat panel, for instance. The admin layout has
  an optional right-hand column for it, `#pk-dock` inside `#admin-drawer`. It is rendered
  **only while a rendered widget declares `dock: true`**, so a layout without such a widget
  is exactly the layout it has always been. The contract (details and the JS commands:
  `PhoenixKitWeb.Components.AdminDock`):

    * the container is `#pk-dock`; it is empty and hidden;
    * the widget opens and closes it with the class `pk-dock-open` on `<body>`
      (`AdminDock.open/1`, `close/1`, `toggle/1`) or on an element of its own markup in the
      header, after which the work area is narrower by the column's width instead of being
      overlapped; below `lg` the column covers the screen under the header. `<body>` is the
      element above both the header (where the widget is) and `#admin-drawer` (where the
      dock is), and LiveView does not patch it: the state survives a live redirect to another
      LiveView and a patch; only a full page load resets it;
    * the width comes from the CSS variable `--pk-dock-width` (default `25rem`), which the
      widget or the host sets on `:root` or `<body>` so that both the dock and a panel in the
      header see it.

  ## Example

      @impl PhoenixKit.Module
      def header_widgets do
        [
          {MyModule.Web.Assistant, "my-assistant",
           fn
             %{impersonating?: true} ->
               nil

             assigns ->
               %{
                 "user_uuid" => assigns.phoenix_kit_current_user.uuid,
                 "locale" => assigns[:current_locale_base]
               }
           end, dock: true}
        ]
      end

  A module that must also compile against an older core, which has no such callback,
  defines `header_widgets/0` without `@impl` (with `@impl` that compile warns).

  Modules with no header widget skip this callback; there is no default, so that the
  registry asks only the modules that define it.
  """
  @callback header_widgets() :: [PhoenixKit.HeaderWidget.entry()]

  @doc """
  Tabs this module adds to the signed-in user's settings strip, `/profile/settings/<id>`.

  Each is a map described in `PhoenixKit.ProfileSettingsTab` (`:id`, `:label`, `:icon`,
  `:after`, `:permission`, `:visible`, `:live_view`). The tab links to a page of the
  module's own, which renders `PhoenixKitWeb.Components.ProfileSettingsTabs.profile_tabs/1`
  with `active` set to the tab's id. With `:live_view`, core declares the route; the route
  exists whether or not the module is enabled, the tab is offered only while it is, so the
  page checks `enabled?/0` in its own `mount/3`.

  ## Example

      def profile_settings_tabs do
        [
          %{
            id: "my-tab",
            # `use Gettext, backend: MyModule.Gettext` in this module; called on
            # every render, after the request's locale is set
            label: fn -> gettext("My tab") end,
            icon: "hero-puzzle-piece",
            after: "security",
            live_view: MyModule.Web.MyTabLive
          }
        ]
      end

  A module that must also compile against an older core, which has no such callback,
  defines `profile_settings_tabs/0` without `@impl`.
  """
  @callback profile_settings_tabs() :: [map()]

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
    notification_channels: 0,
    before_user_delete: 1,
    resource_links: 0,
    css_sources: 0,
    js_sources: 0,
    sitemap_sources: 0,
    oban_queues: 0,
    oban_crons: 0,
    reserved_route_prefixes: 0,
    migrate_legacy: 0,
    email_settings_sections: 0,
    email_templates: 0,
    media_reorganizer: 0,
    file_references: 0,
    expected_schema: 0,
    job_kinds: 0,
    api_tools: 0,
    api_problems: 0,
    header_widgets: 0,
    profile_settings_tabs: 0
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
      def notification_channels, do: []

      @impl PhoenixKit.Module
      def resource_links, do: %{}

      @impl PhoenixKit.Module
      def css_sources, do: []

      @impl PhoenixKit.Module
      def js_sources, do: []

      @impl PhoenixKit.Module
      def sitemap_sources, do: []

      @impl PhoenixKit.Module
      def oban_queues, do: []

      @impl PhoenixKit.Module
      def oban_crons, do: []

      @impl PhoenixKit.Module
      def reserved_route_prefixes, do: []

      @impl PhoenixKit.Module
      def migrate_legacy, do: :ok

      @impl PhoenixKit.Module
      def email_settings_sections, do: []

      @impl PhoenixKit.Module
      def email_templates, do: []

      @impl PhoenixKit.Module
      def media_reorganizer, do: nil

      @impl PhoenixKit.Module
      def job_kinds, do: []

      @impl PhoenixKit.Module
      def api_tools, do: []

      @impl PhoenixKit.Module
      def api_problems, do: %{}

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
                     notification_channels: 0,
                     resource_links: 0,
                     css_sources: 0,
                     js_sources: 0,
                     sitemap_sources: 0,
                     oban_queues: 0,
                     oban_crons: 0,
                     reserved_route_prefixes: 0,
                     migrate_legacy: 0,
                     email_settings_sections: 0,
                     email_templates: 0,
                     media_reorganizer: 0,
                     job_kinds: 0,
                     api_tools: 0,
                     api_problems: 0
    end
  end
end
