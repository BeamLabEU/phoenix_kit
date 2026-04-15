# PR #490 — Added image_set for correct file pulling on the front end image calls

**Author:** @alexdont (Sasha Don) · **Branch:** `dev` → `dev` · **Files:** 14 (+744 / −64)

## Summary

Adds a responsive `<.image_set>` component that renders a `<picture>` element with AVIF/WebP/JPEG `<source>` entries. Adds `alternative_formats` field to `Storage.Dimension` so dimensions can generate additional format variants (e.g., WebP + AVIF alongside JPEG). New `VariantNaming` utility handles format-suffix parsing. Fixes V95 migration idempotency for the `folder_uuid` column. Improves media search (by UUID) and media detail (shows per-variant dimensions/size). Minor UI overflow/word-break fixes.

## Overall verdict

**Approve / merge.** Clean, production-quality PR. Migration is safe, rollback is correct, the component is well-documented, and the utility module is testable. Minor notes below, none blocking.

## Findings

### GOOD

- **V97 migration is idempotent** — `ALTER TABLE ... ADD COLUMN alternative_formats` is wrapped in a `DO $$ BEGIN IF NOT EXISTS ... END $$` block. Safe to run multiple times. ✅
- **V97 rollback is correct** — `down/1` drops only `alternative_formats` and restores the comment to `'96'`. No data-loss risk. ✅
- **V95 migration idempotency fix** — replaces `add_if_not_exists` (which doesn't handle the FK) with a raw SQL block. Correct fix for the idempotency gap. ✅
- **`ImageSet` component** — handles N+1 via pre-loaded `variants` prop, groups by mime_type (not variant name) to avoid mismatch when format conversion fails, correct AVIF > WebP priority, graceful fallback chain (`medium` → largest primary → any variant → `""`). ✅
- **`VariantNaming` module** — clean utility, doctests present, `known_formats/0` is the single source of truth for supported format suffixes. ✅
- **`normalize_dimension_params/1`** — extracting the boolean coercion + alternative_formats filtering into one helper removes the `validate`/`save` duplication nicely. ✅
- **`build_variant_dimensions/1` + `put_original_fallbacks/2`** in media detail — proper separation of concerns; falls back to the file record for original dimensions when the instance record doesn't have them. ✅

### BUG — MEDIUM

- **`Code.ensure_loaded?(Storage) and function_exported?(Storage, :list_image_set_variants, 1)` check in `load_variants/1`** — this guard is correct for optional dependencies, but `list_image_set_variants/1` doesn't appear in the diff. If it doesn't exist on `Storage`, the component will silently return no variants for every auto-load call. Confirm the function exists (or is being added in a companion commit).

### IMPROVEMENT — MEDIUM

- **`prefix_str/1` in V97 is duplicated** from other v-migrations. This is a pre-existing pattern in the codebase, but V97 is a good moment to note: consider extracting to a shared migration helper once a few more migrations land.
- **`Enum.map_join` in dimensions.html.heex** for the table format cell produces a string like `"JPEG +WEBP +AVIF"` — the leading `" +"` separator leaks into the UI (shows as `JPEG +WEBP`). Change to `Enum.join(d.alternative_formats, ", ")` and add a prefix space/separator outside, or use `Enum.map_join(d.alternative_formats, " +", &String.upcase/1)` with a leading ` +` joining directly after the primary format string. Check the rendered output matches design intent.
- **Checkbox `<% current_alternatives = ... %>` in template** — computing data in HEEx with `<% %>` works but a small `assign(:current_alternatives, ...)` in the LiveView would be cleaner.

### NITPICK

- `mime_to_format("image/png")` returns `"png"` and `mime_type_for_format("png")` returns `"image/png"` — round-trips cleanly, but `"png"` will appear as a `<source type="image/png">` entry, which is technically valid but pointless (all browsers support PNG natively). Consider omitting PNG from the `<source>` entries (keep it as fallback only) unless the intent is to serve resized PNG variants.
- `@fallback_variants` is rendered in the `<img srcset>` but also comes from `grouped[nil]` — if all variants have a known mime_type (`webp`, `avif`, `png`), `fallback_variants` will be empty and `build_srcset([])` returns `""`. The `<img>` will then have `srcset=""`. Browsers handle this fine (falls back to `src`), but it's worth adding a note/guard.

## Recommendation

Merge after confirming `Storage.list_image_set_variants/1` exists. The rest is ready.

---

## Follow-up review (commit `5d0dcc73` — "Address PR review feedback")

All prior findings are resolved:

- **BUG — MEDIUM (`list_image_set_variants/1`)** → **Resolved.** Defined at `lib/modules/storage/storage.ex:1803` (plus bulk `list_image_set_variants_for_files/1` at :1827). Guard in `ImageSet.load_variants/1` now succeeds.
- **IMPROVEMENT — `" +"` separator leak in dimensions table** → **Resolved.** Now renders as `JPEG + WEBP, AVIF` via `" + " <> Enum.map_join(..., ", ", &String.upcase/1)` (`dimensions.html.heex:127-134`).
- **IMPROVEMENT — `<% current_alternatives = ... %>` in HEEx** → **Resolved.** Moved into `assign_format_fields/2` in the LiveView; template reads `@current_alternatives` and `@primary_format` (`dimension_form.ex:138-155`, `dimension_form.html.heex:208-215`).
- **NITPICK — PNG in `<source>` list** → **Resolved.** `mime_to_format("image/png")` now returns `nil`; PNG falls through to the fallback `<img>` only (`image_set.ex:127`).
- **NITPICK — empty `srcset=""`** → **Resolved.** `fallback_srcset` is precomputed once; `srcset`/`sizes` attrs are only emitted when non-empty via `if(@fallback_srcset != "", do: ...)`.
- **Migration version collision** → **Handled.** V97 was reassigned to the already-merged per-item markup migration (#493); this PR's column now ships as **V98** with the same idempotent `DO $$ ... IF NOT EXISTS` pattern and a correct `down/1` restoring comment `'97'`.

### Verdict

**Approve / ready to merge.** No new issues found in the follow-up diff.
