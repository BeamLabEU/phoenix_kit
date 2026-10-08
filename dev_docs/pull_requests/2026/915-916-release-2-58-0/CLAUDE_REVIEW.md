# Claude review — PR #915, PR #916 and the V212–V214 storage work (2026-10-08)

**Verdict:** sound; no CRITICAL or HIGH bug. One MEDIUM bug fixed (CSP keyword misattribution), several
MEDIUM improvements fixed, the rest recorded. Reviewed as the 16 commits between `v2.57.1` and `main`, for
release 2.58.0. The suite was green before the fixes (8900 tests, 0 failures); the focused suites are green
after them. **Not yet published** — another agent reviews first.

Scope: PR #915 (self-hosted viewer libraries + load notice, from `alexdont`), PR #916 (site time zone in the date
formatters, from `timujinne`), and the maintainer's direct commits: V212 aspect ratio + Shape filter, V213/V214
Default-set sizes, the Media toolbar filters, the cross-library clone fix, and the etcher 0.20 / deps bump.

## Fixed

- **BUG - MEDIUM — a keyword CSP violation was pinned on a library failure** (`phoenix_kit.js`, the
  `securitypolicyviolation` listener). `blockedURI` of `"inline"`, `"eval"`, `""` resolves against the page, so it
  read as the page's own origin and matched every same-origin library — which, since B1, is all of them. A library
  that merely 404'd was reported as "Blocked by this site's Content-Security-Policy". Now only an absolute URL is
  matched; test added (it fails without the fix).
- **IMPROVEMENT - HIGH (#916) — a second uncached settings read per formatted value.** Each formatter read the
  format key and now `time_zone` straight from the database; the Activity list (50 rows) went from ~100 to ~200
  queries per render. `time_zone` now goes through `get_setting_cached/2`. The integration test evicts the key
  synchronously (`invalidate_now`) after every write and on exit, and is `async: false`, because `invalidate/2` is
  a cast and the cache outlives the sandbox rollback. The format keys stay uncached as before.
- **IMPROVEMENT - MEDIUM (#915) — library URLs were revalidated on every viewer open.** Plug.Static sends the
  immutable header only for `?vsn=` requests; URLs now carry `?vsn=d` (the name already holds version and hash).
- **IMPROVEMENT - MEDIUM (#915) — non-atomic library write.** A compile killed mid-write left a truncated file
  that was never repaired. Written to `.tmp` and renamed; a file of the wrong size is rewritten.
- **IMPROVEMENT - MEDIUM (#915) — the doctor could not see the main failure mode** (a host with a custom root
  layout never loads `phoenix_kit_modules.js`, so `PHOENIX_KIT_LIBS` is undefined and every library fails with
  `facts`). `mix phoenix_kit.doctor` now also checks that file names the libraries.
- **IMPROVEMENT - MEDIUM (#915) — `mix.exs` comments cited deleted tests** (`leaf_bundle_pin_test.exs`, the
  jsDelivr tag pins). Reworded: the ceilings are a manual rule now.
- **IMPROVEMENT - MEDIUM (storage) — the Shape filter listed videos.** A 2.39:1 video or a phone screen
  recording passed "Panoramas"/"Tall" while the badge marks images only. A shape filter now lists pictures only.
- **IMPROVEMENT - MEDIUM (storage) — `VariantSets.variant_for/2` and `stand_in/3` ignored a size's `shape`.** An
  operator-made fixed-box "wide" size could be offered for a portrait file. Both now apply the generator's rule.
- **IMPROVEMENT - MEDIUM (storage) — `msgid "Panorama"` missing from every locale catalog** (only in the `.pot`),
  plus two stray fuzzy flags in `en` ("All shapes", "Every picture"). Added/translated in all locales, flags
  cleared; fuzzy count is 0 everywhere.
- **NITPICK — `?type[a]=b` raised in `URI.encode_query`** in the Media embed's `put_view_options`. Non-binary
  values are dropped.
- **NITPICK (#916) — docs of the `*_with_cached_settings` variants** said "taken as given" where a non-UTC
  `DateTime` is brought to UTC first.

## Recorded, not changed

- **#916, MEDIUM — the Publishing editor preview and `post_show.format_datetime` (sibling repo
  `phoenix_kit_publishing`) now show the site-zone clock** next to an input labelled "(UTC)". Intended by the PR
  ("a DateTime is shown in the site zone"), but the label and the preview now disagree; to be settled in that
  repo (label the preview "site time", or call the pre-change path).
- **#916, MEDIUM — Sessions, Activity, Media detail and `user_settings` show the site zone, not the viewer's**
  (`TimeZone.for_viewer/1` exists and Users / User details use it). Strictly better than raw UTC; inconsistent.
  `last_active_label` mixes a UTC day diff with a site-zone clock near midnight.
- **#915 — `phoenix_kit_sortable.js`** (the host-importable legacy loader, documented in
  `guides/draggable-list-component.md`) still loads SortableJS from jsDelivr.
- **#915 — `vendor_all/1` lacks the `ensure_loaded` loop `run/1` has**, so `update`/`install` may write
  `phoenix_kit_modules.js` without external modules' hooks; the next `mix compile` repairs it (not verified).
- **#915 — no SRI on the opt-in CDN fallback** (`import()` cannot carry it anyway); `library_cdn_fallback` is read
  at compile time (ignored in `runtime.exs`); wavesurfer's BSD-3 licence sits only in core's `vendor_libs`, not
  beside the host's copy; `PHOENIX_KIT_LIB_BASE` relative values resolve differently for `import()`.
- **Storage — 90°/270° rotation made in the viewer lives in `metadata["rotation"]`**, not in width/height, so such
  a file keeps its unrotated shape (EXIF orientation is covered). Documented as a limit in the CHANGELOG.
- **Storage — `remove_dropped_sizes/3` ignores shape**, so renditions of a size that stopped fitting a file are
  kept (storage only, no wrong output).
- **Storage — controlled `MediaBrowser` hosts must handle `:type`/`:sort`/`:shape` navigate keys.** The toolbar
  no longer applies them locally in `on_navigate` mode; only core's Media page uses that mode today.
- **Storage — no test of the Shape filter under a restricted viewer.** Traced: `Shape.filter` is composed before
  `where_library`/`where_viewer` and `set_shape_filter` names no file, so there is no leak today; a test is worth
  adding.
- NITPICKs: `@audited_size_fields` omits `shape`; V213/V214 `down` deletes the seeded names even if an operator
  made a same-named size; `Dimension.changeset` has no `validate_required` for `shape`; the "Made for" field is
  hidden for video sizes; `short_month_test` silently depends on the site zone being "0"; no DST-boundary test.

## Traced, no finding

- **V212–V214:** idempotent and prefix-safe (bare index names on CREATE, qualified DROP, schema-anchored checks);
  division by zero and nulls guarded in the generated column; seeded rows are `ON CONFLICT (variant_set_uuid,
  name) DO NOTHING`, so an admin-edited size is never clobbered; installs with files are left alone;
  `expected_schema.ex` `@chain_hash` recomputed and matches the 80 chain files. **V212 rewrites
  `phoenix_kit_files` once under ACCESS EXCLUSIVE and needs Postgres 12+** (stated in its moduledoc).
- **Cross-library clone fix:** `get_active_file_by_checksum/2` is the only donor lookup and now filters by library.
- **#915:** no path traversal or host-file clobbering (constant names + hash, write-if-absent, never deleted);
  vendored checksums, licences and provenance READMEs match; Etcher 0.20 honours `sortableUrl` /
  `loadSortableFromCdn = false` exactly as `phoenix_kit.js` sets them; gettext complete in all locales; the notice
  uses `textContent` only.
- **#916:** the `tz` database is a core dependency (no host config needed); unset/invalid zones fall back to
  UTC / the unshifted value; only UTC→zone conversions happen, so no DST gap/ambiguity tuples; `Settings` reads
  already `rescue` and `catch :exit`; no core caller passes a non-UTC naive value.
