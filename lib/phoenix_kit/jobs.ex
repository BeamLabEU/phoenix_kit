defmodule PhoenixKit.Jobs do
  @moduledoc ~S"""
  Job runs: long background work an admin can watch and control.

  A **run** is a durable record of one logical piece of work — a backfill, a
  reconcile of one library, an import, a broadcast — that Oban executes batch by
  batch. Pause, resume, cancel and retry are state changes on the run; the worker
  reads the state before every batch and never queues the next one for a run that
  was stopped. Jobs are core and always on: **Admin → Jobs** lists the runs, their
  progress and history, and `jobs.manage` controls them.

  The design, and why it is shaped this way, is
  `dev_docs/plans/2026-10-03-job-runs.md`.

  ## Declaring a kind

  A module implements `PhoenixKit.Jobs.Kind` for each kind of run it has and lists
  them in `PhoenixKit.Module.job_kinds/0`.

  ## Starting a run

  A person, with a scope (the permission is checked against the *active role*):

      PhoenixKit.Jobs.start(scope, MyApp.Jobs.ImportRows, :site, args: %{"file" => "a.csv"})

  Boot, cron, a Mix task or a trigger — the trusted door, which never takes the
  place of a user:

      PhoenixKit.Jobs.System.start(MyApp.Jobs.ImportRows, :site, mode: :cron)

  A second start while a run of the kind and scope is active returns that run
  (`{:ok, run, :existing}`); a kind with `restart/0` returning `:restart` also asks
  it to begin a fresh pass.

  ## Controls

  `pause/2`, `resume/2`, `cancel/2` and `retry/2` take a scope and a run (or its
  uuid). A pause or cancel while a batch is executing is a *request*: the run is
  `pausing` / `cancelling` until the batch finishes, and `resume` is refused
  meanwhile. Each control returns `{:ok, run}` or `{:error, reason}` —
  `:unauthorized`, `:unknown_kind`, `:control_not_offered`, `:not_found` or the
  state machine's (`PhoenixKit.Jobs.StateMachine`).

  ## Reading

  `list_runs/1`, `count_runs/1`, `get_run/1`, `active_run/2`, `history/1`. Live
  changes arrive over `PhoenixKit.Jobs.Events`.
  """

  import Ecto.Query

  alias PhoenixKit.Jobs.{Engine, History, Kind, Kinds, ObanStore, Run, RunWorker}
  alias PhoenixKit.Users.Auth.Scope

  @type run_scope :: :site | {atom() | String.t(), String.t()}
  @type kind :: module() | String.t()

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Controls (a person, with a scope)
  # ---------------------------------------------------------------------------

  @doc """
  Starts a run of `kind` for `run_scope` on behalf of the person behind `scope`.
  Options: `:args`. Returns `{:ok, run, :started | :existing}` or an error.

  `{:error, :raced}` means the start met a run that finished at that very moment
  three times over: **the trigger was not recorded** — try again.
  `{:error, :in_transaction}` means it was called inside a transaction of the
  caller's, which would let a broadcast or `on_finish/2` escape a rollback: call it
  after the transaction commits (see `PhoenixKit.Jobs.Engine`).
  """
  @spec start(Scope.t(), kind(), run_scope(), keyword()) ::
          {:ok, Run.t(), :started | :existing} | {:error, term()}
  def start(%Scope{} = scope, kind, run_scope \\ :site, opts \\ []) do
    with {:ok, kind_mod} <- kind_module(kind),
         :ok <- authorize(scope, kind_mod, nil) do
      Engine.start(
        kind_mod,
        normalize_scope(run_scope),
        Keyword.merge(opts, actor_uuid: Scope.user_uuid(scope), mode: "manual")
      )
    end
  end

  @doc "Pauses a run (see the moduledoc for what a pause while a batch executes means)."
  @spec pause(Scope.t(), Run.t() | String.t()) :: {:ok, Run.t()} | {:error, term()}
  def pause(scope, run), do: control(scope, run, :pause, &{:pause, &1})

  @doc "Resumes a paused run. Refused while the run is still `pausing`."
  @spec resume(Scope.t(), Run.t() | String.t()) :: {:ok, Run.t()} | {:error, term()}
  def resume(scope, run), do: control(scope, run, :resume, &{:resume, &1})

  @doc "Cancels a run. A batch already executing finishes first; its work is kept."
  @spec cancel(Scope.t(), Run.t() | String.t()) :: {:ok, Run.t()} | {:error, term()}
  def cancel(scope, run), do: control(scope, run, :cancel, &{:cancel, &1})

  @doc """
  Starts a new run like a failed or cancelled one (same kind, scope and args),
  recording which it retries. A finished run is never changed.
  """
  @spec retry(Scope.t(), Run.t() | String.t()) ::
          {:ok, Run.t(), :started | :existing} | {:error, term()}
  def retry(%Scope{} = scope, run) do
    with %Run{} = old <- fetch(run) || {:error, :not_found},
         {:ok, kind_mod} <- kind_module(old.kind),
         :ok <- authorize(scope, kind_mod, :retry),
         true <- old.state in ~w(failed cancelled) || {:error, :not_retryable} do
      Engine.start(
        kind_mod,
        scope_of(old),
        args: Map.delete(old.args, "retry_of"),
        retry_of: old.uuid,
        actor_uuid: Scope.user_uuid(scope),
        mode: "manual"
      )
    end
  end

  @doc """
  The controls `scope` may offer on `run` right now: the state allows them, the
  kind offers them, and the person holds `jobs.manage` and the kind's own
  permission. For the Jobs page, which shows only what would work.
  """
  @spec controls_for(Scope.t(), Run.t()) :: [Kind.control()]
  def controls_for(%Scope{} = scope, %Run{} = run) do
    kind_mod = Kinds.get(run.kind)

    if authorize(scope, kind_mod, nil) == :ok do
      run.state
      |> state_controls()
      |> Enum.filter(&(is_nil(kind_mod) or &1 in kind_mod.controls()))
    else
      []
    end
  end

  def controls_for(_scope, _run), do: []

  @doc """
  Whether `scope` may start a run of `kind` (`jobs.manage` and the kind's own
  permission against the active role) — what a screen asks before it offers a
  button that starts one.
  """
  @spec can_start?(Scope.t() | nil, kind()) :: boolean()
  def can_start?(%Scope{} = scope, kind) do
    case kind_module(kind) do
      {:ok, kind_mod} -> authorize(scope, kind_mod, nil) == :ok
      _ -> false
    end
  end

  def can_start?(_scope, _kind), do: false

  defp state_controls(state) when state in ~w(queued running), do: [:pause, :cancel]
  defp state_controls("pausing"), do: [:cancel]
  defp state_controls("paused"), do: [:resume, :cancel]
  defp state_controls(state) when state in ~w(failed cancelled), do: [:retry]
  defp state_controls(_state), do: []

  defp control(%Scope{} = scope, run, control, event) do
    with %Run{} = found <- fetch(run) || {:error, :not_found},
         kind_mod = Kinds.get(found.kind),
         :ok <- authorize(scope, kind_mod, control) do
      actor = Scope.user_uuid(scope)
      Engine.transition(found.uuid, event.(actor), actor_uuid: actor, mode: "manual")
    end
  end

  # `jobs.manage`, the kind's own permission, and a control the kind offers. A
  # kind that is gone (nil) still needs `jobs.manage`: stopping its runs is how it
  # gets cleaned up.
  defp authorize(scope, kind_mod, control) do
    cond do
      not Scope.authenticated?(scope) -> {:error, :unauthorized}
      not Scope.can?(scope, "jobs.manage") -> {:error, :unauthorized}
      kind_mod && kind_permission_missing?(scope, kind_mod) -> {:error, :unauthorized}
      kind_mod && control && control not in kind_mod.controls() -> {:error, :control_not_offered}
      true -> :ok
    end
  end

  defp kind_permission_missing?(scope, kind_mod) do
    case kind_mod.permission() do
      nil -> false
      permission -> not Scope.can?(scope, permission)
    end
  end

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  @doc "A run, or nil."
  @spec get_run(String.t()) :: Run.t() | nil
  def get_run(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Run, uuid)
      :error -> nil
    end
  end

  @doc "The active run of `kind` for `run_scope`, or nil."
  @spec active_run(kind(), run_scope()) :: Run.t() | nil
  def active_run(kind, run_scope \\ :site) do
    name = if is_binary(kind), do: kind, else: kind.kind()
    Engine.active_run(name, normalize_scope(run_scope))
  end

  @doc """
  Runs, newest first. Filters (all optional): `:module`, `:kind`, `:state` (one
  or a list; `:active` for the unfinished ones), `:scope` (`:site` or
  `{type, uuid}`), `:limit` (default 25), `:offset`.
  """
  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(filters \\ []) do
    filters
    |> query()
    |> order_by([r], desc: r.inserted_at, desc: r.uuid)
    |> limit(^Keyword.get(filters, :limit, 25))
    |> offset(^Keyword.get(filters, :offset, 0))
    |> repo().all()
  end

  @doc "How many runs match the filters of `list_runs/1`."
  @spec count_runs(keyword()) :: non_neg_integer()
  def count_runs(filters \\ []) do
    filters |> query() |> select([r], count(r.uuid)) |> repo().one()
  end

  defp query(filters) do
    Enum.reduce(filters, from(r in Run), fn
      {:module, module}, q when is_binary(module) ->
        where(q, [r], r.module == ^module)

      {:kind, kind}, q when is_binary(kind) ->
        where(q, [r], r.kind == ^kind)

      {:state, :active}, q ->
        where(q, [r], r.state in ^Run.active_states())

      {:state, states}, q when is_list(states) ->
        where(q, [r], r.state in ^states)

      {:state, state}, q when is_binary(state) ->
        where(q, [r], r.state == ^state)

      {:scope, :site}, q ->
        where(q, [r], is_nil(r.scope_type))

      {:scope, {type, uuid}}, q ->
        where(q, [r], r.scope_type == ^to_string(type) and r.scope_uuid == ^uuid)

      _other, q ->
        q
    end)
  end

  @doc "The Activity entries of one run, oldest first."
  @spec history(Run.t() | String.t()) :: [PhoenixKit.Activity.Entry.t()]
  def history(%Run{uuid: uuid}), do: History.for_run(uuid)
  def history(uuid) when is_binary(uuid), do: History.for_run(uuid)

  @doc "The kind modules known now (`PhoenixKit.Jobs.Kinds.all/0`)."
  @spec kinds() :: [module()]
  def kinds, do: Kinds.all()

  # ---------------------------------------------------------------------------
  # Inside a batch, and inline
  # ---------------------------------------------------------------------------

  @doc """
  Tells the engine a long batch is still alive, and checks that it still holds the
  run. Call between steps of a batch that may run for minutes. `:ok`, or `{:error,
  :claim_lost}` when something else holds the run now (stop working).

  For a queued batch this is **observability and a cooperative check only**: the
  sweeper never reads it, and judges the batch by its own Oban job. For a script
  (`run_inline/3`) it renews the lease that keeps the sweeper from taking the run
  (`PhoenixKit.Jobs.Run.inline_lease_seconds/0`, an hour).
  """
  @spec heartbeat(Run.t()) :: :ok | {:error, :claim_lost}
  defdelegate heartbeat(run), to: Engine

  @doc """
  Runs a run **in the calling process** to its end (or until it is paused or
  cancelled by someone else): what a Mix task or a script does instead of
  queueing. It goes through the same claim, checkpoint and failure rules as a
  queued run, and refuses a run a batch holds (`{:error, :claimed}`). Mode
  defaults to `"script"`; no Oban job is made. `:on_progress` is called with the
  run after every batch that made progress (a Mix task prints from it). A
  `{:snooze, s}` or a batch's `schedule_in:` is waited out — in short slices, so a
  pause or a cancel ends the wait.

  The claim a script takes is a **lease** (`PhoenixKit.Jobs.Run.inline_lease_seconds/0`,
  an hour, renewed by `heartbeat/1`): the sweeper has no Oban job to ask about a
  script and leaves its claim alone while the lease stands. A script that dies
  leaves its run held until the lease runs out, when the sweeper takes the run back
  (and a new script may take it over). Like `PhoenixKit.Jobs.System`, this is
  trusted application code: it checks no permission.
  """
  @spec run_inline(module(), run_scope(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run_inline(kind, run_scope \\ :site, opts \\ []) do
    opts = opts |> Keyword.put_new(:mode, "script") |> Keyword.put(:dispatch, false)

    with {:ok, run, _how} <- Engine.start(kind, normalize_scope(run_scope), opts) do
      # One identity for the whole loop: the run is this invocation's between batches.
      inline(kind, run, Keyword.put(opts, :owner, Ecto.UUID.generate()))
    end
  end

  defp inline(kind, %Run{uuid: uuid}, opts) do
    case Engine.claim_inline(uuid, opts[:owner]) do
      {:ok, claimed, token} ->
        outcome = RunWorker.batch_outcome(kind, claimed, true)

        case Engine.checkpoint(uuid, token, outcome, dispatch: false, mode: opts[:mode]) do
          {:ok, %Run{state: state} = updated} when state in ~w(queued running) ->
            # A snooze made no progress to report; a batch's own delay is waited
            # out, in slices short enough to notice a pause or a cancel.
            if match?({:more, _, _}, outcome) and opts[:on_progress],
              do: opts[:on_progress].(updated)

            wait(uuid, delay_of(outcome))
            inline(kind, updated, opts)

          {:ok, updated} ->
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :inactive} ->
        {:ok, get_run(uuid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delay_of({:snooze, seconds}), do: seconds
  defp delay_of({:more, _progress, opts}), do: Keyword.get(opts, :schedule_in, 0)
  defp delay_of(_outcome), do: 0

  @wait_slice 250

  defp wait(_uuid, seconds) when seconds <= 0, do: :ok

  defp wait(uuid, seconds) do
    wait_until(uuid, System.monotonic_time(:millisecond) + seconds * 1000)
  end

  # Sleeps in short slices and gives up the wait as soon as the run is no longer
  # waiting for a batch (someone paused or cancelled it), so a control is not
  # held up by a long delay.
  defp wait_until(uuid, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        :ok

      match?(%Run{state: state} when state not in ~w(queued running), get_run(uuid)) ->
        :ok

      true ->
        Process.sleep(min(remaining, @wait_slice))
        wait_until(uuid, deadline)
    end
  end

  # ---------------------------------------------------------------------------
  # Oban's own numbers (the Queue tab) and the old module's functions
  # ---------------------------------------------------------------------------

  @doc """
  Always `true`: Jobs is core. Kept for callers of the module this used to be;
  there is no toggle.
  """
  @doc deprecated: "Jobs is always on"
  @spec enabled?() :: boolean()
  def enabled?, do: true

  @doc "Does nothing: Jobs is always on. Kept for callers of the module this used to be."
  @doc deprecated: "Jobs is always on"
  def enable_system, do: {:ok, :always_on}

  @doc "Does nothing: Jobs is always on. Kept for callers of the module this used to be."
  @doc deprecated: "Jobs is always on"
  def disable_system, do: {:ok, :always_on}

  @doc "The Oban job counts by state and whether Jobs is on."
  @spec get_config() :: map()
  def get_config, do: %{enabled: true, stats: get_job_stats()}

  @doc """
  Job statistics from the Oban jobs table (read through Oban's configured prefix;
  all zeros where no Oban instance runs in this VM, and a database error is
  raised, not hidden).

      iex> PhoenixKit.Jobs.get_job_stats()
      %{available: 5, scheduled: 2, executing: 1, completed: 100, ...}
  """
  @spec get_job_stats() :: map()
  def get_job_stats do
    stats = ObanStore.state_counts()

    Map.new(
      ~w(available scheduled executing completed retryable discarded cancelled)a,
      &{&1, Map.get(stats, Atom.to_string(&1), 0)}
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp kind_module(kind) when is_atom(kind) and not is_nil(kind) do
    if Code.ensure_loaded?(kind) and function_exported?(kind, :kind, 0),
      do: {:ok, kind},
      else: {:error, :unknown_kind}
  end

  defp kind_module(kind) when is_binary(kind) do
    case Kinds.get(kind) do
      nil -> {:error, :unknown_kind}
      mod -> {:ok, mod}
    end
  end

  defp kind_module(_kind), do: {:error, :unknown_kind}

  defp fetch(%Run{uuid: uuid}), do: get_run(uuid)
  defp fetch(uuid) when is_binary(uuid), do: get_run(uuid)

  defp normalize_scope(:site), do: :site
  defp normalize_scope({type, uuid}), do: {to_string(type), to_string(uuid)}

  defp scope_of(%Run{scope_type: nil}), do: :site
  defp scope_of(%Run{scope_type: type, scope_uuid: uuid}), do: {type, to_string(uuid)}
end
