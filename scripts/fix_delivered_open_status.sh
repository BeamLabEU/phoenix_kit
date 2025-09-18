#!/bin/bash

# Fix Delivered & Open Status Script for PhoenixKit
# This script resolves the issue where emails are logged but delivered/open events are not received

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
EVENT_DESTINATION_NAME="${EVENT_DESTINATION_NAME:-phoenixkit-events}"
AWS_REGION="${AWS_REGION:-eu-north-1}"
WEBHOOK_ENDPOINT="${WEBHOOK_ENDPOINT:-http://localhost:4000{prefix}/webhooks/email}"

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_header() { echo -e "${CYAN}=== $1 ===${NC}"; }

# Function to check prerequisites
check_prerequisites() {
    print_header "Prerequisites Check"
    
    local issues=0
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not installed"
        print_info "Install: curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && unzip awscliv2.zip && sudo ./aws/install"
        ((issues++))
    else
        print_success "AWS CLI installed"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured"
        print_info "Configure with: aws configure"
        print_info "Required: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION"
        ((issues++))
    else
        local identity=$(aws sts get-caller-identity --query 'Arn' --output text)
        print_success "AWS credentials valid: $identity"
    fi
    
    # Check webhook endpoint
    if [[ "$WEBHOOK_ENDPOINT" == *"localhost"* ]]; then
        print_warning "Webhook endpoint is localhost - events won't be received from AWS"
        print_info "For production, set: WEBHOOK_ENDPOINT=https://yourdomain.com{prefix}/webhooks/email"
        print_info "For testing, use ngrok: ngrok http 4000"
    fi
    
    echo
    return $issues
}

# Function to diagnose current issue
diagnose_issue() {
    print_header "Issue Diagnosis"
    
    print_info "Checking current PhoenixKit configuration..."
    
    # Check if emails are being logged
    cd /tmp/phoenixkit_hello_world 2>/dev/null || {
        print_error "PhoenixKit test project not found at /tmp/phoenixkit_hello_world"
        return 1
    }
    
    # Check email logs
    local log_count=$(mix run -e "
        logs = PhoenixKit.EmailTracking.list_logs()
        IO.puts(length(logs))
    " 2>/dev/null | tail -1)
    
    if [[ "$log_count" =~ ^[0-9]+$ ]] && [[ $log_count -gt 0 ]]; then
        print_success "Email logging works: $log_count emails in database"
    else
        print_error "No emails found in PhoenixKit logs"
        return 1
    fi
    
    # Check for events
    local event_count=$(mix run -e "
        events = Ecto.Adapters.SQL.query!(PhoenixkitHelloWorld.Repo, \"SELECT COUNT(*) FROM phoenix_kit_email_events\", [])
        IO.puts(List.first(List.first(events.rows)))
    " 2>/dev/null | tail -1)
    
    if [[ "$event_count" == "0" ]]; then
        print_error "No email events found - webhook events not being received!"
        print_info "This is the root cause of missing delivered/open statuses"
    else
        print_info "Found $event_count email events"
    fi
    
    echo
}

# Function to create Configuration Set
create_configuration_set() {
    print_header "Step 1: Create AWS SES Configuration Set"
    
    print_info "Creating Configuration Set: $CONFIGURATION_SET_NAME"
    
    # Check if exists
    if aws sesv2 get-configuration-set --configuration-set-name "$CONFIGURATION_SET_NAME" --region "$AWS_REGION" &>/dev/null; then
        print_success "Configuration Set already exists"
        return 0
    fi
    
    # Create Configuration Set
    aws sesv2 create-configuration-set \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --delivery-options tls-policy=Require \
        --reputation-options reputation-metrics-enabled=true \
        --region "$AWS_REGION"
    
    if [[ $? -eq 0 ]]; then
        print_success "Configuration Set created: $CONFIGURATION_SET_NAME"
    else
        print_error "Failed to create Configuration Set"
        return 1
    fi
    
    echo
}

# Function to create SNS Topic
create_sns_topic() {
    print_header "Step 2: Create SNS Topic for Email Events"
    
    print_info "Creating SNS Topic: $SNS_TOPIC_NAME"
    
    # Create SNS Topic
    local topic_arn=$(aws sns create-topic \
        --name "$SNS_TOPIC_NAME" \
        --region "$AWS_REGION" \
        --query 'TopicArn' \
        --output text)
    
    if [[ $? -eq 0 ]]; then
        print_success "SNS Topic created: $topic_arn"
        echo "$topic_arn"
    else
        print_error "Failed to create SNS Topic"
        return 1
    fi
    
    echo
}

# Function to create SNS Subscription
create_sns_subscription() {
    local topic_arn="$1"
    
    print_header "Step 3: Create SNS Subscription to Webhook"
    
    print_info "Creating HTTPS subscription to: $WEBHOOK_ENDPOINT"
    
    # Create subscription
    local subscription_arn=$(aws sns subscribe \
        --topic-arn "$topic_arn" \
        --protocol https \
        --notification-endpoint "$WEBHOOK_ENDPOINT" \
        --region "$AWS_REGION" \
        --query 'SubscriptionArn' \
        --output text)
    
    if [[ $? -eq 0 ]]; then
        print_success "SNS Subscription created: $subscription_arn"
        
        # Enable raw message delivery
        if [[ "$subscription_arn" != "pending confirmation" ]]; then
            aws sns set-subscription-attributes \
                --subscription-arn "$subscription_arn" \
                --attribute-name RawMessageDelivery \
                --attribute-value true \
                --region "$AWS_REGION"
            print_success "Raw message delivery enabled"
        fi
        
        print_warning "Subscription confirmation required!"
        print_info "PhoenixKit will automatically confirm when it receives the ConfirmSubscription message"
    else
        print_error "Failed to create SNS Subscription"
        return 1
    fi
    
    echo
}

# Function to create Event Destination
create_event_destination() {
    local topic_arn="$1"
    
    print_header "Step 4: Create SES Event Destination"
    
    print_info "Creating Event Destination: $EVENT_DESTINATION_NAME"
    
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
                "click",
                "reject"
            ],
            "SnsDestination": {
                "TopicArn": "'"$topic_arn"'"
            }
        }' \
        --region "$AWS_REGION"
    
    if [[ $? -eq 0 ]]; then
        print_success "Event Destination created with all event types"
        print_info "Events that will be tracked:"
        print_info "  ✓ send - Email accepted by SES"
        print_info "  ✓ delivery - Email delivered successfully"
        print_info "  ✓ bounce - Email bounced"
        print_info "  ✓ complaint - Spam complaint"
        print_info "  ✓ open - Email opened (pixel tracking)"
        print_info "  ✓ click - Link clicked"
        print_info "  ✓ reject - Email rejected"
    else
        print_error "Failed to create Event Destination"
        return 1
    fi
    
    echo
}

# Function to enable open and click tracking
enable_tracking_features() {
    print_header "Step 5: Enable Open & Click Tracking"
    
    print_info "Configuring tracking features in Configuration Set..."
    
    # Enable reputation tracking (helps with deliverability)
    aws sesv2 put-configuration-set-reputation-options \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --reputation-metrics-enabled \
        --region "$AWS_REGION"
    
    print_success "Reputation tracking enabled"
    
    # Enable delivery options
    aws sesv2 put-configuration-set-delivery-options \
        --configuration-set-name "$CONFIGURATION_SET_NAME" \
        --delivery-options TlsPolicy=Require \
        --region "$AWS_REGION"
    
    print_success "TLS delivery required"
    
    print_info "Open tracking: Automatic via SES (pixel in HTML emails)"
    print_info "Click tracking: Automatic via SES (link wrapping in HTML emails)"
    
    echo
}

# Function to test webhook endpoint
test_webhook_locally() {
    print_header "Step 6: Test Webhook Endpoint Locally"
    
    if [[ "$WEBHOOK_ENDPOINT" == *"localhost"* ]]; then
        print_warning "Testing local webhook endpoint..."
        
        # Check if Phoenix server is running
        if curl -s -f "$WEBHOOK_ENDPOINT" &>/dev/null; then
            print_success "Webhook endpoint is accessible locally"
        else
            print_error "Webhook endpoint not accessible"
            print_info "Ensure Phoenix server is running: iex -S mix phx.server"
            print_info "Check route is configured in router.ex"
        fi
    else
        print_info "Testing remote webhook endpoint..."
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_ENDPOINT" || echo "000")
        
        case $http_code in
            000) print_error "Cannot connect to webhook endpoint" ;;
            200|201|204|405) print_success "Webhook endpoint is accessible (HTTP $http_code)" ;;
            *) print_warning "Webhook returned HTTP $http_code (may be expected)" ;;
        esac
    fi
    
    echo
}

# Function to send test email
send_test_email() {
    print_header "Step 7: Send Test Email"
    
    print_info "Sending test email to verify complete tracking flow..."
    
    cd /tmp/phoenixkit_hello_world || {
        print_error "Cannot access PhoenixKit test project"
        return 1
    }
    
    # Create test email script
    cat > /tmp/test_tracking_flow.exs << 'EOF'
import Swoosh.Email

test_email = "timujeen@gmail.com"
from_email = "marketing@hydroforce.ee"
subject = "Email Test - #{:os.system_time(:second)}"

body_html = """
<html>
<body>
<h2>Email Test</h2>
<p>This email tests the complete tracking flow:</p>
<ul>
  <li>✓ Send event</li>
  <li>✓ Delivery event</li>
  <li>✓ Open tracking (this pixel)</li>
  <li>✓ Click tracking (link below)</li>
</ul>
<p><a href="https://example.com?test=click">Click here to test click tracking</a></p>
</body>
</html>
"""

email = new()
|> to(test_email)
|> from({"Hydroforce", from_email})
|> subject(subject)
|> html_body(body_html)
|> text_body("Email tracking test - please check HTML version")

# Send with PhoenixKit
result = PhoenixKit.Mailer.deliver_email(email)

case result do
  {:ok, email_log} ->
    IO.puts("✅ Email sent and logged!")
    IO.puts("PhoenixKit Message ID: #{email_log.message_id}")
    IO.puts("Configuration Set: #{email_log.configuration_set}")
  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
    exit({:shutdown, 1})
end
EOF
    
    mix run /tmp/test_tracking_flow.exs
    
    if [[ $? -eq 0 ]]; then
        print_success "Test email sent!"
        print_info "Now check timujeen@gmail.com and:"
        print_info "1. Verify email delivery"
        print_info "2. Open the email (generates open event)"
        print_info "3. Click the test link (generates click event)"
        print_info "4. Check PhoenixKit admin panel for events"
    else
        print_error "Failed to send test email"
    fi
    
    echo
}

# Function to monitor events
monitor_events() {
    print_header "Step 8: Monitor Events"
    
    print_info "Monitoring PhoenixKit for incoming events..."
    print_info "Events should appear within 1-2 minutes after email actions"
    
    cd /tmp/phoenixkit_hello_world || return 1
    
    for i in {1..10}; do
        local event_count=$(mix run -e "
            events = Ecto.Adapters.SQL.query!(PhoenixkitHelloWorld.Repo, \"SELECT COUNT(*) FROM phoenix_kit_email_events\", [])
            IO.puts(List.first(List.first(events.rows)))
        " 2>/dev/null | tail -1)
        
        if [[ "$event_count" =~ ^[0-9]+$ ]] && [[ $event_count -gt 0 ]]; then
            print_success "Found $event_count email events!"
            
            # Show recent events
            mix run -e "
                events = Ecto.Adapters.SQL.query!(PhoenixkitHelloWorld.Repo, 
                  \"SELECT event_type, occurred_at FROM phoenix_kit_email_events ORDER BY occurred_at DESC LIMIT 5\", [])
                IO.puts(\"Recent events:\")
                Enum.each(events.rows, fn [type, time] ->
                  IO.puts(\"  #{type} at #{time}\")
                end)
            " 2>/dev/null
            break
        else
            print_info "Waiting for events... ($i/10)"
            sleep 30
        fi
    done
    
    echo
}

# Function to display final status
show_final_status() {
    print_header "Final Status Check"
    
    cd /tmp/phoenixkit_hello_world || return 1
    
    # Check email logs with delivered status
    mix run -e "
        logs = PhoenixKit.EmailTracking.list_logs() |> Enum.take(3)
        IO.puts(\"Recent Email Status:\")
        Enum.each(logs, fn log ->
          status = if log.delivered_at, do: \"✅ delivered\", else: \"⏳ sent\"
          IO.puts(\"  #{log.subject}: #{status}\")
        end)
    " 2>/dev/null
    
    # Check event counts
    local event_count=$(mix run -e "
        events = Ecto.Adapters.SQL.query!(PhoenixkitHelloWorld.Repo, \"SELECT COUNT(*) FROM phoenix_kit_email_events\", [])
        IO.puts(List.first(List.first(events.rows)))
    " 2>/dev/null | tail -1)
    
    if [[ "$event_count" =~ ^[0-9]+$ ]] && [[ $event_count -gt 0 ]]; then
        print_success "Email tracking is now working!"
        print_info "Found $event_count events in database"
        print_info "Admin panel: http://localhost:4000{prefix}/admin/emails"
    else
        print_warning "No events received yet"
        print_info "This may be due to:"
        print_info "  - Webhook endpoint not accessible from internet"
        print_info "  - SNS subscription not confirmed"
        print_info "  - Configuration Set not applied to emails"
    fi
}

# Function to show troubleshooting tips
show_troubleshooting() {
    print_header "Troubleshooting Tips"
    
    print_info "If delivered/open events still don't work:"
    echo
    
    print_warning "1. Webhook Endpoint Issues:"
    print_info "   - Use ngrok for local testing: ngrok http 4000"
    print_info "   - Update WEBHOOK_ENDPOINT to ngrok URL"
    print_info "   - Check firewall allows HTTPS traffic"
    echo
    
    print_warning "2. SNS Subscription Issues:"
    print_info "   - Check subscription status in AWS SNS Console"
    print_info "   - Confirm subscription via PhoenixKit logs"
    print_info "   - Verify raw message delivery is enabled"
    echo
    
    print_warning "3. Configuration Set Issues:"
    print_info "   - Verify Configuration Set exists in AWS SES"
    print_info "   - Check Event Destination is enabled"
    print_info "   - Ensure all event types are configured"
    echo
    
    print_warning "4. Domain/Email Issues:"
    print_info "   - Verify sending domain in AWS SES"
    print_info "   - Check account is out of sandbox mode"
    print_info "   - Ensure recipient email can receive mail"
    echo
    
    print_info "Useful commands for debugging:"
    print_info "   aws sesv2 list-configuration-sets --region $AWS_REGION"
    print_info "   aws sns list-subscriptions-by-topic --topic-arn <topic-arn>"
    print_info "   tail -f log/dev.log | grep -i webhook"
    echo
}

# Main execution function
main() {
    echo "=== Fix Delivered & Open Status for PhoenixKit ==="
    echo "This script resolves missing delivered/open events by setting up AWS SES event tracking"
    echo
    
    # Check prerequisites
    check_prerequisites
    local prereq_issues=$?
    
    if [[ $prereq_issues -gt 0 ]]; then
        print_error "Please resolve prerequisite issues before continuing"
        exit 1
    fi
    
    # Diagnose current issue
    diagnose_issue
    
    # Execute setup steps
    create_configuration_set
    
    local topic_arn
    topic_arn=$(create_sns_topic)
    
    if [[ -n "$topic_arn" ]]; then
        create_sns_subscription "$topic_arn"
        create_event_destination "$topic_arn"
    else
        print_error "Cannot continue without SNS Topic ARN"
        exit 1
    fi
    
    enable_tracking_features
    test_webhook_locally
    send_test_email
    monitor_events
    show_final_status
    show_troubleshooting
    
    print_success "Setup complete!"
    print_info "Delivered and open events should now be received by PhoenixKit"
}

# Help function
show_help() {
    echo "Fix Delivered & Open Status Script for PhoenixKit"
    echo
    echo "This script fixes the issue where emails are sent and logged but delivered/open events are missing."
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Environment Variables:"
    echo "  WEBHOOK_ENDPOINT         Required. Webhook URL (default: http://localhost:4000{prefix}/webhooks/email)"
    echo "  CONFIGURATION_SET_NAME   Optional. Configuration Set name (default: phoenixkit-tracking)"
    echo "  SNS_TOPIC_NAME          Optional. SNS Topic name (default: phoenixkit-email-events)"
    echo "  AWS_REGION              Optional. AWS Region (default: eu-north-1)"
    echo
    echo "For production use:"
    echo "  export WEBHOOK_ENDPOINT=https://yourdomain.com{prefix}/webhooks/email"
    echo "  $0"
    echo
    echo "For local testing:"
    echo "  # Terminal 1: Start ngrok"
    echo "  ngrok http 4000"
    echo "  "
    echo "  # Terminal 2: Use ngrok URL"
    echo "  export WEBHOOK_ENDPOINT=https://abc123.ngrok.io{prefix}/webhooks/email"
    echo "  $0"
    echo "  # Note: Replace {prefix} with your configured PhoenixKit URL prefix (default: /phoenix_kit)"
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