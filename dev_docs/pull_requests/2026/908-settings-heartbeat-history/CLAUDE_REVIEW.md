# Claude review — PR #908 (2026-10-06)

**Verdict:** sound; no bugs in the change. One test fragility fixed, one nitpick fixed, one follow-up recorded.

Scope: `history: false` for machine-written settings (the jobs sweeper stamp, sitemap generation stats,
the cached sitemap documents, the per-module stats JSON), `History.check_options!/1` refusing it with
`actor_uuid:` / `source: "settings"`, and the `:unrecorded` result threaded through `record/3`,
`publish/1` and `announce_committed/1`.

## Traced, no finding

- **Every writer is covered.** `update_setting`, `update_json_setting` and the `_with_module` variants
  all funnel through `Queries.insert_setting/2` / `update_setting/2` → `with_history/3`, which calls
  `check_options!/1` before opening the transaction; the batch path calls it first thing in
  `update_settings_batch/2` (so an empty batch is refused too) and `record/3` re-checks for direct callers.
  A refused call takes no lock and writes nothing, as documented.
- **`:unrecorded` is announced to the right audience.** `announce_committed/1` skips only `:unchanged`;
  for `:unrecorded` `History.publish/1` is a no-op and the `setting_changed` broadcast still goes out,
  so settings subscribers (and the cache invalidation) behave as for any write. `settings_subscribe_test`
  pins that.
- **Ordering in `record/3`.** `recorded?/1` runs `check_options!/1` before the `old == new` comparison,
  so a forbidden option combination fails the same way whether or not the value changed.
- **Sitemap seam.** `:sitemap_settings_module` is a test seam defaulting to `PhoenixKit.Settings`; the
  3-arity `update_setting` / `update_json_setting` calls match the real module. A custom stub has to
  accept the opts argument now — it is only a seam, nothing in the tree configures one.

## BUG - MEDIUM (test) — `sweep_worker_test` asserted an empty history on a shared DB — FIXED

`stamps every pass without writing the settings history` asserted
`History.list("job_runs_last_sweep_at") == []`. The history rows this PR stops producing are permanent
and committed, so any database that ever ran a pre-fix sweep outside a sandbox (the shared test DB held
three, dated 2026-10-03) fails the assertion although the code is right. The test now compares the entry
count before and after its three passes, which is what it means to prove.

## NITPICK — one comment block in `Queries.with_history/3` overflowed the line width — FIXED

The edit left a single ~120-column line in the middle of the comment; reflowed.

## IMPROVEMENT - MEDIUM (follow-up, not done) — history already written is never pruned

`History.record/3` marks its entries `permanent: true`, so the activity pruner never takes them. Hosts
that ran the sweeper (every five minutes) and sitemap generation before this release keep every
`setting.changed` row for `job_runs_last_sweep_at`, `sitemap_last_generated`, `sitemap_url_count`,
`sitemap_xml_cache` / `sitemap_html_cache` (whose `from`/`to` carry the whole document) and the module-stats
key. The PR stops the growth; it does not clean up what is there. A one-off cleanup in
`mix phoenix_kit.update` (delete `setting.changed` entries for exactly these keys) would finish the job.
Not done here: it deletes audit rows, which is the maintainer's call.
