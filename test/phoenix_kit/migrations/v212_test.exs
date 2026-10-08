defmodule PhoenixKit.Migrations.Postgres.V212Test do
  @moduledoc """
  V212's file shape, run as the real SQL: the generated column follows `width` and
  `height`, is empty without a usable size, cannot be written, and a re-run and a
  round trip are harmless.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V212
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp column do
    query("""
    SELECT data_type, is_generated, is_nullable FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_files'
      AND column_name = 'aspect_ratio'
    """)
  end

  defp index do
    query("""
    SELECT indexdef FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'phoenix_kit_files_library_aspect_ratio_index'
    """)
  end

  # A minimal file row; only the sizes vary.
  defp insert_file(width, height) do
    n = System.unique_integer([:positive])

    [[ratio]] =
      query(
        """
        INSERT INTO public.phoenix_kit_files
          (original_file_name, file_name, mime_type, file_type, ext, file_checksum,
           user_file_checksum, size, width, height, status, file_path, inserted_at, updated_at)
        VALUES ($1, $1, 'image/jpeg', 'image', 'jpg', $2, $2, 1, $3, $4, 'active', $1, now(), now())
        RETURNING aspect_ratio
        """,
        ["v212-#{n}.jpg", "v212#{n}", width, height]
      )

    ratio
  end

  test "the chain is at 212 or later, with a generated double precision column" do
    assert String.to_integer(marker()) >= 212
    assert [["double precision", "ALWAYS", "YES"]] = column()
  end

  test "it is width over height" do
    assert insert_file(3000, 2000) == 1.5
    assert insert_file(1000, 1000) == 1.0
    assert insert_file(4000, 1000) == 4.0
    assert insert_file(1000, 4000) == 0.25
  end

  test "it is empty without a usable size" do
    assert insert_file(nil, nil) == nil
    assert insert_file(1000, nil) == nil
    assert insert_file(0, 500) == nil
    assert insert_file(500, 0) == nil
  end

  test "it cannot be written" do
    assert_raise Postgrex.Error, ~r/generated/i, fn ->
      query(
        "UPDATE public.phoenix_kit_files SET aspect_ratio = 2.0 WHERE false OR uuid IS NOT NULL"
      )
    end
  end

  test "the index is partial, on the library and the ratio" do
    assert [[def]] = index()
    assert def =~ "(library_uuid, aspect_ratio)"
    assert def =~ "WHERE (aspect_ratio IS NOT NULL)"
  end

  test "running it again changes nothing" do
    run(V212.up_statements("public"))
    run(V212.up_statements("public"))

    assert [["double precision", "ALWAYS", "YES"]] = column()
    assert [[_]] = index()
  end

  test "rolls back and forward again" do
    run(V212.down_statements("public"))
    assert column() == []
    assert index() == []
    assert marker() == "211"

    run(V212.up_statements("public"))
    assert [["double precision", "ALWAYS", "YES"]] = column()
    assert marker() == "212"
  end
end
