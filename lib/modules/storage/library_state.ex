defmodule PhoenixKit.Modules.Storage.LibraryState do
  @moduledoc """
  What is going on with each library's storage, derived — never stored — from two
  things: how many of its files are out of date
  (`PhoenixKit.Modules.Storage.Reconciler.counts_by_library/0`, one grouped query)
  and its `storage.reconcile` run
  (`PhoenixKit.Modules.Storage.Jobs.Reconcile`, `dev_docs/plans/2026-10-03-job-runs.md`
  §6.3, R8).

  | state | when |
  |---|---|
  | `:paused` | its reconcile run is paused (or pausing) |
  | `:syncing` | a reconcile run is queued or running — "N files left" |
  | `:attention` | no run is active, and either its last run failed with files left, or the reconciler tried files and could not finish them (they wait out their retry window) |
  | `:waiting` | files are out of date and **no run** is active: the queue is down, or nothing has triggered yet — the case a global count hides |
  | `:up_to_date` | nothing is out of date |

  "Up to date" means the files carry the revisions of their library's profile and
  variant set. It does **not** prove every recorded object is still on its bucket;
  that is what a later `storage.verify` is for (§6.4).

  The map returned for a library:

      %{state: :syncing, out_of_date: 12, eligible: 12, failing: 0, run: %Run{}}

  `run` is the active run when there is one, else the last one, else `nil`.
  """

  import Ecto.Query

  alias PhoenixKit.Jobs.Run
  alias PhoenixKit.Modules.Storage.Reconciler

  @kind "storage.reconcile"

  @type state :: :up_to_date | :syncing | :paused | :attention | :waiting
  @type t :: %{
          state: state(),
          out_of_date: non_neg_integer(),
          eligible: non_neg_integer(),
          failing: non_neg_integer(),
          run: Run.t() | nil
        }

  @doc "The kind whose runs this state is about."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  The state of each of `library_uuids`, as a map keyed by the uuid string: three
  queries however many libraries (the counts, the active runs, the last runs).
  """
  @spec for_libraries([String.t()]) :: %{String.t() => t()}
  def for_libraries(library_uuids) do
    uuids = Enum.map(library_uuids, &to_string/1)
    counts = Reconciler.counts_by_library(cast(uuids))
    active = active_runs(uuids)
    last = last_runs(uuids)

    Map.new(uuids, fn uuid ->
      {uuid, build(Map.get(counts, uuid), Map.get(active, uuid), Map.get(last, uuid))}
    end)
  end

  @doc "The state of one library."
  @spec for_library(String.t()) :: t()
  def for_library(library_uuid) do
    uuid = to_string(library_uuid)
    Map.fetch!(for_libraries([uuid]), uuid)
  end

  @doc false
  @spec build(map() | nil, Run.t() | nil, Run.t() | nil) :: t()
  def build(counts, active, last) do
    %{out_of_date: out, eligible: eligible, failing: failing} =
      counts || %{out_of_date: 0, eligible: 0, failing: 0}

    %{
      state: state(out, failing, active, last),
      out_of_date: out,
      eligible: eligible,
      failing: failing,
      run: active || last
    }
  end

  defp state(_out, _failing, %Run{state: state}, _last) when state in ~w(paused pausing),
    do: :paused

  defp state(_out, _failing, %Run{}, _last), do: :syncing

  defp state(out, failing, nil, last) do
    cond do
      failing > 0 -> :attention
      out > 0 and match?(%Run{state: "failed"}, last) -> :attention
      out > 0 -> :waiting
      true -> :up_to_date
    end
  end

  # The unfinished reconcile run of each library (there is at most one: the active
  # index allows no more).
  defp active_runs(uuids) do
    from(r in Run,
      where: r.kind == @kind and r.state in ^Run.active_states() and r.scope_type == "library",
      where: r.scope_uuid in ^cast(uuids)
    )
    |> repo().all()
    |> Map.new(&{to_string(&1.scope_uuid), &1})
  end

  # The most recent reconcile run of each library, finished or not.
  defp last_runs(uuids) do
    from(r in Run,
      where: r.kind == @kind and r.scope_type == "library" and r.scope_uuid in ^cast(uuids),
      distinct: r.scope_uuid,
      order_by: [asc: r.scope_uuid, desc: r.inserted_at, desc: r.uuid]
    )
    |> repo().all()
    |> Map.new(&{to_string(&1.scope_uuid), &1})
  end

  defp cast(uuids), do: for(uuid <- uuids, {:ok, cast} <- [Ecto.UUID.cast(uuid)], do: cast)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
