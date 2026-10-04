# The bucket page and the bucket log — request for review

To: Codex (second reviewer). From: Claude, for the maintainer. 2026-10-04.

Two stages, in this order. Please review the code, not this summary; where they disagree, say which is
wrong. Plan and decisions: `dev_docs/plans/2026-10-03-bucket-page.md` (its "Status" section).

**Nothing is released.** No version bump, no tag, no `hex.publish`. This review is the gate; the
CHANGELOG entry sits under `## Unreleased`.

## 1. What to read

| Commit | Pushed | What |
|---|---|---|
| `56fc96813` | yes | A page per site bucket: overview, used by, contents, health (probe button), history |
| `f412df994` | **no** | V208 `phoenix_kit_bucket_log` + the Log card on that page |

`git diff 32edc704e..f412df994 -- lib test config` is all the code and tests. Translations
(`priv/gettext`, 7 locales, 0 fuzzy), `CHANGELOG.md` and the plan doc are mechanical or prose.

By weight of risk, read in this order:

1. `lib/modules/storage/services/manager.ex` — the `report/3` hooks in `write_to`, `safe_retrieve`,
   `bucket_holds?`, `delete_from_bucket`, `delete_file`. This is the live read/write path of every file.
2. `lib/modules/storage/bucket_log.ex` — `record_failure/3` (async), `record/4`, `merge/4`, `not_found?/1`,
   `summary/1`, `recent/2`, `prune/0`.
3. `lib/phoenix_kit/migrations/postgres/v208.ex` and the `phoenix_kit_bucket_log` objects at the end of
   `lib/phoenix_kit/migrations/expected_schema.ex` (hand-declared; shapes copied from
   `Repair.Probe.snapshot/2` on a DB migrated through V208; `chain_hash` restamped).
4. `lib/modules/storage/storage.ex` — `probe_bucket/1`, `bucket_contents/1`, `bucket_location_health/1`,
   and the `delete_bucket/2` clean-up.
5. `lib/modules/storage/web/bucket_page.ex` + `.html.heex` — the LiveView.
6. Wiring: `lib/phoenix_kit_web/integration.ex` (route order), `lib/phoenix_kit_web/users/auth.ex`
   (permission map), `lib/phoenix_kit/install/oban_config.ex` + `config/config.exs` (cron entry),
   `lib/modules/storage/web/settings.{ex,html.heex}` (links; the helpers moved to `web/bucket_info.ex`).
7. Tests: `test/integration/phoenix_kit_web/live/bucket_page_test.exs` (22),
   `test/integration/storage/bucket_log_test.exs` (17), `test/phoenix_kit/migrations/v208_test.exs`,
   the two edits in `test/phoenix_kit/install/oban_config_test.exs`.

## 2. How it was verified

`mix precommit` exit 0; full `mix test` against `phoenix_kit_test`: 8106 tests, 0 failures, 6 skipped.
`release_check` passes the migration/chain-hash items (the rest are release-process items by design).
**Not done:** a browser check of the page (layout, the probe button, the latency bars), `verify.exs
--scenario s7,s8` (no generated baseline here; the real-DB manifest, repair and
`prefix_migration_test` suites were run instead), and any run against a real S3 bucket — every probe and
failure in the tests is a `local` provider.

To reproduce: `PGDATABASE=phoenix_kit_test mix test test/integration/phoenix_kit_web/live/bucket_page_test.exs
test/integration/storage/bucket_log_test.exs test/phoenix_kit/migrations/v208_test.exs`.

## 3. Deliberate choices — challenge them, don't just confirm them

- **Failures only, no successes.** A row per successful read would swamp a busy site. So "latency over
  time" is the *probes* (a click); there is no scheduled probe.
- **A miss is not a failure.** `not_found?/1` is a regex over the provider's message
  (`404|enoent|no such file|not found|nosuchkey`). It is a heuristic over strings. Does it hide a real
  failure (e.g. a message that merely contains "404" in a port or an id), or let a miss through?
- **The same failure within a minute is one row with a count** (`UPDATE … WHERE uuid IN (subquery LIMIT 1)`,
  else INSERT). Two concurrent failures can both insert; accepted. Probes never merge.
- **Written in the background** through `PhoenixKit.TaskSupervisor`; where that supervisor is not running
  (the test suite) it writes **synchronously**. Is the synchronous fallback ever reachable in production,
  and if so inside a caller's transaction (a missing table would poison it)?
- **No foreign key** on `bucket_uuid` (V206/V207 precedent): `Storage.delete_bucket/2` deletes the rows
  after the transaction, best effort. A bucket deleted mid-write leaves orphans until the prune.
- **A user's own bucket (V206) and an unsaved bucket are never logged** (`loggable?/1`).
- **The page reads the log in `handle_params`**, not in `mount`, and degrades to a notice when the table
  is missing (`rescue` + `catch :exit` in `load_log/1`).
- **Probe on a button only**, in `start_async`, re-reading the bucket inside the task so no key sits in
  the assigns.

## 4. What to look for

1. **Secrets in the log.** `message` is the provider's text (`inspect(reason, limit: 10)` for a non-string).
   ExAws error tuples can carry a response body or headers. Can a key, a signature or a presigned URL
   reach `phoenix_kit_bucket_log.message`, and so the page? The page is `media.manage` only.
2. **Can a log write ever fail or slow a file read/write?** Look at every `report/3` call site, the
   `rescue`/`catch :exit` in `record/4`, and `Task.Supervisor.start_child` under load (a bucket that is
   down with many requests per second).
3. **Prefix safety** of V208 and of the manifest entries (`__SCHEMA__`, `uuid_v7_call`, index names bare on
   CREATE). Does the manifest agree with what the chain builds, on a named-schema install?
4. **Visibility.** The page must never open a user's own bucket (`get_site_bucket/1`), and must count, never
   name, a user's profile or library (`Used by`, `By library`). Is there another path that names one?
5. **Route and permission.** `buckets/new` stays ahead of `buckets/:id`; the LiveView is mapped to
   `media.manage` in `auth.ex`. A `media`-only role must be refused.
6. **The cron backfill.** `ensure_worker_cron_entries/2` and `config/config.exs`: a host that already has
   the entry is not duplicated; one that lacks it gains it.
7. **`bucket_contents/1`** — `distinct: fl.path` inside a subquery, grouped by library: are objects counted
   once when cross-user copies share a key? Is the cost acceptable on a bucket with millions of rows (it
   runs in `start_async`, and has no index beyond `idx_file_locations_bucket_uuid`)?
8. **The "Log" and "Probe" gettext entries** and the others added in both commits: spot-check any locale you
   read. `Time` is the *duration* column header.

## 5. Known gaps (not bugs; say if you disagree they are acceptable)

- "Files missing a copy here" is not shown: the reconciler has no per-bucket query for it.
- "Used by" does not show the serve order (`Profiles.bucket_usage/1` does not return it).
- No retention setting in the UI (`bucket_log_retention_days` is a plain setting, default 30).
- The latency chart plots at most the last 20 probes; there is no time axis.

## 6. Questions

1. Is `Task.Supervisor.start_child` with a synchronous fallback the right shape, or should the log write
   go through Oban / a single batching process?
2. Should a failed probe of an unsaved form (`test_connection/1`) be recorded anywhere? Today it is not.
3. Is 30 days a sensible default retention for an operational log?

## 7. Reply format

`dev_docs/pull_requests/2026/<n>-bucket-page/CODEX_REVIEW.md`, or append a section to this file. Severities as
in `AGENTS.md`: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`. Please fix nothing;
report, and say which finding you would block a release on.

## 8. Codex review and improvements — 2026-10-04

Reviewed `32edc704e..f412df994`, including the surrounding providers, profile guards, supervision and
migration machinery. The maintainer subsequently asked to **review and improve** this work, so the
report-only instruction above was superseded. `f412df994` and the request commit were pushed before
making these changes. This review does not publish, tag or bump the version.

### Findings (fixed)

1. **BUG - HIGH — Provider diagnostics can persist credentials and signed URLs. Release blocker.**
   `BucketLog.reason_text/1` and `Storage.probe_message/1` copied strings or inspected provider errors,
   including ExAws response bodies and headers. Truncation is not redaction, and `media.manage` does not
   imply access to integration secrets. `safe_message/1` now returns only controlled diagnostics: HTTP
   status, known S3 error codes, known filesystem error atoms, a few exact operational messages, or a
   generic fallback. Both persistence and the page's probe/log display use it. Arbitrary response text,
   object paths and credentials are discarded; unknown errors consequently lose detail. Tests cover a
   response containing authorization headers, a secret key and a signed URL.

2. **BUG - HIGH — Failure logging can enter a file transaction or exhaust the process/DB pool.
   Release blocker.** The missing-supervisor fallback executed SQL synchronously. Rescuing a SQL error
   does not restore an aborted caller transaction. The shared supervisor also had no task cap, so a dead
   DB could accumulate a task per storage failure. A dedicated supervisor now admits at most four log
   tasks per node and drops diagnostics when absent or saturated. There is no synchronous fallback;
   supervisor exits are caught as well as exceptions. Tests verify both saturation and a missing log
   table inside a caller transaction with the supervisor stopped. `record/4` remains the explicitly
   synchronous API used by administrative probes; file operations use `record_failure/3`.

3. **BUG - MEDIUM — Missing-object detection hides genuine failures. Release blocker.** The original
   unanchored `404|…|not found` matched an endpoint on port 4040, and skipped writes reporting a missing
   source or failed copy verification. Only reads/deletes now suppress missing objects, using structured
   HTTP 404 / `:enoent` or their provider wrappers. A missing bucket is logged even on HTTP 404,
   and a 403 body mentioning `NoSuchKey` or `:enoent` is still a failure.
   Tests cover the port, missing write source, failed verification, ordinary misses and a misleading body.

4. **BUG - MEDIUM — Shared physical keys remove logical files and libraries from Contents.
   Release blocker.** `DISTINCT ON (path)` ran before file counts and library grouping, retaining just
   one arbitrary file/library for each shared key. File counts now come from all active locations;
   per-library objects group by library and key, and bucket totals independently group by key. Tests
   cover two files sharing a key, first in one library and then across site/personal libraries. A shared
   key's bytes are attributed to each library using it, while the bucket's physical bytes count once.

5. **BUG - MEDIUM — A continuous failure merges forever, inflating the last-day total.** The merge
   window was based only on the moving `last_at`. A failure every 30 seconds could keep a month's count
   in a row still considered wholly within the last day. Merging now also requires `inserted_at` within
   the minute. A regression test gives an old row a fresh `last_at` and verifies a new row is created.
   The 24-hour metric remains approximate at its boundary by at most one merge window, and diagnostics
   dropped under load are not counted. This is an operational count, not an exact event ledger.

6. **BUG - MEDIUM — Reusing the LiveView for another bucket retains the previous probe and contents.**
   `handle_params/3` left `probe`, `probing?`, health and contents unchanged; `load_log/1` preferred that
   stale probe over the new bucket's history. Navigation now cancels the outstanding probe and resets
   these assigns before loading the selected bucket. A LiveView patch test verifies the old successful
   probe disappears when the new bucket has no recorded probe.

7. **BUG - MEDIUM — Latest probe selection is ambiguous within one second.** Log timestamps have
   second precision, but summary queries ordered only by `last_at`. Reloading could show an earlier
   result instead of the most recent probe, and chart order could change. Queries now break ties with
   the UUIDv7, like `recent/2` already did. UUIDv7 orders milliseconds; probes in the same
   millisecond have a stable but arbitrary tie order. A regression test inserts success and failure at the same
   timestamp and verifies both the last result and chart order.

8. **IMPROVEMENT - MEDIUM — The claimed absence of keys in page assigns was inaccurate.** The page
   assigned the entire bucket row, including legacy credential fields. The display bucket now clears
   both key fields and retains only a separate legacy-credentials badge flag. Mutating actions reload
   the saved site bucket before calling the guarded context functions, preserving its credentials and
   using current state. A cloud bucket test verifies the assigns, badge and credential-preserving toggle.
   This was server-side retention, not evidence that credentials were rendered to the browser.

### Checks and remaining limits

- V208's SQL, schema-prefix use, manifest shapes and chain hash agree with the real-DB checks. No
  migration or expected-schema changes were needed. The named-schema full-chain test passes.
- Route order and `media.manage` mapping are correct. The existing page tests reject a media-only user
  and a personal bucket. Site profile/library names and personal counts stay separate, including shared
  keys; profile writes continue through the existing ownership guards.
- Cron installation/backfill includes the prune worker and preserves an existing entry. The Oban
  configuration tests pass. Deletion cleanup and eventual pruning of racing orphan rows are acceptable
  for this operational log.
- Contents still scans the bucket's active locations, now with separate logical and physical aggregates.
  Async loading keeps it off the render path, but is not a performance guarantee. No million-row
  benchmark, browser layout check, or real S3 credentials/network probe was performed. The secret tests
  use representative ExAws error shapes; they do not claim a live cloud test.
- Existing stored messages are sanitized on display, but earlier raw values are not rewritten in the
  database. This code remains unreleased. If it was deployed privately, investigate any existing log
  rows before treating the new writer as remediation of historical secret exposure.

### Answers and release decision

1. Keep best-effort logging with a bounded dedicated task supervisor for now. Oban would add durable
   work precisely when the DB/provider is failing. A batching process can be justified later if measured
   failure volume requires it; do not promise exact counts with the current drop-on-overload policy.
2. Do not persist unsaved form tests in the bucket log. They have no stable saved-bucket identity and
   can include personal configuration. Show the result to the form's caller.
3. Thirty days is a reasonable operational default. A retention UI, scheduled probes, serve-order display
   and a per-bucket missing-copy query can follow separately. Their omission does not block this change.
   A 20-probe latency chart is useful as a recent sample, but does not establish long-term availability.

The four explicit release blockers above are fixed. The remaining limitations are acceptable for an
operational diagnostics page; publishing remains a separate task with the repository's release gate.

**Final verification:**

- `PGDATABASE=phoenix_kit_test PGPOOL=10 mix test --max-cases 6`: exit 0;
  **76 doctests, 8,114 tests, 0 failures, 6 skipped, 1 excluded**, with PostgreSQL available.
- The final bucket log/page run after the last classifier and tie-order test refinements: exit 0;
  **48 tests, 0 failures**.
- Expanded migration, real-manifest, hand-declared-manifest, prefix-chain, repair, Oban-config and
  bucket tests: exit 0; **136 tests, 0 failures**.
- Final `mix precommit`: exit 0, including compile, test compilation, formatting, Credo, Dialyzer
  and **254 JavaScript tests**. An existing unreachable-clause warning in
  `test/integration/phoenix_kit_web/live/settings/email_preview_test.exs:87` remains outside this change.
- `git diff --check`: clean. Browser layout, real S3 probing and large-bucket performance remain
  unverified as described above.
