# Emails Module

The PhoenixKit Emails module provides a production-ready outbound email pipeline with logging,
analytics, AWS SES integration, and a full administration UI. This document consolidates all of
the guidance that previously lived in `CLAUDE.md`.

## Architecture Overview

- **PhoenixKit.Emails** – Main API module for email functionality
- **PhoenixKit.Emails.EmailLog** – Core email logging schema with analytics
- **PhoenixKit.Emails.EmailEvent** – Event management (delivery, bounce, click, open)
- **PhoenixKit.Emails.EmailInterceptor** – Swoosh integration for automatic logging
- **PhoenixKit.Emails.SQSWorker** – AWS SQS polling for real-time events
- **PhoenixKit.Emails.SQSProcessor** – Message parsing and event handling
- **PhoenixKit.Emails.RateLimiter** – Anti-spam and rate limiting
- **PhoenixKit.Emails.Archiver** – Data lifecycle and S3 archival
- **PhoenixKit.Emails.Metrics** – Local database analytics and dashboard data

## Core Features

- **Comprehensive Logging** – All outgoing emails logged with metadata
- **Event Management** – Real-time delivery, bounce, complaint, open, click events
- **AWS SES Integration** – Deep integration with SES webhooks for event tracking
- **Analytics Dashboard** – Engagement metrics, campaign analysis, geographic data
- **Rate Limiting** – Multi-layer protection against abuse and spam patterns
- **Data Lifecycle** – Automatic archival, compression, and cleanup
- **Settings Integration** – Configurable via admin settings interface

## Database Tables

- **phoenix_kit_email_logs** – Main email logging with extended metadata
- **phoenix_kit_email_events** – Event management (delivery, engagement)
- **phoenix_kit_email_blocklist** – Blocked addresses for rate limiting
- **phoenix_kit_email_templates** – Email template storage and management

## LiveView Interfaces

- **Emails** – Email log browsing and management at `{prefix}/admin/emails`
- **Details** – Individual email details at `{prefix}/admin/emails/email/:id`
- **Metrics** – Analytics dashboard at `{prefix}/admin/emails/dashboard`
- **Queue** – Queue management at `{prefix}/admin/emails/queue`
- **Blocklist** – Blocklist management at `{prefix}/admin/emails/blocklist`
- **Templates** – Template management at `{prefix}/admin/emails/templates`
- **Template Editor** – Template creation/editing at `{prefix}/admin/emails/templates/new`
  and `{prefix}/admin/emails/templates/:id/edit`
- **Settings** – Email system configuration at `{prefix}/admin/settings/emails`

## Mailer Integration Example

```elixir
# PhoenixKit.Mailer automatically intercepts emails
email =
  new()
  |> to("user@example.com")
  |> from("app@example.com")
  |> subject("Welcome!")
  |> html_body("<h1>Welcome!</h1>")

# Emails are automatically logged when sent
PhoenixKit.Mailer.deliver_email(email,
  user_id: user.id,
  template_name: "welcome",
  campaign_id: "onboarding"
)
```

## AWS SES Infrastructure

PhoenixKit ships tooling that provisions the required AWS infrastructure and stores the resulting
configuration inside PhoenixKit settings. The automation creates:

- An SES configuration set with event publishing
- An SNS topic for SES events
- An SQS queue (and DLQ) with correct permissions
- IAM policies and roles tuned for the above resources
- Persisted configuration values in PhoenixKit Settings

## Configuration Strategy

Email system configuration is managed via the **Settings Database** (preferred) with fallbacks to
environment variables for secrets. Use `config/config.exs` only for baseline PhoenixKit integration.

### Key Settings

- `email_enabled` – Master toggle for the entire system
- `email_save_body` – Store full email content (increases storage)
- `email_ses_events` – Enable AWS SES event processing
- `email_retention_days` – Data retention period (30–365 days)
- `email_sampling_rate` – Percentage of emails to fully log
- `sqs_polling_enabled` – Enable/disable SQS polling worker
- `sqs_polling_interval_ms` – Polling interval for the worker

### Security Features

- Sampling rate controls to reduce storage load
- Per-recipient, per-sender, and global rate limiting
- Automatic blocklist for suspicious patterns
- Compression of historical email bodies
- Optional S3 archival for long-term retention

### Analytics Capabilities

- Engagement metrics (open, click, bounce rates)
- Campaign analysis and segmentation
- Geographic insights
- Provider-level deliverability tracking
- Real-time dashboards and trends

### Recommended Web UI Flow

1. Navigate to `{prefix}/admin/settings/emails`
2. Enable the email system (`email_enabled = true`)
3. Configure AWS SES region and configuration set
4. Adjust retention (`email_retention_days`) and sampling rate (`email_sampling_rate`)
5. Configure whether to persist full bodies (`email_save_body`)
6. Review additional SQS polling parameters as needed

### CLI Flow

```bash
mix phoenix_kit.configure_aws_ses --config-set "my-app-tracking"
mix phoenix_kit.configure_aws_ses --region "eu-north-1"
mix phoenix_kit.configure_aws_ses --status   # Check current config
```

### Environment Variables (Secrets Only)

```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="eu-north-1"  # Optional when stored in Settings
```

### Important Note

⚠️ **Do not configure email settings in `config/config.exs`.** Restrict that file to the PhoenixKit
`repo` and optional `mailer` integration. Manage email configuration at runtime via the Settings UI
or mix tasks.

### Configuration Sources (Priority)

PhoenixKit uses a smart fallback system for credentials and configuration:

1. **Settings Database** – Primary source. Values entered in the UI take precedence.
2. **Environment Variables** – Fallback when Settings values are empty or missing.
3. **config/config.exs** – Only for baseline PhoenixKit integration, never for sensitive data.

### Security Best Practices

- Store AWS credentials in environment variables (or secret manager) for production.
- Keep non-sensitive configuration in the Settings Database for runtime control.
- Never commit credentials or queue URLs to version control.

### Configuration Methods

#### Method 1: Web UI (Recommended)

- Navigate to `{prefix}/admin/settings/emails`
- Configure AWS SES, SNS, SQS endpoints
- Enable/disable the email system
- Adjust retention, sampling, and polling settings
- Changes take effect immediately without deploys

#### Method 2: Mix Task (CLI)

```bash
mix phoenix_kit.configure_aws_ses --config-set "my-app-tracking"
mix phoenix_kit.configure_aws_ses --region "us-east-1"
mix phoenix_kit.configure_aws_ses --status  # Check current config
```

#### Method 3: AWS Setup Script (Full Automation)

```bash
cd /app/scripts
./aws_ses_sqs_setup.sh  # Creates AWS infrastructure + saves to Settings DB
```

#### Method 4: Environment Variables (Secrets Only)

```bash
export AWS_ACCESS_KEY_ID="your-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="eu-north-1"
```

### Storage Map

**Settings Database**

- `aws_region` (default `eu-north-1`)
- `aws_sqs_queue_url`
- `aws_sqs_dlq_url`
- `aws_sqs_queue_arn`
- `aws_sns_topic_arn`
- `aws_ses_configuration_set` (default `phoenixkit-tracking`)
- `email_enabled`
- `email_save_body`
- `email_ses_events`
- `email_retention_days`
- `email_sampling_rate`
- `sqs_polling_enabled`
- `sqs_polling_interval_ms`
- All other email-related settings

**Environment Variables**

- `AWS_ACCESS_KEY_ID` – Used only when Settings DB lacks a value
- `AWS_SECRET_ACCESS_KEY` – Used only when Settings DB lacks a value
- `AWS_REGION` – Optional fallback region

**`config/config.exs`**

- `repo:` – PhoenixKit repository configuration (required)
- `mailer:` – Optional override to reuse parent app mailer
- Never store AWS credentials or email configuration here

### AWS Credentials Priority

```
1. Settings Database (primary)
   └─> If credentials exist and are non-empty → use them
2. Environment Variables (fallback)
   └─> Used when Settings Database values are blank
```

This means:

- ✅ Settings values override environment variables for runtime control
- ✅ Environment variables keep working when the Settings DB is empty
- ❌ Leaving both empty results in missing credentials

Example scenarios:

```bash
# 1) Web UI + ENV → Settings Database wins
# Settings: aws_access_key_id = "AKIA...from_ui"
# ENV:      AWS_ACCESS_KEY_ID = "AKIA...from_env"
# Result:   Uses "AKIA...from_ui"

# 2) ENV only → fallback kicks in
# Settings: aws_access_key_id = ""
# ENV:      AWS_ACCESS_KEY_ID = "AKIA...from_env"
# Result:   Uses "AKIA...from_env"

# 3) Nothing configured → error
# Settings: aws_access_key_id = ""
# ENV:      AWS_ACCESS_KEY_ID not set
# Result:   Raises configuration error
```

### Example Application Configuration

```elixir
# config/config.exs – ONLY basic app configuration
config :phoenix_kit,
  repo: MyApp.Repo,
  mailer: MyApp.Mailer  # Optional: delegate to parent app's mailer

# Configure your app's mailer for development
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.AmazonSES,
  region: "eu-north-1"
# AWS credentials are provided by PhoenixKit via the Settings Database
# Configure credentials via the Web UI at {prefix}/admin/settings/emails
```

## Email System Features

The PhoenixKit email system provides:

- Comprehensive email logging and analytics
- Real-time delivery, bounce, and engagement management
- Anti-spam and rate limiting features
- Admin interfaces at `{prefix}/admin/emails/*`
- Automatic integration with PhoenixKit.Mailer
- AWS SES event tracking via SNS/SQS pipeline

## Troubleshooting

### Common Issues and Solutions

#### Problem 1: Email fails with `expected a map, got: []`

**Symptoms**

```elixir
** (FunctionClauseError) no function clause matching in Map.merge/2
  expected a map, got: []
```

**Root Cause**

The `build_message_tags` function in `interceptor.ex` returned an empty list `[]` instead of a map `%{}`
whenever `message_tags` was passed in as a list.

**Solution**

✅ Fixed in v1.3.3+

A type guard was added in [`lib/phoenix_kit/emails/interceptor.ex:529-534`](lib/phoenix_kit/emails/interceptor.ex#L529-L534):

```elixir
defp build_message_tags(%Email{} = email, opts) do
  base_tags =
    case Keyword.get(opts, :message_tags, %{}) do
      tags when is_map(tags) -> tags
      _ -> %{}
    end
  # ...
end
```

**Verification**

```bash
mix test test/phoenix_kit/emails/interceptor_test.exs
# Expected: 13 tests, 0 failures
```

---

#### Problem 2: Logger warning while compiling the LiveView

**Symptoms**

```
warning: Logger.error/2 is undefined or private
```

**Root Cause**

The `require Logger` call lived inside a function instead of at the top of the module.

**Solution**

✅ Fixed – move `require Logger` to the top of the module:

```elixir
defmodule PhoenixKitWeb.Live.Modules.Emails.Emails do
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Emails
  # ...
end
```

---

#### Problem 3: No repository configured for PhoenixKit

**Symptoms**

```elixir
** (RuntimeError) No repository configured for PhoenixKit.
Please configure a repository in your application:
    config :phoenix_kit, repo: MyApp.Repo
```

**Root Cause**

PhoenixKit requires a configured repository in order to talk to the database.

**Solution**

1. **Production/Development** – add the repo configuration to `config/config.exs`:

   ```elixir
   config :phoenix_kit,
     repo: MyApp.Repo
   ```

2. **Tests** – most functions need a database. Use only the public APIs that do not require a repo,
   such as:

   - `PhoenixKit.Emails.Interceptor.detect_provider/2`
   - `PhoenixKit.Emails.Interceptor.build_ses_headers/2` (with a real log struct)

   Example `DataCase` setup:

   ```elixir
   defmodule PhoenixKit.DataCase do
     use ExUnit.CaseTemplate

     setup tags do
       :ok = Ecto.Adapters.SQL.Sandbox.checkout(PhoenixKit.Repo)

       unless tags[:async] do
         Ecto.Adapters.SQL.Sandbox.mode(PhoenixKit.Repo, {:shared, self()})
       end

       :ok
     end
   end
   ```

---

#### Problem 4: AWS SES credentials are ignored

**Symptoms**

- Emails are not delivered
- No errors appear in logs
- AWS credentials exist in ENV but are ignored

**Root Cause**

PhoenixKit uses the Settings Database as the primary source for AWS credentials.

**Solution**

1. **Check the Settings Database** via the Web UI:

   ```
   {prefix}/admin/settings/emails → aws_access_key_id field
   ```

2. **Check environment variables**:

   ```bash
   echo $AWS_ACCESS_KEY_ID
   echo $AWS_SECRET_ACCESS_KEY
   echo $AWS_REGION
   ```

3. **Clear the Settings Database** if you want to rely solely on environment variables:

   ```elixir
   PhoenixKit.Settings.delete_setting("aws_access_key_id")
   PhoenixKit.Settings.delete_setting("aws_secret_access_key")
   ```

**Verification**

```bash
mix phoenix_kit.configure_aws_ses --status
```

---

#### Problem 5: ConfigurationSetDoesNotExist error

**Symptoms**

```
AWS SES error: ConfigurationSetDoesNotExist
Configuration set 'myapp-emailing' does not exist
```

**Root Cause**

PhoenixKit versions before 1.4.5 required AWS CLI for SES setup (steps 8-9). In Docker/Kubernetes environments without AWS CLI installed, the setup appeared successful but the SES configuration set was never actually created in AWS.

**Solution (PhoenixKit 1.4.5+)**

✅ **Automatic** - infrastructure setup now uses SES v2 API without AWS CLI dependency

Simply re-run the setup:
```elixir
PhoenixKit.AWS.InfrastructureSetup.run(project_name: "yourapp")
```

**Solution (PhoenixKit < 1.4.5)**

1. **Recommended:** Upgrade to PhoenixKit 1.4.5+
2. Re-run setup: `PhoenixKit.AWS.InfrastructureSetup.run(project_name: "yourapp")`

**Manual workaround (if upgrade not possible):**

```bash
# Create configuration set manually
aws sesv2 create-configuration-set \
  --configuration-set-name "yourapp-emailing" \
  --region eu-north-1

# Configure event destination
aws sesv2 create-configuration-set-event-destination \
  --configuration-set-name "yourapp-emailing" \
  --event-destination-name "email-events-to-sns" \
  --event-destination '{
    "Enabled": true,
    "MatchingEventTypes": [
      "SEND", "REJECT", "BOUNCE", "COMPLAINT", "DELIVERY",
      "OPEN", "CLICK", "RENDERING_FAILURE", "DELIVERY_DELAY", "SUBSCRIPTION"
    ],
    "SnsDestination": {
      "TopicArn": "arn:aws:sns:eu-north-1:123456:yourapp-email-events"
    }
  }' \
  --region eu-north-1
```

**Verification**

Check that all 9 setup steps completed successfully:
```elixir
# Look for these log messages:
# [AWS Setup] [8/9] Creating SES Configuration Set...
# [AWS Setup]   ✓ SES Configuration Set created
# [AWS Setup] [9/9] Configuring SES event tracking to SNS...
# [AWS Setup]   ✓ SES Event Tracking configured
```

## Debugging Tips

- Enable verbose logging:

  ```elixir
  # config/dev.exs
  config :logger, level: :debug

  # In iex
  Logger.configure(level: :debug)
  ```

- Inspect recent logs:

  ```elixir
  logs = PhoenixKit.Emails.list_logs(limit: 10)
  failed = PhoenixKit.Emails.list_logs(status: "failed", limit: 10)
  log = PhoenixKit.Emails.get_log!(123)
  IO.inspect(log.error_message)
  ```

- Monitor queue depth:

  ```bash
  aws sqs get-queue-attributes \
    --queue-url "your-queue-url" \
    --attribute-names ApproximateNumberOfMessages
  ```

## Performance Tuning

**Problem: Slow email sending**

- **Symptoms** – Long delivery times and increased database load.
- **Mitigations**
  1. Disable full body saving:

     ```elixir
     PhoenixKit.Settings.update_setting("email_save_body", "false")
     ```

  2. Reduce sampling rate:

     ```elixir
     PhoenixKit.Settings.update_setting("email_sampling_rate", "10")
     ```

  3. Add database indexes:

     ```sql
     CREATE INDEX idx_email_logs_sent_at ON phoenix_kit_email_logs(sent_at);
     CREATE INDEX idx_email_logs_status ON phoenix_kit_email_logs(status);
     ```

## Testing Strategies

- **Unit tests (no DB)** – Focus on pure functions such as `detect_provider/2`.
- **Integration tests (with DB)** – Use `PhoenixKit.DataCase`, sandboxed repo.

Example:

```elixir
defmodule PhoenixKit.Emails.InterceptorTest do
  use ExUnit.Case, async: true

  describe "detect_provider/2" do
    test "detects AWS SES from headers" do
      email = Email.new() |> Email.header("X-SES-CONFIGURATION-SET", "test")
      assert Interceptor.detect_provider(email, []) == "aws_ses"
    end
  end
end
```

## Getting Help

1. Tail application logs: `tail -f log/dev.log`
2. Enable debug logging: `Logger.configure(level: :debug)`
3. Run the email test suite: `mix test test/phoenix_kit/emails/`
4. Search GitHub issues: <https://github.com/phoenixkit/phoenix_kit/issues>
5. Revisit this README for module-specific architecture and troubleshooting details
