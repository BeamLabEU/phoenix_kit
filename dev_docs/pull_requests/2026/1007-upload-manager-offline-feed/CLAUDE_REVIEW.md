# PR #1007 — Fix the upload manager losing files when the LiveView connection drops

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no findings

Follow-up to #1006, in `phoenix_kit_upload_manager.js` (mirrored in `phoenix_kit.js`) and the guide:
`disconnected()` / `reconnected()` hook callbacks, a requeue of what was lost on a rejoin, a fresh `File`
for every re-send, and the upload ref read live.

## Checked and sound

Everything below was read against LiveView 1.2.13, the version in `mix.lock`, and not taken from the PR
description.

- **The callbacks fire when the PR needs them to.** `onError` -> `displayError` -> `showLoader()` calls
  `__disconnected` on every hook, for a dropped socket and for a crashed view alike, so a crash is
  covered too. `join()` also calls `showLoader(timeout)`, so `disconnected` can fire again during a
  rejoin. The hook is idempotent there: only the first call sets `offlineSince`.
- **A rejoin's empty entry list cannot read as "consumed".** `applyJoinPatch` patches the DOM and calls
  `triggerReconnected` in one synchronous run, and the manager's `MutationObserver` is a microtask, so
  it runs after `reconnected()` has already requeued the items. The 250 ms tick cannot land in between.
- **`reconnected()` runs in the right order.** `requeueSeen` runs first, while still offline. The
  transfers stop, `offline` clears, then `requeueUnseen` runs. An item the first pass requeued is
  `queued` and unseen, and the second pass skips it, so nothing is decremented twice.
- **A fresh `File` gets a fresh entry ref.** `genFileRef` draws on a page-wide counter, so old refs in
  `stale`, `ghosts` and `jobs` can never collide with a re-sent entry.
- **Controls work while offline.** `_cancelEntry` is a no-op then, and `chunked.discard` is a plain HTTP
  `DELETE`, so a cancel still reaches the partial file. A soft pause or resume made offline is settled
  by `requeueSeen`.
- **A transfer that finishes while offline is safe.** `entry.progress(100)` goes nowhere, and the job
  stops. On reconnect the item is requeued, and the new job's `GET` returns the full offset, so it
  finishes at once.
- **`_ref()` replaces every use of the old `uploadRef`** in both files, and
  `upload_manager_bundle.test.cjs` holds the two copies together.

The two trade-offs the guide states (a requeued file cancelled while waiting leaves its partial to the
sweep; a file consumed just before the drop can be stored twice) are the right way round: a duplicate
rather than a loss. Content dedup answers the duplicate with `:duplicate`.
