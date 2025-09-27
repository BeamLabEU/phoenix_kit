defmodule PhoenixKit.EmailSystem.Supervisor do
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
          PhoenixKit.EmailSystem.Supervisor
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
      PhoenixKit.EmailSystem.SQSWorker.pause()

      # Start SQS Worker
      PhoenixKit.EmailSystem.SQSWorker.resume()

      # Check status
      PhoenixKit.EmailSystem.SQSWorker.status()

  ## Monitoring

  Supervisor provides information about process state:

      # Get list of child processes
      Supervisor.which_children(PhoenixKit.EmailSystem.Supervisor)

      # Get process count
      Supervisor.count_children(PhoenixKit.EmailSystem.Supervisor)
  """

  use Supervisor

  alias PhoenixKit.EmailSystem.SQSWorker

  @doc """
  Starts supervisor for email tracking system.

  ## Options

  - `:name` - supervisor process name (defaults to `__MODULE__`)

  ## Examples

      {:ok, pid} = PhoenixKit.EmailSystem.Supervisor.start_link()
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def init(_opts) do
    children = build_children()

    # Use :one_for_one strategy - if one process crashes,
    # only that one is restarted
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns information about email tracking system status.

  ## Examples

      iex> PhoenixKit.EmailSystem.Supervisor.system_status()
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
        id == PhoenixKit.EmailSystem.SQSWorker
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

      iex> PhoenixKit.EmailSystem.Supervisor.restart_sqs_worker()
      :ok
  """
  def restart_sqs_worker(supervisor \\ __MODULE__) do
    case Supervisor.terminate_child(supervisor, PhoenixKit.EmailSystem.SQSWorker) do
      :ok ->
        case Supervisor.restart_child(supervisor, PhoenixKit.EmailSystem.SQSWorker) do
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
          PhoenixKit.EmailSystem.Supervisor.child_spec([])
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
    # - CloudWatch metrics publisher

    children
  end

  # Checks whether SQS Worker should start
  defp should_start_sqs_worker? do
    # Check that email tracking is enabled
    # Check that SQS polling is enabled
    # Check that SQS settings exist
    PhoenixKit.EmailSystem.enabled?() &&
      PhoenixKit.EmailSystem.sqs_polling_enabled?() &&
      has_sqs_configuration?()
  end

  # Checks for minimum SQS configuration
  defp has_sqs_configuration? do
    sqs_config = PhoenixKit.EmailSystem.get_sqs_config()

    not is_nil(sqs_config.queue_url) and
      sqs_config.queue_url != ""
  end

  # Creates child spec for SQS Worker
  defp build_sqs_worker_spec do
    %{
      id: PhoenixKit.EmailSystem.SQSWorker,
      start: {PhoenixKit.EmailSystem.SQSWorker, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      # 10 seconds for graceful shutdown
      shutdown: 10_000
    }
  end
end
