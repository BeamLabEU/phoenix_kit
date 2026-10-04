defmodule PhoenixKit.Jobs.Kind do
  @moduledoc ~S"""
  A kind of job run: what a piece of long background work *is* and how one batch
  of it is done. A module declares its kinds with `PhoenixKit.Module.job_kinds/0`
  (a host can list extra ones under `config :phoenix_kit, job_kinds: [...]`).

  ```elixir
  defmodule MyApp.Jobs.ImportRows do
    use PhoenixKit.Jobs.Kind

    @impl true
    def kind, do: "my_app.import_rows"

    @impl true
    def module_key, do: "my_app"

    @impl true
    def title(%{"file" => name}, _scope), do: "Import " <> name

    # Replaying a batch (a crash after the work, before the checkpoint) is safe.
    @impl true
    def idempotent?, do: true

    @impl true
    def batch(run) do
      case MyApp.Import.next_rows(run.args, run.cursor, 100) do
        {[], _} -> {:done, %{"imported" => run.done}, %{done: 0}}
        {rows, cursor} ->
          MyApp.Import.insert(rows)
          {:more, %{cursor: cursor, done: length(rows)}, schedule_in: 1}
      end
    end
  end
  ```

  Start one with `PhoenixKit.Jobs.start/4` (a person) or
  `PhoenixKit.Jobs.System.start/3` (boot, cron, a script). The design is
  `dev_docs/plans/2026-10-03-job-runs.md`.

  ## What `batch/1` returns

    * `{:more, progress, opts}` — checkpoint and carry on. `progress` is
      `%{cursor:, done:, failed:, total:}`; `done` and `failed` are **increments
      of this batch** (the engine adds them in the checkpoint transaction, so a
      replayed batch cannot count twice), `cursor` is where the next batch
      resumes, `total` (optional) replaces the known total. `opts`:
      `schedule_in: seconds` — the pause before the next batch.
    * `{:done, result}` or `{:done, result, progress}` — the run is finished;
      `result` is a map kept on the run, `progress` the last batch's increments.
      **The result comes first**; the engine and the state machine order the two the
      other way round (`{:done, progress, result}`), which
      `PhoenixKit.Jobs.RunWorker.batch_outcome/3` converts at the boundary.
    * `{:snooze, seconds}` — nothing was done (waiting on something outside): the
      progress is left as it was, the claim is released and the next batch is
      dispatched after `seconds`. (Queued, that is a delayed Oban job; inline, the
      script waits.)
    * `{:error, reason}` — the batch failed. Oban retries it (`max_attempts/0`);
      the last failure fails the run.

  A batch may raise; that is an `{:error, _}`. A long batch can call
  `PhoenixKit.Jobs.heartbeat/1` between steps.

  ## The side-effect contract

  A crash after external work and before the checkpoint replays that batch.
  `idempotent?/0` says the kind survives that. **It is a declaration, not a
  check**: the engine never calls it and enforces nothing; it is there so a reader
  (and a future guard at the start boundary) knows what the author promised. A kind
  that is not idempotent (a broadcast that sends mail) must keep its own per-item
  marks, and the engine will not pretend otherwise.

  Replay is also about **counts**. `done`/`failed` are added in the checkpoint
  transaction, so a replayed batch cannot count twice — but work done by a batch
  that crashed before its checkpoint is not counted by anyone, and a kind that
  selects "what is still to do" (rather than walking a cursor) will not see it
  again. Counts recovered from a crash are therefore *approximate* unless the
  kind keeps durable per-item accounting; the Jobs page and the Mix task show what
  the run recorded.

  ## When `on_finish/2` runs

  After the run reaches a terminal state and **after the commit**, once, in the
  process that made the transition. It is best effort: a crash right after the
  commit, a callback that raises, or a kind that is no longer available skips it
  for good — an Oban retry sees a finished run and does not replay it. Use it for
  something whose loss is harmless (dropping a cache, a log line). Work that must
  happen when a run ends needs its own durable record and retry.
  """

  alias PhoenixKit.Jobs.Run

  @type progress :: %{
          optional(:cursor) => map(),
          optional(:done) => non_neg_integer(),
          optional(:failed) => non_neg_integer(),
          optional(:total) => non_neg_integer() | nil
        }
  @type result ::
          {:more, progress(), keyword()}
          | {:done, map()}
          | {:done, map(), progress()}
          | {:snooze, non_neg_integer()}
          | {:error, term()}
  @type control :: :pause | :resume | :cancel | :retry

  @doc "The kind's name, dotted: `\"storage.reconcile\"`. Stored on every run."
  @callback kind() :: String.t()

  @doc "The module key it belongs to: the Activity log's module, and the filter on the Jobs page."
  @callback module_key() :: String.t()

  @doc "A title fixed when the run starts (never recomputed from live data)."
  @callback title(args :: map(), scope :: :site | {String.t(), String.t()}) :: String.t()

  @doc "Does one batch of the run."
  @callback batch(Run.t()) :: result()

  @doc "Whether replaying a batch is safe. See the moduledoc."
  @callback idempotent?() :: boolean()

  @doc "The Oban queue (default `:default`)."
  @callback queue() :: atom()

  @doc "Oban attempts for one batch (default 3)."
  @callback max_attempts() :: pos_integer()

  @doc "How long one batch may take, in milliseconds (default ten minutes)."
  @callback timeout() :: pos_integer() | :infinity

  @doc "Validates a start. `{:error, reason}` refuses it. No side effects."
  @callback on_start(args :: map()) :: :ok | {:error, term()}

  @doc "After the run finished (`state`: `completed`, `failed` or `cancelled`). Idempotent."
  @callback on_finish(Run.t(), state :: String.t()) :: any()

  @doc """
  What a second start does while a run of this kind and scope is active:
  `:merge` (the existing run is returned) or `:restart` (it takes a fresh pass,
  at its next batch boundary).
  """
  @callback restart() :: :merge | :restart

  @doc "A permission needed besides `jobs.manage` to control a run of this kind, or nil."
  @callback permission() :: String.t() | nil

  @doc "The controls an admin is offered (default: all)."
  @callback controls() :: [control()]

  @optional_callbacks queue: 0,
                      max_attempts: 0,
                      timeout: 0,
                      on_start: 1,
                      on_finish: 2,
                      restart: 0,
                      permission: 0,
                      controls: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour PhoenixKit.Jobs.Kind

      @impl PhoenixKit.Jobs.Kind
      def queue, do: :default

      @impl PhoenixKit.Jobs.Kind
      def max_attempts, do: 3

      @impl PhoenixKit.Jobs.Kind
      def timeout, do: :timer.minutes(10)

      @impl PhoenixKit.Jobs.Kind
      def on_start(_args), do: :ok

      @impl PhoenixKit.Jobs.Kind
      def on_finish(_run, _state), do: :ok

      @impl PhoenixKit.Jobs.Kind
      def restart, do: :merge

      @impl PhoenixKit.Jobs.Kind
      def permission, do: nil

      @impl PhoenixKit.Jobs.Kind
      def controls, do: [:pause, :resume, :cancel, :retry]

      defoverridable queue: 0,
                     max_attempts: 0,
                     timeout: 0,
                     on_start: 1,
                     on_finish: 2,
                     restart: 0,
                     permission: 0,
                     controls: 0
    end
  end
end
