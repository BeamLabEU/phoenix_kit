# PhoenixKit Plugin System Architecture

**Date**: 2026-02-23 (updated 2026-02-24)
**Status**: Phase 1 complete, Phase 2 (zero-config auto-discovery) in research

## Overview

PhoenixKit modules can be independently installable as separate hex packages. This document covers the plugin infrastructure, the external module registration pattern, and the deep research into auto-discovery approaches.

## What Was Built (Phase 1)

### PhoenixKit.Module Behaviour

All 21 internal modules implement `use PhoenixKit.Module`, which provides:

**Required callbacks:**
- `module_key/0` — unique string identifier (e.g., `"tickets"`)
- `module_name/0` — human-readable name (e.g., `"Tickets"`)
- `enabled?/0` — whether the module is currently enabled
- `enable_system/0` — enable the module
- `disable_system/0` — disable the module

**Optional callbacks (defaults provided by macro):**
- `get_config/0` — module configuration map
- `permission_metadata/0` — `%{key, label, icon, description}` for permissions matrix
- `admin_tabs/0` — admin sidebar tab definitions (Tab structs with optional `live_view` field)
- `settings_tabs/0` — settings subtab definitions
- `user_dashboard_tabs/0` — user dashboard tab definitions
- `children/0` — supervisor child specs
- `route_module/0` — route module for complex multi-page routing
- `version/0` — module version string

### PhoenixKit.ModuleRegistry

GenServer using `:persistent_term` for zero-cost reads. Loads modules from two sources:
1. **Internal modules** — hardcoded list in `internal_modules/0` (the ONE place that enumerates all 21 bundled modules)
2. **External modules** — currently `Application.get_env(:phoenix_kit, :modules, [])`, targeted for replacement with auto-discovery

Provides aggregated queries: `all_admin_tabs/0`, `all_settings_tabs/0`, `all_permission_metadata/0`, `feature_enabled_checks/0`, `get_by_key/1`, etc.

### Core Files Refactored

Seven core files that previously hardcoded references to all 21 modules now use the registry:

| File | What Changed |
|------|-------------|
| `permissions.ex` | `@feature_module_keys`, `@feature_enabled_checks`, label/icon/desc maps → runtime registry queries |
| `admin_tabs.ex` | Module tabs → `ModuleRegistry.all_admin_tabs()`, settings tabs split |
| `registry.ex` | Hardcoded `tickets_enabled?/billing_enabled?/shop_enabled?` → `enabled_user_dashboard_tabs()` via registry |
| `modules.ex` | 21 explicit aliases → generic registry iteration with `@module_configs` map |
| `supervisor.ex` | 5 hardcoded module children → `ModuleRegistry.static_children()` |
| `admin_nav.ex` | Added `Code.ensure_loaded?` guards for Languages module |
| `integration.ex` | `safe_route_call/3` guards, `compile_module_admin_routes/0` for auto-route generation |

## How External Modules Work (Current — Phase 1)

### Installation (Parent App)

```elixir
# mix.exs — add the dep
{:phoenix_kit_hello_world, path: "../phoenix_kit_hello_world"}

# config.exs — register the module (ONE line)
config :phoenix_kit, :modules, [PhoenixKitHelloWorld]
```

Everything else is auto-discovered from the module's callbacks:
- **Admin sidebar tab** — from `admin_tabs/0`
- **Admin route** — from `live_view` field on the tab struct
- **Permission key** — from `permission_metadata/0`
- **Module card on /admin/modules** — from `get_config/0`
- **Enable/disable** — from `enable_system/0` / `disable_system/0`

### What the Module Provides

```elixir
defmodule PhoenixKitHelloWorld do
  use PhoenixKit.Module

  def module_key, do: "hello_world"
  def module_name, do: "Hello World"
  def enabled?, do: Settings.get_boolean_setting("hello_world_enabled", false)
  def enable_system, do: Settings.update_boolean_setting_with_module("hello_world_enabled", true, module_key())
  def disable_system, do: Settings.update_boolean_setting_with_module("hello_world_enabled", false, module_key())

  def permission_metadata do
    %{key: "hello_world", label: "Hello World", icon: "hero-hand-raised",
      description: "Demo module"}
  end

  def admin_tabs do
    [%Tab{
      id: :admin_hello_world,
      label: "Hello World",
      icon: "hero-hand-raised",
      path: "/admin/hello-world",
      priority: 640,
      level: :admin,
      permission: "hello_world",
      group: :admin_modules,
      live_view: {PhoenixKitHelloWorld.Web.HelloLive, :index}
    }]
  end
end
```

### Route Generation Flow

Admin routes for external modules are generated at compile time:

1. Router macro `phoenix_kit_admin_routes/1` calls `compile_custom_admin_routes/1`
2. `compile_custom_admin_routes/1` collects routes from TWO sources:
   - `admin_dashboard_tabs` config (existing mechanism for parent app custom tabs)
   - `:modules` config → calls each module's `admin_tabs/0` → filters tabs with `live_view` field
3. For each tab with `live_view: {Module, :action}`, generates: `live "/admin/hello-world", Module, :action`
4. Routes are unquoted into the admin live_session

For modules with complex multi-page routes, the `route_modules` config provides a hook:
```elixir
config :phoenix_kit, :route_modules, [MyApp.Routes.ComplexRoutes]
```
These modules implement `admin_routes/0` and/or `public_routes/1`.

---

## Phase 2: Zero-Config Auto-Discovery (Research)

### The Goal

Eliminate the config line entirely. The developer experience should be:

```elixir
# mix.exs — add the dep. That's it.
{:phoenix_kit_hello_world, path: "../phoenix_kit_hello_world"}
```

No `config :phoenix_kit, :modules` line needed.

### What's Compile-Time vs Runtime

| Component | When? | Notes |
|-----------|-------|-------|
| Admin sidebar tabs | **Runtime** | Registry-driven, already dynamic |
| Permission keys | **Runtime** | Registry-driven, already dynamic |
| Module cards on /admin/modules | **Runtime** | Registry-driven, already dynamic |
| Enable/disable | **Runtime** | Registry-driven, already dynamic |
| **Routes** | **Compile-time** | Phoenix constraint — the ONLY thing requiring compile-time knowledge |

Routes are the sole constraint. Phoenix routes are compiled into Plug dispatch tables. There is no runtime route registration in Phoenix. The `live` macro must expand at compile time within a `live_session` block.

### Why the Config Line Was Needed

`@after_compile` hooks and `Application.put_env` are process state. They reset every `mix` invocation. On incremental builds where deps aren't recompiled, those hooks never fire, so Application env is empty. Config is the only thing re-evaluated every time, regardless of what gets recompiled.

But there's another way to bridge compilation sessions: **beam files persist on disk.**

### How Elixir Protocol Consolidation Works (Key Insight)

Protocol consolidation is the ONLY true auto-discovery mechanism in the Elixir ecosystem. It solves the exact same problem we have:

1. You implement a protocol — no registration step needed
2. Elixir scans `.beam` files using `:beam_lib.chunks/2`
3. It reads **persisted module attributes** directly from the binary — without loading the module
4. Pure file I/O, very fast

From Elixir's source (`lib/elixir/lib/protocol.ex`):

```elixir
# Protocol.extract_impls/2 — finds implementations WITHOUT loading modules
def extract_impls(protocol, paths) do
  prefix = Atom.to_charlist(protocol) ++ [?.]
  extract_matching_by_attribute(paths, prefix, fn _mod, attributes ->
    case attributes[:__impl__] do
      [protocol: ^protocol, for: for] -> for
      _ -> nil
    end
  end)
end

# The core: reads attributes from .beam file without loading
defp extract_from_beam(file, callback) do
  case :beam_lib.chunks(file, [:attributes]) do
    {:ok, {module, [attributes: attributes]}} ->
      callback.(module, attributes)
    _ -> nil
  end
end
```

### How Every Major Elixir Library Handles Discovery

| Library | Discovery Method | Auto? |
|---------|-----------------|-------|
| Oban | Runtime string resolution from DB | No — explicit config |
| Commanded | Explicit router dispatch declarations | No |
| Absinthe | Explicit `import_types` + compile callbacks | No |
| Broadway | Direct module in `start_link` config | No |
| Ecto | `:ecto_repos` config key | No |
| Nerves | `MIX_TARGET` env var | No |
| Ash/Spark | `config :my_app, :ash_domains` + extensions in `use` | No |
| **Elixir Protocols** | **`:beam_lib.chunks` scan of `.beam` files** | **Yes** |

Protocol consolidation is the only true auto-discovery. Everything else uses explicit configuration.

### Approach Comparison

#### Approach A: Naive Beam Scanning (Original)

Scan all loaded applications for modules implementing `PhoenixKit.Module`.

```elixir
def discover_phoenix_kit_modules do
  for {app, _, _} <- :application.loaded_applications(),
      {:ok, modules} <- [:application.get_key(app, :modules)],
      mod <- modules,
      implements_behaviour?(mod, PhoenixKit.Module) do
    mod
  end
end
```

**Pros**: Simple.
**Cons**: Loads every module in every dep into the VM. Slow. `:application.loaded_applications()` may be unreliable during compilation. Elixir 1.19+ no longer auto-loads modules after compilation, making `Code.ensure_loaded` checks even more important.

#### Approach B: Custom Mix Compiler

Register a custom Mix compiler that runs before Elixir compilation.

```elixir
def project do
  [compilers: [:phoenix_kit_modules | Mix.compilers()], ...]
end
```

**Pros**: Runs every time. Clean separation.
**Cons**: Requires parent app to modify their `mix.exs` (still a config step, just different). More infrastructure.

#### Approach C: Protocol-Based Discovery

Define a protocol, use consolidation for discovery.

**Pros**: Built-in infrastructure.
**Cons**: Protocols dispatch on types, not module identity. Consolidation happens AFTER compilation (too late for route generation). Would need a struct per plugin. Non-idiomatic.

#### Approach D: Catch-All Route + Runtime Dispatch

One generic route, dynamic dispatch at runtime:

```elixir
live "/admin/m/:module_key/*path", PhoenixKitWeb.PluginLive, :index
```

`PluginLive` looks up the module from the registry and renders its LiveView via `live_render/3`.

**Pros**: Truly zero config, fully dynamic.
**Cons**: Creates nested LiveViews (child has own socket/process). URL structure changes to `/admin/m/hello_world` instead of `/admin/hello-world`. No named route helpers for plugin routes. Navigation within plugin is limited (child can't `push_navigate`). Complex multi-page plugins would be very constrained.

#### Approach E: Targeted Beam Scanning with Persisted Attributes (RECOMMENDED)

**The Protocol Consolidation Pattern applied to PhoenixKit.** This is the same mechanism Elixir itself uses for protocols, adapted for our use case.

**Step 1 — Persist a marker attribute in `use PhoenixKit.Module`:**

```elixir
defmacro __using__(_opts) do
  quote do
    @behaviour PhoenixKit.Module

    # Persist marker in .beam file — survives across compilations
    Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
    @phoenix_kit_module true

    # ... defaults ...
  end
end
```

**Step 2 — Targeted discovery function (works at both compile time and runtime):**

```elixir
defmodule PhoenixKit.ModuleDiscovery do
  @doc """
  Discovers external PhoenixKit modules by scanning beam files.
  Same pattern as Elixir's Protocol.extract_impls/2.

  Only scans deps that depend on :phoenix_kit (fast, targeted).
  Reads persisted attributes via :beam_lib.chunks/2 (no module loading).
  """
  def discover_external_modules do
    phoenix_kit_dependent_apps()
    |> Enum.flat_map(&modules_for_app/1)
    |> Enum.filter(&phoenix_kit_module?/1)
  end

  # Only check apps that explicitly depend on :phoenix_kit
  defp phoenix_kit_dependent_apps do
    for {app, _, _} <- :application.loaded_applications(),
        app != :phoenix_kit,
        depends_on_phoenix_kit?(app) do
      app
    end
  end

  defp depends_on_phoenix_kit?(app) do
    case :application.get_key(app, :applications) do
      {:ok, apps} -> :phoenix_kit in apps
      _ -> false
    end
  end

  # Get the ebin path for an app and list its beam files
  defp modules_for_app(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      _ -> []
    end
  end

  # Check for @phoenix_kit_module attribute via :beam_lib (no module loading)
  defp phoenix_kit_module?(mod) do
    case :beam_lib.chunks(mod, [:attributes]) do
      {:ok, {_, [{:attributes, attrs}]}} ->
        attrs[:phoenix_kit_module] == [true]
      _ ->
        false
    end
  end
end
```

**Step 3 — Use in both compile-time (router) and runtime (registry):**

```elixir
# In compile_module_admin_routes/0 (compile-time, router macro):
defp compile_module_admin_routes do
  PhoenixKit.ModuleDiscovery.discover_external_modules()
  |> Enum.flat_map(fn mod ->
    case Code.ensure_compiled(mod) do
      {:module, _} ->
        if function_exported?(mod, :admin_tabs, 0) do
          mod.admin_tabs()
          |> Enum.filter(&tab_has_live_view?/1)
          |> Enum.map(&tab_struct_to_route/1)
        else
          []
        end
      _ -> []
    end
  end)
end

# In ModuleRegistry (runtime, GenServer init):
def load_modules do
  internal = internal_modules()
  external = PhoenixKit.ModuleDiscovery.discover_external_modules()
  Enum.uniq(internal ++ external)
end
```

**Why this works across all compilation scenarios:**

| Scenario | Beam files exist? | Discovery works? |
|----------|-------------------|-----------------|
| Clean build (`mix compile`) | Yes — deps compile first | Yes |
| Incremental build (parent changed) | Yes — cached in `_build/` | Yes |
| `mix deps.compile --force` | Yes — recompiled | Yes |
| `mix deps.clean + compile` | Yes — recompiled | Yes |

Beam files in `_build/dev/lib/<app>/ebin/` persist across compilation runs. Unlike Application env or `@after_compile` hooks, they don't reset. This is exactly why protocol consolidation is reliable.

**Performance characteristics:**

| Step | Cost | Notes |
|------|------|-------|
| `loaded_applications()` | ~0.01ms | Returns cached OTP data |
| Filter deps depending on phoenix_kit | ~0.1ms | Checks `.app` file deps list, typically 5-20 apps |
| `get_key(app, :modules)` per dep | ~0.01ms | Reads `.app` file |
| `:beam_lib.chunks(mod, [:attributes])` per module | ~0.05ms | Pure file I/O, no code execution |
| **Total for 1 plugin dep with 10 modules** | **~1ms** | Negligible |

**Comparison with explicit config:**

| Aspect | Config line | Beam scanning |
|--------|------------|---------------|
| User effort | One line in config.exs | None — just add the dep |
| Reliability | 100% — config is always evaluated | 99.9% — beam files always exist for compiled deps |
| Debuggability | Explicit — developer sees the list | Implicit — need `discover_external_modules()` to inspect |
| Performance | Zero overhead | ~1ms per external dep |
| Precedent | Ash, Ecto, Oban, Broadway | Elixir protocol consolidation |

#### Approach F: Compiler Tracer

Use Elixir's compiler tracer to observe `{:on_module, bytecode, :none}` events as modules compile:

```elixir
defmodule PhoenixKit.ModuleTracer do
  def trace({:on_module, bytecode, :none}, env) do
    case :beam_lib.chunks(bytecode, [:attributes]) do
      {:ok, {_module, [attributes: attrs]}} ->
        if attrs[:phoenix_kit_module] do
          :ets.insert(:phoenix_kit_discovered_modules, {env.module})
        end
      _ -> :ok
    end
    :ok
  end
  def trace(_event, _env), do: :ok
end
```

**Pros**: Fires in real-time as modules compile. Can detect modules without file scanning.
**Cons**: Parent app must configure the tracer in `mix.exs` (`elixirc_options: [tracers: [PhoenixKit.ModuleTracer]]`). That's still a config step — just different. Tracer only fires during compilation, not available at runtime. Has the same incremental-build problem as `@after_compile` (tracer doesn't fire for cached deps).

#### Approach G: Application Env in `.app` spec

Module declares itself in its `mix.exs` application env:

```elixir
# In phoenix_kit_hello_world/mix.exs
def application do
  [extra_applications: [:logger],
   env: [phoenix_kit_module: PhoenixKitHelloWorld]]
end
```

Discovery reads from each app's env:

```elixir
for {app, _, _} <- :application.loaded_applications(),
    {:ok, mod} <- [Application.get_env(app, :phoenix_kit_module)] do
  mod
end
```

**Pros**: No beam scanning. Fast. Reliable (`.app` files persist).
**Cons**: Module author must add a line to their `mix.exs` (they'd already be doing this for a PhoenixKit plugin). Less automatic than beam scanning. Only one module per app (could use a list instead).

### The Rails Comparison

Rails engines work via Ruby's `inherited` class hook — when any class inherits from `Rails::Engine`, Ruby's runtime calls `inherited(subclass)` which adds it to a global array. This is true auto-discovery.

This works in Ruby because class definitions are imperative side effects in a single-threaded interpreter. Elixir's module definitions are compiled (often in parallel), and there's no `inherited` hook. The closest Elixir equivalent is the persisted-attribute + beam_lib scan approach.

### Recommendation

**Approach E (Targeted Beam Scanning with Persisted Attributes)** is the elegant solution:

1. It's how Elixir itself solves the exact same problem for protocols
2. Zero config for the user — `use PhoenixKit.Module` is all you need
3. One mechanism works for both compile-time (routes) and runtime (registry)
4. Fast and targeted — only scans deps that depend on phoenix_kit
5. Reliable across all compilation scenarios — beam files persist on disk

**Fallback strategy:** If beam scanning proves unreliable in any edge case, the system can fall back to `Application.get_env(:phoenix_kit, :modules, [])`. This means existing installations with the config line continue to work, while new installations get zero-config.

```elixir
def discover_external_modules do
  # Primary: beam scanning (zero-config)
  scanned = scan_beam_files_for_phoenix_kit_modules()

  # Fallback: explicit config (backwards compatible)
  configured = Application.get_env(:phoenix_kit, :modules, [])

  Enum.uniq(scanned ++ configured)
end
```

### Open Questions

1. **Is `:application.loaded_applications()` reliable during router macro expansion?** Deps should be loaded by then, but needs testing across Elixir versions (1.16, 1.17, 1.18, 1.19).

2. **Can `:beam_lib.chunks(mod_atom, [:attributes])` resolve the module atom to a beam file during compilation?** When passed an atom, `:beam_lib` uses `:code.which(mod)` to find the file. This may not work if the module isn't on the code path yet. Alternative: scan `_build/` directory paths directly.

3. **Performance at scale** — If a project has 50 deps and 5 depend on phoenix_kit, scanning ~50-200 modules is trivial. But what about umbrella apps with many apps?

4. **Recompilation triggers** — If a new plugin dep is added, does the parent app's router recompile? It should, since adding a dep triggers a full recompile. But needs verification.

---

## File Locations

| Component | Path |
|-----------|------|
| Module behaviour | `lib/phoenix_kit/module.ex` |
| Module registry | `lib/phoenix_kit/module_registry.ex` |
| Internal module list | `lib/phoenix_kit/module_registry.ex` → `internal_modules/0` |
| Route generation | `lib/phoenix_kit_web/integration.ex` → `compile_module_admin_routes/0` |
| Tab struct (with live_view) | `lib/phoenix_kit/dashboard/tab.ex` |
| Hello World demo | `../phoenix_kit_hello_world/` |

## Extracting a Bundled Module

When extracting a module (e.g., Tickets) to its own hex package:

1. Remove from `internal_modules/0` in `module_registry.ex`
2. Move code to new package
3. Add `use PhoenixKit.Module` with all callbacks (already done)
4. Add `live_view` field to admin tabs that need routes
5. Parent app adds to deps — that's it (if using beam scanning) or + `config :phoenix_kit, :modules, [PhoenixKit.Modules.Tickets]` (if using config fallback)

The module's admin tabs, permissions, settings tabs, supervisor children, and user dashboard tabs all come from callbacks — no core PhoenixKit code changes needed.

## Appendix: Technical Deep-Dive

### `:beam_lib.chunks/2` — Reading Beam Files Without Loading

`:beam_lib` reads specific chunks from `.beam` files using IFF-style chunk headers with offsets. It can seek directly to the attributes chunk. No code execution, no module loading, no code server interaction. Pure I/O + binary parsing.

```elixir
# Three input forms:
:beam_lib.chunks(ModuleAtom, [:attributes])        # Uses :code.which() to find file
:beam_lib.chunks('/path/to/file.beam', [:attributes]) # Direct file path
:beam_lib.chunks(<<bytecode_binary>>, [:attributes])  # Raw binary

# Returns:
{:ok, {ModuleName, [{:attributes, keyword_list}]}}
# where keyword_list contains persisted attributes like:
# [behaviour: [PhoenixKit.Module], phoenix_kit_module: [true], vsn: [...]]
```

### Persisted Module Attributes

`Module.register_attribute(__MODULE__, :name, persist: true)` tells the Elixir compiler to write the attribute value into the `.beam` file's `"Attr"` chunk. Non-persisted attributes exist only during compilation and are discarded.

At runtime, persisted attributes can be read two ways:
1. `MyModule.__info__(:attributes)` — requires module to be loaded
2. `:beam_lib.chunks(mod, [:attributes])` — does NOT require module to be loaded

### Elixir 1.19 Impact

Elixir 1.19 (Oct 2025) changed module loading: modules no longer auto-load after compilation. This means `:code.all_loaded/0` returns fewer results during compilation. The beam_lib approach (scanning files on disk) is unaffected and becomes even more attractive since it doesn't depend on load state.

### Compiler Tracer Events (Reference)

| Event | Fires when |
|-------|-----------|
| `{:on_module, bytecode, :none}` | Module finishes compilation |
| `{:remote_macro, meta, mod, name, arity}` | Remote macro invoked (including `use`) |
| `{:remote_function, meta, mod, name, arity}` | Remote function called |
| `{:struct_expansion, meta, mod, keys}` | Struct expanded |
| `{:compile_env, app, path, return}` | `Application.compile_env` called |

Tracers must include a catch-all `def trace(_event, _env), do: :ok` for forward compatibility.
