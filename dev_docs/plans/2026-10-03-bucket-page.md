# Bucket page — handoff for the next stage

Written 2026-10-03 at the end of a session that shipped **2.49.1** and **2.50.0**. Read this first, then start
on the bucket page. Nothing here is built yet except what "Already done" lists.

State at handoff: `main` at `32edc704e` (2.50.0, published to Hex, tagged `v2.50.0`), tree clean, pushed.

## Status (2026-10-03, later the same day)

Decisions confirmed by the user: **separate `:show` page** (Edit stays the form), **probe is a button only**,
**the log (section 6) comes later as its own release**, **section 7 (retire checklist) skipped for now**.
Sections 1–5 are built (unreleased, `## Unreleased` in the CHANGELOG): `Live.Modules.Storage.BucketPage`,
`BucketInfo` (the lifted display helpers), `Storage.bucket_contents/1`, `bucket_location_health/1`,
`probe_bucket/1`; tests in `test/integration/phoenix_kit_web/live/bucket_page_test.exs`.

Left out on purpose: the per-bucket **"files missing a copy here"** number (the reconciler has no per-bucket
query for it; Health shows location rows by status, the last verification stamp, the global count of
instances not yet checked against any bucket, and the files still on a draining bucket), and the **serve
order** column in "Used by" (`Profiles.bucket_usage/1` does not return it). The probe result lives in the
LiveView only; it is lost on reload until the log exists.

## Already done (do not redo)

**2.49.1 — a bucket in use is protected, and the Buckets list says who uses it.**
- `Storage.delete_bucket/2` and `Storage.update_bucket/3` (turning `enabled` off) return
  `{:error, {:in_use, usage}}` while **any** storage profile has a row for the bucket, whatever the row's role
  or status. A user's personal profile counts. Enabling is always allowed. A user's own bucket (`owner_uuid`)
  is not guarded on disable. The user chose the strict rule on purpose ("this is data, better safe than
  sorry") — do not soften it to "only while active".
- Deleting no longer strips an empty bucket from every profile (`Profiles.remove_bucket_everywhere/1` is gone);
  the `phoenix_kit_storage_profile_buckets_bucket_fkey` FK is `RESTRICT` and backs the check.
- `Profiles.bucket_usage/1` (batched: `%{bucket_uuid => [usage]}`, each usage has profile name, `is_default`,
  `owner_uuid`, `role`, `status`, `libraries`), `Profiles.library_names_using/1` (site libraries named, user
  libraries only counted).
- `PhoenixKitWeb.Live.Modules.Storage.BucketUsage` (`lib/modules/storage/web/bucket_usage.ex`): `refusal_message/3`,
  `used_by_text/1`, `usage_cell/1`. **A user's profile or library is counted, never named** — private to them.
- UI: "Used by" column on the Buckets tab (reloaded on every `handle_params` for the tab), an in-use notice on
  the edit form, named libraries in the refusal to delete a profile.

**2.50.0 — the new-bucket form asks for a storage profile.**
- `Storage.create_bucket(attrs, profile: nil | uuid | :default)`. `:default` is what it does when no option is
  given (kept so seeds, repair and ~59 test call sites are unchanged); the form passes its own choice, **default
  "None: just add the bucket"**. `Profiles.add_bucket/3` generalises `add_to_default/1`.
- A bucket in no profile receives and serves nothing. The created-flash says so.

Key tests: `test/integration/storage/profiles_test.exs` ("a bucket in use", "where a new bucket is placed"),
`test/integration/phoenix_kit_web/live/bucket_usage_ui_test.exs`, `bucket_form_test.exs`.

## The next stage: a page per bucket

The user wants to click a bucket's name on Settings → Media → Buckets and land on a page with everything about
that bucket. They asked "think what else would be helpful". This is the agreed proposal; **sections 1–5 are
approved in principle, section 6 (the log) is the open question** (below).

| # | Section | What it shows | Where the data comes from today |
|---|---|---|---|
| 1 | Overview | type, location (path / bucket name + endpoint/region), provider, the Integrations connection (name + service, linked), access type, priority, `max_size_mb`, enabled, created/updated; the legacy "keys on bucket" badge | `Bucket` row; `bucket_connections/0`, `bucket_type/1`, `bucket_location/1`, `bucket_service/2` are **private in `web/settings.ex`** — lift them into a shared module rather than copying; `BucketCredentials.legacy?/1` |
| 2 | Used by | profiles with role/status/serve order, libraries behind each, "Add to profile" | `Profiles.bucket_usage/1`, `Profiles.add_bucket/3` |
| 3 | Contents | files, copies, total bytes, capacity bar vs `max_size_mb` (free disk space for local), originals vs derived, per-library breakdown | `Storage.calculate_bucket_usage/1`, `calculate_bucket_free_space/1`; counts need a **new** query (below) |
| 4 | Health | live connection probe with timing; files not yet verified on this bucket; files missing a copy here; draining progress | probe: `Storage.test_connection/1`; checks: `Locations`, `LocationCheck`, `Reconciler` — read `reconciler.ex` before designing the per-bucket "missing a copy" number |
| 5 | History | every change to the bucket and to its rows in profiles, with who and when | `Activity` (below) |
| 6 | Log | write/read failures, probe results, latency over time | **does not exist** — see "Open decisions" |
| 7 | Retire this bucket (optional, my suggestion) | the strict rule makes removal a 4-step flow: set `draining` in each profile → wait for the reconciler → remove from each profile → delete. A checklist showing where the bucket is in it, with the blockers named | `Profiles.bucket_usage/1` + location counts |

### Concrete pointers

- **Route.** `lib/phoenix_kit_web/integration.ex:602-603` has `buckets/new` and `buckets/:id/edit`. Add
  `live "/admin/settings/media/buckets/:id", Live.Modules.Storage.BucketPage, :show` **after** `buckets/new`,
  or `new` matches as an `:id`. Edit stays the form; the page links to it.
- **Permission gate.** New LiveViews must be added to the map in `lib/phoenix_kit_web/users/auth.ex` (~line 2371,
  next to `Storage.BucketForm => "media.manage"`). Without an entry it falls through unmapped. Storage admin
  screens are `media.manage`, not `media`.
- **Entry point.** Make the bucket name a link in `lib/modules/storage/web/settings.html.heex` (table cell
  `<div class="font-bold">{bucket.name}</div>`, and the card title for the mobile layout). Use
  `<.pk_link navigate=...>` / `Routes.path/1`, never a hard-coded path.
- **Header.** The breadcrumb is built from `page_section` (+ `_path`), `page_crumbs`, `page_title` only; read
  `dev_docs/guides/2026-09-25-admin-header-trail.md`. Title is the bucket name, never "Media — Bucket".
- **Load the bucket with `Storage.get_site_bucket/1`**, never `get_bucket/1`: a user's own bucket must not open
  here (redirect with "Bucket not found", as `BucketForm` does).
- **No queries in `mount/3`.** Load in `handle_params/3`; use `assign_async` / `start_async` for the contents
  counts and the probe. (`web/settings.ex` already queries in mount — don't copy that.)
- **Contents query.** `get_bucket_file_counts/1` in `web/settings.ex` runs one query *per bucket* (and swallows
  every error); don't extend it for the list. Add a `Storage` function for one bucket: distinct files, active
  `file_locations` rows, bytes, original vs derived (`file_instances.variant_name == "original"`), grouped by
  `files.library_uuid`. `idx_file_locations_bucket_uuid` exists. For the per-library breakdown **name site
  libraries and aggregate user libraries as "N personal libraries"** (commit `5d40b3afb`: no user library names
  in titles or lists).
- **Probe.** `Storage.test_connection/1` takes a params map (the form builds it from the changeset, including
  keys). For a saved bucket add a public `Storage.probe_bucket(%Bucket{})` over the private `probe/2` so no
  secret passes through assigns. Run it with `start_async` — an HTTP-pool *exit* inside the probe must not take
  the LiveView down (`BucketForm`'s `test_connection` handler explains this). It writes, reads and deletes a
  real object: **button, not on-open** (cost, side effects, rate), and show the last result with its time.
- **History.** Bucket lifecycle entries: `module == "storage"` (`Storage.Audit.module_key/0`),
  `resource_type: "storage_bucket"`, `resource_uuid` = the bucket. Profile-row changes
  (`storage.profile.bucket_added` / `bucket_changed` / `bucket_removed`) carry the bucket in
  `metadata["bucket_uuid"]`, with a different `resource_uuid` (the profile). So the query is
  `resource_uuid == ^uuid or metadata->>'bucket_uuid' == ^uuid` — see `history_query/1` in
  `web/history_component.ex`; `Activity.list/1` takes `:query`. Render with `Core.ActivityList`
  (`summarize_details/1`). `Audit.bucket_fields/0` is the list of what is ever logged — never a key.
  Follow the log live as the Settings LiveView does (`{:activity_logged, entry}` on `Activity.pubsub_topic()`).
- **Actions on the page** reuse the guarded context calls; on `{:error, {:in_use, usage}}` show
  `BucketUsage.refusal_message/3`. Do not give the form a `disabled` checkbox to mean "in use" — a disabled
  `<.checkbox>` still submits its hidden `false` and rewrites the value (see CLAUDE.md).
- **Every `<form phx-change>` needs a unique `id`.**

## Open decisions (ask the user)

1. **The log (section 6).** Valuable for diagnosing a failing bucket, but today failures only reach `Logger`.
   It needs a new table (a V208 migration: `bucket_uuid`, `kind`, `ok`, `latency_ms`, `message`, `inserted_at`),
   hooks in `Manager` writes/reads, probes and the reconciler's copy failures, and a prune worker with a
   retention setting. Follow the prefix-safe migration rules (CLAUDE.md), `use PhoenixKit.SchemaPrefix` on the
   schema, and note that adding a migration file **blocks the next release** until the expected-schema manifest is
   restamped (see memory `project_expected_schema_manifest_blocks_release`). **My recommendation: ship sections
   1–5 first as its own release, the log after.** The user has not yet said which they want.
2. **Page vs tab.** I propose a separate `:show` page with Edit staying the form. Not confirmed.
3. **Probe on open vs button.** Recommend button (above). Not confirmed.

## Gotchas learned this session

- **i18n.** `mix gettext.extract --merge` is safe and idempotent; then fill every new msgid by hand in all
  seven locales and **delete the `fuzzy` flag on every carry-over** (fuzzy entries are served, and gettext matched
  `backup`/`primary` onto unrelated strings). A small Python script that un-escapes the msgid, rewrites the
  `msgstr`/`msgstr[n]` and strips `fuzzy` worked well (it wasn't saved — rewrite it). Verify: re-running the
  extract is a no-op, `--check-up-to-date` is clean, **0 fuzzy**, every `%{}` in a msgstr is bound by its msgid.
  Plural forms: pl and ru have 3, the others 2. Address forms: **formal** in de (Sie), es (usted), fr (vous), ru
  (вы); **informal** in it (tu), pl, et. Terms: bucket = de/es/et/fr/it "Bucket"/"bucket", pl "zasobnik", ru
  "бакет"; library = Bibliothek / biblioteca / **kogu** (et) / bibliothèque / libreria / biblioteka / библиотека;
  storage profile = Speicherprofil / perfil de almacenamiento / salvestusprofiil / profil de stockage / profilo
  di archiviazione / profil magazynu / профиль хранения. Baseline untranslated (older drift, not ours): de/fr 52,
  es/it/pl 76, et/ru 0. Composing a sentence from a translated list (`used by: %{used_by}`) avoids case
  agreement in the Slavic languages — keep that shape.
- **Tests.** The Settings page renders **every tab's pane at once** — scope assertions with
  `element("#buckets-table")`, not `render(view)`. A flash sent by a LiveComponent reaches the page
  asynchronously: call `render(view)` after the click. The bucket form asks to create a missing local path
  (a modal) instead of saving — `File.mkdir_p!` the endpoint first. Tests that need a bucket disabled *while it
  stays in a profile* set `enabled` with `Repo.update_all` (the guard refuses `update_bucket`); tests that
  disable or delete through the API free the bucket from its profiles first. Disabling the Default's buckets
  also needs `Manager.invalidate_bucket_cache/0`.
- **Gate.** `mix precommit` (capture the *real* exit code — don't pipe through `tail`), full `mix test` is ~8000
  tests and a few minutes. Known load flakes: `query_canceled` (Postgres 57014) in test setup
  (`ActiveRoleGateTest`, `PermissionsTest`), the History "refresh clamps" test; each passes alone. Compare
  against an isolated run before chasing one.
- **Release.** CHANGELOG `## Unreleased` accumulates; rename it to the new version at release. `mix prerelease`
  → commit → push → `mix hex.publish --yes` → only then tag and push the tag → `mix package.clean`. Commit
  messages start with Add/Update/Fix/Remove; author is Dmitri Don.
- **Languages work** (another agent, shipped in 2.50.0) is unrelated: Languages is core and always on. Don't
  touch it from here.
