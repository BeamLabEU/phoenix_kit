# PR #1026 — A picker upload that matches a trashed file is restored and picked

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; small follow-ups applied

Merged into `main` as 646b5ca2f, with conflicts in `priv/gettext/` only: #1028's mention-notification strings and
this PR's four picker strings were both appended at the end of the POT and the nine `.po` files. Both sides were
kept.

When a `MediaBrowser` picker upload deduplicates to a row in the trash, `revive_picker_duplicate/2` now restores it
(`Storage.restore_file_into(file, nil)`, the same call `Attachments.place/2` makes) before `maybe_set_folder/3`
places it in the upload folder, so the upload gets picked. An upload that still cannot be picked now gets a row in
the upload problems panel. Before, the only trace was a `Logger.warning`.

Checked and fine:
- **Whose row is restored.** Dedup goes by the uploader (`store_file_in_buckets` with `user_uuid`), so only the
  uploader's own file comes back. System-managed rows (tile chunks, hidden unedited originals) have no `user_uuid`,
  so dedup never returns them.
- **Readonly and managed.** `authorize_stored_upload/2` runs before the revive, so a readonly picker returns
  `{:error, :not_allowed}` first. A managed library is forced readonly, and `restore_file_into/2` refuses it again
  (`{:error, :managed}` leaves the row in the trash).
- **Two uploads of the same trashed bytes at once.** `restore_file_into/2` is a conditional `UPDATE … WHERE
  status = 'trashed'`. The loser gets `:not_trashed` and re-reads the row, which keeps the home the winner gave it.
- **Other library.** `in_shown_library?/2` is checked before the revive.
- **Variants.** The restore marks sizes stale and queues the reconciler (`variants_stale_after_restore/1`).

## Findings

### IMPROVEMENT - MEDIUM — POT references were stale (fixed)

`mix gettext.extract --check-up-to-date` failed after the merge. The cause was line-reference drift from this PR and
the PRs before it; no msgid changed. Re-extracted, then ran `gettext.merge --no-fuzzy` over all locales: 0 new,
0 fuzzy, 0 obsolete. The check passes now.

### NITPICK — `unpickable_upload_reason/3` read the file again (fixed)

It called `Storage.get_file(uuid)` only to get the row's `file_type`, which `build_upload_result/6` already puts in
the upload result (the row's value, not the claimed one). It now reads the result:
`unpickable_upload_reason(only_file_type, result)`, and the `result_duplicate?/1` helper is folded in.

### Test coverage — the "not a kind of file this picker takes" branch had no test (added)

The new test uploads PDF bytes as `fake.png` into an image-locked picker and checks the panel row and "0
selected". Unrecognised bytes would not do: the store keeps `file_type: "image"` for an `application/octet-stream`
body (it corrects only the mime), so that branch needs bytes that sniff as another known type.

### IMPROVEMENT - MEDIUM — The panel header says "did not upload" for a file that was saved (not fixed)

The new row goes into the shared upload-problems panel, whose header is "%{count} file(s) did not upload" and whose
Discard-all confirm says "They will not be uploaded". For a new upload whose bytes are another type, the reason
line says "The file was saved, but it cannot be picked here.", so the header contradicts the row. The meaning still
comes through, and the right fix is a separate header for not-picked rows (a new plural msgid in nine locales,
three plural forms in pl/ru/uk). Left for a follow-up, not folded into a review fix.

### NITPICK — Restoring before the placement can still fail (not fixed)

`restore_file_into(file, nil)` clears the home before `maybe_set_folder/3` runs. If the placement is then refused
(the upload folder was trashed meanwhile, `:folder_unavailable`, or it is outside the scope), the file is live and
homeless at the library root, not back in the trash in its old folder, and the panel says "already stored, but it
cannot be picked here". This needs a race against a folder trash, and the file stays reachable from the library
root. Restoring straight into the checked placement folder would close it, but that means copying the private
`Storage.restore_into_target/3` guards into the component.

### NITPICK — Non-picker browsers are not quite "as before" (accepted)

The new `if file.status != "trashed"` guard in `store_upload/8` applies to every browser. Before, a non-picker
re-upload of trashed bytes still called `maybe_set_folder/3`. That linked the trashed row into the upload folder,
or for a homeless row adopted it, and an adopted row then showed in that folder's scoped trash and was restored
there. Now the trashed row is left alone. A link to a trashed file has no use, so this is accepted; it is recorded
because the PR description says non-picker browsers are unchanged.

## Gate

- `media_browser_picker_test.exs` + `media_browser_picker_upload_translations_test.exs` against a scratch
  database: 77 tests, 0 failures. That includes the new test, and the integration tests were not excluded.
- `mix precommit`: green (compile, credo --strict, dialyzer, test.compile, 742 JS tests).
