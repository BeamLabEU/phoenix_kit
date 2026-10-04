defmodule PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker do
  @moduledoc """
  Deletes bucket log entries (V208) last seen before `bucket_log_retention_days`
  (default 30). Daily, by cron (`mix phoenix_kit.update` adds the entry to
  existing hosts). The log is operational, not an audit: configuration changes
  to a bucket live in the Activity log, which is pruned separately.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 3600]

  alias PhoenixKit.Modules.Storage.BucketLog

  @impl Oban.Worker
  def perform(_job) do
    BucketLog.prune()
    :ok
  end
end
