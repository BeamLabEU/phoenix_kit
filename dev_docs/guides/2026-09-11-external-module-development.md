# External Module Development

Everything about writing a standalone `phoenix_kit_*` module package:
discovery, assets, routes. The two landmines (the `extra_applications`
requirement and the inline-hook ban) are also kept in the root `AGENTS.md`.

## Auto-Discovery

Standalone module packages **must** include `:phoenix_kit` in `extra_applications`:

```elixir
def application, do: [extra_applications: [:logger, :phoenix_kit]]
```

Without this, `PhoenixKit.ModuleDiscovery` won't find it and routes 404. Template: `phoenix_kit_hello_world`.

## Tailwind CSS for External Modules

Modules with UI implement `css_sources/0`:

```elixir
@impl PhoenixKit.Module
def css_sources, do: [:phoenix_kit_my_module]
```

Discovery is automatic at compile time via the `:phoenix_kit_css_sources` compiler — generates `assets/css/_phoenix_kit_sources.css`. Parent setup (one-time, by `mix phoenix_kit.install`): add the compiler to `compilers:` in `mix.exs` (before `:phoenix_live_view`) and `@import "./_phoenix_kit_sources.css";` in `app.css`. After setup, adding/removing modules is zero-config.

## JavaScript Hooks for External Modules

PhoenixKit ships hooks (RowMenu, TableCardView, SortableGrid, etc.) in `priv/static/assets/phoenix_kit.js`, exposed as `window.PhoenixKitHooks`. Parent spreads into LiveSocket:

```javascript
hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }
```

**Parent setup (by `mix phoenix_kit.install`):** copy `phoenix_kit.js` to `priv/static/assets/vendor/`, add `<script src={~p"/assets/vendor/phoenix_kit.js"}></script>` **before** `app.js` in root layout. `mix phoenix_kit.update` refreshes it.

**External modules ship their own hooks as a prebuilt bundle declared by `js_sources/0`** (`%{app:, file:, global:}`). The `:phoenix_kit_js_sources` compiler concatenates every declared bundle into `priv/static/assets/vendor/phoenix_kit_modules.js` and folds each `window.<Global>` into `window.PhoenixKitHooks`, so the host needs one `<script>` tag and no per-module `app.js` edits. Namespace hook names (`PhoenixKitCommentsAudioRecorder`, not `AudioRecorder`): the fold is last-write-wins across every bundle and core's own hooks. **Never register a hook from an inline `<script>` in a template** — morphdom does not execute inserted script tags, so an inline hook works on a hard load and silently vanishes on `live_redirect`. Reference: `phoenix_kit_comments`. **A bundle only admin pages mount** can stay out of that file (which every page loads): add `scope: :admin, hooks: ["Name", …]` to the entry and it rides in the lazily loaded admin bundle behind stubs registered under those names — see `PhoenixKit.Module` (`js_sources/0`) and `dev_docs/guides/2026-10-27-public-and-admin-javascript.md`. Entries without `scope:` are unchanged.

Templates in module packages use the same Layout Wrapper as core — see
`dev_docs/guides/2026-09-11-core-components.md` → "Layout Wrapper".

## Route Discovery

Routes auto-discovered at compile time via `ModuleDiscovery` beam scanning. The host router auto-recompiles when module deps change — `phoenix_kit_routes()` injects `__mix_recompile__?/0` with a hash of the discovered set.

**Two patterns:**
1. **Single page** — set `live_view: {Module.Web.IndexLive, :index}` on a tab in `admin_tabs/0` or `settings_tabs/0`. Route auto-generated; dynamic segments (`"hello-world/:id/edit"`) are spliced verbatim, and hidden CRUD pages are tabs with `visible: false`. Tab-only modules: calendar, comments, dashboards, db, locations, posts, staff, user_connections.
2. **Multi-page** — implement `route_module/0` returning a module with `admin_routes/0` and `admin_locale_routes/0` (admin LiveViews, both variants with distinct `:as`), plus `generate/1` / `public_routes/1` for controllers, forwards and public pages. Route-module-only: ai, entities, publishing, newsletters. Most other modules mix the two (tabs for the admin pages, a route module for public/controller routes); never put `live_view:` on a tab AND declare the same path in the route module.

**Profile settings tabs** — `profile_settings_tabs/0` returns maps (`id`, `label`, `icon`, `after`, `permission`, `visible`, `live_view`; reference: `PhoenixKit.ProfileSettingsTab`) that add a tab to `/profile/settings/<id>`. With `live_view:` core routes the page in its authenticated session, both URL shapes, before its own `/profile/settings/:tab`; the page renders `ProfileSettingsTabs.profile_tabs/1` with `active` set to its id. The route exists while the module is disabled, so the page checks `enabled?/0` itself. A host declares the same maps in `config :phoenix_kit, :profile_settings_tabs`.

Only one `live_view:` per path (core deduplicates, first wins — avoid). Fallback for failed auto-discovery:

```elixir
config :phoenix_kit, route_modules: [PhoenixKitEntities.Routes]
```

## Publishing Routing Strategy

Publishing's `/:language/:group/*path` catch-all matches every 2+ segment URL and Phoenix has no fall-through — host routes declared after `phoenix_kit_routes()` shaped `/:locale/<literal>/...` were silently shadowed. Fix: `compile_publishing_routing/1` in `integration.ex` emits an internal `__phoenix_kit_publishing_dispatch` scope plus a host-router `call/2` override that prepends the internal prefix on a `RouterDispatch.maybe_rewrite/1` cache hit (`restore_path/2` un-rewrites after route bind). Known blind spot: `mix phx.routes` shows publishing routes under the internal prefix, not the user-facing URL. The mechanism generalizes — lift to a registry shape when a second module needs it.
