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
