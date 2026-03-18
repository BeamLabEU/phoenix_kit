# PR #426: Add automated scheduled jobs cleanup

**Author:** construct-d
**Status:** Merged
**Files changed:** 2 (40 additions, 0 deletions)

## Summary

Adds automated cleanup of old completed scheduled jobs to prevent database table bloat in long-running systems. The cleanup runs automatically after each scheduled job processing cycle.

## Changes

### `lib/phoenix_kit/scheduled_jobs.ex`

Added `delete_old_jobs/2` function:
- Deletes completed jobs older than a retention period (default: 7 days)
- Configurable statuses: `"executed"`, `"failed"`, `"cancelled"`
- Returns count of deleted records
- Logs cleanup activity

### `lib/phoenix_kit/scheduled_jobs/workers/process_scheduled_jobs_worker.ex`

Added cleanup call in worker:
- Executes `ScheduledJobs.delete_old_jobs()` after processing scheduled jobs
- Runs on every worker execution cycle

## Implementation Details

```elixir
def delete_old_jobs(days \\ 7, statuses \\ ["executed", "failed", "cancelled"]) do
  cutoff_date = DateTime.add(UtilsDate.utc_now(), -days * 24 * 3600, :second)

  {count, _} =
    from(j in ScheduledJob,
      where: j.status in ^statuses,
      where: j.updated_at < ^cutoff_date
    )
    |> repo().delete_all(log: false)

  if count > 0 do
    Logger.info("ScheduledJobs: Deleted #{count} old job(s) older than #{days} days")
  end

  {count, nil}
end
```

## Why This Matters

- **Prevents table bloat** — Old completed jobs accumulate over time
- **No manual intervention** — Automatic cleanup on every job processing cycle
- **Configurable** — Retention period and statuses can be customized
- **Safe** — Uses `delete_all(log: false)` for efficiency, only affects completed jobs

## Testing

No tests were added for this new function. Consider adding:
- Unit tests for cutoff date calculation
- Integration tests with fixture jobs of various ages
- Tests for custom status filtering
