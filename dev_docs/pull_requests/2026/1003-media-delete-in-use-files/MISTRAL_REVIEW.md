# PR #1003: Fix permanent delete in the media trash crashing when a file is in use — Mistral review

**Reviewer:** Mistral · **Baseline:** `a2dd1fe8e` on `main` (merge of #1003).

## What the PR does

`Storage.delete_file_completely/2` now rescues the `Ecto.ConstraintError` a
`RESTRICT` foreign key raises and answers `{:error, :in_use}` instead of
letting it crash the LiveView / trash cleanup. `delete_folder_completely/3`
keeps the folders that still hold such a file (and their ancestors in the
subtree) and answers `{:error, :in_use}`. The media browser counts per-item
results instead of flashing success for everything, and its `put_flash` now
also forwards to the host LiveView (a component's flash never reaches the
page).

## Verified sound

- Stored objects are only deleted after the row transaction commits, so an
  in-use file loses no bytes (`delete_file_and_objects/1`).
- Every caller of `delete_file_completely` handles the new tuple:
  `delete_counting/1` (empty trash / `prune_trash`) logs and skips,
  `Libraries.purge_row/1` refuses the library removal, the browser handles
  `:in_use` per action. `ResourceFolders.purge_named/1` ignores the return,
  which is its contract.
- The rescue only takes `type == :foreign_key`; anything else reraises.
- `folders_still_holding/2` walks parents only within the subtree and treats
  a root-homed (`folder_uuid` nil) blocked file as keeping nothing — correct.
- The `put_flash` wrapper keeps the component copy and forwards to the parent
  via `parent_flash/3`; `handle_parent_info`'s own clause calls
  `Phoenix.LiveView.put_flash` directly, so no recursion.

## Findings

### IMPROVEMENT - MEDIUM — guard-kept files were double-reported as failures (fixed)

With #999's removal guard active, a bulk delete in the trash view
(`delete_selected` with `skip?`) excepts the in-use files
(`removal_except`), but the handler still mapped them to
`{:error, :not_removable}` and flashed "N item(s) could not be removed." on
top of the guard's own "X deleted, Y kept: in use". The kept file was
reported as both kept and failed.

**Fix:** `delete_selected` now rejects `removal_except` files before mapping
results (`lib/phoenix_kit_web/components/media_browser.ex`), so only genuine
refusals count as failures. Locked by a new `refute flash(view) =~ "could
not be removed"` in `media_browser_removal_guard_test.exs`.

### IMPROVEMENT - MEDIUM — i18n: six new strings were pot/et/ru-only (fixed)

Four msgids were extracted to `default.pot` and translated only to et/ru;
de/en/es/fr/it/pl/uk fell back to English. Worse, two strings
("Could not delete the folder. Nothing was removed." / "Could not move the
folder to the trash. Nothing was moved.") were never extracted to the pot at
all. #999, merged the same day for the same component, shipped all locales.

**Fix:** added both folder strings to `default.pot`, added all six entries
to de/en/es/fr/it/pl/uk (et/ru got the two folder strings), and extended
`media_browser_delete_translations_test.exs` from `~w(ru et)` to all eight
shipped locales (`~w(de es et fr it pl ru uk)`) with the folder strings in
`@singular`. 17 tests pass.

### NITPICK — a concurrently deleted file reports `:in_use`

`delete_folder_completely/3` keeps folders for ANY failed file deletion,
including `{:error, :not_found}` from a concurrent delete, and then answers
`{:error, :in_use}`. The conservative answer is safe (nothing is wrongly
deleted), and the race is narrow; left as is.

## Validation

- `mix test test/phoenix_kit_web/components/media_browser_delete_translations_test.exs`
  — 17 tests, 0 failures (PostgreSQL was in recovery, so `:integration`
  tests were excluded; the translations tests are unit).
- `mix compile --warnings-as-errors` — clean.
- `mix precommit` — see the session gate run; DB-backed integration tests
  could not run while the test database was in recovery mode and should be
  run once it is back: `mix test test/integration/phoenix_kit_web/components/media_browser_removal_guard_test.exs test/integration/storage/delete_file_in_use_test.exs`.
