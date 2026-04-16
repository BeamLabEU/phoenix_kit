# PR #497 — Updated media browser component

**Author:** @alexdont (Sasha Don) · **Branch:** `dev` → `dev` · **Files:** 12 (+651 / −106)

**Commits (oldest → newest):**
- `6daa64b3` Add trash bucket, drag-drop upload, and breadcrumb padding to media
- `1479fc99` Fix trash view: truncate datetime, hide folders in trash
- `acafbe53` Update delete modal to reflect soft-delete to trash
- `dd6f2ee6` Fix empty state message for trash view
- `75b1379a` Clear trash filter when navigating to All Files, Root, or folders
- `2695ee39` Fix trash filter persisting across URL-driven navigation
- `01acc031` Fix flash of root view on page refresh with URL params
- `ef5e8bc3` Fix drag-drop upload to show inline progress without modal

## Summary

Adds a trash bucket (soft-delete) for media files via V99 migration + `trashed_at` column + `status: "trashed"`, an Oban `PruneTrashJob` worker keyed off a `trash_retention_days` setting (default 30), drag-drop upload with inline progress hook (`FolderDropUpload` in `phoenix_kit.js`), and several post-merge fixes for the new `MediaBrowser` component (URL-param hydration on first mount, trash filter clearing on navigation, empty-state/banner copy). Scope enforcement on soft-delete is added, but scope enforcement on the **trash view** and on **permanent-delete from trash** is missing. Core mechanics and migration are clean.

## Overall verdict

**Changes requested.** Two scope-safety holes must be closed before merge (both critical — they allow a scoped embed to see and permanently destroy files belonging to other tenants). Everything else is polish.

## Findings

### GOOD

- **V99 migration is idempotent** (`lib/phoenix_kit/migrations/postgres/v99.ex:15-43`). Uses the project's `DO $$ IF NOT EXISTS` pattern for `ADD COLUMN trashed_at TIMESTAMPTZ` and `create_if_not_exists(index(..., where: "trashed_at IS NOT NULL"))`. Partial index is a good touch for prune sweeps. `down/1` drops column + index and restores comment to `'98'`. ✅
- **Migration registration correct** (`lib/phoenix_kit/migrations/postgres.ex`) — `@current_version` bumped to 99 and dispatch map updated. ✅
- **Soft-delete respects scope** (`media_browser.ex:907-915`) — `delete_selected` when **not** in trash view looks up each file via repo and guards with `Storage.within_scope?(file.folder_uuid, scope)` before `Storage.trash_file(file)`. Mirrors the pattern @timujinne added in PR #495 commit `4a7057d5`. ✅
- **Trashed files excluded from normal listings** (`storage.ex:1158-1160`, `storage.ex:1481-1491`) — `list_files_in_scope/2` adds `where: f.status != "trashed"`; `count_orphaned_files/1` adds `f.status != "trashed" and …`. So trashed files don't double-appear in the main grid or inflate orphan counts. ✅
- **Trashed-filter auto-clear on navigation** (`media_browser.ex:123,178,668,983,1115,1160`) — setting `filter_trash: false` in `apply_nav_params`, `init_socket`, and several handlers means URL-driven navigation (click a folder, All Files, Root) leaves trash view cleanly. Closes `75b1379a`/`2695ee39`. ✅
- **First-mount hydration fix** (`media_browser.ex:76-84`) — `Map.has_key?(assigns, :initial_params)` is checked and `apply_nav_params/2` is applied before the first render, avoiding the "flash of root view" before `handle_params`. The guard using `Map.has_key?` (not `assigns[:initial_params]`) is correct — `nil` values won't skip. ✅
- **`PruneTrashJob` worker logic is correct** (`workers/prune_trash_job.ex`) — queue `:file_processing`, `max_attempts: 3`, logs result, delegates to `Storage.prune_trash(days)` which uses `delete_file_completely/1` per file (so variants + dedup tracking + S3 objects all get cleaned up). ✅
- **`trash_retention_days/0` is defensive** (`storage.ex:2033-2045`) — default 30, parses from `Settings`, `rescue _ -> 30` for any unparseable value. ✅
- **All new event bindings have `phx-target={@myself}`** — verified for trash/drag-drop handlers added in this PR.
- **Folders remain permanently deleted** (`media_browser.ex:917-921`) — folders have no trash bucket; `Storage.delete_folder(folder, scope)` preserves scope enforcement.
- **Media detail page supports restore/permanent-delete** (`media_detail.ex:+29/-3`) — viewing a trashed file's detail URL shows appropriate actions rather than 404ing.

### BUG — CRITICAL

1. **Trash view ignores `scope_folder_id`** — `Storage.list_trashed_files/1` (`storage.ex:1995-2004`) and `Storage.count_trashed_files/0` (`storage.ex:2008-2012`) accept no scope parameter. `load_trashed_files/2` in the component (`media_browser.ex:1209-1213`) doesn't pass scope either. A scoped embed (`scope_folder_id: some_uuid`) that toggles `filter_trash` will display **every trashed file in the system**, including files belonging to other scopes/tenants. Same tenant-leak pattern that scope enforcement was supposed to prevent elsewhere.

   **Fix:** Add `scope_folder_id` parameter to `list_trashed_files/2` and `count_trashed_files/1`. Under non-nil scope, join against the folder tree (reuse the recursive CTE from `list_files_in_scope`) so only files whose `folder_uuid` is within the scope subtree are returned. Pass scope from `load_trashed_files/3`.

2. **Permanent-delete from trash skips scope check** — `media_browser.ex:900-905`:

   ```elixir
   if socket.assigns.filter_trash do
     Enum.each(socket.assigns.selected_files, fn file_uuid ->
       Storage.delete_file_completely(file_uuid)  # no within_scope? guard
     end)
   ```

   Combined with bug #1 above, a scoped embed can permanently destroy files anywhere in the system via a crafted `delete_selected` event while in trash view. The non-trash branch (soft-delete) *does* check scope — the trash branch must mirror that.

   **Fix:** Apply the same `repo.get(Storage.File, file_uuid)` + `Storage.within_scope?(file.folder_uuid, scope)` guard before `Storage.delete_file_completely/1`.

### BUG — HIGH

3. **`PruneTrashJob` is defined but never scheduled.** The worker's `@moduledoc` says "Runs daily via cron", but the only crontab entry in `config/config.exs` is `ProcessScheduledJobsWorker`. No cron entry is added for `PruneTrashJob`, and the installer in `lib/phoenix_kit/install/oban_config.ex` only injects the scheduled-jobs worker into parent apps' crontabs. As shipped, trash accumulates forever.

   Note: this matches an existing pattern — `PhoenixKit.Activity.PruneWorker` has the same "Runs daily" docstring and the same lack of scheduling. But since PR #497 introduces a new worker with the same aspirational claim, this PR is the right moment to wire one of these up properly.

   **Fix:** Either (a) add `{"0 3 * * *", PhoenixKit.Modules.Storage.Workers.PruneTrashJob}` to the cron plugin in `config/config.exs` and update the installer so parent apps pick it up, or (b) call `Oban.insert/1` on an `every: {1, :day}` cron schedule from an `Application.start/2` callback. Document the decision in the moduledoc.

4. **`@type t` missing `:trashed_at`** (`schemas/file.ex:94-117`). Schema adds the field but the typespec isn't updated — callers using `@spec trash_file(File.t()) :: …` will type-check inconsistently.

   **Fix:** Add `trashed_at: DateTime.t() | nil` to the `@type t` map.

### IMPROVEMENT — HIGH

5. **Schema docstring Status Flow doesn't include `trashed`** (`schemas/file.ex:15-19`). The enumerated statuses list only `processing`, `active`, `failed`. Adding `- trashed - File has been soft-deleted to the trash bucket` would keep documentation honest.

6. **`list_files/1` (general helper, `storage.ex:1324-1331`) does not filter `status == "trashed"`.** Low-risk because the codebase reads via `list_files_in_scope/2` in the admin UI, but any external caller of `Storage.list_files/1` will now see trashed files. Either add a default `exclude_trashed: true` option to `list_files/1` or audit callers to confirm it's not used for user-facing listings.

### IMPROVEMENT — MEDIUM

7. **`empty_trash/0` and `prune_trash/1` do per-file `delete_file_completely`** via `Enum.each` (`storage.ex:2015-2031`). For large trashes, this serially fires N S3 deletes and N DB transactions. Fine for now (prune runs nightly, bounded by retention), but a batched path would scale better.

8. **Retention setting has no admin UI.** Parent apps that want to change `trash_retention_days` must set the row via IEx/SQL. Matches the `activity_retention_days` precedent, so not a regression, but worth a line in module documentation pointing to where/how to change it.

9. **Drag-drop hook uses a retry loop** (`phoenix_kit.js:2260-2268`) — 20 × 50ms attempts to find the upload input. If the component re-renders slowly or the input is conditionally hidden, the injection silently fails. Adding a `console.warn` on final failure would help parent-app debugging.

### NITPICK

10. **Flash counts the selected set, not the actually-deleted set** (`media_browser.ex:923-929`). Already a pre-existing issue I flagged on PR #495 follow-up, now slightly worse in trash view since under scope-fix (bug #1/#2) some items will be skipped. Worth addressing when #1/#2 are fixed — return counts from the `Enum.each`-replacing `Enum.reduce` and flash the real number.

11. **Hard-coded cutoff arithmetic** (`storage.ex:2022`) — `DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)` works, but `DateTime.add(now, -days, :day)` is idiomatic on modern Elixir and avoids the magic number.

## Verification performed

- Fetched `pr-497` and diffed against `dev`.
- Read V99 migration end-to-end; confirmed idempotent wrapping, partial index, rollback.
- Confirmed `@current_version: 99` in `migrations/postgres.ex`.
- Read `Storage` diff for soft-delete/restore/list_trashed/count_trashed/empty_trash/prune_trash/trash_retention_days.
- Confirmed `list_files_in_scope/2` and `count_orphaned_files/1` add `status != "trashed"` filter; confirmed `list_files/1` does **not**.
- Read component `delete_selected` handler and `load_trashed_files/2` — confirmed both scope gaps described in bugs #1 and #2.
- Grepped `config/config.exs` and `install/oban_config.ex` for `PruneTrashJob` — not present in either crontab.
- Inspected `01acc031` hydration fix — `Map.has_key?(assigns, :initial_params)` guard is correct.
- Spot-checked `phx-target={@myself}` coverage on new bindings (trash toggle, restore, drag-drop) — all correct.

## Recommendation

Block merge on **bugs #1 and #2** (scope safety for trash view and permanent-delete). Strongly request **bug #3** (cron registration) before merge so the worker isn't a "declared-but-dead" feature. Bug #4 (typespec) and Improvement #5 (docstring) are one-liners and should land with #1/#2.

Once those are in, this is a nice addition — soft-delete is a genuine improvement over hard-delete for an admin content tool, drag-drop upload closes a UX gap, and the hydration fix meaningfully improves reload behavior. Good work overall.

---

## Follow-up review (after commit `01638682`)

**New commit on PR:**
- `01638682` Address PR review: tenant isolation, cron wiring, schema fixes

### Fixes verified ✅

| # | Finding | Status | Evidence |
|---|---------|--------|----------|
| 1 | Trash view ignores scope | **FIXED** | `build_trashed_query/1` in `storage.ex:2012-2038` uses recursive CTE (mirrors `build_scope_file_query/4`). `list_trashed_files(scope, opts)`, `count_trashed_files(scope)`, and `empty_trash(scope)` all accept scope. Component passes `scope_folder_id(socket)` at all 6 call sites. |
| 2 | Permanent-delete skips scope check | **FIXED** | `media_browser.ex:900-908` — trash branch now does `repo.get(Storage.File, file_uuid)` + `within_scope?(file.folder_uuid, scope)` guard before `delete_file_completely/1`, mirroring the soft-delete branch. |
| 3 | `PruneTrashJob` not scheduled | **PARTIALLY FIXED** (see new finding 14 below) |
| 4 | `@type t` missing `:trashed_at` | **FIXED** | `schemas/file.ex:110` — `trashed_at: DateTime.t() \| nil` added. |
| 5 | Status Flow docstring missing `trashed` | **FIXED** | `schemas/file.ex:20` — `trashed` enumerated with description. |
| 6 | `list_files/1` didn't filter trashed | **FIXED** | `storage.ex:1325` — `where([f], f.status != "trashed")` added at head of query pipeline. |

CTE pattern check: the recursive CTE matches `build_scope_file_query/4` exactly (same select shape, same join topology), so shared behavior is guaranteed — `within_scope?` semantics hold (root files with `folder_uuid IS NULL` are correctly excluded from non-nil scopes via the inner join on `f.folder_uuid == d.uuid`).

### New findings

#### BUG — HIGH

13. **`restore_selected` has no scope guard** — `media_browser.ex:967-980`:

    ```elixir
    def handle_event("restore_selected", _params, socket) do
      Enum.each(socket.assigns.selected_files, fn file_uuid ->
        Storage.restore_file(file_uuid)  # no within_scope? check
      end)
    ```

    This is the same class of bug as the now-fixed #2. `selected_files` is a `MapSet` populated by `toggle_select` (`media_browser.ex:831-840`), which accepts whatever `file-uuid` the client pushes — **LiveView never validates that the UUID maps to a visible file**. A scoped embed can restore any trashed file in the system by sending a crafted `toggle_select` followed by `restore_selected`, even though bug #1's fix now prevents viewing cross-tenant trashed files through the grid.

    Severity: HIGH, not CRITICAL, because restoration is reversible (the file returns to `active` with `trashed_at = nil`) and doesn't destroy data — but it still violates scope boundaries and can expose a cross-tenant file into the scoped view's active grid.

    **Fix:** Apply the same pattern the delete branch now uses:

    ```elixir
    def handle_event("restore_selected", _params, socket) do
      scope = scope_folder_id(socket)
      repo = PhoenixKit.Config.get_repo()

      Enum.each(socket.assigns.selected_files, fn file_uuid ->
        file = repo.get(Storage.File, file_uuid)
        if file && Storage.within_scope?(file.folder_uuid, scope) do
          Storage.restore_file(file)
        end
      end)
      # ...
    end
    ```

#### BUG — MEDIUM

14. **Cron wiring fix only applies to fresh installs, not existing installs.** The installer change (`oban_config.ex:129` and `:729`) adds `{"0 3 * * *", PhoenixKit.Modules.Storage.Workers.PruneTrashJob}` to both the templated and manual-instruction config — but for **existing** parent apps running `mix phoenix_kit.update`, the upgrade path is `ensure_cron_plugin/2 → add_scheduled_posts_job_to_crontab/1` (`oban_config.ex:404-461`), which only knows how to inject `ProcessScheduledJobsWorker`. There is no matching `ensure_prune_trash_job_crontab` helper.

    Result: existing installations will not pick up the trash cron entry after upgrading, so they'll accumulate trashed files indefinitely unless the operator manually edits `config/config.exs`. Since PhoenixKit ships as a library with a deliberate update path, this is the scenario most consumers will hit.

    **Fix:** Add an `ensure_prune_trash_job_crontab/1` helper modeled on `add_scheduled_posts_job_to_crontab/1` that inserts the `{"0 3 * * *", PhoenixKit.Modules.Storage.Workers.PruneTrashJob}` entry into an existing crontab when it's missing. Chain it from `update_existing_oban_config/3` alongside `ensure_cron_plugin`.

### Nitpicks

15. **Stale `⚡ LATEST` marker on V97 in `migrations/postgres.ex:540` docstring** — now that V99 is marked latest (correctly), the old V97 marker on line 540 should be removed. This was actually pre-existing (V98 didn't remove it either), so it's not this PR's regression, but the file is being modified anyway for the V99 entry — worth cleaning up one line over.

16. **`empty_trash/1` and `prune_trash/1` still per-file `Enum.each`** (storage.ex:2043, 2056). Previous nitpick #7 stands — unchanged. Acceptable for now.

17. **Hard-coded cutoff arithmetic** (`storage.ex:2049`) — `DateTime.add(-days * 86_400, :second)` still not idiomatic. Previous nitpick #11 unchanged.

### Updated recommendation

Finding #13 (restore scope guard) is the only new blocker — small, localized fix, same pattern already in the file for delete. Finding #14 (cron upgrade path) is important for existing deployments; I'd address it in this PR since the feature isn't functionally complete for upgraders otherwise, but it could reasonably be split to a follow-up if time-pressured.

With #13 in and #14 at least documented as a known limitation, the rest of the review feedback has been handled cleanly. The CTE approach for scope, the mirrored `within_scope?` guard on delete, and the `@type t`/docstring consistency are all right. Good follow-through on the initial round.

### Verification performed (follow-up)

- Diffed `ef5e8bc3..01638682` on `storage.ex`, `media_browser.ex`, `oban_config.ex`, `schemas/file.ex`.
- Confirmed `build_trashed_query/1` structure matches `build_scope_file_query/4` in CTE semantics.
- Grepped `scope_folder_id(socket)` in `media_browser.ex` — 27 call sites, including all trash paths.
- Read `within_scope?/2` (`storage.ex:1099-1101`) and `ancestor_of?/3` (`storage.ex:1073-1088`) — semantics preserved.
- Read `toggle_select/select_all` handlers (`media_browser.ex:820-858`) — confirmed `selected_files` is client-trusted.
- Read `Storage.restore_file/1` (`storage.ex:1982-1993`) — confirmed no internal scope check, so callsite must enforce.
- Grepped `ensure_cron_plugin`, `add_scheduled_posts_job_to_crontab` in `oban_config.ex` — confirmed no `PruneTrashJob` insertion in upgrade path.
- Confirmed `@current_version 99` in `migrations/postgres.ex:731` and V99 docstring entry at line 532.
- Confirmed V99 migration `COMMENT ON TABLE phoenix_kit` (not `phoenix_kit_files`) matches V97/V98 pattern — correct.
