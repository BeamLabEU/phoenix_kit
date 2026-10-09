# Claude review — release 2.60.0: storage page, repair, V216 folder layout, PRs #919 / #921 (2026-10-09)

**Verdict:** no CRITICAL finding. One real HIGH-class hazard in the new repair flow (a failed restore was counted
healthy, so the reconciler could drop the only good copy) and four MEDIUM bugs fixed; the rest are recorded below
as open, with the reason each was not changed here. Reviewed `v2.59.0..main` (the storage page split, "Fix all
issues" and the repair trail, V216, #919 Ukrainian locale, #921 sitemap slugs). Three read-only review passes
(media view + storage page, repair/report/audit, V216 + locale) and a manual read of #921. Every item below was
re-checked against the code before it was fixed or recorded. **Not yet published; another agent rechecks first.**

## Fixed

- **BUG - HIGH — a failed restore counted as healthy** (`file_repair.ex`, `repair_instance`). After
  `Manager.copy_object/3` failed for a bad copy the instance was still `healthy?: true`, so `original_ok?` stayed
  true and `Reconciler.reconcile_file/1` ran. The reconciler trusts a bucket that merely *holds* an object, so with
  a corrupt copy in a profile bucket and the only good copy in a bucket the profile no longer names, it could unlink
  the good one. Also let sizes be regenerated from an original that still had a damaged copy. Now `healthy?` is
  true only when every restore succeeded, and the reconcile is skipped after any `:failed` action. Regression test:
  "a copy that cannot be put right is reported, and the reconciler is not run after it" (read-only target dir).
- **BUG - MEDIUM — V216 layout broke `recreate_file_instances/5`** (`storage.ex`). It matched
  `[_, _, md5 | _] = String.split(file_path, "/")`: `MatchError` (a 500 on upload) with 0 hash folders, and the
  second hash folder taken for the MD5 with 2 or 3 (original written to `…/<md5>/e8_original.jpg`). Now
  `Path.basename(file_path)`. It was the only depth-coupled spot in `lib/` (searched).
- **BUG - MEDIUM — viewer "Delete forever" did nothing outside the trash view** (`media_browser.ex`
  `delete_file`). Permanent deletion required `filter_trash`, but the viewer opens a trashed file from `?file=`
  links and the storage page; the confirmed delete answered "File moved to trash". Permanent deletion is now
  decided by the row (`status == "trashed"` and home in scope), like `delete_selected`.
- **BUG - MEDIUM — Media showed every `media` holder a dead Storage link and the uploader's email / file uuid**
  (`admin={true}` for everyone; `MediaStorage` is `media.manage`). The browser gets `can_manage_storage` from
  `Scope.can?(scope, "media.manage")` and builds `details_path` only then; the uploader/uuid rows follow it.
  Test in `own_media_test.exs`.
- **BUG - MEDIUM — private user-library data in the site's permanent Activity log** (`audit.ex`). `log_damage` /
  `log_repair` wrote the file name, library uuid and bucket names of a *private* library's file, permanent and
  readable on History by anyone with the site Activity view. Both now skip a file in a private library (a failed
  lookup counts as private).
- **IMPROVEMENT - MEDIUM — the old address `/admin/media/:uuid` named a private library** (its uuid) in the
  redirect to someone who cannot read the file. `MediaDetail.browse_path/2` now falls back to `/admin/media`.
- **NITPICK — "N damaged copies" counted log entries**, so Verify run twice on one copy read "2". Counted by
  distinct object key now. Stale key-layout docs (`store_file` @doc, storage README) point at `KeyLayout`.
- **IMPROVEMENT — Ukrainian catalogue** was 131 msgids behind `default.pot` (all V216 and repair strings fell back
  to English) and carried 7 stale ones. Caught up (see the CHANGELOG; counts checked by script).

## Checked, no change needed

- **V216** is idempotent and prefix-safe (`ADD COLUMN IF NOT EXISTS`, table qualified), constant default so no
  rewrite, down path drops the column and stored `file_path` keeps every existing key. `@current_version`,
  `expected_schema.ex`, the restamped `@chain_hash` and `v216_test.exs` are all in place.
- **Key safety.** The new layout puts no user text in a key — `key_prefix` (validated) plus slices of the MD5 — so
  there is no traversal / collision surface; a layout change never re-keys or orphans an existing file; private
  files get no new guessable keys.
- **Redirect safety.** The old-address redirect builds its target from DB slugs / the library uuid, the file uuid
  is cast, the annotation is URL-encoded; `?file=` on the target re-applies the viewer guards.
- **#921 sitemap** is correct: the canonical grouping key keeps the post's own slug while each language's entry
  uses its `language_slugs` entry, resolved with Publishing's own `resolve_language_key/2` (feature-detected, with a
  stand-in for hosts without it).
- **#919 uk locale:** plural header and forms are right, no placeholder mismatches in any locale.

## Open (recorded, deliberately not changed here)

- **Shared keys in `FileRepair.remake`** — it regenerates in place over a key another file's instance also uses
  (the reconciler passes `fresh_key: true`). Needs the reconciler's shared-key check lifted into a shared helper;
  too wide for a release pass. Reaches only cross-user clones that predate "libraries share nothing".
- **No per-file lock around `FileRepair`** (two admins, or a repair next to the Oban reconciler), and the
  `start_async` task dies with the LiveView on navigation (temp copies, no `storage.file.repaired` entry). Wants a
  per-file advisory lock plus a supervised task; the UI already disables the buttons while one runs in a tab.
- **Repair reads every copy up to three times** (verify pass 1, pass 2, final) — 2–3× egress on cloud buckets.
- **Disabled buckets** are verified and may be written to by `restore`; the reconciler honours `enabled`.
- **`:unreadable` + no good copy** is reported `:unrecoverable` although a transient error may hide a good copy.
- **Non-repairs are logged as repairs** (each click on an unfixable file writes a permanent entry; no dedupe).
- **Viewer sidebar writes (details, tags, EXIF read, rotate) skip the browser's `own_files_only` guard** — a
  contributor in a shared library can edit another member's file details. Pre-existing for details; tags widen it.
- **Per-rendition downloads** (annotated / burned / custom sizes) are no longer offered to a `media` holder; they
  exist on the `media.manage` storage page only. Confirm that narrowing is intended.
- **`MediaStorage.mount` / `MediaDetail.mount` query the DB** (the old page did too); `reload/1` keeps a stale
  Verification card after "Make"; repair actions need `media.manage` but not a `:edit` check on the file's library.
- **No test** runs an upload under key layouts 0/2/3 (the `recreate_file_instances` bug above hid for that reason).
- Nits: `resource_type` of the new entries (`bucket`, `file`) differs from `storage_bucket`; one Activity entry and
  broadcast per damaged copy; en `default.po` carries 46 new fuzzy-flagged empty entries; ru singular forms drop
  `%{count}` (pre-existing); viewer deep link `?annotation=` focuses a shape only on Media, not Libraries.
