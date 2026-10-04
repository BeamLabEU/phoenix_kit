defmodule PhoenixKit.Jobs.ObanStore do
  @moduledoc """
  Reads of Oban's own `oban_jobs` table, routed the way Oban routes them.

  `Oban.Job` carries no PhoenixKit `@schema_prefix`, so `Repo.get(Oban.Job, id)`
  reads the connection's default schema — the wrong table on an install whose
  Oban lives in a named schema (`config :app, Oban, prefix: "..."`), and a table
  that may not exist at all. Oban inserts a dispatch with its configured prefix;
  everything that looks at the dispatch again must go through the same
  configuration. This module is the one place that does.

  **The prefix is known only from a running Oban instance.** Where none runs in
  this VM (a script, a web-only node), this module does not guess: a dispatch
  lookup answers `:unavailable`, and a listing answers the default the caller
  gave. It never falls back to a raw query on the repo, which would read the
  default schema — a different table. A database error while reading the *right*
  table is not "unavailable"; it is raised.
  """

  import Ecto.Query

  alias PhoenixKit.Jobs.Run

  @doc "Whether an Oban instance runs in this VM, so that its table can be read."
  @spec available?() :: boolean()
  def available?, do: not is_nil(Oban.whereis(Oban))

  @doc """
  The Oban job `id` as the current dispatch of `run`, or `nil` when there is none
  that belongs to it: never made, pruned, or a row of another worker, run or
  generation (an integer id alone proves nothing). `:unavailable` when Oban cannot
  be asked — **including for a run that has no job id**: whether a dispatch is
  missing cannot be judged while nothing could have made one.
  """
  @spec dispatch_of(Run.t()) :: Oban.Job.t() | nil | :unavailable
  def dispatch_of(%Run{oban_job_id: id} = run) do
    cond do
      not available?() -> :unavailable
      is_nil(id) -> nil
      true -> check(Oban.Repo.get(Oban.config(), Oban.Job, id), run)
    end
  end

  defp check(%Oban.Job{} = job, %Run{} = run), do: if(dispatch?(job, run), do: job, else: nil)
  defp check(nil, _run), do: nil

  defp dispatch?(%Oban.Job{worker: worker, args: args}, %Run{} = run) do
    worker == inspect(PhoenixKit.Jobs.RunWorker) and
      args["run_uuid"] == run.uuid and args["generation"] == run.generation
  end

  @doc "`Oban.Repo.all/2` for `query`; `default` when Oban cannot be asked."
  @spec all(Ecto.Queryable.t(), list()) :: list()
  def all(query, default \\ []), do: read(default, &Oban.Repo.all(&1, query))

  @doc "`Oban.Repo.one/2` for `query`; `default` when Oban cannot be asked."
  @spec one(Ecto.Queryable.t(), term()) :: term()
  def one(query, default \\ nil), do: read(default, &Oban.Repo.one(&1, query))

  @doc "`Oban.Repo.aggregate/3` for `query`; `default` when Oban cannot be asked."
  @spec aggregate(Ecto.Queryable.t(), :count | :sum | :avg | :min | :max, term()) :: term()
  def aggregate(query, kind, default \\ 0),
    do: read(default, &Oban.Repo.aggregate(&1, query, kind))

  @stalled_after 600

  @doc """
  The queues that look dead: an active run's current dispatch has been `available`
  for `after_seconds` (default ten minutes) and **nothing in that queue has executed
  or attempted a job in that time**. Paused runs and obsolete generations do not
  need dispatch and cannot make a queue look stalled. Observed from Oban's own
  table — a web node with `queues: false` proves nothing about a separate worker
  node, and this reads what the nodes actually did. Empty when Oban cannot be asked.
  """
  @spec stalled_queues(non_neg_integer(), DateTime.t()) :: [String.t()]
  def stalled_queues(after_seconds \\ @stalled_after, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -after_seconds, :second)
    worker = inspect(PhoenixKit.Jobs.RunWorker)
    # Oban's read prefix must not override the kit table's own schema, including
    # a default-public kit with Oban installed into a separate named schema.
    run_prefix = Run.__schema__(:prefix) || "public"

    waiting =
      from(j in Oban.Job,
        join: r in Run,
        prefix: ^run_prefix,
        on: r.oban_job_id == j.id,
        where: r.state in ~w(queued running),
        where: is_nil(r.claim_owner) or r.claim_owner != "inline",
        where: fragment("?->>'run_uuid' = ?::text", j.args, r.uuid),
        where: fragment("?->>'generation' = ?::text", j.args, r.generation),
        where: j.worker == ^worker and j.state == "available" and j.scheduled_at < ^since,
        distinct: true,
        select: j.queue
      )
      |> all()

    if waiting == [] do
      []
    else
      alive =
        from(j in Oban.Job,
          where:
            j.queue in ^waiting and
              (j.state == "executing" or j.attempted_at > ^since or j.completed_at > ^since),
          distinct: true,
          select: j.queue
        )
        |> all()

      waiting -- alive
    end
  end

  @doc "The Oban job counts by state (empty when Oban cannot be asked)."
  @spec state_counts() :: %{String.t() => non_neg_integer()}
  def state_counts do
    from(j in Oban.Job, group_by: j.state, select: {j.state, count(j.id)})
    |> all()
    |> Map.new()
  end

  defp read(default, fun) do
    if available?(), do: fun.(Oban.config()), else: default
  end
end
