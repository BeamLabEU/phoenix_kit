defmodule PhoenixKit.Modules.Emails.Supervisor do
  @moduledoc """
  Supervisor for PhoenixKit email tracking system.

  This module manages all processes necessary for email tracking:
  - SQS Worker for processing events from AWS SQS
  - Additional processes (metrics, archiving, etc.)

  ## Integration into Parent Application

  Add supervisor to your application's supervision tree:

      # In lib/your_app/application.ex
      def start(_type, _args) do
        children = [
          # ... your other processes

          # PhoenixKit Email Tracking
          Emails.Supervisor
        ]

        opts = [strategy: :one_for_one, name: YourApp.Supervisor]
        Supervisor.start_link(children, opts)
      end

  ## Configuration

  Supervisor automatically reads settings from PhoenixKit Settings:

  - `sqs_polling_enabled` - enable/disable SQS Worker
  - `sqs_polling_interval_ms` - polling interval
  - other SQS settings

  ## Process Management

      # Stop SQS Worker
      Emails.SQSWorker.pause()

      # Start SQS Worker
      Emails.SQSWorker.resume()

      # Check status
      Emails.SQSWorker.status()

  ## Monitoring

  Supervisor provides information about process state:

      # Get list of child processes
      Supervisor.which_children(Emails.Supervisor)

      # Get process count
      Supervisor.count_children(Emails.Supervisor)
  """

  use Supervisor

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQS.PollingManager, as: SQSPollingManager
  alias PhoenixKit.Modules.Emails.SQS.Worker, as: SQSWorker

  @doc """
  Starts supervisor for email tracking system.

  ## Options

  - `:name` - supervisor process name (defaults to `__MODULE__`)

  ## Examples

      {:ok, pid} = Emails.Supervisor.start_link()
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def init(_opts) do
    children = build_children()

    # Start initial SQS polling job if enabled
    start_initial_sqs_polling_job()

    # Use :one_for_one strategy - if one process crashes,
    # only that one is restarted
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns information about email tracking system status.

  ## Examples

      iex> Emails.Supervisor.system_status()
      %{
        supervisor_running: true,
        sqs_worker_running: true,
        sqs_worker_status: %{polling_enabled: true, ...},
        children_count: 1
      }
  """
  def system_status(supervisor \\ __MODULE__) do
    children = Supervisor.which_children(supervisor)
    child_count = Supervisor.count_children(supervisor)

    sqs_worker_running =
      Enum.any?(children, fn {id, _pid, _type, _modules} ->
        id == Emails.SQSWorker
      end)

    sqs_worker_status =
      if sqs_worker_running do
        try do
          SQSWorker.status()
        catch
          _, _ -> %{error: "worker_not_responding"}
        end
      else
        %{error: "worker_not_started"}
      end

    %{
      supervisor_running: true,
      sqs_worker_running: sqs_worker_running,
      sqs_worker_status: sqs_worker_status,
      children_count: child_count.active,
      total_restarts: child_count.workers
    }
  catch
    _, _ ->
      %{
        supervisor_running: false,
        error: "supervisor_not_accessible"
      }
  end

  @doc """
  Stops and restarts SQS Worker.

  Useful for applying new configuration settings.

  ## Examples

      iex> Emails.Supervisor.restart_sqs_worker()
      :ok
  """
  def restart_sqs_worker(supervisor \\ __MODULE__) do
    case Supervisor.terminate_child(supervisor, Emails.SQSWorker) do
      :ok ->
        case Supervisor.restart_child(supervisor, Emails.SQSWorker) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## --- Helper Functions for Integration ---

  @doc """
  Returns child spec for integration into parent supervisor.

  This function is used when you want more precise control
  over email tracking integration in your application.

  ## Examples

      # In lib/your_app/application.ex
      def start(_type, _args) do
        children = [
          # ... other processes
          Emails.Supervisor.child_spec([])
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  ## --- Private Functions ---

  # Builds list of child processes based on configuration
  defp build_children do
    children = []

    # Add SQS Worker if polling is enabled
    children =
      if should_start_sqs_worker?() do
        [build_sqs_worker_spec() | children]
      else
        children
      end

    # In the future, other processes can be added here:
    # - Metrics collector
    # - Archiving worker
    # - Cleanup scheduler

    children
  end

  # Checks whether SQS Worker should start
  defp should_start_sqs_worker? do
    # Check that email tracking is enabled
    # Check that AWS SES events processing is enabled
    # Check that SQS polling is enabled
    # Check that SQS settings exist
    Emails.enabled?() &&
      Emails.ses_events_enabled?() &&
      Emails.sqs_polling_enabled?() &&
      has_sqs_configuration?()
  end

  # Checks for minimum SQS configuration
  defp has_sqs_configuration? do
    sqs_config = Emails.get_sqs_config()

    not is_nil(sqs_config.queue_url) and
      sqs_config.queue_url != ""
  end

  # Creates child spec for SQS Worker
  defp build_sqs_worker_spec do
    %{
      id: Emails.SQSWorker,
      start: {Emails.SQSWorker, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      # 10 seconds for graceful shutdown
      shutdown: 10_000
    }
  end

  # Start initial SQS polling job if enabled
  # Uses spawn to defer job creation until Oban is ready
  defp start_initial_sqs_polling_job do
    if should_start_oban_polling?() do
      # Spawn a process that waits for Oban to be ready before creating the job
      spawn(fn ->
        # Wait for Oban to start (max 10 attempts with 500ms delay)
        wait_for_oban(10, 500)

        Logger.info("Email Supervisor: Starting initial SQS polling job via Oban")

        case SQSPollingManager.enable_polling() do
          {:ok, job} ->
            Logger.info("Email Supervisor: Initial SQS polling job started", %{job_id: job.id})

          {:error, reason} ->
            Logger.warning("Email Supervisor: Failed to start initial SQS polling job", %{
              reason: inspect(reason)
            })
        end
      end)
    end
  end

  # Wait for Oban to be available
  defp wait_for_oban(0, _delay), do: :timeout

  defp wait_for_oban(attempts, delay) do
    case Oban.Registry.config(Oban) do
      %Oban.Config{} ->
        :ok
    end
  catch
    _, _ ->
      Process.sleep(delay)
      wait_for_oban(attempts - 1, delay)
  end

  # Check if Oban-based polling should start
  defp should_start_oban_polling? do
    Emails.enabled?() &&
      Emails.ses_events_enabled?() &&
      Emails.sqs_polling_enabled?() &&
      has_sqs_configuration?()
  end
end
