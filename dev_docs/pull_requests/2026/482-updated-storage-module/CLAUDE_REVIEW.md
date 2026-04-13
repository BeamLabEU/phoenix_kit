# PR #482 Review: Updated Storage module

**Reviewer:** Claude
**Date:** 2026-04-10
**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/482
**Author:** alexdont
**Base:** dev ← dev
**Size:** +4471 / -1084 across 33 files, 40 commits

## Resolution

Bugs #1–#10 fixed in two commits:
- `a55966a8` — HIGH: folder transaction, sync progress delta, cycle detection + depth limit
- `ddd677cb` — MEDIUM: nil guard, Integer.parse, temp file cleanup, async test_connection, bulk delete files

Remaining improvements (#12–#24) left for author to address.

## Summary

Large PR that significantly enhances the Storage module with:
- Folder system (create, rename, move, color, drag-drop, tree sidebar)
- Multipart S3 uploads for large files
- Tigris provider support
- Media Health page with sync monitoring
- Oban-based sync worker with progress tracking
- Configurable max upload size
- Reusable `SearchableSelect` LiveComponent
- Provider-aware bucket form redesign (card sections, test connection)
- DaisyUI 5 migration for bucket/dimension forms
- Activity badge color DRY refactor + pagination filter fix
- Accept all file types for upload

---

## Findings

### BUG - CRITICAL

_(none found)_

### BUG - HIGH

#### 1. `delete_folder/1` not wrapped in a transaction — FIXED in a55966a8
**File:** `lib/modules/storage/storage.ex` (~line 916-927)

Three sequential DB operations (reparent child folders, reparent files, delete folder) run without a transaction. If `repo().delete(folder)` fails after the `update_all` calls succeed, children are reparented but the folder remains — inconsistent state.

```elixir
def delete_folder(%Folder{} = folder) do
  # Should be wrapped in repo().transaction/1
  from(f in Folder, where: f.parent_uuid == ^folder.uuid)
  |> repo().update_all(set: [parent_uuid: folder.parent_uuid])

  from(f in File, where: f.folder_uuid == ^folder.uuid)
  |> repo().update_all(set: [folder_uuid: folder.parent_uuid])

  repo().delete(folder)
end
```

**Fix:** Wrap all three operations in `repo().transaction(fn -> ... end)`.

---

#### 2. Health LiveView: Cumulative sync progress corrupts stats — FIXED in a55966a8
**File:** `lib/modules/storage/web/health.ex` (~line 96-109)

The `:in_progress` handler does `new_healthy = report.healthy + synced`, but `synced` is the **cumulative** total (not a delta). Each progress callback inflates `healthy` further, and `Enum.drop(report.under_replicated, synced)` over-drops items. Health percentage can exceed 100%.

**Fix:** Track previous synced count and apply only the delta, or restructure to use absolute counts.

---

#### 3. `update_folder/2` allows creating circular parent references — FIXED in a55966a8
**File:** `lib/modules/storage/storage.ex` (~line 903-907)

No validation prevents moving a folder under one of its own descendants (A→B→C, then move A under C). This creates a cycle that causes `folder_breadcrumbs/1` to infinitely recurse and `build_folder_tree/1` to produce incorrect results.

**Fix:** Before updating `parent_uuid`, walk the ancestor chain of the target parent and verify the folder being moved is not an ancestor.

---

### BUG - MEDIUM

#### 4. `toggle_bucket` crashes on nil bucket — FIXED in ddd677cb
**File:** `lib/modules/storage/web/settings.ex` (~line 276-288)

`Storage.get_bucket(bucket_uuid)` can return `nil` (bucket deleted between page load and click). `!bucket.enabled` raises `KeyError`.

**Fix:** Add a `nil` guard or pattern match.

---

#### 5. `folder_breadcrumbs/1` — N+1 queries with no depth limit — FIXED (depth limit) in a55966a8
**File:** `lib/modules/storage/storage.ex` (~line 929-935)

Recursive individual queries per ancestor level. No depth guard means a cycle (see finding #3) causes infinite recursion.

**Fix:** Use a recursive CTE, or add a depth limit (e.g., max 20 levels) plus visited-set tracking.

---

#### 6. `String.to_integer` crash on non-numeric input — FIXED in ddd677cb
**File:** `lib/modules/storage/web/settings.ex` (~line 179-191)

`String.to_integer(val)` in `update_storage_form` crashes with `ArgumentError` if user submits empty string or non-numeric value for redundancy/max upload size fields.

**Fix:** Use `Integer.parse/1` with fallback.

---

#### 7. Move-to-folder: no descendant cycle check — FIXED (via #3 update_folder) in a55966a8
**File:** `lib/phoenix_kit_web/live/users/media.ex` (`move_selected_to_folder` handler)

The handler checks `sel_folder_uuid != target` (self-move) but does not check if `target` is a descendant of the folder being moved. This is the UI-side manifestation of finding #3.

---

#### 8. `replicate_to_buckets` temp file leaked on exception — FIXED in ddd677cb
**File:** `lib/modules/storage/services/manager.ex` (~line 127-144)

The `rescue` clause returns an error tuple but does not clean up the temp file created before the failing call. `File.rm(local_path)` is skipped when `store_across_buckets` raises.

**Fix:** Use `try/after` to ensure cleanup, or wrap with `File.rm` in the rescue clause.

---

#### 9. `test_connection` runs synchronously in LiveView process — FIXED in ddd677cb
**File:** `lib/modules/storage/web/bucket_form.ex` (~line 175-190)

`handle_info({:run_test_connection, ...})` calls `Storage.test_connection/1` synchronously. Network calls to S3/B2/R2/Tigris can hang for seconds, blocking the entire LiveView process and making the page unresponsive.

**Fix:** Use `Task.async` + `handle_info` for the result.

---

#### 10. `delete_selected` only deletes folders, ignores selected files — FIXED in ddd677cb
**File:** `lib/phoenix_kit_web/live/users/media.ex` (`handle_event("delete_selected", ...)`)

The handler only deletes selected folders. Selected files are silently ignored. Flash says `"N folder(s) deleted"` but user may expect files deleted too.

**Fix:** Either also delete selected files, or disable the delete button when only files are selected and clarify in UI.

---

### IMPROVEMENT - HIGH

#### 11. S3 provider no longer uses global `Application.put_env` — great fix
**File:** `lib/modules/storage/providers/s3.ex`

The old code used `Application.put_env(:ex_aws, :s3, config)` which is process-global and unsafe for concurrent uploads to different buckets. The new code passes config per-request via `ExAws.request(aws_config(bucket))`. This fixes a real race condition.

---

#### 12. `count_folder_contents` double-counts files that are both home and linked
**File:** `lib/modules/storage/storage.ex` (~line 937-960)

If a file has `folder_uuid = X` AND a `FolderLink` pointing to folder X, it's counted twice (once from home files query, once from links query).

**Fix:** Use `UNION` or exclude home files from the links count.

---

#### 13. `load_existing_files` calls `folder_breadcrumbs` per unique folder — N+1 on folder paths
**File:** `lib/phoenix_kit_web/live/users/media.ex` (`load_existing_files`)

For each unique `folder_uuid` in loaded files, `folder_breadcrumbs/1` is called (which itself does recursive queries). Many files across different folders produces dozens of queries.

**Fix:** Batch-load folder paths with a single recursive CTE, or cache breadcrumbs per session.

---

#### 14. `persistent_term` sync state invisible in multi-node deployments
**File:** `lib/modules/storage/workers/sync_files_job.ex`

`persistent_term` is node-local. If Oban runs the sync job on node A but admin views Health page on node B, `get_sync_state()` returns nothing. PubSub broadcasts work cross-node, but page refresh loses progress.

---

### IMPROVEMENT - MEDIUM

#### 15. SearchableSelect: no click-outside-to-close behavior
**File:** `lib/phoenix_kit_web/live/components/searchable_select.ex`

The dropdown has a `close` event but nothing triggers it externally. No `phx-click-away` mechanism. Users can only close by clicking the toggle again or selecting an option.

---

#### 16. SearchableSelect: hidden input may not trigger parent form change
**File:** `lib/phoenix_kit_web/live/components/searchable_select.ex` (~line 88-97)

When selection changes, the LiveComponent updates its own state and the hidden input value changes on re-render. But since this is a component-internal update, the parent form's `phx-change` may not fire, leaving the form changeset with a stale region value until submit.

---

#### 17. R2 provider missing from region select in bucket form
**File:** `lib/modules/storage/web/bucket_form.html.heex`

The bucket form has `SearchableSelect` region pickers for S3, B2, and Tigris, but not R2 (Cloudflare R2). R2 users get no region selector.

---

#### 18. `sync_under_replicated` race condition with stale `location_count`
**File:** `lib/modules/storage/storage.ex` (~line 482-512)

`sync_instance/4` reads `item.location_count` at query time. Two concurrent sync jobs would both read the same count and replicate to the same missing buckets, creating duplicate `FileLocation` records. `SyncFilesJob` uses `max_attempts: 1` which reduces but doesn't eliminate the risk.

---

#### 19. `ilike` search doesn't escape special characters
**File:** `lib/phoenix_kit_web/live/users/media.ex` (`load_existing_files`)

Search query interpolated as `"%#{search_query}%"` in `ilike`. While Ecto parameterizes (no SQL injection), `%`, `_`, and `\` in user input aren't escaped — searching for `%` matches all files.

---

#### 20. `handle_params` reloads entire folder tree on every navigation
**File:** `lib/phoenix_kit_web/live/users/media.ex`

Every `handle_params` call (page change, folder nav, search) loads the full folder tree from DB. Could be loaded once in `mount` and updated incrementally.

---

### NITPICK

#### 21. Broad `rescue error ->` in S3 provider functions
**File:** `lib/modules/storage/providers/s3.ex` (~line 35-39)

`store_file`, `retrieve_file`, `delete_file`, `file_exists?`, and `test_connection` all use broad `rescue error ->`. Per previous PR #473 review feedback, these should be narrowed to specific exception types.

---

#### 22. `accept: :any` for media uploads
**File:** `lib/phoenix_kit_web/live/users/media.ex`

Changed from `accept: ["image/*", "video/*", "application/pdf"]` to `accept: :any`. Removes defense-in-depth against malicious file uploads (executables, scripts). May be intentional for general-purpose storage.

---

#### 23. Inline `<style>` and `<script>` in media template
**File:** `lib/phoenix_kit_web/live/users/media.html.heex` (~line 7-24)

CSS for `.renaming-preview` animation and JS for view mode initialization would be better in the CSS bundle and JS hooks.

---

#### 24. Hardcoded English strings in media templates
**File:** `lib/phoenix_kit_web/live/users/media.html.heex`

Strings like "All Files", "Folders", "Root", "Select all", "No folders yet" are hardcoded instead of using `gettext()`. Rest of codebase consistently uses `gettext` for i18n.

---

## Positive Highlights

- **S3 global config race fix** (#11) — Real concurrency bug resolved by passing config per-request
- **Activity badge DRY refactor** — Extracted shared helpers, fixed pagination filter loss
- **Multipart upload support** — Proper streaming for large files with concurrent chunk uploads
- **Oban-based sync** — Persistent, reliable sync with progress tracking via PubSub
- **Provider-aware form UX** — Clean conditional rendering per storage provider
- **`store_across_buckets` fix** — Now correctly returns only successful bucket UUIDs

## Recommendation

All HIGH and MEDIUM bugs have been fixed. Remaining items (#12–#24) are improvements and nitpicks — assigned to author (alexdont) for follow-up.
