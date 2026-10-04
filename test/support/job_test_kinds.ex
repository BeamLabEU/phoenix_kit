defmodule PhoenixKit.Test.JobKinds do
  @moduledoc false

  # Kinds for the job engine's tests. A run's `args` steer what a batch does, so
  # one kind covers progress, errors, snoozes and a slow batch.
  #
  #   "steps"      how many batches the run takes (default 3)
  #   "per_batch"  `done` added by each batch (default 10)
  #   "raise_at"   the step on which the batch raises
  #   "error_at"   the step on which the batch returns `{:error, _}`
  #   "snooze_at"  the step on which the batch snoozes (once)
  #   "snooze_for" the seconds that snooze asks for (default 0)
  #   "sleep_ms"   a batch sleeps this long before it answers
  #   "schedule_in" pause after each batch (default 0)
  #   "notify"     a pid (as a string key in `:persistent_term`) told of every batch
  defmodule Counter do
    @moduledoc false
    use PhoenixKit.Jobs.Kind

    alias PhoenixKit.Test.JobKinds

    @impl true
    def kind, do: "test.counter"

    @impl true
    def module_key, do: "test"

    @impl true
    def title(args, _scope), do: "Count to #{args["steps"] || 3}"

    @impl true
    def idempotent?, do: true

    @impl true
    def batch(run), do: JobKinds.step(run)
  end

  defmodule Restarting do
    @moduledoc false
    use PhoenixKit.Jobs.Kind

    alias PhoenixKit.Test.JobKinds

    @impl true
    def kind, do: "test.restarting"

    @impl true
    def module_key, do: "test"

    @impl true
    def title(_args, _scope), do: "Restarting"

    @impl true
    def idempotent?, do: true

    @impl true
    def restart, do: :restart

    @impl true
    def batch(run), do: JobKinds.step(run)
  end

  # A kind whose batch may only take 200 ms, to see a timeout for real.
  defmodule Short do
    @moduledoc false
    use PhoenixKit.Jobs.Kind

    alias PhoenixKit.Test.JobKinds

    @impl true
    def kind, do: "test.short"

    @impl true
    def module_key, do: "test"

    @impl true
    def title(_args, _scope), do: "Short"

    @impl true
    def idempotent?, do: true

    @impl true
    def timeout, do: 200

    @impl true
    def batch(run), do: JobKinds.step(run)
  end

  defmodule Guarded do
    @moduledoc false
    use PhoenixKit.Jobs.Kind

    alias PhoenixKit.Test.JobKinds

    @impl true
    def kind, do: "test.guarded"

    @impl true
    def module_key, do: "test"

    @impl true
    def title(_args, _scope), do: "Guarded"

    @impl true
    def idempotent?, do: true

    @impl true
    def permission, do: "media.manage"

    @impl true
    def controls, do: [:pause, :cancel]

    @impl true
    def on_start(%{"refuse" => true}), do: {:error, :refused}
    def on_start(_args), do: :ok

    @impl true
    def batch(run), do: JobKinds.step(run)
  end

  defp sleep(nil), do: :ok
  defp sleep(ms), do: Process.sleep(ms)

  @doc false
  def step(run) do
    args = run.args
    steps = args["steps"] || 3
    per_batch = args["per_batch"] || 10
    step = run.cursor["step"] || 0

    sleep(args["sleep_ms"])

    cond do
      args["raise_at"] == step ->
        raise "boom at step #{step}"

      args["error_at"] == step ->
        {:error, "no luck at step #{step}"}

      args["snooze_at"] == step and not :persistent_term.get({:job_snoozed, run.uuid}, false) ->
        # A snooze checkpoints nothing, so "once" is remembered outside the run.
        :persistent_term.put({:job_snoozed, run.uuid}, true)
        {:snooze, args["snooze_for"] || 0}

      step + 1 >= steps ->
        {:done, %{"steps" => steps}, %{done: per_batch}}

      true ->
        {:more, %{cursor: %{"step" => step + 1}, done: per_batch, total: steps * per_batch},
         schedule_in: args["schedule_in"] || 0}
    end
  end
end
