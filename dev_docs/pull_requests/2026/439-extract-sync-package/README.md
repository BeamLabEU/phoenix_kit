# PR #439 — Extract Sync module to standalone phoenix_kit_sync package

**Author:** Max (mdon)
**Base:** dev
**Date:** 2026-03-20
**Impact:** -16,574 lines / +30 lines (net: -16,544)

## Summary

Removes the built-in Sync module (~16,500 lines) from PhoenixKit and registers it as an external package (`{:phoenix_kit_sync, "~> 0.1"}`). When installed as a dependency, the module is auto-discovered via beam scanning — no config needed.

## What was removed

- **31 source files** in `lib/modules/sync/` — all Sync logic, API controller, LiveViews, WebSocket, workers
- **Sync API routes** (10 endpoints) + WebSocket forward + endpoint socket mount
- **Admin LiveView routes** (`/admin/sync`, `/admin/sync/connections`, `/admin/sync/history`)
- **Oban `sync: 5` queue** and `ensure_sync_queue` installer function
- **Admin nav icon**, module card on Modules page, landing page redirects
- **Deprecated `phoenix_kit_socket/0` macro** implementation (cleanup handler kept in `endpoint_integration.ex`)
- **Sitemap exclusion** pattern for `/sync`

## What was kept

- **Migration files** (V37, V40, V44, V56, V58, V74) — historical records for version upgrades
- **`sync` permission key** seeded by V53 — harmless, reused when the external package is installed
- **`endpoint_integration.ex`** — now handles removing deprecated `phoenix_kit_socket()` calls from parent apps

## Key changes

| File | Change |
|------|--------|
| `module_registry.ex` | Removed `Sync` from `internal_modules/0`, added `PhoenixKitSync` to `known_external_packages/0` |
| `oban_config.ex` | Removed `sync: 5` queue, `ensure_sync_queue/2` function, related dialyzer directives |
| `integration.ex` | Removed 90 lines: Sync API routes, WebSocket forward, admin routes |
| `endpoint.ex` | Removed `/sync` socket mount (5 lines) |
| `admin_nav.ex` | Removed sync icon mapping |
| `modules.html.heex` | Removed 52-line Sync module card |
| `permissions.ex` | Updated count: 25→24 permission keys (19 feature modules) |
| `README.md` | Updated feature list, permission counts, examples, admin routes docs |
| Tests | Updated module count (21→20), permission counts (25→24, 20→19) |
