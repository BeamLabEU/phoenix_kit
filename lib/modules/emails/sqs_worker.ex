defmodule PhoenixKit.Modules.Emails.SQSWorker do
  @moduledoc """
  SQS Worker for processing email events from AWS SQS Queue.

  ## ⚠️ DEPRECATION NOTICE

  This GenServer-based worker is deprecated in favor of the Oban-based approach.
  For new installations, use `PhoenixKit.Modules.Emails.SQSPollingManager` instead.

  The GenServer approach has been replaced with Oban jobs to allow:
  - Dynamic enabling/disabling without application restart
  - Better job monitoring and failure tracking
  - Automatic retries via Oban's built-in retry mechanism
  - Integration with existing Oban infrastructure

  ## Migration Path

  If you're currently using SQSWorker, you can migrate to the new approach:

      # Old approach (GenServer)
      PhoenixKit.Modules.Emails.SQSWorker.status()
      PhoenixKit.Modules.Emails.SQSWorker.pause()
      PhoenixKit.Modules.Emails.SQSWorker.resume()

      # New approach (Oban-based)
      PhoenixKit.Modules.Emails.SQSPollingManager.status()
      PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()
      PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()

  ## Backward Compatibility

  This module maintains backward compatibility by delegating to SQSPollingManager
  where appropriate. The GenServer will still work but is not recommended for
  new installations.

  ## Architecture

  ```
  AWS SES → SNS Topic → SQS Queue → SQS Worker → Database
  ```

  ## Configuration

  All settings are retrieved from PhoenixKit Settings and checked dynamically:

  - `email_ses_events` - master switch for AWS SES events processing
  - `sqs_polling_enabled` - enable/disable polling
  - `sqs_polling_interval_ms` - interval between polling cycles
  - `sqs_max_messages_per_poll` - maximum messages per batch
  - `aws_sqs_queue_url` - SQS queue URL
  - `aws_region` - AWS region

  ## Usage (Legacy)

      # In supervision tree (deprecated)
      {PhoenixKit.Modules.Emails.SQSWorker, []}

      # Worker management (delegates to new API)
      PhoenixKit.Modules.Emails.SQSWorker.status()
      PhoenixKit.Modules.Emails.SQSWorker.process_now()
      PhoenixKit.Modules.Emails.SQSWorker.pause()
      PhoenixKit.Modules.Emails.SQSWorker.resume()

  """

  use GenServer
  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKit.Modules.Emails.SQSProcessor

  # 20 seconds
  @default_long_poll_timeout 20

  ## --- Client API ---

  @doc """
  Starts the SQS Worker process.

  ## Options

  - `:name` - process name (defaults to `__MODULE__`)

  ## Examples

      {:ok, pid} = PhoenixKit.Modules.Emails.SQSWorker.start_link()
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current status of the worker process.

  **Note**: This function now delegates to SQSPollingManager for consistency.

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSWorker.status()
      %{
        polling_enabled: true,
        messages_processed: 150,
        errors_count: 2,
        last_poll: ~U[2025-09-20 15:30:45.123456Z],
        queue_url: "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue",
        average_processing_time_ms: 45.2
      }
  """
  def status(worker \\ __MODULE__) do
    # Try new API first, fallback to GenServer if needed
    case get_status_from_manager() do
      {:ok, status} -> status
      :error -> get_status_from_genserver(worker)
    end
  end

  defp get_status_from_manager do
    {:ok, SQSPollingManager.status()}
  catch
    _, _ -> :error
  end

  defp get_status_from_genserver(worker) do
    GenServer.call(worker, :status)
  catch
    _, _ ->
      %{
        error: "Worker not responding",
        message: "Consider using PhoenixKit.Modules.Emails.SQSPollingManager.status() instead"
      }
  end

  @doc """
  Forces a polling cycle to start immediately.

  **Note**: This function now delegates to SQSPollingManager.

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSWorker.process_now()
      :ok
  """
  def process_now(_worker \\ __MODULE__) do
    Logger.info(
      "SQSWorker.process_now/1 is deprecated - delegating to SQSPollingManager.poll_now/0"
    )

    case SQSPollingManager.poll_now() do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Pauses polling (temporarily).

  **Note**: This function now delegates to SQSPollingManager.

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSWorker.pause()
      :ok
  """
  def pause(_worker \\ __MODULE__) do
    Logger.info(
      "SQSWorker.pause/1 is deprecated - delegating to SQSPollingManager.disable_polling/0"
    )

    case SQSPollingManager.disable_polling() do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Resumes polling after pause.

  **Note**: This function now delegates to SQSPollingManager.

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSWorker.resume()
      :ok
  """
  def resume(_worker \\ __MODULE__) do
    Logger.info(
      "SQSWorker.resume/1 is deprecated - delegating to SQSPollingManager.enable_polling/0"
    )

    case SQSPollingManager.enable_polling() do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Processes all messages from DLQ (Dead Letter Queue).

  This function retrieves all messages from DLQ, processes them through
  SQSProcessor, and optionally deletes successfully processed messages.

  ## Parameters

  - `opts` - Processing options:
    - `:batch_size` - Batch size (default 10)
    - `:delete_after` - Delete successfully processed messages (default false)
    - `:max_batches` - Maximum number of batches (default 100)

  ## Returns

  - `{:ok, result}` - Successful processing with results
  - `{:error, reason}` - Processing error

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSWorker.process_dlq_messages()
      {:ok, %{total_processed: 15, successful: 12, errors: 3}}

      iex> PhoenixKit.Modules.Emails.SQSWorker.process_dlq_messages(delete_after: true)
      {:ok, %{total_processed: 8, successful: 8, errors: 0, deleted: 8}}
  """
  def process_dlq_messages(opts \\ []) do
    GenServer.call(__MODULE__, {:process_dlq, opts}, 30_000)
  end

  @doc """
  Deletes processed messages from DLQ.

  ## Parameters

  - `receipt_handles` - List of receipt handles to delete

  ## Returns

  - `{:ok, deleted_count}` - Number of deleted messages
  - `{:error, reason}` - Deletion error

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSWorker.delete_dlq_messages(["receipt1", "receipt2"])
      {:ok, 2}
  """
  def delete_dlq_messages(receipt_handles) when is_list(receipt_handles) do
    GenServer.call(__MODULE__, {:delete_dlq_messages, receipt_handles}, 10_000)
  end

  ## --- Server Callbacks ---

  @doc false
  def init(_opts) do
    # Get configuration at startup
    config = Emails.get_sqs_config()

    state = %{
      queue_url: config.queue_url,
      polling_enabled: config.polling_enabled,
      polling_interval_ms: config.polling_interval_ms,
      max_messages_per_poll: config.max_messages_per_poll,
      visibility_timeout: config.visibility_timeout,
      paused: false,

      # AWS configuration
      aws_config: build_aws_config(config),

      # Metrics
      messages_processed: 0,
      errors_count: 0,
      last_poll: nil,
      total_processing_time_ms: 0,

      # Internal state
      poll_timer_ref: nil
    }

    # Check configuration validity
    case validate_configuration(state) do
      :ok ->
        if state.polling_enabled and not state.paused do
          # Start immediately
          {:ok, schedule_next_poll(state, 0)}
        else
          Logger.info("SQS Worker started but polling is disabled")
          {:ok, state}
        end

      {:error, reason} ->
        Logger.error("SQS Worker failed to start: #{reason}")
        {:ok, %{state | polling_enabled: false}}
    end
  end

  @doc false
  def handle_info(:poll_sqs, state) do
    # Check current polling status from database (dynamic check)
    ses_events_enabled = Emails.ses_events_enabled?()
    current_polling_enabled = Emails.sqs_polling_enabled?()

    cond do
      # AWS SES events processing is disabled - stop polling
      not ses_events_enabled ->
        if state.polling_enabled do
          Logger.info("SQS Worker: AWS SES events disabled via settings, stopping polling cycle")
        end

        # Check status again after 30 seconds to detect if it was re-enabled
        new_state =
          %{state | polling_enabled: false}
          |> schedule_next_poll(30_000, true)

        {:noreply, new_state}

      # Polling is enabled and not paused - perform normal polling cycle
      ses_events_enabled and current_polling_enabled and not state.paused ->
        # Log if polling was just re-enabled
        if not state.polling_enabled do
          Logger.info("SQS Worker: Polling enabled via settings, resuming polling cycle")
        end

        new_state =
          %{state | polling_enabled: true}
          |> perform_polling_cycle()
          |> schedule_next_poll(state.polling_interval_ms)

        {:noreply, new_state}

      # Polling is disabled - log once and schedule status check
      not current_polling_enabled ->
        if state.polling_enabled do
          Logger.info("SQS Worker: Polling disabled via settings, stopping polling cycle")
        end

        # Check status again after 30 seconds to detect if polling was re-enabled
        new_state =
          %{state | polling_enabled: false}
          |> schedule_next_poll(30_000, true)

        {:noreply, new_state}

      # Worker is paused - keep checking
      state.paused ->
        new_state = schedule_next_poll(state, state.polling_interval_ms)
        {:noreply, new_state}
    end
  end

  @doc false
  def handle_cast(:process_now, state) do
    Logger.info("SQS Worker: Processing triggered manually")
    new_state = perform_polling_cycle(state)
    {:noreply, new_state}
  end

  def handle_cast(:pause, state) do
    Logger.info("SQS Worker: Paused")
    new_state = cancel_timer(%{state | paused: true})
    {:noreply, new_state}
  end

  def handle_cast(:resume, state) do
    Logger.info("SQS Worker: Resumed")

    new_state =
      %{state | paused: false}
      # Resume immediately
      |> schedule_next_poll(0)

    {:noreply, new_state}
  end

  @doc false
  def handle_call(:status, _from, state) do
    average_processing_time =
      if state.messages_processed > 0 do
        state.total_processing_time_ms / state.messages_processed
      else
        0.0
      end

    status = %{
      polling_enabled: state.polling_enabled,
      paused: state.paused,
      messages_processed: state.messages_processed,
      errors_count: state.errors_count,
      last_poll: state.last_poll,
      queue_url: state.queue_url,
      average_processing_time_ms: Float.round(average_processing_time, 2)
    }

    {:reply, status, state}
  end

  @doc false
  def handle_call({:process_dlq, opts}, _from, state) do
    batch_size = Keyword.get(opts, :batch_size, 10)
    delete_after = Keyword.get(opts, :delete_after, false)
    max_batches = Keyword.get(opts, :max_batches, 100)

    dlq_url = PhoenixKit.Settings.get_setting("aws_sqs_dlq_url")

    if dlq_url do
      result = process_dlq_batches_sync(dlq_url, batch_size, delete_after, max_batches)
      {:reply, {:ok, result}, state}
    else
      {:reply, {:error, :dlq_url_not_configured}, state}
    end
  rescue
    error ->
      Logger.error("DLQ processing failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @doc false
  def handle_call({:delete_dlq_messages, receipt_handles}, _from, state) do
    dlq_url = PhoenixKit.Settings.get_setting("aws_sqs_dlq_url")

    if dlq_url do
      deleted_count = delete_messages_from_dlq(dlq_url, receipt_handles)
      {:reply, {:ok, deleted_count}, state}
    else
      {:reply, {:error, :dlq_url_not_configured}, state}
    end
  rescue
    error ->
      Logger.error("DLQ message deletion failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @doc false
  def terminate(reason, state) do
    Logger.info("SQS Worker shutting down", %{reason: inspect(reason)})
    cancel_timer(state)
    :ok
  end

  ## --- Private Helper Functions ---

  # Performs one SQS polling cycle
  defp perform_polling_cycle(state) do
    _start_time = System.monotonic_time(:millisecond)

    case receive_messages(state) do
      {:ok, [_ | _] = messages} ->
        Logger.info("SQS Worker: Received #{length(messages)} messages")

        processing_start = System.monotonic_time(:millisecond)
        processed_count = process_messages(messages, state)
        processing_time = System.monotonic_time(:millisecond) - processing_start

        %{
          state
          | messages_processed: state.messages_processed + processed_count,
            total_processing_time_ms: state.total_processing_time_ms + processing_time,
            last_poll: DateTime.utc_now()
        }

      {:ok, []} ->
        %{state | last_poll: DateTime.utc_now()}

      {:error, reason} ->
        Logger.error("SQS Worker: Failed to receive messages", %{
          reason: inspect(reason),
          queue_url: state.queue_url
        })

        %{state | errors_count: state.errors_count + 1, last_poll: DateTime.utc_now()}
    end
  end

  # Retrieves messages from SQS queue
  defp receive_messages(state) do
    case state.queue_url do
      nil ->
        {:error, :queue_url_not_configured}

      queue_url when is_binary(queue_url) ->
        request =
          ExAws.SQS.receive_message(
            queue_url,
            max_number_of_messages: state.max_messages_per_poll,
            wait_time_seconds: @default_long_poll_timeout,
            visibility_timeout: state.visibility_timeout,
            message_attribute_names: [:all],
            attribute_names: [:all]
          )

        case ExAws.request(request, state.aws_config) do
          # Handle all possible response formats from ExAws
          {:ok, %{"Messages" => messages}} when is_list(messages) ->
            {:ok, messages}

          {:ok, %{"messages" => messages}} when is_list(messages) ->
            {:ok, messages}

          {:ok, %{body: %{messages: messages}}} when is_list(messages) ->
            {:ok, messages}

          {:ok, %{body: %{"Messages" => messages}}} when is_list(messages) ->
            {:ok, messages}

          {:ok, %{body: %{"messages" => messages}}} when is_list(messages) ->
            {:ok, messages}

          {:ok, _response} ->
            # No messages (any other successful response)
            {:ok, []}

          {:error, error} ->
            error_info = safe_extract_error_info(error)

            Logger.error("SQS Worker: ExAws request failed", %{
              error: inspect(error),
              error_type: error_info.type,
              error_details: error_info.details,
              queue_url: queue_url
            })

            {:error, error}
        end
    end
  end

  # Processes message list in parallel
  defp process_messages(messages, state) do
    # Create tasks for parallel processing
    tasks =
      Enum.map(messages, fn message ->
        Task.async(fn ->
          process_single_message(message, state.queue_url, state.aws_config)
        end)
      end)

    # Wait for all tasks to complete
    results = Task.await_many(tasks, 30_000)

    # Count successfully processed
    Enum.count(results, & &1)
  end

  # Processes a single message
  defp process_single_message(message, queue_url, aws_config) do
    message_id = message["MessageId"]
    receipt_handle = message["ReceiptHandle"]

    with {:ok, event_data} <- SQSProcessor.parse_sns_message(message),
         {:ok, _result} <- SQSProcessor.process_email_event(event_data),
         :ok <- delete_message(queue_url, receipt_handle, aws_config) do
      true
    else
      {:error, reason} ->
        Logger.error("Failed to process SQS message", %{
          message_id: message_id,
          reason: inspect(reason)
        })

        false
    end
  end

  # Deletes processed message from queue
  defp delete_message(queue_url, receipt_handle, aws_config) do
    ExAws.SQS.delete_message(queue_url, receipt_handle)
    |> ExAws.request(aws_config)
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to delete SQS message", %{
          error: inspect(error),
          error_type: if(is_map(error), do: error.__struct__, else: :unknown),
          queue_url: queue_url,
          receipt_handle: String.slice(receipt_handle, 0, 50) <> "...",
          has_aws_config: not Enum.empty?(aws_config)
        })

        # Non-critical error, message will return to queue
        :ok
    end
  end

  # Schedules the next polling cycle
  defp schedule_next_poll(state, delay_ms, force \\ false) do
    new_state = cancel_timer(state)

    # Schedule next cycle if:
    # - polling is enabled and not paused, OR
    # - force is true (for status checks when polling is disabled)
    if (new_state.polling_enabled and not new_state.paused) or force do
      timer_ref = Process.send_after(self(), :poll_sqs, delay_ms)
      %{new_state | poll_timer_ref: timer_ref}
    else
      new_state
    end
  end

  # Cancels the current timer
  defp cancel_timer(state) do
    if state.poll_timer_ref do
      Process.cancel_timer(state.poll_timer_ref)
    end

    %{state | poll_timer_ref: nil}
  end

  # Validates configuration correctness
  defp validate_configuration(state) do
    cond do
      is_nil(state.queue_url) or state.queue_url == "" ->
        {:error, "SQS queue URL not configured"}

      Enum.empty?(state.aws_config) ->
        Logger.warning(
          "AWS credentials not configured - will use default credential provider chain"
        )

        validate_other_configuration(state)

      not is_list(state.aws_config) ->
        {:error, "Invalid AWS configuration format"}

      true ->
        validate_other_configuration(state)
    end
  end

  # Validates other configuration (non-AWS)
  defp validate_other_configuration(state) do
    cond do
      not is_integer(state.polling_interval_ms) or state.polling_interval_ms <= 0 ->
        {:error, "Invalid polling interval"}

      not is_integer(state.max_messages_per_poll) or
        state.max_messages_per_poll <= 0 or
          state.max_messages_per_poll > 10 ->
        {:error, "Invalid max messages per poll (must be 1-10)"}

      not is_integer(state.visibility_timeout) or state.visibility_timeout <= 0 ->
        {:error, "Invalid visibility timeout"}

      true ->
        :ok
    end
  end

  # Builds AWS configuration from settings
  defp build_aws_config(config) do
    if config.aws_access_key_id && config.aws_secret_access_key && config.aws_region do
      [
        access_key_id: config.aws_access_key_id,
        secret_access_key: config.aws_secret_access_key,
        region: config.aws_region
      ]
    else
      # If AWS credentials are not configured, use empty list
      # ExAws will use default credential provider chain
      []
    end
  end

  # Safely extracts error information
  defp safe_extract_error_info(error) do
    if is_map(error) and Map.has_key?(error, :__struct__) do
      %{
        type: error.__struct__,
        details: Map.from_struct(error)
      }
    else
      %{
        type: :string_error,
        details: %{message: to_string(error)}
      }
    end
  rescue
    _ ->
      %{
        type: :unknown_error,
        details: %{message: "Failed to extract error details"}
      }
  end

  # Synchronous processing of message batches from DLQ
  defp process_dlq_batches_sync(dlq_url, batch_size, delete_after, max_batches) do
    Logger.info("Processing DLQ messages", %{
      dlq_url: dlq_url,
      batch_size: batch_size,
      delete_after: delete_after,
      max_batches: max_batches
    })

    process_dlq_batches_recursive(dlq_url, batch_size, delete_after, max_batches, 0, %{
      total_processed: 0,
      successful: 0,
      errors: 0,
      deleted: 0
    })
  end

  # Recursive DLQ batch processing
  defp process_dlq_batches_recursive(
         dlq_url,
         batch_size,
         delete_after,
         max_batches,
         current_batch,
         stats
       ) do
    if current_batch >= max_batches do
      Logger.warning("Reached max batches limit", %{
        current_batch: current_batch,
        max_batches: max_batches
      })

      stats
    else
      messages =
        ExAws.SQS.receive_message(dlq_url,
          max_number_of_messages: batch_size,
          wait_time_seconds: 1
        )
        |> ExAws.request()
        |> case do
          {:ok, %{body: %{messages: messages}}} -> messages
          _ -> []
        end

      if Enum.empty?(messages) do
        Logger.info("No more messages in DLQ", %{batches_processed: current_batch})
        stats
      else
        Logger.info("Processing DLQ batch #{current_batch + 1}: #{length(messages)} messages")

        {successful_count, error_count, processed_receipts} = process_dlq_message_batch(messages)

        new_stats = %{
          total_processed: stats.total_processed + length(messages),
          successful: stats.successful + successful_count,
          errors: stats.errors + error_count,
          deleted: stats.deleted
        }

        # Delete successfully processed messages if required
        final_stats =
          if delete_after and not Enum.empty?(processed_receipts) do
            deleted_count = delete_messages_from_dlq(dlq_url, processed_receipts)
            %{new_stats | deleted: new_stats.deleted + deleted_count}
          else
            new_stats
          end

        # Continue processing next batch
        process_dlq_batches_recursive(
          dlq_url,
          batch_size,
          delete_after,
          max_batches,
          current_batch + 1,
          final_stats
        )
      end
    end
  end

  # Processing one batch of messages from DLQ
  defp process_dlq_message_batch(messages) do
    results =
      Enum.map(messages, fn message ->
        case SQSProcessor.parse_sns_message(message) do
          {:ok, event_data} ->
            message_id = get_in(event_data, ["mail", "messageId"])
            event_type = event_data["eventType"]

            case SQSProcessor.process_email_event(event_data) do
              {:ok, _result} ->
                {:ok, message["ReceiptHandle"]}

              {:error, reason} ->
                Logger.warning(
                  "Failed to process #{event_type} for #{message_id}: #{inspect(reason)}"
                )

                {:error, reason}
            end

          {:error, reason} ->
            Logger.warning("Failed to parse DLQ message: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    successful_results =
      Enum.filter(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    error_results =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)

    processed_receipts = Enum.map(successful_results, fn {:ok, receipt} -> receipt end)

    {length(successful_results), length(error_results), processed_receipts}
  end

  # Deleting messages from DLQ
  defp delete_messages_from_dlq(dlq_url, receipt_handles) do
    Logger.info("Deleting #{length(receipt_handles)} messages from DLQ")

    successful_deletes =
      Enum.count(receipt_handles, fn receipt_handle ->
        try do
          ExAws.SQS.delete_message(dlq_url, receipt_handle)
          |> ExAws.request()
          |> case do
            {:ok, _} ->
              true

            {:error, reason} ->
              Logger.error("Failed to delete DLQ message: #{inspect(reason)}")
              false
          end
        rescue
          error ->
            Logger.error("Exception while deleting DLQ message: #{inspect(error)}")
            false
        end
      end)

    Logger.info(
      "Successfully deleted #{successful_deletes}/#{length(receipt_handles)} messages from DLQ"
    )

    successful_deletes
  end
end
