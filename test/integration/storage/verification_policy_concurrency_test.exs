defmodule PhoenixKit.Modules.Storage.VerificationPolicyConcurrencyTest do
  @moduledoc "Global verification admission across real committed PostgreSQL sessions."
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Jobs.{Engine, Run}
  alias PhoenixKit.Modules.Storage.Jobs.VerifyLibrary
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Test.Repo

  @moduletag :integration

  setup do
    Sandbox.mode(Repo, :auto)
    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [], plugins: []})
    suffix = System.unique_integer([:positive])

    libraries =
      for n <- 1..2 do
        {:ok, library} =
          Libraries.create_system_library(%{name: "Verification concurrency #{suffix}-#{n}"})

        library
      end

    uuids = Enum.map(libraries, & &1.uuid)

    on_exit(fn ->
      runs =
        Repo.all(
          from(r in Run,
            where: r.kind == "storage.verify_library" and r.scope_uuid in ^uuids,
            select: r.uuid
          )
        )

      strings = Enum.map(runs, &to_string/1)
      Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'run_uuid'", j.args) in ^strings))
      Repo.delete_all(from(e in Entry, where: e.resource_uuid in ^(runs ++ uuids)))
      Repo.delete_all(from(r in Run, where: r.uuid in ^runs))
      Repo.delete_all(from(l in Library, where: l.uuid in ^uuids))
      Sandbox.mode(Repo, :manual)
    end)

    %{libraries: libraries}
  end

  test "simultaneous starts on different libraries admit one run and one dispatch", %{
    libraries: libraries
  } do
    results =
      libraries
      |> Task.async_stream(
        fn library ->
          Engine.start(VerifyLibrary, {"library", library.uuid},
            args: %{"mode" => "presence", "include_previews" => false, "through" => nil}
          )
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, run, :started}] = Enum.filter(results, &match?({:ok, _, :started}, &1))
    assert Enum.count(results, &(&1 == {:error, :verification_busy})) == 1
    uuids = Enum.map(libraries, & &1.uuid)

    assert Repo.aggregate(
             from(r in Run, where: r.kind == "storage.verify_library" and r.scope_uuid in ^uuids),
             :count
           ) == 1

    assert Repo.aggregate(
             from(j in Oban.Job, where: fragment("?->>'run_uuid' = ?", j.args, ^run.uuid)),
             :count
           ) == 1

    stamped =
      Enum.filter(
        libraries,
        &Libraries.get_library(&1.uuid).settings["verification_last_started_at"]
      )

    assert length(stamped) == 1
  end

  test "duplicate starts on the same library remain idempotent under contention", %{
    libraries: [library | _]
  } do
    results =
      1..6
      |> Task.async_stream(
        fn _ ->
          Engine.start(VerifyLibrary, {"library", library.uuid},
            args: %{"mode" => "presence", "include_previews" => false, "through" => nil}
          )
        end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, run, :started}] = Enum.filter(results, &match?({:ok, _, :started}, &1))
    assert Enum.count(results, &match?({:ok, _, :existing}, &1)) == 5
    assert Enum.all?(results, fn {:ok, found, _} -> found.uuid == run.uuid end)
  end
end
