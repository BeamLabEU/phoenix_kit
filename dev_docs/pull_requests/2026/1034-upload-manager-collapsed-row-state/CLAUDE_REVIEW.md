# PR #1034 — Keep upload rows' state current while the upload panel is shrunk

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no changes

Merged into `main` as 32091a6cf. The PR was written before the public/admin JS split (#990). The merge commit copies
the fix into `phoenix_kit_admin.js` and keeps the stub in `phoenix_kit.js`. Both bundles get identical hunks: the
`+`/`-` lines of the two files' diffs match exactly.

When shrunk, the panel ran no row pass at all, so `li[data-state]` stayed at whatever state it had when the panel shrank.
A host checking `li[data-state="queued"], li[data-state="uploading"]` (the agent Dock) refused to send until the panel
was opened. Now `_syncRowStates()` runs while the panel is shrunk: it creates rows for new files, updates `data-state`
and drops rows for files that are gone. It also runs whenever the queue is empty, before the early returns, so Dismiss
or Clear removes the last rows. The full `_renderRows()` (order, text, buttons) still waits until the panel is opened.
Row creation moved into `_newRow/1`, which both passes share.

Checked and fine:
- **Leftovers.** The "unfinished from a previous page" list is drawn from `this.leftovers`, not from `rowEls`, so
  dropping rows when the queue is empty does not touch it.
- **Keys.** `seen[it.id]` is keyed by a number and `Object.keys(rowEls)` gives strings. JS object keys are strings
  either way, so the comparison holds.
- **Gate.** `test/js/upload_manager_collapsed_rows.test.cjs` is picked up by `mix test.js` (`test/js/*.test.cjs`).

## Findings

None.

## Validation

`mix test.js`: 881/881. `mix precommit`: green.
