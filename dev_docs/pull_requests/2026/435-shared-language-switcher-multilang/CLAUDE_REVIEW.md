# PR #435 Review — Extract shared LanguageSwitcher and MultilangForm components

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/435
**Author:** Max Don (mdon)
**Branch:** dev → dev
**Date:** 2026-03-19
**Size:** +3,762 / -1,415 (21 files)

## Summary

Extracts two shared components from duplicated code across entities and publishing modules:

1. **`LanguageSwitcher`** — Configurable language selector UI with 3 variants (inline/tabs/pills), 3 display modes (auto/full/compact), status dots, primary indicators, accessibility attrs, safe coercion, and dev-time validation.

2. **`MultilangForm`** — Form helpers for multilang translation workflows. Provides `mount_multilang/1`, `handle_switch_language/2`, `merge_translatable_params/4`, `<.translatable_field>`, `<.multilang_tabs>`, `<.multilang_fields_wrapper>`, skeleton loading, and `inject_db_field_into_data/5`.

All entity forms (data_form, entity_form, data_view) and publishing templates swapped to use shared components. Old `publishing/web/components/language_switcher.ex` deleted. 86 new tests added.

## Architecture Assessment

### What works well

- **Clean separation of concerns:** LanguageSwitcher is pure UI (no Multilang dependency), MultilangForm bridges UI and Multilang business logic. This means LanguageSwitcher can be used by publishing module (which has its own language model) without pulling in entity Multilang.

- **Defensive coding:** Both components use safe coercion (`coerce_attrs/1`), rescue blocks around Multilang calls, and graceful fallbacks. `resolve_click_js/2` rescues bad JS functions. `lang_field/2` handles both atom and string-keyed maps.

- **Dev-time validation:** `validate_config/1` catches conflicting attrs (e.g., `exclude_primary + primary_divider`) in non-prod environments via Logger warnings. Won't crash in prod.

- **Good API design:** The `translatable_field` component supports two translation models (JSONB data column vs settings translations) via `secondary_name`/`lang_data_key` overrides, avoiding the need for separate components.

- **Test coverage:** 86 tests cover rendering, display modes, filtering, status dots, interaction modes, coercion, accessibility, error display, and field attribute forwarding. Tests use `rendered_to_string` for fast component-level testing without LiveView overhead.

### Entity form refactoring

- `data_form.ex`: ~210 lines of multilang boilerplate replaced with `mount_multilang()`, `handle_switch_language()`, and `multilang_enabled?()` imports. Crash-proof rescue blocks added to validate/save handlers.
- `entity_form.html.heex`: Manual language tabs replaced with `<.multilang_tabs>` + `<.multilang_fields_wrapper>` + `<.translatable_field>`. Custom skeleton markup provided for entity form layout.
- `data_view.ex`: ~90 lines of duplicated multilang mount/refresh logic replaced with imports.

### Publishing module changes

- Old `publishing/web/components/language_switcher.ex` (442 lines) deleted.
- All publishing templates (`editor`, `preview`, `html`, `listing`, `index`, `show`) now import from the shared location.
- `index.ex` adds `import PhoenixKitWeb.Components.LanguageSwitcher` for publishing overview pills.

## Issues Found and Fixed

### Fixed (commit `1905697`)

1. **`length/1` in template guards** — Templates used `length(@language_tabs) > 1` on every render (O(n)). **Fix:** Added precomputed `show_multilang_tabs` boolean assign to `mount_multilang/1` and `refresh_multilang/1`. All three templates (`data_form.html.heex`, `entity_form.html.heex`, `data_view.ex`) now use `@show_multilang_tabs`. The `multilang_tabs` component uses `match?([_, _ | _], @language_tabs)` (O(1) pattern match).

2. **`Enum.at/2` for prev_lang in O(n) loop** — `language_switcher.ex:205` called `Enum.at(@filtered_languages, idx - 1)` inside a `for` loop, making divider logic O(n²). **Fix:** Precompute `divider_indices` as a `MapSet` of indices that get a divider. Template checks `(idx - 1) not in @divider_indices` instead of looking up the previous element. Removed dead `show_divider?(false, ...)` clause.

3. **`preserve_primary_fields/2` duplicate in data_form** — `data_form.ex:835-844` had a private version that duplicated `MultilangForm`'s `do_preserve_primary_fields/4`. **Fix:** Added public `preserve_primary_fields/4` to `MultilangForm`. `data_form.ex` now calls the shared helper with `@preserve_fields` module attribute, removing the private duplicate.

### Remaining (Low Priority)

4. **No `phx-target` on `<.translatable_field>` inputs** — The translatable field component hardcodes `phx-debounce="300"` but doesn't accept/forward a `phx-target` attribute. If the field is used inside a `<.live_component>`, events would bubble to the wrong target. Currently all usages are in LiveViews, so this is fine.

5. **`switch_lang_js/2` always pushes event** — The JS function sends `"switch_language"` even when the server-side handler would reject the code (not in enabled languages). This means a brief skeleton flash before LiveView re-renders with unchanged state. Harmless UX-wise but could be optimized.

6. **Publishing `index.ex` imports** — `index.ex:23` imports `PhoenixKitWeb.Components.LanguageSwitcher` but was previously working without it. The diff shows it was added to support pill-variant language display on the publishing overview page. The import is appropriate.

## Verdict

**✅ Approve** — Well-structured extraction that eliminates significant duplication across entities and publishing modules. The shared components have a clean API, good test coverage, and defensive coding practices. Three post-merge optimizations were applied (precomputed assigns, MapSet divider indices, consolidated preserve helper). The architecture cleanly separates UI rendering (LanguageSwitcher) from business logic (MultilangForm → Multilang), making each independently reusable.
