defmodule PhoenixKit.Notifications.PruneWorker do
  @moduledoc """
  Oban worker that deletes notifications whose underlying activity is older
  than the retention window.

  Retention is configured via `notifications_retention_days` (defaults to the
  value of `activity_retention_days` if unset) — we never outlive the activity
  a notification references, and the FK cascade handles the other direction.

  Runs daily (wired from `lib/phoenix_kit/install/oban_config.ex`).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.Notifications

  @impl Oban.Worker
  def perform(_job) do
    days = Notifications.retention_days()
    Notifications.prune(days)
    :ok
  end
end
