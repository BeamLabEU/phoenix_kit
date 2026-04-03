#!/bin/bash
#
# AWS Email Infrastructure Setup Script
# ======================================
#
# This script creates the complete AWS infrastructure for email event handling:
# - SNS Topic for email events
# - SQS Dead Letter Queue (DLQ) for failed messages
# - SQS Main Queue with DLQ redrive policy
# - SNS to SQS subscription
# - All necessary IAM policies
#
# Usage:
#   1. Configure the variables in the CONFIGURATION section below
#   2. Ensure AWS CLI is configured with proper credentials
#   3. Run: bash scripts/setup_aws_email_infrastructure.sh
#

set -e  # Exit on any error

# ============================================================================
# CONFIGURATION - EDIT THESE VALUES
# ============================================================================

# Project/Application name (used as prefix for resource names)
PROJECT_NAME="myapp"

# AWS Region
AWS_REGION="eu-north-1"

# Queue names (without URLs - will be generated)
MAIN_QUEUE_NAME="${PROJECT_NAME}-email-queue"
DLQ_NAME="${PROJECT_NAME}-email-dlq"

# SNS Topic name
SNS_TOPIC_NAME="${PROJECT_NAME}-email-events"

# SES Configuration Set name (for SES integration)
SES_CONFIG_SET_NAME="${PROJECT_NAME}-emailing"

# Queue configurations
# Main Queue settings optimized for email event processing
MAIN_QUEUE_VISIBILITY_TIMEOUT=600        # 10 minutes (allows complex DB operations)
MAIN_QUEUE_MESSAGE_RETENTION=1209600     # 14 days (protects against extended outages)
MAIN_QUEUE_MAX_RECEIVE_COUNT=3           # Retries before sending to DLQ
MAIN_QUEUE_RECEIVE_WAIT_TIME=20          # Long polling time (reduces API calls)

# Dead Letter Queue settings for failed messages
DLQ_VISIBILITY_TIMEOUT=60                # 1 minute (manual processing)
DLQ_MESSAGE_RETENTION=1209600            # 14 days (allows troubleshooting)

# SQS Polling interval for your application (in milliseconds)
SQS_POLLING_INTERVAL=5000                # 5 seconds

# ============================================================================
# SCRIPT EXECUTION - DO NOT EDIT BELOW THIS LINE
# ============================================================================

# Check dependencies
echo "Checking dependencies..."
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install it first."
    exit 1
fi

echo "✓ All dependencies found"
echo ""

echo "=============================================="
echo "AWS Email Infrastructure Setup"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Project: $PROJECT_NAME"
echo "  Region: $AWS_REGION"
echo "  Main Queue: $MAIN_QUEUE_NAME"
echo "  DLQ: $DLQ_NAME"
echo "  SNS Topic: $SNS_TOPIC_NAME"
echo ""
echo "Queue Settings (Optimized for Email Events):"
echo "  Main Queue Retention: 14 days (protects against outages)"
echo "  Main Queue Visibility: 10 minutes (allows complex processing)"
echo "  DLQ Retention: 14 days (allows troubleshooting)"
echo ""
echo "Starting setup..."
echo ""

# Get AWS Account ID
echo "[1/9] Getting AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  ✓ Account ID: $ACCOUNT_ID"
echo ""

# Create Dead Letter Queue (DLQ)
echo "[2/9] Creating Dead Letter Queue..."
DLQ_URL=$(aws sqs create-queue \
  --queue-name "$DLQ_NAME" \
  --attributes "{
    \"VisibilityTimeout\": \"$DLQ_VISIBILITY_TIMEOUT\",
    \"MessageRetentionPeriod\": \"$DLQ_MESSAGE_RETENTION\",
    \"SqsManagedSseEnabled\": \"true\"
  }" \
  --region "$AWS_REGION" \
  --output text \
  --query 'QueueUrl' 2>/dev/null || \
  aws sqs get-queue-url --queue-name "$DLQ_NAME" --region "$AWS_REGION" --output text --query 'QueueUrl')

DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${DLQ_NAME}"
echo "  ✓ DLQ Created/Found"
echo "    URL: $DLQ_URL"
echo "    ARN: $DLQ_ARN"
echo ""

# Set DLQ policy to allow access from account
echo "[3/9] Setting DLQ policy..."
DLQ_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Id": "__default_policy_ID",
  "Statement": [
    {
      "Sid": "__owner_statement",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "SQS:*",
      "Resource": "${DLQ_ARN}"
    }
  ]
}
EOF
)

DLQ_POLICY_COMPACT=$(echo "$DLQ_POLICY" | jq -c .)
aws sqs set-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attributes "{\"Policy\":\"$(echo "$DLQ_POLICY_COMPACT" | sed 's/"/\\"/g')\"}" \
  --region "$AWS_REGION"

echo "  ✓ DLQ Policy set"
echo ""

# Create SNS Topic
echo "[4/9] Creating SNS Topic..."
SNS_TOPIC_ARN=$(aws sns create-topic \
  --name "$SNS_TOPIC_NAME" \
  --region "$AWS_REGION" \
  --output text \
  --query 'TopicArn' 2>/dev/null || \
  echo "arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}")

echo "  ✓ SNS Topic Created/Found"
echo "    ARN: $SNS_TOPIC_ARN"
echo ""

# Create Main Queue with Redrive Policy
echo "[5/9] Creating Main Queue with DLQ redrive policy..."
REDRIVE_POLICY=$(cat <<EOF
{
  "deadLetterTargetArn": "${DLQ_ARN}",
  "maxReceiveCount": ${MAIN_QUEUE_MAX_RECEIVE_COUNT}
}
EOF
)

REDRIVE_POLICY_COMPACT=$(echo "$REDRIVE_POLICY" | jq -c .)
MAIN_QUEUE_URL=$(aws sqs create-queue \
  --queue-name "$MAIN_QUEUE_NAME" \
  --attributes "{\"VisibilityTimeout\":\"$MAIN_QUEUE_VISIBILITY_TIMEOUT\",\"MessageRetentionPeriod\":\"$MAIN_QUEUE_MESSAGE_RETENTION\",\"ReceiveMessageWaitTimeSeconds\":\"$MAIN_QUEUE_RECEIVE_WAIT_TIME\",\"RedrivePolicy\":\"$(echo "$REDRIVE_POLICY_COMPACT" | sed 's/"/\\\\\\"/g')\",\"SqsManagedSseEnabled\":\"true\"}" \
  --region "$AWS_REGION" \
  --output text \
  --query 'QueueUrl' 2>/dev/null || \
  aws sqs get-queue-url --queue-name "$MAIN_QUEUE_NAME" --region "$AWS_REGION" --output text --query 'QueueUrl')

MAIN_QUEUE_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${MAIN_QUEUE_NAME}"
echo "  ✓ Main Queue Created/Found"
echo "    URL: $MAIN_QUEUE_URL"
echo "    ARN: $MAIN_QUEUE_ARN"
echo ""

# Set Main Queue policy to allow SNS to send messages and account to manage messages
echo "[6/9] Setting Main Queue policy to allow SNS and account access..."
MAIN_QUEUE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Id": "${PROJECT_NAME}-sqs-policy",
  "Statement": [
    {
      "Sid": "AllowSNSPublish",
      "Effect": "Allow",
      "Principal": {
        "Service": "sns.amazonaws.com"
      },
      "Action": "SQS:SendMessage",
      "Resource": "${MAIN_QUEUE_ARN}",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "${SNS_TOPIC_ARN}"
        }
      }
    },
    {
      "Sid": "AllowAccountAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": [
        "SQS:ReceiveMessage",
        "SQS:DeleteMessage",
        "SQS:GetQueueAttributes",
        "SQS:SendMessage"
      ],
      "Resource": "${MAIN_QUEUE_ARN}"
    }
  ]
}
EOF
)

MAIN_QUEUE_POLICY_COMPACT=$(echo "$MAIN_QUEUE_POLICY" | jq -c .)
aws sqs set-queue-attributes \
  --queue-url "$MAIN_QUEUE_URL" \
  --attributes "{\"Policy\":\"$(echo "$MAIN_QUEUE_POLICY_COMPACT" | sed 's/"/\\"/g')\"}" \
  --region "$AWS_REGION"

echo "  ✓ Main Queue Policy set"
echo ""

# Subscribe SQS to SNS
echo "[7/9] Creating SNS subscription to SQS..."
SUBSCRIPTION_ARN=$(aws sns subscribe \
  --topic-arn "$SNS_TOPIC_ARN" \
  --protocol sqs \
  --notification-endpoint "$MAIN_QUEUE_ARN" \
  --region "$AWS_REGION" \
  --output text \
  --query 'SubscriptionArn' 2>/dev/null || echo "Already subscribed")

echo "  ✓ SNS → SQS Subscription created"
if [ "$SUBSCRIPTION_ARN" != "Already subscribed" ]; then
  echo "    Subscription ARN: $SUBSCRIPTION_ARN"
fi
echo ""

# Create SES Configuration Set using v2 API
echo "[8/9] Creating SES Configuration Set (v2 API)..."
aws sesv2 create-configuration-set \
  --configuration-set-name "$SES_CONFIG_SET_NAME" \
  --region "$AWS_REGION" 2>/dev/null || echo "  (Configuration Set already exists)"

echo "  ✓ SES Configuration Set created/verified"
echo "    Name: $SES_CONFIG_SET_NAME"
echo ""

# Add SNS Event Destination to Configuration Set using v2 API with all 10 event types
echo "[9/9] Configuring SES event tracking to SNS (v2 API with 10 event types)..."
aws sesv2 create-configuration-set-event-destination \
  --configuration-set-name "$SES_CONFIG_SET_NAME" \
  --event-destination-name "sns-destination" \
  --event-destination "{
    \"Enabled\": true,
    \"MatchingEventTypes\": [\"SEND\", \"REJECT\", \"BOUNCE\", \"COMPLAINT\", \"DELIVERY\", \"OPEN\", \"CLICK\", \"RENDERING_FAILURE\", \"DELIVERY_DELAY\", \"SUBSCRIPTION\"],
    \"SnsDestination\": {
      \"TopicArn\": \"$SNS_TOPIC_ARN\"
    }
  }" \
  --region "$AWS_REGION" 2>/dev/null || echo "  (Event destination already exists)"

echo "  ✓ SES Event Tracking configured (SES v2 API)"
echo "    Events (10 types): SEND, REJECT, BOUNCE, COMPLAINT, DELIVERY, OPEN, CLICK, RENDERING_FAILURE, DELIVERY_DELAY, SUBSCRIPTION"
echo "    Destination: SNS → SQS"
echo ""

# ============================================================================
# OUTPUT CONFIGURATION FOR APPLICATION FORM
# ============================================================================

echo "=============================================="
echo "✓ Setup Complete!"
echo "=============================================="
echo ""
echo "Copy these values to your application configuration form:"
echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                    AWS Configuration Form                          ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo "AWS Access Key ID:"
echo "  [Use your AWS credentials]"
echo ""
echo "AWS Secret Access Key:"
echo "  [Use your AWS credentials]"
echo ""
echo "AWS Region:"
echo "  $AWS_REGION"
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo "Email Sender Settings"
echo "─────────────────────────────────────────────────────────────────────"
echo ""
echo "From Email:"
echo "  [e.g., hello@${PROJECT_NAME}.com]"
echo ""
echo "From Name:"
echo "  [e.g., ${PROJECT_NAME^}]"
echo ""
echo "NOTE: Configure these in your application's config.exs and runtime.exs"
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo "AWS SES & SQS Settings"
echo "─────────────────────────────────────────────────────────────────────"
echo ""
echo "SES Configuration Set:"
echo "  $SES_CONFIG_SET_NAME"
echo ""
echo "SQS Polling Interval:"
echo "  $SQS_POLLING_INTERVAL (ms)"
echo ""
echo "SNS Topic ARN:"
echo "  $SNS_TOPIC_ARN"
echo ""
echo "SQS Queue URL:"
echo "  $MAIN_QUEUE_URL"
echo ""
echo "SQS Queue ARN:"
echo "  $MAIN_QUEUE_ARN"
echo ""
echo "SQS Dead Letter Queue URL:"
echo "  $DLQ_URL"
echo ""
echo "SQS Dead Letter Queue ARN:"
echo "  $DLQ_ARN"
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo "Architecture Diagram"
echo "─────────────────────────────────────────────────────────────────────"
echo ""
echo "  SES Events → SNS ($SNS_TOPIC_NAME)"
echo "                 ↓"
echo "               SQS ($MAIN_QUEUE_NAME) → Your Application"
echo "                 ↓ (after $MAIN_QUEUE_MAX_RECEIVE_COUNT failed attempts)"
echo "               SQS DLQ ($DLQ_NAME)"
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo "Quick Verification Commands"
echo "─────────────────────────────────────────────────────────────────────"
echo ""
echo "# Check messages in main queue:"
echo "aws sqs get-queue-attributes \\"
echo "  --queue-url \"$MAIN_QUEUE_URL\" \\"
echo "  --attribute-names ApproximateNumberOfMessages"
echo ""
echo "# Check messages in DLQ:"
echo "aws sqs get-queue-attributes \\"
echo "  --queue-url \"$DLQ_URL\" \\"
echo "  --attribute-names ApproximateNumberOfMessages"
echo ""
echo "# Test SNS publish:"
echo "aws sns publish \\"
echo "  --topic-arn \"$SNS_TOPIC_ARN\" \\"
echo "  --message \"Test message\""
echo ""
echo "# Receive messages:"
echo "aws sqs receive-message \\"
echo "  --queue-url \"$MAIN_QUEUE_URL\" \\"
echo "  --max-number-of-messages 10"
echo ""
echo "=============================================="

# Save configuration to a file for reference
CONFIG_FILE="aws-email-config-${PROJECT_NAME}.txt"
cat > "$CONFIG_FILE" <<EOF
AWS Email Infrastructure Configuration
Generated: $(date)

Project: $PROJECT_NAME
Region: $AWS_REGION
Account ID: $ACCOUNT_ID

Resources Created:
==================

SNS Topic:
  Name: $SNS_TOPIC_NAME
  ARN: $SNS_TOPIC_ARN

Main Queue:
  Name: $MAIN_QUEUE_NAME
  URL: $MAIN_QUEUE_URL
  ARN: $MAIN_QUEUE_ARN
  Visibility Timeout: ${MAIN_QUEUE_VISIBILITY_TIMEOUT}s (10 minutes - allows complex processing)
  Message Retention: ${MAIN_QUEUE_MESSAGE_RETENTION}s ($(($MAIN_QUEUE_MESSAGE_RETENTION / 86400)) days - protects against outages)
  Max Receive Count: $MAIN_QUEUE_MAX_RECEIVE_COUNT (retries before DLQ)
  Long Polling: ${MAIN_QUEUE_RECEIVE_WAIT_TIME}s (reduces API costs)

Dead Letter Queue:
  Name: $DLQ_NAME
  URL: $DLQ_URL
  ARN: $DLQ_ARN
  Visibility Timeout: ${DLQ_VISIBILITY_TIMEOUT}s (1 minute - manual processing)
  Message Retention: ${DLQ_MESSAGE_RETENTION}s ($(($DLQ_MESSAGE_RETENTION / 86400)) days - allows troubleshooting)

SES Configuration Set: $SES_CONFIG_SET_NAME
SQS Polling Interval: ${SQS_POLLING_INTERVAL}ms

Application Form Values:
========================
AWS Region: $AWS_REGION
SES Configuration Set: $SES_CONFIG_SET_NAME
SQS Polling Interval: $SQS_POLLING_INTERVAL
SNS Topic ARN: $SNS_TOPIC_ARN
SQS Queue URL: $MAIN_QUEUE_URL
SQS Queue ARN: $MAIN_QUEUE_ARN
SQS Dead Letter Queue URL: $DLQ_URL
EOF

echo "Configuration saved to: $CONFIG_FILE"
echo ""
