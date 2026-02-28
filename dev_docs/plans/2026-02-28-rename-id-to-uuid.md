# Plan: Rename `_id` → `_uuid` across all modules

**Status:** Phase 1 Complete - Phase 2 Complete - Phase 2b Complete (Post-Review Fixes)
**Created:** 2026-02-28
**Updated:** 2026-02-28

## Context

The UUID migration was declared complete, but `featured_image_id`, `created_by_id`, and `updated_by_id` naming survived in metadata structs, JSONB keys, form fields, helper functions, and variable names. All these fields actually store UUIDs (e.g., `Scope.user_id/1` returns `user.uuid`). No production data existed in the affected tables, so renamed cleanly without backward-compat hacks.

**Phase 1** (completed) - Renamed struct fields and metadata keys.

**Phase 2** (in progress) - Remove critical blockers that prevent dropping legacy `id` and `_id` columns from the database.

---

## Phase 1: Field/Variable Naming (COMPLETE)

### Scope

Three renames across all modules (publishing, pages, posts, scheduled_jobs, storage, media_selector):

| Old name | New name | Type |
|----------|----------|------|
| `featured_image_id` | `featured_image_uuid` | struct field, JSONB string key, form field name, function names |
| `created_by_id` | `created_by_uuid` | struct field, frontmatter key, variable names, option keys |
| `updated_by_id` | `updated_by_uuid` | struct field, frontmatter key, variable names |

**Skipped migration files** (v17, v42, v46, v54, v59, v61, v62) — they reference actual DB column names.

### Files modified

#### Publishing module (18 files)
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

#### Pages module (4 files)
- [x] `lib/modules/pages/metadata.ex` — same changes as publishing metadata
- [x] `lib/modules/pages/storage.ex` — variable names, map keys
- [x] `lib/modules/pages/storage/helpers.ex` — same function renames as publishing helpers
- [x] `lib/modules/pages/listing_cache.ex` — map keys

#### Other modules (5 files)
- [x] `lib/modules/storage/storage.ex` — SQL fragments: `data->>'featured_image_id'` → `data->>'featured_image_uuid'`, `metadata->>'featured_image_id'` → `metadata->>'featured_image_uuid'`
- [x] `lib/modules/posts/posts.ex` — docstring only
- [x] `lib/phoenix_kit_web/helpers/media_selector_helper.ex` — assign name
- [x] `lib/phoenix_kit/scheduled_jobs.ex` — option key `:created_by_id` → `:created_by_uuid`, docstring
- [x] `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` — docstring

#### Test files (4 files)
- [x] `test/modules/publishing/schema_test.exs`
- [x] `test/modules/publishing/mapper_test.exs`
- [x] `test/modules/publishing/metadata_test.exs`
- [x] `test/modules/publishing/storage_utils_test.exs`

### Special cases resolved

1. **`resolve_scope_user_ids/1`** in `publishing.ex` — the tuple `{user_uuid, user_id}` had two identical UUID values (`Scope.user_id/1` returns `user.uuid`). Eliminated the tuple, collapsed to a single UUID return. Same for `resolve_user_ids/1` in `dual_write.ex`.

2. **`storage/storage.ex` SQL fragments** — updated JSONB string key literals in WHERE clauses.

3. **`dual_write.ex`** — `"featured_image"` (no suffix) in `publishing_posts.data` is a separate field from `"featured_image_id"` in `publishing_contents.data`. Only renamed the `_id` one.

---

## Phase 2: Legacy ID Column Removal Blockers (IN PROGRESS)

### Summary

Before we can drop the legacy `id` (integer) and `_id` (integer FK) columns, we must ensure **NO CODE writes to these columns**. Currently, several places still use `user.id` (legacy integer ID) instead of `user.uuid` (UUIDv7).

### Critical Blockers

#### 1. User ID References Still Using Legacy Integer

| File | Line | Issue | Status |
|------|------|-------|--------|
| `lib/phoenix_kit_web/live/users/media.ex` | 354 | `user_id = if current_user, do: current_user.id, else: 1` | [ ] |
| `lib/phoenix_kit_web/live/users/media_selector.ex` | 213 | `user_id = if current_user, do: current_user.id, else: 1` | [ ] |
| `lib/phoenix_kit_web/live/dashboard/settings.ex` | 557 | `user_id = current_user.id` | [ ] |
| `lib/phoenix_kit/users/auth.ex` | 178 | `Events.broadcast_user_session_disconnected(user.id, ...)` | [ ] |
| `lib/phoenix_kit/dashboard/presence.ex` | 78, 317 | `user.id` used for presence tracking | [ ] |

#### 2. Storage System Writes to Legacy Column

| File | Line | Issue | Status |
|------|------|-------|--------|
| `lib/modules/storage/storage.ex` | 1421 | `user_id: user_id` (receives `current_user.id`) | [ ] |
| `lib/modules/storage/storage.ex` | 1422 | `user_uuid: resolve_user_uuid(user_id)` | [ ] |

**Note:** Need to change function signature from `user_id` (integer) to `user_uuid` (UUID) and stop writing to `user_id` field.

#### 3. Schema Primary Key Pattern

| File | Line | Issue | Status |
|------|------|-------|--------|
| `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` | 30 | Uses `@primary_key {:id, :binary_id, autogenerate: true}` instead of `{:uuid, UUIDv7, autogenerate: true}` | [ ] |

#### 4. User Form Still Uses Legacy ID

| File | Line | Issue | Status |
|------|------|-------|--------|
| `lib/phoenix_kit_web/users/user_form.ex` | 197, 234, 442, 553, 681 | Uses `user.id` and `current_user.id` for comparison/logging | [ ] |
| `lib/phoenix_kit_web/users/user_form.html.heex` | 260, 310 | Uses `@user.id == @phoenix_kit_current_user.id` | [ ] |

### Non-Critical (Parameter Naming Only)

These are parameter names that accept UUIDs but use `_id` naming. **No changes needed** - they already work with UUIDs:

- `lib/modules/emails/interceptor.ex` - `user_id` opt accepts UUID
- `lib/modules/ai/ai.ex` - `user_id` filter opt accepts UUID
- `lib/modules/comments/comments.ex` - `user_id` parameter validates as UUID

### Verification Commands

```bash
# Find all user.id / current_user.id references
grep -rn "user\.id\|current_user\.id" lib/ --include="*.ex" --include="*.heex" | grep -v "socket.id\|# "

# Verify no writes to legacy user_id column (after fix)
grep -rn "user_id:" lib/modules/storage/ lib/phoenix_kit/ --include="*.ex" | grep -v "user_uuid\|# "

# Run full test suite
mix test

# Compile with warnings
mix compile --warnings-as-errors
```

### Pre-Drop Checklist

- [x] Fix all `current_user.id` → `current_user.uuid` in media.ex, media_selector.ex, settings.ex
- [x] Fix auth.ex broadcast to use `user.uuid`
- [x] Fix dashboard/presence.ex to use `user.uuid`
- [x] Fix storage.ex to not write to `user_id` column (set only `user_uuid`)
- [x] Fix ScheduledJob schema primary key pattern
- [x] Fix user_form.ex and user_form.html.heex to use `.uuid`
- [ ] Verify NO writes to any legacy `_id` columns (only NULLs or absent)
- [ ] Run full test suite with legacy columns dropped (local test)

### Phase 2 Verification Results

- **mix compile --warnings-as-errors** — ✅ clean
- **mix test** — ✅ 488 tests, 0 failures
- **mix credo --strict** — ✅ no issues
- **mix format** — ✅ formatted

### Files Changed in Phase 2

| File | Changes |
|------|---------|
| `lib/phoenix_kit_web/live/users/media.ex` | `current_user.id` → `current_user.uuid`, `user_id` → `user_uuid` |
| `lib/phoenix_kit_web/live/users/media_selector.ex` | `current_user.id` → `current_user.uuid`, `user_id` → `user_uuid` |
| `lib/phoenix_kit_web/live/dashboard/settings.ex` | `current_user.id` → `current_user.uuid`, `user_id` → `user_uuid` |
| `lib/phoenix_kit_web/users/auth.ex` | `user.id` → `user.uuid` for broadcast |
| `lib/phoenix_kit/users/auth.ex` | `user_id` → `user_uuid` in `update_user_avatar/4` |
| `lib/phoenix_kit/dashboard/presence.ex` | `user.id` → `user.uuid` for presence tracking |
| `lib/modules/storage/storage.ex` | Changed all `user_id` params to `user_uuid`, removed writes to legacy `user_id` column, removed `resolve_user_uuid/1` helper |
| `lib/phoenix_kit/scheduled_jobs/scheduled_job.ex` | `@primary_key {:id, :binary_id, ...}` → `{:uuid, UUIDv7, ...}` |
| `lib/phoenix_kit/scheduled_jobs.ex` | `job.id` → `job.uuid` in logging |
| `lib/phoenix_kit_web/users/user_form.ex` | `user.id` → `user.uuid`, `user_id` → `user_uuid` |
| `lib/phoenix_kit_web/users/user_form.html.heex` | `@user.id` → `@user.uuid` |

---

## Phase 2b: Items Missed by Claude, Found by Kimi Review (COMPLETE)

### Why they were missed

The search strategy during Phase 1 and Phase 2 was **pattern-specific**: greps targeted the exact strings `featured_image_id`, `created_by_id`, `updated_by_id`, `user.id`, and `current_user.id`. This caught direct struct field accesses on the User model but missed a different category of problem: **`user_id` as a variable or map key that holds a UUID value but uses legacy naming**. These cases don't access `.id` on a struct — they just use `user_id` as a name for something that is already a UUID. They were invisible to searches for `\.id\b` because the naming inconsistency was one level removed.

Specifically, the blind spots were:

1. **Presence metadata keys** — `simple_presence.ex` stored the user UUID under the atom key `:user_id` in ETS. The value was correct (a UUID), but the key name was wrong. This was only discoverable by reading the presence tracking code and tracing what key consumers (`live_sessions.ex`, `live_sessions.html.heex`) read back.

2. **`user_id` variable holding a UUID** — `upload_controller.ex` had a function called `get_current_user_id` that returned `user.uuid`. The variable `user_id` throughout the controller and the Oban job args key `user_id:` all held UUID values but had legacy names. A grep for `user.id` would never find this.

3. **Log messages** — `oauth.ex` used `user.id` only in a string interpolation inside a `Logger.info` call. This was syntactically identical to the struct access patterns that were caught elsewhere, but was in a file not included in the original file list and not covered by the targeted greps.

4. **`dashboard/presence.ex` `:ids` format** — `get_tab_viewers/2` had a `:ids` format branch reading `&1[:user_id]` from tab presence metadata, but the metadata was written with key `user_uuid` (line 78 of the same file). This was a latent bug — always returning nil — only visible by reading both the writer and reader of the same data structure.

5. **`live_sessions.ex` tracking map** — built a `user = %{uuid: ..., id: user_id, ...}` map where `id:` held a UUID from `Scope.user_id/1`. The `id:` key was unused by `track_user/2` (which only reads `.uuid` and `.email`), so it was dead code with legacy naming.

### Root cause of the gap

The verification grep at the end of each phase only checked for **strings that were known to be wrong up front** (`featured_image_id`, `user.id`, etc.). It did not check for the inverse: **variables or keys named `user_id` that hold UUIDs**. A complete audit requires both directions:

```bash
# What was checked (field access on struct)
grep -rn "\.id\b" lib/ | grep -v socket.id | grep user

# What was NOT checked (variable/key name holding a UUID)
grep -rn "\buser_id\b" lib/ | grep -v "# \|@doc\|migrations"
# Then manually verify each hit actually holds an integer vs UUID
```

### Files fixed in Phase 2b

| File | What was wrong | Fix |
|------|---------------|-----|
| `lib/phoenix_kit/admin/simple_presence.ex` | `:user_id` key in ETS metadata held UUID | Renamed key to `:user_uuid` |
| `lib/phoenix_kit_web/live/users/live_sessions.ex` | Read `&1.user_id` from presence meta; built map with `id: user_id` key | Read `&1.user_uuid`; removed `id:` key |
| `lib/phoenix_kit_web/live/users/live_sessions.html.heex` | `session.user_id` in template | `session.user_uuid` |
| `lib/phoenix_kit_web/users/oauth.ex` | `user.id` in Logger.info message | `user.uuid` |
| `lib/phoenix_kit/dashboard/presence.ex` | `:ids` format read `&1[:user_id]` (always nil); docstring showed integer example | Read `&1[:user_uuid]`; updated docstring |
| `lib/phoenix_kit_web/controllers/upload_controller.ex` | Function named `get_current_user_id`, variable `user_id`, Oban args key `user_id:`, param name `"user_id"` — all held UUIDs | Renamed everything to `user_uuid` |

### Phase 2b Verification

- **mix compile --warnings-as-errors** — ✅ clean
- **mix test** — ✅ 488 tests, 0 failures

---

## Phase 1 Verification Results

- `mix compile --warnings-as-errors` — clean
- `mix test test/modules/publishing/` — **129 tests, 0 failures**
- Grep confirms zero remaining `featured_image_id`, `created_by_id`, `updated_by_id` outside migration files
