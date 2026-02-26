# PR #359 — Add plugin module system with zero-config auto-discovery

**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/359
**Author:** @mdon | **Merged:** 2026-02-24 into `dev`
**Size:** +4,427 / -2,285 lines across 44 files

## What

Introduces a formal plugin architecture for PhoenixKit modules:

- **`PhoenixKit.Module` behaviour** — 5 required + 8 optional callbacks with `use`-macro defaults
- **`PhoenixKit.ModuleRegistry`** — GenServer-backed registry using `:persistent_term` for zero-cost reads
- **`PhoenixKit.ModuleDiscovery`** — Scans `.beam` files for `@phoenix_kit_module` attribute; auto-discovers deps without config

All 21 internal modules now implement the behaviour. Seven hardcoded enumeration files now delegate to the registry.

## Why

Previously, adding a module required touching 7+ core files (admin_tabs, permissions, registry, modules, supervisor, etc.). External plugins were impossible without forking PhoenixKit. This PR reduces that to zero config — add the dep, get the behaviour, everything else is auto-wired.

## How

1. `use PhoenixKit.Module` persists `@phoenix_kit_module true` in the compiled `.beam` file (same pattern as Elixir protocol consolidation)
2. `ModuleDiscovery` scans only apps that declare `:phoenix_kit` in their application dependencies
3. `ModuleRegistry` aggregates tabs, permissions, children, routes from all modules at startup
4. `integration.ex` generates admin routes at compile time from `admin_tabs` with `live_view` field
5. `auth.ex` subscribes all admin LiveViews to module PubSub events for live sidebar updates

## Bug Fixes in This PR

- **Cascade fix:** Shop disabled _after_ billing toggle succeeds (not before)
- **`Tab.permission_granted?/2`:** Fixed atom key handling (was silently bypassing checks)
- **`static_children/0`:** Now catches per-module failures instead of crashing supervisor
- **Server-side toggle auth:** `authorize_toggle/2` validates key against `accessible_modules` MapSet

## Files

- `CLAUDE_REVIEW.md` — Full code review with design analysis and recommendations
