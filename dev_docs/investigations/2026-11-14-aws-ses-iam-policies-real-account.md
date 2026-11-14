# Amazon SES IAM policies: check against a real AWS account

Date: 2026-11-14. Plan: `dev_docs/plans/2026-11-14-aws-ses-iam-policies.md`
(phase 2). Core at `32091a6cf` (phase 1 is `14fa4ddeb`).

## Result

The setup policy and the running policy built by `PhoenixKit.AWS.IamPolicy`
are sufficient and no wider than needed for what was exercised. Every check
passed.

## How it was run

- A throwaway IAM user in a real account, region `eu-north-1`, with a verified
  sender. The account is out of the SES sandbox.
- Dmitri attached each policy by hand as the user's only inline policy; the
  policies were the module's output for the project name `pk-iam-verify`,
  pasted unchanged.
- The calls were made from a script through core's own code:
  `InfrastructureSetup.run/1`, `Swoosh.Adapters.AmazonSES.deliver/2` with the
  configuration set, `Integrations.Validators.aws_ses/1`, and
  `ExAws.SQS.receive_message` / `delete_message` (the two calls the emails
  package's poller makes). The poller itself and the admin UI were not used.
- Mail went to `success@simulator.amazonses.com`.

## Checks

| # | Policy attached | Action | Expected | Result |
|---|---|---|---|---|
| 1 | setup | setup from scratch | all nine steps succeed | passed |
| 2 | setup | setup again | succeeds, nothing changed | passed |
| 3 | setup | setup for another project name (`pk-iam-check`) | AWS refuses: the policy names exact resources | refused at `sqs:CreateQueue` |
| 4 | setup | send with the configuration set | accepted | passed |
| 5 | setup | read the queue and the dead-letter queue, delete what was read | events arrive and are deleted | Send and Delivery received and deleted; dead-letter queue readable, empty |
| 6 | running | setup | AWS refuses, the error names the setup policy | refused at `sqs:CreateQueue`, with the hint |
| 7 | running | send | accepted | passed |
| 8 | running | read and delete | events arrive and are deleted | Send and Delivery received and deleted |
| 9 | running | Test Connection | passes with the account and the quota | passed: account id and send quota |
| 10 | setup without `sns:Subscribe` | setup | fails at step 7 | failed at `subscribe_sqs_to_sns`, with the hint |

## What this settles

- **The configuration-set ARN is accepted** as the resource of
  `ses:CreateConfigurationSet` and `ses:CreateConfigurationSetEventDestination`
  (check 1). The plan had this from AWS's reference only.
- **`Resource: "*"` on the `Send` statement is enough** to send with a
  configuration set and to read the quota (checks 4, 7, 9).
- **Exact names scope the key**: the same policy could not create another
  project's queue (check 3).
- **Step 7 no longer hides a missing `sns:Subscribe`** (check 10). Before the
  fix this run ended in success with no subscription.
- **A new setup publishes the eight delivery events**, without OPEN and CLICK:
  the setup's own log lists what it sent.
- **SNS reports a refusal as `AuthorizationError`**, not `AccessDenied`.
  `InfrastructureSetup.access_denied?/1` matches it through the "not
  authorized to perform" text; a test now holds that shape.

## Not covered

- The event destination was not read back from AWS (the policies grant no
  read of it), so "no OPEN or CLICK" rests on the request that was sent.
- `track_opens_and_clicks: true` was not run.
- The emails package's poller, its settings panel and the Integrations form
  were not driven; only the AWS calls they make.
- One region, one account, the `aws` partition.
- The first run of the day used a key that still had a broad policy and
  created the `pk-iam-check-*` resources. It proves nothing about the
  policies and is not counted above.

## Cleanup

To delete in `eu-north-1`:

- IAM user `phoenix_kit_temp` (and its access key);
- SQS queues `pk-iam-verify-email-queue`, `pk-iam-verify-email-dlq`,
  `pk-iam-check-email-queue`, `pk-iam-check-email-dlq`;
- SNS topics `pk-iam-verify-email-events`, `pk-iam-check-email-events` (their
  subscriptions go with them);
- SES configuration sets `pk-iam-verify-emailing`, `pk-iam-check-emailing`.
