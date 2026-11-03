# PR #999 — Add a removal guard and server-side confirmation to the media browser

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; the HIGH below is fixed (follow-up of 2026-11-03)

## Checked and sound

- **The guard call fails closed.** It runs in an unlinked monitored process; a raise, throw, exit, kill,
  timeout, malformed answer or a foreign uuid all come back as `:error`, which removes nothing. The log
  names the module and exception class only; `$callers` and the locale are carried over.
- **Event coverage.** Every MediaBrowser handler that trashes or deletes is in `@removal_events`; the drag
  onto Trash pushes only `trash_file`/`trash_folder`/`delete_selected`.
- **Confirmation cannot be skipped or forged.** The pending `{event, params}` is stored server-side under a
  single-use token; sending the final event directly still goes through `run_removal`. On confirm
  `replay_removal` drops the gate markers, re-runs the gates and rebuilds the plan; `same_files?` compares
  files, the free set and folder uuids.
- **Skip actions pass `only:`**, so a file trashed after the dialog opened is never deleted by it.
- **The modal** escapes text, allows only local/http(s) links, and `label: nil` hides detail and link.

## Findings

### BUG - HIGH — `delete_selected` planned item by item, so a file could disappear unasked (fixed)
`removal_analysis("delete_selected")` planned each selected file and folder against the state *before*
the action and concatenated the plans; the handler then runs them in sequence. A file that survives one
step only because it moves into (or stays in) another selected item was in the plan as `rehome`/`unlink`,
never asked about, never listed, and not protected by `only:`:

- (a) live view, folders A and B selected, F homed in A and linked into B: trashing A rehomes F into B,
  trashing B then trashes F;
- (b) Trash view, A and B trashed and selected, same F: deleting A promotes F into B, deleting B
  **deleted F for good**;
- (c) live view in folder C, file F (homed in C, linked into subfolder S) and folder S selected:
  removing F from C rehomes it into S, trashing S trashes it.

**Fix:** `Storage.removal_plan(:selection, %{files: [{file, viewed_folder}], folders: [...], kind:
:trash | :delete})` reads the selection as one unit. It builds the per-item plans as before, then
settles the files they only move: `gone` is every folder of the selected subtrees; for a trash a file
survives only through its home (not in `gone`, not the folder it is taken out of) or a link from a LIVE
folder outside `gone` (other than that folder) — `trash_folder/2` promotes along live links only; for a
permanent delete, through a link from any folder outside `gone`. A file that does not survive moves to
`trash` / `delete`, so the guard is asked about it and the dialog counts it. Proven against the
operations: ordering does not change the outcome (a file promoted into a later-trashed folder is promoted
again along its remaining links), which is what lets the plan stay order-free. Without a folder in the
selection nothing cascades and the plan is the per-item one. The browser's analysis calls it; three
tests in `media_browser_removal_guard_test.exs` cover (a), (b) and (c) — (c) also confirms and checks the
file really ends in the trash, (b) asserts the row survives and calls the Storage plan directly.

### IMPROVEMENT - MEDIUM — "Delete all orphaned" skips the guard on a false premise (OPEN)
The comment, the moduledoc and `RemovalGuard` say orphans "are in no folder by definition", but
`orphaned_files_query/1` has no folder condition: an orphan is a live file no registered module reference
or `:file_reference_sources` entry points at (`file_reference_sources_test.exs` says so). A host that
implements `RemovalGuard` but not `file_reference_sources` gets its in-use files queued to the trash, then
pruned. Either ask `places/2` and queue only the free uuids, or fix the docs and tell hosts to register the
same tables in `:file_reference_sources`. (A scoped browser and a picker now refuse the event — see #994.)

### IMPROVEMENT - MEDIUM — the guard's `ctx` cannot tell a trash from a permanent delete (OPEN)
`ctx.action` is `:delete_file`/`:delete_selected`/`:delete_folder` for both outcomes; outside the trash view
these only trash. The analysis knows `kind`; passing `kind: :trash | :delete` in `ctx` (and documenting it)
would let a host allow trashing but refuse deleting.

### NITPICKs (not changed)
- With a guard on, a bulk Delete that only unlinks/rehomes has no confirmation at all (`client_confirm/2`
  drops the prompt; the analysis answers `:pass`).
- The blocked dialog says "Cannot delete: …" for a Move to trash; places beyond the first 50 held files
  render with no name; the places list is unbounded.
- "the confirmation goes through the gates again: another user's file is refused" never opens a dialog —
  the re-gating it names is covered by the next test.
