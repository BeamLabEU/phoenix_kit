defmodule PhoenixKit.PubSub.Manager do
  @moduledoc """
  PubSub Manager for PhoenixKit admin live updates.

  Manages its own PubSub system independent of parent applications.
  Automatically starts when needed and provides simple broadcast/subscribe API.
  """

  use GenServer
  require Logger

  @pubsub_name :phoenix_kit_internal_pubsub
  @manager_name __MODULE__

  ## Public API

  @doc """
  Broadcasts a message to a topic.
  """
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub_name, topic, message)
  end

  @doc """
  Subscribes to a topic.
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub_name, topic)
  end

  @doc """
  Unsubscribes from a topic.
  """
  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub_name, topic)
  end

  @doc """
  Starts the PubSub manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @manager_name)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Start our own PubSub system
    children = [
      {Phoenix.PubSub, name: @pubsub_name, adapter: Phoenix.PubSub.PG2}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, supervisor_pid} ->
        Logger.debug("PhoenixKit PubSub system started with PID: #{inspect(supervisor_pid)}")
        {:ok, %{supervisor: supervisor_pid, pubsub_name: @pubsub_name}}

      {:error, reason} ->
        Logger.error("Failed to start PhoenixKit PubSub system: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      pubsub_name: state.pubsub_name,
      supervisor_pid: state.supervisor,
      running: Process.alive?(state.supervisor)
    }

    {:reply, status, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("PhoenixKit.PubSub.Manager terminating: #{inspect(reason)}")

    # Supervisor will handle cleanup of PubSub
    if state.supervisor && Process.alive?(state.supervisor) do
      Supervisor.stop(state.supervisor)
    end

    :ok
  end
end
