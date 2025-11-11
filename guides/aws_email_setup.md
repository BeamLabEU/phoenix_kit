# AWS Email Setup Guide

PhoenixKit provides comprehensive AWS integration for email tracking and event handling. This guide covers the complete setup process for AWS SES, SNS, and SQS services.

## Overview

The AWS email infrastructure enables you to:
- Track email delivery, opens, clicks, and other events
- Process email events in real-time using SQS polling
- Store email data with configurable retention policies
- Integrate with AWS services for advanced analytics

## Quick Start

### 1. Create AWS Account (if you don't have one)

1. Go to [AWS Console](https://aws.amazon.com/console/)
2. Sign up for a new account or sign in to existing account
3. Complete account verification process

### 2. Create IAM User for PhoenixKit

1. Navigate to [IAM Console](https://console.aws.amazon.com/iam/)
2. Go to "Users" → "Add user"
3. Enter user name (e.g., `phoenixkit-user`)
4. Select "Programmatic access" type
5. Attach policies:
   ```
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "sqs:*",
           "sns:*",
           "ses:*",
           "sts:GetCallerIdentity",
           "ec2:DescribeRegions"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

### 3. Get AWS Credentials

1. After creating the user, download or copy:
   - **Access Key ID** (e.g., `AKIAIOSFODNN7EXAMPLE`)
   - **Secret Access Key** (e.g., `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`)
2. Store these credentials securely - you won't be able to see the secret key again

### 4. Configure in PhoenixKit Admin UI

1. Navigate to `{prefix}/admin/settings/emails`
2. Scroll to "AWS Configuration" section
3. Enter your AWS credentials:
   - **Access Key ID**: Your 20-character access key
   - **Secret Access Key**: Your secret access key
   - **Region**: Select your preferred AWS region
4. Click "Verify Credentials" to test connectivity
5. Click "Save AWS Settings" to persist the configuration

> **Understanding Credentials Verification**
>
> When you click "Verify Credentials", PhoenixKit calls AWS STS GetCallerIdentity to verify:
> - ✅ Credentials are valid (not expired or revoked)
> - ✅ AWS account ID is accessible
> - ✅ Credentials can authenticate with AWS
>
> **Permissions are NOT checked during verification.** Actual permissions (CreateQueue, CreateTopic, etc.)
> are verified during "Setup AWS Infrastructure" (next step). If permissions are missing, you'll receive
> a specific error message indicating which permission is required.

### 5. Setup AWS Infrastructure

1. After saving credentials, click "Setup AWS Infrastructure"
2. PhoenixKit will automatically create:
   - SNS Topic for email events
   - SQS Main Queue for message processing
   - SQS Dead Letter Queue for failed messages
   - SES Configuration Set for tracking
3. Wait for completion (typically 30-60 seconds)

### 6. Verify Email/Domain in SES

1. Navigate to [SES Console](https://console.aws.amazon.com/ses/)
2. Go to "Verified identities" → "Email addresses" or "Domains"
3. Verify the email address you'll use as sender
4. If using custom domain, verify the domain

### 7. Enable Email System

1. Return to PhoenixKit settings
2. Toggle "Enable Emails" to ON
3. Configure other settings as needed

### 8. Understanding AWS Permissions

PhoenixKit requires the following AWS permissions for full email functionality:

#### Required Permissions (for Setup AWS Infrastructure)

- **SQS** (Simple Queue Service):
  - `sqs:CreateQueue`, `sqs:GetQueueAttributes`, `sqs:SetQueueAttributes`
  - `sqs:ReceiveMessage`, `sqs:DeleteMessage` (for SQS worker)

- **SNS** (Simple Notification Service):
  - `sns:CreateTopic`, `sns:Subscribe`, `sns:SetTopicAttributes`

- **SES** (Simple Email Service):
  - `ses:CreateConfigurationSet`, `ses:CreateConfigurationSetEventDestination`
  - `ses:SendEmail`, `ses:SendRawEmail` (for sending emails)

- **STS** (Security Token Service):
  - `sts:GetCallerIdentity` (for credentials verification)

#### Optional Permissions

- **EC2** `ec2:DescribeRegions`:
  - Used for automatic region discovery in the admin UI
  - If not granted, manual region selection from common regions list is available
  - NOT required for email functionality

If any required permission is missing, "Setup AWS Infrastructure" will fail with a specific error message
indicating which permission is needed. Simply add the permission to your IAM policy and try again.

## Detailed Instructions

### IAM Configuration

#### Minimal Required Permissions

For production, use least-privilege permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail",
        "ses:CreateConfigurationSet",
        "ses:CreateConfigurationSetEventDestination",
        "ses:UpdateConfigurationSetEventDestination",
        "ses:DescribeConfigurationSets",
        "ses:GetSendQuota"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:GetQueueAttributes",
        "sqs:SetQueueAttributes",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ListQueues"
      ],
      "Resource": "arn:aws:sqs:*:*:phoenixkit-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:Subscribe",
        "sns:ListSubscriptions",
        "sns:GetTopicAttributes",
        "sns:SetTopicAttributes"
      ],
      "Resource": "arn:aws:sns:*:*:phoenixkit-*"
    },
    {
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "OptionalEC2ForAutoRegionDiscovery",
      "Effect": "Allow",
      "Action": "ec2:DescribeRegions",
      "Resource": "*"
    }
  ]
}
```

**Note**: The `ec2:DescribeRegions` permission allows PhoenixKit to automatically fetch the list of available AWS regions when configuring SES integration. This is optional - if not granted, PhoenixKit will fall back to a predefined list of common regions.

#### Environment Variables (Alternative)

You can also configure credentials via environment variables:

```bash
# ~/.bashrc or ~/.zshrc
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_DEFAULT_REGION="eu-north-1"
```

### Region Selection

Choose a region based on:
- **Data residency requirements** (GDPR, CCPA, etc.)
- **Latency** for your users
- **Service availability** (some services vary by region)
- **Cost considerations** (different pricing per region)

Common regions:
- `us-east-1` (N. Virginia) - highest service availability
- `us-west-2` (Oregon) - good for APAC users
- `eu-west-1` (Ireland) - good for European users
- `ap-southeast-1` (Singapore) - good for Asian users

### SES Configuration

#### Email Verification

Before sending emails, you need to verify:
- **Email addresses**: Send verification email to the address
- **Domains**: Verify DNS records (MX, CNAME, etc.)

#### Production Considerations

1. **Request Production Access**: SES starts in "sandbox mode"
   - Request production access via [AWS Support](https://console.aws.amazon.com/support/)
   - Alternatively, use verified email addresses in sandbox

2. **Vetting Process**: Amazon may review your use case
   - Provide details about your email volume and content
   - Explain how you handle unsubscribe requests

### Monitoring and Troubleshooting

#### Common Issues

**1. "Invalid credentials" error**
- Verify Access Key ID and Secret Access Key are correct
- Ensure IAM user has the correct permissions
- Check if the account is in good standing

**2. "Access denied" error**
- Verify IAM permissions for SQS, SNS, and SES
- Check resource ARN patterns in policies
- Ensure the region is correct

**3. SQS polling not working**
- Ensure SQS polling is enabled in settings
- Check SQS queue URL is correct
- Verify SNS subscription is active

#### Logs and Monitoring

1. **AWS CloudTrail**: Track API calls
2. **AWS CloudWatch**: Monitor metrics and logs
3. **PhoenixKit Logs**: Check for email processing errors

#### Testing Your Setup

1. **Send Test Email**:
   ```elixir
   Swoosh.Email.new()
   |> Swoosh.Email.to("test@example.com")
   |> Swoosh.Email.from({sender_name, sender_email})
   |> Swoosh.Email.subject("Test from PhoenixKit")
   |> Swoosh.Email.html_body("<h1>Test Email</h1>")
   |> PhoenixKit.Mailer.deliver_email()
   ```

2. **Check Event Tracking**:
   - Look for email events in PhoenixKit admin UI
   - Monitor SQS queue for incoming messages
   - Check SES event notifications

## Advanced Configuration

### Custom SQS Polling Settings

Configure these settings in PhoenixKit admin UI:
- **Polling Interval**: How often to check SQS (1-60 seconds)
- **Max Messages**: Messages to process per poll (1-10)
- **Visibility Timeout**: How long messages are hidden (30-43200 seconds)

### S3 Archival for Long-term Storage

1. Enable "S3 Archival" in settings
2. Configure S3 bucket:
   ```bash
   aws s3 mb s3://your-phoenixkit-emails
   ```
3. Set retention policies for automatic cleanup

### Data Retention and Compliance

- **Retention Period**: Configure how long to keep email data
- **Compression**: Enable body compression after X days
- **GDPR Compliance**: Implement data deletion policies
- **Access Controls**: Use IAM roles for access control

## Security Best Practices

### Production Deployment

1. **Use IAM Roles**: Instead of access keys, use IAM roles with EC2 instances
2. **Rotate Credentials**: Regularly rotate access keys
3. **Enable CloudTrail**: Monitor all API calls
4. **Use KMS**: Encrypt sensitive data at rest

### Network Security

1. **VPC Endpoints**: Use interface VPC endpoints for private connectivity
2. **Security Groups**: Restrict access to SQS/SNS endpoints
3. **Network ACLs**: Control traffic flow at subnet level

## Cost Optimization

### Cost Control Measures

1. **SQS**: Use long polling to reduce costs
2. **SNS**: Use filtered subscriptions to reduce processing
3. **SES**: Monitor send quotas and bounce rates
4. **Storage**: Use S3 lifecycle policies for automated cleanup

### Estimated Costs

Example costs for 10,000 emails/month:
- **SES**: Free (within limits)
- **SQS**: ~$1/month
- **SNS**: ~$1/month
- **S3**: ~$0.50/month (for archival)

## Support and Resources

### AWS Documentation

- [SES Developer Guide](https://docs.aws.amazon.com/ses/latest/dg/Welcome.html)
- [SQS Developer Guide](https://docs.aws.amazon.com/sqs/latest/dg/Welcome.html)
- [SNS Developer Guide](https://docs.aws.amazon.com/sns/latest/dg/Welcome.html)

### PhoenixKit Resources

- **Email Configuration Guide**: `/docs/EMAIL_CONFIGURATION.md`
- **AWS Solutions Guide**: `/docs/AWS_EMAILS_SOLUTIONS.md`
- **Troubleshooting**: `/docs/AWS_SES_SETUP.md`

### Getting Help

1. **AWS Support**: [AWS Support Center](https://aws.amazon.com/support/)
2. **PhoenixKit Issues**: GitHub Issues
3. **Community**: PhoenixKit Discord/Community forums

---

**Note**: Always test your email setup in a non-production environment before deploying to production. Monitor costs and adjust settings as needed.