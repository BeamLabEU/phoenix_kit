defmodule PhoenixKit.Jobs.StateMachine do
  @moduledoc """
  The transitions of a job run, as pure functions (no database, no clock, no
  Oban): `transition/3` takes a run, an event and the time, and answers the fields to
  change and the effects to carry out, or why the event does not apply.

  `PhoenixKit.Jobs.Engine` does the I/O — it locks the run row, calls this,
  writes the changes, inserts the Oban job a `{:dispatch, seconds}` effect asks
  for and the Activity entry a `{:log, …}` effect asks for, all in one
  transaction. Keeping the rules here makes them testable without a database
  (`dev_docs/plans/2026-10-03-job-runs.md`, §3.2, §14 R1, R2, R5, R7).

  ## Events

    * `{:claim, token}` — a batch is about to work. Needs `queued` or `running`
      and no claim held. A pending restart is taken in here.
    * `{:checkpoint, token, outcome}` — the batch holding `token` is done.
      `outcome` is `{:more, progress, opts}`, `{:done, progress, result}`,
      `{:snooze, seconds}`, `{:fail, message}` (final) or `{:release, message}`
      (an error Oban will retry).
    * `{:pause, actor}`, `{:resume, actor}`, `{:cancel, actor}`
    * `:request_restart` — a trigger asked for a fresh pass
    * `{:heartbeat, token}`
    * `{:rescue, limit}` — the sweeper found the dispatch lost; refused while a
      batch holds the run
    * `{:fail, message}` — the run cannot go on (a job the sweeper found
      discarded); refused while a batch holds the run — a batch ends its own run
      through `{:checkpoint, token, {:fail, message}}`

  ## Precedence when a batch ends

  | State | Batch returns more / snoozes | Batch is done |
  |---|---|---|
  | `running`, no restart pending | next batch dispatched | `completed` |
  | `running`, restart pending | pass restarts (`queued`, counters reset) | pass restarts |
  | `pausing` | `paused`, nothing dispatched | `completed` (nothing is left to pause) |
  | `cancelling` | `cancelled` | `cancelled` |

  A pending restart never overrides a pause or a cancel; it waits.
  """

  alias PhoenixKit.Jobs.Run

  @type actor :: String.t() | nil
  @type progress :: %{
          optional(:cursor) => map(),
          optional(:done) => non_neg_integer(),
          optional(:failed) => non_neg_integer(),
          optional(:total) => non_neg_integer() | nil
        }
  @type outcome ::
          {:more, progress(), keyword()}
          | {:done, progress(), map()}
          | {:snooze, non_neg_integer()}
          | {:fail, String.t()}
          | {:release, String.t()}
  @type event ::
          {:claim, String.t()}
          | {:checkpoint, String.t(), outcome()}
          | {:pause, actor()}
          | {:resume, actor()}
          | {:cancel, actor()}
          | :request_restart
          | {:heartbeat, String.t()}
          | {:rescue, pos_integer()}
          | {:fail, String.t()}
  @type effect ::
          {:dispatch, non_neg_integer()}
          | {:log, String.t(), map()}
  @type error ::
          :inactive
          | :claimed
          | :claim_lost
          | :already_pausing
          | :already_paused
          | :already_cancelling
          | :draining
          | :not_paused
          | :cancelling
          | :finished
          | :not_active

  @doc """
  Applies `event` to `run` at `now`: `{:ok, changes, effects}` — `changes` is a
  map of fields to write, `effects` what to do besides — or `{:error, reason}`.
  """
  @spec transition(Run.t(), event(), DateTime.t()) :: {:ok, map(), [effect()]} | {:error, error()}

  # ---- claim ---------------------------------------------------------------

  def transition(%Run{state: state}, {:claim, _token}, _now) when state not in ~w(queued running),
    do: {:error, :inactive}

  def transition(%Run{claim_token: token}, {:claim, _token}, _now) when not is_nil(token),
    do: {:error, :claimed}

  def transition(%Run{} = run, {:claim, token}, now) do
    base = %{
      claim_token: token,
      claim_owner: "queue",
      owner_token: nil,
      claimed_at: now,
      heartbeat_at: now,
      wake_at: nil,
      state: "running"
    }

    base = if is_nil(run.started_at), do: Map.put(base, :started_at, now), else: base

    changes = if restart_pending?(run), do: Map.merge(base, reset(run)), else: base
    {:ok, changes, []}
  end

  # ---- heartbeat -----------------------------------------------------------

  def transition(%Run{claim_token: token}, {:heartbeat, token}, now) when not is_nil(token),
    do: {:ok, %{heartbeat_at: now}, []}

  def transition(%Run{}, {:heartbeat, _token}, _now), do: {:error, :claim_lost}

  # ---- pause ---------------------------------------------------------------

  def transition(%Run{state: "queued"}, {:pause, actor}, now), do: paused(actor, now)

  def transition(%Run{state: "running"} = run, {:pause, actor}, now) do
    if Run.claimed?(run), do: pausing(actor, now), else: paused(actor, now)
  end

  def transition(%Run{state: "pausing"}, {:pause, _actor}, _now), do: {:error, :already_pausing}
  def transition(%Run{state: "paused"}, {:pause, _actor}, _now), do: {:error, :already_paused}
  def transition(%Run{state: "cancelling"}, {:pause, _actor}, _now), do: {:error, :cancelling}
  def transition(%Run{}, {:pause, _actor}, _now), do: {:error, :finished}

  # ---- resume --------------------------------------------------------------

  def transition(%Run{state: "paused"} = run, {:resume, _actor}, _now) do
    {:ok,
     %{
       state: "queued",
       generation: run.generation + 1,
       paused_by_uuid: nil,
       paused_at: nil,
       claim_owner: nil,
       owner_token: nil,
       wake_at: nil,
       error: nil
     }, [{:dispatch, 0}, {:log, "job.resumed", %{}}]}
  end

  # Refused while the batch drains: a second dispatch beside it is what the
  # claim exists to prevent.
  def transition(%Run{state: "pausing"}, {:resume, _actor}, _now), do: {:error, :draining}
  def transition(%Run{}, {:resume, _actor}, _now), do: {:error, :not_paused}

  # ---- cancel --------------------------------------------------------------

  def transition(%Run{state: state}, {:cancel, _actor}, _now)
      when state in ~w(completed failed cancelled),
      do: {:error, :finished}

  def transition(%Run{state: "cancelling"}, {:cancel, _actor}, _now),
    do: {:error, :already_cancelling}

  def transition(%Run{state: state} = run, {:cancel, actor}, now) do
    if Run.claimed?(run) and state in ~w(running pausing) do
      {:ok, %{state: "cancelling", cancelled_by_uuid: actor, cancelled_at: now},
       [{:log, "job.cancel_requested", %{}}]}
    else
      {:ok, cancelled(actor, now), [{:log, "job.cancelled", %{}}]}
    end
  end

  # ---- restart request -----------------------------------------------------

  def transition(%Run{state: state}, :request_restart, _now)
      when state in ~w(completed failed cancelled),
      do: {:error, :finished}

  def transition(%Run{} = run, :request_restart, _now),
    do: {:ok, %{restart_seq: run.restart_seq + 1}, []}

  # ---- checkpoint ----------------------------------------------------------

  def transition(%Run{claim_token: token} = run, {:checkpoint, token, outcome}, now)
      when not is_nil(token) do
    checkpoint(run, outcome, now)
  end

  def transition(%Run{}, {:checkpoint, _token, _outcome}, _now), do: {:error, :claim_lost}

  # ---- sweeper -------------------------------------------------------------

  # Failing a run from outside needs a run nothing holds: a batch that holds
  # it is ended by its own checkpoint (or, if it is dead, released first), so
  # the claim is never cleared from under a live batch.
  def transition(%Run{state: state}, {:fail, _message}, _now)
      when state in ~w(completed failed cancelled),
      do: {:error, :finished}

  def transition(%Run{claim_token: token}, {:fail, _message}, _now) when not is_nil(token),
    do: {:error, :claimed}

  def transition(%Run{} = run, {:fail, message}, now), do: fail_run(run, message, now)

  def transition(%Run{state: state}, {:rescue, _limit}, _now)
      when state not in ~w(queued running),
      do: {:error, :not_active}

  # A rescue replaces a lost dispatch; a held claim means one is not lost.
  def transition(%Run{claim_token: token}, {:rescue, _limit}, _now) when not is_nil(token),
    do: {:error, :claimed}

  def transition(%Run{rescues: rescues} = run, {:rescue, limit}, now) do
    if rescues >= limit do
      message = "the run lost its dispatch #{rescues} times and was given up on"
      fail_run(run, message, now)
    else
      {:ok,
       Map.merge(Map.delete(release(), :wake_at), %{
         rescues: rescues + 1,
         last_rescued_at: now,
         generation: run.generation + 1
       }),
       [
         {:dispatch, Run.seconds_until_wake(run, now)},
         {:log, "job.rescued", %{"rescues" => rescues + 1}}
       ]}
    end
  end

  # ---- checkpoint outcomes -------------------------------------------------

  # An error Oban will retry: the claim is released so the retry can take it,
  # and nothing is dispatched. A requested pause or cancel settles now: nothing
  # is executing any more.
  defp checkpoint(%Run{} = run, {:release, message}, now) do
    changes =
      release()
      |> Map.merge(settle(run, now))
      |> Map.merge(%{error: message, interruptions: run.interruptions + 1})

    {:ok, changes, settle_log(run)}
  end

  defp checkpoint(%Run{} = run, {:fail, message}, now), do: fail_run(run, message, now)

  defp checkpoint(%Run{state: "running"} = run, outcome, now) do
    progressed = progress(run, outcome)

    cond do
      restart_pending?(run) ->
        {:ok,
         release_after_batch(run)
         |> Map.merge(reset(run))
         |> Map.merge(restarted(run))
         |> Map.put(:generation, run.generation + 1),
         [{:dispatch, 0}, {:log, "job.restarted", %{}}]}

      match?({:done, _, _}, outcome) ->
        {:done, _, result} = outcome

        {:ok, Map.merge(release(), Map.merge(progressed, completed(result, now))),
         [{:log, "job.completed", %{"done" => progressed.done}}]}

      true ->
        seconds = delay(outcome)

        changes =
          release_after_batch(run)
          |> Map.merge(progressed)
          |> Map.merge(%{generation: run.generation + 1, wake_at: wake_at(now, seconds)})

        {:ok, changes, [{:dispatch, seconds}]}
    end
  end

  # A pause was asked while the batch worked. Its work is recorded either way;
  # a last batch completes the run (nothing is left to pause), anything else
  # settles into `paused` and dispatches nothing.
  defp checkpoint(%Run{state: "pausing"} = run, outcome, now) do
    progressed = progress(run, outcome)

    case outcome do
      {:done, _progress, result} ->
        {:ok,
         Map.merge(
           release(),
           Map.merge(
             progressed,
             completed(Map.put(result, "pause_arrived_after_the_last_batch", true), now)
           )
         ), [{:log, "job.completed", %{"done" => progressed.done}}]}

      _ ->
        {:ok,
         Map.merge(
           release(),
           Map.merge(progressed, %{state: "paused", paused_at: run.paused_at || now})
         ), [{:log, "job.paused", %{}}]}
    end
  end

  # A cancel was asked: it wins, even over a last batch. What the batch did is
  # still recorded.
  defp checkpoint(%Run{state: "cancelling"} = run, outcome, now) do
    progressed = progress(run, outcome)

    result =
      case outcome do
        {:done, _progress, result} -> %{result: result}
        _ -> %{}
      end

    {:ok,
     release()
     |> Map.merge(progressed)
     |> Map.merge(result)
     |> Map.merge(%{state: "cancelled", finished_at: now, cancelled_at: run.cancelled_at || now}),
     [{:log, "job.cancelled", %{"done" => progressed.done}}]}
  end

  defp checkpoint(%Run{}, _outcome, _now), do: {:error, :not_active}

  # ---- pieces --------------------------------------------------------------

  # The run ends: failed, or cancelled when a cancel was waiting for this batch.
  defp fail_run(%Run{state: "cancelling"} = run, _message, now) do
    {:ok, Map.merge(cancelled(run.cancelled_by_uuid, now), release()),
     [{:log, "job.cancelled", %{}}]}
  end

  defp fail_run(%Run{}, message, now) do
    {:ok, Map.merge(failed(message, now), release()),
     [{:log, "job.failed", %{"error" => message}}]}
  end

  defp paused(actor, now) do
    {:ok,
     %{
       state: "paused",
       paused_by_uuid: actor,
       paused_at: now,
       claim_owner: nil,
       owner_token: nil,
       wake_at: nil
     }, [{:log, "job.paused", %{}}]}
  end

  defp pausing(actor, now) do
    {:ok, %{state: "pausing", paused_by_uuid: actor, paused_at: now},
     [{:log, "job.pause_requested", %{}}]}
  end

  defp cancelled(actor, now) do
    %{
      state: "cancelled",
      cancelled_by_uuid: actor,
      cancelled_at: now,
      finished_at: now,
      claim_owner: nil,
      owner_token: nil,
      wake_at: nil
    }
  end

  defp completed(result, now),
    do: %{state: "completed", result: result, finished_at: now, error: nil}

  defp failed(message, now), do: %{state: "failed", error: message, finished_at: now}

  defp release,
    do: %{claim_token: nil, claim_owner: nil, owner_token: nil, claimed_at: nil, wake_at: nil}

  # After a batch that leaves more to do. A script keeps its ownership of the run
  # between its batches (it waits out the delay itself, and nothing is dispatched
  # for it); the batch claim, though, is given up — a pause then takes effect at
  # once, not as a drain of work that is not running.
  defp release_after_batch(%Run{claim_owner: "inline"}),
    do: %{claim_token: nil, claimed_at: nil, wake_at: nil}

  defp release_after_batch(%Run{}), do: release()

  defp wake_at(_now, seconds) when seconds <= 0, do: nil
  defp wake_at(now, seconds), do: DateTime.add(now, seconds, :second)

  # A pause or cancel that was waiting for the batch takes effect.
  defp settle(%Run{state: "pausing"} = run, now),
    do: %{state: "paused", paused_at: run.paused_at || now}

  defp settle(%Run{state: "cancelling"} = run, now),
    do: %{state: "cancelled", finished_at: now, cancelled_at: run.cancelled_at || now}

  defp settle(%Run{}, _now), do: %{}

  defp settle_log(%Run{state: "pausing"}), do: [{:log, "job.paused", %{}}]
  defp settle_log(%Run{state: "cancelling"}), do: [{:log, "job.cancelled", %{}}]
  defp settle_log(%Run{}), do: []

  defp restart_pending?(%Run{restart_seq: seq, restart_ack: ack}), do: seq > ack

  # A fresh pass: what the last one did is forgotten, and every request up to now
  # is taken in. A request that lands after this commits has a higher number.
  defp reset(%Run{restart_seq: seq}) do
    %{cursor: %{}, done: 0, failed_count: 0, total: nil, restart_ack: seq, error: nil}
  end

  defp restarted(%Run{}), do: %{state: "queued"}

  # What a batch adds. `done` and `failed` are increments; `total`, when given,
  # replaces the old one.
  defp progress(%Run{} = run, {:more, %{} = progress, _opts}), do: add(run, progress, true)
  defp progress(%Run{} = run, {:done, %{} = progress, _result}), do: add(run, progress, false)

  defp progress(%Run{} = run, _outcome) do
    %{done: run.done, failed_count: run.failed_count, total: run.total, cursor: run.cursor}
  end

  defp add(%Run{} = run, progress, keep_cursor?) do
    %{
      done: run.done + Map.get(progress, :done, 0),
      failed_count: run.failed_count + Map.get(progress, :failed, 0),
      total: Map.get(progress, :total, run.total),
      cursor: if(keep_cursor?, do: Map.get(progress, :cursor, run.cursor), else: run.cursor)
    }
  end

  defp delay({:more, _progress, opts}), do: Keyword.get(opts, :schedule_in, 0)
  defp delay({:snooze, seconds}), do: seconds
  defp delay(_outcome), do: 0
end
