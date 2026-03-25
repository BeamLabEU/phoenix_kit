#!/bin/bash
#
# TEST AWS Email Infrastructure Setup Script
# ==========================================
#
# This is a TEST version for validating AWS SES event type configuration.
# Uses demo names with timestamps to avoid conflicts.
#
# Testing: All 10 AWS SES event types in UPPERCASE format
#

set -e  # Exit on any error

# ============================================================================
# TEST CONFIGURATION - Uses demo names with timestamp
# ============================================================================

# Generate unique timestamp for test resources
TIMESTAMP=$(date +%s)

# Project/Application name (demo prefix for testing)
PROJECT_NAME="demo-test-${TIMESTAMP}"

# AWS Region
AWS_REGION="eu-north-1"

# Queue names
MAIN_QUEUE_NAME="${PROJECT_NAME}-queue"
DLQ_NAME="${PROJECT_NAME}-dlq"

# SNS Topic name
SNS_TOPIC_NAME="${PROJECT_NAME}-sns"

# SES Configuration Set name
SES_CONFIG_SET_NAME="${PROJECT_NAME}-config"

# Queue configurations (shorter times for testing)
MAIN_QUEUE_VISIBILITY_TIMEOUT=300        # 5 minutes (test)
MAIN_QUEUE_MESSAGE_RETENTION=345600      # 4 days (test)
MAIN_QUEUE_MAX_RECEIVE_COUNT=3
MAIN_QUEUE_RECEIVE_WAIT_TIME=20

DLQ_VISIBILITY_TIMEOUT=60
DLQ_MESSAGE_RETENTION=345600             # 4 days (test)

SQS_POLLING_INTERVAL=5000

# ============================================================================
# SCRIPT EXECUTION
# ============================================================================

echo "=============================================="
echo "TEST AWS Email Infrastructure Setup"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Project: $PROJECT_NAME"
echo "  Region: $AWS_REGION"
echo "  Main Queue: $MAIN_QUEUE_NAME"
echo "  DLQ: $DLQ_NAME"
echo "  SNS Topic: $SNS_TOPIC_NAME"
echo "  Config Set: $SES_CONFIG_SET_NAME"
echo ""
echo "Starting TEST setup..."
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
  --query 'QueueUrl')

DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${DLQ_NAME}"
echo "  ✓ DLQ Created"
echo "    URL: $DLQ_URL"
echo "    ARN: $DLQ_ARN"
echo ""

# Set DLQ policy
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
  --query 'TopicArn')

echo "  ✓ SNS Topic Created"
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

REDRIVE_POLICY_ESCAPED=$(echo "$REDRIVE_POLICY" | jq -c . | sed 's/"/\\"/g')
MAIN_QUEUE_URL=$(aws sqs create-queue \
  --queue-name "$MAIN_QUEUE_NAME" \
  --attributes '{"VisibilityTimeout":"'"$MAIN_QUEUE_VISIBILITY_TIMEOUT"'","MessageRetentionPeriod":"'"$MAIN_QUEUE_MESSAGE_RETENTION"'","ReceiveMessageWaitTimeSeconds":"'"$MAIN_QUEUE_RECEIVE_WAIT_TIME"'","RedrivePolicy":"'"$REDRIVE_POLICY_ESCAPED"'","SqsManagedSseEnabled":"true"}' \
  --region "$AWS_REGION" \
  --output text \
  --query 'QueueUrl')

MAIN_QUEUE_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${MAIN_QUEUE_NAME}"
echo "  ✓ Main Queue Created"
echo "    URL: $MAIN_QUEUE_URL"
echo "    ARN: $MAIN_QUEUE_ARN"
echo ""

# Set Main Queue policy
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
  --query 'SubscriptionArn')

echo "  ✓ SNS → SQS Subscription created"
echo "    Subscription ARN: $SUBSCRIPTION_ARN"
echo ""

# Create SES Configuration Set using v2 API
echo "[8/9] Creating SES Configuration Set (v2 API)..."
aws sesv2 create-configuration-set \
  --configuration-set-name "$SES_CONFIG_SET_NAME" \
  --region "$AWS_REGION"

echo "  ✓ SES Configuration Set created"
echo "    Name: $SES_CONFIG_SET_NAME"
echo ""

# Add SNS Event Destination with ALL 10 event types in UPPERCASE using v2 API
echo "[9/9] Configuring SES event tracking to SNS (v2 API with 10 event types)..."
echo "  >> Adding ALL 10 AWS SES event types in UPPERCASE format"
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
  --region "$AWS_REGION"

echo "  ✓ SES Event Tracking configured (SES v2 API)"
echo "    Events (10 types): SEND, REJECT, BOUNCE, COMPLAINT, DELIVERY, OPEN, CLICK, RENDERING_FAILURE, DELIVERY_DELAY, SUBSCRIPTION"
echo "    Destination: SNS → SQS"
echo ""

# ============================================================================
# OUTPUT TEST CONFIGURATION
# ============================================================================

echo "=============================================="
echo "✓ TEST Setup Complete!"
echo "=============================================="
echo ""
echo "Test Resources Created:"
echo "  SNS Topic ARN: $SNS_TOPIC_ARN"
echo "  SQS Queue URL: $MAIN_QUEUE_URL"
echo "  SQS Queue ARN: $MAIN_QUEUE_ARN"
echo "  SQS DLQ URL: $DLQ_URL"
echo "  Config Set: $SES_CONFIG_SET_NAME"
echo ""
echo "Next Steps:"
echo "1. Verify resources with AWS CLI commands"
echo "2. Send test email"
echo "3. Check SQS for events"
echo "4. Clean up resources when done"
echo ""

# Save test configuration
TEST_CONFIG_FILE="/tmp/test-aws-config-${TIMESTAMP}.txt"
cat > "$TEST_CONFIG_FILE" <<EOF
TEST AWS Email Infrastructure Configuration
Generated: $(date)
Timestamp: $TIMESTAMP

Project: $PROJECT_NAME
Region: $AWS_REGION
Account ID: $ACCOUNT_ID

Test Resources:
===============

SNS Topic:
  Name: $SNS_TOPIC_NAME
  ARN: $SNS_TOPIC_ARN

Main Queue:
  Name: $MAIN_QUEUE_NAME
  URL: $MAIN_QUEUE_URL
  ARN: $MAIN_QUEUE_ARN

Dead Letter Queue:
  Name: $DLQ_NAME
  URL: $DLQ_URL
  ARN: $DLQ_ARN

SES Configuration Set: $SES_CONFIG_SET_NAME

Event Types Configured (10 types):
  SEND, REJECT, BOUNCE, COMPLAINT, DELIVERY, OPEN, CLICK,
  RENDERING_FAILURE, DELIVERY_DELAY, SUBSCRIPTION

Cleanup Commands:
=================

# 1. Delete Configuration Set (removes Event Destination)
aws sesv2 delete-configuration-set --configuration-set-name "$SES_CONFIG_SET_NAME" --region "$AWS_REGION"

# 2. Unsubscribe SNS
aws sns unsubscribe --subscription-arn "$SUBSCRIPTION_ARN" --region "$AWS_REGION"

# 3. Delete SQS Queue
aws sqs delete-queue --queue-url "$MAIN_QUEUE_URL" --region "$AWS_REGION"

# 4. Delete DLQ
aws sqs delete-queue --queue-url "$DLQ_URL" --region "$AWS_REGION"

# 5. Delete SNS Topic
aws sns delete-topic --topic-arn "$SNS_TOPIC_ARN" --region "$AWS_REGION"

Verification Commands:
======================

# Check Event Destination configuration
aws sesv2 get-configuration-set-event-destinations --configuration-set-name "$SES_CONFIG_SET_NAME" --region "$AWS_REGION" --output json | jq '.EventDestinations[].EventTypes'

# Send test email
aws sesv2 send-email --from-email-address "marketing@hydroforce.ee" --destination "ToAddresses=admin@hydroforce.ee" --content "Simple={Subject={Data='Test 10 Events',Charset=utf8},Body={Text={Data='Testing all event types',Charset=utf8}}}" --configuration-set-name "$SES_CONFIG_SET_NAME" --region "$AWS_REGION"

# Check for messages in SQS
aws sqs receive-message --queue-url "$MAIN_QUEUE_URL" --max-number-of-messages 10 --wait-time-seconds 20 --region "$AWS_REGION" --output json

# Count messages in queue
aws sqs get-queue-attributes --queue-url "$MAIN_QUEUE_URL" --attribute-names ApproximateNumberOfMessages --region "$AWS_REGION"
EOF

echo "Test configuration saved to: $TEST_CONFIG_FILE"
echo ""
echo "Run verification:"
echo "  cat $TEST_CONFIG_FILE"
echo ""
