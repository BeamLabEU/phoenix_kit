#!/bin/bash

# AWS SES Domain Setup Script for hydroforce.ee
# This script sets up domain verification and DKIM for hydroforce.ee domain

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration variables
DOMAIN="${DOMAIN:-hydroforce.ee}"
MARKETING_EMAIL="${MARKETING_EMAIL:-marketing@hydroforce.ee}"
AWS_REGION="${AWS_REGION:-eu-north-1}"

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_header() { echo -e "${CYAN}=== $1 ===${NC}"; }

# Function to check AWS CLI and credentials
check_prerequisites() {
    print_header "Prerequisites Check"
    
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not installed"
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured"
        exit 1
    fi
    
    local identity=$(aws sts get-caller-identity --query 'Arn' --output text)
    print_success "AWS credentials valid: $identity"
    print_info "Region: $AWS_REGION"
    print_info "Domain: $DOMAIN"
    print_info "Marketing Email: $MARKETING_EMAIL"
    echo
}

# Function to verify domain in AWS SES
setup_domain_verification() {
    print_header "Domain Verification Setup"
    
    print_info "Setting up domain identity for $DOMAIN..."
    
    # Create domain identity
    aws sesv2 put-email-identity \
        --email-identity "$DOMAIN" \
        --region "$AWS_REGION" \
        --output table
    
    if [ $? -eq 0 ]; then
        print_success "Domain identity created/updated: $DOMAIN"
    else
        print_error "Failed to create domain identity"
        return 1
    fi
    
    # Get domain verification details
    print_info "Getting domain verification details..."
    local verification_info=$(aws sesv2 get-email-identity \
        --email-identity "$DOMAIN" \
        --region "$AWS_REGION" \
        --output json)
    
    local verification_status=$(echo "$verification_info" | jq -r '.VerificationStatus // "Unknown"')
    print_info "Current verification status: $verification_status"
    
    if [[ "$verification_status" == "Success" ]]; then
        print_success "Domain is already verified!"
    else
        print_warning "Domain verification required"
        print_info "Add the following TXT record to your DNS:"
        
        # Get verification token (SES v2 format)
        local verification_token=$(echo "$verification_info" | jq -r '.VerificationInfo.SOARecord // "Not available"')
        if [[ "$verification_token" != "Not available" ]]; then
            print_info "TXT Record: $verification_token"
        else
            print_warning "Verification token not available in response"
            print_info "Check AWS SES Console for verification requirements"
        fi
    fi
    
    echo
}

# Function to setup DKIM
setup_dkim() {
    print_header "DKIM Setup"
    
    print_info "Enabling DKIM for $DOMAIN..."
    
    # Enable DKIM
    aws sesv2 put-email-identity-dkim-attributes \
        --email-identity "$DOMAIN" \
        --signing-enabled \
        --region "$AWS_REGION"
    
    if [ $? -eq 0 ]; then
        print_success "DKIM enabled for $DOMAIN"
    else
        print_warning "Failed to enable DKIM (domain may not be verified yet)"
    fi
    
    # Get DKIM tokens
    print_info "Getting DKIM configuration..."
    local dkim_info=$(aws sesv2 get-email-identity-dkim-attributes \
        --email-identity "$DOMAIN" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo "{}")
    
    local dkim_status=$(echo "$dkim_info" | jq -r '.SigningEnabled // false')
    if [[ "$dkim_status" == "true" ]]; then
        print_success "DKIM is enabled"
        
        # Get DKIM tokens
        local dkim_tokens=$(echo "$dkim_info" | jq -r '.Tokens[]? // empty' 2>/dev/null)
        if [[ -n "$dkim_tokens" ]]; then
            print_info "Add these CNAME records to your DNS:"
            echo "$dkim_tokens" | while read token; do
                if [[ -n "$token" ]]; then
                    print_info "CNAME: ${token}._domainkey.$DOMAIN → ${token}.dkim.amazonses.com"
                fi
            done
        fi
    else
        print_warning "DKIM not enabled yet"
    fi
    
    echo
}

# Function to setup marketing email specifically
setup_marketing_email() {
    print_header "Marketing Email Setup"
    
    print_info "Setting up marketing email: $MARKETING_EMAIL"
    
    # Create email identity (optional if domain is verified)
    aws sesv2 put-email-identity \
        --email-identity "$MARKETING_EMAIL" \
        --region "$AWS_REGION" \
        --output table
    
    if [ $? -eq 0 ]; then
        print_success "Marketing email identity created: $MARKETING_EMAIL"
    else
        print_warning "Failed to create email identity (may already exist)"
    fi
    
    # Check verification status
    local email_info=$(aws sesv2 get-email-identity \
        --email-identity "$MARKETING_EMAIL" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo "{}")
    
    local email_status=$(echo "$email_info" | jq -r '.VerificationStatus // "Unknown"')
    print_info "Marketing email verification status: $email_status"
    
    if [[ "$email_status" == "Success" ]]; then
        print_success "Marketing email is verified and ready to use!"
    else
        if [[ "$email_status" == "Pending" ]]; then
            print_warning "Email verification pending - check your inbox for verification email"
        else
            print_info "If domain $DOMAIN is verified, this email will work automatically"
        fi
    fi
    
    echo
}

# Function to test email sending capability
test_email_sending() {
    print_header "Email Sending Test"
    
    print_info "Testing email sending capability..."
    print_warning "This will attempt to send a test email to verify configuration"
    
    read -p "Enter test recipient email (or press Enter to skip): " test_recipient
    
    if [[ -z "$test_recipient" ]]; then
        print_info "Skipping email test"
        return 0
    fi
    
    print_info "Sending test email from $MARKETING_EMAIL to $test_recipient..."
    
    # Create simple test email
    local message_body="Subject: AWS SES Domain Setup Test - $DOMAIN
From: $MARKETING_EMAIL
To: $test_recipient

Hello!

This is a test email from the AWS SES domain setup for $DOMAIN.

Configuration:
- Domain: $DOMAIN
- Marketing Email: $MARKETING_EMAIL
- AWS Region: $AWS_REGION
- Timestamp: $(date)

If you receive this email, the domain is properly configured for sending.

Best regards,
Hydroforce Team"

    # Send via AWS SES CLI
    aws sesv2 send-email \
        --from-email-address "$MARKETING_EMAIL" \
        --destination "ToAddresses=$test_recipient" \
        --content "Simple={Subject={Data=\"AWS SES Domain Setup Test - $DOMAIN\",Charset=utf-8},Body={Text={Data=\"$message_body\",Charset=utf-8}}}" \
        --region "$AWS_REGION" \
        --output json
    
    if [ $? -eq 0 ]; then
        print_success "Test email sent successfully!"
        print_info "Check the recipient's inbox for the test message"
    else
        print_error "Failed to send test email"
        print_info "This may be due to:"
        print_info "  - Domain not verified yet"
        print_info "  - Account in sandbox mode"
        print_info "  - Recipient email not verified (in sandbox)"
        print_info "  - Insufficient permissions"
    fi
    
    echo
}

# Function to display DNS configuration summary
show_dns_summary() {
    print_header "DNS Configuration Summary"
    
    print_info "To complete the setup, add these DNS records:"
    echo
    
    # Domain verification
    print_info "1. Domain Verification (if not verified):"
    print_info "   Check AWS SES Console → Verified identities → $DOMAIN"
    print_info "   Add the TXT record shown there to your DNS"
    echo
    
    # DKIM records
    print_info "2. DKIM Configuration:"
    local dkim_info=$(aws sesv2 get-email-identity-dkim-attributes \
        --email-identity "$DOMAIN" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo "{}")
    
    local dkim_tokens=$(echo "$dkim_info" | jq -r '.Tokens[]? // empty' 2>/dev/null)
    if [[ -n "$dkim_tokens" ]]; then
        print_info "   Add these CNAME records:"
        echo "$dkim_tokens" | while read token; do
            if [[ -n "$token" ]]; then
                echo "   CNAME: ${token}._domainkey.$DOMAIN → ${token}.dkim.amazonses.com"
            fi
        done
    else
        print_info "   DKIM tokens not available yet (domain may need verification first)"
    fi
    echo
    
    print_info "3. SPF Record (recommended):"
    print_info "   TXT: v=spf1 include:amazonses.com ~all"
    echo
    
    print_info "4. DMARC Record (recommended):"
    print_info "   TXT: _dmarc.$DOMAIN → v=DMARC1; p=quarantine; rua=mailto:dmarc@$DOMAIN"
    echo
}

# Function to display next steps
show_next_steps() {
    print_header "Next Steps"
    
    print_info "1. 📧 Configure DNS records as shown above"
    print_info "2. ⏱️  Wait for DNS propagation (up to 72 hours)"
    print_info "3. 🔍 Verify domain status in AWS SES Console"
    print_info "4. 🚀 Use PhoenixKit AWS SES setup script:"
    print_info "   export WEBHOOK_ENDPOINT=https://yourdomain.com{prefix}/webhooks/email"
    print_info "   # Note: Replace {prefix} with your configured PhoenixKit URL prefix (default: /phoenix_kit)"
    print_info "   /app/scripts/aws_ses_setup.sh"
    print_info "5. ✅ Test email tracking with PhoenixKit"
    echo
    
    print_info "📊 Monitoring Commands:"
    print_info "   aws sesv2 list-email-identities --region $AWS_REGION"
    print_info "   aws sesv2 get-email-identity --email-identity $DOMAIN --region $AWS_REGION"
    print_info "   /app/scripts/aws_ses_verify.sh"
    echo
    
    print_info "📚 Documentation:"
    print_info "   - Setup Guide: /app/docs/AWS_SES_SETUP_GUIDE.md"
    print_info "   - Security Guide: /app/docs/AWS_SES_SECURITY.md"
    echo
}

# Main execution
main() {
    echo "=== Hydroforce Domain Setup for AWS SES ==="
    echo
    
    check_prerequisites
    setup_domain_verification
    setup_dkim
    setup_marketing_email
    test_email_sending
    show_dns_summary
    show_next_steps
    
    print_success "Hydroforce domain setup completed!"
}

# Help function
show_help() {
    echo "Hydroforce Domain Setup Script for AWS SES"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Environment Variables:"
    echo "  DOMAIN                Optional. Domain name (default: hydroforce.ee)"
    echo "  MARKETING_EMAIL       Optional. Marketing email (default: marketing@hydroforce.ee)"
    echo "  AWS_REGION           Optional. AWS Region (default: eu-north-1)"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "Example:"
    echo "  export DOMAIN=hydroforce.ee"
    echo "  export MARKETING_EMAIL=marketing@hydroforce.ee"
    echo "  export AWS_REGION=eu-north-1"
    echo "  $0"
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