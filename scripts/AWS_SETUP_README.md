# AWS Email Infrastructure Setup Script

Automated script to create complete AWS infrastructure for email event handling via SNS and SQS.

## What the Script Creates

The script automatically creates a complete infrastructure for processing email events:

```
SES Events → SNS Topic → SQS Main Queue → Your Application
                              ↓ (after N failed attempts)
                         SQS Dead Letter Queue
```

### Created Resources:

1. **SNS Topic** - receives events from SES
2. **SQS Main Queue** - main queue for message processing
3. **SQS Dead Letter Queue (DLQ)** - queue for failed messages
4. **IAM Policies** - access policies between services
5. **SNS Subscription** - SQS subscription to SNS topic
6. **SES Configuration Set** - tracks email events (sends, bounces, opens, clicks, etc.)
7. **SES Event Destination** - forwards SES events to SNS topic

## Usage

### 1. Configure Parameters

Open `scripts/setup_aws_email_infrastructure.sh` and modify parameters in the **CONFIGURATION** section:

```bash
# Project name (used as prefix for all resources)
PROJECT_NAME="myapp"

# AWS region
AWS_REGION="eu-north-1"

# Queue names (created automatically)
MAIN_QUEUE_NAME="${PROJECT_NAME}-email-queue"
DLQ_NAME="${PROJECT_NAME}-email-dlq"

# SNS Topic name
SNS_TOPIC_NAME="${PROJECT_NAME}-email-events"

# SES Configuration Set name
SES_CONFIG_SET_NAME="${PROJECT_NAME}-emailing"

# Queue configurations
MAIN_QUEUE_VISIBILITY_TIMEOUT=300        # 5 minutes
MAIN_QUEUE_MESSAGE_RETENTION=345600      # 4 days
MAIN_QUEUE_MAX_RECEIVE_COUNT=3           # Retries before DLQ
MAIN_QUEUE_RECEIVE_WAIT_TIME=20          # Long polling

DLQ_VISIBILITY_TIMEOUT=60                # 1 minute
DLQ_MESSAGE_RETENTION=1209600            # 14 days

# Application SQS polling interval (milliseconds)
SQS_POLLING_INTERVAL=5000                # 5 seconds
```

### 2. Verify AWS CLI

Ensure AWS CLI is configured with proper credentials:

```bash
aws configure list
aws sts get-caller-identity
```

### 3. Run the Script

```bash
bash scripts/setup_aws_email_infrastructure.sh
```

or:

```bash
./scripts/setup_aws_email_infrastructure.sh
```

### 4. Execution Result

The script will output:
- Progress of resource creation
- **Ready-to-use values for configuration form**
- Commands for infrastructure verification
- Save configuration to file `aws-email-config-{PROJECT_NAME}.txt`

## Example Output

```
==============================================
AWS Email Infrastructure Setup
==============================================

Configuration:
  Project: myapp
  Region: eu-north-1
  Main Queue: myapp-email-queue
  DLQ: myapp-email-dlq
  SNS Topic: myapp-email-events
  SES Configuration Set: myapp-emailing

[1/9] Getting AWS Account ID...
  ✓ Account ID: 123456789012

[2/9] Creating Dead Letter Queue...
  ✓ DLQ Created/Found
    URL: https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-dlq
    ARN: arn:aws:sqs:eu-north-1:123456789012:myapp-email-dlq

[3/9] Setting DLQ policy...
  ✓ DLQ Policy set

[4/9] Creating SNS Topic...
  ✓ SNS Topic Created/Found
    ARN: arn:aws:sns:eu-north-1:123456789012:myapp-email-events

[5/9] Creating Main Queue with DLQ redrive policy...
  ✓ Main Queue Created/Found
    URL: https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-queue
    ARN: arn:aws:sqs:eu-north-1:123456789012:myapp-email-queue

[6/9] Setting Main Queue policy to allow SNS and account access...
  ✓ Main Queue Policy set

[7/9] Creating SNS subscription to SQS...
  ✓ SNS → SQS Subscription created

[8/9] Creating SES Configuration Set...
  ✓ SES Configuration Set created/verified
    Name: myapp-emailing

[9/9] Configuring SES event tracking to SNS...
  ✓ SES Event Tracking configured
    Events: send, reject, bounce, complaint, delivery, open, click, renderingFailure
    Destination: SNS → SQS

==============================================
✓ Setup Complete!
==============================================

Copy these values to your application configuration form:

╔════════════════════════════════════════════════════════════════════╗
║                    AWS Configuration Form                          ║
╚════════════════════════════════════════════════════════════════════╝

AWS Region:
  eu-north-1

─────────────────────────────────────────────────────────────────────
Email Sender Settings
─────────────────────────────────────────────────────────────────────

From Email:
  [e.g., hello@myapp.com]

From Name:
  [e.g., Myapp]

NOTE: Configure these in your application's config.exs and runtime.exs

─────────────────────────────────────────────────────────────────────
AWS SES & SQS Settings
─────────────────────────────────────────────────────────────────────

SES Configuration Set:
  myapp-emailing

SQS Polling Interval:
  5000 (ms)

SNS Topic ARN:
  arn:aws:sns:eu-north-1:123456789012:myapp-email-events

SQS Queue URL:
  https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-queue

SQS Queue ARN:
  arn:aws:sqs:eu-north-1:123456789012:myapp-email-queue

SQS Dead Letter Queue URL:
  https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-dlq

SQS Dead Letter Queue ARN:
  arn:aws:sqs:eu-north-1:123456789012:myapp-email-dlq
```

## Multi-Site Configuration

### Using the Script for Multiple Sites in One AWS Account

**Good news**: The script is designed for multi-site usage! You can run it multiple times with different `PROJECT_NAME` values.

#### Why it works perfectly:

1. **Resource Isolation**: Each PROJECT_NAME creates unique resource names:
   - `site1-email-queue`, `site1-email-dlq`, `site1-email-events`
   - `site2-email-queue`, `site2-email-dlq`, `site2-email-events`

2. **Independent Processing**: Each site processes only its own messages

3. **Different SES Configuration Sets**: Each site can have its own configuration set

4. **AWS Limits**: SQS and SNS have high limits (tens of thousands of resources)

#### Best Practices for Multi-Site Setup:

1. **Naming**: Use meaningful PROJECT_NAME values (e.g., `eznews`, `blogsite`, `shop`)
2. **Monitoring**: Add tags to resources for grouping (optional enhancement)
3. **Billing**: Use tags to track costs per project (optional enhancement)

#### Example for Multiple Sites:

```bash
# Site 1
PROJECT_NAME="eznews" ./scripts/setup_aws_email_infrastructure.sh

# Site 2
PROJECT_NAME="blogsite" ./scripts/setup_aws_email_infrastructure.sh

# Site 3
PROJECT_NAME="shop" ./scripts/setup_aws_email_infrastructure.sh
```

**No script modifications needed** - it's ready for multi-site usage!

## Using in Different AWS Accounts

To create infrastructure in a different AWS account:

1. Configure AWS CLI for the new account:
   ```bash
   aws configure --profile new-account
   ```

2. Modify parameters in the script (PROJECT_NAME, region, etc.)

3. Run script with the appropriate profile:
   ```bash
   AWS_PROFILE=new-account ./scripts/setup_aws_email_infrastructure.sh
   ```

## SES Identity Verification

**IMPORTANT**: Before you can send emails with AWS SES, you must verify the email addresses or domains you want to send from.

### Understanding SES Sandbox vs Production

When you first create an AWS account, your SES account is in **Sandbox mode** with these restrictions:

#### Sandbox Mode Restrictions:
- ❌ Can only send TO verified email addresses
- ❌ Can only send FROM verified email addresses
- ❌ Limited to 200 emails per day
- ❌ Limited to 1 email per second

#### Production Mode Benefits:
- ✅ Can send to ANY email address
- ✅ Higher sending quota (default: 50,000 emails/day)
- ✅ Higher sending rate (default: 14 emails/second)
- ✅ Can request quota increases

### Checking Your SES Account Status

```bash
# Check if you're in sandbox or production mode
aws sesv2 get-account --region YOUR_REGION

# Look for "ProductionAccessEnabled": true or false
```

### Verifying Email Addresses

To verify a single email address:

```bash
# Send verification email
aws ses verify-email-identity \
  --email-address hello@yourdomain.com \
  --region YOUR_REGION

# Check verification status
aws ses get-identity-verification-attributes \
  --identities hello@yourdomain.com \
  --region YOUR_REGION

# List all verified identities
aws ses list-identities --region YOUR_REGION
```

**Steps:**
1. Run the `verify-email-identity` command
2. Check the inbox of that email address
3. Click the verification link in the email from AWS
4. Verification completes instantly after clicking the link

### Verifying Domains (Recommended for Production)

Domain verification allows you to send from ANY email address at that domain (e.g., hello@, noreply@, support@).

```bash
# Start domain verification
aws ses verify-domain-identity \
  --domain yourdomain.com \
  --region YOUR_REGION

# This returns DNS records you need to add
```

**Steps:**
1. Run the command above - it returns TXT records
2. Add the TXT record to your domain's DNS settings
3. Wait for DNS propagation (can take up to 72 hours, usually 30 minutes)
4. AWS automatically detects the DNS record and verifies the domain

**Example DNS Record:**
```
Type: TXT
Name: _amazonses.yourdomain.com
Value: [Long verification code from AWS]
TTL: 1800
```

### Checking Verification Status

```bash
# Check specific email/domain
aws ses get-identity-verification-attributes \
  --identities yourdomain.com hello@yourdomain.com \
  --region YOUR_REGION

# Check all identities
aws ses list-identities --region YOUR_REGION

# Check with detailed info
aws sesv2 list-email-identities --region YOUR_REGION
```

### Requesting Production Access

If you're still in Sandbox mode, request production access:

1. **Via AWS Console:**
   - Go to SES console → Account Dashboard
   - Click "Request production access"
   - Fill out the form explaining your use case
   - Usually approved within 24 hours

2. **Via AWS CLI:**
   ```bash
   # Check current status
   aws sesv2 get-account --region YOUR_REGION | jq '.ProductionAccessEnabled'
   ```

### Common Verification Issues

#### Issue: "Email address is not verified" error
**Solution**: Verify the FROM email address:
```bash
aws ses verify-email-identity --email-address your-from-email@domain.com --region YOUR_REGION
```

#### Issue: Can only send to certain addresses
**Solution**: You're in Sandbox mode. Either:
- Verify recipient email addresses (for testing)
- Request production access (for real usage)

#### Issue: Domain verification not working
**Solution**:
```bash
# Check DNS propagation
dig TXT _amazonses.yourdomain.com

# Verify DNS record matches AWS value exactly
aws ses verify-domain-identity --domain yourdomain.com --region YOUR_REGION
```

### Best Practices

1. **For Development/Testing**: Verify individual email addresses
2. **For Production**: Verify the entire domain
3. **Multiple Domains**: You can verify multiple domains in the same account
4. **Sender Reputation**: Use a consistent FROM address (e.g., hello@yourdomain.com)
5. **DKIM**: Enable DKIM signing for better deliverability

### Setting up DKIM (Optional but Recommended)

DKIM improves email deliverability and helps prevent emails from going to spam:

```bash
# Enable DKIM for a domain
aws sesv2 create-email-identity \
  --email-identity yourdomain.com \
  --dkim-signing-attributes SigningEnabled=true \
  --region YOUR_REGION

# Get DKIM records to add to DNS
aws sesv2 get-email-identity \
  --email-identity yourdomain.com \
  --region YOUR_REGION | jq '.DkimAttributes'
```

This returns 3 CNAME records to add to your DNS.

## Verifying Created Infrastructure

### Check message count in queue:
```bash
aws sqs get-queue-attributes \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-queue" \
  --attribute-names ApproximateNumberOfMessages
```

### Check DLQ:
```bash
aws sqs get-queue-attributes \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-dlq" \
  --attribute-names ApproximateNumberOfMessages
```

### Test SNS publish:
```bash
aws sns publish \
  --topic-arn "arn:aws:sns:eu-north-1:123456789012:myapp-email-events" \
  --message "Test message"
```

### Receive messages from queue:
```bash
aws sqs receive-message \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-queue" \
  --max-number-of-messages 10 \
  --wait-time-seconds 20
```

## Features

### Idempotency
The script can be run multiple times - it won't create duplicates but will use existing resources.

### Security & Permissions

#### SQS Queue Policy
The script configures a comprehensive SQS policy with two statements:

1. **SNS Access** - Allows SNS to publish messages:
   - Principal: `sns.amazonaws.com`
   - Action: `SQS:SendMessage`
   - Condition: Only from the configured SNS topic

2. **Account Access** - Allows IAM users/roles in the account to manage messages:
   - Principal: `arn:aws:iam::{ACCOUNT_ID}:root`
   - Actions:
     - `SQS:ReceiveMessage` - Read messages from queue
     - `SQS:DeleteMessage` - Delete processed messages
     - `SQS:GetQueueAttributes` - Check queue status
     - `SQS:SendMessage` - Send test messages

**Why both statements are needed:**
- The first allows SES → SNS → SQS event flow
- The second allows your application to receive and delete messages after processing
- Without the second statement, you'll see `[warning] Failed to delete SQS message` errors

#### Additional Security Features
- SQS encryption enabled (SQS-managed SSE)
- SNS can only write to the specified SQS queue (restricted by ARN condition)
- All policies follow principle of least privilege

### Long Polling
The main queue uses long polling (20 seconds) for efficient message retrieval and cost reduction.

### Dead Letter Queue
After 3 failed processing attempts, messages are automatically moved to DLQ for further analysis.

## PhoenixKit Integration

This script is designed to work seamlessly with PhoenixKit, an Elixir/Phoenix framework extension. Here's how to integrate the AWS infrastructure with your Phoenix application.

### Step 1: Configure Environment Variables

Create or update your `.env` file with AWS credentials:

```bash
# .env file
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_REGION=eu-north-1

# Optional: Email sender settings
FROM_EMAIL=hello@yourdomain.com
FROM_NAME=YourApp
```

**Security Note**: Never commit `.env` files to version control. Add `.env` to your `.gitignore`.

### Step 2: Configure config.exs

Update your `config/config.exs` with PhoenixKit settings:

```elixir
# config/config.exs
import Config

# Configure Swoosh API client
config :swoosh, api_client: Swoosh.ApiClient.Finch

# Configure PhoenixKit
config :phoenix_kit,
  repo: YourApp.Repo,
  mailer: YourApp.Mailer,
  layouts_module: YourAppWeb.Layouts,
  phoenix_version_strategy: :modern,
  from_email: "hello@yourdomain.com",
  from_name: "YourApp"

# Configure your application
config :your_app,
  ecto_repos: [YourApp.Repo]

# Configure the mailer for development (uses local adapter)
config :your_app, YourApp.Mailer,
  adapter: Swoosh.Adapters.Local
```

### Step 3: Configure runtime.exs

Update your `config/runtime.exs` to use AWS SES in production:

```elixir
# config/runtime.exs
import Config
import Dotenvy

# Load environment variables
source!([".env", ".env.#{config_env()}", System.get_env()])

# Helper function to get environment variables
env! = fn key, type, default \\ nil ->
  case env!(key, type) do
    nil -> default
    value -> value
  end
end

if config_env() == :dev do
  # Development: optionally use AWS SES if credentials provided
  if env!("AWS_ACCESS_KEY_ID", :string) &&
     env!("AWS_SECRET_ACCESS_KEY", :string) do
    config :your_app, YourApp.Mailer,
      adapter: Swoosh.Adapters.AmazonSES,
      access_key: env!("AWS_ACCESS_KEY_ID", :string!),
      secret: env!("AWS_SECRET_ACCESS_KEY", :string!),
      region: env!("AWS_REGION", :string, "eu-north-1")
  end

  # Configure PhoenixKit email settings
  config :phoenix_kit,
    from_email: env!("FROM_EMAIL", :string, "noreply@localhost"),
    from_name: env!("FROM_NAME", :string, "YourApp Dev")
end

if config_env() == :prod do
  # Production: use AWS SES
  config :your_app, YourApp.Mailer,
    adapter: Swoosh.Adapters.AmazonSES,
    access_key: env!("AWS_ACCESS_KEY_ID", :string!),
    secret: env!("AWS_SECRET_ACCESS_KEY", :string!),
    region: env!("AWS_REGION", :string, "eu-north-1")

  # Configure PhoenixKit email settings
  config :phoenix_kit,
    from_email: env!("FROM_EMAIL", :string, "hello@yourdomain.com"),
    from_name: env!("FROM_NAME", :string, "YourApp")
end
```

### Step 4: PhoenixKit Configuration in Admin Panel

After running the setup script, you'll receive configuration values. Enter them in your PhoenixKit admin panel:

1. Navigate to `/admin/settings/email` (or your PhoenixKit configuration page)
2. Fill in the form with values from the script output:

```
AWS Region:                    eu-north-1
SES Configuration Set:         myapp-emailing
SQS Polling Interval:          5000
SNS Topic ARN:                 arn:aws:sns:...
SQS Queue URL:                 https://sqs.eu-north-1...
SQS Queue ARN:                 arn:aws:sqs:...
SQS Dead Letter Queue URL:     https://sqs.eu-north-1...
```

### Step 5: Email Tracking with PhoenixKit

PhoenixKit automatically tracks email events from SQS. The email tracker runs as a background process.

#### Mix Tasks for Email Management

```bash
# Sync email statuses from SQS (manual trigger)
mix phoenix_kit.sync_email_status

# Process Dead Letter Queue messages
mix phoenix_kit.email.process_dlq

# Peek at DLQ messages without processing
mix phoenix_kit.email.process_dlq --peek

# Debug SQS queue status
mix phoenix_kit.email.debug_sqs
```

#### How Email Tracking Works

1. Your app sends an email via `YourApp.Mailer.deliver(email)`
2. Email is sent through AWS SES with configuration set `myapp-emailing`
3. SES generates events (send, delivery, bounce, open, click, etc.)
4. Events flow: SES → SNS → SQS
5. PhoenixKit polls SQS queue every 5 seconds (configurable)
6. Email statuses are updated in your database automatically

#### Email Event Types Tracked

- `send` - Email accepted by SES
- `delivery` - Email delivered to recipient
- `bounce` - Email bounced (permanent or temporary)
- `complaint` - Recipient marked as spam
- `open` - Recipient opened the email
- `click` - Recipient clicked a link
- `reject` - SES rejected the email
- `renderingFailure` - Template rendering failed

### Step 6: Testing the Integration

#### Send a test email:

```elixir
# In IEx console
iex> alias YourApp.Mailer
iex> import Swoosh.Email

iex> email = new()
...> |> to("recipient@example.com")
...> |> from({"YourApp", "hello@yourdomain.com"})
...> |> subject("Test Email")
...> |> text_body("This is a test email from AWS SES")

iex> Mailer.deliver(email)
{:ok, %{id: "..."}}
```

#### Check SQS queue for events:

```bash
# Check message count
aws sqs get-queue-attributes \
  --queue-url "YOUR_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region eu-north-1

# Manually receive messages to see events
aws sqs receive-message \
  --queue-url "YOUR_QUEUE_URL" \
  --max-number-of-messages 1 \
  --region eu-north-1
```

#### Monitor email tracker logs:

```bash
# If using Supervisor (production)
tail -f /var/log/supervisor/elixir.log | grep "email"

# Development logs
tail -f log/dev.log | grep "email"
```

### Step 7: Handling Failed Messages (DLQ)

Messages end up in the Dead Letter Queue after 3 failed processing attempts. This usually indicates:

- Malformed SES event JSON
- Database errors during status update
- Application errors in email tracking code

#### Investigate DLQ messages:

```bash
# View DLQ messages
mix phoenix_kit.email.process_dlq --peek

# Process and retry DLQ messages
mix phoenix_kit.email.process_dlq

# Manually inspect via AWS CLI
aws sqs receive-message \
  --queue-url "YOUR_DLQ_URL" \
  --max-number-of-messages 10 \
  --region eu-north-1
```

#### Clear DLQ after investigation:

```bash
# Purge all messages from DLQ
aws sqs purge-queue \
  --queue-url "YOUR_DLQ_URL" \
  --region eu-north-1
```

### Common Integration Issues

#### Issue: Emails send but events not appearing in database
**Causes:**
- SQS polling not running
- Configuration Set not attached to emails
- Wrong SQS queue URL in config

**Solutions:**
```bash
# Check if PhoenixKit email tracker is running
ps aux | grep "phoenix_kit"

# Manually trigger sync
mix phoenix_kit.sync_email_status

# Verify SES configuration set
aws ses describe-configuration-set \
  --configuration-set-name myapp-emailing \
  --region eu-north-1
```

#### Issue: All messages going to DLQ
**Causes:**
- Database migration not run
- Email tracking schema mismatch
- Application code errors

**Solutions:**
```bash
# Check application logs for errors
tail -f log/prod.log

# Run migrations
mix ecto.migrate

# Check DLQ message format
mix phoenix_kit.email.process_dlq --peek
```

#### Issue: Swoosh not using configuration set
**Solution:** PhoenixKit automatically adds the configuration set. Verify it's configured:

```elixir
# In your mailer or email tracking configuration
config :phoenix_kit,
  ses_configuration_set: "myapp-emailing"
```

### Production Deployment Checklist

- [ ] `.env` file configured with AWS credentials
- [ ] `config.exs` updated with from_email and from_name
- [ ] `runtime.exs` configured for production with AWS SES
- [ ] PhoenixKit admin panel configured with SQS/SNS ARNs
- [ ] SES domain/email verified (check "SES Identity Verification" section)
- [ ] SES account in production mode (not sandbox)
- [ ] Test email sent and delivered successfully
- [ ] SQS queue receiving events (check queue message count)
- [ ] Email statuses updating in database
- [ ] DLQ monitored and empty (or low message count)
- [ ] Application logs show no SQS/SES errors

## Troubleshooting

### Common Issues and Solutions

#### Issue: "jq: command not found"
**Solution**: Install jq
```bash
# Ubuntu/Debian
apt-get install jq

# macOS
brew install jq
```

#### Issue: "AWS CLI not configured"
**Solution**: Configure AWS credentials
```bash
aws configure
```

#### Issue: "Access Denied" errors
**Solution**: Ensure your IAM user/role has permissions for:
- SNS: CreateTopic, Subscribe, SetTopicAttributes
- SQS: CreateQueue, SetQueueAttributes, GetQueueUrl
- STS: GetCallerIdentity

#### Issue: Script creates resources but they don't appear in AWS Console
**Solution**: Check you're viewing the correct region in AWS Console (match script's AWS_REGION)

#### Issue: `[warning] Failed to delete SQS message` in application logs
**Symptoms:**
- Application logs show warnings about failed message deletions
- Messages appear in "ApproximateNumberOfMessagesNotVisible" and return to queue after visibility timeout
- Same messages are processed multiple times

**Cause**:
SQS Queue Policy is missing permissions for account to delete messages. The policy only allows SNS to send messages, but not your IAM users/roles to manage them.

**Solution**:
Update the SQS Queue Policy to include account access. The script automatically does this, but if you created queues manually, add this statement:

```json
{
  "Sid": "AllowAccountAccess",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{YOUR_ACCOUNT_ID}:root"
  },
  "Action": [
    "SQS:ReceiveMessage",
    "SQS:DeleteMessage",
    "SQS:GetQueueAttributes",
    "SQS:SendMessage"
  ],
  "Resource": "arn:aws:sqs:{REGION}:{ACCOUNT_ID}:{QUEUE_NAME}"
}
```

**To verify the issue:**
```bash
# Check for stuck messages
aws sqs get-queue-attributes \
  --queue-url "YOUR_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
  --region YOUR_REGION

# If "ApproximateNumberOfMessagesNotVisible" is > 0 and keeps growing, you have this issue
```

**To fix existing queue:**
Re-run the setup script (it's idempotent) or manually update the policy using AWS Console or CLI.

#### Issue: SES events not appearing in SQS
**Cause**: SES Configuration Set not configured or not attached to emails

**Solution**:
1. Verify Configuration Set exists: `aws ses list-configuration-sets --region YOUR_REGION`
2. Check event destinations are configured (the script does this automatically)
3. Ensure your application uses the Configuration Set when sending emails
4. For Swoosh adapter, this is automatic if configured correctly

## Monitoring and Maintenance

Regular monitoring ensures your email infrastructure is healthy and helps catch issues early.

### Daily/Weekly Monitoring

#### 1. Check Queue Message Counts

Monitor your SQS queues for message buildup:

```bash
# Check main queue
aws sqs get-queue-attributes \
  --queue-url "YOUR_MAIN_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
  --region YOUR_REGION | jq '.Attributes'

# Check DLQ (should be 0 or very low)
aws sqs get-queue-attributes \
  --queue-url "YOUR_DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region YOUR_REGION | jq '.Attributes'
```

**What to look for:**
- Main queue: Should process messages quickly (< 100 messages normally)
- DLQ: Should be 0 or very low (< 10 messages)
- Messages not visible: Indicates messages being processed

**Red flags:**
- ⚠️ Main queue growing steadily → Processing not keeping up
- 🚨 DLQ has messages → Application errors need investigation
- ⚠️ Messages not visible stays high → Visibility timeout too short or processing too slow

#### 2. Check SES Sending Statistics

```bash
# Get recent sending stats
aws ses get-send-statistics --region YOUR_REGION | jq '.SendDataPoints[-5:]'

# Get account status and quota
aws sesv2 get-account --region YOUR_REGION | jq '{
  SendQuota: .SendQuota,
  ProductionAccess: .ProductionAccessEnabled,
  EnforcementStatus: .EnforcementStatus
}'
```

**What to monitor:**
- Bounces: Should be < 5% of sends
- Complaints: Should be < 0.1% of sends
- Rejects: Should be 0 or very low
- Quota usage: Should stay below 80% of daily limit

**Red flags:**
- 🚨 Bounce rate > 5% → Email list quality issue
- 🚨 Complaint rate > 0.1% → Spam complaints (can disable account)
- ⚠️ Near quota limit → May need quota increase

#### 3. Monitor Application Logs

```bash
# Production (Supervisor)
tail -f /var/log/supervisor/elixir.log | grep -i "email\|sqs\|ses"

# Development
tail -f log/dev.log | grep -i "email\|sqs\|ses"

# Look for errors
grep -i "error\|warning\|failed" /var/log/supervisor/elixir.log | grep -i "email\|sqs"
```

**What to look for:**
- Successful email sends
- SQS message processing
- Email status updates

**Red flags:**
- 🚨 "Failed to delete SQS message" warnings
- 🚨 "MessageRejected" errors from SES
- 🚨 Database errors during email tracking

### Handling Dead Letter Queue Messages

When messages appear in DLQ, investigate immediately:

#### Step 1: View DLQ Messages

```bash
# Using PhoenixKit
mix phoenix_kit.email.process_dlq --peek

# Or manually with AWS CLI
aws sqs receive-message \
  --queue-url "YOUR_DLQ_URL" \
  --max-number-of-messages 10 \
  --region YOUR_REGION
```

#### Step 2: Identify the Problem

Common causes:
- **Malformed JSON**: SES sent unexpected event format
- **Database errors**: Migration missing or schema mismatch
- **Application errors**: Bug in email tracking code
- **Network issues**: Temporary connectivity problems

#### Step 3: Fix and Retry

```bash
# After fixing the underlying issue, retry DLQ messages
mix phoenix_kit.email.process_dlq

# If messages are permanently bad, purge them
aws sqs purge-queue --queue-url "YOUR_DLQ_URL" --region YOUR_REGION
```

### Maintenance Tasks

#### Monthly: Review SES Reputation Metrics

```bash
# Check reputation dashboard
aws sesv2 get-account --region YOUR_REGION | jq '.EnforcementStatus'

# List suppression list (bounced/complained emails)
aws sesv2 list-suppressed-destinations --region YOUR_REGION
```

**Actions:**
- Review bounced emails and remove from mailing list
- Investigate spam complaints
- Clean up suppression list if needed

#### Monthly: Audit Queue Policies

```bash
# Review main queue policy
aws sqs get-queue-attributes \
  --queue-url "YOUR_MAIN_QUEUE_URL" \
  --attribute-names Policy \
  --region YOUR_REGION | jq -r '.Attributes.Policy' | jq

# Verify both SNS and account access statements exist
```

#### Quarterly: Review AWS Costs

```bash
# SES costs
aws ce get-cost-and-usage \
  --time-period Start=2025-01-01,End=2025-03-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --filter file://<(echo '{
    "Dimensions": {
      "Key": "SERVICE",
      "Values": ["Amazon Simple Email Service"]
    }
  }') \
  --region us-east-1

# Similar for SQS and SNS
```

**Expected costs:**
- SES: $0-10/month for small volumes (< 10,000 emails)
- SQS: $0 (free tier covers most usage)
- SNS: $0 (free tier covers most usage)

### Setting Up CloudWatch Alarms

Create alarms for proactive monitoring:

#### Alarm 1: DLQ Messages > 10

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "email-dlq-messages-high" \
  --alarm-description "Alert when DLQ has > 10 messages" \
  --metric-name ApproximateNumberOfMessagesVisible \
  --namespace AWS/SQS \
  --statistic Average \
  --period 300 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --datapoints-to-alarm 1 \
  --evaluation-periods 1 \
  --dimensions Name=QueueName,Value=YOUR_DLQ_NAME \
  --alarm-actions "arn:aws:sns:YOUR_REGION:YOUR_ACCOUNT:YOUR_ALERT_TOPIC" \
  --region YOUR_REGION
```

#### Alarm 2: High Bounce Rate

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "ses-high-bounce-rate" \
  --alarm-description "Alert when bounce rate > 5%" \
  --metric-name Reputation.BounceRate \
  --namespace AWS/SES \
  --statistic Average \
  --period 3600 \
  --threshold 0.05 \
  --comparison-operator GreaterThanThreshold \
  --datapoints-to-alarm 1 \
  --evaluation-periods 1 \
  --alarm-actions "arn:aws:sns:YOUR_REGION:YOUR_ACCOUNT:YOUR_ALERT_TOPIC" \
  --region YOUR_REGION
```

### Backup and Disaster Recovery

#### Backing Up Configuration

```bash
# Export all infrastructure details
cat > aws-email-backup-$(date +%Y%m%d).json <<EOF
{
  "sns_topic": "$(aws sns list-topics --region YOUR_REGION | jq -r '.Topics[0].TopicArn')",
  "sqs_main_queue": "$(aws sqs get-queue-url --queue-name myapp-email-queue --region YOUR_REGION | jq -r '.QueueUrl')",
  "sqs_dlq": "$(aws sqs get-queue-url --queue-name myapp-email-dlq --region YOUR_REGION | jq -r '.QueueUrl')",
  "ses_config_set": "myapp-emailing",
  "verified_identities": $(aws ses list-identities --region YOUR_REGION)
}
EOF
```

#### Disaster Recovery Steps

If infrastructure is accidentally deleted:

1. **Re-run setup script**: The script is idempotent
   ```bash
   bash scripts/setup_aws_email_infrastructure.sh
   ```

2. **Update application config**: If ARNs/URLs changed
3. **Verify SES identities**: May need to re-verify domains
4. **Test email flow**: Send test email and check SQS

### Health Check Script

Create a simple health check script:

```bash
#!/bin/bash
# health-check-email-infra.sh

REGION="eu-north-1"
MAIN_QUEUE_URL="YOUR_MAIN_QUEUE_URL"
DLQ_URL="YOUR_DLQ_URL"

echo "🔍 Email Infrastructure Health Check"
echo "===================================="

# Check main queue
MAIN_COUNT=$(aws sqs get-queue-attributes \
  --queue-url "$MAIN_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region "$REGION" | jq -r '.Attributes.ApproximateNumberOfMessages')

echo "📬 Main Queue Messages: $MAIN_COUNT"
[ "$MAIN_COUNT" -gt 100 ] && echo "⚠️  WARNING: High message count in main queue!"

# Check DLQ
DLQ_COUNT=$(aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region "$REGION" | jq -r '.Attributes.ApproximateNumberOfMessages')

echo "💀 DLQ Messages: $DLQ_COUNT"
[ "$DLQ_COUNT" -gt 0 ] && echo "🚨 ERROR: Messages in DLQ require investigation!"

# Check SES status
PRODUCTION=$(aws sesv2 get-account --region "$REGION" | jq -r '.ProductionAccessEnabled')
echo "📧 SES Production Mode: $PRODUCTION"
[ "$PRODUCTION" != "true" ] && echo "⚠️  WARNING: SES still in sandbox mode!"

# Check sending quota
SENT_24H=$(aws sesv2 get-account --region "$REGION" | jq -r '.SendQuota.SentLast24Hours')
MAX_24H=$(aws sesv2 get-account --region "$REGION" | jq -r '.SendQuota.Max24HourSend')
USAGE_PCT=$(echo "scale=2; $SENT_24H / $MAX_24H * 100" | bc)

echo "📊 Quota Usage: $SENT_24H / $MAX_24H ($USAGE_PCT%)"
[ $(echo "$USAGE_PCT > 80" | bc) -eq 1 ] && echo "⚠️  WARNING: Near quota limit!"

echo ""
echo "✅ Health check complete"
```

Run it regularly:
```bash
chmod +x health-check-email-infra.sh
./health-check-email-infra.sh

# Or add to cron for daily checks
0 9 * * * /path/to/health-check-email-infra.sh >> /var/log/email-health.log 2>&1
```

## Deleting Infrastructure

If you need to delete the created infrastructure:

```bash
# Delete SNS subscription
aws sns list-subscriptions-by-topic \
  --topic-arn "arn:aws:sns:eu-north-1:123456789012:myapp-email-events"
# Copy the SubscriptionArn and execute:
aws sns unsubscribe --subscription-arn "SUBSCRIPTION_ARN"

# Delete SNS topic
aws sns delete-topic \
  --topic-arn "arn:aws:sns:eu-north-1:123456789012:myapp-email-events"

# Delete queues
aws sqs delete-queue \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-queue"

aws sqs delete-queue \
  --queue-url "https://sqs.eu-north-1.amazonaws.com/123456789012/myapp-email-dlq"
```

## Requirements

- AWS CLI version 2.x
- `jq` for JSON processing
- Permissions to create SNS and SQS resources in AWS account

## Script Improvements from Testing

The script has been tested in production and includes these improvements:

1. **Dependency Checks**: Validates AWS CLI and jq are installed before execution
2. **Improved JSON Handling**: Proper escaping for policy documents
3. **Error Handling**: Graceful handling of existing resources (idempotency)
4. **Compact JSON**: Uses `jq -c` for policy compression
5. **Detailed Output**: Step-by-step progress with clear success indicators

## Support

If you encounter errors:

1. Check AWS credentials: `aws sts get-caller-identity`
2. Verify IAM user permissions
3. Ensure the region is available
4. Check AWS account limits for SQS/SNS resources

## Files

- `scripts/setup_aws_email_infrastructure.sh` - main installation script
- `aws-email-config-{PROJECT_NAME}.txt` - saved configuration (created automatically)
- `scripts/AWS_SETUP_README.md` - this documentation file

## Production-Tested Configuration

The script has been successfully tested with the following configuration:

- **Project**: beamlab
- **Region**: eu-north-1
- **Account**: 123456789012 (example)
- **Resources Created**:
  - SNS Topic: `beamlab-email-events`
  - Main Queue: `beamlab-email-queue`
  - DLQ: `beamlab-email-dlq`
- **Test Results**: ✅ SNS → SQS message flow verified and working
- **Status**: Ready for production use

## License

This script is provided as-is for use with AWS services. Ensure you understand AWS pricing for SNS and SQS services before using in production.
