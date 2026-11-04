# PR #1003 — Fix permanent delete in the media trash crashing when a file is in use

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; follow-ups listed

Mistral's two fixes (double reporting of guard-kept files, i18n of the delete messages) and 8a047f0b4
(`:not_found` no longer blocks a folder) are in place.

## Checked and sound

- **Rescue placement.** `in_use_as_error/2` wraps the whole top-level transaction, so the rollback has
  happened before the rescue; only `type == :foreign_key` becomes `{:error, :in_use}`, anything else is
  re-raised.
- **Objects only after commit** (`delete_file_and_objects/1` → `delete_stored_objects`), so an in-use file
  loses no bytes.
- **`folders_still_holding/2`** keeps the blocked file's folder and its ancestors up to the subtree top.
- **Every caller handles the new tuple:** `delete_counting/1` (empty trash, prune) logs and skips,
  `Libraries.purge_row/1` refuses, the browser's three delete paths have an `:in_use` branch.
- **Flash forwarding.** The component's `put_flash` also forwards to the host via `parent_flash/3`;
  `handle_parent_info` calls `Phoenix.LiveView.put_flash` directly — no recursion.

## Findings

### IMPROVEMENT - MEDIUM — the managed-folder message was untranslated (fixed 2026-11-03, with the whole gap)
`managed_folder_message/0` ("This folder belongs to a module and can't be deleted here.", added in
124e9c515) is in no catalog, and `MediaBrowserDeleteTranslationsTest` does not list it. Not hand-appended:
the catalogs are **282 msgids behind `lib/`** (`mix gettext.extract` on this tree; 45 obsolete), from many
PRs and direct commits since the last round trip — see the #1001 review. The project rule is the full
extract/merge round trip with every fuzzy entry hand-fixed, so this goes into that pass; add the string to
the test's `@singular` then.

### IMPROVEMENT - MEDIUM — Empty trash keeps in-use files silently and leaves the trash view (OPEN)
`empty_trash` only gets `{:ok, count}` back (`delete_counting/1` logs and drops refusals): with one of three
trashed files attached and no guard holding it, the flash says "2 files permanently deleted", the view
leaves the trash (`filter_trash` follows `removal_except/1`, which is empty), and the kept file is never
mentioned. Return the kept uuids from the Storage call and reuse `not_removed_message/1`.

### NITPICK — every failed file delete in a folder is reported as "in use" (not changed)
`blocked` takes every failure but `:not_found`, and the folder answer is `{:error, :in_use}` whenever
something was kept, so a changeset rollback reads as "in use by something else". Not changed because the
alternative message ("Could not delete the folder. Nothing was removed.") would be false after a partial
delete; this wants its own wording.

### PLAUSIBLE — the rescue misleads inside a caller's transaction (not changed)
Inside a caller's `Repo.transaction` there is no savepoint: the FK violation aborts the outer transaction,
the function still answers `{:error, :in_use}`, and the caller's next query and commit fail. No current
caller does this (CRM and inbox call after commit; the sandbox hides it with savepoints). Document "call
outside a transaction" or check `repo().in_transaction?()`.

### Related, not this PR — library purge on a user's own storage deletes bytes first
`purge_file(file, true)` deletes a file's objects on the user's own bucket before `purge_row` learns the
row is `:in_use`; the still-referenced row is left with its bytes gone, and the purge retries forever
logging "kept their objects on the user's own bucket". Worth its own fix: check the references (or run the
row delete) before the object delete.

**Follow-up 2026-11-03 — catalogs round-tripped.** `mix gettext.extract` + `merge` added the missing
msgids (214 per Western locale, 200 in et/ru) and flagged 88 (80) entries fuzzy, each serving a
translation copied from a different msgid. All were translated by hand (one translator per locale,
applied through a round-trip tool that rewrites only `msgstr`/flag lines and checks `%{}` parity):
**0 untranslated, 0 fuzzy in de, es, et, fr, it, pl, ru, uk**; `en` stays empty by design, its 142 fuzzy
flags cleared (two served wrong English: "Manage members" → "Managers", "Personal storage" →
"Personal"). A second extract + merge changes nothing.
