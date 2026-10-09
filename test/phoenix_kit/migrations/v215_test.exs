defmodule PhoenixKit.Migrations.Postgres.V215Test do
  @moduledoc """
  V215's photo position, run as the real SQL: the two columns, that an existing
  file has no position, that a box on the map is answered by the GiST index (and
  not by a scan, once there is anything to scan), and a re-run and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V215
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp columns do
    query("""
    SELECT column_name, data_type, is_nullable FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_files'
      AND column_name IN ('latitude', 'longitude') ORDER BY column_name
    """)
  end

  defp index do
    query("""
    SELECT indexdef FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'phoenix_kit_files_geo_index'
    """)
  end

  defp insert_file(lat, lon) do
    n = System.unique_integer([:positive])

    query(
      """
      INSERT INTO public.phoenix_kit_files
        (original_file_name, file_name, mime_type, file_type, ext, file_checksum,
         user_file_checksum, size, status, file_path, latitude, longitude, inserted_at, updated_at)
      VALUES ($1, $1, 'image/jpeg', 'image', 'jpg', $2, $2, 1, 'active', $1, $3, $4, now(), now())
      """,
      ["v215-#{n}.jpg", "v215#{n}", lat, lon]
    )
  end

  test "the chain is at 215 or later, with two nullable double precision columns" do
    assert String.to_integer(marker()) >= 215

    assert [
             ["latitude", "double precision", "YES"],
             ["longitude", "double precision", "YES"]
           ] = columns()
  end

  test "the index is a partial GiST index on the point" do
    assert [[definition]] = index()
    assert definition =~ "USING gist"
    assert definition =~ "point(longitude, latitude)"
    assert definition =~ "latitude IS NOT NULL"
  end

  test "a file without a position is allowed" do
    insert_file(nil, nil)
    assert [[0]] = query("SELECT count(*) FROM public.phoenix_kit_files WHERE latitude = 91")
  end

  test "a box on the map is answered from the index" do
    for i <- 1..300, do: insert_file(46.0 + rem(i, 20) / 10, 14.0 + rem(i, 30) / 10)
    query("ANALYZE public.phoenix_kit_files")

    # Planner statistics decide; with the table this small the sequential scan
    # can win, so ask what the planner does when it may not use one.
    query("SET LOCAL enable_seqscan = off")

    plan =
      query("""
      EXPLAIN SELECT uuid FROM public.phoenix_kit_files
      WHERE latitude IS NOT NULL AND longitude IS NOT NULL
        AND point(longitude, latitude) <@ box(point(14.0, 46.0), point(15.0, 47.0))
      """)
      |> List.flatten()
      |> Enum.join("\n")

    assert plan =~ "phoenix_kit_files_geo_index"
  end

  test "running it again changes nothing" do
    run(V215.up_statements("public"))
    run(V215.up_statements("public"))

    assert length(columns()) == 2
    assert [[_]] = index()
  end

  test "rolls back and forward again" do
    run(V215.down_statements("public"))
    assert columns() == []
    assert index() == []
    assert marker() == "214"

    run(V215.up_statements("public"))
    assert length(columns()) == 2
    assert marker() == "215"
  end
end
