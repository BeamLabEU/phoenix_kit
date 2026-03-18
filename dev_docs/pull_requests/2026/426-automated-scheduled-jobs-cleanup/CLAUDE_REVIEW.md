# Claude Review — PR #426

**Verdict:** Approve with suggestions
**Risk:** Low

## What's Good

### Problem Solving
- Addresses a real operational issue — database table bloat from completed jobs
- Clean implementation using Ecto's `delete_all/2` with proper query filtering
- Configurable defaults (7 days, common statuses) are sensible

### Code Quality
- Well-documented with clear examples in `@doc` string
- Uses `log: false` to avoid audit log spam for bulk deletions
- Logs cleanup activity for observability
- Uses `UtilsDate.utc_now()` for consistent UTC handling (matches project patterns)

### Design
- Non-invasive — adds utility function called by existing worker
- Automatic — no manual intervention or cron setup required
- Runs on every job processing cycle, so cleanup frequency scales with job volume

## Suggestions

### 1. Missing Tests (Low Priority)

No tests were added for `delete_old_jobs/2`. Consider adding:

```elixir
# Test file: test/phoenix_kit/scheduled_jobs_test.exs

describe "delete_old_jobs/2" do
  test "deletes jobs older than cutoff date" do
    # Create old executed job
    old_job = insert(:scheduled_job,
      status: "executed",
      updated_at: DateTime.add(UtilsDate.utc_now(), -10, :day)
    )

    # Create recent executed job (should not be deleted)
    recent_job = insert(:scheduled_job,
      status: "executed",
      updated_at: UtilsDate.utc_now()
    )

    # Create pending job (should not be deleted)
    pending_job = insert(:scheduled_job,
      status: "pending",
      updated_at: DateTime.add(UtilsDate.utc_now(), -10, :day)
    )

    {count, _} = ScheduledJobs.delete_old_jobs(7)

    assert count == 1
    assert repo().get(ScheduledJob, old_job.uuid) == nil
    assert repo().get(ScheduledJob, recent_job.uuid) != nil
    assert repo().get(ScheduledJob, pending_job.uuid) != nil
  end

  test "respects custom days parameter" do
    insert(:scheduled_job,
      status: "executed",
      updated_at: DateTime.add(UtilsDate.utc_now(), -5, :day)
    )

    {count, _} = ScheduledJobs.delete_old_jobs(7)

    assert count == 0
  end

  test "respects custom statuses parameter" do
    insert(:scheduled_job,
      status: "executed",
      updated_at: DateTime.add(UtilsDate.utc_now(), -10, :day)
    )
    insert(:scheduled_job,
      status: "failed",
      updated_at: DateTime.add(UtilsDate.utc_now(), -10, :day)
    )

    {count, _} = ScheduledJobs.delete_old_jobs(7, ["executed"])

    assert count == 1
  end
end
```

### 2. Consider Adding Oban Integration for Large Deployments (Enhancement)

For applications with very high job volumes, running `delete_all` on every worker execution could be expensive. Consider:

```elixir
# Option A: Rate limit cleanup to once per hour
@last_cleanup :atom

defp maybe_cleanup_old_jobs do
  now = System.system_time(:second)
  last_cleanup = Process.get(@last_cleanup, 0)

  if now - last_cleanup > 3600 do
    ScheduledJobs.delete_old_jobs()
    Process.put(@last_cleanup, now)
  end

  :ok
end

# Option B: Use Oban.Proliable for cleanup job
Oban.insert!(PhoenixKit.ScheduledJobs.CleanupJob,
  args: %{days: 7},
  schedule_in: :timer.hours(24)
)
```

This is a future enhancement — current implementation is fine for moderate job volumes.

### 3. Worker Execution Frequency Context (Minor)

The cleanup runs every time `ProcessScheduledJobsWorker` executes. Consider documenting the expected execution frequency in the module `@moduledoc`:

```elixir
@moduledoc """
Processes scheduled jobs and performs automatic cleanup of old records.

Runs every 60 seconds (configurable via Oban cron). Cleanup deletes
completed jobs older than 7 days to prevent table bloat.
"""
```

## Risk Assessment

| Change | Risk | Reason |
|--------|------|--------|
| `delete_old_jobs/2` function | Low | Pure query, well-scoped, uses safe defaults |
| Worker cleanup call | Low | Non-blocking, runs after main work, logged |

## Test Coverage

**Current:** No tests for `delete_old_jobs/2`
**Recommendation:** Add basic unit/integration tests (see Suggestion 1)

## Summary

This is a solid operational improvement that addresses a real pain point for long-running systems. The implementation is clean, well-documented, and follows project patterns. Adding tests would make it perfect.
