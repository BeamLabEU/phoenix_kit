defmodule PhoenixKit.Handoff.PruneWorker do
  @moduledoc """
  Oban worker that deletes expired cross-domain handoff rows (`phoenix_kit_handoff_tokens`).

  Runs daily. A row is redeemable for `PhoenixKit.Handoff.ttl_seconds/0` seconds and is refused
  after that whether it has been pruned or not, so the schedule only keeps the table small: it
  deletes the rows that expired more than a day ago (`PhoenixKit.Handoff.prune_expired/1`). Every
  mint also deletes a few rows that expired minutes ago, so the table does not wait for this job.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.Handoff

  @impl Oban.Worker
  def perform(_job) do
    Handoff.prune_expired()
    :ok
  end
end
