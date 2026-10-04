defmodule PhoenixKit.Migrations.Postgres.V207Test do
  @moduledoc """
  V207's job runs table, run as the real SQL: the shape, the one-active-run-per-
  kind-and-scope index (and which states count as active), the checks, and a
  re-run and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V207
  alias PhoenixKit.Test.Repo

  @library "01a0f33e-0000-7000-8000-00000000cccc"
  @other_library "01a0f33e-0000-7000-8000-00000000dddd"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp insert_run(attrs \\ []) do
    kind = Keyword.get(attrs, :kind, "test.kind")
    state = Keyword.get(attrs, :state, "queued")
    scope_type = Keyword.get(attrs, :scope_type)
    scope_uuid = Keyword.get(attrs, :scope_uuid)
    mode = Keyword.get(attrs, :mode, "manual")

    query(
      """
      INSERT INTO public.phoenix_kit_job_runs (kind, module, scope_type, scope_uuid, title, state, mode)
      VALUES ($1, 'test', $2, $3::text::uuid, 'A run', $4, $5)
      RETURNING uuid::text
      """,
      [kind, scope_type, scope_uuid, state, mode]
    )
  end

  defp violation?(fun, code) do
    fun.()
    false
  rescue
    error in Postgrex.Error -> error.postgres.code == code
  end

  test "the chain is at 207 or later, with the table and its columns" do
    assert String.to_integer(marker()) >= 207

    columns =
      query("""
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_job_runs'
      """)
      |> List.flatten()

    for column <-
          ~w(uuid kind module scope_type scope_uuid title state done failed_count total cursor args
             result error mode started_by_uuid paused_by_uuid cancelled_by_uuid generation
             claim_token claimed_at oban_job_id restart_seq restart_ack rescues last_rescued_at
             heartbeat_at started_at paused_at cancelled_at finished_at inserted_at updated_at claim_owner wake_at interruptions owner_token) do
      assert column in columns, column
    end
  end

  test "a new run is queued, manual, with nothing done and an empty cursor" do
    [[uuid]] = insert_run()

    assert [["queued", "manual", 0, 0, 0, %{}]] =
             query(
               """
               SELECT state, mode, done, failed_count, generation, cursor
               FROM public.phoenix_kit_job_runs WHERE uuid = $1::text::uuid
               """,
               [uuid]
             )
  end

  describe "one active run per kind and scope" do
    test "a second active run of the same kind and scope is refused" do
      insert_run(scope_type: "library", scope_uuid: @library)

      assert violation?(
               fn -> insert_run(scope_type: "library", scope_uuid: @library) end,
               :unique_violation
             )
    end

    test "the site's scope (no scope at all) is one scope like another" do
      insert_run()
      assert violation?(fn -> insert_run() end, :unique_violation)
    end

    test "a different kind, or a different scope, is a different run" do
      insert_run(scope_type: "library", scope_uuid: @library)

      assert [[_]] = insert_run(kind: "test.other", scope_type: "library", scope_uuid: @library)
      assert [[_]] = insert_run(scope_type: "library", scope_uuid: @other_library)
      assert [[_]] = insert_run()
    end

    test "every unfinished state is active, so a draining run still blocks a new one" do
      for state <- V207.active_states() do
        kind = "test.#{state}"
        insert_run(kind: kind, state: state)
        assert violation?(fn -> insert_run(kind: kind) end, :unique_violation), state
      end
    end

    test "a finished run blocks nothing, however many there are" do
      for state <- ~w(completed failed cancelled) do
        kind = "test.done.#{state}"
        insert_run(kind: kind, state: state)
        insert_run(kind: kind, state: state)
        assert [[_]] = insert_run(kind: kind)
      end
    end
  end

  describe "the checks" do
    test "a state that is not one of the eight is refused" do
      assert violation?(fn -> insert_run(state: "sleeping") end, :check_violation)
    end

    test "a mode that is not one of the four is refused" do
      assert violation?(fn -> insert_run(mode: "magic") end, :check_violation)
    end

    test "a scope names both its type and its uuid, or neither" do
      assert violation?(fn -> insert_run(scope_type: "library") end, :check_violation)
      assert violation?(fn -> insert_run(scope_uuid: @library) end, :check_violation)
    end
  end

  test "a run outlives what it was about: there are no foreign keys" do
    [[uuid]] = insert_run(scope_type: "library", scope_uuid: @library)

    assert [] ==
             query("""
             SELECT conname FROM pg_constraint c
             JOIN pg_class t ON t.oid = c.conrelid
             JOIN pg_namespace n ON n.oid = t.relnamespace
             WHERE t.relname = 'phoenix_kit_job_runs' AND n.nspname = 'public' AND c.contype = 'f'
             """)

    assert [[^uuid]] =
             query(
               "SELECT uuid::text FROM public.phoenix_kit_job_runs WHERE uuid = $1::text::uuid",
               [
                 uuid
               ]
             )
  end

  test "a re-run changes nothing" do
    [[uuid]] = insert_run()

    run(V207.up_statements("public"))

    assert [[^uuid]] =
             query(
               "SELECT uuid::text FROM public.phoenix_kit_job_runs WHERE uuid = $1::text::uuid",
               [
                 uuid
               ]
             )

    assert String.to_integer(marker()) >= 207
  end

  test "a round trip removes the table and puts it back empty" do
    insert_run()

    run(V207.down_statements("public"))

    assert [[nil]] = query("SELECT to_regclass('public.phoenix_kit_job_runs')::text")
    assert marker() == "206"

    run(V207.up_statements("public"))

    assert [[0]] = query("SELECT count(*)::int FROM public.phoenix_kit_job_runs")
    assert marker() == "207"
  end
end
