defmodule PhoenixKit.Modules.Storage.Jobs.Reconcile do
  @moduledoc """
  Brings one library's files up to date with its storage profile and variant set
  (`storage.reconcile`, V205): copies objects where the profile wants them,
  unlinks them where it no longer does, and makes, remakes or deletes sizes by the
  set. `PhoenixKit.Modules.Storage.Reconciler` does the work of a batch.

  **One run per library** (scope `{"library", uuid}`). That is what lets an admin
  see a library's state, check it, pause it and read who did what
  (`dev_docs/plans/2026-10-03-job-runs.md`, §6.2). A run with no library scope
  walks every library, as the old pass did.

  **Started by itself** — `trigger/1` starts a run for each library that has files
  the reconciler may take, whenever a profile, a variant set or one of their rows
  changes (their revision is bumped), a library moves to another one, an upload
  made fewer copies or sizes than wanted, and by the daily prune and on boot. It
  is called by `Storage.Workers.ReconcileJob`, the Oban job those places have
  always queued (so they work inside a transaction too, and an older job still in
  the queue does the right thing). An admin starts one with **Check now**.

  `restart/0` is `:restart`: a change made while a pass runs starts the pass again
  from the beginning at its next batch boundary, because its cursor would skip
  files the change made stale.

  **Throttled**: ten files a batch, two seconds between batches, on the
  `file_processing` queue, so copying and ImageMagick/FFmpeg work stay bounded by
  that queue. A file that could not be finished waits ten minutes before it is
  tried again (`reconcile_attempted_at`).

  **Counts.** `done` is files reconciled, `failed` files that could not be
  finished yet (they stay stale), `total` the files this pass starts with. A pass
  whose batch was interrupted counts that batch's already-finished files in nobody's
  tally (see `PhoenixKit.Jobs.Kind`).
  """

  use PhoenixKit.Jobs.Kind

  import Ecto.Query

  alias PhoenixKit.Jobs.Run
  alias PhoenixKit.Jobs.System, as: JobsSystem
  alias PhoenixKit.Modules.Storage.{Libraries, Reconciler}

  @batch_size 10
  @pause_seconds 2

  @impl true
  def kind, do: "storage.reconcile"

  @impl true
  def module_key, do: "storage"

  @impl true
  def title(_args, {"library", uuid}) do
    case Libraries.get_library(uuid) do
      %{kind: "system", name: name} -> "Bring \"#{name}\" up to date with its storage settings"
      # A user's library is theirs and private: its name is not written into a title that
      # the Jobs page, the Libraries tab and the History tab show to site managers.
      %{kind: "user"} -> "Bring a user's library up to date with its storage settings"
      nil -> "Bring a library up to date with its storage settings"
    end
  end

  def title(_args, _scope), do: "Bring every library up to date with its storage settings"

  @impl true
  def idempotent?, do: true

  @impl true
  def restart, do: :restart

  @impl true
  def permission, do: "media.manage"

  @impl true
  def queue, do: :file_processing

  # A batch copies objects and makes sizes: video transcodes take minutes.
  @impl true
  def timeout, do: :timer.minutes(30)

  @impl true
  def batch(run) do
    scope = scope_opts(run)

    total =
      if run.cursor["after"] in [nil, ""],
        do: %{total: Reconciler.stale_count(scope)},
        else: %{}

    case Reconciler.run_batch(run.cursor["after"], @batch_size, %{}, scope) do
      {:more, last_uuid, batch} ->
        cursor = %{"after" => last_uuid, "outcomes" => outcomes(run, batch)}

        {:more, total |> Map.merge(counts(batch)) |> Map.put(:cursor, cursor),
         schedule_in: @pause_seconds}

      {:done, batch} ->
        {:done, %{"outcomes" => outcomes(run, batch)}, Map.merge(total, counts(batch))}
    end
  end

  defp scope_opts(%{scope_type: "library", scope_uuid: uuid}), do: [library_uuid: to_string(uuid)]
  defp scope_opts(_run), do: []

  # What every batch of the pass did so far, kept in the cursor so the last one can
  # report the whole pass.
  defp outcomes(run, batch) do
    Enum.reduce(batch, run.cursor["outcomes"] || %{}, fn {outcome, n}, acc ->
      Map.update(acc, Atom.to_string(outcome), n, &(&1 + n))
    end)
  end

  # A file brought up to date is done; one that could not be finished yet is
  # failed (it stays stale and is tried again); one another reconciler holds
  # (`:skipped`) is neither — that reconciler counts it.
  defp counts(batch),
    do: %{done: Map.get(batch, :reconciled, 0), failed: Map.get(batch, :stale, 0)}

  @doc """
  Starts a run for every library that has files the reconciler may take now,
  and records a restart for existing library runs even when their files are
  temporarily ineligible or their current batch has already stamped them.
  Returns `{:ok, libraries}` or `{:error, reason}` if a start was refused. A
  database error raises; the trigger job retries either failure.

  `:source` is the short phrase the run's history keeps ("a profile changed").
  """
  @spec trigger(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def trigger(opts \\ []) do
    libraries = Enum.uniq(Reconciler.libraries_with_work() ++ active_libraries())

    Enum.reduce_while(libraries, {:ok, libraries}, fn uuid, success ->
      case JobsSystem.start(__MODULE__, {"library", uuid},
             mode: :auto,
             source: opts[:source] || "a change to storage settings"
           ) do
        {:ok, _run, _how} -> {:cont, success}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp active_libraries do
    from(r in Run,
      where: r.kind == ^kind() and r.scope_type == "library",
      where: r.state in ~w(queued running pausing paused),
      select: r.scope_uuid
    )
    |> PhoenixKit.RepoHelper.repo().all()
    |> Enum.map(&to_string/1)
  end
end
