# AWS Email Setup Guide

How to send mail through Amazon SES from a PhoenixKit site, and how to receive
its delivery events (delivered, bounced, complained) through SNS and SQS.

Sending is part of PhoenixKit itself. Delivery events are the job of the
`phoenix_kit_emails` module; without it you need only the sending steps.

## The short version

1. Create an IAM user and give it the **setup policy**.
2. Create an access key for it and save it as an **Amazon SES** connection in
   Settings → Integrations.
3. Verify your sender in SES.
4. In Settings → Emails Transactional, add the connection as an Amazon SES/SQS
   account and press **Setup Infrastructure**.
5. Replace the setup policy with the **running policy**.

The policies below are the only ones the key needs. The connection form in
Settings → Integrations shows the same two, with your site's names and region
already filled in and a Copy button: prefer those over typing the placeholders
here by hand.

## IAM policies

The key needs more while the infrastructure is being created than it does
afterwards, so there are two policies, used one after the other.

In both, replace:

- `<region>` with the AWS region of the connection, for example `eu-north-1`;
- `<project>` with your project name: the site's project title in lower case,
  with every character outside `a-z`, `0-9` and `-` turned into `-` and the
  dashes at both ends removed. "My App!" gives `my-app`. A title that leaves
  nothing gives `myapp`.

### 1. Setup policy

Attach it before you create the connection and keep it until **Setup
Infrastructure** has succeeded.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Send",
      "Effect": "Allow",
      "Action": [
        "ses:SendRawEmail",
        "ses:SendEmail",
        "ses:GetSendQuota"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SetupInfrastructure",
      "Effect": "Allow",
      "Action": [
        "ses:CreateConfigurationSet",
        "ses:CreateConfigurationSetEventDestination",
        "sns:CreateTopic",
        "sns:Subscribe",
        "sqs:CreateQueue",
        "sqs:GetQueueUrl",
        "sqs:SetQueueAttributes"
      ],
      "Resource": [
        "arn:aws:ses:<region>:*:configuration-set/<project>-emailing",
        "arn:aws:sns:<region>:*:<project>-email-events",
        "arn:aws:sqs:<region>:*:<project>-email-queue",
        "arn:aws:sqs:<region>:*:<project>-email-dlq"
      ]
    },
    {
      "Sid": "ReadDeliveryEvents",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage"
      ],
      "Resource": [
        "arn:aws:sqs:<region>:*:<project>-email-queue",
        "arn:aws:sqs:<region>:*:<project>-email-dlq"
      ]
    }
  ]
}
```

### 2. Running policy

Once the setup has succeeded, replace the setup policy with this one. It is
the setup policy without the `SetupInfrastructure` statement: the key that
stays on your server can send and read its two queues, and can create or
reconfigure nothing.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Send",
      "Effect": "Allow",
      "Action": [
        "ses:SendRawEmail",
        "ses:SendEmail",
        "ses:GetSendQuota"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadDeliveryEvents",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage"
      ],
      "Resource": [
        "arn:aws:sqs:<region>:*:<project>-email-queue",
        "arn:aws:sqs:<region>:*:<project>-email-dlq"
      ]
    }
  ]
}
```

### A site that only sends

With no delivery events there is nothing to set up, and the key needs the
`Send` statement alone:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Send",
      "Effect": "Allow",
      "Action": [
        "ses:SendRawEmail",
        "ses:SendEmail",
        "ses:GetSendQuota"
      ],
      "Resource": "*"
    }
  ]
}
```

### Things to know

- **Running the setup again needs the setup policy again.** The setup is safe
  to repeat: it finds what already exists and leaves it as it is.
- **A failed setup names what was missing.** When AWS refuses a call, the
  error shows the action it refused. Compare your policy with the setup
  policy above and try again.
- **If the project title changed after the setup,** the queues keep the names
  they were created with. Use those names in the policy: each account under
  Delivery Event Tracking shows its queue, topic and configuration set.
- **`ses:SendEmail` is not used today.** Mail is sent with `SendRawEmail`. The
  other action is in the policy so that a later move to the newer SES API
  breaks no key.
- **No List or Describe permission is needed.** Older instructions asked for
  `sqs:ListQueues`, `sns:ListTopics`, `ses:ListConfigurationSets` and
  `ec2:DescribeRegions`, or for `ses:*`, `sqs:*` and `sns:*`. Nothing calls
  them; you can remove them.

### What each permission is for

| When | What PhoenixKit does | IAM action |
|---|---|---|
| Sending | sends the message | `ses:SendRawEmail` |
| Test Connection | reads the send quota; if refused, the test still passes with a note | `ses:GetSendQuota` |
| Test Connection, setup | asks AWS whose key this is | `sts:GetCallerIdentity` (allowed to every key, not in the policy) |
| Setup | creates the queue and the dead-letter queue, or finds them | `sqs:CreateQueue`, `sqs:GetQueueUrl` |
| Setup | sets who may send to and read the queues | `sqs:SetQueueAttributes` |
| Setup | creates the topic and subscribes the queue to it | `sns:CreateTopic`, `sns:Subscribe` |
| Setup | creates the configuration set and its event destination | `ses:CreateConfigurationSet`, `ses:CreateConfigurationSetEventDestination` |
| Running | reads delivery events and removes the ones it has processed | `sqs:ReceiveMessage`, `sqs:DeleteMessage` |

The resources the setup creates:

| Resource | Name |
|---|---|
| SQS queue | `<project>-email-queue` |
| SQS dead-letter queue | `<project>-email-dlq` |
| SNS topic | `<project>-email-events` |
| SES configuration set | `<project>-emailing` |

## Step by step

### 1. Create the IAM user

1. Open the [IAM console](https://console.aws.amazon.com/iam/home#/users) and
   create a user. It needs no console access.
2. On the user, choose Permissions → Add permissions → Create inline policy →
   JSON, and paste the **setup policy**.
3. Under Security credentials, create an access key. Copy the access key ID
   and the secret access key: the secret is shown once.

### 2. Save the connection

1. In the admin, open Settings → Integrations and add an **Amazon SES**
   connection.
2. Enter the access key ID, the secret access key and the region.
3. Press **Test Connection**. It checks the key against SES and shows the AWS
   account it belongs to.

### 3. Verify your sender

1. In the [SES console](https://console.aws.amazon.com/ses/home#/identities)
   verify your domain or your sender address. SES refuses mail from an
   identity that is not verified.
2. A new account starts in the SES sandbox and can send to verified
   recipients only.
   [Request production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html)
   before real sending.

### 4. Choose the connection for sending

In Settings → Emails Transactional, select the Amazon SES connection as the one the
site sends with, and send a test email.

### 5. Set up delivery events

This step needs the `phoenix_kit_emails` module.

1. In Settings → Emails Transactional, open **Delivery Event Tracking** and its
   Amazon SES/SQS section.
2. Press **Add account** and choose the connection.
3. Press **Setup Infrastructure**. It creates the two queues, the topic, the
   subscription, the configuration set and its event destination in the
   connection's region, and saves their names.
4. Turn polling on.

### 6. Narrow the key

In the IAM console, replace the setup policy on the user with the **running
policy**. Polling and sending go on working.

## Open and click tracking

The setup publishes eight delivery events: `SEND`, `REJECT`, `BOUNCE`,
`COMPLAINT`, `DELIVERY`, `RENDERING_FAILURE`, `DELIVERY_DELAY` and
`SUBSCRIPTION`.

It does not publish `OPEN` and `CLICK` unless asked to. With those two on, SES
adds a tracking pixel to every message and rewrites every link in it to pass
through its own redirect host. That includes the links of sign-in,
confirmation and password-reset mail, with their tokens.

**A site set up before this changed** has both on. To turn them off, open the
[SES console](https://console.aws.amazon.com/ses/home#/configuration-sets),
choose the configuration set `<project>-emailing`, open Event destinations,
edit `email-events-to-sns` and untick **Opens** and **Clicks**. PhoenixKit
never changes an event destination that already exists.

## Queue settings

The setup creates the queues with these values:

| | Queue | Dead-letter queue |
|---|---|---|
| Visibility timeout | 10 minutes | 1 minute |
| Message retention | 14 days | 14 days |
| Moves to the dead-letter queue after | 3 failed reads | |

Polling interval, messages per poll and the visibility timeout used while
reading are set under SQS Worker Tuning in the same settings section.

## Troubleshooting

**"Invalid credentials" on Test Connection.** The access key ID or the secret
is wrong, or the key was deleted or deactivated in IAM.

**"Credentials are valid, but not authorised for GetSendQuota".** The key
works but has no `ses:GetSendQuota`. Sending is unaffected; add the action if
you want the quota shown.

**The setup fails with AccessDenied or "not authorized to perform".** The key
lacks an action of the setup policy; AWS names it in the message. Attach the
setup policy and run the setup again.

**The setup fails although the policy is attached.** Check that `<region>` and
`<project>` in your policy match the connection's region and your project
name. A policy written for another region or another name matches none of the
resources.

**Events stop arriving after the key was narrowed.** The running policy names
the two queues. If they were created under an earlier project title, the
policy must carry the names they have: each account under Delivery Event
Tracking shows them.

**Mail is sent but no event arrives.** Check that polling is on, that the
message was sent with the configuration set (the account must be the one that
sends), and in the SNS console that the topic has a confirmed subscription to
the queue.

## AWS documentation

- [SES Developer Guide](https://docs.aws.amazon.com/ses/latest/dg/Welcome.html)
- [SQS Developer Guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html)
- [SNS Developer Guide](https://docs.aws.amazon.com/sns/latest/dg/welcome.html)
- [Actions, resources and condition keys for Amazon SES](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonses.html)
