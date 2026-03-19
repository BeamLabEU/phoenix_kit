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

## Issues Found

### Medium Priority

1. **`length/1` in template guards** — `entity_form.html.heex:74` uses `length(@language_tabs) > 1` inside a HEEx conditional. `length/1` is O(n) and called on every render. Not a real performance issue with ~10 languages, but `Enum.count_until(@language_tabs, 2) >= 2` or a precomputed assign would be more idiomatic. Same pattern in `multilang_tabs` component at `multilang_form.ex:443`.

2. **`Enum.at/2` for prev_lang in O(n) loop** — `language_switcher.ex:205` calls `Enum.at(@filtered_languages, idx - 1)` inside a `for` loop that already has an index. Since `Enum.at/2` on a list is O(n), and this is called for each language, the total becomes O(n²). For typical language lists (2-10 items) this is negligible, but could be avoided by tracking the previous element in the loop accumulator.

### Low Priority / Observations

3. **No `phx-target` on `<.translatable_field>` inputs** — The translatable field component hardcodes `phx-debounce="300"` but doesn't accept/forward a `phx-target` attribute. If the field is used inside a component that needs targeting (e.g., a `<.live_component>`), events would bubble to the wrong target. Currently all usages are in LiveViews, so this is fine.

4. **`preserve_primary_fields/2` in data_form is a private duplicate** — `data_form.ex:835-844` has a private `preserve_primary_fields/2` that partially overlaps with `MultilangForm.merge_translatable_params/4`'s `preserve_fields` option. The data_form version preserves title/slug/status on secondary tabs; the MultilangForm version is more generic. This works but could be consolidated in a future cleanup.

5. **`switch_lang_js/2` always pushes event** — The JS function sends `"switch_language"` even when the server-side handler would reject the code (not in enabled languages). This means a brief skeleton flash before LiveView re-renders with unchanged state. Harmless UX-wise but could be optimized.

6. **Publishing `index.ex` imports** — `index.ex:23` imports `PhoenixKitWeb.Components.LanguageSwitcher` but was previously working without it. The diff shows it was added to support pill-variant language display on the publishing overview page. The import is appropriate.

## Verdict

**✅ Approve** — Well-structured extraction that eliminates significant duplication across entities and publishing modules. The shared components have a clean API, good test coverage, and defensive coding practices. The medium-priority issues are minor efficiency concerns that don't affect correctness or user experience. The architecture cleanly separates UI rendering (LanguageSwitcher) from business logic (MultilangForm → Multilang), making each independently reusable.
