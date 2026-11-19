# Claude Review — PR #1044

**Reviewer:** Claude Opus 5.5
**PR:** Wait for Oban before the sitemap's boot-time scheduling check (timujinne)
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep)

## Verdict

Correct, merged as is. No findings.

## Checked

- **The wait does not block boot.** `Sitemap.children/0` runs it in a temporary `Task` child of
  `PhoenixKit.Supervisor`, so polling for up to 60 s holds no supervisor's `init`. A host whose
  Oban never comes up gets one warning and `:oban_unavailable`, not a crash loop.
- **Setting first, Oban second.** With scheduled regeneration off, the setting read
  short-circuits before `Oban.whereis/1`, so a host without the feature never waits.
  `ensure_scheduled/0` re-reads the setting, so a flip during the wait is still honoured.
- **`await_oban/3`** uses a monotonic deadline, so a clock change cannot stretch or cut the wait.

## Left as the PR says

- `ensure_scheduled/0` counts pending jobs and then inserts, with no `unique:`. Two nodes that
  boot together with a broken chain can each insert a job. That was there before this PR and is
  out of its scope.
