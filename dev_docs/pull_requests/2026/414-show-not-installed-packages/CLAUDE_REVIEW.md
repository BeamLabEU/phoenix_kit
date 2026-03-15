# PR #414 Review — Show Not-Installed Packages on Modules Page

**Reviewer:** Claude
**Date:** 2026-03-15
**Verdict:** Approve

## Summary

Small, focused PR that adds an "Available Packages" section to the admin Modules page. When known external PhoenixKit packages (currently just `phoenix_kit_newsletters`) are not installed, they appear as dashed-border cards with install instructions.

## Changes

### `module_registry.ex`
- New `known_external_packages/0` private function — returns a list of known external package metadata (module, hex_package name, display name, description, icon, hex_url)
- New `not_installed_packages/0` public function — filters `known_external_packages` to those where `Code.ensure_loaded?/1` returns false
- Currently only one package listed: `phoenix_kit_newsletters`

### `modules.ex` (LiveView)
- Assigns `not_installed_packages` in mount

### `modules.html.heex`
- Replaces the static "More Modules Coming Soon" placeholder with a dynamic "Available Packages" grid
- Each card shows: icon, name, description, "Not installed" badge, Hex.pm link, and `mix.exs` snippet
- Only rendered when `@not_installed_packages != []`

## What Works Well

- Clean separation: registry knows about packages, LiveView just passes data, template just renders
- Good UX: shows exactly what to add to `mix.exs` with the dependency snippet
- Properly conditional: section hidden when all packages are installed
- Natural follow-up to PR #413 (newsletters extraction)

## Minor Notes

- The `known_external_packages/0` list will grow over time as more modules are extracted. The current approach (hardcoded list) is fine for now but may eventually warrant a config-driven or auto-discovered approach.
- `Code.ensure_loaded?/1` is the right check — it works at runtime without compile-time coupling.

No issues found. Clean PR.
