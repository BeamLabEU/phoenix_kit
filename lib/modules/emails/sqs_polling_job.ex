defmodule PhoenixKit.Modules.Emails.SQSPollingJob do
  @moduledoc """
  Oban worker for polling AWS SQS queue for email events.

  This worker replaces the GenServer-based SQSWorker with an Oban-based
  approach that allows dynamic enabling/disabling without application restart.

  ## Architecture

  ```
  AWS SES → SNS Topic → SQS Queue → SQSPollingJob (Oban) → SQSProcessor → Database
  ```

  ## Features

  - **Dynamic Configuration**: Automatically responds to settings changes without restart
  - **Oban Integration**: Uses Oban's job system for reliable background processing
  - **Self-Scheduling**: Each job schedules the next polling cycle
  - **Batch Processing**: Process up to 10 messages at a time
  - **Error Handling**: Retry logic with Dead Letter Queue
  - **Settings-Based Control**: Polling can be enabled/disabled via Settings

  ## Configuration

  All settings are retrieved from PhoenixKit Settings:

  - `sqs_polling_enabled` - enable/disable polling (checked before each cycle)
  - `sqs_polling_interval_ms` - interval between polling cycles
  - `sqs_max_messages_per_poll` - maximum messages per batch
  - `sqs_visibility_timeout` - time for message processing
  - `aws_sqs_queue_url` - SQS queue URL
  - `aws_region` - AWS region

  ## Usage

      # Enable polling (starts first job)
      PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()

      # Disable polling (stops scheduling new jobs)
      PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()

      # Trigger immediate polling
      PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()

      # Check status
      PhoenixKit.Modules.Emails.SQSPollingManager.status()

  ## Oban Queue Configuration

  Add to your `config/config.exs`:

      config :your_app, Oban,
        repo: YourApp.Repo,
        queues: [
          sqs_polling: 1  # Only one concurrent polling job
        ]

  ## Implementation Notes

  - Uses `unique: [period: 60]` to prevent duplicate jobs
  - Schedules next job only if polling is enabled
  - Uses existing SQSProcessor for event processing
  - Compatible with existing SQSWorker API
  """

  use Oban.Worker,
    queue: :sqs_polling,
    max_attempts: 3,
    # Short unique period to prevent duplicate submissions while allowing self-scheduling
    # 10 seconds is enough to prevent accidental double-clicks but allows 5s polling interval
    unique: [period: 10, states: [:scheduled, :available, :executing]]

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSProcessor

  @default_long_poll_timeout 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Check if polling is enabled before processing
    if should_poll?() do
      Logger.debug("SQS Polling Job: Starting polling cycle")

      config = Emails.get_sqs_config()

      case validate_configuration(config) do
        :ok ->
          result = perform_polling_cycle(config)
          schedule_next_poll(config.polling_interval_ms)
          result

        {:error, reason} ->
          Logger.error("SQS Polling Job: Invalid configuration - #{reason}")
          {:error, reason}
      end
    else
      Logger.debug("SQS Polling Job: Polling disabled, skipping cycle")
      :ok
    end
  end

  @doc """
  Cancels all scheduled SQS polling jobs.

  Called when polling is disabled to immediately clean up pending jobs.

  ## Returns

  - `{:ok, count}` - Number of cancelled jobs

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingJob.cancel_scheduled()
      {:ok, 2}
  """
  @spec cancel_scheduled() :: {:ok, non_neg_integer()}
  def cancel_scheduled do
    worker_name = inspect(__MODULE__)

    {count, _} =
      Oban.Job
      |> where([j], j.worker == ^worker_name)
      |> where([j], j.state in ["available", "scheduled"])
      |> get_repo().delete_all()

    Logger.info("SQSPollingJob: Cancelled #{count} scheduled jobs")
    {:ok, count}
  end

  defp get_repo do
    PhoenixKit.RepoHelper.repo()
  end

  ## --- Private Functions ---

  # Check if polling should be performed
  defp should_poll? do
    Emails.enabled?() and
      Emails.ses_events_enabled?() and
      Emails.sqs_polling_enabled?()
  end

  # Validate SQS configuration
  defp validate_configuration(config) do
    cond do
      is_nil(config.queue_url) or config.queue_url == "" ->
        {:error, "SQS queue URL not configured"}

      not is_integer(config.polling_interval_ms) or config.polling_interval_ms <= 0 ->
        {:error, "Invalid polling interval"}

      not is_integer(config.max_messages_per_poll) or
        config.max_messages_per_poll <= 0 or
          config.max_messages_per_poll > 10 ->
        {:error, "Invalid max messages per poll (must be 1-10)"}

      not is_integer(config.visibility_timeout) or config.visibility_timeout <= 0 ->
        {:error, "Invalid visibility timeout"}

      true ->
        :ok
    end
  end

  # Perform one polling cycle
  defp perform_polling_cycle(config) do
    _start_time = System.monotonic_time(:millisecond)

    case receive_messages(config) do
      {:ok, [_ | _] = messages} ->
        Logger.info("SQS Polling Job: Received #{length(messages)} messages")

        processing_start = System.monotonic_time(:millisecond)
        processed_count = process_messages(messages, config)
        processing_time = System.monotonic_time(:millisecond) - processing_start

        Logger.info(
          "SQS Polling Job: Processed #{processed_count}/#{length(messages)} messages in #{processing_time}ms"
        )

        {:ok,
         %{processed: processed_count, total: length(messages), duration_ms: processing_time}}

      {:ok, []} ->
        Logger.debug("SQS Polling Job: No messages in queue")
        {:ok, %{processed: 0, total: 0}}

      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to receive messages", %{
          reason: inspect(reason),
          queue_url: config.queue_url
        })

        {:error, reason}
    end
  end

  # Receive messages from SQS queue
  defp receive_messages(config) do
    aws_config = build_aws_config(config)

    request =
      ExAws.SQS.receive_message(
        config.queue_url,
        max_number_of_messages: config.max_messages_per_poll,
        wait_time_seconds: @default_long_poll_timeout,
        visibility_timeout: config.visibility_timeout,
        message_attribute_names: [:all],
        attribute_names: [:all]
      )

    case ExAws.request(request, aws_config) do
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
        {:ok, []}

      {:error, error} ->
        Logger.error("SQS Polling Job: ExAws request failed", %{
          error: inspect(error),
          queue_url: config.queue_url
        })

        {:error, error}
    end
  end

  # Process message list in parallel
  defp process_messages(messages, config) do
    aws_config = build_aws_config(config)

    tasks =
      Enum.map(messages, fn message ->
        Task.async(fn ->
          process_single_message(message, config.queue_url, aws_config)
        end)
      end)

    results = Task.await_many(tasks, 30_000)
    Enum.count(results, & &1)
  end

  # Process a single message
  defp process_single_message(message, queue_url, aws_config) do
    message_id = message["MessageId"]
    receipt_handle = message["ReceiptHandle"]

    with {:ok, event_data} <- SQSProcessor.parse_sns_message(message),
         {:ok, _result} <- SQSProcessor.process_email_event(event_data),
         :ok <- delete_message(queue_url, receipt_handle, aws_config) do
      true
    else
      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to process message", %{
          message_id: message_id,
          reason: inspect(reason)
        })

        false
    end
  end

  # Delete processed message from queue
  defp delete_message(queue_url, receipt_handle, aws_config) do
    ExAws.SQS.delete_message(queue_url, receipt_handle)
    |> ExAws.request(aws_config)
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("SQS Polling Job: Failed to delete message", %{
          error: inspect(error),
          queue_url: queue_url
        })

        :ok
    end
  end

  # Schedule next polling job
  defp schedule_next_poll(interval_ms) do
    if should_poll?() do
      %{}
      |> __MODULE__.new(schedule_in: div(interval_ms, 1000))
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          Logger.debug("SQS Polling Job: Next poll scheduled in #{interval_ms}ms")
          :ok

        {:error, reason} ->
          Logger.error("SQS Polling Job: Failed to schedule next poll", %{
            reason: inspect(reason)
          })

          :ok
      end
    else
      Logger.debug("SQS Polling Job: Polling disabled, not scheduling next poll")
      :ok
    end
  end

  # Build AWS configuration
  defp build_aws_config(config) do
    if config.aws_access_key_id != "" and config.aws_secret_access_key != "" and
         config.aws_region != "" do
      [
        access_key_id: String.trim(config.aws_access_key_id),
        secret_access_key: String.trim(config.aws_secret_access_key),
        region: String.trim(config.aws_region)
      ]
    else
      []
    end
  end
end
