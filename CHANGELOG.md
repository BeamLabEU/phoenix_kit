## 2.52.0 - 2026-10-04

### Added

- **Core's emails are written in Markdown, with a button** (#899). The eight auth emails (confirmation,
  password reset, magic link, login alert and the rest) have Markdown defaults with a call-to-action
  button and the address written out under it, translated into all eight core languages. Markdown email
  bodies gained optional paragraphs (a top-level paragraph whose placeholders all fill in blank is left out
  of both bodies), raw-HTML blocks written as a lone triple-brace placeholder, and links whose label is
  their own address (printed once in the text body).
- **A welcome email**, off by default (`email_welcome_enabled`, Settings → Emails → Sending). It is sent
  at most once, after an address is confirmed — by the confirmation link, a magic link, OAuth or
  magic-link registration. The confirmation only enqueues `WelcomeEmailWorker` inside its own
  transaction, so a rollback takes the job with it; a refused or locked insert is logged and never fails
  the confirmation.
- **The notification email goes through the shared layout** — the email notification channel sends core's
  `notification` email, so it carries the header, footer and a host's overrides like every other email.
- **A core-owned sidebar order for module tabs, and `config :phoenix_kit, :admin_tab_order`** (#901). Core
  now places each module's tab itself instead of leaving the order to load order, with id tie-breaks. A
  host moves tabs, or whole groups, between groups and positions with `:admin_tab_order` (see
  `lib/phoenix_kit/dashboard/ADMIN_README.md`); unknown groups are ignored with a warning.
- **`mix phoenix_kit.update` steps Oban's schema up to the Oban library** (#902). Oban's schema is
  versioned apart from core's chain, and core's open `~> 2.20` pin lets a host move to a newer Oban that
  expects a newer schema — under Oban 2.24 (schema v14) every unique insert, cron's included, failed with
  `invalid input value for enum oban_job_state: "suspended"`. The update checks the schema at core's
  prefix and at the host Oban config's prefix and writes a host migration
  (`phoenix_kit_update_oban_vNN_to_vMM`) that runs `Oban.Migration.up/1`; `mix phoenix_kit.doctor` and
  `status` report the version, and the application logs one warning at boot when it is behind.

### Changed

- **The HTML body of an email is built from the highest-priority host part first.** A host that
  overrides only `text.txt` of an email now gets its own words in the HTML version too, instead of an
  HTML version built from the caller's `html` or `markdown` default. The text body order is unchanged.
- **The email-confirmation waiting screen is shorter** (#900): one line with the address and when it was
  sent. With no confirmation on record it says so instead of claiming an email went out.

### Fixed

- **The admin Modules page no longer rescans every beam file on each mount** (#895).
  `ModuleDiscovery.cached_external_modules/0` keeps the scan until `ModuleRegistry` rescans or a module is
  registered/unregistered; concurrent cold readers share one scan (node-local lock). Compile-time callers
  still read the disk.
- **The dev server no longer rescans beam files on every request** (#898). The router's
  `__mix_recompile__?/0` uses `ModuleDiscovery.module_hash_fast/0`, which fingerprints the code path with
  `stat` only and runs the full scan when the fingerprint changed. A merge dropped the module attributes
  behind its memo, which made every call fall back to a full scan; they are restored, and a fall-back is
  now logged.
- **The schema manifest no longer carries the newsletters template foreign key** (#896); the newsletters
  module owns that table's shape.
- **The Oban schema check works on Oban 2.20–2.21**, where `Oban.Migration.current_version/1` is not
  public yet, and follows the `{repo, opts}` form of the Oban `:repo` option.
- **The welcome email enqueue catches an exit** as well as a raise, so a dead pool on a magic-link
  registration cannot fail the response.

## 2.51.0 - 2026-10-04

### Added

- **A page per bucket** (Settings → Media → Buckets → the bucket's name, `/admin/settings/media/buckets/:id`).
  Edit stays the form; the page links to it and offers Enable/Disable, Delete and Add to profile, all through
  the guarded context calls (a bucket in use is refused with the usual message). Five sections:
  - **Overview** — location, service, the Integrations connection (linked for a holder of
    `integrations_system`), the "Keys on bucket" badge, access type, priority, maximum size, CDN, created and
    updated. The type/service/location wording now lives in `Storage.BucketInfo`, shared with the list.
  - **Used by** — each site profile with role, status and the libraries behind it; a user's profile and
    libraries are counted, never named.
  - **Contents** — files, objects, bytes, originals apart from derived, a capacity bar against `max_size_mb`
    (the disk's free space for a local bucket) and a per-library breakdown (user libraries aggregated).
    New `Storage.bucket_contents/1`; loaded with `start_async`, never in `mount/3`.
  - **Health** — a **Test connection** button (never run on open: it writes, reads and deletes a real object)
    over the new `Storage.probe_bucket/1`, which probes the saved bucket without passing a key through the
    assigns; location rows by status (`Storage.bucket_location_health/1`); the files still on a draining bucket.
  - **History** — every change to the bucket and to its rows in profiles, kept permanently, following live.
  A user's own bucket (V206) does not open here. The Buckets list links each name to its page. Gated by
  `media.manage` like the other storage screens.

- **V208: the bucket log, and a Log section on the bucket page.** `phoenix_kit_bucket_log` (no foreign key,
  so it never blocks deleting a bucket; `Storage.delete_bucket/2` removes the bucket's rows) records, for a
  **site** bucket only (a user's own bucket and an unsaved form test are never logged):
  - every write, read or delete that **failed** (`Manager` reports it in the background through
    a dedicated supervisor capped at four tasks, skipping diagnostics when unavailable or full), with a
    controlled diagnostic that excludes response bodies, headers, URLs and credentials;
    a missing object on read or delete is how a failover starts and is not logged (failed writes are),
    and a success is not logged either — a row per request would swamp a busy site;
  - every **probe** of a saved bucket (`Storage.probe_bucket/1`) with its result and how long it took, so
    latency over time comes from the probes;
  - the same failure within a minute of its first occurrence is **one row** with a count, so a bucket
    that is down does not write a row per request.
  The page shows the failures of the last day, the last failure, a chart of the latest probe times, and the
  entries (all, or failures only). The last probe's result now outlives a reload. A host that has not run the
  update yet gets a notice instead of an error. Entries are pruned daily to `bucket_log_retention_days`
  (default 30) by `Storage.Workers.BucketLogPruneWorker`; `mix phoenix_kit.update` adds its cron entry
  (`20 4 * * *`) to existing hosts. The manifest declares the table, its columns, constraints and indexes.

### Fixed

- **Bucket page review findings.** Shared keys count once in bucket object/byte totals while every logical
  file and library remains counted. Failure logging has no synchronous fallback into file transactions,
  and log messages and displayed probe errors contain only controlled diagnostics. Continuous failures
  start a new row after a minute; probes sharing a timestamp have a deterministic order. Navigating to
  another bucket resets its probe and contents, and legacy credentials stay out of page assigns while
  bucket actions reload the stored row before changing it.

### i18n

- New strings translated in all seven locales, 0 fuzzy.

## 2.50.0 - 2026-10-03

### Changed

- **Languages is core and always on; the Modules page toggle becomes a switch on its own settings page.**
  Languages was a feature module with an Enabled/Disabled card on Modules, but it is bundled, nothing
  installs or removes it, and what the toggle really controlled was whether the *site* is multi-language.
  It now follows Jobs: `languages` is a core permission key (`Permissions.core_section_keys/0`, so
  `feature_enabled?("languages")` is always true), its Settings → Languages tab is a core admin tab, and
  `PhoenixKit.Modules.Languages` is no longer a `PhoenixKit.Module` or in `ModuleRegistry`. The first card
  of Settings → Languages is **Multiple languages**, the same `languages_enabled` setting
  (`Languages.enabled?/0`, `enable_system/0`, `disable_system/0`), so an existing install keeps its state,
  its role grants (the key is unchanged) and its configured languages. Off, the site serves its
  configured fallback locale only and the page shows just the switch; on, the configuration, URL behaviour and switcher preview
  appear. The page used to be refused by `Auth` while the module was off, so the switch could only be
  reached from Modules; the core key is what lets it live on the page.
  - Language configuration APIs keep their behavior; the former `PhoenixKit.Module` callbacks are removed.
    `get_languages/0` now backs the settings page (empty while off)
    instead of the preview list, which no admin screen shows any more.
  - Full operator-access checks now require `languages` even while the site's multi-language switch
    is off. Custom roles keep their existing grants; no additional authority is backfilled.
  - `migrate_legacy/0` (the one-time copy of `publishing_default_language_no_prefix`) was run by the registry's
    boot sweep; `PhoenixKit.Supervisor` now calls it next to `normalize_language_settings/0`.
  - Packages that call `Languages.enabled?/0` or `get_enabled_languages/0` are unaffected. Anything that
    looked the module up as `ModuleRegistry.get_by_key("languages")` now gets `nil`.

- **The new-bucket form asks which storage profile the bucket joins, and offers "None" first.**
  Before, every bucket created in Settings → Media silently joined the Default profile, so it
  was written to by every library that names no profile of its own. With none chosen the bucket is
  only added to the system: it receives and serves nothing until a profile lists it (Storage
  profiles tab). A chosen profile takes it as a primary and the profile's files are placed again.
  `Storage.create_bucket/2` takes `profile:` (`nil`, a site profile's uuid, or `:default`, which is
  what it did and still does when no option is given, so existing callers are unchanged);
  `Profiles.add_bucket/3` is the general form of `add_to_default/1`.

### Fixed

- **Language settings and navigation review fixes.** Locale switching preserves an unrelated host
  segment such as `/nl/products` when Dutch is not enabled; an explicit current locale still strips
  a language that has since been disabled. An empty frontend dropdown no longer renders a globe menu.
  The Languages page's preview controls now update both its generated code and live preview, restoring
  saved languages no longer claims English is the default, and configuration events from an already-open
  page are refused after another admin turns multiple languages off.

- **A language menu offered languages the site does not serve when the Languages module was off.**
  The admin user menu and the frontend `Core.LanguageSwitcher` read `Languages.get_display_languages/0`,
  which returns a dozen hardcoded defaults while the module is off (it feeds the admin Languages page's
  preview), so a host with the module disabled showed ja, es, fr and the rest, each linking to a
  locale route that does not exist. Both now read `Languages.get_enabled_languages/0`, which is empty
  while the module is off, and the continent grouping (`get_enabled_languages_by_continent/0`)
  follows. Two lesser corrections ride along: a language switched off inside an enabled module is no
  longer offered by the frontend switcher, and the admin user menu hides its language section when
  there is only one language, as the dashboard menu already did.
  `get_display_languages/0` keeps its behaviour and now says it is not a list to offer a visitor.

### i18n

- The Multiple languages card and its flash messages in all seven locales; the three Modules-card strings
  that nothing uses any more are gone.
- The new-bucket form's storage profile strings in all seven locales.

## 2.49.1 - 2026-10-03

### Added

- **The Buckets list shows which storage profiles use each bucket.** A "Used by" column names the
  profiles (with the bucket's role and status there, and how many libraries stand behind each) or
  says "Not used"; a user's personal profile is counted, never named. The bucket's edit page
  carries the same notice. (`Profiles.bucket_usage/1`, `Profiles.library_names_using/1`.)

### Changed

- **A bucket a storage profile lists cannot be deleted or disabled.** `Storage.delete_bucket/2`
  and `Storage.update_bucket/3` (turning `enabled` off) return `{:error, {:in_use, usage}}` while
  any profile has a row for the bucket, whatever the row's role or status (a user's own profile
  counts too), and the settings page and the bucket form say which profiles. Free the bucket
  first on the Storage profiles tab, then delete or disable it. Enabling is always allowed, and a
  user's own bucket is unchanged. Deleting an empty bucket no longer takes it out of every profile
  on the way — that could leave a library with nowhere to write. The delete confirmation no
  longer says it removes location records (it has refused a bucket holding files since V204).
- The refusal to delete a storage profile that libraries use names the site libraries in the way
  (a user's library is only counted), and tells the Default apart from a profile in use.

### Removed

- `Profiles.remove_bucket_everywhere/1` (only the bucket delete called it).

### i18n

- The new strings in all seven locales.

## 2.49.0 - 2026-10-03

### Added

- **Each library's storage has a state, and can be checked and paused.** Settings → Media →
  Libraries has a Sync column: **Up to date**, **Syncing** ("N files left"), **Paused**,
  **Waiting** (files are out of date and no run is working on them — the case the Health page's
  global count hid) or **Needs attention** (the last run failed with files left, or the reconciler
  keeps failing on some). **Check now**, **Pause** and **Resume** are offered to those who hold
  `jobs.manage` and `media.manage`, and the column follows the library's run live. "Up to date"
  means the files carry their library's current profile and variant-set revisions; it does not
  prove every object is still on its bucket. The Health page links to the storage runs.
  (`Storage.LibraryState`; `Reconciler.out_of_date_query/1` and `counts_by_library/0` count what is
  out of date apart from what the reconciler may take now.)
- **Settings → Media has a History tab, and every change to the site's storage settings is
  recorded.** Who created, renamed or deleted a bucket, a storage profile, a library, a variant set
  or a size; who added a bucket to a profile, changed its role, order or status, or took it out;
  who moved a library to another profile or variant set or changed its annotated-thumbnail choice;
  who reset the sizes or remade them all — each with the person, the time and what changed from →
  to (`Storage.Audit`, `storage.profile.updated`, `storage.library.profile_changed`, …). The
  entries are permanent (not pruned by the activity retention), name only fields that are not
  secret — never a key — and leave out a user's own library, profile and bucket, which are
  private. The tab lists them with the storage job runs' entries, filters between the two, pages,
  and follows the log live; each row opens its full entry on the Activity page. The context
  functions take `actor_uuid:` in their options (`create_profile/2`, `put_bucket/4`,
  `set_library_profile/3`, `Storage.update_bucket/3`, …); without one an entry says the system did
  it.
- **Each History row can be opened in place** ("Show every field"), so a media manager who may not
  open the Activity page (`media.manage` does not imply `dashboard`) still reads every field that
  changed, not only the first three. Run titles never contain a user's library name: a user's
  library is "a user's library" on the Jobs page, the Libraries tab and in the History.
- `PhoenixKitWeb.Components.Core.ActivityList`: a list of activity entries for any screen that
  shows a slice of the log; the Activity page shares its `summarize_details/1`.
- **The Runs tab warns when a queue is not working**: a run's batch has been available for ten
  minutes and nothing in that queue has run since — observed from Oban's own table, so a web node
  with `queues: false` does not cry wolf for a worker node.
- `Jobs.can_start?/2`, for a screen that offers a button that starts a run.

### Changed

- **The storage reconciler is a job run per library** (`storage.reconcile`) instead of one walk
  over every file. A change to a profile, a variant set or a library's choice still queues
  `Workers.ReconcileJob`, which now starts the runs for the libraries that have files to bring up
  to date (a pass already running begins again at its next batch). Each run shows on Admin → Jobs
  with its progress, can be paused between batches, and keeps a history.
- **The location backfill, the checksum backfill and the library purge are job runs too**
  (`storage.location_backfill`, `storage.checksum_backfill`, `storage.purge_library`). The purge is
  visible but cannot be paused or cancelled: it walks the whole library and cannot be undone. The
  old Oban jobs remain as shims that start the runs, so jobs queued by 2.48.0 or earlier still work.

### Fixed

- Storage configuration changes and their audit entries commit together; failed audit inserts
  roll back the change, and rolled-back changes produce no storage audit announcement. Diffs use
  locked, current rows, so stale forms cannot record incorrect old values or duplicate no-ops.
- Storage audit redacts credentials and query tokens in endpoint/CDN URLs and includes bucket
  access, capacity and CDN changes, alternative size formats, and checks requested for one set.
- Media History identifies the affected resource, includes global storage settings with the
  signed-in actor, refreshes after missed announcements, and handles invalid or removed pages.
  Historical users retain their UUID label; Activity links require dashboard access.
- Object Storage service labels load their setup module before checking its optional label
  callback, so the Integrations list shows the service on its first visit after boot.
- Storage reconcile triggers preserve restart requests for active libraries even when their
  files are temporarily ineligible, and return start failures so the trigger job can retry.
- The stalled-queue warning ignores paused runs and superseded dispatches, and matches the
  current dispatch using each table's configured schema.
- The Libraries tab refreshes derived sync state every 30 seconds while visible, including
  changes that produce no run event. Its counts query reads only the displayed libraries.

### i18n

- The new strings in all seven locales.

## 2.48.0 - 2026-10-03

### Added

- **`PhoenixKit.Email.Layout.render_parts/2`**: the site's email header and footer on their own, for
  a module that builds its own document (#893). Chosen by the same code as the layout (group, then
  shared, then core; the reader's language; a blank file counts as missing), and without `:paths`
  it reads the host's template directories like every email. See the email templates guide.
- **Job runs: long background work an admin can watch and control** (V207, `PhoenixKit.Jobs`). A run
  is a durable record of one piece of work — its state, progress, who started, paused or cancelled
  it, and its history — that Oban executes batch by batch. `Jobs.start/pause/resume/cancel/retry`
  take the signed-in `Scope` and check `jobs.manage` and the kind's own permission against the
  active role; boot, cron and scripts use `Jobs.System.start/3`, and `Jobs.run_inline/3` runs the
  same kind in a script without Oban. A module adds a kind with `use PhoenixKit.Jobs.Kind` and
  `job_kinds/0` (or `config :phoenix_kit, job_kinds: [...]`); the engine owns the rest.
  - Every transition is one transaction: the row is locked, the change written, the next batch's Oban
    job inserted and the Activity entry made together, so a crash cannot leave a run with no job or
    a change with no history. A batch holds a claim on the run; an Oban job carries the generation it
    was made for and an older one does nothing. Pause and cancel while a batch executes are requests
    (`pausing`, `cancelling`) the batch settles at its checkpoint; resume is refused while one drains;
    a trigger that arrives during the last batch starts a fresh pass instead of being lost.
  - A sweeper (`Jobs.SweepWorker`, every five minutes) releases a dead batch's claim, fails a run
    whose Oban job was discarded or cancelled, and rescues a lost dispatch up to three times;
    `Jobs.PruneWorker` deletes finished runs after `job_runs_retention_days` (default 90).
    `mix phoenix_kit.update` adds both to the host's crontab.
- **The Jobs page has a Runs tab** (the default), with state and module filters, progress bars, the
  controls each viewer may use, a drawer of one run with its history, and live updates; Oban's own
  table is the Queue tab. It warns when runs are waiting and the sweeper has not been seen for
  15 minutes. The tab, filters and opened run are in the URL.
- **The capture-date backfill is the first kind** (`storage.capture_date_backfill`, `media.manage`):
  it shows on the Runs tab with its progress and can be paused, resumed and cancelled. The mix task
  runs the same kind inline.

### Fixed

- **A feature module's email text came out in the sender's language, not the recipient's** (#892).
  `RecipientLocale.in_locale/2` now also installs the recipient's base language as the process
  locale for the duration, which is what a module's own Gettext backend reads.
- **Recovery of job runs is decided under the run's row lock.** The sweeper lists candidates; the
  engine (`Engine.recover/4`) reloads each and decides from the run as it is then, so a slow sweep
  can no longer undo a newer dispatch, steal a live claim or charge the rescue budget twice. A
  rescue or an outside failure of a run a batch holds is refused by the state machine.
- **A script's claim (`Jobs.run_inline/3`) is a lease the sweeper respects** (new column
  `claim_owner`, an hour, renewed by `Jobs.heartbeat/1`); a dead script's run is taken back when the
  lease runs out. Inline execution now waits out `{:snooze, s}` and `schedule_in:`.
- **An obsolete Oban delivery stays inert even when its kind has gone**: the worker claims first and
  only then looks the kind up.
- **Job runs work on a named Oban schema**: recovery, `Jobs.get_job_stats/0` and the Jobs page read
  Oban's table through its configured prefix, and check a job is the run's own.
- **The engine refuses to run inside a caller's transaction** (`{:error, :in_transaction}`), so no
  event or `on_finish/2` escapes a rollback; `Jobs.start/4` documents `{:error, :raced}` as "not
  recorded".
- **A script that asks its next batch to wait keeps its run through the wait** (`wake_at`, and the
  script stays the run's owner between batches): the sweeper no longer reads the wait as a lost
  dispatch, and a rescue carries what is left of a delay into its dispatch.
- **A script's wait belongs to the script that asked for it**: `Jobs.run_inline/3` carries an owner
  identity (`owner_token`) between its batches, another invocation is refused while it stands, and
  a rescue keeps a delayed run's due time.
- **Without an Oban instance the sweeper, the stats and the Jobs page no longer guess**: a run that
  never had a dispatch keeps its rescue budget, nothing falls back to the default schema's table, and
  the Queue tab says Oban is not running on that node.
- **The "counts may be approximate" notice follows `interruptions`**, a new counter of batches cut off
  and run again (an Oban retry, a sweeper release, a dead script's takeover); the Mix task prints it.
- The Jobs page's sweeper warning and Runs badge cover all runs, not the filtered page; the open run
  refreshes with the table; the filters use the core select.

### Changed

- **Jobs is no longer a module you switch on: it is always on.** It leaves the Modules page; `jobs` is
  a core section key and `jobs.manage` a sub-permission that is granted to Admin at boot and *not*
  backfilled to existing holders of `jobs`, who keep viewing. `Jobs.enabled?/0`, `enable_system/0`
  and `disable_system/0` remain, deprecated, as `true` and no-ops.
- **The capture-date backfill's worker** starts a run instead of walking the library itself; its old
  job shape still arrives and does the same.

### i18n

- The Jobs page's new strings (the Runs tab, its controls, history and notices) in all seven locales.

## 2.47.0 - 2026-10-03

### Changed

- **The bucket rows of a storage profile, and a library's storage, are saved with a Save button.**
  Changing a row of the Storage profiles tab (role, stores, upload order, serve order, status) saved
  the instant a control changed or a number stopped moving, with no sign that anything had; the
  profile's own name and copy counts saved only on their button or on Enter. Libraries → a
  library's profile, variant set and annotated thumbnails saved on every dropdown change, and a
  different profile or variant set moves and resizes the library's files. Each of these is a form with
  one Save button now: disabled until something changes, then "Unsaved changes", then "Saved" (and the
  usual confirmation at the top). `Core.SaveButton` is the component, opt-in like `date_nav`.
- **Removing a bucket from a profile says what it does.** The "x" is "Remove from profile", and the
  confirmation says the files are copied to the profile's other buckets and then deleted from this
  bucket, that the bucket itself stays, and that the profile stops sending it files.

### Added

- **The Storage profiles tab says when a bucket is idle and offers the count that uses it.** With
  one Primary and a Replica or Backup at one copy, the other bucket holds nothing, so a line under the
  copy counts names it ("Not used at this copy count: …") and a button — "Keep every original on 2
  buckets" — sets the count after a confirmation that says existing files are copied in the
  background. The count is offered only where it is unambiguous (one primary, one copy, a bucket
  waiting); with several primaries a higher count would also put every file on every primary, so the
  line only names the idle buckets. The server applies only the count it would itself recommend.
  `Profiles.copies_advice/1` is the one reading of what a count means for a profile's buckets.
- **Creating a bucket says when the Default now spreads files.** A new bucket joins the Default as a
  primary; when that leaves it keeping fewer copies than it has primaries, the confirmation adds
  "Each original is stored on 1 of the 2 primary buckets, so files are spread across them, not
  mirrored", with where to change it.

### Fixed

- **The line under a profile's copy counts treated every bucket as equal.** With one Primary and one
  Replica at one copy it said files were spread at random across both; in fact the copy goes to the
  primary and the replica holds nothing unless a write to the primary fails. It now says so and, with
  several primaries, counts only them.

### i18n

- The strings the Save buttons, the idle-bucket line and the copy-count button added (9 in all) are
  extracted and translated in de, es, et, fr, it, pl and ru; no entry is fuzzy.


## 2.46.0 - 2026-10-02

### Added

- **A library can choose annotated thumbnails for itself.** Libraries → each library has an
  "Annotated thumbnails" select: site setting, on or off. Baking the annotation shapes into the grid
  thumbnail, regenerating it when annotations change, and showing it in the grid all follow the
  file's library, falling back to the site setting (Media Configuration) when the library has made no
  choice, so nothing changes until one does. Turning it on or off for a library does not bake or drop
  existing thumbnails: a file picks the change up the next time its annotations change, as with the
  site setting. It lives in the library's JSON `settings`, so there is no migration:
  `Libraries.setting/2`, `setting_among/2` and `put_setting/3` read and write a per-library setting
  (the keys are listed in `Libraries` and refused otherwise, a value of the wrong type is refused, and
  only the key changes), and `AnnotationThumbnail.enabled_for?/1`, `enabled_for_file?/1` and
  `enabled_among/1` apply the rule; `AnnotationThumbnail.enabled?/0` is still the site default.

### Changed

- **The Integrations lists say which service an Object Storage connection is.** Every Object
  Storage connection read "Object Storage (S3-compatible)", so a Tigris connection could not be told
  from an Amazon or a Backblaze one. The table (Settings → Integrations and My Integrations) now
  shows the service — Tigris, Cloudflare R2, Backblaze B2, … — as a badge next to the provider, and
  as a "Service" row in the card view. A provider with a `:setup_module` can add its own with an
  optional `label/1` (`Providers.setup_label/2`).
- **The Media Buckets list shows a Type and reads cleanly.** The Provider column is a Type column:
  Local or Cloud, with the service a cloud bucket is on (the one its integration is for — Tigris,
  Cloudflare R2, …) as a badge beside it. Under the bucket's name, the location is in words —
  `fotki-dev-test1 · t3.storage.dev` for a cloud bucket, the path for a local one — instead of
  `tigris:fotki-dev-test1https://t3.storage.dev`.
- **The Storage profiles tab is clearer and lines up.** The bucket rows sit on one grid, so each
  control is under its own heading and the dropdowns have fixed widths. "Pool" is "Upload order"
  (empty reads "Any"), with a tooltip on it and on Role and Serve order; the statuses read "Active",
  "Read-only (no new files)" and "Draining (moving files out)". The copy counts are "Copies of each
  original", "Copies of each size and tile" and "Copies needed to accept an upload", and a line under
  them says what they mean with the buckets the profile has now — two buckets at one copy spread
  files across them rather than mirror them, and a count above the number of buckets is flagged. The
  description no longer promises that every change moves files: renaming a profile or changing the
  copies an upload needs does not.
- **Media Configuration no longer has a second editor for redundancy, sizes and tiles.** "Redundancy
  Copies", "Auto-Generate Variants" and "Deep Zoom Tile Generation" were leftovers from before
  profiles and variant sets: they edited the Default storage profile's copy count and the Default
  variant set's flags, which every library on another profile or set ignored, under names and with
  limits that disagreed with the real editors. Copies are set on the Storage profiles tab, and
  sizes and tiles on the variant set; the tab now says so, with links, and keeps what is genuinely
  site-wide: annotated thumbnails, image editing and the upload size limit. Nothing stored changes,
  and `Storage.set_redundancy_copies/1`, `Storage.set_auto_generate_variants/1` and
  `Storage.set_tile_generation/1` are as they were.

### Fixed

- **A profile's "Used by" count left out the libraries that use it without naming it.** The Default
  said "Used by 0 libraries" while the Media library, which names no profile and so uses the
  Default, said it was on it. The Default's count now includes the libraries with no profile of their own.

### i18n

- The strings the Media Buckets list, the Storage profiles tab, the Configuration tab and the
  per-library annotated thumbnails added (31 in all, one with plural forms) are extracted and
  translated in de, es, et, fr, it, pl and ru; no entry is fuzzy.


## 2.45.0 - 2026-10-02

### Added

- **The Object Storage integration opens on a choice of service and asks only what that service
  needs.** "S3-compatible" is a protocol, not a place: the form (site-wide and personal alike)
  now starts with a Service select — Amazon S3, Cloudflare R2, Backblaze B2, Tigris, Wasabi,
  DigitalOcean Spaces, or Other S3-compatible — and shows that service's own fields:
  a grouped region list for Amazon (from `aws_regions`), a region with suggestions for
  Backblaze, Wasabi and Spaces, the account id and optional jurisdiction for R2 (a pasted
  `<id>.r2.cloudflarestorage.com` is read for you), nothing but the keys for Tigris, and an
  endpoint for anything else. Field labels and help follow the service ("Application Key ID" for
  Backblaze, where in the console to find each key). The endpoint is built for you
  (`s3.<region>.backblazeb2.com`, `<account>.r2.cloudflarestorage.com`, `t3.storage.dev`, …);
  what is stored is still `access_key`, `secret_key`, `region` and `endpoint`, plus `service`,
  `account_id` and `jurisdiction` so an edit shows the choice again. A connection saved before this
  opens on the service its endpoint names, so nothing needs migrating. The logic is
  `PhoenixKit.Integrations.ObjectStorageServices`, reached through the new
  `Providers.setup_fields/2`, `setup_attrs/2`, `setup_changed/3` and `setup_saved/3` and a
  provider's optional `:setup_module`, so any provider can shape its form the same way.
  `setup_field/1` gains `:combo` (free text with suggestions), grouped selects, a `prompt` and a
  field-level `on_change`.
- **The storage bucket form starts with a type, and cloud buckets start from an integration.**
  Settings → Media → Add Storage Bucket asks for a Name (the PhoenixKit bucket's own label — it
  used to read "Bucket Name" and was mistaken for the bucket on the storage service) and a Type:
  Local Filesystem, which asks for the storage path, or Cloud storage, which lists the Object Storage
  integrations by name and service with an "Add a connection" link. Picking one sets the bucket's
  provider (R2, B2, Tigris, otherwise S3), fills the endpoint and region and then asks for the
  bucket's name on that service, labelled for it ("Bucket name on Backblaze B2"). Only Amazon has a
  region to choose; only "Other" has an endpoint to type; the rest come from the integration.
  Moving a bucket to another integration replaces what the first one filled in. The old Storage
  Provider select is gone from new buckets; existing buckets show their service and keep working.

### Changed

- **A new Tigris bucket no longer asks for a region.** The list of Tigris cities was only ever the
  request's signing region — Tigris is one global endpoint (`t3.storage.dev`) and places data by a
  setting of the bucket in its own console — so it read as a placement choice and was not one. New
  Tigris buckets sign with `auto`; existing ones keep the region they have.
- **Settings → Integrations is split into tabs.** "Connections" and "Personal integrations" (which
  services users may connect on their own) are tabs of the page; the encryption key warning stays
  above them, so it is seen whichever one is open.
- **The tab of a settings page is in the URL.** General (`/admin/settings`), Users, Authorization,
  Organization, Website access, Emails Transactional, Integrations, Crawlers, Media and Sitemap kept the
  active tab only in the page's state, so a refresh went back to the first tab and a tab could not be
  linked to or reached with the browser's Back button. Each tab now has its own URL
  (`/admin/settings/users?tab=sessions`); the first tab's URL carries no query and an unknown `?tab=`
  opens it. The tabs patch, so the page is not reloaded and unsaved edits in a hidden tab are kept.
  `PhoenixKitWeb.Live.Settings.UrlTabs` (`active/2`, `patch_links/2`) is the shared helper. The
  `switch_settings_tab` event is gone from these pages; the Media page's "Details" link on the
  missing-tools warning is a link to `?tab=external_libraries` now.

### i18n

- The strings the Object Storage service form and the storage bucket form added (37 in all) are
  extracted and translated in de, es, et, fr, it, pl and ru; no entry is fuzzy.


## 2.44.0 - 2026-10-01

### Added

- **Email files can be written in Markdown, with a shared header, footer and layout groups
  (#887).** A `markdown.md` part feeds both bodies: the HTML (links and a lone-link paragraph
  as accent-coloured buttons, tables, lists) and the text (`label: url`). `{{variable}}` /
  `{{{variable}}}` work as in an `html` part and a link target is checked after substitution —
  only `http(s)` and `mailto:` become links. The layout gains `_header` / `_footer` parts, and a
  group (`layout: "billing"` or the email's `layout.txt`) brings `_layout-billing`,
  `_header-billing`, `_footer-billing`, each falling back to the shared one.
  `Content.resolve_with_sources/5` says where every part came from. Raises the
  `phoenix_kit_templates` floor to 0.2.2.
- **Email branding (#887, #890).** Every part of a file email sees `{{logo_url}}` (the site logo
  as an absolute, permanently signed URL; empty for a private library's logo) and
  `{{accent_color}}`. Settings → Emails Transactional has a Branding tab with the accent colour
  (`email_accent_color`, `#rrggbb`, blank = neutral) and the logo emails carry; core's layout
  draws an accent bar only once a colour is set.
- **Admin email preview (#890).** `/admin/settings/email-sending/preview` lists every email the
  site sends — core's eight and those enabled modules declare through the new
  `c:PhoenixKit.Module.email_templates/0` callback (default `[]`; collected by
  `ModuleRegistry.all_email_templates/0`, `PhoenixKit.Email.Catalog`) — renders the chosen one
  in a chosen language with sample values through the same resolution a send uses (HTML in a
  sandboxed iframe, text, subject), and says for each part whether it came from a database
  template, a host file or the built-in default, and which file overrides it. Gated by
  `settings`.

### Changed

- Core's default email copy lives in `PhoenixKit.Email.CoreTemplates` (one function per email),
  shared by the send and the preview; the text is unchanged.

### Fixed

- **A dialect language preference rendered core's default copy in English (#889).** A recipient
  or web visitor on `es-ES` matched no Gettext catalogue and read English; the locale is now
  chosen by `RecipientLocale.gettext_locale/1` (the locale, its `pt_BR` spelling, then its base
  language), shared by the web and by emails and notifications rendered for a recipient.
- **A bare `{{url}}` on a line of a Markdown email** is documented as text, not a link (write
  `[label]({{url}})`).

### i18n

- The strings the three PRs added (the Email preview page, the Branding tab, the core email
  labels — 69 per locale) were never extracted, so every locale showed them in English. They
  are extracted and translated in de, es, et, fr, it, pl and ru, and the fuzzy carry-overs the
  merge produced were rewritten by hand.

## 2.43.1 - 2026-10-01

### Fixed

- **Uploaded and generated media no longer ship in the Hex package.** `priv/media` is
  excluded even when its files are ignored by Git. The release gate inspects the built
  package and refuses media or generated sitemaps before publication.
- **Restricted Media viewers cannot change another person's visible folder.** Folder
  colour, header and cover events use `folder-uuid`; the ownership guard now checks that
  parameter as well as the other folder identifiers.
- **Wall-clock cache deadlines survive slow loads and a busy cache process.**
  `Cache.remember/4` subtracts loading time from a boundary-based lifetime and skips
  caching a value loaded after its deadline. An explicit `Cache.put/4` expiry is measured
  when called, so waiting in the cache's mailbox cannot extend it.
- **Admin-page generator tests no longer overwrite a concurrently running test's repo
  configuration.** The generator tests run synchronously.

## 2.43.0 - 2026-10-01

### Added

- **Media shows each viewer only what is theirs.** A holder of `media` without the new
  `media.view_all` sees, in a site library, the files they uploaded, the folders they
  created or that hold their files, and those folders' ancestors: in the grid, folders,
  tree, search, counts, trash and orphans, and on the file's own page. An Owner/Admin or a
  holder of `media.view_all` sees everything, as before. Every event that names someone
  else's file or a folder the viewer cannot see is refused, so is changing a folder they did
  not create, and a hand-edited `?file=` link opens only a file of the library shown that the
  viewer may see (it opened any file, of any library, before). A trashed file's URL answers its
  uploader, an Owner/Admin or a `media.view_all` holder; changing another person's file needs
  `media.view_all`. Emptying the trash and clearing orphans work for a restricted viewer on
  their own files only.
- **User libraries join Media's switcher**, grouped "Site" and "Mine" (`/admin/media/my/<id>`).
  A holder of `media` who is not an Owner/Admin is sent there from `/admin/libraries`; that page
  remains for people who hold `storage` without `media` and for the admin's audited list of other
  users' libraries. The profile's Media tab has an "Open" link on every library.
- **Two sub-permissions of `media`:** `media.view_all` (see everyone's files in the site's
  libraries) and `media.manage` (Settings → Media: buckets, sizes, health). They appear under
  Media in the permissions matrix.
- **Which services users may connect on their own is a site setting.** Settings →
  Integrations has a "Personal integrations" card: a checkbox per provider that supports
  personal use, and the personal "add integration" page offers exactly the ticked ones. The
  list used to be fixed in code (Telegram and OpenRouter); until an admin saves a choice those
  two are still what users are offered, so nothing changes on upgrade. A provider opts in with
  `personal_default: true` (offered until the admin chooses), and Object Storage is also
  offered while users may keep a library on their own bucket (`personal_also_while`). The
  page refuses a provider it did not offer, even to a hand-made event.
- **A shared HTML layout for emails built from files and defaults** (`PhoenixKit.Email.Layout`).
  Core's auth emails and the defaults a module passes to `Mailer.send_from_template/4` ship no
  `html` part, so they went out as plain text; they now arrive as HTML — the site's name above
  the body, the name and a link to the site below it, inline styles, no brand colours, no external
  resources, and no words of its own to translate. A text-only message is escaped, split into
  paragraphs and its `http(s)://` addresses linked (a link ends at invisible and bidirectional
  format characters, so it cannot display one address and open another). A host overrides the
  layout with `_layout/html.html` under its `phoenix_kit_templates` root (needs
  `phoenix_kit_templates` 0.2.1; older releases skip the name and core's layout is used). A layout
  without `{{{content}}}` is refused with one warning. `layout: false` opts out; an `html` part
  that is already a whole document, and any database template, are never wrapped. A blank `html`
  or `text` part (an empty override file) is now treated as missing. See `guides/email-templates.md`.

- **Module UI standardisation, core side.**
  - `<.date_nav>` — previous / today / next over a date held in the URL (stateless patch links, optional
    native picker, `DateNav.parse_param/2` clamps to min/max). Not in the global import list; import it.
  - `line_chart hover={:crosshair}` — a snapping crosshair with a server-computed readout (x, value, optional
    `point_note`, the rows active at that x), keyboard (arrows, Home/End, Escape), touch (tap to pin) and a
    polite live region; the native tooltips stay as the no-JS readout.
  - `SearchPicker` draws its list in the top layer (a modal body or overflow ancestor no longer cuts it off),
    closes on blur, picks on touch-up, and takes `close_on_pick`, `row_layout="stacked"` and the input's
    `form`/`maxlength`/`required`/`inputmode`.
  - `table_default` gets a `toolbar_primary` slot, `bulk_actions_toolbar` a `primary` slot, `form_actions`
    `submit_disabled`, `form_section` an `:actions` slot, an optional title, and `page_action` `show_label`.
    `Utils.Reorder` and `sortable_row` take non-UUID keys; modals take heights in `dvh` as well as `vh`.
  - `Utils.Date.short/1` and `short_with_year/1` — localized day-month dates.
- **Settings → Users → Profile Page:** an admin chooses which sections the user settings page shows (custom
  fields, email, start page, annotation reset, password, connected accounts, sessions, notifications, and the
  Google address inside the identity form). What is stored is the list of *hidden* sections, so a section added
  later shows up; a tab whose sections are all hidden is not offered; name and avatar cannot be hidden. The
  toggle is attributed to the admin. It hides the section on the page — it is not an access control.
- **`Storage.store_from_url/2`** — a fetch that cannot reach the server's own network: public addresses only
  (`Utils.PublicAddress`, IPv4 and IPv6, with `config :phoenix_kit, :blocked_ip_ranges` for ranges only your
  network knows), every redirect re-checked, https never downgraded to http, ports 80/443, size and time capped,
  bytes sniffed for the type. `URLSigner.verify_url/2` is the file route's own check for a file URL.
- **`Cache.remember/4`** — get-or-compute with a wall-clock expiry (`until: {:end_of_day, "Europe/Tallinn"}`,
  `:end_of_hour`, `:end_of_minute`); errors are returned, never stored. `Cache.put/4` takes `expires_in:`.
- **`PhoenixKitWeb.Plugs.ProbeBlock`** — answers scanner probes (`/.env`, `wp-login.php`, `*.php`) with a bare
  404; `/.well-known/` always passes; `extra:` / `except:` adjust it.
- **Sitemap:** `config :phoenix_kit, sitemap: [extra_sources: [...]]` adds sources without restating the
  defaults; a route with `metadata: %{sitemap: false}` stays out of the sitemap. The doctor warns when robots.txt
  (a static file or a routed one) has no `Sitemap:` line, and counts image sizes made by an older pipeline.
- **Host hooks:** `config :phoenix_kit, host_live_view_locale: :leave` keeps a host LiveView's own locale;
  `host_anonymous_scope: {Mod, :fun, args}` gives the host layout its own scope when nobody is signed in
  (display only). `hidden_admin_tabs` now also covers host, legacy and runtime-registered admin tabs.

### Fixed

- **`PhoenixKit.System.Dependencies` compiles on OTP 28.** The external-tools list held compiled
  `~r` sigils in a module attribute, which OTP 28 cannot escape into a function body; it is built
  in a function now.
- **A file that merely starts with the letters `BM` is no longer an image.** A CSV or note beginning
  "BMI,weight…" was sniffed as a BMP and stored as `image/bmp`; a BMP must also carry a valid file header.
- **A grayscale image is no longer treated as see-through.** `gray` contains the letter the alpha check
  looked for, so black-and-white photos were written as PNG instead of JPEG.
- **An animated GIF or WebP resized to a still format makes its file.** ImageMagick wrote one file per
  frame and never the one asked for, so the size failed on every retry; frame 0 is used unless the target is
  itself a GIF or WebP.
- **A download whose response ends with trailers is kept.** The trailers re-opened the temporary file and
  orphaned the downloaded one (`Storage.store_from_url/2`).
- **`Cache.remember/4` measures its boundary from before the load.** A load straddling midnight kept
  yesterday's value for a day more; `end_of_minute`/`end_of_hour` are also right across the hour the clocks go back.
- **`host_anonymous_scope` no longer takes the login pages down.** The host's function runs only when the
  layout has no scope yet, and one that raises leaves the scope absent and logs.
- **The hidden-profile-sections read fails open on a dead pool too** (it caught raises, not exits).
- **The profile's tabs stay on the personal integration "add" and edit pages.** They
  disappeared after "Add integration", so the page no longer said where you were.
- **The Multiple Sessions setting reads "Enable multiple sessions"** (it said "multi-account
  switcher in the header"; the switcher is in the user menu).

- **Image sizes keep transparency and are never enlarged.** A see-through image gets a PNG (or
  `variant_alpha_format`) size instead of a black-backed JPEG, and a size larger than its original is the
  original's size. Sizes made earlier keep working; `VariantSets.remake_all/0` remakes them (manual — it
  queues every size of every file — and every spec hash changed, so an ordinary revision bump of a size set
  also makes that set's files stale).
- **ImageMagick is pinned to the sniffed format and limited on every call.** A file is decoded only by the
  coder its bytes name, never one chosen from its file name; bytes nothing recognises under an `image/*` claim
  are stored as `application/octet-stream`.
- **The doctor no longer leaves a pooled connection with an empty `search_path`.** Behind PgBouncer in
  transaction mode its session-level `SET`/`RESET` landed on different backends, and a host's pages then failed
  with "relation does not exist" until the pool was reset; the setting is now transaction-local.
  `PostgresPreflight` no longer calls a PgBouncer login rejection "unreachable".
- **`table_default` keeps its toolbar on an empty plain table**, `gen.admin.page` stops rewriting the host's tab
  list and pointing gettext at the kit, `PublicAddress` no longer treats reserved IPv6 space as public, the
  `SearchPicker` list no longer sticks on "Searching…" when focus is elsewhere, and phone form fields no longer
  zoom iOS (including kit pages inside a host layout).
- **Core compiles on Elixir 1.18 with OTP 28.**

### Changed

- **`phoenix_kit_templates` floor is `~> 0.2.1`.** Core's email layout looks up the host's `_layout`
  override, which 0.2.0 skips.
- **The storage administration screens (Settings → Media: buckets, sizes, profiles, health) need
  `media.manage`, no longer just `media`.** So giving an end user Media does not hand them the
  bucket form.

### Upgrading

- Every role that holds `media` when this boots is granted `media.view_all` and `media.manage`
  once (and Admin gets them with the other new keys), so **nothing changes for existing roles**.
  A role created afterwards gets neither by default: a holder of `media` alone sees only their own
  files. Revoke `media.view_all` from a role to make it so; it is not given back.
- The media pickers (`MediaSelectorModal` and the featured-image picker) are not filtered by viewer.

---

Older releases are archived by quarter in
[`dev_docs/changelogs/`](https://github.com/BeamLabEU/phoenix_kit/tree/main/dev_docs/changelogs):
[2026 Q3](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q3.md) ·
[2026 Q2](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q2.md) ·
[2026 Q1](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q1.md) ·
[2025](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2025.md)
