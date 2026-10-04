defmodule PhoenixKit.Jobs.RunWorker do
  @moduledoc """
  The one Oban worker behind every job run: it does **one batch** of a run and
  hands the next to Oban through the engine.

  An Oban job here is `%{"run_uuid", "generation", "kind"}`. The flow:

    1. **claim** the run for this generation (`Engine.claim/2`): an older
       generation or a run that is paused, cancelled or finished does nothing
       (`:ok`), and a run another batch still holds is snoozed. This comes
       first, before anything else is looked at, so a delivery that is not the
       run's current dispatch is inert whatever else is true — including a kind
       that has since disappeared;
    2. the kind is looked up from the claimed run; a kind that is gone (its
       module disabled or removed) fails the run ("kind unavailable") by
       checkpointing the failure with the claim just taken, rather than looping;
    3. call `kind.batch/1`, rescuing a raise, an exit or a throw as an error;
    4. **checkpoint** (`Engine.checkpoint/4`): progress, cursor, the next
       dispatch and the history, in one transaction.

  An error that Oban will retry releases the claim and is returned, so the retry
  can take it; the last attempt fails the run. A `timeout/1` kill leaves the
  claim held — `PhoenixKit.Jobs.SweepWorker` releases it once Oban says the job is
  no longer executing.

  `uniqueness` is on `run_uuid` + `generation`: the *same* dispatch cannot be
  inserted twice. It does **not** serialise execution — the claim does.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:run_uuid, :generation],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias PhoenixKit.Jobs.{Engine, Kinds, Run}

  @busy_snooze 5

  @impl Oban.Worker
  def timeout(%Oban.Job{args: %{"kind" => kind_name}}) do
    case Kinds.get(kind_name) do
      nil -> :timer.minutes(10)
      kind -> kind.timeout()
    end
  end

  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_uuid" => run_uuid, "generation" => generation}} = job) do
    case Engine.claim(run_uuid, generation) do
      {:ok, run, token} ->
        outcome =
          case Kinds.get(run.kind) do
            nil -> {:fail, unavailable(run.kind)}
            kind -> batch_outcome(kind, run, job.attempt >= job.max_attempts)
          end

        settle(run_uuid, token, outcome)

      {:skip, :busy} ->
        {:snooze, @busy_snooze}

      {:skip, _reason} ->
        :ok

      {:error, reason} ->
        {:error, "could not claim run #{run_uuid}: #{inspect(reason)}"}
    end
  end

  defp settle(run_uuid, token, outcome) do
    case Engine.checkpoint(run_uuid, token, outcome, mode: "auto") do
      {:ok, _run} ->
        case outcome do
          {:release, message} -> {:error, message}
          _ -> :ok
        end

      {:error, :claim_lost} ->
        Logger.warning("Jobs: run #{run_uuid} lost its claim before the checkpoint; dropping it")
        :ok

      {:error, reason} ->
        Logger.warning("Jobs: run #{run_uuid} could not checkpoint: #{inspect(reason)}")
        {:error, "checkpoint failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Runs one batch of `run` and answers what the state machine takes: the kind's
  return, normalised, with a raise, an exit or a throw as an error. `final?` says
  whether Oban has no attempts left (an error then fails the run instead of
  being retried). Also used by inline execution.
  """
  @spec batch_outcome(module(), Run.t(), boolean()) :: PhoenixKit.Jobs.StateMachine.outcome()
  def batch_outcome(kind, %Run{} = run, final?) do
    kind.batch(run) |> normalize(final?)
  rescue
    error -> failure(Exception.message(error), final?)
  catch
    class, reason -> failure("#{class}: #{inspect(reason)}", final?)
  end

  defp normalize({:more, %{} = progress, opts}, _final?) when is_list(opts),
    do: {:more, progress, opts}

  defp normalize({:more, %{} = progress}, _final?), do: {:more, progress, []}
  defp normalize({:done, %{} = result}, _final?), do: {:done, %{}, result}

  defp normalize({:done, %{} = result, %{} = progress}, _final?),
    do: {:done, progress, result}

  defp normalize({:snooze, seconds}, _final?) when is_integer(seconds) and seconds >= 0,
    do: {:snooze, seconds}

  defp normalize({:error, reason}, final?), do: failure(message(reason), final?)
  defp normalize(other, _final?), do: {:fail, "invalid batch result: #{inspect(other)}"}

  defp failure(message, true), do: {:fail, message}
  defp failure(message, false), do: {:release, message}

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp unavailable(kind_name),
    do: "kind unavailable: #{kind_name} (its module is disabled or gone)"
end
