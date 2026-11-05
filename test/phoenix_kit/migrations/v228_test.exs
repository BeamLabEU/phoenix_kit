defmodule PhoenixKit.Migrations.Postgres.V228Test do
  @moduledoc """
  V228's reconcile lease on `phoenix_kit_files`, run as the real SQL: the two
  columns, a re-run and a round trip, and that the manifest (`ExpectedSchema`)
  declares exactly what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V228
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp columns do
    query("""
    SELECT column_name, data_type, datetime_precision, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_files'
      AND column_name IN ('reconcile_lock_token', 'reconcile_locked_until')
    ORDER BY column_name
    """)
  end

  test "the chain is at 228 or later, with both columns nullable and without a default" do
    assert String.to_integer(marker()) >= 228

    assert [
             ["reconcile_lock_token", "uuid", nil, nil, "YES"],
             ["reconcile_locked_until", "timestamp without time zone", 0, nil, "YES"]
           ] = columns()
  end

  test "rolls back, forward, and again without change" do
    run(V228.down_statements("public"))
    assert columns() == []
    assert marker() == "227"

    run(V228.up_statements("public"))
    assert length(columns()) == 2
    assert marker() == "228"

    run(V228.up_statements("public"))
    assert length(columns()) == 2
  end

  describe "the manifest" do
    defp declared_by_v228 do
      for %{since: 228} = object <- ExpectedSchema.objects("public"), do: object
    end

    defp newest_shape(%{revisions: revisions}) do
      {_version, shape} = Enum.max_by(revisions, fn {version, _} -> version end)
      shape
    end

    test "declares the two columns" do
      assert [
               %{id: "column:phoenix_kit_files.reconcile_lock_token", class: :column},
               %{id: "column:phoenix_kit_files.reconcile_locked_until", class: :column}
             ] = declared_by_v228()
    end

    test "what it declares matches what the chain built" do
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v228(),
            problem = problem(object, Probe.lookup(snapshot, object.check)),
            do: {object.id, problem}

      assert problems == []
    end

    defp problem(_object, nil), do: :missing

    defp problem(object, observed) do
      case Differ.compare(object.class, newest_shape(object), observed) do
        :match ->
          nil

        {:mismatch, _} = mismatch ->
          if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
      end
    end
  end
end
