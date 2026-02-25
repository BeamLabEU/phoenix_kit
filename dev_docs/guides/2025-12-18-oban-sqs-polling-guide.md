# Oban-based SQS Polling for PhoenixKit Email System

## Overview

PhoenixKit Email System now uses Oban jobs for SQS polling instead of GenServer. This provides:

- **Dynamic Control**: Enable/disable polling without application restart
- **Better Monitoring**: View jobs in Oban Web UI
- **Automatic Retries**: Built-in retry mechanism via Oban
- **Self-Scheduling**: Each job schedules the next polling cycle
- **Settings Integration**: Automatically responds to PhoenixKit Settings changes

## Architecture

```
AWS SES → SNS Topic → SQS Queue → Oban Job (SQSPollingJob) → SQSProcessor → Database
```

## Configuration

### 1. Oban Queue Configuration

Add to your `config/config.exs`:

```elixir
config :your_app, Oban,
  repo: YourApp.Repo,
  queues: [
    default: 10,
    emails: 50,
    file_processing: 20,
    posts: 10,
    sitemap: 5,
    sqs_polling: 1  # Only one concurrent polling job
  ],
  plugins: [
    Oban.Plugins.Pruner
  ]
```

**Important**: `sqs_polling: 1` ensures only one polling job runs at a time.

### 2. PhoenixKit Settings

Configure SQS polling via Settings:

```elixir
# Enable/disable polling
PhoenixKit.Emails.set_sqs_polling(true)

# Set polling interval (milliseconds)
PhoenixKit.Emails.set_sqs_polling_interval(5000)

# Set max messages per poll (1-10)
PhoenixKit.Emails.set_sqs_max_messages(10)

# Configure AWS SQS
PhoenixKit.Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/...")
PhoenixKit.Emails.set_aws_region("eu-north-1")
```

## Usage

### Starting Polling

```elixir
# Enable polling and start first job
iex> PhoenixKit.Emails.SQSPollingManager.enable_polling()
{:ok, %Oban.Job{id: 123, queue: "sqs_polling"}}
```

### Stopping Polling

```elixir
# Disable polling (existing jobs will skip execution)
iex> PhoenixKit.Emails.SQSPollingManager.disable_polling()
:ok
```

### Manual Polling

```elixir
# Trigger immediate poll (regardless of schedule)
iex> PhoenixKit.Emails.SQSPollingManager.poll_now()
{:ok, %Oban.Job{id: 124}}
```

### Checking Status

```elixir
iex> PhoenixKit.Emails.SQSPollingManager.status()
%{
  enabled: true,
  interval_ms: 5000,
  pending_jobs: 1,
  last_run: ~U[2025-09-20 15:30:45Z],
  queue_url: "https://sqs.eu-north-1.amazonaws.com/...",
  aws_region: "eu-north-1",
  max_messages_per_poll: 10,
  system_enabled: true,
  ses_events_enabled: true
}
```

### Changing Polling Interval

```elixir
# Set to 3 seconds (3000ms)
iex> PhoenixKit.Emails.SQSPollingManager.set_polling_interval(3000)
{:ok, %Setting{}}

# Next scheduled job will use new interval
```

## How It Works

### Job Lifecycle

1. **Job Execution**: `SQSPollingJob.perform/1` is called
2. **Settings Check**: Job checks if `sqs_polling_enabled?()` is true
3. **Polling**: If enabled, polls SQS queue for messages
4. **Processing**: Processes messages via `SQSProcessor`
5. **Self-Scheduling**: Schedules next job after `polling_interval_ms`

### Dynamic Control

Jobs check settings **before each execution**:

```elixir
# Disable polling
PhoenixKit.Emails.set_sqs_polling(false)

# Next scheduled job will skip execution and NOT schedule another job
# Polling stops automatically
```

### Unique Jobs

Jobs use `unique: [period: 60]` to prevent duplicates:

```elixir
# Only one job of this type can be scheduled within 60 seconds
use Oban.Worker,
  queue: :sqs_polling,
  max_attempts: 3,
  unique: [period: 60]
```

## Monitoring

### Via Oban Web UI

If you have Oban Web installed:

1. Navigate to `/admin/oban` (or your Oban Web path)
2. Filter by queue: `sqs_polling`
3. View job history, failures, retries

### Via Status Function

```elixir
iex> status = PhoenixKit.Emails.SQSPollingManager.status()
iex> status.pending_jobs
1
iex> status.last_run
~U[2025-09-20 15:30:45Z]
```

### Via Database

```elixir
# Query Oban jobs table
iex> import Ecto.Query
iex> repo = PhoenixKit.RepoHelper.repo()
iex> from(j in Oban.Job,
...>   where: j.worker == "PhoenixKit.Emails.SQSPollingJob",
...>   where: j.state in ["available", "scheduled", "executing"],
...>   select: {j.id, j.state, j.scheduled_at}
...> ) |> repo.all()
[{123, "scheduled", ~U[2025-09-20 15:35:45Z]}]
```

## Backward Compatibility

### Existing SQSWorker API

The old GenServer-based API still works via delegation:

```elixir
# Old API (deprecated but works)
PhoenixKit.Emails.SQSWorker.status()
PhoenixKit.Emails.SQSWorker.pause()
PhoenixKit.Emails.SQSWorker.resume()
PhoenixKit.Emails.SQSWorker.process_now()

# New API (recommended)
PhoenixKit.Emails.SQSPollingManager.status()
PhoenixKit.Emails.SQSPollingManager.disable_polling()
PhoenixKit.Emails.SQSPollingManager.enable_polling()
PhoenixKit.Emails.SQSPollingManager.poll_now()
```

### Migration Path

If you're using the old GenServer approach:

1. **No immediate action required** - delegation maintains compatibility
2. **Update code gradually** - replace `SQSWorker` calls with `SQSPollingManager`
3. **Test thoroughly** - verify polling works with new approach
4. **Monitor logs** - look for deprecation warnings

## Troubleshooting

### Polling Not Starting

Check all prerequisites:

```elixir
# 1. Email system enabled?
iex> PhoenixKit.Emails.enabled?()
true

# 2. SES events enabled?
iex> PhoenixKit.Emails.ses_events_enabled?()
true

# 3. Polling enabled?
iex> PhoenixKit.Emails.sqs_polling_enabled?()
true

# 4. Queue URL configured?
iex> PhoenixKit.Emails.get_sqs_queue_url()
"https://sqs.eu-north-1.amazonaws.com/..."

# 5. Oban running?
iex> Oban.check_queue(queue: :sqs_polling)
{:ok, ...}
```

### Jobs Not Processing

Check job status in database:

```elixir
iex> import Ecto.Query
iex> repo = PhoenixKit.RepoHelper.repo()
iex> from(j in Oban.Job,
...>   where: j.worker == "PhoenixKit.Emails.SQSPollingJob",
...>   order_by: [desc: j.inserted_at],
...>   limit: 5,
...>   select: {j.id, j.state, j.errors}
...> ) |> repo.all()
```

### AWS Credentials Issues

Verify AWS configuration:

```elixir
iex> PhoenixKit.Emails.aws_configured?()
true

iex> config = PhoenixKit.Emails.get_sqs_config()
iex> config.aws_access_key_id
"AKIA..."
iex> config.aws_region
"eu-north-1"
```

## Performance Considerations

### Polling Interval

- **Too frequent** (< 1s): May hit AWS rate limits, wastes resources
- **Too infrequent** (> 60s): Delays email event processing
- **Recommended**: 5-10 seconds for most applications

### Max Messages Per Poll

- **Maximum**: 10 (SQS limit)
- **Recommended**: 10 for high-volume systems, 5 for low-volume

### Queue Concurrency

- **Always use**: `sqs_polling: 1`
- **Why**: Prevents duplicate polling and race conditions

## Example: Complete Setup

```elixir
# 1. Enable email system
PhoenixKit.Emails.enable_system()

# 2. Enable SES events
PhoenixKit.Emails.set_ses_events(true)

# 3. Configure AWS SQS
PhoenixKit.Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/164974350822/phoenixkit-email-queue")
PhoenixKit.Emails.set_aws_region("eu-north-1")

# 4. Set polling parameters
PhoenixKit.Emails.set_sqs_polling_interval(5000)  # 5 seconds
PhoenixKit.Emails.set_sqs_max_messages(10)

# 5. Enable polling
PhoenixKit.Emails.SQSPollingManager.enable_polling()

# 6. Verify status
PhoenixKit.Emails.SQSPollingManager.status()

# 7. Monitor for a few minutes
:timer.sleep(60_000)
PhoenixKit.Emails.SQSPollingManager.status()
```

## Related Documentation

- [Email System Overview](/app/lib/phoenix_kit_web/live/modules/emails/README.md)
- [AWS SES Setup Guide](/app/scripts/aws_ses_sqs_setup.sh)
- [Oban Documentation](https://hexdocs.pm/oban/Oban.html)
- [PhoenixKit Settings](/app/lib/phoenix_kit/settings.ex)
