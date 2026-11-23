# PR #1056 — Add a host-defined file mark to MediaBrowser

**Author:** timujinne · **State:** merged 2026-11-23 (`f37a52a13`) · **Reviewed:** 2026-11-23

Reviewed before the merge, from the PR diff. Fixes made on main after the merge are at the end.

**Verdict:** merged. Fixes 1 and 2 are done on main. The rest is optional polish, still open.

## Checked, fine

- `toggle_mark` passes the library, `viewer_uuid` and `foreign_reference?` gates, because
  `param_uuids/2` collects its `file-uuid`. Pickers refuse it through
  `@picker_file_write_events`.
- `mark_refusal/2` refuses in these cases: `readonly` (managed libraries included, through
  `force_managed_readonly` / `refresh_library_permissions`), the mark switched off, a file the
  browser does not show, and a trashed file.
- The host contract is an assign, not a callback, so there is no N+1: `marked?/2` is a MapSet
  lookup.
- Leaving `toggle_mark` out of `@write_events` (no `own_files_only` check, no removal guard) is
  deliberate and documented. A mark neither removes nor rewrites the file.

## Findings

1. **IMPROVEMENT - MEDIUM — the gettext files were edited by hand.** `default.pot` and the nine
   `.po` files get "Mark", "Remove mark" and "Marked" appended at the end. Moved entries keep
   stale references ("Set as featured" still cites `helpers.ex:445`, now at line 649), so
   `mix gettext.extract --check-up-to-date` reports the files stale. Run the full
   extract/merge round-trip and keep the translations.
2. **IMPROVEMENT - MEDIUM — the 8 integration tests were never run.** The PR body says
   `media_browser_mark_integration_test.exs` was not run locally. It covers the forged uuid,
   the restricted viewer and the viewer sidebar. Nothing runs `mix test` automatically, so
   run it against a real database before merging.
3. **NITPICK — the video/PDF corner badge moves to `top-9` whenever `@mark` is set**
   (`grid_view.html.heex`, `helpers.ex`). In readonly, select mode or the trash, an unmarked
   tile draws nothing in that corner. Move the badge only when a toggle or badge is drawn.
4. **NITPICK — the list column's sr-only header says "Mark" (an action).** It should name what
   the column holds: `mark_state_label/1` ("Marked" or the host's `on_label`).
5. **NITPICK — `normalize_mark/1` checks its input unevenly.**
   - `icon: ""` is kept as an empty icon, while empty labels fall back to the defaults.
   - A non-enumerable `uuids` raises `Protocol.UndefinedError` instead of the documented
     `ArgumentError`.
   - A string-keyed map silently becomes an empty mark.
6. **NITPICK — the moduledoc should say the host owns the set.** `update/2` replaces the
   optimistic set with the host's `mark`. A host that saves the click but leaves its own assign
   as it was sees the click undone on its next re-render. `featured` behaves the same way;
   state it in the `{:set_mark, …}` docs.

## Fixed on main after the merge (2026-11-23)

- **Finding 1.** Ran `mix gettext.extract --merge --no-fuzzy`. `default.pot` and the nine
  `.po` files (plus `errors`/`phoenix_kit`) now match the code, and
  `mix gettext.extract --check-up-to-date` passes. No fuzzy entries. The round-trip also showed
  drift from before these PRs: 14 obsolete msgids were dropped (no longer in `lib/`), and 42
  msgids from the 3.7.0 release work (CDN bucket mapping, the Turnstile integration) were
  missing from the `.po` files. All of them are now translated by hand, in every locale (et
  and ru already had all but seven). Placeholders, Markdown links and Bunny's own UI labels
  (Origin URL, Storage Zone, Add Pull Zone, Security → S3 Authentication) are kept as they
  are. Terms follow each catalog's existing wording ("Pull zone ID", "Test Connection",
  bucket), and the register matches each locale (formal Spanish, German *Sie*). Every locale
  now has 0 untranslated and 0 fuzzy entries.
- **Finding 2.** `media_browser_mark_integration_test.exs` was run on a scratch database with
  the rest of the media suites: it passes.
