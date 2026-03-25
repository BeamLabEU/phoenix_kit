defmodule PhoenixkitEu.AWSInfrastructureSetup do
  @moduledoc """
  AWS Infrastructure Setup compatible with ExAws + sweet_xml.

  This module works around the PhoenixKit 1.4.4 incompatibility with sweet_xml
  by handling the parsed XML responses (atom keys) instead of raw nested XML (string keys).
  """

  require Logger

  alias ExAws.{STS, SNS, SQS}
  alias PhoenixKit.Settings

  @doc """
  Runs AWS infrastructure setup and saves results to database.

  ## Options
  - `:project_name` - Project name (default: from settings or "PhoenixKit")
  - `:region` - AWS region (default: from settings or "eu-north-1")
  - `:access_key_id` - AWS access key (default: from settings)
  - `:secret_access_key` - AWS secret key (default: from settings)

  ## Returns
  - `{:ok, config_map}` - Successfully created infrastructure
  - `{:error, step, reason}` - Failed at specific step
  """
  def run(opts \\ []) do
    # Get configuration
    project_name =
      Keyword.get(opts, :project_name) ||
        Settings.get_setting("project_title", "PhoenixKit")

    project_name = sanitize_project_name(project_name)

    region =
      Keyword.get(opts, :region) ||
        Settings.get_setting("aws_region", "eu-north-1")

    access_key_id =
      Keyword.get(opts, :access_key_id) ||
        Settings.get_setting("aws_access_key_id")

    secret_access_key =
      Keyword.get(opts, :secret_access_key) ||
        Settings.get_setting("aws_secret_access_key")

    if is_nil(access_key_id) || is_nil(secret_access_key) || access_key_id == "" ||
         secret_access_key == "" do
      {:error, "validation", "AWS credentials not found. Please configure them first."}
    else
      config = [
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        region: region
      ]

      run_setup(project_name, region, config)
    end
  end

  defp run_setup(project_name, region, config) do
    Logger.info("[AWS Setup] Starting infrastructure setup for project: #{project_name}")
    Logger.info("[AWS Setup] Region: #{region}")

    with {:ok, account_id} <- get_account_id(config),
         {:ok, dlq_url, dlq_arn} <- create_dlq(project_name, account_id, config),
         :ok <- set_dlq_policy(dlq_url, dlq_arn, account_id, config),
         {:ok, topic_arn} <- create_sns_topic(project_name, config),
         {:ok, queue_url, queue_arn} <-
           create_main_queue(project_name, account_id, dlq_arn, config),
         :ok <- set_queue_policy(queue_url, queue_arn, topic_arn, account_id, config),
         {:ok, _sub_arn} <- subscribe_sqs_to_sns(topic_arn, queue_arn, config),
         {:ok, config_set} <- create_ses_config_set(project_name, region, config),
         :ok <- configure_ses_events(config_set, topic_arn, region, config) do
      result_config = %{
        "aws_region" => region,
        "aws_sns_topic_arn" => topic_arn,
        "aws_sqs_queue_url" => queue_url,
        "aws_sqs_queue_arn" => queue_arn,
        "aws_sqs_dlq_url" => dlq_url,
        "aws_ses_configuration_set" => config_set,
        "sqs_polling_interval_ms" => "5000"
      }

      Logger.info("[AWS Setup] ✅ Infrastructure setup completed successfully!")
      {:ok, result_config}
    else
      {:error, step, reason} = error ->
        Logger.error("[AWS Setup] ❌ Failed at step: #{step}")
        Logger.error("[AWS Setup] Reason: #{reason}")
        error
    end
  end

  # Private functions

  defp get_account_id(config) do
    Logger.info("[AWS Setup] [1/9] Getting AWS Account ID...")

    case STS.get_caller_identity() |> ExAws.request(config) do
      {:ok, %{body: body}} when is_map(body) ->
        # Handle sweet_xml parsed response (atom keys)
        account_id = body[:account] || body["account"]

        if account_id do
          Logger.info("[AWS Setup]   ✓ Account ID: #{account_id}")
          {:ok, account_id}
        else
          {:error, "get_account_id", "Could not parse account ID from response: #{inspect(body)}"}
        end

      {:error, reason} ->
        {:error, "get_account_id", "AWS API error: #{inspect(reason)}"}
    end
  end

  defp create_dlq(project_name, account_id, config) do
    Logger.info("[AWS Setup] [2/9] Creating Dead Letter Queue...")
    dlq_name = "#{project_name}-email-dlq"

    case SQS.create_queue(dlq_name,
           visibility_timeout: "60",
           message_retention_period: "1209600",
           sqs_managed_sse_enabled: "true"
         )
         |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        dlq_url = get_queue_url_from_response(body)
        region = config[:region]
        dlq_arn = "arn:aws:sqs:#{region}:#{account_id}:#{dlq_name}"

        Logger.info("[AWS Setup]   ✓ DLQ Created")
        Logger.info("[AWS Setup]     URL: #{dlq_url}")
        Logger.info("[AWS Setup]     ARN: #{dlq_arn}")
        {:ok, dlq_url, dlq_arn}

      {:error, {:http_error, 400, %{body: body}}} when is_binary(body) ->
        if String.contains?(body, "QueueAlreadyExists") do
          handle_existing_queue(dlq_name, account_id, config, "DLQ")
        else
          {:error, "create_dlq", body}
        end

      {:error, reason} ->
        {:error, "create_dlq", inspect(reason)}
    end
  end

  defp set_dlq_policy(dlq_url, dlq_arn, account_id, config) do
    Logger.info("[AWS Setup] [3/9] Setting DLQ policy...")

    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Id" => "__default_policy_ID",
        "Statement" => [
          %{
            "Sid" => "__owner_statement",
            "Effect" => "Allow",
            "Principal" => %{"AWS" => "arn:aws:iam::#{account_id}:root"},
            "Action" => "SQS:*",
            "Resource" => dlq_arn
          }
        ]
      })

    case SQS.set_queue_attributes(dlq_url, policy: policy) |> ExAws.request(config) do
      {:ok, _} ->
        Logger.info("[AWS Setup]   ✓ DLQ Policy set")
        :ok

      {:error, reason} ->
        {:error, "set_dlq_policy", inspect(reason)}
    end
  end

  defp create_sns_topic(project_name, config) do
    Logger.info("[AWS Setup] [4/9] Creating SNS Topic...")
    topic_name = "#{project_name}-email-events"

    case SNS.create_topic(topic_name) |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        topic_arn = body[:topic_arn] || body["TopicArn"] || body["topic_arn"]

        Logger.info("[AWS Setup]   ✓ SNS Topic Created/Found")
        Logger.info("[AWS Setup]     ARN: #{topic_arn}")
        {:ok, topic_arn}

      {:error, reason} ->
        {:error, "create_sns_topic", inspect(reason)}
    end
  end

  defp create_main_queue(project_name, account_id, dlq_arn, config) do
    Logger.info("[AWS Setup] [5/9] Creating Main Queue with DLQ redrive policy...")
    queue_name = "#{project_name}-email-queue"

    redrive_policy =
      Jason.encode!(%{
        "deadLetterTargetArn" => dlq_arn,
        "maxReceiveCount" => 3
      })

    case SQS.create_queue(queue_name,
           visibility_timeout: "600",
           message_retention_period: "1209600",
           receive_message_wait_time_seconds: "20",
           redrive_policy: redrive_policy,
           sqs_managed_sse_enabled: "true"
         )
         |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        queue_url = get_queue_url_from_response(body)
        region = config[:region]
        queue_arn = "arn:aws:sqs:#{region}:#{account_id}:#{queue_name}"

        Logger.info("[AWS Setup]   ✓ Main Queue Created")
        Logger.info("[AWS Setup]     URL: #{queue_url}")
        Logger.info("[AWS Setup]     ARN: #{queue_arn}")
        {:ok, queue_url, queue_arn}

      {:error, {:http_error, 400, %{body: body}}} when is_binary(body) ->
        if String.contains?(body, "QueueAlreadyExists") do
          handle_existing_queue(queue_name, account_id, config, "Main Queue")
        else
          {:error, "create_main_queue", body}
        end

      {:error, reason} ->
        {:error, "create_main_queue", inspect(reason)}
    end
  end

  defp set_queue_policy(queue_url, queue_arn, topic_arn, account_id, config) do
    Logger.info("[AWS Setup] [6/9] Setting Main Queue policy to allow SNS and account access...")

    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Id" => "sqs-policy",
        "Statement" => [
          %{
            "Sid" => "AllowSNSPublish",
            "Effect" => "Allow",
            "Principal" => %{"Service" => "sns.amazonaws.com"},
            "Action" => "SQS:SendMessage",
            "Resource" => queue_arn,
            "Condition" => %{"ArnEquals" => %{"aws:SourceArn" => topic_arn}}
          },
          %{
            "Sid" => "AllowAccountAccess",
            "Effect" => "Allow",
            "Principal" => %{"AWS" => "arn:aws:iam::#{account_id}:root"},
            "Action" => [
              "SQS:ReceiveMessage",
              "SQS:DeleteMessage",
              "SQS:GetQueueAttributes",
              "SQS:SendMessage"
            ],
            "Resource" => queue_arn
          }
        ]
      })

    case SQS.set_queue_attributes(queue_url, policy: policy) |> ExAws.request(config) do
      {:ok, _} ->
        Logger.info("[AWS Setup]   ✓ Main Queue Policy set")
        :ok

      {:error, reason} ->
        {:error, "set_queue_policy", inspect(reason)}
    end
  end

  defp subscribe_sqs_to_sns(topic_arn, queue_arn, config) do
    Logger.info("[AWS Setup] [7/9] Creating SNS subscription to SQS...")

    case SNS.subscribe(topic_arn, "sqs", queue_arn) |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        sub_arn =
          body[:subscription_arn] || body["SubscriptionArn"] || body["subscription_arn"] ||
            "confirmed"

        Logger.info("[AWS Setup]   ✓ SNS → SQS Subscription created")

        if sub_arn && sub_arn != "pending confirmation" do
          Logger.info("[AWS Setup]     Subscription ARN: #{sub_arn}")
        end

        {:ok, sub_arn}

      {:error, _reason} ->
        Logger.info("[AWS Setup]   ℹ️  Subscription may already exist")
        {:ok, "existing"}
    end
  end

  defp create_ses_config_set(project_name, _region, config) do
    Logger.info("[AWS Setup] [8/9] Creating SES Configuration Set...")
    config_set_name = "#{project_name}-emailing"

    alias PhoenixkitEu.AWS.SESv2

    case SESv2.create_configuration_set(config_set_name, config) do
      {:ok, ^config_set_name} ->
        Logger.info("[AWS Setup]   ✓ SES Configuration Set created")
        Logger.info("[AWS Setup]     Name: #{config_set_name}")
        {:ok, config_set_name}

      {:error, reason} ->
        Logger.error("[AWS Setup]   ❌ Failed to create SES Configuration Set")
        Logger.error("[AWS Setup]     Reason: #{inspect(reason)}")
        {:error, "create_ses_config_set", reason}
    end
  end

  defp configure_ses_events(config_set, topic_arn, _region, config) do
    Logger.info("[AWS Setup] [9/9] Configuring SES event tracking to SNS...")

    alias PhoenixkitEu.AWS.SESv2

    case SESv2.create_configuration_set_event_destination(
           config_set,
           "email-events-to-sns",
           topic_arn,
           config
         ) do
      :ok ->
        Logger.info("[AWS Setup]   ✓ SES Event Tracking configured")

        Logger.info(
          "[AWS Setup]     Events: SEND, REJECT, BOUNCE, COMPLAINT, DELIVERY, OPEN, CLICK, RENDERING_FAILURE"
        )

        Logger.info("[AWS Setup]     Destination: #{topic_arn}")
        :ok

      {:error, reason} ->
        Logger.error("[AWS Setup]   ❌ Failed to configure SES event tracking")
        Logger.error("[AWS Setup]     Reason: #{inspect(reason)}")
        {:error, "configure_ses_events", reason}
    end
  end

  # Helper functions

  defp get_queue_url_from_response(body) when is_map(body) do
    body[:queue_url] || body["QueueUrl"] || body["queue_url"]
  end

  defp handle_existing_queue(queue_name, account_id, config, queue_type) do
    case SQS.get_queue_url(queue_name) |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        queue_url = get_queue_url_from_response(body)
        region = config[:region]
        queue_arn = "arn:aws:sqs:#{region}:#{account_id}:#{queue_name}"
        Logger.info("[AWS Setup]   ✓ #{queue_type} Found (already exists)")
        Logger.info("[AWS Setup]     URL: #{queue_url}")
        {:ok, queue_url, queue_arn}

      {:error, reason} ->
        {:error, "get_existing_queue", "Failed to get existing #{queue_type}: #{inspect(reason)}"}
    end
  end

  defp sanitize_project_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.trim("-")
  end
end
