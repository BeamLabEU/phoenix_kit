# Plan: Rename `_id` → `_uuid` across all modules

**Status:** Complete
**Created:** 2026-02-28
**Completed:** 2026-02-28

## Context

The UUID migration was declared complete, but `featured_image_id`, `created_by_id`, and `updated_by_id` naming survived in metadata structs, JSONB keys, form fields, helper functions, and variable names. All these fields actually store UUIDs (e.g., `Scope.user_id/1` returns `user.uuid`). No production data existed in the affected tables, so renamed cleanly without backward-compat hacks.

## Scope

Three renames across all modules (publishing, pages, posts, scheduled_jobs, storage, media_selector):

| Old name | New name | Type |
|----------|----------|------|
| `featured_image_id` | `featured_image_uuid` | struct field, JSONB string key, form field name, function names |
| `created_by_id` | `created_by_uuid` | struct field, frontmatter key, variable names, option keys |
| `updated_by_id` | `updated_by_uuid` | struct field, frontmatter key, variable names |

**Skipped migration files** (v17, v42, v46, v54, v59, v61, v62) — they reference actual DB column names.

## Files modified

### Publishing module (18 files)
- [x] `lib/modules/publishing/metadata.ex` — struct type, serialize list, defaults, parsing
- [x] `lib/modules/publishing/publishing.ex` — variable names, audit metadata, JSONB data map
- [x] `lib/modules/publishing/dual_write.ex` — variable names, map construction, `resolve_user_ids/1`
- [x] `lib/modules/publishing/db_storage.ex` — removed dead `created_by_id` opt
- [x] `lib/modules/publishing/storage.ex` — variable names
- [x] `lib/modules/publishing/storage/helpers.ex` — audit fields, `resolve_featured_image_id/2` → `resolve_featured_image_uuid/2`, `normalize_featured_image_id/1` → `normalize_featured_image_uuid/1`
- [x] `lib/modules/publishing/schemas/publishing_content.ex` — docstring, `get_featured_image_id/1` → `get_featured_image_uuid/1`
- [x] `lib/modules/publishing/db_storage/mapper.ex` — calls to `get_featured_image_id` → `get_featured_image_uuid`
- [x] `lib/modules/publishing/listing_cache.ex` — map keys
- [x] `lib/modules/publishing/db_importer.ex` — map keys
- [x] `lib/modules/publishing/workers/migrate_to_database_worker.ex` — map keys
- [x] `lib/modules/publishing/web/editor.ex` — form key
- [x] `lib/modules/publishing/web/editor.html.heex` — form input `name=`, form references
- [x] `lib/modules/publishing/web/editor/forms.ex` — form keys, normalization
- [x] `lib/modules/publishing/web/editor/persistence.ex` — Map.take key
- [x] `lib/modules/publishing/web/editor/preview.ex` — form data, metadata
- [x] `lib/modules/publishing/web/editor/helpers.ex` — defaults, `sanitize_featured_image_id/1` → `sanitize_featured_image_uuid/1`
- [x] `lib/modules/publishing/web/html.ex` — map key
- [x] `lib/modules/publishing/README.md` — documentation

### Pages module (4 files)
- [x] `lib/modules/pages/metadata.ex` — same changes as publishing metadata
- [x] `lib/modules/pages/storage.ex` — variable names, map keys
- [x] `lib/modules/pages/storage/helpers.ex` — same function renames as publishing helpers
- [x] `lib/modules/pages/listing_cache.ex` — map keys

### Other modules (5 files)
- [x] `lib/modules/storage/storage.ex` — SQL fragments: `data->>'featured_image_id'` → `data->>'featured_image_uuid'`, `metadata->>'featured_image_id'` → `metadata->>'featured_image_uuid'`
- [x] `lib/modules/posts/posts.ex` — docstring only
- [x] `lib/phoenix_kit_web/helpers/media_selector_helper.ex` — assign name
- [x] `lib/phoenix_kit/scheduled_jobs.ex` — option key `:created_by_id` → `:created_by_uuid`, docstring
- [x] `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` — docstring

### Test files (4 files)
- [x] `test/modules/publishing/schema_test.exs`
- [x] `test/modules/publishing/mapper_test.exs`
- [x] `test/modules/publishing/metadata_test.exs`
- [x] `test/modules/publishing/storage_utils_test.exs`

## Special cases resolved

1. **`resolve_scope_user_ids/1`** in `publishing.ex` — the tuple `{user_uuid, user_id}` had two identical UUID values (`Scope.user_id/1` returns `user.uuid`). Eliminated the tuple, collapsed to a single UUID return. Same for `resolve_user_ids/1` in `dual_write.ex`.

2. **`storage/storage.ex` SQL fragments** — updated JSONB string key literals in WHERE clauses.

3. **`dual_write.ex`** — `"featured_image"` (no suffix) in `publishing_posts.data` is a separate field from `"featured_image_id"` in `publishing_contents.data`. Only renamed the `_id` one.

## Verification results

- `mix compile --warnings-as-errors` — clean
- `mix test test/modules/publishing/` — **129 tests, 0 failures**
- Grep confirms zero remaining `featured_image_id`, `created_by_id`, `updated_by_id` outside migration files
