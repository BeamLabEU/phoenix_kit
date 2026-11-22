defmodule PhoenixKit.Handoff.PruneWorker do
  @moduledoc """
  Oban worker that deletes expired cross-domain handoff rows (`phoenix_kit_handoff_tokens`).

  Runs daily. A row is redeemable for `PhoenixKit.Handoff.ttl_seconds/0` seconds and is refused
  after that whether it has been pruned or not, so the schedule only keeps the table small: it
  deletes the rows that expired more than a day ago (`PhoenixKit.Handoff.prune_expired/1`). Every
  mint also deletes a few rows that expired minutes ago, so the table does not wait for this job.

  The delete is made in **bounded batches** (1000 rows a statement, at most 100 statements
  a run), so a table that grew while the job was off (or was never scheduled) is not cleared by
  one long statement that holds locks and a connection; what a run leaves over, the next one
  takes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.Handoff

  @batch 1_000
  @max_batches 100

  @impl Oban.Worker
  def perform(_job) do
    prune()
    :ok
  end

  @doc """
  Deletes the rows that expired more than a day ago, `batch:` rows (default #{@batch}) a
  statement, until none is left or `max_batches:` (default #{@max_batches}) statements were made.
  Returns how many rows it deleted.
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    batch = Keyword.get(opts, :batch, @batch)
    prune_batches(batch, Keyword.get(opts, :max_batches, @max_batches), 0)
  end

  defp prune_batches(_batch, 0, deleted), do: deleted

  defp prune_batches(batch, left, deleted) do
    case Handoff.prune_expired(limit: batch) do
      ^batch -> prune_batches(batch, left - 1, deleted + batch)
      count -> deleted + count
    end
  end
end
