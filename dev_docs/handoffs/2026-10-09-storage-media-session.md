# Handoff: PhoenixKit storage and media work (session of 2026-10-08 to 2026-10-09)

Written so a fresh session can continue without the chat. Facts here were true when it was written;
re-check commit hashes with `git log` before relying on them. It continues
`2026-10-07-storage-media-session.md`, which is still the reference for the viewer, HEIC, focal point and
libraries work.

## Repos and state

| Repo | Path | Branch | Latest commit | Working tree |
|---|---|---|---|---|
| phoenix_kit (core) | `/www/phoenix_kit` | main | `3ea40f527` (release 2.59.0) | clean, pushed |
| phoenix_kit_photos (module) | `/www/phoenix_kit_photos` | main | `4856027` | clean, untouched this session |
| fotki (host app) | `/www/app` | main | `f3bc5a2` | **uncommitted**, see below |

Core is at **2.59.0**, migrations up to **V215**. 2.58.0 carried V212 to V214 and Alex's viewer-library PR;
2.59.0 carries V215 and the tabs/EXIF work, plus another agent's hardening pass on top of it
(`dbfe05683`, `6b1011339`: hostile EXIF input, map-bound wrapping, concurrent details edits).

**Host (`/www/app`) uncommitted, and they matter:** `priv/repo/migrations/*_phoenix_kit_update_v21{1_to_v212,
2_to_v213,3_to_v214,4_to_v215}.exs` (a deploy needs them), `mix.lock` (etcher 0.20, swoosh 1.29, pubsub 2.4.1),
`lib/fotki_web/components/layouts/root.html.heex` (`phx-track-static` on the two PhoenixKit script tags), and
`config/dev.exs` (**not mine**, the user's live-reload/reloadable_apps tweak). Commit only when asked.

**Open PR:** #919 "Add Ukrainian (uk) translations" (timujinne) was a draft for a while; the user said not to
touch it. It adds locale files, so it will conflict with `.po` changes; resolve entry by entry against the base.

## What was done

**Media/Libraries headers.** The library selector moved from a `<select>` in the page body to the ▾ beside the
title in the admin header (`page_title_switcher`, `Core.CrumbSwitcher`), on Media and on `/admin/libraries/<lib>`.
Media drops its section crumb on the default library ("Media / Media" read oddly). `CrumbSwitcher` items may carry a
`hint` ("Site"/"Mine"). The CrumbSwitcher hook closes the panel again after a pick once the patch lands.

**Libraries share nothing.** An upload into a second library no longer clones files from another library: a
duplicate donor must be in the **same library** (`get_active_file_by_checksum/2`). Earlier clones across libraries
keep sharing objects until re-uploaded.

**File shape (V212).** `phoenix_kit_files.aspect_ratio` is a generated `STORED` column (`width/height`) with a
partial index `(library_uuid, aspect_ratio)`. `Storage.Shape` holds the thresholds as constants (**wide ≥ 2.0,
tall ≤ 0.5**; a per-user setting is a stated future step) and `list_files_in_scope(shape: :wide | :tall)`.
Pictures only. Why a number and not a flag: no backfill, follows edits, thresholds stay a choice.

**Default set sizes (V213, V214)** — 14 sizes after "Reset to defaults":
`thumbnail` 150w, `thumbnail_square` 150², `small` 300w, `small_square` 300², `medium` 800w, `large` 1920w,
`mini_square` 64² (q70), `thumbnail_wide` / `small_wide` / `medium_wide` (150 / 300 / 800 **tall**, `fit_by`
height, `shape: wide`), and the four video sizes. Squares and mini crop around the subject (`crop_mode: focus`).
A rendition has a `shape` (any/wide/tall; the standard sizes must stay `any`); the generator and
`expected_variants/1` both read it, from the file's row when the struct in hand predates its size. The grid uses
`small_square`, list rows `thumbnail_square`, and marks a panorama with a badge beside the file size.
**Rollout rule (user's call):** the migrations add the new sizes only to installs **with no files**; existing sites
get them from "Reset to defaults". Recreating missing renditions is deliberately **not** automatic: it waits for a
long-running-jobs feature (see Open).

**Media toolbar.** daisyUI 5 renamed `active` to `menu-active`, so the chosen row never showed (Media, Activity,
Users: fixed). The Filter button says "All types"; the Filter menu has a Shape section (All shapes / Panoramas /
Tall). Type, sort and shape live in the URL (`?type=&sort=&shape=`) and survive folder changes
(`Embed.keep_view_options`), so a reloaded iPad tab comes back to the same view.

**Title & description in every language.** One form, a tab per language, one Save (`Core.FileDetailsFields`, used by
the viewer sidebar and the detail page). Tabs switch client-side (`LiveView.JS`), so typed text in other tabs
survives. `Storage.update_file_details_languages/3` writes all languages and tags in one held write and skips
languages that did not change; `FileDetails.by_language/3` reads the post. The viewer section is open from the start.

**EXIF and GPS (V215).** `Storage.Exif` turns ImageMagick's tag dump (`CaptureDate.read_exif/1`) into a summary kept
in `metadata["exif"]` (camera, lens, exposure, dates + offset, gps; serial number and maker note are not kept; `{}`
means read-and-empty) and the position into `latitude`/`longitude` with a partial **GiST index on
`point(longitude, latitude)`** (built-in Postgres). `Storage.Geo` + `list_files_in_scope(bounds: {s, w, n, e})`
answer a map box, including across the antimeridian. `Storage.read_exif/1` re-reads a photo (an edited photo's
unedited backup is read; recorded only while the bytes are still the original), `Storage.exif_tags/1` is the whole
dump. UI: dimensions rows and a "Camera & location" panel (`Core.FileExifPanel`: groups, "Show on a map" link,
Read EXIF, Read again, All EXIF). The viewer shows it only where it offers the title editor; never in a public
lightbox.

**Host.** `phx-track-static` on the PhoenixKit script tags so open tabs reload after a deploy (needs
`mix assets.deploy` / `phx.digest` for hashed URLs; dev has none).

## Open / next

1. **Long-running jobs with a progress screen** (pause/stop, stats): needed to recreate missing renditions and to
   backfill EXIF for existing photos. Today: "Reset to defaults" + "Check every file", and a per-photo Read EXIF.
2. **The map UI.** The data layer is ready (`bounds:`, `Geo.parse_bounds/1`); clustering for a zoomed-out map
   (a grid `GROUP BY`) is not built.
3. **Per-user wide/tall thresholds** (settings); today constants in `Storage.Shape`.
4. **"Not translated yet" cue** in the language tabs (a note or an `English: …` placeholder under an empty
   language): proposed, not built. Users read the grey fallback placeholder as a value.
5. **Offered, not done:** swap the tab strip for the shared `language_switcher` (tabs, `on_click_js`) and the
   inputs for `Core.Input`/`Core.Textarea`.
6. **Core installer text** should mention `phx-track-static` on the PhoenixKit script tags.
7. **Known limits (from the 2.58.0 notes):** a 90°/270° viewer rotation lives in `metadata["rotation"]` only, so such a
   file keeps its unrotated shape; renditions of a size whose shape stopped fitting a file are kept, and the
   reconciler does not add new ones until the set's revision moves.
8. **From the 2026-10-07 handoff, still open:** retest viewer neighbour warming on the MacBook (network tab); Live Photos
   (the picker sends the still only; motion needs ffmpeg and the PhotoSync route); WebDAV/PhotoSync parked behind its
   Phase 0; `ffmpeg` is still not installed in the container. Skipped by decision: iPad not uploading some JPEGs
   (iOS picker behaviour, nothing to do server-side).
9. **Host housekeeping:** now that the viewer libraries are self-hosted, the jsdelivr entry in the CSP can come out;
   the Tailwind line scanning `../../../phoenix_kit/lib` goes when the host returns to the Hex release.
10. One unexplained thing: a title Save once never reached the server (no `save_media_details` in the log, page had
    reloaded several times). Likely the dev live-reload (below) or Safari discarding the tab; not reproduced.

## How to work here

- **Host:** `supervisorctl restart elixir` (logs `/var/log/elixir.log`). **Core is not hot-reloaded** in the host
  (`reloadable_apps: [:fotki]`): restart after core edits. The dev live reload watches `../phoenix_kit/lib` and
  `priv/gettext`, so **every core edit reloads the user's open browser tab** and loses unsaved typing: avoid editing
  core while they test.
- **After a core change with a migration:** migrate the dev DB **before** restarting, or the host dies on the missing
  column: `cd /www/app && mix phoenix_kit.update --no-start --yes --skip-assets` (writes a host migration file). After
  a pull that changes `mix.lock` run `mix deps.get` in both repos; the running host then needs a restart.
- **Dev DB:** `PGPASSWORD=$DB_PASSWORD psql -h $DB_HOSTNAME -p $DB_PORT -U $DB_USERNAME $DB_DATABASE`. Test DB:
  `PGPASSWORD=postgres psql -h localhost -U postgres phoenix_kit_test`.
- **New migration checklist (core):** `vNNN.ex` with `up_statements/1`/`down_statements/1` and a `Locks` note; docs
  entry and `@current_version` in `migrations/postgres.ex`; read the catalog shape from the test DB (after one test run
  migrates it) into `expected_schema.ex` (columns: `pos`, `default`; indexes: `keys`, `method`, `predicate`,
  `opclasses`); restamp `@chain_hash` with
  `MIX_ENV=test mix run --no-start -e 'IO.puts(elem(Mix.Tasks.PhoenixKit.ReleaseCheck.compute_chain_hash(),0))'`;
  a `test/phoenix_kit/migrations/vNNN_test.exs` (columns, re-run, round trip). Data-only migrations that add sizes use
  `WHERE NOT EXISTS (SELECT 1 FROM phoenix_kit_files)`.
- **Tests:** one `mix test` at a time against the DB (two at once deadlock on `ALTER TABLE`). Run the full suite with
  `run_in_background` on the command itself (a nested `&` is killed): `MIX_ENV=test mix test --max-cases 8`, ~10 min,
  8985 tests at 2.59.0. JS: `node --test test/js/*.test.cjs`. A fresh test DB now carries the squares/wide sizes in the
  Default set, so tests that need "no subject crop" delete the focus renditions in setup. The Media `view=all`
  URL-sync test is occasionally flaky under load (`assert_patch` 100 ms).
- **Before committing core:** `mix format`, `mix credo --strict` (it checks test files too: lines ≤ 120),
  `MIX_ENV=test mix compile --warnings-as-errors`.
- **Translations:** `mix gettext.extract --merge`, then fill the new msgids in the 7 locales and clear fuzzy marks
  (a script replacing the `msgstr` of entries that are empty or fuzzy works well); `--check-up-to-date` must pass.
- **Splitting a commit when two features share files:** `git add -p` is unavailable; stage a hand-built version of
  each shared file with `git hash-object -w` + `git update-index --cacheinfo`, verify it compiles in a scratch
  `git worktree`, commit, then `git add -A`.
- **Commit rules:** commit and push only when the user says so. Messages start with Add, Update, Fix, Remove or Merge
  and end with the Co-Authored-By trailer. The CHANGELOG and version bump belong to a release.

## Addendum (same day): Details page split into media view + storage page

Uncommitted in core (nothing committed or pushed). `mix test` full run was green apart from six tests that
pointed at the old page, since fixed; credo, format, gettext check and dialyzer pass.

- **Header** over a file's page: `Media / [library] / <file name> / Storage`. `MediaDetail.trail/2`, `view_path/2`.
- **Viewer sidebar is now "Media details"**: status/trash state, uploaded by + file uuid (admin context only),
  updated, PDF pages, tags (edited with the title in one Save), Move to trash / Restore / Delete forever (sent to
  the MediaBrowser, which closes the viewer). Its link "Storage" goes to the storage page.
- **`/admin/media/:uuid` now redirects** to the media view (`?file=`, keeps `?annotation=`; `Media` selects that
  shape via `etcher:select-shape`, **unverified in a browser**). The old page (editor, comments, EXIF, downloads)
  is gone; its tests were removed or moved (`media_viewer_details_test.exs`, `media_browser_test.exs`).
- **Storage page** `/admin/media/:uuid/storage` (`Live.Users.MediaStorage`, `media.manage`): checksum of the
  original, renditions table (wanted vs stored, state, checksum, buckets), Verify copies (`FileReport.verify/1`,
  `Manager.checksum_in/2` reads each copy from its own bucket), Make what is missing (`Reconciler.reconcile_file/1`),
  per-row Make, Regenerate all, unedited original (download / restore / delete).
- Ideas not built: expected copy count per profile, last-verified stamps written back, bulk verify, a
  storage-usage view of unedited originals, folder crumbs in the header.
