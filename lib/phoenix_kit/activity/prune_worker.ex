defmodule PhoenixKit.Activity.PruneWorker do
  @moduledoc """
  Oban worker that prunes old activity entries based on the configured retention period.

  Runs daily. Retention is configured via the `activity_retention_days` setting (default: 90).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.Activity

  @impl Oban.Worker
  def perform(_job) do
    days = Activity.retention_days()
    Activity.prune(days)
    :ok
  end
end
