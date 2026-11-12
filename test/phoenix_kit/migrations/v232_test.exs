defmodule PhoenixKit.Migrations.Postgres.V232Test do
  @moduledoc """
  V232's stacks, run as the real SQL: the table and the columns, a re-run and a round
  trip, a deleted stack leaving its files unstacked, and that the manifest
  (`ExpectedSchema`) declares exactly what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V232
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp table? do
    [[exists]] =
      query("""
      SELECT EXISTS (SELECT 1 FROM information_schema.tables
                     WHERE table_schema = 'public' AND table_name = 'phoenix_kit_file_stacks')
      """)

    exists
  end

  defp columns do
    query("""
    SELECT column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_files'
      AND column_name IN ('stack_uuid', 'stack_position')
    ORDER BY column_name
    """)
    |> List.flatten()
  end

  test "the chain is at 232 or later, with the table and the columns" do
    assert String.to_integer(marker()) >= 232
    assert table?()
    assert columns() == ["stack_position", "stack_uuid"]
  end

  test "rolls back, forward, and again without change" do
    run(V232.down_statements("public"))
    refute table?()
    assert columns() == []
    assert marker() == "231"

    run(V232.up_statements("public"))
    assert table?()
    assert columns() == ["stack_position", "stack_uuid"]
    assert marker() == "232"

    run(V232.up_statements("public"))
    assert table?()
  end

  test "deleting a stack leaves its files, unstacked" do
    [[library]] = query("SELECT uuid FROM phoenix_kit_storage_libraries LIMIT 1")

    [[stack]] =
      query("INSERT INTO phoenix_kit_file_stacks (library_uuid) VALUES ($1) RETURNING uuid", [
        library
      ])

    [[file]] =
      query(
        """
        INSERT INTO phoenix_kit_files (original_file_name, file_name, mime_type, file_type, ext,
          file_checksum, user_file_checksum, size, library_uuid, stack_uuid, stack_position,
          inserted_at, updated_at)
        VALUES ('a.png', 'a.png', 'image/png', 'image', 'png', $1, $1, 1, $2, $3, 0, now(), now())
        RETURNING uuid
        """,
        [Ecto.UUID.generate(), library, stack]
      )

    query("DELETE FROM phoenix_kit_file_stacks WHERE uuid = $1", [stack])

    assert [[nil]] = query("SELECT stack_uuid FROM phoenix_kit_files WHERE uuid = $1", [file])
  end

  describe "the manifest" do
    defp declared_by_v232 do
      Enum.filter(ExpectedSchema.objects("public"), fn object ->
        Enum.any?(object.revisions, &(elem(&1, 0) == 232))
      end)
    end

    test "declares the table, the columns, their keys and indexes" do
      ids = MapSet.new(declared_by_v232(), & &1.id)

      for id <- [
            "table:phoenix_kit_file_stacks",
            "column:phoenix_kit_file_stacks.title",
            "column:phoenix_kit_file_stacks.description",
            "column:phoenix_kit_files.stack_uuid",
            "column:phoenix_kit_files.stack_position",
            "index:phoenix_kit_file_stacks_library_uuid_index",
            "index:phoenix_kit_files_stack_index",
            "constraint:phoenix_kit_file_stacks.phoenix_kit_file_stacks_pkey",
            "constraint:phoenix_kit_file_stacks.phoenix_kit_file_stacks_library_uuid_fkey",
            "constraint:phoenix_kit_files.phoenix_kit_files_stack_uuid_fkey"
          ] do
        assert id in ids, id
      end
    end

    test "what it declares matches what the chain built" do
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v232(),
            problem = problem(object, Probe.lookup(snapshot, object.check)),
            do: {object.id, problem}

      assert problems == []
    end

    defp problem(_object, nil), do: :missing

    defp problem(object, observed) do
      {_version, shape} = List.last(object.revisions)

      case Differ.compare(object.class, shape, observed) do
        :match ->
          nil

        {:mismatch, _} = mismatch ->
          if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
      end
    end
  end
end
