defmodule PhoenixKit.Jobs.SweepWorker do
  @moduledoc """
  Finds the runs that stopped without saying so and puts them right — the
  run-level twin of `Oban.Plugins.Lifeline` (which only rescues the Oban row).
  Cron, every five minutes (`mix phoenix_kit.update` adds the entry to existing
  hosts).

  The sweeper only **lists candidates** (unfinished runs untouched for
  `@grace_seconds`). Whether one needs help is decided by
  `PhoenixKit.Jobs.Engine.recover/4` under the run's row lock, from the run as it
  is at that moment — a run a live worker advanced, rescued or claimed since the
  listing is left alone, so a slow sweep can never undo a newer dispatch
  (`dev_docs/plans/2026-10-03-job-runs.md`, §16 F1).

  It reads each run's **own Oban job** (`oban_job_id`, checked to be this run's
  `RunWorker` job of this generation), through Oban's configured repo and prefix
  (`PhoenixKit.Jobs.ObanStore`), never "is there any job" and never a stale
  heartbeat alone (§14 R5). **When Oban cannot be asked — no instance runs in this
  VM — every run that depends on a dispatch is left, one that never had a job id
  included**, so a sweep from a script cannot spend a rescue on a dispatch nothing
  here could have made:

  | the run | what it has | action |
  |---|---|---|
  | holds a **queue** claim | its job is `executing` | leave it (Lifeline owns a genuinely dead one) |
  | holds a **queue** claim | its job is anything else | the batch died: **release** the claim |
  | holds an **inline** claim | a lease still running | leave it |
  | holds an **inline** claim | a lease that ran out (`Run.lease_expired?/2`) | the script died: **release** the claim |
  | **inline**, between two batches (waiting out a delay) | a lease still running | leave it: the script will be back at `wake_at` |
  | **inline**, between two batches | a lease that ran out | **rescue** — the dispatch carries the rest of the delay |
  | waiting | `available`, `scheduled`, `retryable`, `executing` | leave it |
  | waiting | `discarded` | its attempts are spent: the run **fails** |
  | waiting | `cancelled` outside the engine | the run **fails** |
  | waiting | `completed`, or gone, or of another generation | a lost dispatch: **rescue** |

  A script (`Jobs.run_inline/3`) has no Oban job, so a missing job proves nothing
  about it; its claim carries a lease (an hour without a `Jobs.heartbeat/1`) which
  also covers the waits between its batches (`wake_at` plus the lease).
  The limitation is deliberate: a crashed script's run stays held until its lease
  runs out, and a new script may take it over then.

  A rescue gives the run a new generation and dispatches it, and is counted on the
  row (`rescues`), so the budget survives restarts; at `@rescue_limit` the run fails
  instead of restarting for ever. A run changed in the last `@grace_seconds` is
  left alone: its dispatch may be in flight.

  Each pass stamps `job_runs_last_sweep_at`, which the Jobs page reads to warn when
  no sweeper has been seen.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  import Ecto.Query

  require Logger

  alias PhoenixKit.Jobs.{Engine, ObanStore, Run}
  alias PhoenixKit.Settings

  @rescue_limit 3
  @grace_seconds 120
  @setting "job_runs_last_sweep_at"

  @doc "The setting the last pass stamps, an ISO 8601 timestamp."
  def last_sweep_setting, do: @setting

  @impl Oban.Worker
  def perform(_job) do
    result = sweep()

    if result != %{released: 0, failed: 0, rescued: 0} do
      Logger.info("Jobs sweep: #{inspect(result)}")
    end

    :ok
  end

  @doc """
  One pass. Returns how many claims were released, runs failed and dispatches
  rescued. Public so a test, a Mix task or the Jobs page can run it now.

  `:after_listing` (a function, for tests) is called once the candidates are
  listed and before the first is recovered, to let a test move the world in
  between.
  """
  @spec sweep(DateTime.t(), keyword()) :: %{
          released: integer(),
          failed: integer(),
          rescued: integer()
        }
  def sweep(now \\ DateTime.utc_now(), opts \\ []) do
    now = DateTime.truncate(now, :second)
    cutoff = DateTime.add(now, -@grace_seconds, :second)

    candidates =
      from(r in Run,
        where:
          r.state in ["queued", "running", "pausing", "cancelling"] and r.updated_at < ^cutoff,
        order_by: r.inserted_at,
        select: r.uuid
      )
      |> repo().all()

    if hook = opts[:after_listing], do: hook.()

    result =
      Enum.reduce(candidates, %{released: 0, failed: 0, rescued: 0}, fn uuid, acc ->
        merge(acc, recover(uuid, now, cutoff))
      end)

    Settings.update_setting(@setting, DateTime.to_iso8601(now))
    result
  end

  # One run's trouble (a database error reading Oban's table, say) must not stop
  # the pass over the others: it is logged, and the run is tried again next time.
  defp recover(uuid, now, cutoff) do
    case Engine.recover(uuid, cutoff, &decide(&1, now)) do
      {:ok, tag} -> tag
      {:error, _reason} -> :left
    end
  rescue
    error ->
      Logger.warning(
        "Jobs sweep: run #{uuid} could not be recovered: #{Exception.message(error)}"
      )

      :left
  end

  defp merge(acc, outcome) do
    case outcome do
      :released -> %{acc | released: acc.released + 1}
      :failed -> %{acc | failed: acc.failed + 1}
      :rescued -> %{acc | rescued: acc.rescued + 1}
      _left -> acc
    end
  end

  # What to do with a run, from the run as the engine holds it under its lock.
  defp decide(%Run{claim_token: token} = run, now) when not is_nil(token) do
    if claim_alive?(run, now) do
      :leave
    else
      {:released,
       {:checkpoint, token, {:release, "the batch did not finish (a crash or a timeout)"}}}
    end
  end

  # A script waiting out a delay between its batches: it owns the run, and there is
  # no Oban job to find. Its lease says whether it is still there; if it is not,
  # the rescue carries the rest of the delay into the dispatch.
  defp decide(%Run{state: state, claim_owner: "inline"} = run, now)
       when state in ["queued", "running"] do
    cond do
      not Run.lease_expired?(run, now) -> :leave
      # An expired owner is not charged a rescue for a dispatch nothing here can make.
      not ObanStore.available?() -> :leave
      true -> {:rescued, {:rescue, @rescue_limit}}
    end
  end

  defp decide(%Run{state: state} = run, _now) when state in ["queued", "running"] do
    case ObanStore.dispatch_of(run) do
      :unavailable ->
        :leave

      %Oban.Job{state: state} when state in ~w(available scheduled retryable executing) ->
        :leave

      %Oban.Job{state: "discarded"} = job ->
        {:failed, {:fail, "the batch used up its attempts: #{last_error(job)}"}}

      %Oban.Job{state: "cancelled"} ->
        {:failed, {:fail, "its Oban job was cancelled outside the run"}}

      _lost ->
        {:rescued, {:rescue, @rescue_limit}}
    end
  end

  defp decide(%Run{}, _now), do: :leave

  # Is the batch that holds the run still there? A script's is as long as its
  # lease; an Oban batch's is as long as its job executes. When Oban cannot be
  # asked, assume it is.
  defp claim_alive?(%Run{claim_owner: "inline"} = run, now), do: not Run.lease_expired?(run, now)

  defp claim_alive?(%Run{} = run, _now) do
    case ObanStore.dispatch_of(run) do
      :unavailable -> true
      %Oban.Job{state: "executing"} -> true
      _ -> false
    end
  end

  defp last_error(%Oban.Job{errors: [_ | _] = errors}) do
    errors |> List.last() |> Map.get("error", "unknown error")
  end

  defp last_error(_job), do: "unknown error"

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
