# PR #1011 — Fix uploads waiting for a Resume click after a page reload, and re-sending a stored file

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve with fixes; one nitpick fixed, one
improvement open for a decision

The server now decides per leftover: leave it, discard it (a `.done` marker says it was taken), send it
again without a click (`upload_resume: :auto`), or list it with Resume. `UploadResume` holds a Web Lock
per page, so a dead page's records are taken at once and a throttled tab's are left alone.

## Checked and sound

- **A failed store is never marked as taken.** `mark_taken/1` runs on `{:ok, _}` only, and
  `process_single_upload/3` and `store_upload/8` return `{:postpone, _}` on every failure. In
  `parent_progress/3` the marker follows `File.cp!`, with the bytes held by `UploadInbox`, so a later
  store failure stays in the Upload problems panel.
- **The id rebuilt from a key is the id the upload used.** `upload_id/2` joins with `Enum.join/2`, so
  integers and their string forms hash alike, and `split_client_key/1` is the exact reverse of
  `client_key/1`, a name holding `|` included.
- **A forged report does nothing.** The key only feeds a hash into a fixed-length hex id, so no path is
  built from it. The owner comes from the socket, and the reply goes back only to the client that asked.
- **`age_ms` is a duration, so clock skew between browser and server cannot move the verdict.** Old
  records with no `picked` send none, and then any marker counts, which is the safe reading.
- **A leftover is never wrongly dropped by an old marker.** `written_since?/2` ignores a marker older
  than the copy, and `external/1` clears the marker on every re-send.
- **No stale "unfinished" notice after a discard.** `upload-discard` does not reach the manager's
  `localStorage` list, but the media browser renders it with `remember={false}`, so there is none.
- **#1007 and this PR together, on a reconnect.** Both hooks run: the manager requeues and `UploadResume`
  reports. A re-send of a file the manager still holds is stopped by `holds/1`.
- **`external?/1` fails safe.** A host wrapping `external/1` in its own closure reads as not resumable,
  so it falls back to `:ask` instead of auto-sending with no marker behind it.

## Findings

### IMPROVEMENT - MEDIUM — a re-send without a click goes to the folder on screen, which may not be the one picked (open)

The stash records the URL's `folder` parameter (`_scopeNow/0`), and the file is placed by
`current_folder_uuid/1` when it arrives. On the Media page the two agree, because the folder is in the URL.

A picker, or an embedded browser without `on_navigate`, keeps its folder in socket state. A person walks
to folder X in one of those and drops a file, then the page reloads. The browser mounts at the top of its
scope, the record's scope still matches, and the file is stored at the top, not in X, with nothing to
say so.

The file is not lost, and the Resume button had the same placement. What changes is that Resume was an
act taken while looking at a folder; `:auto` is silent.

Not fixed, because the fix is a design choice about this feature's defaults. There are two ways:

1. **Remember the folder (recommended).** Render the current folder on the hook's element, keep it in the
   stash record, send it back in the report, and let the server check it against the scope and use it as
   the upload's destination. This keeps the no-click behaviour everywhere.
2. **Ask instead.** Make `auto_resume?/1` also require `controlled_mode?/1`, so these browsers fall back
   to the Resume row. Two lines, but a picker loses what this PR gives it.

### NITPICK — a look running when the hook was destroyed armed a timer nothing clears (fixed)

`destroyed()` clears `_rescan`, but `_reportLeftovers/2` is an asynchronous chain. A look in flight at that
moment went on to set `_rescan` again, and while another tab held its lock it kept rescheduling itself
every 60 s until a full page load, and could call `pushEventTo` on the dead hook. It needs a live
navigation to land inside the stash read, so it is rare.

`_abandoned/2` and the report step now stop on `_destroyed`, the flag `_hold/0` already uses. Test:
`test/js/upload_resume.test.cjs`, "a look still running when the hook is destroyed…", which failed before
the fix.

## Validation, for #1007 to #1012 together

#1010 and #1011 say they did not run the full suite or dialyzer, so the merged tip was run whole, with the
fixes from these reviews.

- `mix precommit`: clean, dialyzer and 663 JS tests included.
- `mix test` on a new database built from V1 to V227: 89 doctests, 13,972 tests, 1 excluded, 11 failures.
  None comes from these PRs:
  - **7 need ImageMagick 7** (`HdrSynthTest`, `SvgRasterTest`, `RawPreviewTest`): `System.cmd("magick", …)`
    raises `:enoent` on a machine with ImageMagick 6.
  - **3 are a leak between tests** (`DoctorOrphanedFkDestructiveTest`). Its `ADD CONSTRAINT` validates
    every row of `phoenix_kit_activities`, and earlier tests had committed rows there (`organization.*`,
    `api.key_*`, `setting.changed`) whose actors no longer exist. None of these six PRs logs an activity.
    Not fixed here; the source is those tests' logging escaping the sandbox.
  - **1 was a wrong test, fixed** (`ApiPersonalKeysTest`, "in a borrowed session no key and no service user
    is created"; from `2aa6c5db2`, before these PRs). It counted users before `borrowed/1` added its own, so
    it failed every time, and no forged event created anyone. It now counts after. The file passes (33
    tests); the full suite was not run again for that one change.

The two shared databases could not give this answer. `beamlab_test` is stamped V227 without V226's
`personal` column (1,282 false failures), and `phoenix_kit_test` is at V224, below the V225 floor, so
`test_helper.exs` excludes the whole integration half and the run looks nearly green.
