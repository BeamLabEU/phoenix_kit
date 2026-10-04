defmodule PhoenixKit.Jobs.Engine do
  @moduledoc """
  The transactional core of job runs. Not the public API — that is
  `PhoenixKit.Jobs`, which checks permissions and takes a `Scope`; this module
  trusts its caller and does the I/O the pure `PhoenixKit.Jobs.StateMachine`
  decides.

  **Every transition is one transaction**: the row is locked (`FOR UPDATE`), the
  state machine says what changes and what to do besides, the changes are
  written, the Oban job a dispatch asks for is inserted, and the Activity entry
  is inserted — all or nothing. The PubSub broadcast, the feed's broadcast and
  the kind's `on_finish/2` happen **after** the commit.

  Because the row is locked, a pause that races a checkpoint is serialised: it
  either commits first (the checkpoint then sees `pausing` and dispatches
  nothing) or after (it then sees the batch is done). That is what a re-read of
  the state before an enqueue could not give.

  ## Not inside another transaction

  The promise above — nothing is published or finished before the commit — can
  only be kept when this module's transaction is the outermost one. Called from
  inside a host's `Repo.transaction/1` or an `Ecto.Multi`, the commit is the
  host's, and an event or an `on_finish/2` would escape a transaction that may
  still roll back. Every entry point therefore refuses to run there and answers
  `{:error, :in_transaction}` before writing anything: call `PhoenixKit.Jobs`
  after your transaction commits.

  ## Dispatch

  A dispatch bumps `generation` (the state machine puts it in the changes) and
  inserts a `PhoenixKit.Jobs.RunWorker` job carrying that generation. A job of an
  older generation finds a mismatch when it tries to claim and does nothing.
  When Oban is not running (a web-only node, a script) the insert is skipped,
  the run keeps its new generation and no job, and the sweeper — or the next
  node that runs Oban — recovers it.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.Jobs.{Events, History, Kinds, Run, RunWorker, StateMachine}

  @type ctx :: %{actor: String.t() | nil, mode: String.t(), dispatch: boolean()}
  @type scope :: :site | {String.t(), String.t()}

  @actions %{
    "queued" => :queued,
    "running" => :running,
    "pausing" => :pausing,
    "paused" => :paused,
    "cancelling" => :cancelling,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled
  }

  defp repo, do: PhoenixKit.RepoHelper.repo()
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # ---------------------------------------------------------------------------
  # Start
  # ---------------------------------------------------------------------------

  @doc """
  Starts a run of `kind` for `scope`, or says which one is already active.

  Options: `:args` (a map), `:actor_uuid`, `:mode` (default `"manual"`),
  `:retry_of` (a run uuid, kept in the args). Returns `{:ok, run, :started}`,
  `{:ok, run, :existing}` (an active run of this kind and scope exists; the
  kind's `restart/0` decided whether it was asked for a fresh pass) or
  `{:error, reason}`. `{:error, :raced}` — the active run finished as this start
  arrived, three attempts in a row — means the trigger was **not** recorded.
  """
  @spec start(module(), scope(), keyword()) ::
          {:ok, Run.t(), :started | :existing} | {:error, term()}
  def start(kind, scope, opts \\ []), do: start(kind, scope, opts, 3)

  # A start that meets an active run which finishes before it can be read is
  # tried again (the next attempt finds no active run and makes its own): a
  # trigger must not be lost to that window.
  defp start(kind, scope, opts, attempts_left) do
    case do_start(kind, scope, opts) do
      {:error, :raced} when attempts_left > 1 -> start(kind, scope, opts, attempts_left - 1)
      other -> other
    end
  end

  defp do_start(kind, scope, opts) do
    if repo().in_transaction?(),
      do: {:error, :in_transaction},
      else: do_start_outside(kind, scope, opts)
  end

  defp do_start_outside(kind, scope, opts) do
    ctx = ctx(opts)
    args = opts |> Keyword.get(:args, %{}) |> stringify()
    args = if retry = opts[:retry_of], do: Map.put(args, "retry_of", to_string(retry)), else: args
    {scope_type, scope_uuid} = split_scope(scope)

    with :ok <- kind.on_start(args) do
      attrs = %{
        kind: kind.kind(),
        module: kind.module_key(),
        scope_type: scope_type,
        scope_uuid: scope_uuid,
        title: kind.title(args, scope),
        mode: ctx.mode,
        started_by_uuid: ctx.actor,
        args: args,
        generation: 1
      }

      case insert_and_dispatch(attrs, ctx) do
        {:ok, run, entries} ->
          published(run, entries, :started)
          {:ok, run, :started}

        {:error, %Ecto.Changeset{} = changeset} ->
          if Keyword.has_key?(changeset.errors, :kind),
            do: existing(kind, scope, ctx),
            else: {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp insert_and_dispatch(attrs, ctx) do
    result =
      transact(fn ->
        with {:ok, run} <- repo().insert(Run.insert_changeset(attrs)),
             {:ok, run, entries} <-
               run_effects(run, [{:dispatch, 0}, {:log, "job.started", %{}}], ctx) do
          {run, entries}
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, {run, entries}} -> {:ok, run, entries}
      {:error, reason} -> {:error, reason}
    end
  end

  # A start that finds a run already active returns it. A kind that wants a fresh
  # pass (a profile changed again while it reconciles) leaves the request on the
  # run, to be taken in at its next batch boundary.
  defp existing(kind, scope, ctx) do
    case active_run(kind.kind(), scope) do
      nil ->
        # It finished between the conflict and the read: the caller may try again.
        {:error, :raced}

      run ->
        if kind.restart() == :restart do
          case transition(run.uuid, :request_restart, ctx_opts(ctx)) do
            {:ok, run} -> {:ok, run, :existing}
            # It finished (or went) before the request landed: the trigger is not
            # lost, the start is tried again and makes a run of its own.
            {:error, reason} when reason in [:finished, :not_found] -> {:error, :raced}
            # Anything else means the request was not recorded: say so.
            {:error, reason} -> {:error, reason}
          end
        else
          {:ok, run, :existing}
        end
    end
  end

  @doc "The active run of `kind` for `scope`, or nil."
  @spec active_run(String.t(), scope()) :: Run.t() | nil
  def active_run(kind, scope) do
    {scope_type, scope_uuid} = split_scope(scope)

    query =
      from(r in Run, where: r.kind == ^kind and r.state in ^Run.active_states(), limit: 1)

    query =
      if scope_type,
        do: where(query, [r], r.scope_type == ^scope_type and r.scope_uuid == ^scope_uuid),
        else: where(query, [r], is_nil(r.scope_type))

    repo().one(query)
  end

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc """
  Applies a state machine event to the run, in one transaction. Returns the
  updated run, or `{:error, reason}` (`:not_found` or the machine's).
  """
  @spec transition(String.t(), StateMachine.event(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def transition(run_uuid, event, opts \\ []) do
    ctx = ctx(opts)

    result =
      transact(fn ->
        with %Run{} = run <- lock(run_uuid) || {:error, :not_found} do
          apply_event(run, event, ctx)
        end
        |> unwrap()
      end)

    case result do
      {:ok, step} ->
        announce(step)
        {:ok, elem(step, 1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One event on a locked run: the machine decides, the changes are written, the
  # effects carried out. `{before, updated, entries, event}`, to be announced after
  # the commit.
  defp apply_event(%Run{} = run, event, ctx) do
    with {:ok, changes, effects} <- StateMachine.transition(run, event, now()),
         {:ok, updated} <- repo().update(Ecto.Changeset.change(run, changes)),
         {:ok, updated, entries} <- run_effects(updated, effects, ctx) do
      {:ok, {run, updated, entries, event}}
    end
  end

  # Inside a transaction function: an error rolls back, anything else is the value.
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: repo().rollback(reason)

  defp announce({before, run, entries, event}) do
    published(run, entries, action(before, run, event))
    finished(before, run)
  end

  # The one place a transaction opens. Refused inside an outer one: the commit
  # would not be ours, and what follows it would escape a rollback.
  defp transact(fun) do
    if repo().in_transaction?(), do: {:error, :in_transaction}, else: repo().transaction(fun)
  end

  @doc """
  Takes the claim on a run for the Oban job of `generation`. `{:ok, run, token}`
  (the run as it is now, a pending restart already taken in), or `{:skip,
  reason}`: `:obsolete` (an older generation, or the run is gone), `:inactive`
  (paused, cancelled, finished…) or `:busy` (a batch still holds it).
  """
  @spec claim(String.t(), integer()) ::
          {:ok, Run.t(), String.t()}
          | {:skip, :obsolete | :inactive | :busy}
          | {:error, :in_transaction}
  def claim(run_uuid, generation) do
    token = Ecto.UUID.generate()

    result =
      transact(fn ->
        case lock(run_uuid) do
          nil ->
            repo().rollback({:skip, :obsolete})

          %Run{generation: g} when g != generation ->
            repo().rollback({:skip, :obsolete})

          run ->
            case StateMachine.transition(run, {:claim, token}, now()) do
              {:error, :claimed} ->
                repo().rollback({:skip, :busy})

              {:error, _reason} ->
                repo().rollback({:skip, :inactive})

              {:ok, changes, _effects} ->
                {:ok, updated} = repo().update(Ecto.Changeset.change(run, changes))
                updated
            end
        end
      end)

    case result do
      {:ok, run} -> {:ok, run, token}
      {:error, {:skip, _reason} = skip} -> skip
      {:error, :in_transaction} -> {:error, :in_transaction}
    end
  end

  @doc """
  Claims a run for **inline** execution (`PhoenixKit.Jobs.run_inline/3`): any
  generation, and the run's generation is bumped so a pending Oban job of the
  old one is inert. Refuses a run a batch already holds — unless that is a
  script's claim whose lease ran out (`Run.lease_expired?/2`), which a new script
  may take over. The claim is marked `inline`: the sweeper has no Oban job to ask
  about it, and judges it only by its lease.

  `owner` identifies the invocation (`run_inline/3` makes one and passes it to every
  batch of its loop). It is kept on the run between the batches, while the script
  waits out a delay, and **a different owner is refused (`:claimed`) while that
  owner's lease stands** — the wait belongs to the invocation that asked for it.
  A new invocation may take the run over once the lease has run out.
  """
  @spec claim_inline(String.t(), String.t()) ::
          {:ok, Run.t(), String.t()}
          | {:error, :claimed | :inactive | :not_found | :in_transaction}
  def claim_inline(run_uuid, owner \\ Ecto.UUID.generate()) do
    token = Ecto.UUID.generate()

    result =
      transact(fn ->
        with %Run{} = run <- lock(run_uuid) || {:error, :not_found},
             :ok <- not_waited_on_by_another(run, owner),
             {free, interrupted} = free_of_dead_script(run),
             {:ok, changes, _} <- StateMachine.transition(free, {:claim, token}, now()),
             changes = inline_claim_changes(changes, run, interrupted, owner),
             {:ok, updated} <- repo().update(Ecto.Changeset.change(run, changes)) do
          updated
        else
          {:error, :claimed} -> repo().rollback(:claimed)
          {:error, :not_found} -> repo().rollback(:not_found)
          {:error, :in_transaction} -> repo().rollback(:in_transaction)
          {:error, _} -> repo().rollback(:inactive)
        end
      end)

    case result do
      {:ok, run} -> {:ok, run, token}
      {:error, reason} -> {:error, reason}
    end
  end

  # A script waiting out a delay between its batches holds no batch claim, but the
  # run is still its own: another invocation does not get to discard the wait.
  defp not_waited_on_by_another(%Run{} = run, owner) do
    if Run.inline_waiting?(run) and run.owner_token != owner and
         not Run.lease_expired?(run, now()),
       do: {:error, :claimed},
       else: :ok
  end

  defp inline_claim_changes(changes, %Run{} = run, interrupted, owner) do
    changes =
      Map.merge(changes, %{
        generation: run.generation + 1,
        claim_owner: "inline",
        owner_token: owner
      })

    if interrupted,
      do: Map.put(changes, :interruptions, run.interruptions + 1),
      else: changes
  end

  # The run as a new script may see it: a dead script's claim is not one. The
  # second element says a batch was cut off (the new script will run it again).
  defp free_of_dead_script(%Run{} = run) do
    if Run.inline_claim?(run) and Run.lease_expired?(run, now()),
      do: {%{run | claim_token: nil, claim_owner: nil}, true},
      else: {run, false}
  end

  @doc """
  Recovers one run the sweeper suspects stopped without saying so — **decided under
  the row lock**.

  The caller lists candidates cheaply; whether a candidate really needs recovery
  is only knowable once nothing else can move it, so the decision is made here:
  the run is locked and reloaded, must still be unchanged since `cutoff` and
  waiting on a batch (`queued`, `running`, `pausing`, `cancelling`), and `decide`
  is then called with the run as it is *now* and answers `:leave` or
  `{tag, event}` — the state machine event that puts it right, and a tag
  (`:released`, `:failed`, `:rescued`) for the caller's tally. A candidate that a
  live worker advanced, rescued or claimed in the meantime is therefore left
  alone, whatever the sweeper saw before. A release is followed by one more
  decision on the released run (a dead job is judged like any waiting one), in
  the same transaction.

  `{:ok, tag}` (`:left` when nothing was done) or `{:error, reason}`.
  """
  @spec recover(
          String.t(),
          DateTime.t(),
          (Run.t() -> :leave | {atom(), StateMachine.event()}),
          keyword()
        ) :: {:ok, atom()} | {:error, term()}
  def recover(run_uuid, cutoff, decide, opts \\ []) do
    ctx = ctx(Keyword.put_new(opts, :mode, "auto"))

    result =
      transact(fn ->
        with %Run{} = run <- lock(run_uuid) || {:error, :not_found},
             :ok <- recoverable(run, cutoff) do
          recover_steps(run, decide, ctx, [], nil)
        end
        |> unwrap()
      end)

    case result do
      {:ok, {tag, steps}} ->
        Enum.each(steps, &announce/1)
        {:ok, tag}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recoverable(%Run{state: state, updated_at: updated_at}, cutoff) do
    cond do
      state not in ~w(queued running pausing cancelling) -> {:error, :not_active}
      DateTime.compare(updated_at, cutoff) != :lt -> {:error, :changed}
      true -> :ok
    end
  end

  defp recover_steps(%Run{} = run, decide, ctx, steps, last_tag) do
    case decide.(run) do
      :leave ->
        {:ok, {last_tag || :left, Enum.reverse(steps)}}

      {tag, event} ->
        with {:ok, {_before, updated, _entries, _event} = step} <- apply_event(run, event, ctx) do
          steps = [step | steps]

          if tag == :released and updated.state in ~w(queued running) do
            recover_steps(updated, decide, ctx, steps, :released)
          else
            {:ok, {tally(tag, updated), Enum.reverse(steps)}}
          end
        end
    end
  end

  # A rescue that used up the budget failed the run: the tally says so.
  defp tally(:rescued, %Run{state: "failed"}), do: :failed
  defp tally(tag, _run), do: tag

  @doc """
  The batch holding `token` is done: records its outcome (see
  `PhoenixKit.Jobs.StateMachine`) and, unless a pause or cancel was waiting,
  dispatches the next batch — in one transaction. `:dispatch` false (inline
  execution) leaves the dispatch to the caller.
  """
  @spec checkpoint(String.t(), String.t(), StateMachine.outcome(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def checkpoint(run_uuid, token, outcome, opts \\ []),
    do: transition(run_uuid, {:checkpoint, token, outcome}, opts)

  @doc "Records a sign of life from the batch holding `token`. Cheap: no transaction."
  @spec heartbeat(Run.t()) :: :ok | {:error, :claim_lost}
  def heartbeat(%Run{uuid: uuid, claim_token: token}) when not is_nil(token) do
    {count, _} =
      from(r in Run, where: r.uuid == ^uuid and r.claim_token == ^token)
      |> repo().update_all(set: [heartbeat_at: now()])

    if count == 1, do: :ok, else: {:error, :claim_lost}
  end

  def heartbeat(%Run{}), do: {:error, :claim_lost}

  # ---------------------------------------------------------------------------
  # Effects
  # ---------------------------------------------------------------------------

  # Carries out what a transition asked for, inside its transaction: the Oban
  # job of a dispatch and the Activity entries of a log. Returns the run with the
  # dispatch's job id and the inserted entries (published after the commit).
  defp run_effects(%Run{} = run, effects, ctx) do
    Enum.reduce_while(effects, {:ok, run, []}, fn
      {:dispatch, seconds}, {:ok, run, entries} ->
        run = if ctx.dispatch, do: dispatch(run, seconds), else: run
        {:cont, {:ok, run, entries}}

      {:log, action, extra}, {:ok, run, entries} ->
        case repo().insert(History.entry_changeset(run, action, extra, ctx)) do
          {:ok, entry} -> {:cont, {:ok, run, [entry | entries]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
    end)
    |> case do
      {:ok, run, entries} -> {:ok, run, Enum.reverse(entries)}
      error -> error
    end
  end

  defp dispatch(%Run{} = run, seconds) do
    kind = Kinds.get(run.kind)

    opts =
      [queue: kind && kind.queue(), max_attempts: kind && kind.max_attempts()]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.merge(if seconds > 0, do: [schedule_in: seconds], else: [])

    args = %{"run_uuid" => run.uuid, "generation" => run.generation, "kind" => run.kind}

    case insert_job(RunWorker.new(args, opts)) do
      {:ok, job_id} ->
        from(r in Run, where: r.uuid == ^run.uuid)
        |> repo().update_all(set: [oban_job_id: job_id])

        %{run | oban_job_id: job_id}

      :unavailable ->
        Logger.warning(
          "Jobs: no Oban to dispatch run #{run.uuid} (#{run.kind}); the sweeper will pick it up"
        )

        run
    end
  end

  # Oban not running (no instance, a dead pool) is not an error of the run: it
  # keeps its generation and the sweeper dispatches it later.
  defp insert_job(changeset) do
    case Oban.insert(changeset) do
      {:ok, %Oban.Job{id: id}} -> {:ok, id}
      {:error, _reason} -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  # ---------------------------------------------------------------------------
  # After the commit
  # ---------------------------------------------------------------------------

  defp published(run, entries, action) do
    Enum.each(entries, &Activity.broadcast/1)
    Events.broadcast(run, action)
  end

  # A run that just reached a terminal state tells its kind, outside the
  # transaction; a kind that raises must not undo anything.
  defp finished(%Run{state: before}, %Run{state: state} = run) when before != state do
    if Run.terminal?(state) do
      case Kinds.get(run.kind) do
        nil ->
          :ok

        kind ->
          try do
            kind.on_finish(run, state)
          rescue
            error -> Logger.warning("Jobs: #{run.kind} on_finish raised #{inspect(error)}")
          catch
            kind, reason ->
              Logger.warning("Jobs: #{run.kind} on_finish #{inspect({kind, reason})}")
          end
      end
    end

    :ok
  end

  defp finished(_before, _run), do: :ok

  # What happened, for the broadcast: the new state, or `:progress` for a batch
  # that moved the counters without changing the state.
  defp action(%Run{state: state}, %Run{state: state}, {:checkpoint, _token, _outcome}),
    do: :progress

  defp action(_before, %Run{state: state}, _event), do: Map.fetch!(@actions, state)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp lock(run_uuid) do
    from(r in Run, where: r.uuid == ^run_uuid, lock: "FOR UPDATE") |> repo().one()
  end

  defp ctx(opts) do
    %{
      actor: opts[:actor_uuid],
      mode: Keyword.get(opts, :mode, "manual"),
      dispatch: Keyword.get(opts, :dispatch, true)
    }
  end

  defp ctx_opts(%{actor: actor, mode: mode}), do: [actor_uuid: actor, mode: mode]

  defp split_scope(:site), do: {nil, nil}
  defp split_scope({type, uuid}) when is_binary(type), do: {type, to_string(uuid)}

  defp stringify(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
