# CLAUDE_REVIEW — PR #503

**Title:** Add V103 nested categories migration and folder-scoped media picker
**Author:** @mdon
**Base/Head:** `dev` ← `mdon/dev`
**Diff:** +181 / −27 across 4 files
**Merged:** 2026-04-22

Files touched:
- `lib/phoenix_kit/migrations/postgres.ex` (bump `@current_version`, moduledoc entry for V103)
- `lib/phoenix_kit/migrations/postgres/v103.ex` (new)
- `lib/modules/storage/schemas/file.ex` (widen `file_type` allowlist)
- `lib/phoenix_kit_web/live/components/media_selector_modal.ex` (new `scope_folder_id` attr + `load_files/2` refactor)

## Summary of the change

Three loosely-related changes bundled into one PR:

1. **V103 migration** — adds nullable self-FK `parent_uuid` on `phoenix_kit_cat_categories` plus a b-tree index on `(parent_uuid)` to support arbitrary-depth category trees. Purely a schema prep for downstream plugin code; no main-app consumers of the column land in this PR.
2. **File `file_type` allowlist widened** — from `["image", "video", "document", "archive"]` to include `"audio"` and `"other"`.
3. **MediaSelectorModal gets a `scope_folder_id` attr** — filters the browse query to a single folder (including files reached via `FolderLink`), assigns newly-uploaded files into that folder, and refactors `load_files/2` from nested if/case branches into four composable `scope_files_by_*` helpers.

## Verdict

**LGTM with observations.** The migration is well-structured and idempotent. The modal refactor is a clear readability win. A few soft concerns called out below — none are blockers, all are worth knowing for follow-up work.

---

## V103 — nested categories migration

### Idempotency / reversibility — PASSES

- Column add is guarded by `information_schema.columns` lookup scoped to the correct schema (respects `prefix: …`).
- Index uses `CREATE INDEX IF NOT EXISTS`.
- `down/1` is written and uses `DROP INDEX IF EXISTS` + `DROP COLUMN IF EXISTS`.
- Version comment (`COMMENT ON TABLE … IS '103'` / `'102'`) matches the project convention.

Consistent with the V102 pattern. Good.

### IMPROVEMENT - MEDIUM — No `ON DELETE` clause on the self-FK

```sql
ADD COLUMN parent_uuid UUID REFERENCES phoenix_kit_cat_categories(uuid);
```

The moduledoc is explicit that this is intentional ("parent/child linkage is managed by the context layer, which runs subtree-walking cascades inside a transaction. A DB-level cascade would bypass the soft-delete machinery and the activity log."). The resulting default is `ON DELETE NO ACTION`, which *does* act as a safety net — it will refuse to delete a parent that still has children.

That's actually a correct design decision, but it only works if the context layer always walks the subtree before calling `Repo.delete/1`. If any code path calls a plain `Repo.delete` on a category with children, it will now raise a foreign-key violation where it previously succeeded (the children would just be orphaned, which is its own bug).

**Worth verifying before the downstream plugin code lands:** grep every `Repo.delete` / `delete_all` that touches `phoenix_kit_cat_categories` and confirm it either (a) walks the tree first or (b) is paired with matching `ON DELETE CASCADE`-free cascade logic. The repo doesn't ship that consumer yet, so this is a note for the follow-up PR.

### NITPICK — Index name inconsistent with V87

V87 created indexes via Ecto's `index/3`, which auto-generated names like `phoenix_kit_cat_categories_catalogue_uuid_index`. V103 creates `phoenix_kit_cat_categories_parent_index` — the `_uuid` segment is dropped. Not a bug, just a naming drift. If the next person greps for `*_parent_uuid_index` they'll miss it.

### NITPICK — Index could be partial

The b-tree on `(parent_uuid)` indexes all rows, including the NULL roots (which will be every existing row on migration day and a meaningful fraction of all rows once trees are populated). A partial `WHERE parent_uuid IS NOT NULL` index would be smaller and still cover the "list children of X" query. For any plausible cat-categories table size this is negligible; flagging for completeness.

### NITPICK — Cycle prevention lives in application code, undocumented

A nullable self-FK with `NO ACTION` permits cycles (`A.parent = B, B.parent = A`) at the DB layer. The moduledoc doesn't mention cycle prevention. If downstream code relies on `ancestor_of?/2`-style recursive walks (and the storage context already has one in `storage.ex:1075` with a 50-hop limit), it'll need the same safeguard here. Worth a sentence in the moduledoc, and a bounded walk in the consuming context.

---

## `file.ex` — file_type allowlist widened

### Observation — unblocks silent failures, not a feature

The only caller in this PR that emits `"other"` is `MediaSelectorModal.determine_file_type/1`, which already returned `"other"` for anything non-image/non-video. Before this PR, uploading a PDF through the modal must have tripped `validate_inclusion` and silently failed — the upload path does `_ = maybe_set_folder(...)` and throws away non-matching results, so the symptom would have been "uploaded PDF never appears". Good catch, silently widens what the library can handle.

`"audio"` has no in-tree emitter — presumably a downstream plugin sets `file_type = "audio"` directly. Fine.

---

## MediaSelectorModal — scope_folder_id

### Phoenix lifecycle — no regressions

`update/2` on a LiveComponent is the correct place for data loads (distinct from the Iron Law's "no queries in `mount/3`"). The existing pattern is preserved.

### Ecto — scope helper refactor is a readability win

`load_files/2` previously had four conditional-reassignment blocks stacked imperatively. The new version pipes through `scope_files_by_user / _folder / _type / _search`, each with a nil/default clause that no-ops. Cyclomatic complexity drops, the query grows left-to-right, and it's easy to add a new scope without touching the existing branches. The inline comment explicitly calls out credo's complaint and the fix — good.

### IMPROVEMENT - MEDIUM — `maybe_set_folder` silently discards errors

```elixir
_ = maybe_set_folder(file, socket.assigns[:scope_folder_id])
```

Both success paths in `process_upload/3` pattern-match on `{:ok, file, :duplicate}` / `{:ok, file}` and then discard the `maybe_set_folder` result with `_ =`. The implementation returns `{:ok, _} | {:error, changeset}` (for the `folder_uuid` UPDATE path) or `{:ok | :error, FolderLink}` (for the link-insert path). If either fails — FK violation, stale repo, anything — the file uploads successfully but **doesn't appear in the scoped picker** and the user gets no feedback.

The moduledoc addition describes this as the critical behavior for per-object isolation ("files already living elsewhere get a `FolderLink` into the scope folder on re-upload rather than being moved out from under their original owner"). Silently losing that behavior on error deserves at least a `Logger.warning`.

Suggested:

```elixir
case maybe_set_folder(file, socket.assigns[:scope_folder_id]) do
  :noop -> :ok
  :already_in_folder -> :ok
  {:ok, _} -> :ok
  {:error, reason} ->
    Logger.warning("Could not scope uploaded file #{file.uuid} to folder: #{inspect(reason)}")
end
```

### IMPROVEMENT - LOW — Upload + scope assignment aren't transactional

`Storage.store_file_in_buckets/6` (which presumably inserts the File row) and `maybe_set_folder/2` are two separate DB round trips. If the process crashes between them, the file exists without scope. Low priority because the file itself is recoverable and the next re-upload will re-enter the adoption path, but something to keep in mind.

### ~~BUG - LOW~~ Resolved — dedup is per-user, not global

Initial worry: a duplicate-upload by user B onto user A's unscoped orphan would adopt A's file into B's scope, hijacking it.

Walking through `Storage.store_file_in_buckets/6` (`lib/modules/storage/storage.ex:2331`) shows this isn't reachable: the dedup check is keyed on `calculate_user_file_checksum(user_uuid, file_checksum)`, which folds `user_uuid` into the hash. User B uploading user A's bytes produces a *different* `user_file_checksum` and creates a new File row rather than returning A's. Cross-user orphan adoption can't happen.

The remaining "same-user adopts own orphan" case is actually desirable — the user gets a proper home folder for their previously-orphan file. No fix needed.

### NITPICK — `in subquery(linked_subq)` is fine but `join` could be clearer

`scope_files_by_folder` uses `f.uuid in subquery(linked_subq)`. That's equivalent to a left-join + `NOT NULL` filter but neither is obviously better at this scale. Leaving as-is is fine.

### NITPICK — search wildcard escaping

`scope_files_by_search` inserts user input as `"%#{search}%"`. Parameterization prevents injection (thanks to `^`), but `%` and `_` in user input become wildcards. Pre-existing behavior from the old version, but worth sanitizing on a future polish pass.

---

## What's not covered

- **No tests accompany the refactor.** The `scope_files_by_*` helpers are pure-ish (query in → query out) and trivial to unit-test. For a LiveComponent change, the integration tests (`test/modules/publishing/integration/`-style) would cover the modal's upload flow end-to-end.
- **No migration test.** The `test/support/postgres/migrations/` wrapper will run V103 automatically on `mix test.setup`, but there's no assertion that V103 up/down are actually idempotent on an existing tree. Given the moduledoc's "lossy rollback" warning, a round-trip test would be valuable.
- **Docstring on `scope_folder_id`** — the in-module comment at line 82 of `media_selector_modal.ex` duplicates the attrs doc up top. Minor, could be deduped.

---

## Bundling note

V103 migration, file_type allowlist, and the modal scope work are three distinct concerns. The connective tissue is downstream (catalogue-style plugins that lazy-create per-object folders and need to classify non-image uploads), which isn't in this repo. Would have been three easier-to-review PRs; not a blocker since the merge strategy preserves history and the PR body does explain the connection.
