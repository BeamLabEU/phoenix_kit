defmodule PhoenixKit.Modules.Storage.VerificationPolicy do
  @moduledoc """
  Verification admission: one unfinished verification across the installation,
  and at most one new run per library in a rolling 30 days. Queued, running,
  draining and paused runs all occupy the global slot. Availability and deep
  checks share the limit; retries that create a new run count as new checks.

  Admission runs inside the job engine's transaction under a PostgreSQL advisory
  transaction lock. The library's internal last-start timestamp is written with
  the run, so pruning job history cannot erase a cooldown. Older runs without
  that timestamp are counted too. Failed insertions consume no allowance.
  """
  import Ecto.Query

  alias PhoenixKit.Jobs.Run
  alias PhoenixKit.Modules.Storage.Library

  @kind "storage.verify_library"
  @last_start_key "verification_last_started_at"
  @cooldown_seconds 30 * 86_400
  @lock 0x504B564552494659

  @doc "Admits a verification inside the engine's transaction; never call outside it."
  def admit({"library", uuid}) do
    if repo().in_transaction?(),
      do: admit_in_transaction(uuid),
      else: {:error, :admission_requires_transaction}
  end

  def admit(_scope), do: {:error, :invalid_scope}

  defp admit_in_transaction(uuid) do
    repo().query!("SELECT pg_advisory_xact_lock($1::bigint)", [@lock])

    active =
      repo().all(
        from(r in Run,
          where: r.kind == @kind and r.state in ^Run.active_states(),
          select: {r.scope_type, r.scope_uuid}
        )
      )

    cond do
      Enum.any?(active, &(&1 != {"library", uuid})) -> {:error, :verification_busy}
      active != [] -> :ok
      true -> reserve_library(uuid)
    end
  end

  defp reserve_library(uuid) do
    case repo().one(
           from(l in Library, where: l.uuid == ^uuid and is_nil(l.trashed_at), lock: "FOR UPDATE")
         ) do
      nil ->
        {:error, :not_found}

      library ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case next_allowed_for([library], now)[uuid] do
          nil ->
            stamp = DateTime.to_iso8601(now)

            repo().update_all(from(l in Library, where: l.uuid == ^uuid),
              set: [settings: Map.put(library.settings || %{}, @last_start_key, stamp)]
            )

            :ok

          next ->
            {:error, {:verification_cooldown, next}}
        end
    end
  end

  @doc "Public availability for the viewer's own libraries, without exposing other job details."
  def status(libraries) do
    %{
      busy:
        repo().exists?(from(r in Run, where: r.kind == @kind and r.state in ^Run.active_states())),
      next_allowed: next_allowed_for(libraries)
    }
  end

  @doc "The next allowed dates, or nil for libraries eligible now; one batched history query."
  def next_allowed_for(libraries, now \\ DateTime.utc_now())
  def next_allowed_for([], _now), do: %{}

  def next_allowed_for(libraries, now) do
    uuids = Enum.map(libraries, & &1.uuid)

    starts =
      Map.new(
        repo().all(
          from(r in Run,
            where: r.kind == @kind and r.scope_type == "library" and r.scope_uuid in ^uuids,
            group_by: r.scope_uuid,
            select: {r.scope_uuid, max(r.inserted_at)}
          )
        )
      )

    Map.new(libraries, fn library ->
      last = latest(timestamp((library.settings || %{})[@last_start_key]), starts[library.uuid])
      next = if last, do: DateTime.add(last, @cooldown_seconds, :second)
      {library.uuid, if(next && DateTime.compare(next, now) == :gt, do: next)}
    end)
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp timestamp(_value), do: nil
  defp latest(nil, right), do: right
  defp latest(left, nil), do: left
  defp latest(left, right), do: if(DateTime.compare(left, right) == :gt, do: left, else: right)
  defp repo, do: PhoenixKit.RepoHelper.repo()
end
