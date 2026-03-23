# Module System: Building PhoenixKit Modules

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [How Auto-Discovery Works](#how-auto-discovery-works)
- [Required Callbacks](#required-callbacks)
- [Optional Callbacks](#optional-callbacks)
- [Folder Structure Convention](#folder-structure-convention)
- [Admin Tabs](#admin-tabs)
- [Subtabs and Hidden Pages](#subtabs-and-hidden-pages)
- [Settings Tabs](#settings-tabs)
- [Permission Metadata](#permission-metadata)
- [Supervisor Children](#supervisor-children)
- [Route Integration](#route-integration)
- [Navigation System (Paths Module)](#navigation-system-paths-module)
- [Component Reuse](#component-reuse)
- [JavaScript in External Modules](#javascript-in-external-modules)
- [Enable / Disable Patterns](#enable--disable-patterns)
- [Database and Migrations](#database-and-migrations)
- [External Hex Packages](#external-hex-packages)
- [Pitfalls for Developers and Agents](#pitfalls-for-developers-and-agents)
- [Reference Files](#reference-files)

---

## Overview

PhoenixKit's module system is a plugin architecture that lets feature modules self-register into the platform. Adding a module no longer requires touching 7+ core files — a module just uses the behaviour and gets wired up automatically.

**What a registered module gets for free:**

| System | What happens automatically |
|--------|---------------------------|
| Admin sidebar | Tabs appear when module is enabled |
| Permission system | Permission key registered for role-based access |
| Supervisor | `children/0` specs started alongside PhoenixKit |
| Routes | Admin routes generated at compile time |
| Modules admin page | Enable/disable toggle with live status |
| Settings sidebar | Settings tabs appear when module is enabled |

**Three components power the system:**

- **`PhoenixKit.Module`** — the behaviour contract (5 required + 9 optional callbacks)
- **`PhoenixKit.ModuleRegistry`** — GenServer + `:persistent_term` registry; zero-cost reads
- **`PhoenixKit.ModuleDiscovery`** — zero-config beam file scanning; finds modules without config

---

## Quick Start

```elixir
defmodule PhoenixKit.Modules.Analytics do
  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ── Required callbacks ────────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: "analytics"

  @impl PhoenixKit.Module
  def module_name, do: "Analytics"

  @impl PhoenixKit.Module
  def enabled?, do: Settings.get_boolean_setting("analytics_enabled", false)

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("analytics_enabled", true, "analytics")
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("analytics_enabled", false, "analytics")
  end

  # ── Optional callbacks ────────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "analytics",          # MUST match module_key exactly
      label: "Analytics",
      icon: "hero-chart-bar",
      description: "Traffic and usage analytics"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_analytics,
        label: "Analytics",
        icon: "hero-chart-bar",
        path: "/admin/analytics",
        priority: 600,
        level: :admin,
        permission: "analytics",  # MUST match module_key
        match: :prefix,
        group: :admin_modules
      )
    ]
  end
end
```

That's a complete module. No config file entries required. Just place the file in `lib/modules/analytics/analytics.ex` and it is auto-discovered.

---

## How Auto-Discovery Works

`use PhoenixKit.Module` writes a persisted attribute into the compiled `.beam` file:

```elixir
Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
@phoenix_kit_module true
```

At startup, `ModuleDiscovery` uses `:beam_lib.chunks/2` to scan the ebin directories of all applications that list `:phoenix_kit` in their dependencies — reading the attribute **without loading modules**. Any beam file with `@phoenix_kit_module true` is added to the registry.

**Discovery order:**

1. Internal modules (hardcoded list in `ModuleRegistry.internal_modules/0`)
2. External modules found by beam scanning (`ModuleDiscovery.scan_beam_files/0`)
3. Explicitly configured modules (`config :phoenix_kit, :modules, [MyModule]`)

Steps 2 and 3 are merged and deduplicated. Internal modules are never duplicated even if a dep re-exports them.

**Compile-time vs runtime:**

- Route macros run at compile time (`integration.ex`) — external modules need a recompile to generate routes
- Registry population runs at runtime (GenServer init) — no recompile needed for enable/disable

---

## Required Callbacks

All five must be implemented. `use PhoenixKit.Module` provides no defaults for these.

### `module_key/0 :: String.t()`

Globally unique string identifier. Used as the permission key, settings key prefix, PubSub topic segment, and toggle event identifier.

```elixir
def module_key, do: "analytics"
```

**Rules:**
- Lowercase snake_case
- Must be unique across ALL registered modules (startup warning if duplicate)
- Must exactly match `permission_metadata.key` (startup warning if mismatch)
- Treat it as immutable — changing it breaks existing settings in the DB

### `module_name/0 :: String.t()`

Human-readable display name shown in the modules admin page.

```elixir
def module_name, do: "Analytics"
```

### `enabled?/0 :: boolean()`

Whether the module is currently active. Called frequently — keep it cheap. The settings cache handles the DB read.

```elixir
def enabled? do
  Settings.get_boolean_setting("analytics_enabled", false)
rescue
  _ -> false
end
```

The `rescue` clause is required — `enabled?/0` is called before migrations run, so the settings table may not exist yet.

### `enable_system/0` and `disable_system/0`

Enable or disable the module system-wide. Must return `:ok | {:ok, term()} | {:error, term()}`.

```elixir
def enable_system do
  Settings.update_boolean_setting_with_module("analytics_enabled", true, "analytics")
end

def disable_system do
  Settings.update_boolean_setting_with_module("analytics_enabled", false, "analytics")
end
```

The LiveView `modules.ex` normalizes the return via `normalize_result/1`, so all three return shapes are valid. Return `{:error, reason}` to surface an error in the UI without crashing.

---

## Optional Callbacks

All have defaults provided by `use PhoenixKit.Module`. Only implement what you need.

### `get_config/0 :: map()`

Returns a map of config/stats shown on the admin modules card.

**Default:** `%{enabled: enabled?()}`

```elixir
def get_config do
  %{
    enabled: enabled?(),
    event_count: count_events(),
    last_sync: last_sync_time()
  }
end
```

> **Performance warning:** `get_config/0` is called on every render of the admin modules page. Do not perform unbounded queries or slow I/O here. Keep it fast. If you need expensive stats, cache them.

### `permission_metadata/0 :: permission_meta() | nil`

Registers the module with the permission system. Required for custom role access control.

**Default:** `nil` (no permission key registered — module always accessible to admins/owners)

```elixir
def permission_metadata do
  %{
    key: "analytics",        # Must match module_key/0 exactly
    label: "Analytics",
    icon: "hero-chart-bar",
    description: "Traffic and usage analytics"
  }
end
```

If `nil`, the module has no dedicated permission and custom roles will never be able to see it in the sidebar.

### `admin_tabs/0 :: [Tab.t()]`

Admin sidebar tabs. **Default:** `[]`

See [Admin Tabs](#admin-tabs) for full details.

### `settings_tabs/0 :: [Tab.t()]`

Subtabs under Admin → Settings. **Default:** `[]`

See [Settings Tabs](#settings-tabs).

### `user_dashboard_tabs/0 :: [Tab.t()]`

User-facing dashboard tabs. **Default:** `[]`

### `children/0 :: [Supervisor.child_spec()]`

Supervisor children started with PhoenixKit's supervisor. **Default:** `[]`

```elixir
def children, do: [PhoenixKit.Modules.Analytics.Worker]
```

See [Supervisor Children](#supervisor-children).

### `route_module/0 :: module() | nil`

Module containing route macros injected into the router at compile time. **Default:** `nil`

### `version/0 :: String.t()`

Semantic version string. **Default:** `"0.0.0"`. Useful for external packages.

### `migration_module/0 :: module() | nil`

Returns the versioned migration coordinator module for this plugin. **Default:** `nil`

When set, `mix phoenix_kit.update` will auto-detect the module's migration state, compare `migrated_version_runtime()` with `current_version()`, and generate + run migration files if the database is behind.

```elixir
def migration_module, do: MyModule.Migration
```

The coordinator module must implement:
- `current_version/0` — returns the latest migration version (integer)
- `migrated_version_runtime/1` — reads the current DB version; accepts `[prefix: "public"]` options (safe to call outside migration context)
- `up/1` — runs migrations; accepts `[prefix: "public", version: target]` options
- `down/1` — rolls back migrations; accepts `[prefix: "public", version: target]` options

Version is tracked via a SQL comment on a designated table (e.g., `COMMENT ON TABLE phoenix_kit_my_items IS '2'`). Each version is an immutable module (e.g., `MyModule.Migration.Postgres.V01`) that the coordinator calls via `Module.concat/1`.

See `PhoenixKitDocumentCreator.Migration` for a production example.

---

## Folder Structure Convention

### Internal modules (inside PhoenixKit)

All modules live in `lib/modules/` with the `PhoenixKit.Modules.<Name>` namespace.

```
lib/modules/analytics/
├── analytics.ex          # PhoenixKit.Modules.Analytics — main context + behaviour
├── events.ex             # PhoenixKit.Modules.Analytics.Events
├── worker.ex             # PhoenixKit.Modules.Analytics.Worker
└── web/
    ├── index.ex          # PhoenixKit.Modules.Analytics.Web.Index (LiveView)
    └── settings.ex       # PhoenixKit.Modules.Analytics.Web.Settings (LiveView)
```

**Rules:**
- Backend and web code live in the same folder
- The main context file (`analytics.ex`) is the one that `use PhoenixKit.Module`
- Do not use `lib/phoenix_kit/modules/`, `lib/phoenix_kit_web/live/modules/`, or `lib/phoenix_kit/<name>.ex`

### External modules (standalone packages)

```
lib/
  my_phoenix_kit_module.ex                   # Main module (behaviour callbacks)
  my_phoenix_kit_module/
    paths.ex                                 # Centralized path helpers
    documents.ex                             # Context / business logic
    schemas/
      item.ex                               # Ecto schemas
    migration.ex                             # Migration coordinator
    migration/postgres/
      v01.ex                                # Initial tables
      v02.ex                                # Schema changes
    web/
      index_live.ex                          # Main admin page
      detail_live.ex                         # Detail/edit page
      components/
        my_scripts.ex                        # JS hook component
        item_card.ex                         # Shared UI component
        editor_panel.ex                      # Shared editor component
mix/
  tasks/
    my_phoenix_kit_module.install.ex          # Install task
```

---

## Admin Tabs

Admin sidebar tabs are defined in `admin_tabs/0` as `%Tab{}` structs.

```elixir
def admin_tabs do
  [
    %Tab{
      id: :admin_analytics,           # Atom — must be unique across ALL modules
      label: "Analytics",
      icon: "hero-chart-bar",
      path: "analytics",              # Relative slug — core prepends /admin/
      priority: 600,                  # Lower = higher in sidebar
      level: :admin,                  # Always :admin for admin sidebar
      permission: "analytics",        # Must match module_key and permission_metadata.key
      match: :prefix,                 # :prefix or :exact
      group: :admin_modules,          # :admin_main or :admin_modules
      live_view: {MyModule.Web.IndexLive, :index}
    }
  ]
end
```

### Tab struct complete reference

| Field | Type | Default | Description |
|---|---|---|---|
| `:id` | atom | *required* | Unique identifier (prefix with `:admin_yourmodule`) |
| `:label` | string | *required* | Display text in sidebar |
| `:icon` | string | `nil` | Heroicon name (e.g., `"hero-chart-bar"`) |
| `:path` | string | *required* | Relative slug (`"my-module"`) or absolute (`"/admin/my-module"`) |
| `:priority` | integer | `500` | Sort order (lower = higher in sidebar) |
| `:level` | atom | `:user` | `:admin`, `:settings`, `:user`, or `:all` |
| `:permission` | string | `nil` | Permission key (use `module_key()`) |
| `:group` | atom | `nil` | Sidebar group (`:admin_modules` for module tabs) |
| `:match` | atom/fn | `:prefix` | `:exact`, `:prefix`, `{:regex, ~r/...}`, or `fn path -> bool end` |
| `:live_view` | tuple | `nil` | `{Module, :action}` for auto-routing |
| `:parent` | atom | `nil` | Parent tab ID (for subtabs or hidden sub-pages) |
| `:visible` | bool/fn | `true` | Show in sidebar. `false` hides it. Can be `fn scope -> bool end` |
| `:badge` | `Badge` | `nil` | Badge indicator (count, dot, status) |
| `:tooltip` | string | `nil` | Hover text |
| `:external` | bool | `false` | Whether this links to an external site |
| `:new_tab` | bool | `false` | Whether to open in a new browser tab |
| `:attention` | atom | `nil` | Animation: `:pulse`, `:bounce`, `:shake`, `:glow` |
| `:metadata` | map | `%{}` | Custom metadata for advanced use cases |
| `:subtab_display` | atom | `:when_active` | When to show subtabs: `:when_active` or `:always` |
| `:subtab_indent` | string | `nil` | Tailwind padding class (e.g., `"pl-6"`) |
| `:subtab_icon_size` | string | `nil` | Icon size class (e.g., `"w-3 h-3"`) |
| `:subtab_text_size` | string | `nil` | Text size class (e.g., `"text-xs"`) |
| `:subtab_animation` | atom | `nil` | `:none`, `:slide`, `:fade`, `:collapse` |
| `:redirect_to_first_subtab` | bool | `false` | Navigate to first subtab when clicking parent |
| `:highlight_with_subtabs` | bool | `false` | Keep parent highlighted when subtab is active |

### Priority reference

| Priority | Module |
|----------|--------|
| 700+ | Core admin tabs (Dashboard, Users, Media, Settings) |
| 640 | Tickets |
| 620 | DB |
| 600 | Billing |
| 570 | Emails |
| 540 | Storage |
| 500 | Publishing |
| 480 | Shop |

Use a value in an existing gap or adjust nearby modules if needed.

### Groups

- `:admin_main` — core platform tabs (Dashboard, Users, Media, Settings)
- `:admin_modules` — feature module tabs (everything else)

### Match modes

- `:prefix` — tab highlighted for the path and all sub-paths (use for modules with sub-pages)
- `:exact` — tab highlighted only for the exact path

### Paths use hyphens, not underscores

`/admin/magic-link`, not `/admin/magic_link`.

---

## Subtabs and Hidden Pages

For modules with multiple pages, use a combination of visible subtabs and hidden pages.

### Visible subtabs

Subtabs appear indented under their parent in the sidebar when the parent is active:

```elixir
def admin_tabs do
  [
    # Parent tab with subtab configuration
    %Tab{
      id: :admin_my_module,
      label: "My Module",
      icon: "hero-puzzle-piece",
      path: "my-module",
      priority: 650,
      level: :admin,
      permission: module_key(),
      match: :prefix,
      group: :admin_modules,
      subtab_display: :when_active,        # Show subtabs only when parent is active
      highlight_with_subtabs: false,        # Don't highlight parent when subtab is active
      live_view: {MyModule.Web.IndexLive, :index}
    },
    # Visible subtab (appears in sidebar under parent)
    %Tab{
      id: :admin_my_module_reports,
      label: "Reports",
      icon: "hero-chart-bar",
      path: "my-module/reports",
      priority: 651,
      level: :admin,
      permission: module_key(),
      parent: :admin_my_module,
      live_view: {MyModule.Web.ReportsLive, :index}
    },
    # Another visible subtab
    %Tab{
      id: :admin_my_module_settings,
      label: "Settings",
      icon: "hero-cog-6-tooth",
      path: "my-module/settings",
      priority: 652,
      level: :admin,
      permission: module_key(),
      parent: :admin_my_module,
      live_view: {MyModule.Web.SettingsLive, :index}
    }
  ]
end
```

**Subtab display modes:**
- `:when_active` — subtabs visible only when the parent tab or one of its subtabs is active
- `:always` — subtabs always visible regardless of parent state

**`highlight_with_subtabs`:**
- `false` (default) — parent is not highlighted when a subtab is active
- `true` — parent stays highlighted when any subtab is active

### Hidden pages

For pages that need routes but shouldn't appear in the sidebar (edit pages, detail views, creation forms):

```elixir
%Tab{
  id: :admin_my_module_item_edit,
  path: "my-module/items/:uuid/edit",    # Path parameters work
  level: :admin,
  permission: module_key(),
  parent: :admin_my_module,               # Keeps parent highlighted
  visible: false,                          # Not shown in sidebar
  live_view: {MyModule.Web.ItemEditorLive, :edit}
}
```

### Conditional tabs via config flags

Gate tabs behind compile-time configuration:

```elixir
@testing_mode Application.compile_env(:my_module, :testing_mode, false)

@impl PhoenixKit.Module
def admin_tabs do
  base_tabs() ++ testing_tabs()
end

defp base_tabs do
  [%Tab{id: :admin_my_module, ...}]
end

defp testing_tabs do
  if @testing_mode do
    [%Tab{id: :admin_my_module_testing, label: "Testing", icon: "hero-beaker", ...}]
  else
    []
  end
end
```

Users enable via config:

```elixir
config :my_module, :testing_mode, true
```

### Real-world example: Document Creator (14 tabs)

```elixir
def admin_tabs do
  [
    # Main landing page (visible, with subtab config)
    %Tab{id: :admin_document_creator, path: "document-creator",
         subtab_display: :when_active, highlight_with_subtabs: false, ...},

    # Hidden CRUD pages (route exists, no sidebar entry)
    %Tab{id: :admin_document_creator_template_new,
         path: "document-creator/templates/new",
         visible: false, parent: :admin_document_creator, ...},
    %Tab{id: :admin_document_creator_template_edit,
         path: "document-creator/templates/:uuid/edit",
         visible: false, parent: :admin_document_creator, ...},
    %Tab{id: :admin_document_creator_document_edit,
         path: "document-creator/documents/:uuid/edit",
         visible: false, parent: :admin_document_creator, ...},

    # Visible subtabs (appear under parent in sidebar)
    %Tab{id: :admin_document_creator_headers,
         path: "document-creator/headers",
         parent: :admin_document_creator, ...},
    %Tab{id: :admin_document_creator_footers,
         path: "document-creator/footers",
         parent: :admin_document_creator, ...},

    # Hidden CRUD pages for subtabs
    %Tab{id: :admin_document_creator_header_new,
         path: "document-creator/headers/new",
         visible: false, parent: :admin_document_creator, ...},
    %Tab{id: :admin_document_creator_header_edit,
         path: "document-creator/headers/:uuid/edit",
         visible: false, parent: :admin_document_creator, ...},
    # ... footer_new, footer_edit similarly

    # Conditional testing tabs (behind :testing_editors config flag)
    # ... only included when config is true
  ]
end
```

Key patterns:
- **One main tab** visible in the sidebar with `subtab_display: :when_active`
- **Subtabs** for major sections (Headers, Footers) — visible, with `parent`
- **Hidden tabs** for CRUD pages — `visible: false`, still auto-routed
- **Path parameters** work in tab paths: `"document-creator/templates/:uuid/edit"`
- **All tabs** share the same `permission: module_key()` for consistent access control

---

## Settings Tabs

Settings subtabs appear under Admin → Settings when the module is enabled.

```elixir
def settings_tabs do
  [
    Tab.new!(
      id: :admin_settings_analytics,
      label: "Analytics",
      icon: "hero-chart-bar",
      path: "/admin/settings/analytics",
      priority: 910,
      level: :admin,
      parent: :admin_settings,          # Required for settings subtabs
      permission: "analytics"
    )
  ]
end
```

The `parent: :admin_settings` field links this tab as a subtab of the Settings section.

---

## Permission Metadata

`permission_metadata/0` integrates the module with PhoenixKit's role-based permission system.

```elixir
def permission_metadata do
  %{
    key: "analytics",
    label: "Analytics",
    icon: "hero-chart-bar",
    description: "Traffic and usage analytics"
  }
end
```

### How permissions work

| Role type | Default access | Can be changed? |
|---|---|---|
| **Owner** | Full access to everything | No — hardcoded, cannot be restricted |
| **Admin** | All permission keys by default | Yes — per key via Admin > Roles |
| **Custom roles** | No permissions initially | Yes — must be granted explicitly |

Without `permission_metadata/0` (returns `nil`), the module has no dedicated permission key. Admins and owners still see it; custom roles never will.

### Checking permissions in code

```elixir
alias PhoenixKit.Users.Auth.Scope

# In a LiveView
scope = socket.assigns.phoenix_kit_current_scope

Scope.has_module_access?(scope, "my_module")   # does user have this permission?
Scope.admin?(scope)                             # is user Owner or Admin?
Scope.system_role?(scope)                       # Owner, Admin, or User (not custom)?
Scope.owner?(scope)                             # is user Owner?
Scope.user_roles(scope)                         # list of role names
```

### Access guards on admin tabs

PhoenixKit's `on_mount` hook automatically checks the `:permission` field on each tab before rendering the LiveView. If the user's role doesn't have the permission, they get a 302 redirect. You don't need manual guards — just set `:permission` correctly.

For fine-grained checks within a page:

```elixir
<button :if={Scope.admin?(@phoenix_kit_current_scope)} phx-click="delete">
  Delete
</button>
```

### Startup validation

The registry warns at boot if:
- `permission_metadata.key` does not match `module_key`
- Tabs have no `:permission` field but the module has `permission_metadata`
- Duplicate tab IDs exist across modules

These are warnings, not crashes — a misconfigured module won't take down the app.

---

## Supervisor Children

Return child specs from `children/0` to start processes alongside PhoenixKit's supervisor tree.

```elixir
def children do
  [
    PhoenixKit.Modules.Analytics.Worker,
    {PhoenixKit.Modules.Analytics.Cache, ttl: :timer.minutes(5)}
  ]
end
```

### Important details

- `static_children/0` is called from `PhoenixKit.Supervisor.init/1` — before the ModuleRegistry GenServer starts. It builds the list directly from the internal module list. This means `children/0` must not rely on the registry being initialized.
- Individual module failures in `children/0` are caught by `static_children/0` and logged as warnings — they do not crash the supervisor.
- Children start with the PhoenixKit supervisor regardless of whether the module is "enabled". If you only want a process running when enabled, check `enabled?/0` inside the child's `start_link/1` and return `:ignore`.

### Conditional children with optional dependencies

Guard child specs on optional library availability:

```elixir
def children do
  if Code.ensure_loaded?(ChromicPDF) do
    [{MyModule.PdfSupervisor, []}]
  else
    []
  end
end
```

This ensures the module loads even when the optional dependency isn't installed.

### Worker that respects enabled state

```elixir
def start_link(_opts) do
  if PhoenixKit.Modules.Analytics.enabled?() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  else
    :ignore
  end
end
```

---

## Route Integration

### Auto-routing via `live_view` field

For most modules, auto-routing via the tab's `:live_view` field is sufficient. No manual router entries needed.

A tab like:

```elixir
%Tab{path: "my-module", live_view: {MyModule.Web.IndexLive, :index}}
```

Generates at compile time:

```elixir
live "/admin/my-module", MyModule.Web.IndexLive, :index
```

inside the admin `live_session` with the admin layout applied.

### Custom route module

For complex routing needs (non-LiveView routes, custom pipelines), implement `route_module/0`:

```elixir
def route_module, do: PhoenixKitAnalytics.Router
```

```elixir
defmodule PhoenixKitAnalytics.Router do
  defmacro phoenix_kit_admin_routes do
    quote do
      live "/admin/analytics", PhoenixKitAnalytics.Web.Index, :index
      live "/admin/analytics/:id", PhoenixKitAnalytics.Web.Show, :show
    end
  end
end
```

Routes are generated at compile time via `compile_plugin_admin_routes/0` in `integration.ex`. A recompile is required after adding a new external module.

### Assigns available in admin LiveViews

PhoenixKit's `on_mount` hooks inject these assigns:

| Assign | Type | Description |
|---|---|---|
| `@phoenix_kit_current_scope` | `Scope` | Authenticated user's scope (role, permissions) |
| `@current_locale` | `String` | Current locale string (e.g., `"en"`, `"ja"`) |
| `@url_path` | `String` | Current URL path (used for active nav highlighting) |

Set `@page_title` in `mount/3` — it appears in the browser tab.

---

## Navigation System (Paths Module)

Every path your module generates — in templates, redirects, or LiveView navigation — **must** go through `PhoenixKit.Utils.Routes.path/1`. This handles the configurable URL prefix and locale prefix.

### Create a Paths module

Centralize all path construction in one file:

```elixir
# lib/my_module/paths.ex
defmodule MyModule.Paths do
  @moduledoc """
  Centralized path helpers for My Module.

  All navigation paths go through `PhoenixKit.Utils.Routes.path/1`, which
  handles the configurable URL prefix and locale prefix automatically.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/my-module"

  # ── Main ──────────────────────────────────────────────────────────
  def index, do: Routes.path(@base)

  # ── Items ─────────────────────────────────────────────────────────
  def item_new, do: Routes.path("#{@base}/items/new")
  def item_edit(uuid), do: Routes.path("#{@base}/items/#{uuid}/edit")
  def item_show(uuid), do: Routes.path("#{@base}/items/#{uuid}")

  # ── Settings ──────────────────────────────────────────────────────
  def settings, do: Routes.path("#{@base}/settings")
end
```

### Usage in LiveViews and templates

```elixir
alias MyModule.Paths

# Redirect after save
{:noreply, redirect(socket, to: Paths.index())}

# Handle not-found
case get_item(uuid) do
  nil ->
    socket |> put_flash(:error, "Not found") |> redirect(to: Paths.index())
  item ->
    assign(socket, item: item)
end
```

```heex
<a href={Paths.item_edit(@item.uuid)} class="btn btn-sm">Edit</a>
<a href={Paths.index()} class="btn btn-ghost btn-sm">Back</a>
```

### Tab paths vs template paths

| Where | How to specify paths |
|---|---|
| Tab struct `path` | `"my-module"` (relative — core prepends `/admin/`) |
| Template `href` / `redirect` | `Paths.index()` (wraps `Routes.path/1`) |
| Email URLs | `Routes.url("/path")` (full URL) |

### Why relative paths break

The browser resolves relative paths relative to the current URL. When locale segments (e.g., `/ja/`) are in the path, relative paths resolve incorrectly. Always use absolute paths via `Routes.path/1`.

---

## Component Reuse

As modules grow, extract shared UI into reusable function components. This keeps LiveViews focused on business logic.

### Creating a shared component

```elixir
# lib/my_module/web/components/item_card.ex
defmodule MyModule.Web.Components.ItemCard do
  use Phoenix.Component

  attr :item, :map, required: true
  attr :on_edit, :string, default: nil
  attr :on_delete, :string, default: nil

  def item_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h3 class="card-title">{@item.name}</h3>
        <p class="text-base-content/70 text-sm">{@item.description}</p>
        <div class="card-actions justify-end">
          <button :if={@on_edit} class="btn btn-sm btn-ghost"
                  phx-click={@on_edit} phx-value-uuid={@item.uuid}>Edit</button>
          <button :if={@on_delete} class="btn btn-sm btn-error btn-outline"
                  phx-click={@on_delete} phx-value-uuid={@item.uuid}>Delete</button>
        </div>
      </div>
    </div>
    """
  end
end
```

### Using components across LiveViews

```elixir
defmodule MyModule.Web.IndexLive do
  use Phoenix.LiveView
  import MyModule.Web.Components.ItemCard

  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-4 p-4">
      <.item_card :for={item <- @items} item={item}
                  on_edit="edit_item" on_delete="delete_item" />
    </div>
    """
  end
end
```

### Shared editor panel pattern

For modules with multiple editor pages that share the same shell:

```elixir
# lib/my_module/web/components/editor_panel.ex
defmodule MyModule.Web.Components.EditorPanel do
  use Phoenix.Component

  attr :id, :string, required: true, doc: "Unique prefix for element IDs"
  attr :hook, :string, required: true, doc: "Phoenix hook name"
  attr :save_event, :string, required: true, doc: "LiveView event for saving"
  attr :show_toolbar, :boolean, default: true

  def editor_panel(assigns) do
    ~H"""
    <div class="flex-1">
      <div
        id={"#{@id}-wrapper"}
        phx-hook={@hook}
        phx-update="ignore"
        data-editor-id={"#{@id}-editor"}
        data-save-event={@save_event}
      >
        <div :if={@show_toolbar} id={"#{@id}-toolbar"}
             class="border-b border-base-300 p-2"></div>
        <div id={"#{@id}-editor"} style="min-height: 500px;"></div>
      </div>
    </div>
    """
  end
end
```

Used by multiple LiveViews with different parameters:

```elixir
# Template editor
import MyModule.Web.Components.EditorPanel
<.editor_panel id="template" hook="TemplateEditor" save_event="save_template" />

# Document editor
<.editor_panel id="document" hook="DocumentEditor" save_event="save_document"
               show_toolbar={false} />
```

### Multi-step modal component

```elixir
# lib/my_module/web/components/create_modal.ex
defmodule MyModule.Web.Components.CreateModal do
  use Phoenix.Component

  attr :open, :boolean, required: true
  attr :step, :string, default: "choose"
  attr :templates, :list, default: []
  attr :creating, :boolean, default: false

  def modal(assigns) do
    ~H"""
    <div :if={@open} class="modal modal-open">
      <div class="modal-box max-w-lg">
        <%= case @step do %>
          <% "choose" -> %>
            <h3 class="text-lg font-bold">Choose Type</h3>
            <%!-- Step 1: selection UI --%>
          <% "configure" -> %>
            <h3 class="text-lg font-bold">Configure</h3>
            <%!-- Step 2: form fields --%>
        <% end %>
      </div>
      <div class="modal-backdrop" phx-click="modal_close"></div>
    </div>
    """
  end
end
```

### Component design guidelines

1. **Use `attr` declarations** — they provide documentation, validation, and compile-time warnings
2. **Use daisyUI semantic classes** — `bg-base-100`, `text-base-content`, `btn btn-primary` (never hardcode colors)
3. **Use `text-base-content/70`** for muted text, not `text-gray-500`
4. **Prefix element IDs** with the component's `@id` to avoid collisions
5. **Pass event names as attrs** (e.g., `on_edit="edit_item"`) — makes components reusable across LiveViews

---

## JavaScript in External Modules

External modules **cannot inject into the parent app's asset pipeline** (`app.js`, `esbuild`, `node_modules`). All JavaScript must be delivered as **inline `<script>` tags** or via **base64-encoded compile-time embedding**.

### Simple inline hooks

For small amounts of JS, use inline `<script>` tags:

```elixir
defmodule MyModule.Web.Components.MyScripts do
  use Phoenix.Component

  def my_scripts(assigns) do
    ~H"""
    <script>
      window.PhoenixKitHooks = window.PhoenixKitHooks || {};
      window.PhoenixKitHooks.MyHook = {
        mounted() {
          this.el.addEventListener("click", () => {
            this.pushEvent("clicked", {id: this.el.dataset.id});
          });
        },
        destroyed() { /* cleanup */ }
      };
    </script>
    """
  end
end
```

Usage:

```heex
<.my_scripts />
<div id="my-widget" phx-hook="MyHook" phx-update="ignore" data-id={@item.id}>
  ...
</div>
```

**Rules:**
- Register hooks on `window.PhoenixKitHooks` — PhoenixKit spreads this object into the LiveSocket
- Pages using hooks must use **full page load** (`redirect/2`, not `navigate/2`) so inline scripts execute
- Never assume access to `node_modules`, `esbuild`, or the parent app's JS build

### Base64-encoded JS delivery (for large scripts)

Large inline `<script>` tags inside LiveView renders **do not work reliably**:

1. **LiveView morphdom breaks `</script>` boundaries** — DOM patching can corrupt the boundary between `</script>` and subsequent HTML
2. **HTML strings inside JS confuse rendering** — JS code containing `'<h1>Title</h1>'` can be parsed as HTML
3. **Browser extensions block inline eval()** — MetaMask's hardened JS, etc.

The solution is **compile-time base64 encoding**:

```elixir
defmodule MyModule.Web.Components.MyScripts do
  use Phoenix.Component

  # Read and encode JS at compile time
  @external_resource Path.join(__DIR__, "my_hooks.js")
  @js_source __DIR__ |> Path.join("my_hooks.js") |> File.read!()
  @js_base64 Base.encode64(@js_source)
  @js_version to_string(:erlang.phash2(@js_source))

  def my_scripts(assigns) do
    assigns =
      assigns
      |> assign(:js_base64, @js_base64)
      |> assign(:js_version, @js_version)

    ~H"""
    <div id="my-module-js-payload" hidden data-c={@js_base64} data-v={@js_version}></div>
    <script>
    (function(){
      var p=document.getElementById("my-module-js-payload");
      if(!p) return;
      var v=p.dataset.v;
      if(window.__MyModuleVersion===v) return;
      var old=document.getElementById("my-module-js-script");
      if(old) old.remove();
      window.__MyModuleVersion=v;
      var s=document.createElement("script");
      s.id="my-module-js-script";
      s.textContent=atob(p.dataset.c);
      document.head.appendChild(s);
    })();
    </script>
    """
  end
end
```

The JS source file lives alongside the component:

```javascript
// lib/my_module/web/components/my_hooks.js
(function() {
  "use strict";
  if (window.__MyModuleInitialized) return;
  window.__MyModuleInitialized = true;

  window.PhoenixKitHooks = window.PhoenixKitHooks || {};
  window.PhoenixKitHooks.MyEditor = {
    mounted() {
      this.handleEvent("load-data", (data) => { /* handle server events */ });
    },
    destroyed() { /* cleanup */ }
  };
})();
```

**Why base64 works better:**
- No HTML-significant characters in base64 → no morphdom corruption
- `document.createElement("script")` bypasses extension blocks on `eval()`
- Content hash (`@js_version`) ensures re-execution on LiveView navigations
- `@external_resource` tells Mix to track the JS file for recompilation

**Editing workflow:**
1. Edit `my_hooks.js`
2. From parent app: `mix deps.compile my_module --force`
3. Restart Phoenix server

### Loading vendor libraries from CDN

```javascript
var _libLoaded = false;
var _libCallbacks = [];

function ensureLibrary(callback) {
  if (typeof MyLibrary !== "undefined") { callback(); return; }
  _libCallbacks.push(callback);
  if (_libLoaded) return;
  _libLoaded = true;

  var link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = "https://cdn.jsdelivr.net/npm/my-library@1.0/dist/style.min.css";
  document.head.appendChild(link);

  var script = document.createElement("script");
  script.src = "https://cdn.jsdelivr.net/npm/my-library@1.0/dist/lib.min.js";
  script.onload = function() {
    var cbs = _libCallbacks.slice();
    _libCallbacks = [];
    cbs.forEach(function(cb) { cb(); });
  };
  document.head.appendChild(script);
}
```

### LiveView JS interop

```javascript
// JS → Elixir
this.pushEvent("save_content", {html: editor.getHtml()});

// Elixir → JS
this.handleEvent("load-content", ({html}) => { editor.setContent(html); });
```

```elixir
# In LiveView handle_event
{:noreply, push_event(socket, "load-content", %{html: content.html})}
```

---

## Enable / Disable Patterns

### Standard pattern (most modules)

```elixir
def enable_system do
  Settings.update_boolean_setting_with_module("analytics_enabled", true, "analytics")
end

def disable_system do
  Settings.update_boolean_setting_with_module("analytics_enabled", false, "analytics")
end
```

The third argument to `update_boolean_setting_with_module/3` is the module name for audit trail.

### With cascade (e.g., disabling a dependency)

If disabling your module must also disable a dependent module, do the primary operation first, then cascade:

```elixir
def disable_system do
  result = Settings.update_boolean_setting_with_module("analytics_enabled", false, "analytics")
  case result do
    {:ok, _} -> PhoenixKit.Modules.Reports.disable_system()
    error -> error
  end
  result
end
```

> **Note:** Two DB writes are not atomic. If the first succeeds and the second fails, state is inconsistent. This is an accepted limitation for low-risk cascades. Wrap in `Repo.transaction` if atomicity matters.

### With dashboard refresh

Some modules need to trigger a dashboard tab refresh after toggling:

```elixir
def enable_system do
  result = Settings.update_boolean_setting_with_module("analytics_enabled", true, "analytics")
  refresh_dashboard_tabs()
  result
end

defp refresh_dashboard_tabs do
  if Code.ensure_loaded?(PhoenixKit.Dashboard.Registry) and
       PhoenixKit.Dashboard.Registry.initialized?() do
    PhoenixKit.Dashboard.Registry.load_defaults()
  end
end
```

---

## Database and Migrations

### Table naming

Prefix all tables with `phoenix_kit_` followed by your module key:

```
phoenix_kit_my_module_items
phoenix_kit_my_module_categories
```

### Schemas

```elixir
defmodule MyModule.Schemas.Item do
  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Schemas.UUIDv7

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_my_module_items" do
    field :name, :string
    field :status, :string, default: "active"

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime)
  end
end
```

### Versioned migrations

See the hello_world README for a complete migration coordinator example with V01, V02, install task, and upgrade workflow.

Key rules:
- Version modules are immutable — never edit a shipped V01
- Use `create_if_not_exists` and `add_if_not_exists` for idempotency
- Track version via SQL comment: `COMMENT ON TABLE {table} IS '{version}'`
- Use `uuid_generate_v7()` for new UUID columns (not `gen_random_uuid()`)

### Foreign keys

Safe to reference:

| Table | Primary key |
|---|---|
| `phoenix_kit_users` | `uuid` (UUIDv7) |
| `phoenix_kit_user_roles` | `uuid` (UUIDv7) |
| `phoenix_kit_settings` | `uuid` (UUIDv7) |

Always reference `uuid`, not `id` (integer IDs are deprecated).

---

## External Hex Packages

Creating a standalone `phoenix_kit_analytics` hex package:

**1. Add `phoenix_kit` as a dependency:**

```elixir
# mix.exs
{:phoenix_kit, "~> 1.7"}
```

**2. Implement the behaviour:**

```elixir
defmodule PhoenixKitAnalytics do
  use PhoenixKit.Module
  # ... callbacks
end
```

**3. No config needed.** Auto-discovery finds it via beam scanning.

**4. Optional explicit config (backwards compat):**

```elixir
config :phoenix_kit, :modules, [PhoenixKitAnalytics]
```

**5. Create a Paths module** (see [Navigation System](#navigation-system-paths-module)).

**6. Routes require recompile** after adding the dependency.

---

## Pitfalls for Developers and Agents

These are the most common mistakes when building modules. Read this section carefully.

### `module_key` and `permission_metadata.key` must be identical

```elixir
# Correct
def module_key, do: "analytics"
def permission_metadata, do: %{key: "analytics", ...}

# Wrong — mismatch causes toggle events to break
def module_key, do: "analytics"
def permission_metadata, do: %{key: "analytics_module", ...}
```

### Tab `id` must be unique across ALL modules

```elixir
# Namespaced — good
id: :admin_analytics

# Too generic — will collide
id: :admin
id: :index
```

### Tab `permission` must match `module_key`

```elixir
# Correct
Tab.new!(permission: "analytics", ...)

# Missing — custom roles see the tab but get denied on click
Tab.new!(...)  # no :permission field
```

### Tab paths use hyphens

```elixir
# Correct
path: "magic-link"

# Wrong — will 404
path: "magic_link"
```

### `get_config/0` is called on every modules page render

```elixir
# Fast — single aggregate query
def get_config do
  %{enabled: enabled?(), count: repo().aggregate(MySchema, :count)}
end

# Slow — N queries
def get_config do
  %{enabled: enabled?(), items: repo().all(MySchema)}
end
```

### Settings keys must be unique across all modules

```elixir
# Namespaced — good
"analytics_enabled"
"analytics_retention_days"

# Generic — will conflict
"enabled"
"retention_days"
```

### `enable_system`/`disable_system` must return a recognized shape

Valid returns: `:ok`, `{:ok, anything}`, `{:error, reason}`. Other values (e.g., `false`, `nil`) will be treated as errors.

### Children run regardless of enabled state

`children/0` are started unconditionally. Check `enabled?()` inside `start_link/1` and return `:ignore` if the module should only run when enabled.

### Do not call `ModuleRegistry` during `children/0`

`static_children/0` runs before the registry GenServer starts.

### Modules are disabled by default

All modules default to disabled. Enable via the admin UI or programmatically: `MyModule.enable_system()`.

### `enabled?/0` must rescue

Called before migrations run. Without `rescue`, crashes on startup:

```elixir
def enabled? do
  Settings.get_boolean_setting("my_module_enabled", false)
rescue
  _ -> false
end
```

### JS hooks require full page load

Inline `<script>` tags only execute on full page loads (`redirect/2`), not LiveView navigations (`navigate/2`). If your page has JS hooks, ensure entry points use `redirect/2`.

### Base64 JS requires dep recompile

After editing JS source files, run `mix deps.compile my_module --force` from the parent app and restart the server. Dev reloader only watches the app's own modules, not deps.

### Do not use `lib/phoenix_kit/modules/` for new modules

New modules belong in `lib/modules/`. The legacy `lib/phoenix_kit/modules/` path is deprecated.

---

## on_mount Hooks (Authentication & Authorization)

PhoenixKit provides `on_mount` hooks that handle authentication and authorization for LiveViews. These are automatically applied to admin LiveViews via the `live_session` configuration, but you can also use them in custom LiveViews.

### Available hooks

| Hook | Purpose |
|---|---|
| `:phoenix_kit_mount_current_user` | Mounts the current user from session token |
| `:phoenix_kit_mount_current_scope` | Mounts user + scope (role, permissions) |
| `:phoenix_kit_ensure_authenticated` | Requires authentication, redirects to login if not |
| `:phoenix_kit_ensure_authenticated_scope` | Requires scope-based authentication |
| `:phoenix_kit_redirect_if_user_is_authenticated` | Redirects away if already logged in (for login pages) |
| `:phoenix_kit_redirect_if_authenticated_scope` | Scope-based redirect if authenticated |
| `:phoenix_kit_ensure_admin` | Requires admin role (Owner or Admin) |
| `:phoenix_kit_ensure_owner` | Requires Owner role specifically |
| `:phoenix_kit_ensure_module_access` | Checks module permission via tab `:permission` field |

### How admin LiveViews use hooks

Admin LiveViews (those routed via tab `live_view` fields) are automatically placed inside a `live_session` that applies:

1. `:phoenix_kit_mount_current_scope` — loads the user and scope from session
2. `:phoenix_kit_ensure_authenticated_scope` — redirects to login if not authenticated
3. `:phoenix_kit_ensure_admin` — redirects if not Owner/Admin
4. `:phoenix_kit_ensure_module_access` — checks the tab's `:permission` field against the user's role

This means **you don't need to add auth checks** in your admin LiveViews — they're handled automatically. The scope is available in all admin LiveViews via `@phoenix_kit_current_scope`.

### Using hooks in custom LiveViews

If your module has non-admin pages (e.g., user-facing dashboard tabs), you can reference these hooks:

```elixir
# In your route module or router
live_session :my_module_user,
  on_mount: [
    {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope},
    {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}
  ] do
  live "/my-module/dashboard", MyModule.Web.UserDashboardLive, :index
end
```

---

## ModuleRegistry Query API

The `PhoenixKit.ModuleRegistry` provides runtime query functions for introspecting registered modules. These are primarily used by PhoenixKit internals, but can be useful for debugging or building cross-module features.

### Module queries

```elixir
ModuleRegistry.all_modules()           # All registered modules (internal + external)
ModuleRegistry.enabled_modules()       # Only currently enabled modules
ModuleRegistry.get_by_key("analytics") # Find module by key string (nil if not found)
```

### Tab collection

```elixir
ModuleRegistry.all_admin_tabs()          # Admin tabs from all modules
ModuleRegistry.all_settings_tabs()       # Settings tabs from all modules
ModuleRegistry.all_user_dashboard_tabs() # User dashboard tabs from all modules
```

### Permission queries

```elixir
ModuleRegistry.all_permission_metadata() # Permission metadata from all modules
ModuleRegistry.all_feature_keys()        # List of all module keys
ModuleRegistry.permission_labels()       # %{"analytics" => "Analytics", ...}
ModuleRegistry.permission_icons()        # %{"analytics" => "hero-chart-bar", ...}
ModuleRegistry.permission_descriptions() # %{"analytics" => "Traffic and usage...", ...}
ModuleRegistry.feature_enabled_checks()  # %{"analytics" => {Module, :enabled?}, ...}
```

### Module filtering

```elixir
ModuleRegistry.all_route_modules()       # Modules with route_module/0 defined
ModuleRegistry.modules_with_migrations() # Modules with migration_module/0 defined
ModuleRegistry.all_children()            # Supervisor child specs from all modules
```

### Runtime inspection (debugging)

```elixir
# Check if registry has initialized
ModuleRegistry.initialized?()

# Register/unregister modules at runtime (rare, mainly for testing)
ModuleRegistry.register(MyModule)
ModuleRegistry.unregister(MyModule)
```

---

## Reference Files

| File | Purpose |
|------|---------|
| `lib/phoenix_kit/module.ex` | Behaviour definition, callbacks, `use` macro |
| `lib/phoenix_kit/module_registry.ex` | Registry GenServer, all query API |
| `lib/phoenix_kit/module_discovery.ex` | Beam file auto-discovery |
| `lib/phoenix_kit/dashboard/tab.ex` | Tab struct with 40+ fields |
| `lib/phoenix_kit/dashboard/README.md` | Tab system full reference (badges, presence, context) |
| `lib/phoenix_kit/supervisor.ex` | Where `static_children/0` is called |
| `lib/phoenix_kit_web/integration.ex` | Compile-time route generation |
| `lib/phoenix_kit_web/live/modules.ex` | Admin modules page LiveView |
| **External examples** | |
| `phoenix_kit_hello_world/` | Minimal plugin template with comprehensive README |
| `phoenix_kit_document_creator/` | Full-featured plugin (13 tabs, migrations, base64 JS, shared components) |
| **Internal module examples** | |
| `lib/modules/seo/seo.ex` | Minimal — settings tab only |
| `lib/modules/db/db.ex` | Supervisor child and admin tab |
| `lib/modules/maintenance/maintenance.ex` | Two enable levels (module vs mode) |
| `lib/modules/billing/billing.ex` | Cascade to shop module |
