defmodule PhoenixKit.EmailSystem do
  @moduledoc """
  Email system for PhoenixKit - main API module.

  This module provides the primary interface for email system functionality,
  including system configuration, log management, event management, and analytics.

  ## Core Features

  - **Email Logging**: Comprehensive logging of all outgoing emails
  - **Event Management**: Manage delivery, bounce, complaint, open, and click events
  - **AWS SES Integration**: Deep integration with AWS SES for event management
  - **Analytics**: Detailed metrics and engagement analysis
  - **System Settings**: Configurable options for system behavior
  - **Rate Limiting**: Protection against abuse and spam
  - **Archival**: Automatic cleanup and archival of old data

  ## System Settings

  All settings are stored in the PhoenixKit settings system with module "email_system":

  - `email_enabled` - Enable/disable the entire system
  - `email_save_body` - Save full email body (vs preview only)
  - `email_ses_events` - Manage AWS SES delivery events
  - `email_cloudwatch_metrics` - Enable CloudWatch metrics
  - `email_retention_days` - Days to keep emails (default: 90)
  - `aws_ses_configuration_set` - AWS SES configuration set name
  - `email_compress_body` - Compress body after N days
  - `email_archive_to_s3` - Enable S3 archival
  - `email_sampling_rate` - Percentage of emails to fully log

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if email system is enabled
  - `enable_system/0` - Enable email system
  - `disable_system/0` - Disable email system
  - `get_config/0` - Get current system configuration

  ### Email Log Management
  - `list_logs/1` - Get emails with filters
  - `get_log!/1` - Get email log by ID
  - `create_log/1` - Create new email log
  - `update_log_status/2` - Update log status

  ### Event Management
  - `create_event/1` - Create system event
  - `list_events_for_log/1` - Get events for specific log
  - `process_webhook_event/1` - Process incoming webhook

  ### Analytics & Metrics
  - `get_system_stats/1` - Overall system statistics
  - `get_engagement_metrics/1` - Open/click rate analysis
  - `get_campaign_stats/1` - Campaign-specific metrics
  - `get_provider_performance/1` - Provider comparison

  ### Maintenance
  - `cleanup_old_logs/1` - Remove old logs
  - `compress_old_bodies/1` - Compress storage
  - `archive_to_s3/1` - Archive to S3

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKit.EmailSystem.enabled?() do
        # System is active
      end

      # Get system statistics
      stats = PhoenixKit.EmailSystem.get_system_stats(:last_30_days)
      # => %{total_sent: 5000, delivered: 4850, bounce_rate: 2.5, open_rate: 23.4}

      # Get campaign performance
      campaign_stats = PhoenixKit.EmailSystem.get_campaign_stats("newsletter_2024")
      # => %{total_sent: 1000, delivery_rate: 98.5, open_rate: 25.2, click_rate: 4.8}

      # Process webhook from AWS SES
      {:ok, event} = PhoenixKit.EmailSystem.process_webhook_event(webhook_data)

      # Clean up old data
      {deleted_count, _} = PhoenixKit.EmailSystem.cleanup_old_logs(90)

  ## Configuration Example

      # In your application config
      config :phoenix_kit,
        email_enabled: true,
        email_save_body: false,
        email_retention_days: 90,
        aws_ses_configuration_set: "my-app-system"
  """

  alias PhoenixKit.EmailSystem.{EmailEvent, EmailLog, SQSProcessor}
  alias PhoenixKit.Settings

  import Ecto.Query, only: [where: 3, group_by: 3, select: 3]

  ## --- Manual Synchronization Functions ---

  # Check if message ID matches AWS SES format
  defp aws_message_id?(message_id) do
    String.match?(
      message_id,
      ~r/^[0-9a-f]{16}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[0-9]{6}$/
    )
  end

  # Check if message ID is PhoenixKit internal format
  defp internal_message_id?(message_id) do
    String.starts_with?(message_id, "pk_")
  end

  # Find log and prepare result tuple
  defp find_log_and_prepare_result(message_id, search_type, log_finder_fn) do
    case log_finder_fn.(message_id) do
      {:ok, log} ->
        aws_id =
          if search_type == :aws_message_id,
            do: message_id,
            else: log.aws_message_id || message_id

        log_message(search_type, true, log, message_id, aws_id)
        {log, aws_id, search_type}

      {:error, :not_found} ->
        log_message(search_type, false, nil, message_id, message_id)
        {nil, message_id, search_type}
    end
  end

  # Log search results
  defp log_message(search_type, found?, log, message_id, aws_id) do
    require Logger

    case {search_type, found?} do
      {:aws_message_id, true} ->
        Logger.info("Found existing email log by AWS message ID", %{
          log_id: log.id,
          current_status: log.status,
          aws_message_id: message_id
        })

      {:aws_message_id, false} ->
        Logger.info("No existing email log found for AWS message_id: #{message_id}")

      {:internal_message_id, true} ->
        Logger.info("Found existing email log by internal message ID", %{
          log_id: log.id,
          current_status: log.status,
          internal_message_id: message_id,
          aws_message_id: aws_id
        })

      {:internal_message_id, false} ->
        Logger.warning("No existing email log found for internal message_id: #{message_id}")

      {:unknown_format, true} ->
        Logger.info("Found existing email log by unknown message ID format", %{
          log_id: log.id,
          current_status: log.status,
          search_message_id: message_id,
          aws_message_id: aws_id
        })

      {:unknown_format, false} ->
        Logger.info("No existing email log found for message_id: #{message_id}")
    end
  end

  # Determine the search strategy and AWS message ID to use for SQS search
  defp determine_search_strategy(message_id) do
    require Logger

    cond do
      aws_message_id?(message_id) ->
        find_log_and_prepare_result(
          message_id,
          :aws_message_id,
          &EmailLog.find_by_aws_message_id/1
        )

      internal_message_id?(message_id) ->
        find_log_and_prepare_result(message_id, :internal_message_id, &get_log_by_message_id/1)

      true ->
        handle_unknown_format_search(message_id)
    end
  end

  # Handle unknown format by trying both search approaches
  defp handle_unknown_format_search(message_id) do
    require Logger

    case get_log_by_message_id(message_id) do
      {:ok, log} ->
        aws_id = log.aws_message_id || message_id
        log_message(:unknown_format, true, log, message_id, aws_id)
        {log, aws_id, :unknown_format}

      {:error, :not_found} ->
        case EmailLog.find_by_aws_message_id(message_id) do
          {:ok, log} ->
            Logger.info("Found existing email log by AWS message ID (fallback)", %{
              log_id: log.id,
              current_status: log.status,
              aws_message_id: message_id
            })

            {log, message_id, :unknown_format}

          {:error, :not_found} ->
            log_message(:unknown_format, false, nil, message_id, message_id)
            {nil, message_id, :unknown_format}
        end
    end
  end

  @doc """
  Manually sync email status by fetching events from SQS queues.

  This function searches for events in both the main SQS queue and DLQ
  that match the given message_id and processes them to update email status.

  ## Parameters

  - `message_id` - The AWS SES message ID or internal PhoenixKit message ID to sync

  ## Returns

  - `{:ok, result}` - Successful sync with processing results
  - `{:error, reason}` - Error during sync process

  ## Examples

      iex> PhoenixKit.EmailSystem.sync_email_status("0110019971abc123-...")
      {:ok, %{events_processed: 3, log_updated: true}}

      iex> PhoenixKit.EmailSystem.sync_email_status("pk_abc123...")
      {:ok, %{events_processed: 1, log_updated: true}}
  """
  def sync_email_status(message_id) when is_binary(message_id) do
    require Logger

    Logger.info("Starting email status sync", %{message_id: message_id})

    if enabled?() do
      # Check AWS configuration first
      if aws_configured?() do
        try do
          # Determine the search strategy based on message ID type
          {existing_log, aws_message_id, search_strategy} = determine_search_strategy(message_id)

          # Get events from SQS and DLQ using the appropriate message ID
          Logger.debug("Fetching events from SQS and DLQ queues", %{
            search_strategy: search_strategy,
            aws_message_id: aws_message_id,
            original_message_id: message_id
          })

          sqs_events = fetch_sqs_events_for_message(aws_message_id)
          dlq_events = fetch_dlq_events_for_message(aws_message_id)

          all_events = sqs_events ++ dlq_events

          Logger.info("Event search results", %{
            message_id: message_id,
            sqs_events: length(sqs_events),
            dlq_events: length(dlq_events),
            total_events: length(all_events)
          })

          if Enum.empty?(all_events) do
            message =
              if existing_log do
                "No new events found in SQS/DLQ for this email"
              else
                "No events found and no email log exists for this message ID"
              end

            {:ok,
             %{
               events_processed: 0,
               total_events_found: 0,
               sqs_events_found: 0,
               dlq_events_found: 0,
               log_updated: false,
               existing_log_found: existing_log != nil,
               message: message
             }}
          else
            # Process events through SQS processor
            Logger.debug("Processing #{length(all_events)} events")

            results =
              Enum.with_index(all_events, 1)
              |> Enum.map(fn {event, index} ->
                Logger.debug(
                  "Processing event #{index}/#{length(all_events)}: #{event["eventType"] || "unknown"}"
                )

                result = SQSProcessor.process_email_event(event)

                case result do
                  {:ok, _} ->
                    Logger.debug("Successfully processed event #{index}")
                    result

                  {:error, reason} ->
                    Logger.warning("Failed to process event #{index}: #{inspect(reason)}")
                    result
                end
              end)

            successful_results =
              Enum.filter(results, fn
                {:ok, _} -> true
                _ -> false
              end)

            failed_results =
              Enum.filter(results, fn
                {:error, _} -> true
                _ -> false
              end)

            Logger.info("Event processing completed", %{
              message_id: message_id,
              total_events: length(all_events),
              successful: length(successful_results),
              failed: length(failed_results)
            })

            {:ok,
             %{
               events_processed: length(successful_results),
               events_failed: length(failed_results),
               total_events_found: length(all_events),
               sqs_events_found: length(sqs_events),
               dlq_events_found: length(dlq_events),
               log_updated: length(successful_results) > 0,
               existing_log_found: existing_log != nil,
               results: successful_results,
               failed_results: failed_results,
               message:
                 "Successfully processed #{length(successful_results)}/#{length(all_events)} events"
             }}
          end
        rescue
          error ->
            Logger.error("Error during email status sync", %{
              message_id: message_id,
              error: inspect(error),
              stacktrace: __STACKTRACE__
            })

            {:error, "Failed to sync email status: #{Exception.message(error)}"}
        end
      else
        Logger.debug("AWS credentials not configured for sync_email_status")

        {:error,
         "AWS credentials not configured. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."}
      end
    else
      Logger.debug("Email system is disabled, cannot sync status")
      {:error, "Email system is disabled. Please enable it in settings."}
    end
  end

  @doc """
  Fetch SES events from main SQS queue for specific message ID.

  ## Parameters

  - `message_id` - The AWS SES message ID to search for

  ## Returns

  List of SES events matching the message ID.
  """
  def fetch_sqs_events_for_message(message_id) do
    require Logger

    queue_url = Settings.get_setting("aws_sqs_queue_url")

    cond do
      not aws_configured?() ->
        Logger.debug("AWS credentials not configured, skipping SQS fetch")
        []

      is_nil(queue_url) or queue_url == "" ->
        Logger.warning("SQS queue URL not configured", %{
          setting: "aws_sqs_queue_url",
          current_value: queue_url
        })

        []

      not valid_queue_url?(queue_url) ->
        Logger.error("Invalid SQS queue URL format", %{
          queue_url: queue_url,
          expected_format: "https://sqs.{region}.amazonaws.com/{account_id}/{queue_name}"
        })

        []

      true ->
        try do
          Logger.info("Starting SQS message search", %{
            message_id: message_id,
            queue_url: queue_url
          })

          # Poll multiple batches to find the target message
          found_events = poll_sqs_for_message(queue_url, message_id, [], 0, 5)

          Logger.info("SQS search completed", %{
            message_id: message_id,
            queue_url: queue_url,
            events_found: length(found_events)
          })

          found_events
        rescue
          error ->
            Logger.error("Failed to fetch SQS events", %{
              error: inspect(error),
              message_id: message_id,
              queue_url: queue_url
            })

            []
        end
    end
  end

  @doc """
  Fetch SES events from DLQ queue for specific message ID.

  ## Parameters

  - `message_id` - The AWS SES message ID to search for

  ## Returns

  List of SES events matching the message ID from DLQ.
  """
  def fetch_dlq_events_for_message(message_id) do
    require Logger

    dlq_url = Settings.get_setting("aws_sqs_dlq_url")

    if dlq_url && aws_configured?() do
      try do
        Logger.debug("Starting DLQ message search for message_id: #{message_id}")

        # Poll multiple batches to find the target message (don't delete from DLQ)
        found_events = poll_dlq_for_message(dlq_url, message_id, [], 0, 5)

        Logger.info("DLQ search completed", %{
          message_id: message_id,
          events_found: length(found_events)
        })

        found_events
      rescue
        error ->
          Logger.warning("Failed to fetch DLQ events: #{inspect(error)}")
          []
      end
    else
      if aws_configured?() do
        Logger.debug("DLQ URL not configured, skipping DLQ fetch")
      else
        Logger.debug("AWS credentials not configured, skipping DLQ fetch")
      end

      []
    end
  end

  # Helper function to check message_id in message
  defp parse_and_check_message_id(sqs_message, target_message_id) do
    case SQSProcessor.parse_sns_message(sqs_message) do
      {:ok, event_data} ->
        message_id = get_in(event_data, ["mail", "messageId"])
        message_id == target_message_id

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end

  # Helper function to poll SQS in batches to find specific message
  defp poll_sqs_for_message(queue_url, target_message_id, found_events, batch_count, max_batches) do
    require Logger

    if batch_count >= max_batches do
      Logger.debug("Reached maximum SQS polling batches (#{max_batches})")
      found_events
    else
      # Log configuration details for debugging
      aws_config = get_aws_config()

      Logger.debug("Polling SQS batch #{batch_count + 1}/#{max_batches}", %{
        queue_url: queue_url,
        target_message_id: target_message_id,
        region: aws_config[:region],
        has_access_key: aws_config[:access_key_id] != nil,
        has_secret_key: aws_config[:secret_access_key] != nil
      })

      # Poll for messages with visibility timeout
      messages =
        ExAws.SQS.receive_message(queue_url,
          max_number_of_messages: 10,
          visibility_timeout: 30,
          wait_time_seconds: 2
        )
        |> ExAws.request(aws_config)
        |> case do
          {:ok, %{body: %{messages: messages}}} ->
            Logger.debug("Successfully received #{length(messages)} messages from SQS")
            messages

          {:ok, %{body: %{}}} ->
            Logger.debug("SQS returned empty response (no messages)")
            []

          {:error, {:http_error, status_code, %{code: error_code, message: error_message}}} ->
            Logger.error("SQS HTTP error", %{
              status_code: status_code,
              error_code: error_code,
              error_message: error_message,
              queue_url: queue_url,
              region: aws_config[:region]
            })

            []

          error ->
            Logger.warning("SQS poll error", %{
              error: inspect(error),
              queue_url: queue_url,
              region: aws_config[:region]
            })

            []
        end

      Logger.debug("SQS batch #{batch_count + 1}: received #{length(messages)} messages")

      if Enum.empty?(messages) do
        # No more messages, stop polling
        found_events
      else
        # Process this batch
        {matching_messages, messages_to_delete} =
          process_sqs_batch(messages, target_message_id)

        # Delete processed messages from queue
        delete_sqs_messages(queue_url, messages_to_delete)

        new_found_events = found_events ++ matching_messages

        if Enum.empty?(matching_messages) do
          # No matches in this batch, continue to next batch
          poll_sqs_for_message(
            queue_url,
            target_message_id,
            new_found_events,
            batch_count + 1,
            max_batches
          )
        else
          # Found matches, but continue searching for more events for same message
          poll_sqs_for_message(
            queue_url,
            target_message_id,
            new_found_events,
            batch_count + 1,
            max_batches
          )
        end
      end
    end
  end

  # Process a batch of SQS messages
  defp process_sqs_batch(messages, target_message_id) do
    require Logger

    Enum.reduce(messages, {[], []}, fn message, {matching, to_delete} ->
      case parse_and_check_message_id(message, target_message_id) do
        true ->
          # This message matches our target
          case SQSProcessor.parse_sns_message(message) do
            {:ok, event_data} ->
              Logger.debug("Found matching SQS message for #{target_message_id}")
              {[event_data | matching], [message | to_delete]}

            {:error, reason} ->
              Logger.warning("Failed to parse matching SQS message: #{inspect(reason)}")
              {matching, [message | to_delete]}
          end

        false ->
          # This message doesn't match, delete it so others can process it
          {matching, [message | to_delete]}
      end
    end)
  end

  # Delete processed messages from SQS
  defp delete_sqs_messages(queue_url, messages) do
    require Logger

    Enum.each(messages, fn message ->
      Logger.debug("Attempting to delete message with keys: #{inspect(Map.keys(message))}")

      receipt_handle =
        message["ReceiptHandle"] || message["receiptHandle"] || message["receipt_handle"] ||
          message[:receipt_handle]

      if receipt_handle do
        case ExAws.SQS.delete_message(queue_url, receipt_handle)
             |> ExAws.request(get_aws_config()) do
          {:ok, _} ->
            Logger.debug(
              "Deleted SQS message: #{message["MessageId"] || message["messageId"] || "unknown"}"
            )

          {:error, reason} ->
            Logger.warning("Failed to delete SQS message: #{inspect(reason)}")
        end
      else
        Logger.warning("Message missing ReceiptHandle: #{inspect(message)}")
      end
    end)
  end

  # Helper function to poll DLQ in batches to find specific message (don't delete from DLQ)
  defp poll_dlq_for_message(dlq_url, target_message_id, found_events, batch_count, max_batches) do
    require Logger

    if batch_count >= max_batches do
      Logger.debug("Reached maximum DLQ polling batches (#{max_batches})")
      found_events
    else
      # Poll for messages with visibility timeout (don't delete from DLQ for debugging)
      messages =
        ExAws.SQS.receive_message(dlq_url,
          max_number_of_messages: 10,
          visibility_timeout: 30,
          wait_time_seconds: 2
        )
        |> ExAws.request(get_aws_config())
        |> case do
          {:ok, %{body: %{messages: messages}}} ->
            messages

          {:ok, %{body: %{}}} ->
            []

          error ->
            Logger.warning("DLQ poll error: #{inspect(error)}")
            []
        end

      Logger.debug("DLQ batch #{batch_count + 1}: received #{length(messages)} messages")

      if Enum.empty?(messages) do
        # No more messages, stop polling
        found_events
      else
        # Process this batch (but don't delete from DLQ)
        matching_messages = process_dlq_batch(messages, target_message_id)
        new_found_events = found_events ++ matching_messages

        if Enum.empty?(matching_messages) do
          # No matches in this batch, continue to next batch
          poll_dlq_for_message(
            dlq_url,
            target_message_id,
            new_found_events,
            batch_count + 1,
            max_batches
          )
        else
          # Found matches, but continue searching for more events for same message
          poll_dlq_for_message(
            dlq_url,
            target_message_id,
            new_found_events,
            batch_count + 1,
            max_batches
          )
        end
      end
    end
  end

  # Process a batch of DLQ messages (don't delete from DLQ)
  defp process_dlq_batch(messages, target_message_id) do
    require Logger

    Enum.reduce(messages, [], fn message, matching ->
      case parse_and_check_message_id(message, target_message_id) do
        true ->
          # This message matches our target
          case SQSProcessor.parse_sns_message(message) do
            {:ok, event_data} ->
              Logger.debug("Found matching DLQ message for #{target_message_id}")
              [event_data | matching]

            {:error, reason} ->
              Logger.warning("Failed to parse matching DLQ message: #{inspect(reason)}")
              matching
          end

        false ->
          # This message doesn't match
          matching
      end
    end)
  end

  ## --- System Settings ---

  @doc """
  Checks if the email system is enabled.

  Returns true if the "email_enabled" setting is true.

  ## Examples

      iex> PhoenixKit.EmailSystem.enabled?()
      true
  """
  def enabled? do
    Settings.get_boolean_setting("email_enabled", false)
  end

  @doc """
  Enables the email system.

  Sets the "email_enabled" setting to true.

  ## Examples

      iex> PhoenixKit.EmailSystem.enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("email_enabled", true, "email_system")
  end

  @doc """
  Disables the email system.

  Sets the "email_enabled" setting to false.

  ## Examples

      iex> PhoenixKit.EmailSystem.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module("email_enabled", false, "email_system")
  end

  @doc """
  Checks if full email body saving is enabled.

  Returns true if the "email_save_body" setting is true.

  ## Examples

      iex> PhoenixKit.EmailSystem.save_body_enabled?()
      false
  """
  def save_body_enabled? do
    Settings.get_boolean_setting("email_save_body", false)
  end

  @doc """
  Enables or disables full email body saving.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_save_body(true)
      {:ok, %Setting{}}
  """
  def set_save_body(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_save_body",
      enabled,
      "email_system"
    )
  end

  @doc """
  Checks if AWS SES event management is enabled.

  ## Examples

      iex> PhoenixKit.EmailSystem.ses_events_enabled?()
      true
  """
  def ses_events_enabled? do
    Settings.get_boolean_setting("email_ses_events", true)
  end

  @doc """
  Enables or disables AWS SES event management.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_ses_events(true)
      {:ok, %Setting{}}
  """
  def set_ses_events(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_ses_events",
      enabled,
      "email_system"
    )
  end

  @doc """
  Gets the configured retention period for emails in days.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_retention_days()
      90
  """
  def get_retention_days do
    Settings.get_integer_setting("email_retention_days", 90)
  end

  @doc """
  Sets the retention period for emails.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_retention_days(180)
      {:ok, %Setting{}}
  """
  def set_retention_days(days) when is_integer(days) and days > 0 do
    Settings.update_setting_with_module(
      "email_retention_days",
      to_string(days),
      "email_system"
    )
  end

  @doc """
  Gets the AWS SES configuration set name.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_ses_configuration_set()
      "my-app-system"
  """
  def get_ses_configuration_set do
    Settings.get_setting("aws_ses_configuration_set", nil)
  end

  @doc """
  Sets the AWS SES configuration set name.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_ses_configuration_set("my-system-set")
      {:ok, %Setting{}}
  """
  def set_ses_configuration_set(config_set_name) when is_binary(config_set_name) do
    Settings.update_setting_with_module(
      "aws_ses_configuration_set",
      config_set_name,
      "email_system"
    )
  end

  @doc """
  Gets the sampling rate for email logging (percentage).

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sampling_rate()
      100  # Log 100% of emails
  """
  def get_sampling_rate do
    Settings.get_integer_setting("email_sampling_rate", 100)
  end

  @doc """
  Sets the sampling rate for email logging.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sampling_rate(80)  # Log 80% of emails
      {:ok, %Setting{}}
  """
  def set_sampling_rate(percentage)
      when is_integer(percentage) and percentage >= 0 and percentage <= 100 do
    Settings.update_setting_with_module(
      "email_sampling_rate",
      to_string(percentage),
      "email_system"
    )
  end

  ## --- AWS SQS Configuration ---

  @doc """
  Gets the AWS SNS Topic ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sns_topic_arn()
      "arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events"
  """
  def get_sns_topic_arn do
    Settings.get_setting("aws_sns_topic_arn", nil)
  end

  @doc """
  Sets the AWS SNS Topic ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sns_topic_arn("arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events")
      {:ok, %Setting{}}
  """
  def set_sns_topic_arn(topic_arn) when is_binary(topic_arn) do
    Settings.update_setting_with_module(
      "aws_sns_topic_arn",
      topic_arn,
      "email_system"
    )
  end

  @doc """
  Gets the AWS SQS Queue URL for email events.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sqs_queue_url()
      "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue"
  """
  def get_sqs_queue_url do
    Settings.get_setting("aws_sqs_queue_url", nil)
  end

  @doc """
  Sets the AWS SQS Queue URL for email events.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue")
      {:ok, %Setting{}}
  """
  def set_sqs_queue_url(queue_url) when is_binary(queue_url) do
    Settings.update_setting_with_module(
      "aws_sqs_queue_url",
      queue_url,
      "email_system"
    )
  end

  @doc """
  Gets the AWS SQS Queue ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sqs_queue_arn()
      "arn:aws:sqs:eu-north-1:123456789012:phoenixkit-email-queue"
  """
  def get_sqs_queue_arn do
    Settings.get_setting("aws_sqs_queue_arn", nil)
  end

  @doc """
  Sets the AWS SQS Queue ARN for email events.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sqs_queue_arn("arn:aws:sqs:eu-north-1:123456789012:phoenixkit-email-queue")
      {:ok, %Setting{}}
  """
  def set_sqs_queue_arn(queue_arn) when is_binary(queue_arn) do
    Settings.update_setting_with_module(
      "aws_sqs_queue_arn",
      queue_arn,
      "email_system"
    )
  end

  @doc """
  Gets the AWS SQS Dead Letter Queue URL.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sqs_dlq_url()
      "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-dlq"
  """
  def get_sqs_dlq_url do
    Settings.get_setting("aws_sqs_dlq_url", nil)
  end

  @doc """
  Sets the AWS SQS Dead Letter Queue URL.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sqs_dlq_url("https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-dlq")
      {:ok, %Setting{}}
  """
  def set_sqs_dlq_url(dlq_url) when is_binary(dlq_url) do
    Settings.update_setting_with_module(
      "aws_sqs_dlq_url",
      dlq_url,
      "email_system"
    )
  end

  @doc """
  Gets the AWS region for SES and SQS services.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_aws_region()
      "eu-north-1"
  """
  def get_aws_region do
    Settings.get_setting("aws_region", System.get_env("AWS_REGION", "eu-north-1"))
  end

  @doc """
  Sets the AWS region for SES and SQS services.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_aws_region("eu-north-1")
      {:ok, %Setting{}}
  """
  def set_aws_region(region) when is_binary(region) do
    Settings.update_setting_with_module(
      "aws_region",
      region,
      "email_system"
    )
  end

  ## --- SQS Worker Configuration ---

  @doc """
  Checks if SQS polling is enabled.

  ## Examples

      iex> PhoenixKit.EmailSystem.sqs_polling_enabled?()
      true
  """
  def sqs_polling_enabled? do
    Settings.get_boolean_setting("sqs_polling_enabled", false)
  end

  @doc """
  Enables or disables SQS polling.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sqs_polling(true)
      {:ok, %Setting{}}
  """
  def set_sqs_polling(enabled) when is_boolean(enabled) do
    Settings.update_setting_with_module(
      "sqs_polling_enabled",
      to_string(enabled),
      "email_system"
    )
  end

  @doc """
  Gets the SQS polling interval in milliseconds.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sqs_polling_interval()
      5000  # 5 seconds
  """
  def get_sqs_polling_interval do
    Settings.get_integer_setting("sqs_polling_interval_ms", 5000)
  end

  @doc """
  Sets the SQS polling interval in milliseconds.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sqs_polling_interval(3000)  # 3 seconds
      {:ok, %Setting{}}
  """
  def set_sqs_polling_interval(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Settings.update_setting_with_module(
      "sqs_polling_interval_ms",
      to_string(interval_ms),
      "email_system"
    )
  end

  @doc """
  Gets the maximum number of SQS messages to receive per polling cycle.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sqs_max_messages()
      10
  """
  def get_sqs_max_messages do
    Settings.get_integer_setting("sqs_max_messages_per_poll", 10)
  end

  @doc """
  Sets the maximum number of SQS messages to receive per polling cycle.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sqs_max_messages(20)
      {:ok, %Setting{}}
  """
  def set_sqs_max_messages(max_messages)
      when is_integer(max_messages) and max_messages > 0 and max_messages <= 10 do
    Settings.update_setting_with_module(
      "sqs_max_messages_per_poll",
      to_string(max_messages),
      "email_system"
    )
  end

  @doc """
  Gets the SQS message visibility timeout in seconds.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sqs_visibility_timeout()
      300  # 5 minutes
  """
  def get_sqs_visibility_timeout do
    Settings.get_integer_setting("sqs_visibility_timeout", 300)
  end

  @doc """
  Sets the SQS message visibility timeout in seconds.

  ## Examples

      iex> PhoenixKit.EmailSystem.set_sqs_visibility_timeout(600)  # 10 minutes
      {:ok, %Setting{}}
  """
  def set_sqs_visibility_timeout(timeout_seconds)
      when is_integer(timeout_seconds) and timeout_seconds > 0 do
    Settings.update_setting_with_module(
      "sqs_visibility_timeout",
      to_string(timeout_seconds),
      "email_system"
    )
  end

  @doc """
  Gets comprehensive SQS configuration.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_sqs_config()
      %{
        sns_topic_arn: "arn:aws:sns:...",
        queue_url: "https://sqs.eu-north-1.amazonaws.com/...",
        polling_enabled: true,
        polling_interval_ms: 5000,
        max_messages_per_poll: 10
      }
  """
  def get_sqs_config do
    %{
      sns_topic_arn: get_sns_topic_arn(),
      queue_url: get_sqs_queue_url(),
      queue_arn: get_sqs_queue_arn(),
      dlq_url: get_sqs_dlq_url(),
      aws_region: get_aws_region(),
      aws_access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      aws_secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
      polling_enabled: sqs_polling_enabled?(),
      polling_interval_ms: get_sqs_polling_interval(),
      max_messages_per_poll: get_sqs_max_messages(),
      visibility_timeout: get_sqs_visibility_timeout()
    }
  end

  @doc """
  Gets the current email system configuration.

  Returns a map with all current settings.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_config()
      %{
        enabled: true,
        save_body: false,
        ses_events: true,
        retention_days: 90,
        sampling_rate: 100,
        ses_configuration_set: "my-system",
        sns_topic_arn: "arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events",
        sqs_queue_url: "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue",
        sqs_polling_enabled: false,
        aws_region: "eu-north-1"
      }
  """
  def get_config do
    %{
      enabled: enabled?(),
      save_body: save_body_enabled?(),
      ses_events: ses_events_enabled?(),
      retention_days: get_retention_days(),
      sampling_rate: get_sampling_rate(),
      ses_configuration_set: get_ses_configuration_set(),
      compress_after_days: get_compress_after_days(),
      archive_to_s3: s3_archival_enabled?(),
      cloudwatch_metrics: cloudwatch_metrics_enabled?(),
      # AWS SQS Configuration
      sns_topic_arn: get_sns_topic_arn(),
      sqs_queue_url: get_sqs_queue_url(),
      sqs_queue_arn: get_sqs_queue_arn(),
      sqs_dlq_url: get_sqs_dlq_url(),
      aws_region: get_aws_region(),
      # SQS Worker Configuration
      sqs_polling_enabled: sqs_polling_enabled?(),
      sqs_polling_interval_ms: get_sqs_polling_interval(),
      sqs_max_messages_per_poll: get_sqs_max_messages(),
      sqs_visibility_timeout: get_sqs_visibility_timeout()
    }
  end

  ## --- Email Log Management ---

  @doc """
  Lists emails with optional filters.

  ## Options

  - `:status` - Filter by status (sent, delivered, bounced, etc.)
  - `:campaign_id` - Filter by campaign
  - `:template_name` - Filter by template
  - `:provider` - Filter by email provider
  - `:from_date` - Emails sent after this date
  - `:to_date` - Emails sent before this date
  - `:recipient` - Filter by recipient email
  - `:limit` - Limit results (default: 50)
  - `:offset` - Offset for pagination

  ## Examples

      iex> PhoenixKit.EmailSystem.list_logs(%{status: "bounced", limit: 10})
      [%EmailLog{}, ...]
  """
  def list_logs(filters \\ %{}) do
    if enabled?() do
      EmailLog.list_logs(filters)
    else
      []
    end
  end

  @doc """
  Counts emails with optional filtering (without loading all records).

  ## Parameters

  - `filters` - Map of filters to apply (optional)

  ## Examples

      iex> PhoenixKit.EmailSystem.count_logs(%{status: "bounced"})
      42
  """
  def count_logs(filters \\ %{}) do
    if enabled?() do
      EmailLog.count_logs(filters)
    else
      0
    end
  end

  @doc """
  Gets a single email log by ID.

  Raises `Ecto.NoResultsError` if the log does not exist or system is disabled.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_log!(123)
      %EmailLog{}
  """
  def get_log!(id) do
    ensure_enabled!()
    EmailLog.get_log!(id)
  end

  @doc """
  Gets an email log by message ID.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_log_by_message_id("msg-abc123")
      %EmailLog{}
  """
  def get_log_by_message_id(message_id) when is_binary(message_id) do
    if enabled?() do
      case EmailLog.get_log_by_message_id(message_id) do
        nil -> {:error, :not_found}
        log -> {:ok, log}
      end
    else
      {:error, :system_disabled}
    end
  end

  @doc """
  Creates an email log if system is enabled.

  ## Examples

      iex> PhoenixKit.EmailSystem.create_log(%{
        message_id: "abc123",
        to: "user@example.com",
        from: "app@example.com"
      })
      {:ok, %EmailLog{}}
  """
  def create_log(attrs \\ %{}) do
    if enabled?() and should_log_email?(attrs) do
      # Add system-level defaults
      attrs =
        Map.merge(attrs, %{
          configuration_set: get_ses_configuration_set(),
          body_full:
            if(save_body_enabled?() and attrs[:body_full], do: attrs[:body_full], else: nil)
        })

      EmailLog.create_log(attrs)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Updates the status of an email log.

  ## Examples

      iex> PhoenixKit.EmailSystem.update_log_status(log, "delivered")
      {:ok, %EmailLog{}}
  """
  def update_log_status(log, status) when is_binary(status) do
    if enabled?() do
      EmailLog.update_status(log, status)
    else
      {:ok, log}
    end
  end

  ## --- Event Management ---

  @doc """
  Creates an email system event.

  ## Examples

      iex> PhoenixKit.EmailSystem.create_event(%{
        email_log_id: 1,
        event_type: "open"
      })
      {:ok, %EmailEvent{}}
  """
  def create_event(attrs \\ %{}) do
    if enabled?() and ses_events_enabled?() do
      EmailEvent.create_event(attrs)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Lists events for a specific email log.

  ## Examples

      iex> PhoenixKit.EmailSystem.list_events_for_log(123)
      [%EmailEvent{}, ...]
  """
  def list_events_for_log(email_log_id) when is_integer(email_log_id) do
    if enabled?() do
      EmailEvent.for_email_log(email_log_id)
    else
      []
    end
  end

  @doc """
  Processes an incoming webhook event (typically from AWS SES).

  ## Examples

      iex> webhook_data = %{
        "eventType" => "bounce",
        "mail" => %{"messageId" => "abc123"}
      }
      iex> PhoenixKit.EmailSystem.process_webhook_event(webhook_data)
      {:ok, %EmailEvent{}}
  """
  def process_webhook_event(webhook_data) when is_map(webhook_data) do
    if enabled?() and ses_events_enabled?() do
      case extract_message_id(webhook_data) do
        nil ->
          {:error, :message_id_not_found}

        message_id ->
          case get_log_by_message_id(message_id) do
            {:error, :not_found} ->
              {:error, :email_log_not_found}

            {:ok, email_log} ->
              process_event_for_log(email_log, webhook_data)

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:ok, :skipped}
    end
  end

  ## --- Analytics & Metrics ---

  @doc """
  Gets overall system statistics for a time period.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_system_stats(:last_30_days)
      %{
        total_sent: 5000,
        delivered: 4850,
        bounced: 150,
        opened: 1200,
        clicked: 240,
        delivery_rate: 97.0,
        bounce_rate: 3.0,
        open_rate: 24.7,
        click_rate: 20.0
      }
  """
  def get_system_stats(period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)

      basic_stats = EmailLog.get_stats_for_period(start_date, end_date)

      Map.merge(basic_stats, %{
        # Add aliases for email_stats.ex compatibility
        complaints: basic_stats.complained,
        total_opened: basic_stats.opened,
        total_clicked: basic_stats.clicked,
        # Calculate percentages
        delivery_rate: safe_percentage(basic_stats.delivered, basic_stats.total_sent),
        bounce_rate: safe_percentage(basic_stats.bounced, basic_stats.total_sent),
        complaint_rate: safe_percentage(basic_stats.complained, basic_stats.total_sent),
        open_rate: safe_percentage(basic_stats.opened, basic_stats.delivered),
        click_rate: safe_percentage(basic_stats.clicked, basic_stats.opened),
        failure_rate: safe_percentage(basic_stats.failed, basic_stats.total_sent)
      })
    else
      %{}
    end
  end

  @doc """
  Gets engagement metrics with trend analysis.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_engagement_metrics(:last_7_days)
      %{
        avg_open_rate: 24.5,
        avg_click_rate: 4.2,
        bounce_rate: 2.8,
        engagement_trend: :increasing
      }
  """
  def get_engagement_metrics(period \\ :last_30_days) do
    if enabled?() do
      EmailLog.get_engagement_metrics(period)
    else
      %{}
    end
  end

  @doc """
  Gets daily delivery trend data for chart visualization.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_daily_delivery_trends(:last_7_days)
      %{
        labels: ["2024-09-01", "2024-09-02", ...],
        delivered: [120, 190, 300, ...],
        bounced: [5, 10, 15, ...]
      }
  """
  def get_daily_delivery_trends(period \\ :last_7_days) do
    if enabled?() do
      EmailLog.get_daily_delivery_trends(period)
    else
      %{labels: [], delivered: [], bounced: [], total_sent: []}
    end
  end

  @doc """
  Gets statistics for a specific campaign.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_campaign_stats("newsletter_2024")
      %{
        total_sent: 1000,
        delivery_rate: 98.5,
        open_rate: 25.2,
        click_rate: 4.8
      }
  """
  def get_campaign_stats(campaign_id) when is_binary(campaign_id) do
    if enabled?() do
      EmailLog.get_campaign_stats(campaign_id)
    else
      %{}
    end
  end

  @doc """
  Gets template-specific performance metrics.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_template_stats(:last_30_days)
      %{
        "welcome_email" => %{sent: 100, delivered: 95, opened: 45, clicked: 12},
        "password_reset" => %{sent: 50, delivered: 48, opened: 30, clicked: 8}
      }
  """
  def get_template_stats(period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)

      # Get basic stats grouped by template
      basic_stats =
        EmailLog
        |> where([l], l.sent_at >= ^start_date and l.sent_at <= ^end_date)
        |> where([l], not is_nil(l.template_name))
        |> group_by([l], l.template_name)
        |> select([l], {
          l.template_name,
          %{
            sent: count(l.id),
            delivered: sum(fragment("CASE WHEN ? = ? THEN 1 ELSE 0 END", l.status, "delivered")),
            opened: sum(fragment("CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END", l.opened_at)),
            clicked: sum(fragment("CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END", l.clicked_at))
          }
        })
        |> repo().all()
        |> Map.new()

      basic_stats
    else
      %{}
    end
  end

  @doc """
  Gets provider-specific performance metrics.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_provider_performance(:last_7_days)
      %{
        "aws_ses" => %{delivery_rate: 98.5, bounce_rate: 1.5},
        "smtp" => %{delivery_rate: 95.0, bounce_rate: 5.0}
      }
  """
  def get_provider_performance(period \\ :last_7_days) do
    if enabled?() do
      EmailLog.get_provider_performance(period)
    else
      %{}
    end
  end

  @doc """
  Gets geographic distribution of engagement events.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_geo_stats("open", :last_30_days)
      %{"US" => 500, "CA" => 200, "UK" => 150}
  """
  def get_geo_stats(event_type, period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)
      EmailEvent.get_geo_distribution(event_type, start_date, end_date)
    else
      %{}
    end
  end

  @doc """
  Gets the most clicked links for a time period.

  ## Examples

      iex> PhoenixKit.EmailSystem.get_top_links(:last_30_days, 10)
      [%{url: "https://example.com/product", clicks: 150}, ...]
  """
  def get_top_links(period \\ :last_30_days, limit \\ 10) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)
      EmailEvent.get_top_clicked_links(start_date, end_date, limit)
    else
      []
    end
  end

  ## --- Maintenance Functions ---

  @doc """
  Removes emails older than the specified number of days.

  Uses the system retention setting if no days specified.

  ## Examples

      iex> PhoenixKit.EmailSystem.cleanup_old_logs()
      {150, nil}  # Deleted 150 records

      iex> PhoenixKit.EmailSystem.cleanup_old_logs(180)
      {75, nil}   # Deleted 75 records older than 180 days
  """
  def cleanup_old_logs(days_old \\ nil) do
    if enabled?() do
      days = days_old || get_retention_days()
      EmailLog.cleanup_old_logs(days)
    else
      {0, nil}
    end
  end

  @doc """
  Compresses body_full field for old emails to save storage.

  ## Examples

      iex> PhoenixKit.EmailSystem.compress_old_bodies()
      {25, nil}  # Compressed 25 records

      iex> PhoenixKit.EmailSystem.compress_old_bodies(60)
      {40, nil}  # Compressed 40 records older than 60 days
  """
  def compress_old_bodies(days_old \\ nil) do
    if enabled?() do
      days = days_old || get_compress_after_days()
      EmailLog.compress_old_bodies(days)
    else
      {0, nil}
    end
  end

  @doc """
  Archives old emais to S3 if archival is enabled.

  ## Examples

      iex> PhoenixKit.EmailSystem.archive_to_s3()
      {:ok, archived_count: 100, s3_key: "archives/2024/01/emails.json"}
  """
  def archive_to_s3(days_old \\ nil) do
    if enabled?() and s3_archival_enabled?() do
      days = days_old || get_retention_days()
      logs_to_archive = EmailLog.get_logs_for_archival(days)

      if length(logs_to_archive) > 0 do
        # This would be implemented in a separate Archiver module
        # For now, return a placeholder
        {:ok, archived_count: length(logs_to_archive), logs: logs_to_archive}
      else
        {:ok, archived_count: 0, logs: []}
      end
    else
      {:ok, :skipped}
    end
  end

  ## --- Private Helper Functions ---

  # Ensure the system is enabled, raise if not
  defp ensure_enabled! do
    unless enabled?() do
      raise "Email system is not enabled"
    end
  end

  # Determine if an email should be logged based on sampling rate
  defp should_log_email?(_attrs) do
    sampling_rate = get_sampling_rate()

    if sampling_rate >= 100 do
      true
    else
      # Use deterministic sampling based on message_id or random
      :rand.uniform(100) <= sampling_rate
    end
  end

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end

  # Extract message ID from webhook data
  defp extract_message_id(webhook_data) do
    webhook_data["mail"]["messageId"] ||
      webhook_data["messageId"] ||
      get_in(webhook_data, ["mail", "commonHeaders", "messageId"])
  end

  # Process a specific event for an email log
  defp process_event_for_log(email_log, webhook_data) do
    case EmailEvent.create_from_ses_webhook(email_log, webhook_data) do
      {:ok, event} ->
        # Update email log status based on event
        update_log_status_from_event(email_log, event)
        {:ok, event}

      error ->
        error
    end
  end

  # Update email log status based on event type
  defp update_log_status_from_event(email_log, %PhoenixKit.EmailSystem.EmailEvent{
         event_type: "delivery"
       }) do
    EmailLog.mark_as_delivered(email_log)
  end

  defp update_log_status_from_event(email_log, %PhoenixKit.EmailSystem.EmailEvent{
         event_type: "bounce",
         bounce_type: bounce_type
       }) do
    EmailLog.mark_as_bounced(email_log, bounce_type)
  end

  defp update_log_status_from_event(email_log, %PhoenixKit.EmailSystem.EmailEvent{
         event_type: "open"
       }) do
    EmailLog.mark_as_opened(email_log)
  end

  defp update_log_status_from_event(email_log, %PhoenixKit.EmailSystem.EmailEvent{
         event_type: "click",
         link_url: url
       }) do
    EmailLog.mark_as_clicked(email_log, url)
  end

  defp update_log_status_from_event(_email_log, _event) do
    # No status update needed for other event types
    :ok
  end

  # Get compression setting
  defp get_compress_after_days do
    Settings.get_integer_setting("email_compress_body", 30)
  end

  # Check if S3 archival is enabled
  defp s3_archival_enabled? do
    Settings.get_boolean_setting("email_archive_to_s3", false)
  end

  # Check if CloudWatch metrics are enabled
  defp cloudwatch_metrics_enabled? do
    Settings.get_boolean_setting("email_cloudwatch_metrics", false)
  end

  # Get period start/end dates
  defp get_period_dates(:last_7_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -7, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_30_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -30, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_90_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -90, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_24_hours) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -1, :day)
    {start_date, end_date}
  end

  defp get_period_dates({:date_range, start_date, end_date})
       when is_struct(start_date, Date) and is_struct(end_date, Date) do
    start_datetime = DateTime.new!(start_date, ~T[00:00:00])
    end_datetime = DateTime.new!(end_date, ~T[23:59:59])
    {start_datetime, end_datetime}
  end

  # Calculate safe percentage
  defp safe_percentage(numerator, denominator) when denominator > 0 do
    (numerator / denominator * 100) |> Float.round(1)
  end

  defp safe_percentage(_, _), do: 0.0

  # Helper function to check if AWS credentials are configured
  # Checks both settings and environment variables (settings take priority)
  defp aws_configured? do
    access_key = get_aws_access_key()
    secret_key = get_aws_secret_key()

    access_key && secret_key && access_key != "" && secret_key != ""
  end

  # Get AWS configuration for ExAws
  defp get_aws_config do
    [
      access_key_id: get_aws_access_key(),
      secret_access_key: get_aws_secret_key(),
      region: __MODULE__.get_aws_region()
    ]
  end

  # Helper functions to get AWS settings with fallback
  defp get_aws_access_key do
    Settings.get_setting("aws_access_key_id")
    |> case do
      key when is_binary(key) and key != "" -> key
      _ -> System.get_env("AWS_ACCESS_KEY_ID")
    end
  end

  defp get_aws_secret_key do
    Settings.get_setting("aws_secret_access_key")
    |> case do
      key when is_binary(key) and key != "" -> key
      _ -> System.get_env("AWS_SECRET_ACCESS_KEY")
    end
  end

  # Validate SQS queue URL format
  defp valid_queue_url?(queue_url) when is_binary(queue_url) do
    # Expected format: https://sqs.{region}.amazonaws.com/{account_id}/{queue_name}
    case Regex.run(
           ~r|^https://sqs\.([a-z0-9-]+)\.amazonaws\.com/(\d+)/([a-zA-Z0-9_-]+)$|,
           queue_url
         ) do
      [_full, _region, _account_id, _queue_name] -> true
      _ -> false
    end
  end

  defp valid_queue_url?(_), do: false
end
