defmodule PhoenixKit.Jobs.PruneWorker do
  @moduledoc """
  Deletes finished job runs older than `job_runs_retention_days` (default 90, the
  activity log's default). Daily, by cron (`mix phoenix_kit.update` adds the entry
  to existing hosts). An unfinished run is never pruned, however old.

  A run's history in the Activity log is pruned by its own retention
  (`activity_retention_days`), separately.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 3600]

  import Ecto.Query

  alias PhoenixKit.Jobs.Run
  alias PhoenixKit.Settings

  @default_days 90

  @impl Oban.Worker
  def perform(_job) do
    prune()
    :ok
  end

  @doc "How long finished runs are kept, in days."
  @spec retention_days() :: pos_integer()
  def retention_days do
    case Integer.parse(Settings.get_setting("job_runs_retention_days", "#{@default_days}")) do
      {days, _} when days > 0 -> days
      _ -> @default_days
    end
  end

  @doc "Deletes the finished runs older than the retention. Returns how many."
  @spec prune() :: non_neg_integer()
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)

    {count, _} =
      from(r in Run, where: r.state in ^Run.terminal_states() and r.finished_at < ^cutoff)
      |> PhoenixKit.RepoHelper.repo().delete_all()

    count
  end
end
