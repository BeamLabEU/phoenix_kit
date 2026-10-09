# Claude review — release 2.59.0: EXIF + GPS (V215), per-language file details (2026-10-09)

**Verdict:** sound design; no CRITICAL or HIGH bug. Three MEDIUM robustness bugs in the new EXIF/Geo code fixed
(each reachable from a crafted file or URL), a handful of small improvements recorded. Reviewed as the 3 commits
between `v2.58.0` and `main` (191480d0d, 99a686963, 4a206a150). `mix precommit` exits 0 and the full suite is green
(87 doctests, 8990 tests, 0 failures) on the sandbox test DB. **Not yet published** — another agent reviews first.

Scope: V215 (`latitude`/`longitude` + partial GiST index on `point(longitude, latitude)`), `Storage.Exif`,
`Storage.Geo`, `Storage.read_exif/1` / `exif_tags/1`, the `ProcessFileJob` hook, `FileExifPanel`,
`FileDetailsFields` + `update_file_details_languages/3`, the viewer and detail-page wiring, and the translations.

## Fixed

- **BUG - MEDIUM — a tag of hundreds of digits raised in `Exif.number/1`** (`Float.parse/1` raises
  `ArgumentError` past a few hundred digits). Reached from the upload job (`with_exif`, so a crafted JPEG could
  fail processing on every retry) and from "All EXIF" (`groups/1`, crashing the viewer LiveView). Digits are now
  bounded to 15 per part. Tests added (`exif_test.exs`, "tags a file cannot be trusted…").
- **BUG - MEDIUM — `:erlang.float_to_binary/2` raised on very large values in `groups/1`.** Same bounded-digits
  fix removes the range; a test shows a 15-digit value rendering.
- **BUG - MEDIUM — text in a legacy encoding (Latin-1, Windows-1251 `Make`/`Artist`) is not UTF-8.** It went
  into `metadata["exif"]`, which Jason/Postgrex cannot encode, so the write would fail; and into the LiveView
  diff for "All EXIF". `CaptureDate.parse_exif_properties/1` now drops invalid bytes where the tags are read, and
  `Exif.text/1` guards the public `summary/1` too.
- **BUG - MEDIUM — `Geo.parse_bounds/1` raised on a coordinate of hundreds of digits** (it is meant for URL
  params). `to_number/1` now returns `nil`; test added.
- **IMPROVEMENT - MEDIUM — `Exif.gps_timestamp/2` stored whatever the tag held** (`"ab:cd:ef"`, hour 25,
  100-digit seconds). The date must be `YYYY:MM:DD` and the time a real one, else the timestamp is dropped.
- **IMPROVEMENT - MEDIUM — `FileDetails.by_language/3` let a non-text value through** (a nested map posted as a
  title). The admin detail page put it back into the form (`details_values`), where rendering a map as an input
  value would crash the LiveView. Non-binary values are now dropped like an absent key; test added.
- **NITPICK — `exif_geo_test.exs` asserted ImageMagick 7's `45/1,28/1,1199/100`;** IM 6 (the sandbox) prints a
  space after each comma. The code handles both (the parsers allow whitespace); the assertion now ignores spaces.
- **NITPICK — comment blocks in `process_file_job.ex` were interleaved** (the EXIF note sat under the capture-date
  note, and `merge_exif` split `update_file_with_metadata` from its comment). Reordered, no behaviour change.

## Checked, no change needed

- **V215** is re-runnable, schema-prefix-safe (bare index name on CREATE, qualified on DROP), declared in
  `ExpectedSchema` with a restamped `chain_hash`, and has a down path. The index is partial; photos without GPS
  pay nothing.
- **Privacy:** the position is shown only where the viewer offers the title editor (`details_path`/`edit_target`
  guard, first `handle_event` clauses) and `read_exif` also checks `within_scope?` on the row as it is now. The
  upload log lines print the metadata *before* the EXIF is merged, so no coordinates reach the logs. The detail
  page is an admin page like its existing delete/edit events.
- **Race with an image edit:** `record_exif/4` re-locks the row and checks `original_key?/2` in the same
  transaction, as the storage guide requires; the job path records through the existing guarded transaction.
- **Gettext:** 0 fuzzy; all 34 new msgids are translated in de/es/et/fr/it/pl/ru (`en` is the empty-msgstr
  catalog by convention).

## Recorded, not changed

- **Two `identify` runs per uploaded image** (`CaptureDate.resolve/2` and `Exif.read/1` each read the tags). Cheap
  next to variant generation, but a shared read would need `CaptureDate.resolve` to accept tags.
- **`invalid_details_message/3`** builds the error text from the changeset in English (`Phoenix.Naming.humanize`),
  not through gettext.
- **The map link goes to openstreetmap.org** (`rel=noopener noreferrer`, user-clicked): the one third-party URL
  the panel emits. No tiles load on the page itself.
- **Nothing in the UI uses `bounds:` yet;** the API (`list_files_in_scope/2`, `Geo`) ships ahead of a map view.
- **Existing photos have no position until read** (by design: "Read EXIF" per photo). A bulk backfill job like
  `CaptureDateBackfillJob` is the natural follow-up.
