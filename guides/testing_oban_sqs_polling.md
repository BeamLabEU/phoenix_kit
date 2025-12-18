# Testing Oban-based SQS Polling

Quick guide for testing the new Oban-based SQS polling system in IEx console.

## Prerequisites

1. PhoenixKit application running
2. Database with email system tables
3. AWS SQS queue configured

## Step 1: Check System Status

```elixir
# Open IEx console
iex -S mix phx.server

# Check if email system is enabled
PhoenixKit.Emails.enabled?()
# => true

# Check if SES events are enabled
PhoenixKit.Emails.ses_events_enabled?()
# => true

# Check if SQS polling is currently enabled
PhoenixKit.Emails.sqs_polling_enabled?()
# => false (initially)

# Check SQS configuration
config = PhoenixKit.Emails.get_sqs_config()
config.queue_url
# => "https://sqs.eu-north-1.amazonaws.com/..."
```

## Step 2: Enable Polling

```elixir
# Enable SQS polling
PhoenixKit.Emails.SQSPollingManager.enable_polling()
# => {:ok, %Oban.Job{id: 1, queue: "sqs_polling", ...}}

# Verify polling is enabled
PhoenixKit.Emails.sqs_polling_enabled?()
# => true
```

## Step 3: Check Polling Status

```elixir
# Get detailed status
status = PhoenixKit.Emails.SQSPollingManager.status()

# Check status fields
status.enabled
# => true

status.interval_ms
# => 5000

status.pending_jobs
# => 1

status.queue_url
# => "https://sqs.eu-north-1.amazonaws.com/..."
```

## Step 4: Trigger Manual Poll

```elixir
# Trigger immediate polling (useful for testing)
PhoenixKit.Emails.SQSPollingManager.poll_now()
# => {:ok, %Oban.Job{id: 2, ...}}

# Wait a moment and check status again
:timer.sleep(5000)
status = PhoenixKit.Emails.SQSPollingManager.status()
status.last_run
# => ~U[2025-09-20 15:30:45Z]
```

## Step 5: Monitor Jobs in Database

```elixir
# Query Oban jobs
import Ecto.Query
repo = PhoenixKit.RepoHelper.repo()

# Get all SQS polling jobs
jobs = from(j in Oban.Job,
  where: j.worker == "PhoenixKit.Emails.SQSPollingJob",
  order_by: [desc: j.inserted_at],
  limit: 10,
  select: %{
    id: j.id,
    state: j.state,
    scheduled_at: j.scheduled_at,
    completed_at: j.completed_at,
    errors: j.errors
  }
) |> repo.all()

# View jobs
jobs
# => [
#   %{id: 3, state: "completed", scheduled_at: ..., completed_at: ..., errors: []},
#   %{id: 2, state: "completed", scheduled_at: ..., completed_at: ..., errors: []},
#   %{id: 1, state: "completed", scheduled_at: ..., completed_at: ..., errors: []}
# ]
```

## Step 6: Change Polling Interval

```elixir
# Change polling interval to 3 seconds
PhoenixKit.Emails.SQSPollingManager.set_polling_interval(3000)
# => {:ok, %Setting{...}}

# Verify new interval
status = PhoenixKit.Emails.SQSPollingManager.status()
status.interval_ms
# => 3000

# Next scheduled job will use new interval
```

## Step 7: Disable Polling

```elixir
# Disable polling
PhoenixKit.Emails.SQSPollingManager.disable_polling()
# => :ok

# Verify polling is disabled
PhoenixKit.Emails.sqs_polling_enabled?()
# => false

# Check status (no new jobs will be scheduled)
status = PhoenixKit.Emails.SQSPollingManager.status()
status.enabled
# => false
```

## Step 8: Test Backward Compatibility

```elixir
# Test old SQSWorker API (should delegate to new API)

# Enable polling via old API
PhoenixKit.Emails.SQSWorker.resume()
# => :ok
# (Logs: "SQSWorker.resume/1 is deprecated - delegating to SQSPollingManager.enable_polling/0")

# Check status via old API
PhoenixKit.Emails.SQSWorker.status()
# => %{enabled: true, interval_ms: 3000, ...}

# Trigger manual poll via old API
PhoenixKit.Emails.SQSWorker.process_now()
# => :ok
# (Logs: "SQSWorker.process_now/1 is deprecated - delegating to SQSPollingManager.poll_now/0")

# Disable polling via old API
PhoenixKit.Emails.SQSWorker.pause()
# => :ok
# (Logs: "SQSWorker.pause/1 is deprecated - delegating to SQSPollingManager.disable_polling/0")
```

## Step 9: Test Error Handling

```elixir
# Test with invalid queue URL
PhoenixKit.Emails.set_sqs_queue_url("invalid-url")
PhoenixKit.Emails.SQSPollingManager.poll_now()
# Job will fail and log error

# Check failed job
import Ecto.Query
repo = PhoenixKit.RepoHelper.repo()

failed_jobs = from(j in Oban.Job,
  where: j.worker == "PhoenixKit.Emails.SQSPollingJob",
  where: fragment("cardinality(?) > 0", j.errors),
  order_by: [desc: j.inserted_at],
  limit: 1,
  select: %{id: j.id, state: j.state, errors: j.errors}
) |> repo.one()

failed_jobs.errors
# => [%{attempt: 1, at: ~U[...], error: "..."}]

# Restore valid queue URL
PhoenixKit.Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/...")
```

## Step 10: Continuous Monitoring

```elixir
# Watch polling for 1 minute
for _i <- 1..12 do
  status = PhoenixKit.Emails.SQSPollingManager.status()
  IO.puts("Pending jobs: #{status.pending_jobs}, Last run: #{status.last_run}")
  :timer.sleep(5000)
end
```

## Common Issues

### Issue: Jobs not scheduling

**Solution**: Check all prerequisites

```elixir
PhoenixKit.Emails.enabled?()
PhoenixKit.Emails.ses_events_enabled?()
PhoenixKit.Emails.sqs_polling_enabled?()
PhoenixKit.Emails.get_sqs_queue_url()
```

### Issue: AWS credentials error

**Solution**: Verify AWS configuration

```elixir
PhoenixKit.Emails.aws_configured?()
config = PhoenixKit.Emails.get_sqs_config()
config.aws_access_key_id
config.aws_secret_access_key
config.aws_region
```

### Issue: Oban not processing jobs

**Solution**: Check Oban status

```elixir
# Check if Oban is running
Oban.check_queue(queue: :sqs_polling)
# => {:ok, ...}

# Check queue configuration
Application.get_env(:your_app, Oban)
# => [repo: YourApp.Repo, queues: [sqs_polling: 1, ...], ...]
```

## Clean Up After Testing

```elixir
# Disable polling
PhoenixKit.Emails.SQSPollingManager.disable_polling()

# Cancel all pending jobs
import Ecto.Query
repo = PhoenixKit.RepoHelper.repo()

from(j in Oban.Job,
  where: j.worker == "PhoenixKit.Emails.SQSPollingJob",
  where: j.state in ["available", "scheduled"]
)
|> repo.delete_all()
```

## Next Steps

- Monitor production logs for polling activity
- Set up Oban Web UI for visual monitoring
- Configure alerts for failed jobs
- Adjust polling interval based on traffic

See [Oban SQS Polling Guide](./oban_sqs_polling.md) for complete documentation.
