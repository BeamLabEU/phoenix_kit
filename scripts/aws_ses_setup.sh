#!/bin/bash

# AWS SES Setup Script for PhoenixKit Email
# This script automates the setup of AWS SES Configuration Set, SNS Topic, and Event Destinations

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
CONFIGURATION_SET_NAME="${CONFIGURATION_SET_NAME:-phoenixkit-tracking}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-phoenixkit-email-events}"
EVENT_DESTINATION_NAME="${EVENT_DESTINATION_NAME:-phoenixkit-events}"
WEBHOOK_ENDPOINT="${WEBHOOK_ENDPOINT}"
AWS_REGION="${AWS_REGION:-eu-north-1}"

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first:"
        print_info "curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'"
        print_info "unzip awscliv2.zip && sudo ./aws/install"
        exit 1
    fi
}

# Function to verify AWS credentials
verify_aws_credentials() {
    print_info "Verifying AWS credentials..."
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured or invalid."
        print_info "Configure your credentials with: aws configure"
        print_info "Required permissions: SES, SNS, IAM (read/write)"
        exit 1
    fi
    
    local identity=$(aws sts get-caller-identity --query 'Arn' --output text)
    print_success "AWS credentials verified: $identity"
}

# Function to check webhook endpoint
check_webhook_endpoint() {
    if [[ -z "$WEBHOOK_ENDPOINT" ]]; then
        print_error "WEBHOOK_ENDPOINT environment variable is required"
        print_info "Set it with: export WEBHOOK_ENDPOINT=https://yourdomain.com{prefix}/webhooks/email"
        print_info "Note: Replace {prefix} with your configured PhoenixKit URL prefix (default: /phoenix_kit)"
        exit 1
    fi
    
    print_info "Webhook endpoint: $WEBHOOK_ENDPOINT"
    
    # Validate URL format
    if [[ ! "$WEBHOOK_ENDPOINT" =~ ^https?:// ]]; then
        print_error "Webhook endpoint must be a valid HTTPS URL"
        exit 1
    fi
}

# Function to create Configuration Set
create_configuration_set() {
    print_info "Creating Configuration Set: $CONFIGURATION_SET_NAME"
    
    # Check if Configuration Set already exists
    if aws sesv2 get-configuration-set --configuration-set-name "$CONFIGURATION_SET_NAME" &> /dev/null; then
        print_warning "Configuration Set '$CONFIGURATION_SET_NAME' already exists"
        return 0
    fi
    
    # Create Configuration Set
    aws sesv2 create-configuration-set \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --delivery-options tls-policy=Require \
        --reputation-options reputation-metrics-enabled=true \
        --tracking-options custom-redirect-domain="" \
        --region "$AWS_REGION"
    
    print_success "Configuration Set '$CONFIGURATION_SET_NAME' created successfully"
}

# Function to create SNS Topic
create_sns_topic() {
    print_info "Creating SNS Topic: $SNS_TOPIC_NAME"
    
    # Create SNS Topic
    local topic_arn=$(aws sns create-topic \
        --name "$SNS_TOPIC_NAME" \
        --region "$AWS_REGION" \
        --query 'TopicArn' \
        --output text)
    
    print_success "SNS Topic created: $topic_arn"
    echo "$topic_arn"
}

# Function to create SNS Subscription
create_sns_subscription() {
    local topic_arn="$1"
    
    print_info "Creating SNS Subscription to webhook endpoint"
    
    # Create HTTPS subscription
    local subscription_arn=$(aws sns subscribe \
        --topic-arn "$topic_arn" \
        --protocol https \
        --notification-endpoint "$WEBHOOK_ENDPOINT" \
        --region "$AWS_REGION" \
        --query 'SubscriptionArn' \
        --output text)
    
    # Set subscription attributes for raw message delivery
    if [[ "$subscription_arn" != "pending confirmation" ]]; then
        aws sns set-subscription-attributes \
            --subscription-arn "$subscription_arn" \
            --attribute-name RawMessageDelivery \
            --attribute-value true \
            --region "$AWS_REGION"
    fi
    
    print_success "SNS Subscription created: $subscription_arn"
    print_warning "Subscription confirmation will be sent to your webhook endpoint"
    print_info "PhoenixKit will automatically confirm the subscription"
}

# Function to create Event Destination
create_event_destination() {
    local topic_arn="$1"
    
    print_info "Creating Event Destination: $EVENT_DESTINATION_NAME"
    
    # Check if Event Destination already exists
    if aws sesv2 get-configuration-set-event-destinations \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --region "$AWS_REGION" 2>/dev/null | \
        grep -q "$EVENT_DESTINATION_NAME"; then
        print_warning "Event Destination '$EVENT_DESTINATION_NAME' already exists"
        return 0
    fi
    
    # Create Event Destination with all event types
    aws sesv2 create-configuration-set-event-destination \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --event-destination-name "$EVENT_DESTINATION_NAME" \
        --event-destination '{
            "Enabled": true,
            "MatchingEventTypes": [
                "send",
                "delivery",
                "bounce",
                "complaint",
                "open",
                "click"
            ],
            "SnsDestination": {
                "TopicArn": "'"$topic_arn"'"
            }
        }' \
        --region "$AWS_REGION"
    
    print_success "Event Destination '$EVENT_DESTINATION_NAME' created successfully"
}

# Function to set IAM policy for SNS Topic
set_sns_topic_policy() {
    local topic_arn="$1"
    
    print_info "Setting SNS Topic policy for SES access"
    
    # Get AWS account ID
    local account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    
    # Create policy document
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AllowSESToPublish",
                "Effect": "Allow",
                "Principal": {
                    "Service": "ses.amazonaws.com"
                },
                "Action": "sns:Publish",
                "Resource": "'"$topic_arn"'",
                "Condition": {
                    "StringEquals": {
                        "aws:SourceAccount": "'"$account_id"'"
                    }
                }
            }
        ]
    }'
    
    # Set topic policy
    aws sns set-topic-attributes \
        --topic-arn "$topic_arn" \
        --attribute-name Policy \
        --attribute-value "$policy_document" \
        --region "$AWS_REGION"
    
    print_success "SNS Topic policy updated for SES access"
}

# Function to test webhook endpoint
test_webhook_endpoint() {
    print_info "Testing webhook endpoint accessibility..."
    
    if command -v curl &> /dev/null; then
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_ENDPOINT" || echo "000")
        
        case $http_code in
            000)
                print_warning "Could not connect to webhook endpoint. Check if it's accessible from the internet."
                ;;
            200|201|204)
                print_success "Webhook endpoint is accessible (HTTP $http_code)"
                ;;
            4*|5*)
                print_warning "Webhook endpoint returned HTTP $http_code (this may be expected for unauthorized requests)"
                ;;
            *)
                print_info "Webhook endpoint returned HTTP $http_code"
                ;;
        esac
    else
        print_warning "curl not available, skipping webhook endpoint test"
    fi
}

# Function to display setup summary
display_summary() {
    echo
    print_success "=== AWS SES Setup Complete ==="
    echo
    print_info "Configuration Set: $CONFIGURATION_SET_NAME"
    print_info "SNS Topic: $SNS_TOPIC_NAME"
    print_info "Event Destination: $EVENT_DESTINATION_NAME"
    print_info "Webhook Endpoint: $WEBHOOK_ENDPOINT"
    print_info "AWS Region: $AWS_REGION"
    echo
    print_info "Next steps:"
    print_info "1. Configure PhoenixKit to use the Configuration Set:"
    print_info "   PhoenixKit.EmailTracking.set_ses_configuration_set(\"$CONFIGURATION_SET_NAME\")"
    print_info "2. Enable SES events in PhoenixKit:"
    print_info "   PhoenixKit.Settings.update_setting(\"email_tracking_ses_events\", \"true\")"
    print_info "3. Verify configuration:"
    print_info "   mix phoenix_kit.email.verify_config --detailed --check aws"
    print_info "4. Send test email and check for webhook events"
    echo
}

# Main execution
main() {
    echo "=== PhoenixKit AWS SES Setup Script ==="
    echo
    
    # Preliminary checks
    check_aws_cli
    verify_aws_credentials
    check_webhook_endpoint
    
    # Setup process
    create_configuration_set
    
    local topic_arn=$(create_sns_topic)
    
    create_sns_subscription "$topic_arn"
    
    set_sns_topic_policy "$topic_arn"
    
    create_event_destination "$topic_arn"
    
    test_webhook_endpoint
    
    display_summary
}

# Help function
show_help() {
    echo "PhoenixKit AWS SES Setup Script"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Environment Variables:"
    echo "  WEBHOOK_ENDPOINT          Required. Your webhook URL (https://yourdomain.com{prefix}/webhooks/email)"
    echo "  CONFIGURATION_SET_NAME    Optional. Configuration Set name (default: phoenixkit-tracking)"
    echo "  SNS_TOPIC_NAME           Optional. SNS Topic name (default: phoenixkit-email-events)"
    echo "  EVENT_DESTINATION_NAME   Optional. Event Destination name (default: phoenixkit-events)"
    echo "  AWS_REGION               Optional. AWS Region (default: eu-north-1)"
    echo
    echo "Example:"
    echo "  export WEBHOOK_ENDPOINT=https://myapp.com{prefix}/webhooks/email"
    echo "  export AWS_REGION=us-east-1"
    echo "  # Note: Replace {prefix} with your configured PhoenixKit URL prefix (default: /phoenix_kit)"
    echo "  $0"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
}

# Command line argument handling
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        main
        ;;
    *)
        print_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac