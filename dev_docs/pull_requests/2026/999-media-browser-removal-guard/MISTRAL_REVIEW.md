# PR #999: Add a removal guard and server-side confirmation to the media browser — Mistral review

**Reviewer:** Mistral · **Baseline:** `66fe06c1b` on `main` (merge of #999), re-read after #1003.

## What the PR does

New `PhoenixKit.Modules.Storage.RemovalGuard` behaviour: a host module
(`config :phoenix_kit, :file_removal_guard`) is asked `places/2` before any
media-browser event that makes a file disappear. The browser stops the six
removal events in a `handle_event` clause placed after the viewer /
own-files / library gates, builds the plan from `Storage.removal_plan/2`
(the same decisions the operations carry out), and shows a server dialog
(`RemovalModal`, popover top-layer, token-checked confirm/cancel/release).
The confirmation replays the original event through every gate again with a
fresh plan; if the files changed, the dialog is redrawn.

## Verified sound

- `@removal_events` covers every event that can make a file disappear —
  cross-checked against every `Storage.remove_file_from_folder` /
  `trash_folder` / `delete_*_completely` / `empty_trash` call site in the
  browser; `delete_all_orphaned` is deliberately out (documented), moves are
  rehomes, not disappearances.
- The analysis clauses read the same params and predicates as the handlers
  (`"file-uuid"`, `"file_uuid"`, `"folder_uuid"`, `"id"`,
  `removable_here?/3`, `appearance_folder/2`, the picker's no-permanent-delete
  refusal), and the replay drops the gate markers so the gates re-judge.
- `Removal.call/3` runs the host callback in an unlinked monitored process
  with a kill-on-timeout, fails closed on raise/exit/bad shape/foreign uuids,
  and copies `$callers`, locale and logger metadata. Logs name the module and
  exception class, never request data.
- `safe_href/1` accepts only `Routes.local_path?/1` paths or `http(s)://`
  URLs; `label: nil` places leak neither detail nor href. Modal text is
  HEEx-escaped.
- Tokens are 72-bit random, single-use (pending cleared on confirm), and a
  mismatched token is a no-op.
- `empty_trash` gained `except:`/`only:` and stays in the trash view when
  something was kept; the plan's managed-library refusals match the
  operations.
- gettext: all new strings shipped in pot + all 9 `.po` files, with a
  translations test over 8 locales.

## Findings

### IMPROVEMENT - MEDIUM — interaction with #1003 double-reported guard-kept files (fixed)

#1003's `delete_selected` counted guard-excepted files as
`{:error, :not_removable}` failures ("could not be removed") in addition to
the guard's "kept: in use" summary. Fixed in the #1003 follow-up review (see
`../1003-media-delete-in-use-files/MISTRAL_REVIEW.md`): excepted files are
now excluded from the results entirely, with a regression assertion.

### NITPICK — folder+file selection title names only the folders

`RemovalModal.title/4` shows "Move N folders and their contents…" whenever
`folders > 0`, even when files are selected too; the file count appears in
the list below. Cosmetic only, left as is.

## Validation

Translations tests pass (unit). Integration suite for the guard
(`media_browser_removal_guard_test.exs`, 1000+ lines) requires PostgreSQL,
which was in recovery mode during this review — run before merging anything
on top: `mix test test/integration/phoenix_kit_web/components/media_browser_removal_guard_test.exs`.
