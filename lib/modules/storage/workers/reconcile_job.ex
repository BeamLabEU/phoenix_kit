defmodule PhoenixKit.Modules.Storage.Workers.ReconcileJob do
  @moduledoc """
  The trigger of the storage reconciler (V205). It queues nothing to walk files
  itself any more: since job runs (`PhoenixKit.Jobs`) the walk is a run per
  library, `Storage.Jobs.Reconcile`, which an admin can watch and pause on
  Settings → Media → Libraries and Admin → Jobs. This worker is what every place
  that *changes* storage settings still queues (`enqueue/0`): its job starts those
  runs (`Reconcile.trigger/1`) for the libraries that have files to bring up to
  date.

  Why a job rather than starting the runs directly: a profile or variant set
  changes inside a transaction in several places, and a run cannot be started
  from inside one (the engine refuses, so nothing it announces escapes a
  rollback). An Oban insert commits with the caller's transaction and runs after
  it. Only one pending trigger exists at a time (`unique` over `[:worker, :queue]`);
  a job queued by an earlier release, with a cursor in its args, simply triggers.
  """

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: [:available, :scheduled]]

  alias PhoenixKit.Modules.Storage.Jobs.Reconcile
  alias PhoenixKit.Modules.Storage.Reconciler

  @batch_size 10

  @doc """
  Queues the trigger. Never raises: a change must not fail because Oban is not
  running (a test, a Mix task); the daily prune and the next boot queue one anyway.
  """
  @spec enqueue() :: :queued | :unavailable
  def enqueue do
    case Oban.insert(new(%{})) do
      {:ok, _job} -> :queued
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc "Queues the trigger when any file is stale. Never raises."
  @spec maybe_enqueue() :: :queued | :nothing_to_do | :unavailable
  def maybe_enqueue do
    if Reconciler.pending?(), do: enqueue(), else: :nothing_to_do
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Reconcile.trigger() do
      {:ok, _libraries} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a whole pass in the calling process and returns the totals
  (`:reconciled`, `:stale`, `:skipped`). For tests and Mix tasks.
  """
  @spec run_pass() :: map()
  def run_pass, do: run_pass(nil, %{})

  defp run_pass(cursor, totals) do
    case Reconciler.run_batch(cursor, @batch_size, totals) do
      {:more, last_uuid, totals} -> run_pass(last_uuid, totals)
      {:done, totals} -> totals
    end
  end
end
