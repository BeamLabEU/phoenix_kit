defmodule PhoenixKit.Modules.Publishing.Workers.MigrateLegacyStructureWorker do
  @moduledoc """
  Oban worker for migrating legacy structure posts to versioned structure.

  No-op in DB-only mode — database posts are inherently versioned.
  Kept for API compatibility with listing UI.

  ## Usage

      MigrateLegacyStructureWorker.enqueue("docs")

  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    group_slug = Map.fetch!(args, "group_slug")

    Logger.info(
      "[MigrateLegacyStructureWorker] No-op: DB posts are inherently versioned (group: #{group_slug})"
    )

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc """
  Creates a new migration job.
  """
  def create_job(group_slug, opts \\ []) do
    args =
      %{"group_slug" => group_slug}
      |> maybe_put("user_id", Keyword.get(opts, :user_id))

    new(args)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Enqueues a migration job.
  """
  def enqueue(group_slug, opts \\ []) do
    group_slug
    |> create_job(opts)
    |> Oban.insert()
  end
end
