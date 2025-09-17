#!/bin/bash

# AWS SES Verification Script for PhoenixKit Email
# This script verifies the AWS SES configuration and troubleshoots common issues

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
CONFIGURATION_SET_NAME="${CONFIGURATION_SET_NAME:-phoenixkit-tracking}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-phoenixkit-email-events}"
AWS_REGION="${AWS_REGION:-eu-north-1}"
TEST_EMAIL="${TEST_EMAIL:-timujeen@gmail.com}"

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_header() { echo -e "${CYAN}=== $1 ===${NC}"; }

# Function to check AWS CLI installation and credentials
check_aws_prerequisites() {
    print_header "AWS Prerequisites"
    
    # Check AWS CLI
    if command -v aws &> /dev/null; then
        local aws_version=$(aws --version 2>&1 | cut -d' ' -f1)
        print_success "AWS CLI installed: $aws_version"
    else
        print_error "AWS CLI not installed"
        return 1
    fi
    
    # Check AWS credentials
    if aws sts get-caller-identity &> /dev/null; then
        local identity=$(aws sts get-caller-identity --query 'Arn' --output text)
        local account_id=$(aws sts get-caller-identity --query 'Account' --output text)
        print_success "AWS credentials valid: $identity"
        print_info "Account ID: $account_id"
        print_info "Region: $AWS_REGION"
    else
        print_error "AWS credentials invalid or not configured"
        return 1
    fi
    
    echo
}

# Function to check domain/email verification status
check_verification_status() {
    print_header "Email/Domain Verification Status"
    
    # Get verified identities
    local identities=$(aws sesv2 list-email-identities --region "$AWS_REGION" --query 'EmailIdentities[].IdentityName' --output text)
    
    if [[ -n "$identities" ]]; then
        print_info "Verified email addresses and domains:"
        for identity in $identities; do
            local verification_status=$(aws sesv2 get-email-identity \
                --email-identity "$identity" \
                --region "$AWS_REGION" \
                --query 'VerificationStatus' \
                --output text 2>/dev/null || echo "ERROR")
            
            if [[ "$verification_status" == "SUCCESS" ]]; then
                print_success "$identity"
            else
                print_warning "$identity (Status: $verification_status)"
            fi
        done
    else
        print_warning "No verified email addresses or domains found"
        print_info "Verify at least one email or domain to send emails"
    fi
    
    # Check if test email domain is verified
    local test_domain=$(echo "$TEST_EMAIL" | cut -d'@' -f2)
    if echo "$identities" | grep -q "$TEST_EMAIL\|$test_domain"; then
        print_success "Test email domain is verified"
    else
        print_warning "Test email domain '$test_domain' is not verified"
        print_info "This may prevent email sending in production"
    fi
    
    echo
}

# Function to check Configuration Set
check_configuration_set() {
    print_header "Configuration Set: $CONFIGURATION_SET_NAME"
    
    # Check if Configuration Set exists
    if aws sesv2 get-configuration-set --configuration-set-name "$CONFIGURATION_SET_NAME" --region "$AWS_REGION" &> /dev/null; then
        print_success "Configuration Set exists"
        
        # Get Configuration Set details
        local config_details=$(aws sesv2 get-configuration-set \
            --configuration-set-name "$CONFIGURATION_SET_NAME" \
            --region "$AWS_REGION" \
            --output json)
        
        # Check reputation tracking
        local reputation_enabled=$(echo "$config_details" | jq -r '.ReputationOptions.ReputationMetricsEnabled // false')
        if [[ "$reputation_enabled" == "true" ]]; then
            print_success "Reputation tracking enabled"
        else
            print_warning "Reputation tracking disabled"
        fi
        
        # Check delivery options
        local tls_policy=$(echo "$config_details" | jq -r '.DeliveryOptions.TlsPolicy // "Optional"')
        print_info "TLS Policy: $tls_policy"
        
    else
        print_error "Configuration Set does not exist"
        print_info "Run the setup script to create it"
        return 1
    fi
    
    echo
}

# Function to check Event Destinations
check_event_destinations() {
    print_header "Event Destinations"
    
    # Get event destinations
    local destinations=$(aws sesv2 get-configuration-set-event-destinations \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --region "$AWS_REGION" \
        --query 'EventDestinations' \
        --output json 2>/dev/null || echo "[]")
    
    local dest_count=$(echo "$destinations" | jq '. | length')
    
    if [[ "$dest_count" -gt 0 ]]; then
        print_success "$dest_count event destination(s) configured"
        
        echo "$destinations" | jq -r '.[] | "\(.Name): \(.Enabled) - Events: \(.MatchingEventTypes | join(", "))"' | while read line; do
            local name=$(echo "$line" | cut -d':' -f1)
            local enabled=$(echo "$line" | cut -d':' -f2 | cut -d'-' -f1 | xargs)
            local events=$(echo "$line" | cut -d'-' -f2 | cut -d':' -f2 | xargs)
            
            if [[ "$enabled" == "true" ]]; then
                print_success "$name (Events: $events)"
            else
                print_warning "$name - DISABLED"
            fi
        done
    else
        print_error "No event destinations configured"
        print_info "Events will not be sent to SNS"
        return 1
    fi
    
    echo
}

# Function to check SNS Topic and Subscription
check_sns_configuration() {
    print_header "SNS Configuration"
    
    # Find SNS topic
    local topic_arn=$(aws sns list-topics \
        --region "$AWS_REGION" \
        --query "Topics[?contains(TopicArn, '$SNS_TOPIC_NAME')].TopicArn" \
        --output text)
    
    if [[ -n "$topic_arn" ]]; then
        print_success "SNS Topic exists: $topic_arn"
        
        # Check topic policy
        local policy=$(aws sns get-topic-attributes \
            --topic-arn "$topic_arn" \
            --region "$AWS_REGION" \
            --query 'Attributes.Policy' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$policy" ]] && echo "$policy" | grep -q "ses.amazonaws.com"; then
            print_success "SES publish policy configured"
        else
            print_warning "SES publish policy may be missing"
        fi
        
        # Check subscriptions
        local subscriptions=$(aws sns list-subscriptions-by-topic \
            --topic-arn "$topic_arn" \
            --region "$AWS_REGION" \
            --query 'Subscriptions' \
            --output json)
        
        local sub_count=$(echo "$subscriptions" | jq '. | length')
        
        if [[ "$sub_count" -gt 0 ]]; then
            print_success "$sub_count subscription(s) found"
            
            echo "$subscriptions" | jq -r '.[] | "\(.Protocol):\(.Endpoint) - \(.SubscriptionArn)"' | while read line; do
                local endpoint=$(echo "$line" | cut -d':' -f2- | cut -d'-' -f1 | xargs)
                local subscription_arn=$(echo "$line" | cut -d'-' -f2- | xargs)
                
                if [[ "$subscription_arn" == *"pending confirmation"* ]]; then
                    print_warning "Subscription pending confirmation: $endpoint"
                else
                    print_success "Confirmed subscription: $endpoint"
                fi
            done
        else
            print_error "No subscriptions found"
            return 1
        fi
        
    else
        print_error "SNS Topic not found: $SNS_TOPIC_NAME"
        return 1
    fi
    
    echo
}

# Function to check sending quota and limits
check_sending_limits() {
    print_header "Sending Limits and Quota"
    
    # Get send quota
    local quota_info=$(aws sesv2 get-send-quota --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
    
    local max_24hour=$(echo "$quota_info" | jq -r '.Max24HourSend // "N/A"')
    local max_send_rate=$(echo "$quota_info" | jq -r '.MaxSendRate // "N/A"')
    local sent_last_24h=$(echo "$quota_info" | jq -r '.SentLast24Hours // "N/A"')
    
    print_info "Max 24-hour send: $max_24hour"
    print_info "Max send rate: $max_send_rate emails/second"
    print_info "Sent last 24h: $sent_last_24h"
    
    # Check if in sandbox mode
    local account_attributes=$(aws sesv2 get-account --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
    local production_access=$(echo "$account_attributes" | jq -r '.ProductionAccessEnabled // false')
    
    if [[ "$production_access" == "true" ]]; then
        print_success "Production access enabled"
    else
        print_warning "Account is in SES Sandbox mode"
        print_info "You can only send to verified email addresses"
        print_info "Request production access to send to any email"
    fi
    
    # Check reputation
    local reputation=$(aws sesv2 get-reputation --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
    local reputation_status=$(echo "$reputation" | jq -r '.ReputationStatus // "N/A"')
    
    if [[ "$reputation_status" != "N/A" ]]; then
        print_info "Reputation status: $reputation_status"
    fi
    
    echo
}

# Function to test Configuration Set by sending test email
test_configuration_set() {
    print_header "Configuration Set Test"
    
    print_info "Testing Configuration Set by attempting to send test email..."
    print_info "Test recipient: $TEST_EMAIL"
    
    # Create test email
    local message_id=$(date +%s)_test
    local subject="PhoenixKit AWS SES Test - $message_id"
    local body="This is a test email from PhoenixKit AWS SES configuration verification script.

Configuration Set: $CONFIGURATION_SET_NAME
Message ID: $message_id
Timestamp: $(date)

This email was sent to verify that AWS SES is properly configured for email tracking events."

    # Try to send email using SES v2 API
    local send_result=$(aws sesv2 send-email \
        --from-email-address "noreply@$(echo "$TEST_EMAIL" | cut -d'@' -f2)" \
        --destination "ToAddresses=$TEST_EMAIL" \
        --content "
        Simple={
            Subject={Data=\"$subject\",Charset=utf-8},
            Body={Text={Data=\"$body\",Charset=utf-8}}
        }" \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo "{}")
    
    local message_id_result=$(echo "$send_result" | jq -r '.MessageId // ""')
    
    if [[ -n "$message_id_result" ]]; then
        print_success "Test email sent successfully"
        print_info "Message ID: $message_id_result"
        print_info "Check your webhook logs for delivery events"
    else
        print_error "Failed to send test email"
        print_info "This might be due to:"
        print_info "- Unverified sender email/domain"
        print_info "- SES sandbox restrictions"
        print_info "- Configuration Set issues"
        print_info "- Insufficient permissions"
    fi
    
    echo
}

# Function to display troubleshooting tips
show_troubleshooting_tips() {
    print_header "Troubleshooting Tips"
    
    print_info "Common issues and solutions:"
    echo
    
    print_warning "1. Events not received in webhook:"
    print_info "   - Check SNS subscription confirmation status"
    print_info "   - Verify webhook endpoint is publicly accessible"
    print_info "   - Check PhoenixKit logs for webhook processing errors"
    print_info "   - Ensure Configuration Set is specified in email sending"
    echo
    
    print_warning "2. Email not being sent:"
    print_info "   - Verify sender email/domain in AWS SES"
    print_info "   - Check if account is in sandbox mode"
    print_info "   - Verify AWS credentials have SES permissions"
    print_info "   - Check sending quota limits"
    echo
    
    print_warning "3. Configuration issues:"
    print_info "   - Recreate Configuration Set if corrupted"
    print_info "   - Check Event Destination SNS topic ARN"
    print_info "   - Verify SNS topic policy allows SES publishing"
    print_info "   - Ensure webhook endpoint handles SNS format"
    echo
    
    print_info "Useful commands:"
    print_info "   aws sesv2 list-configuration-sets --region $AWS_REGION"
    print_info "   aws sns list-topics --region $AWS_REGION"
    print_info "   aws sesv2 get-send-statistics --region $AWS_REGION"
    echo
}

# Function to check PhoenixKit configuration
check_phoenixkit_config() {
    print_header "PhoenixKit Configuration Check"
    
    # This would need to be run from within Phoenix project
    print_info "To check PhoenixKit configuration, run from your Phoenix project:"
    print_info "   mix phoenix_kit.email.verify_config --detailed --check aws"
    print_info "   mix phoenix_kit.email.verify_config --check sns"
    echo
    
    print_info "Required PhoenixKit settings:"
    print_info "   - aws_ses_configuration_set: '$CONFIGURATION_SET_NAME'"
    print_info "   - email_tracking_enabled: 'true'"
    print_info "   - email_tracking_ses_events: 'true'"
    echo
}

# Main verification function
main() {
    echo "=== PhoenixKit AWS SES Configuration Verification ==="
    echo "Region: $AWS_REGION"
    echo "Configuration Set: $CONFIGURATION_SET_NAME"
    echo "SNS Topic: $SNS_TOPIC_NAME"
    echo "Test Email: $TEST_EMAIL"
    echo
    
    local error_count=0
    
    # Run all checks
    check_aws_prerequisites || ((error_count++))
    check_verification_status || ((error_count++))
    check_configuration_set || ((error_count++))
    check_event_destinations || ((error_count++))
    check_sns_configuration || ((error_count++))
    check_sending_limits || ((error_count++))
    
    # Optional test (may fail in sandbox mode)
    if [[ "${SKIP_EMAIL_TEST:-}" != "true" ]]; then
        test_configuration_set
    fi
    
    check_phoenixkit_config
    show_troubleshooting_tips
    
    # Summary
    print_header "Verification Summary"
    if [[ $error_count -eq 0 ]]; then
        print_success "All checks passed! AWS SES is properly configured."
        print_info "Your PhoenixKit email tracking should work correctly."
    else
        print_warning "$error_count issue(s) found."
        print_info "Review the errors above and fix them before testing email tracking."
    fi
    
    echo
}

# Help function
show_help() {
    echo "PhoenixKit AWS SES Configuration Verification Script"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Environment Variables:"
    echo "  CONFIGURATION_SET_NAME   Optional. Configuration Set name (default: phoenixkit-tracking)"
    echo "  SNS_TOPIC_NAME          Optional. SNS Topic name (default: phoenixkit-email-events)"
    echo "  AWS_REGION              Optional. AWS Region (default: eu-north-1)"
    echo "  TEST_EMAIL              Optional. Test email address (default: timujeen@gmail.com)"
    echo "  SKIP_EMAIL_TEST         Optional. Set to 'true' to skip email sending test"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo "  --summary     Show only summary without detailed checks"
    echo
    echo "Examples:"
    echo "  $0                                    # Full verification"
    echo "  SKIP_EMAIL_TEST=true $0               # Skip email sending test"
    echo "  AWS_REGION=us-east-1 $0               # Use different region"
}

# Command line argument handling
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    --summary)
        # Quick summary mode
        check_aws_prerequisites &>/dev/null && print_success "AWS CLI: OK" || print_error "AWS CLI: FAIL"
        aws sesv2 get-configuration-set --configuration-set-name "$CONFIGURATION_SET_NAME" --region "$AWS_REGION" &>/dev/null && print_success "Configuration Set: OK" || print_error "Configuration Set: MISSING"
        aws sns list-topics --region "$AWS_REGION" --query "Topics[?contains(TopicArn, '$SNS_TOPIC_NAME')]" --output text | grep -q . && print_success "SNS Topic: OK" || print_error "SNS Topic: MISSING"
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