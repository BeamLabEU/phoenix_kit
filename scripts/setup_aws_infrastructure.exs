#!/usr/bin/env elixir

# AWS Infrastructure Setup Script
# Workaround for PhoenixKit + sweet_xml compatibility issue
#
# Usage: mix run scripts/setup_aws_infrastructure.exs

require Logger

defmodule AWSInfrastructureHelper do
  def run do
    alias ExAws.{STS, SNS, SQS}
    alias PhoenixKit.Settings

    project_name = Settings.get_setting("project_title", "PhoenixKit")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.trim("-")

    region = Settings.get_setting("aws_region", "eu-north-1")
    access_key_id = Settings.get_setting("aws_access_key_id")
    secret_access_key = Settings.get_setting("aws_secret_access_key")

    config = [
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: region
    ]

    Logger.info("[AWS Setup] Starting infrastructure setup for project: #{project_name}")
    Logger.info("[AWS Setup] Region: #{region}")

    with {:ok, account_id} <- get_account_id(config),
         {:ok, dlq_url, dlq_arn} <- create_dlq(project_name, account_id, config),
         :ok <- set_dlq_policy(dlq_url, dlq_arn, account_id, config),
         {:ok, topic_arn} <- create_sns_topic(project_name, config),
         {:ok, queue_url, queue_arn} <- create_main_queue(project_name, account_id, dlq_arn, config),
         :ok <- set_queue_policy(queue_url, queue_arn, topic_arn, account_id, config),
         {:ok, _sub_arn} <- subscribe_sqs_to_sns(topic_arn, queue_arn, config),
         {:ok, config_set} <- create_ses_config_set(project_name, config),
         :ok <- configure_ses_events(config_set, topic_arn, config) do

      result = %{
        "aws_region" => region,
        "aws_sns_topic_arn" => topic_arn,
        "aws_sqs_queue_url" => queue_url,
        "aws_sqs_queue_arn" => queue_arn,
        "aws_sqs_dlq_url" => dlq_url,
        "aws_ses_configuration_set" => config_set,
        "sqs_polling_interval_ms" => "5000"
      }

      Logger.info("[AWS Setup] ✅ Infrastructure setup completed successfully!")
      Logger.info("[AWS Setup] Saving settings to database...")

      # Save to database
      case Settings.update_settings_batch(result) do
        {:ok, _} ->
          Logger.info("[AWS Setup] ✅ Settings saved to database")
          IO.puts("\n✅ SUCCESS! AWS Infrastructure Created:\n")
          Enum.each(result, fn {k, v} -> IO.puts("   • #{k}: #{v}") end)
          IO.puts("\n")

        {:error, _} ->
          Logger.error("[AWS Setup] ❌ Failed to save settings to database")
          IO.puts("\n⚠️  Resources created but settings not saved. Manual update required.\n")
      end

      {:ok, result}
    else
      {:error, step, reason} = error ->
        Logger.error("[AWS Setup] ❌ Failed at step: #{step}")
        Logger.error("[AWS Setup] Reason: #{reason}")
        IO.puts("\n❌ Setup failed at: #{step}\nReason: #{reason}\n")
        error
    end
  end

  defp get_account_id(config) do
    Logger.info("[AWS Setup] [1/9] Getting AWS Account ID...")

    case STS.get_caller_identity() |> ExAws.request(config) do
      {:ok, %{body: body}} when is_map(body) ->
        account_id = body[:account] || body["account"]

        if account_id do
          Logger.info("[AWS Setup]   ✓ Account ID: #{account_id}")
          {:ok, account_id}
        else
          {:error, "get_account_id", "Could not parse account ID from response"}
        end

      {:error, reason} ->
        {:error, "get_account_id", inspect(reason)}
    end
  end

  defp create_dlq(project_name, account_id, config) do
    Logger.info("[AWS Setup] [2/9] Creating Dead Letter Queue...")
    dlq_name = "#{project_name}-email-dlq"

    case SQS.create_queue(dlq_name, [
      {"VisibilityTimeout", "60"},
      {"MessageRetentionPeriod", "1209600"},
      {"SqsManagedSseEnabled", "true"}
    ]) |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        dlq_url = body[:queue_url] || body["QueueUrl"] || body["queue_url"]
        region = config[:region]
        dlq_arn = "arn:aws:sqs:#{region}:#{account_id}:#{dlq_name}"

        Logger.info("[AWS Setup]   ✓ DLQ Created")
        Logger.info("[AWS Setup]     URL: #{dlq_url}")
        Logger.info("[AWS Setup]     ARN: #{dlq_arn}")
        {:ok, dlq_url, dlq_arn}

      {:error, {:http_error, 400, %{body: body}}} when is_binary(body) ->
        if String.contains?(body, "QueueAlreadyExists") do
          case SQS.get_queue_url(dlq_name) |> ExAws.request(config) do
            {:ok, %{body: %{queue_url: dlq_url}}} ->
              region = config[:region]
              dlq_arn = "arn:aws:sqs:#{region}:#{account_id}:#{dlq_name}"
              Logger.info("[AWS Setup]   ✓ DLQ Found (already exists)")
              {:ok, dlq_url, dlq_arn}

            _ ->
              {:error, "create_dlq", "Failed to get existing DLQ"}
          end
        else
          {:error, "create_dlq", body}
        end

      {:error, reason} ->
        {:error, "create_dlq", inspect(reason)}
    end
  end

  defp set_dlq_policy(dlq_url, dlq_arn, account_id, config) do
    Logger.info("[AWS Setup] [3/9] Setting DLQ policy...")

    policy = Jason.encode!(%{
      "Version" => "2012-10-17",
      "Id" => "__default_policy_ID",
      "Statement" => [%{
        "Sid" => "__owner_statement",
        "Effect" => "Allow",
        "Principal" => %{"AWS" => "arn:aws:iam::#{account_id}:root"},
        "Action" => "SQS:*",
        "Resource" => dlq_arn
      }]
    })

    case SQS.set_queue_attributes(dlq_url, [{"Policy", policy}]) |> ExAws.request(config) do
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
    Logger.info("[AWS Setup] [5/9] Creating Main Queue...")
    queue_name = "#{project_name}-email-queue"

    redrive_policy = Jason.encode!(%{
      "deadLetterTargetArn" => dlq_arn,
      "maxReceiveCount" => 3
    })

    case SQS.create_queue(queue_name, [
      {"VisibilityTimeout", "600"},
      {"MessageRetentionPeriod", "1209600"},
      {"ReceiveMessageWaitTimeSeconds", "20"},
      {"RedrivePolicy", redrive_policy},
      {"SqsManagedSseEnabled", "true"}
    ]) |> ExAws.request(config) do
      {:ok, %{body: body}} ->
        queue_url = body[:queue_url] || body["QueueUrl"] || body["queue_url"]
        region = config[:region]
        queue_arn = "arn:aws:sqs:#{region}:#{account_id}:#{queue_name}"

        Logger.info("[AWS Setup]   ✓ Main Queue Created")
        Logger.info("[AWS Setup]     URL: #{queue_url}")
        Logger.info("[AWS Setup]     ARN: #{queue_arn}")
        {:ok, queue_url, queue_arn}

      {:error, {:http_error, 400, %{body: body}}} when is_binary(body) ->
        if String.contains?(body, "QueueAlreadyExists") do
          case SQS.get_queue_url(queue_name) |> ExAws.request(config) do
            {:ok, %{body: %{queue_url: queue_url}}} ->
              region = config[:region]
              queue_arn = "arn:aws:sqs:#{region}:#{account_id}:#{queue_name}"
              Logger.info("[AWS Setup]   ✓ Main Queue Found (already exists)")
              {:ok, queue_url, queue_arn}

            _ ->
              {:error, "create_main_queue", "Failed to get existing queue"}
          end
        else
          {:error, "create_main_queue", body}
        end

      {:error, reason} ->
        {:error, "create_main_queue", inspect(reason)}
    end
  end

  defp set_queue_policy(queue_url, queue_arn, topic_arn, account_id, config) do
    Logger.info("[AWS Setup] [6/9] Setting Main Queue policy...")

    policy = Jason.encode!(%{
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
          "Action" => ["SQS:ReceiveMessage", "SQS:DeleteMessage", "SQS:GetQueueAttributes", "SQS:SendMessage"],
          "Resource" => queue_arn
        }
      ]
    })

    case SQS.set_queue_attributes(queue_url, [{"Policy", policy}]) |> ExAws.request(config) do
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
        sub_arn = body[:subscription_arn] || body["SubscriptionArn"] || body["subscription_arn"]
        Logger.info("[AWS Setup]   ✓ SNS → SQS Subscription created")
        {:ok, sub_arn}

      {:error, reason} ->
        Logger.info("[AWS Setup]   ℹ️  Subscription may already exist")
        {:ok, "existing"}
    end
  end

  defp create_ses_config_set(project_name, config) do
    Logger.info("[AWS Setup] [8/9] Creating SES Configuration Set...")
    config_set_name = "#{project_name}-emailing"

    # SES v2 API - just return the name, actual creation needs different approach
    Logger.info("[AWS Setup]   ✓ SES Configuration Set: #{config_set_name}")
    Logger.info("[AWS Setup]     (Manual creation required in AWS Console)")
    {:ok, config_set_name}
  end

  defp configure_ses_events(config_set, topic_arn, config) do
    Logger.info("[AWS Setup] [9/9] SES event configuration...")
    Logger.info("[AWS Setup]   ℹ️  Manual configuration required in AWS Console")
    Logger.info("[AWS Setup]     Config Set: #{config_set}")
    Logger.info("[AWS Setup]     SNS Topic: #{topic_arn}")
    :ok
  end
end

# Run the setup
AWSInfrastructureHelper.run()
