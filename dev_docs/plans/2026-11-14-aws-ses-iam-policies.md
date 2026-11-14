# One answer to "what IAM policy does the SES key need?"

Status: proposed (2026-11-14), **verified against `main` the same day**
(core `ea9f60ff3`, `phoenix_kit_emails` 0.8.0 `dd32ca6`). Written from fotki.ee
while setting up SES delivery events. Line numbers below are `main`'s. What the
check changed is listed in "Verified against main" at the end.

## Why

People set up the Amazon SES connection and ask which IAM policy to attach.
Core gives seven different answers, and none of them is right:

| Where | What it says | Problem |
|---|---|---|
| Integrations → Amazon SES instructions (`lib/phoenix_kit/integrations/providers.ex:1149`) | `ses:SendEmail` / `ses:SendRawEmail` only | Sending works. **Setup Infrastructure** and SQS polling then fail with AccessDenied, and nothing says that up front |
| `PhoenixKit.AWS.CredentialsVerifier.check_permissions/3` and `PhoenixKitWeb.Components.Core.AwsCredentialsVerify` (line 223) | probes `sqs:ListQueues`, `sns:ListTopics`, `ses:ListConfigurationSets`, `ec2:DescribeRegions`; the component warns "Missing Critical Permissions" when one is denied | Nothing the product does needs these four. The component is rendered nowhere, but the probes still run on every **Test Connection** (`Integrations.Validators.enrich_fact/2`), which shows "management API: SES, SQS, SNS" for a key that has the List actions. That reads as a goal, so operators add them |
| `guides/aws-email-setup.md`, "Understanding AWS Permissions" (lines 99–127) | a third list: adds `sqs:GetQueueAttributes`, `sns:SetTopicAttributes` | Neither is called |
| `Integrations.Validators` moduledoc and comments (lines 18, 160, 535) | "least privilege: `ses:SendEmail` only" | The send path calls `SendRawEmail`; a `SendEmail`-only key cannot send |
| `README.md:464` and `lib/phoenix_kit/install/mailer_config.ex:354` (generated into the host's config) | `ses:*` | Far broader than anything uses |
| `guides/aws-email-setup.md`, Quick Start (lines 28–45) | `sqs:*`, `sns:*`, `ses:*`, `ec2:DescribeRegions` | Far broader than anything uses |
| same guide, "Minimal Required Permissions" (lines 133–194) | actions scoped to `arn:aws:sqs:*:*:phoenixkit-*` and `arn:aws:sns:*:*:phoenixkit-*` | **Wrong**: setup names resources `<project>-email-*` from the project title (`fotki-email-queue`), so this policy makes setup fail. The guide also describes an "AWS Configuration" section of `/admin/settings/emails` that no longer exists |

Result seen on one site: three different policies handed out over time
(send-only; a ~17-action mix of the List probes, `ec2:DescribeRegions` and
`GetSendQuota`; a hand-derived one).

## What the code actually calls (the source of truth)

| Phase | Caller | AWS action (IAM name) |
|---|---|---|
| Send | `Swoosh.Adapters.AmazonSES` (`@action "SendRawEmail"`) | `ses:SendRawEmail` |
| Connection check | `PhoenixKit.Integrations.Validators` (SES) | `ses:GetSendQuota`. Optional: if it is denied, the check passes with a note |
| Setup | `PhoenixKit.AWS.InfrastructureSetup.run/1` step 1 | `sts:GetCallerIdentity` (needs no permission) |
| Setup | steps 2 and 5, plus `handle_existing_queue/4` | `sqs:CreateQueue`, `sqs:GetQueueUrl` |
| Setup | steps 3 and 6 | `sqs:SetQueueAttributes` |
| Setup | step 4 | `sns:CreateTopic` |
| Setup | step 7 | `sns:Subscribe` |
| Setup | step 8 (`PhoenixKit.AWS.SESv2`) | `ses:CreateConfigurationSet` |
| Setup | step 9 | `ses:CreateConfigurationSetEventDestination` |
| Running | `phoenix_kit_emails`: `SQSPollingJob`, `Emails` | `sqs:ReceiveMessage` (main queue and DLQ), `sqs:DeleteMessage` (main queue only; the DLQ is read, never emptied) |
| Optional probes | `CredentialsVerifier.check_permissions/3`, run by every Test Connection | `sqs:ListQueues`, `sns:ListTopics`, `ses:ListConfigurationSets`, `ec2:DescribeRegions` |

Nothing calls `ChangeMessageVisibility`, `GetQueueAttributes`, `Delete*`,
`Update*`, `DescribeConfigurationSets` or `ListSubscriptions`.

The resource names come from `InfrastructureSetup`:

- `<p>-email-dlq` and `<p>-email-queue` (SQS)
- `<p>-email-events` (SNS)
- `<p>-emailing` (SES configuration set)

`<p>` is the project title, sanitised. The emails package derives it in
`amazon_ses_sqs.ex` `project_name/0`: lower-case it and replace anything
outside `[a-z0-9-]` with `-`. `InfrastructureSetup` then sanitises it again.

S3 archival (`Emails.Archiver`) uses a storage connection, not the SES key, so
it is out of scope here.

## Decision: two policies, shown as two steps

The key needs more permissions while infrastructure is being created than it
does afterwards. Show both, in this order:

**1. Setup policy.** Attach it before creating the connection, and keep it
until Setup Infrastructure has worked:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Send",
      "Effect": "Allow",
      "Action": ["ses:SendRawEmail", "ses:SendEmail", "ses:GetSendQuota"],
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
        "arn:aws:ses:<region>:*:configuration-set/<p>-emailing",
        "arn:aws:sns:<region>:*:<p>-email-events",
        "arn:aws:sqs:<region>:*:<p>-email-*"
      ]
    },
    {
      "Sid": "ReadDeliveryEvents",
      "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage"],
      "Resource": "arn:aws:sqs:<region>:*:<p>-email-*"
    }
  ]
}
```

**2. Running policy.** Once setup has succeeded, replace the setup policy with
this one, which is the setup policy without `SetupInfrastructure`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Send",
      "Effect": "Allow",
      "Action": ["ses:SendRawEmail", "ses:SendEmail", "ses:GetSendQuota"],
      "Resource": "*"
    },
    {
      "Sid": "ReadDeliveryEvents",
      "Effect": "Allow",
      "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage"],
      "Resource": "arn:aws:sqs:<region>:*:<p>-email-*"
    }
  ]
}
```

Notes for the wording shown to users:

- **A site that only sends**, with no delivery events, needs only the
  `Send` statement. Say so. The Running policy is also correct for it, since
  the SQS statement covers queues that don't exist yet.
- **Re-running Setup Infrastructure** needs the setup policy again. Setup is
  idempotent, so attaching the policy and clicking again is safe. Its
  AccessDenied error should say this (see 3 below).
- **`ses:SendEmail` is not called today.** It is kept so that a move to the
  SES v2 send API doesn't break every installed key.
- **The `SetupInfrastructure` ARNs are valid per AWS's reference.** Both
  `ses:CreateConfigurationSet` and `ses:CreateConfigurationSetEventDestination`
  take the `configuration-set` resource
  (`arn:aws:ses:<region>:<account>:configuration-set/<name>`), and every SQS
  and SNS action in the policy takes a queue or topic ARN. The real-account
  run in step 6 still confirms it. `GetSendQuota` takes no resource, and
  `SendRawEmail` is authorised against the sending **identity** as well as the
  configuration set, so the `Send` statement must stay on `"*"`.
- **If the project title changes, the resource names change.** Then the
  policy no longer matches the queues that already exist. Either keep the
  names that were used, or show the names actually saved in the account's
  tracking settings (`Emails.set_aws_tracking/2` has them).
- **The probes are optional.** Leave `sqs:ListQueues`, `sns:ListTopics`,
  `ses:ListConfigurationSets` and `ec2:DescribeRegions` out of both
  policies.

## Build

### 1. One module builds both policies: `PhoenixKit.AWS.IamPolicy`

- `setup(project: p, region: r)` and `running(project: p, region: r)` return
  maps. `json/1` pretty-prints them.
- **One function for resource names.** Move the names out of
  `InfrastructureSetup` into one function used by both setup and this
  module, e.g. `PhoenixKit.AWS.InfrastructureSetup.resource_names/1` returning
  `%{dlq:, queue:, topic:, configuration_set:}`. Setup and policy then cannot
  drift apart.
- **Move the project-name derivation into core.** It is now duplicated
  between `amazon_ses_sqs.ex` `project_name/0` (emails) and
  `InfrastructureSetup.sanitize_project_name/1`. The emails package calls
  core's version.
- **Each action list sits next to its call site**, as a module attribute
  (`@iam_actions`) in `InfrastructureSetup` and its peers. `IamPolicy` reads
  these lists.
- **Tests:**
  - every action `InfrastructureSetup` declares is in `setup/1`;
  - `running/1` is `setup/1` minus `SetupInfrastructure`;
  - the resource ARNs match `resource_names/1` for a few titles (`"Fotki"`,
    `"My App!"`, `"myapp"`).

### 2. Show both policies where people need them

- **Integrations → Amazon SES instructions** (`providers.ex`): replace the
  send-only step with the two-step text:
  - "Attach the **setup policy**, create the key; after **Setup
    Infrastructure** has run in Settings → Email Sending, replace it with
    the **running policy**."
  - Both policies are shown in collapsible code blocks with a copy button,
    filled in with this site's project name and the connection's region. If
    no region is set yet, show `<region>`.
- **The Amazon SES/SQS panel** (`phoenix_kit_emails`,
  `web/settings_sections/amazon_ses_sqs.html.heex`):
  - next to **Setup Infrastructure**: the setup policy, collapsed;
  - after a successful setup, change the success flash or the account row
    to: "Infrastructure created. You can now narrow the key to the running
    policy", with that policy.

### 3. Errors that name the policy

- In `amazon_ses_sqs.ex` `run_account_setup/2`, an
  `{:error, step, reason}` whose reason is AccessDenied should say three
  things:
  - which action was missing (AWS names it in the message);
  - that this is the setup policy;
  - the policy itself.
- The SQS poller already reports failures in the tracker row. An
  AccessDenied there should point to the running policy.

### 4. Make the "Verify credentials" probes optional

- **Delete `AwsCredentialsVerify`.** Nothing on `main` renders it, in core
  or in `phoenix_kit_emails`. Its gettext strings go with it.
- **Delete `CredentialsVerifier.get_available_regions/3`** and its EC2
  helpers. Nothing calls it.
- **`check_permissions/3` cannot simply be deleted**: `Validators.enrich_fact/2`
  calls it on every Test Connection and `aws_note/2` (tested in
  `validators_test.exs`) turns the result into "management API: SES, SQS,
  SNS". Replace that note with one that reports what matters: the account id
  (STS, already there) and nothing about List actions. Then delete
  `check_permissions/3`. Test Connection stops making four calls whose
  denial means nothing.

### 5. Rewrite the guide's IAM section

`guides/aws-email-setup.md`:

- **Delete both old policies** (the `sqs:*`/`ses:*` one and the
  `phoenixkit-*` one).
- **In their place:**
  - the two-step explanation;
  - both policies, with `<project>`/`<region>` placeholders and how
    `<project>` is derived;
  - the action/caller table above.
- **Update the steps to the current UI:** Settings → Integrations for the
  key, then Settings → Email Sending → Delivery Event Tracking → Amazon
  SES/SQS → Add account → Setup Infrastructure → polling on.
- **Fix `install/mailer_config.ex:354` and `README.md:464`**, both
  `ses:*`, so they point to the guide.
- **Fix the `Validators` moduledoc and comments** (lines 18, 160, 535):
  the send-only key is `ses:SendRawEmail`, not `ses:SendEmail`.
- **Fix the `InfrastructureSetup` moduledoc**: "All necessary IAM policies"
  means the two queue access policies, not the key's policy.
- **Remove the dead links** at the end of the guide
  (`/docs/EMAIL_CONFIGURATION.md` and two more that do not exist).

### 6. Check against real AWS once

Use a throwaway IAM user in a test account:

1. With the setup policy, **Setup Infrastructure succeeds**.
2. Running it again also succeeds, showing it is idempotent.
3. Swap to the running policy. **Polling still works** and a send works.
4. With the running policy, Setup Infrastructure fails with an AccessDenied
   that names the setup policy.

Record the result, including the `CreateConfigurationSet` resource question,
in a `dev_docs/reports/` file.

## Related, worth deciding in the same pass

`PhoenixKit.AWS.SESv2.create_configuration_set_event_destination/4`
subscribes to **OPEN and CLICK** as well. Enabling those makes SES:

- add a tracking pixel;
- rewrite **every link** through `awstrack.me`, including confirmation,
  magic-link and password-reset links with their tokens.

That is a privacy and token-exposure cost that most sites don't want for
auth mail. Suggest one of:

- leave OPEN and CLICK out by default, behind a setting;
- or mark auth-mail links with `ses:no-track`.

Either way, the guide should tell existing installs how to untick them on
the event destination.

## Verified against main (2026-11-14)

Checked against core `ea9f60ff3` and `phoenix_kit_emails` 0.8.0 (`dd32ca6`),
and against AWS's IAM service reference
(`servicereference.us-east-1.amazonaws.com/v1/{ses,sqs,sns,sts}`). Nothing was
run against a real AWS account; step 6 is still owed.

**Confirmed as written:**

- The action/caller table. These are the only AWS calls outside storage and
  the S3 key store: nine setup steps, `GetSendQuota`, `SendRawEmail` (Swoosh
  `@action`), `ReceiveMessage` and `DeleteMessage`.
- Nothing calls `ChangeMessageVisibility`, `GetQueueAttributes`, `Delete*`,
  `Update*`, `DescribeConfigurationSets`, `ListSubscriptions` or
  `SetTopicAttributes`.
- The resource names, and that the guide's `phoenixkit-*` ARNs match none of
  them.
- The project-name derivation is duplicated: `amazon_ses_sqs.ex:535` in the
  emails package and `InfrastructureSetup.sanitize_project_name/1` in core,
  the same three steps.
- The guide's "AWS Configuration" section and "Verify Credentials" button no
  longer exist.
- `SESv2` subscribes to OPEN and CLICK; no code sets `ses:no-track`.

**Corrected in this copy:**

- Seven conflicting answers, not four (three rows added to the table).
- The probes do run in production: on every Test Connection, through
  `Validators.enrich_fact/2`. Step 4 is rewritten for that.
- `AwsCredentialsVerify` is unused on `main` too, so it is deleted, not
  reworded.
- The DLQ is only read; `DeleteMessage` is for the main queue.
- The configuration-set ARN question is answered by the reference.

**Found while checking, to fix in the same pass:**

1. **Step 7 hides a missing `sns:Subscribe`.** `step_7_subscribe_sqs_to_sns/3`
   turns every error into `{:ok, "existing"}`. A key without `sns:Subscribe`
   gets a green setup, a saved account and a queue that never receives an
   event. `Subscribe` is idempotent on AWS, so no error needs swallowing:
   return the error like the other steps.
2. **A title with no ASCII letters gives an empty project name.** `"Фотки"`
   sanitises to `""`, and setup creates `-email-queue`, `-email-events`,
   `-emailing`. The shared name function must refuse an empty result (or fall
   back to `myapp`, as an unset title does), and the policy must be built from
   the same value.
3. **The names saved by setup are the truth for the running policy.** The
   tracking row holds `queue_arn`, `dlq_url`, `sns_topic_arn`,
   `configuration_set` and `region`. Build the running policy shown after
   setup from those, not from the current title. That also covers installs set
   up under an older title and the legacy global `aws_*` settings.
4. **`phoenix_kit_emails` has uncommitted work** in ten files (not in
   `amazon_ses_sqs.ex`). The emails half of this plan waits for that, or goes
   in after it.
5. **Release order.** The emails package can call core's `IamPolicy` and name
   function only on a core that has them: feature-detect, as for
   `Activity.log/3`, and keep its own derivation as the fallback.
6. **Strings.** The new instructions and errors are gettext entries in ten
   locales; core's and the emails package's catalogues both change.

