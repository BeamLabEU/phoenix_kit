defmodule PhoenixKit.AWS.InfrastructureSetup do
  @moduledoc """
  Automated AWS infrastructure setup for email event handling.

  This module creates the complete AWS infrastructure for email event tracking:
  - SNS Topic for email events
  - SQS Dead Letter Queue (DLQ) for failed messages
  - SQS Main Queue with DLQ redrive policy
  - SNS to SQS subscription
  - SES Configuration Set with event destinations
  - The access policies of the two queues (who may send to and read them)

  It does not touch the IAM policy of the key it runs with. What that key
  needs is built by `PhoenixKit.AWS.IamPolicy` from `iam_actions/0` and
  `resource_names/1`, the same values this module creates the resources from.

  ## Usage

      iex> PhoenixKit.AWS.InfrastructureSetup.run(
      ...>   project_name: "myapp",
      ...>   region: "eu-north-1",
      ...>   access_key_id: "AKIA...",
      ...>   secret_access_key: "..."
      ...> )
      {:ok, %{
        "aws_region" => "eu-north-1",
        "aws_sns_topic_arn" => "arn:aws:sns:...",
        "aws_sqs_queue_url" => "https://sqs...",
        ...
      }}

  ## Configuration Options

  - `:project_name` - Project name used as prefix for resources (required)
  - `:region` - AWS region (default: "eu-north-1")
  - `:access_key_id` - AWS access key ID (required)
  - `:secret_access_key` - AWS secret access key (required)
  - `:queue_visibility_timeout` - Main queue visibility timeout in seconds (default: 600 / 10 minutes)
  - `:queue_retention` - Message retention period in seconds (default: 1209600 / 14 days)
  - `:max_receive_count` - Max retries before DLQ (default: 3)
  - `:polling_interval_ms` - SQS polling interval in milliseconds (default: 5000)
  - `:track_opens_and_clicks` - Also publish OPEN and CLICK events (default: false).
    With them on, SES adds a tracking pixel to every message and rewrites every
    link through its own redirect host, sign-in and password-reset links included.

  ## Queue Configuration (Optimized for Email Events)

  **Main Queue:**
  - Visibility Timeout: 10 minutes - Allows complex database operations without message redelivery
  - Message Retention: 14 days - Protects against extended outages (weekends, holidays)
  - Max Receive Count: 3 attempts - Balances retry attempts with DLQ routing

  **Dead Letter Queue:**
  - Visibility Timeout: 1 minute - For manual processing and troubleshooting
  - Message Retention: 14 days - Allows thorough analysis of failed messages

  ## Return Values

  - `{:ok, config_map}` - Successfully created infrastructure
  - `{:error, step, reason}` - Failed at specific step with reason
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias ExAws.SNS
  alias ExAws.SQS
  alias ExAws.STS
  alias PhoenixKit.AWS.SESv2
  alias PhoenixKit.Config.AWS
  alias PhoenixKit.Settings

  @dialyzer {:nowarn_function,
             step_2_create_dlq: 2,
             step_3_set_dlq_policy: 4,
             step_4_create_sns_topic: 1,
             step_5_create_main_queue: 3,
             step_6_set_main_queue_policy: 5,
             step_7_subscribe_sqs_to_sns: 3,
             step_8_create_ses_config_set: 1,
             step_9_configure_ses_events: 3}

  # Queue configuration optimized for email event processing
  # 10 minutes - allows complex DB operations without message redelivery
  @default_visibility_timeout 600
  # 14 days - protects against extended outages (weekends, holidays)
  @default_retention 1_209_600
  @default_max_receive_count 3
  @default_polling_interval 5000

  # Dead Letter Queue configuration
  @default_dlq_visibility_timeout 60
  # 14 days - allows troubleshooting of failed messages
  @default_dlq_retention 1_209_600

  # What an unset project title gives, and what a title with no ASCII letter
  # or digit falls back to.
  @default_project_name "myapp"

  # The IAM actions `run/1` needs, by the kind of resource each is granted on.
  # Keep this next to the steps: a call added below without its action here
  # leaves the setup policy short (`PhoenixKit.AWS.IamPolicy`).
  @iam_actions %{
    # steps 2, 3, 5, 6 and `handle_existing_queue/4`
    queue: ["sqs:CreateQueue", "sqs:GetQueueUrl", "sqs:SetQueueAttributes"],
    # steps 4 and 7
    topic: ["sns:CreateTopic", "sns:Subscribe"],
    # steps 8 and 9
    configuration_set: [
      "ses:CreateConfigurationSet",
      "ses:CreateConfigurationSetEventDestination"
    ]
  }

  @doc """
  The IAM actions `run/1` calls, keyed by the resource they are granted on
  (`:queue`, `:topic`, `:configuration_set`).

  Step 1 (`sts:GetCallerIdentity`) is not listed: AWS allows it to every key.
  """
  @spec iam_actions() :: %{atom() => [String.t()]}
  def iam_actions, do: @iam_actions

  @doc """
  The name AWS resources are prefixed with, from the site's project title.

  Lower-cased, with everything outside `[a-z0-9-]` turned into `-`. A title
  that leaves nothing (unset, or with no ASCII letter or digit) gives
  `"#{@default_project_name}"`.

      iex> PhoenixKit.AWS.InfrastructureSetup.project_name("My App!")
      "my-app"

      iex> PhoenixKit.AWS.InfrastructureSetup.project_name("Фотки")
      "myapp"
  """
  @spec project_name() :: String.t()
  def project_name do
    project_name(Settings.get_setting("project_title", @default_project_name))
  end

  @spec project_name(term()) :: String.t()
  def project_name(title) when is_binary(title) do
    name =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    if name == "", do: @default_project_name, else: name
  end

  def project_name(_title), do: @default_project_name

  @doc """
  The names `run/1` gives the resources of a project.

      iex> PhoenixKit.AWS.InfrastructureSetup.resource_names("Fotki")
      %{
        dlq: "fotki-email-dlq",
        queue: "fotki-email-queue",
        topic: "fotki-email-events",
        configuration_set: "fotki-emailing"
      }
  """
  @spec resource_names(term()) :: %{
          dlq: String.t(),
          queue: String.t(),
          topic: String.t(),
          configuration_set: String.t()
        }
  def resource_names(project) do
    name = project_name(project)

    %{
      dlq: "#{name}-email-dlq",
      queue: "#{name}-email-queue",
      topic: "#{name}-email-events",
      configuration_set: "#{name}-emailing"
    }
  end

  @doc """
  Runs the complete AWS infrastructure setup.

  ## Options

  - `:project_name` - Required. Project name for resource naming
  - `:region` - AWS region (default: "eu-north-1")
  - `:access_key_id` - AWS access key (falls back to settings/env)
  - `:secret_access_key` - AWS secret key (falls back to settings/env)
  - `:track_opens_and_clicks` - Publish OPEN and CLICK events too (default: false)

  ## Examples

      iex> run(project_name: "myapp", region: "eu-north-1")
      {:ok, %{"aws_sns_topic_arn" => "arn:aws:sns:...", ...}}

      iex> run(project_name: "test")
      {:error, "get_account_id", "Invalid credentials"}
  """
  def run(opts) do
    project_name = Keyword.fetch!(opts, :project_name)
    region = Keyword.get(opts, :region, AWS.region())

    # Get AWS credentials
    access_key_id =
      Keyword.get(opts, :access_key_id) ||
        Settings.get_setting("aws_access_key_id") || AWS.access_key_id() || nil

    secret_access_key =
      Keyword.get(opts, :secret_access_key) ||
        Settings.get_setting("aws_secret_access_key") || AWS.secret_access_key() || nil

    unless access_key_id && secret_access_key do
      return_error("validation", "AWS credentials not found. Please configure them first.")
    end

    # Build configuration
    config = %{
      project_name: project_name(project_name),
      names: resource_names(project_name),
      track_opens_and_clicks: Keyword.get(opts, :track_opens_and_clicks, false) == true,
      region: region,
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      queue_visibility_timeout:
        Keyword.get(opts, :queue_visibility_timeout, @default_visibility_timeout),
      queue_retention: Keyword.get(opts, :queue_retention, @default_retention),
      max_receive_count: Keyword.get(opts, :max_receive_count, @default_max_receive_count),
      polling_interval_ms: Keyword.get(opts, :polling_interval_ms, @default_polling_interval),
      dlq_visibility_timeout: @default_dlq_visibility_timeout,
      dlq_retention: @default_dlq_retention
    }

    Logger.info("[AWS Setup] Starting infrastructure setup for project: #{config.project_name}")

    with {:ok, account_id} <- step_1_get_account_id(config),
         {:ok, dlq_url, dlq_arn} <- step_2_create_dlq(config, account_id),
         :ok <- step_3_set_dlq_policy(config, dlq_url, dlq_arn, account_id),
         {:ok, sns_topic_arn} <- step_4_create_sns_topic(config),
         {:ok, queue_url, queue_arn} <- step_5_create_main_queue(config, account_id, dlq_arn),
         :ok <-
           step_6_set_main_queue_policy(config, queue_url, queue_arn, sns_topic_arn, account_id),
         {:ok, _subscription_arn} <-
           step_7_subscribe_sqs_to_sns(config, sns_topic_arn, queue_arn),
         {:ok, config_set_name} <- step_8_create_ses_config_set(config),
         :ok <- step_9_configure_ses_events(config, config_set_name, sns_topic_arn) do
      result_config = %{
        "aws_region" => region,
        "aws_sns_topic_arn" => sns_topic_arn,
        "aws_sqs_queue_url" => queue_url,
        "aws_sqs_queue_arn" => queue_arn,
        "aws_sqs_dlq_url" => dlq_url,
        "aws_ses_configuration_set" => config_set_name,
        "sqs_polling_interval_ms" => Integer.to_string(config.polling_interval_ms)
      }

      Logger.info("[AWS Setup] ✅ Infrastructure setup completed successfully!")
      {:ok, result_config}
    else
      {:error, step, reason} ->
        Logger.error("[AWS Setup] ❌ Failed at step: #{step}. Reason: #{reason}")
        {:error, step, with_policy_hint(reason)}
    end
  end

  @doc """
  Whether a setup failure is AWS refusing the key a permission.

  Such a failure is cured by attaching the setup policy
  (`PhoenixKit.AWS.IamPolicy.setup/1`) and running setup again.
  """
  @spec access_denied?(term()) :: boolean()
  def access_denied?(reason) when is_binary(reason) do
    String.contains?(reason, ["AccessDenied", "not authorized to perform"])
  end

  def access_denied?(_reason), do: false

  defp with_policy_hint(reason) do
    if access_denied?(reason) do
      reason <>
        " — " <>
        gettext(
          "The key lacks a permission of the setup policy. Attach the setup policy to the key (it is shown with the Amazon SES connection in Settings → Integrations) and run the setup again: it is safe to repeat."
        )
    else
      reason
    end
  end

  # Step 1: Get AWS Account ID
  defp step_1_get_account_id(config) do
    Logger.info("[AWS Setup] [1/9] Getting AWS Account ID...")

    case STS.get_caller_identity()
         |> ExAws.request(aws_config(config)) do
      {:ok, %{body: body}} ->
        # Handle both sweet_xml parsed (atom keys) and raw XML (string keys) responses
        account_id = body[:account] || body["account"]

        if account_id do
          Logger.info("[AWS Setup]   ✓ Account ID: #{account_id}")
          {:ok, account_id}
        else
          return_error(
            "get_account_id",
            "Could not parse account ID from response: #{inspect(body)}"
          )
        end

      {:error, reason} ->
        return_error("get_account_id", "Failed to get AWS Account ID: #{inspect(reason)}")
    end
  end

  # Step 2: Create Dead Letter Queue (DLQ)
  defp step_2_create_dlq(config, account_id) do
    Logger.info("[AWS Setup] [2/9] Creating Dead Letter Queue...")

    dlq_name = config.names.dlq

    case SQS.create_queue(dlq_name,
           visibility_timeout: Integer.to_string(config.dlq_visibility_timeout),
           message_retention_period: Integer.to_string(config.dlq_retention),
           sqs_managed_sse_enabled: "true"
         )
         |> ExAws.request(aws_config(config)) do
      {:ok, body} ->
        dlq_url = get_queue_url_from_response(body)
        dlq_arn = "arn:aws:sqs:#{config.region}:#{account_id}:#{dlq_name}"
        Logger.info("[AWS Setup]   ✓ DLQ Created")
        Logger.info("[AWS Setup]     URL: #{dlq_url}")
        Logger.info("[AWS Setup]     ARN: #{dlq_arn}")
        {:ok, dlq_url, dlq_arn}

      {:error, {"QueueNameExists", _message}} ->
        handle_existing_queue(dlq_name, account_id, config, "DLQ")

      {:error, reason} ->
        return_error("create_dlq", inspect(reason))
    end
  end

  # Step 3: Set DLQ Policy
  defp step_3_set_dlq_policy(config, dlq_url, dlq_arn, account_id) do
    Logger.info("[AWS Setup] [3/9] Setting DLQ policy...")

    policy = %{
      "Version" => "2012-10-17",
      "Id" => "__default_policy_ID",
      "Statement" => [
        %{
          "Sid" => "__owner_statement",
          "Effect" => "Allow",
          "Principal" => %{
            "AWS" => "arn:aws:iam::#{account_id}:root"
          },
          "Action" => "SQS:*",
          "Resource" => dlq_arn
        }
      ]
    }

    policy_json = JSON.encode!(policy)

    case SQS.set_queue_attributes(dlq_url, policy: policy_json)
         |> ExAws.request(aws_config(config)) do
      {:ok, _} ->
        Logger.info("[AWS Setup]   ✓ DLQ Policy set")
        :ok

      {:error, reason} ->
        return_error("set_dlq_policy", inspect(reason))
    end
  end

  # Step 4: Create SNS Topic
  defp step_4_create_sns_topic(config) do
    Logger.info("[AWS Setup] [4/9] Creating SNS Topic...")

    topic_name = config.names.topic

    case SNS.create_topic(topic_name)
         |> ExAws.request(aws_config(config)) do
      {:ok, %{body: body}} ->
        # Handle both sweet_xml parsed (atom keys) and raw XML (string keys) responses
        topic_arn = body[:topic_arn] || body["TopicArn"] || body["topic_arn"]

        Logger.info("[AWS Setup]   ✓ SNS Topic Created/Found")
        Logger.info("[AWS Setup]     ARN: #{topic_arn}")
        {:ok, topic_arn}

      {:error, reason} ->
        return_error("create_sns_topic", inspect(reason))
    end
  end

  # Step 5: Create Main Queue with Redrive Policy
  defp step_5_create_main_queue(config, account_id, dlq_arn) do
    Logger.info("[AWS Setup] [5/9] Creating Main Queue with DLQ redrive policy...")

    queue_name = config.names.queue

    redrive_policy = %{
      "deadLetterTargetArn" => dlq_arn,
      "maxReceiveCount" => config.max_receive_count
    }

    case SQS.create_queue(queue_name,
           visibility_timeout: Integer.to_string(config.queue_visibility_timeout),
           message_retention_period: Integer.to_string(config.queue_retention),
           receive_message_wait_time_seconds: "20",
           redrive_policy: JSON.encode!(redrive_policy),
           sqs_managed_sse_enabled: "true"
         )
         |> ExAws.request(aws_config(config)) do
      {:ok, body} ->
        queue_url = get_queue_url_from_response(body)
        queue_arn = "arn:aws:sqs:#{config.region}:#{account_id}:#{queue_name}"
        Logger.info("[AWS Setup]   ✓ Main Queue Created")
        Logger.info("[AWS Setup]     URL: #{queue_url}")
        Logger.info("[AWS Setup]     ARN: #{queue_arn}")
        {:ok, queue_url, queue_arn}

      {:error, {"QueueNameExists", _message}} ->
        handle_existing_queue(queue_name, account_id, config, "Main Queue")

      {:error, reason} ->
        return_error("create_main_queue", inspect(reason))
    end
  end

  # Step 6: Set Main Queue Policy
  defp step_6_set_main_queue_policy(config, queue_url, queue_arn, sns_topic_arn, account_id) do
    Logger.info("[AWS Setup] [6/9] Setting Main Queue policy to allow SNS and account access...")

    policy = %{
      "Version" => "2012-10-17",
      "Id" => "#{config.project_name}-sqs-policy",
      "Statement" => [
        %{
          "Sid" => "AllowSNSPublish",
          "Effect" => "Allow",
          "Principal" => %{
            "Service" => "sns.amazonaws.com"
          },
          "Action" => "SQS:SendMessage",
          "Resource" => queue_arn,
          "Condition" => %{
            "ArnEquals" => %{
              "aws:SourceArn" => sns_topic_arn
            }
          }
        },
        %{
          "Sid" => "AllowAccountAccess",
          "Effect" => "Allow",
          "Principal" => %{
            "AWS" => "arn:aws:iam::#{account_id}:root"
          },
          "Action" => [
            "SQS:ReceiveMessage",
            "SQS:DeleteMessage",
            "SQS:GetQueueAttributes",
            "SQS:SendMessage"
          ],
          "Resource" => queue_arn
        }
      ]
    }

    policy_json = JSON.encode!(policy)

    case SQS.set_queue_attributes(queue_url, policy: policy_json)
         |> ExAws.request(aws_config(config)) do
      {:ok, _} ->
        Logger.info("[AWS Setup]   ✓ Main Queue Policy set")
        :ok

      {:error, reason} ->
        return_error("set_main_queue_policy", inspect(reason))
    end
  end

  # Step 7: Subscribe SQS to SNS
  defp step_7_subscribe_sqs_to_sns(config, sns_topic_arn, queue_arn) do
    Logger.info("[AWS Setup] [7/9] Creating SNS subscription to SQS...")

    case SNS.subscribe(sns_topic_arn, "sqs", queue_arn)
         |> ExAws.request(aws_config(config)) do
      {:ok, %{body: body}} ->
        # Handle both sweet_xml parsed (atom keys) and raw XML (string keys) responses
        subscription_arn =
          body[:subscription_arn] || body["SubscriptionArn"] || body["subscription_arn"]

        Logger.info("[AWS Setup]   ✓ SNS → SQS Subscription created")

        if subscription_arn && subscription_arn != "pending confirmation" do
          Logger.info("[AWS Setup]     Subscription ARN: #{subscription_arn}")
        end

        {:ok, subscription_arn}

      # No error is expected to be harmless here: `Subscribe` answers with the
      # existing subscription when there is one. Passing an error off as
      # "already exists" let a key without `sns:Subscribe` finish the setup
      # with a queue no event would ever reach.
      {:error, reason} ->
        return_error("subscribe_sqs_to_sns", inspect(reason))
    end
  end

  # Step 8: Create SES Configuration Set
  defp step_8_create_ses_config_set(config) do
    Logger.info("[AWS Setup] [8/9] Creating SES Configuration Set...")

    config_set_name = config.names.configuration_set

    case SESv2.create_configuration_set(config_set_name, aws_config(config)) do
      {:ok, ^config_set_name} ->
        Logger.info("[AWS Setup]   ✓ SES Configuration Set created")
        Logger.info("[AWS Setup]     Name: #{config_set_name}")
        {:ok, config_set_name}

      {:error, reason} ->
        return_error("create_ses_config_set", inspect(reason))
    end
  end

  # Step 9: Configure SES Event Tracking
  defp step_9_configure_ses_events(config, config_set_name, sns_topic_arn) do
    Logger.info("[AWS Setup] [9/9] Configuring SES event tracking to SNS...")

    case SESv2.create_configuration_set_event_destination(
           config_set_name,
           "email-events-to-sns",
           sns_topic_arn,
           aws_config(config),
           track_opens_and_clicks: config.track_opens_and_clicks
         ) do
      :ok ->
        Logger.info("[AWS Setup]   ✓ SES Event Tracking configured")

        Logger.info(
          "[AWS Setup]     Events: " <>
            Enum.join(SESv2.event_types(config.track_opens_and_clicks), ", ")
        )

        Logger.info("[AWS Setup]     Destination: #{sns_topic_arn}")
        :ok

      {:error, reason} ->
        return_error("configure_ses_events", inspect(reason))
    end
  end

  # Helper: Build AWS configuration
  defp aws_config(config) do
    [
      access_key_id: String.trim(config.access_key_id),
      secret_access_key: String.trim(config.secret_access_key),
      region: String.trim(config.region)
    ]
  end

  # Helper: Extract queue URL from a CreateQueue/GetQueueUrl response.
  # SQS's JSON protocol (beamlab_ex_aws_sqs) returns the raw AWS response
  # map keyed exactly as documented ("QueueUrl") — no atom/snake_case
  # normalization layer, unlike SNS/STS below which still go through
  # sweet_xml's Query/XML parsing.
  defp get_queue_url_from_response(body) when is_map(body) do
    body["QueueUrl"]
  end

  # Helper: Handle existing queue scenario (idempotent setup)
  defp handle_existing_queue(queue_name, account_id, config, queue_type) do
    case SQS.get_queue_url(queue_name) |> ExAws.request(aws_config(config)) do
      {:ok, body} ->
        queue_url = get_queue_url_from_response(body)
        region = config.region
        queue_arn = "arn:aws:sqs:#{region}:#{account_id}:#{queue_name}"
        Logger.info("[AWS Setup]   ✓ #{queue_type} Found (already exists)")
        Logger.info("[AWS Setup]     URL: #{queue_url}")
        {:ok, queue_url, queue_arn}

      {:error, reason} ->
        return_error(
          "get_existing_queue",
          "Failed to get existing #{queue_type}: #{inspect(reason)}"
        )
    end
  end

  # Helper: Return error tuple
  defp return_error(step, reason), do: {:error, step, reason}
end
