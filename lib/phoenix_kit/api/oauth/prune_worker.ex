defmodule PhoenixKit.API.OAuth.PruneWorker do
  @moduledoc """
  Oban worker that clears the OAuth tables daily (`PhoenixKit.API.OAuth.Prune`): consents nobody
  finished, grants that have been over for three days (with their hidden key, unless it has
  confirmations), expired requests, codes and tokens, and registered clients nobody uses.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias PhoenixKit.API.OAuth.Prune

  @impl Oban.Worker
  def perform(_job) do
    Prune.run()
    :ok
  end
end
