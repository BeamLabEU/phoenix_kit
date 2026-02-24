# Module System: Building PhoenixKit Modules

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [How Auto-Discovery Works](#how-auto-discovery-works)
- [Required Callbacks](#required-callbacks)
- [Optional Callbacks](#optional-callbacks)
- [Folder Structure Convention](#folder-structure-convention)
- [Admin Tabs](#admin-tabs)
- [Settings Tabs](#settings-tabs)
- [Permission Metadata](#permission-metadata)
- [Supervisor Children](#supervisor-children)
- [Route Integration](#route-integration)
- [Enable / Disable Patterns](#enable--disable-patterns)
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

- **`PhoenixKit.Module`** — the behaviour contract (5 required + 8 optional callbacks)
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
def enabled?, do: Settings.get_boolean_setting("analytics_enabled", false)
```

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

---

## Folder Structure Convention

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

---

## Admin Tabs

Admin sidebar tabs are defined in `admin_tabs/0` as `Tab.new!/1` structs.

```elixir
def admin_tabs do
  [
    Tab.new!(
      id: :admin_analytics,           # Atom — must be unique across ALL modules
      label: "Analytics",
      icon: "hero-chart-bar",
      path: "/admin/analytics",       # Must start with "/"
      priority: 600,                  # Higher = appears higher in group
      level: :admin,                  # Always :admin for admin sidebar
      permission: "analytics",        # Must match module_key and permission_metadata.key
      match: :prefix,                 # :prefix or :exact
      group: :admin_modules           # :admin_main or :admin_modules
    )
  ]
end
```

**Priority reference** (existing modules, for insertion guidance):

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

**Groups:**
- `:admin_main` — core platform tabs (Dashboard, Users, Media, Settings)
- `:admin_modules` — feature module tabs (everything else)

**Match modes:**
- `:prefix` — tab highlighted for the path and all sub-paths (use for modules with sub-pages)
- `:exact` — tab highlighted only for the exact path

**Paths use hyphens, not underscores:** `/admin/magic-link`, not `/admin/magic_link`.

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

**How permissions work:**

- **Owner** — always full access, hard-coded, cannot be restricted
- **Admin** — all 25 permission keys by default, including new module keys
- **Custom roles** — no permissions initially; must be granted explicitly via UI or `Permissions.set_permissions/3`

Without `permission_metadata/0` (returns `nil`), the module has no dedicated permission key. Admins and owners still see it; custom roles never will.

**Startup validation:** The registry warns at boot if `permission_metadata.key` ≠ `module_key`. This mismatch causes toggle events and permission checks to use different keys, which is always a bug.

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

**Important details:**

- `static_children/0` is called from `PhoenixKit.Supervisor.init/1` — before the ModuleRegistry GenServer starts. It builds the list directly from the internal module list. This means `children/0` must not rely on the registry being initialized.
- Individual module failures in `children/0` are caught by `static_children/0` and logged as warnings — they do not crash the supervisor.
- Children start with the PhoenixKit supervisor regardless of whether the module is "enabled". If you only want a process running when enabled, check `enabled?/0` inside the child's `start_link/1` and return `:ignore`.

---

## Route Integration

If your module has admin LiveViews, declare them as tabs with a `live_view` field (for external packages) or register routes directly in `phoenix_kit_web/router.ex` (for internal modules).

**For internal modules:**

Add routes directly to the router. The module's admin tab `path` must match the route path.

**For external packages:**

Implement `route_module/0` pointing to a module that contains a `phoenix_kit_admin_routes/0` macro:

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
  # Cascade only after primary succeeds
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

  def module_key, do: "analytics"
  def module_name, do: "Analytics"
  # ... rest of callbacks
end
```

**3. No config needed.** Auto-discovery finds the module via beam scanning because your app depends on `:phoenix_kit`.

**4. Optional explicit config (backwards compat):**

```elixir
config :phoenix_kit, :modules, [PhoenixKitAnalytics]
```

**5. Routes require recompile** after adding the dependency (standard Phoenix constraint).

---

## Pitfalls for Developers and Agents

These are the most common mistakes when building modules. Read this section carefully.

### `module_key` and `permission_metadata.key` must be identical

```elixir
# ✅ Correct
def module_key, do: "analytics"
def permission_metadata, do: %{key: "analytics", ...}

# ❌ Wrong — mismatch causes toggle events to break
def module_key, do: "analytics"
def permission_metadata, do: %{key: "analytics_module", ...}
```

The registry warns at startup but does not crash. The symptom is that enabling/disabling the module works in the UI but permission checks use the wrong key.

### Tab `id` must be unique across ALL modules

Tab IDs are atoms and must be globally unique. A collision causes unpredictable sidebar behavior.

```elixir
# ✅ Namespaced
id: :admin_analytics

# ❌ Too generic — likely to collide
id: :admin
id: :index
```

### Tab `permission` must match `module_key`

```elixir
# ✅ Correct — custom roles can access
Tab.new!(permission: "analytics", ...)

# ❌ Missing permission — custom roles see the tab but get denied on click
Tab.new!(...)  # no :permission field
```

The registry warns at startup for any module that has `permission_metadata` but has tabs without `:permission`.

### Tab paths use hyphens

```elixir
# ✅ Correct
path: "/admin/magic-link"

# ❌ Wrong — will 404
path: "/admin/magic_link"
```

### `get_config/0` is called on every modules page render

`get_config/0` is not cached by the framework. Every admin who opens the Modules admin page calls it for every module. Do not do slow queries or N+1 DB calls here. Aggregate with a single query or read from cache.

```elixir
# ✅ Fast — single aggregate query
def get_config do
  %{enabled: enabled?(), count: repo().aggregate(MySchema, :count)}
end

# ❌ Slow — N queries
def get_config do
  %{enabled: enabled?(), items: repo().all(MySchema)}
end
```

### Settings keys must be unique across all modules

Settings are stored globally in the settings table. If two modules use the same setting key, they will interfere with each other.

```elixir
# ✅ Namespaced
"analytics_enabled"
"analytics_retention_days"

# ❌ Generic — will conflict
"enabled"
"retention_days"
```

### `enable_system`/`disable_system` must return a recognized shape

The LiveView normalizes results via `normalize_result/1`. Valid returns:

```elixir
:ok
{:ok, anything}
{:error, reason}
```

Other return values (e.g., `false`, `nil`) will be treated as errors in the UI.

### Children run regardless of enabled state

`children/0` are started unconditionally by the PhoenixKit supervisor. If your worker should only run when the module is enabled, return `:ignore` from `start_link/1`:

```elixir
def start_link(_opts) do
  if PhoenixKit.Modules.Analytics.enabled?() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  else
    :ignore
  end
end
```

### Do not call `ModuleRegistry` during `children/0`

`static_children/0` runs before the registry GenServer starts. Any call to `ModuleRegistry.*` inside `children/0` will fail or return empty results.

### Modules are disabled by default

All modules default to disabled (`enabled?/0` returns `false`). Enable via the admin UI at `/{prefix}/admin/modules` or programmatically:

```elixir
PhoenixKit.Modules.Analytics.enable_system()
```

### Do not use `lib/phoenix_kit/modules/` for new modules

New modules belong in `lib/modules/`. The legacy `lib/phoenix_kit/modules/` path is deprecated.

---

## Reference Files

| File | Purpose |
|------|---------|
| `lib/phoenix_kit/module.ex` | Behaviour definition, callbacks, `use` macro |
| `lib/phoenix_kit/module_registry.ex` | Registry GenServer, all query API |
| `lib/phoenix_kit/module_discovery.ex` | Beam file auto-discovery |
| `lib/phoenix_kit/supervisor.ex` | Where `static_children/0` is called |
| `lib/phoenix_kit_web/integration.ex` | Compile-time route generation |
| `lib/phoenix_kit_web/live/modules.ex` | Admin modules page LiveView |
| `lib/modules/seo/seo.ex` | Minimal module — settings tab only, no admin tab |
| `lib/modules/db/db.ex` | Module with supervisor child and admin tab |
| `lib/modules/tickets/tickets.ex` | Module with admin + settings tabs and stats in `get_config` |
| `lib/modules/maintenance/maintenance.ex` | Module with two enable levels (module vs mode) |
| `lib/modules/billing/billing.ex` | Module with cascade to shop module |
| `lib/phoenix_kit/dashboard/README.md` | Tab system full reference |
| `lib/phoenix_kit/dashboard/ADMIN_README.md` | Admin sidebar customization |
