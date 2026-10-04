defmodule PhoenixKit.Migrations.Postgres.V208Test do
  @moduledoc """
  V208's bucket log table, run as the real SQL: the shape, the checks, no
  foreign keys, and a re-run and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V208
  alias PhoenixKit.Test.Repo

  @bucket "01a0f33e-0000-7000-8000-00000000eeee"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp insert_entry(kind \\ "write", count \\ 1) do
    query(
      """
      INSERT INTO public.phoenix_kit_bucket_log (bucket_uuid, kind, ok, count)
      VALUES ($1::text::uuid, $2, false, $3)
      RETURNING uuid::text
      """,
      [@bucket, kind, count]
    )
  end

  defp violation?(fun, code) do
    fun.()
    false
  rescue
    error in Postgrex.Error -> error.postgres.code == code
  end

  test "the chain is at 208 or later, with the table and its columns" do
    assert String.to_integer(marker()) >= 208

    columns =
      query("""
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_bucket_log'
      """)
      |> List.flatten()

    for column <- ~w(uuid bucket_uuid kind ok latency_ms message count inserted_at last_at) do
      assert column in columns, column
    end
  end

  test "a new entry is one occurrence, stamped now" do
    [[uuid]] = insert_entry()

    assert [[1, true]] =
             query(
               """
               SELECT count, last_at >= now() - interval '1 minute'
               FROM public.phoenix_kit_bucket_log WHERE uuid = $1::text::uuid
               """,
               [uuid]
             )
  end

  describe "the checks" do
    test "every kind the log knows is accepted" do
      for kind <- V208.kinds(), do: assert([[_]] = insert_entry(kind))
    end

    test "a kind that is not one of the four is refused" do
      assert violation?(fn -> insert_entry("copy") end, :check_violation)
    end

    test "an entry stands for at least one occurrence" do
      assert violation?(fn -> insert_entry("write", 0) end, :check_violation)
    end
  end

  test "an entry outlives its bucket: there are no foreign keys" do
    assert [] ==
             query("""
             SELECT conname FROM pg_constraint c
             JOIN pg_class t ON t.oid = c.conrelid
             JOIN pg_namespace n ON n.oid = t.relnamespace
             WHERE t.relname = 'phoenix_kit_bucket_log' AND n.nspname = 'public' AND c.contype = 'f'
             """)

    assert [[_]] = insert_entry()
  end

  test "a re-run changes nothing" do
    [[uuid]] = insert_entry()

    run(V208.up_statements("public"))

    assert [[^uuid]] =
             query(
               "SELECT uuid::text FROM public.phoenix_kit_bucket_log WHERE uuid = $1::text::uuid",
               [uuid]
             )

    assert String.to_integer(marker()) >= 208
  end

  test "a round trip removes the table and puts it back empty" do
    insert_entry()

    run(V208.down_statements("public"))

    assert [[nil]] = query("SELECT to_regclass('public.phoenix_kit_bucket_log')::text")
    assert marker() == "207"

    run(V208.up_statements("public"))

    assert [[0]] = query("SELECT count(*)::int FROM public.phoenix_kit_bucket_log")
    assert marker() == "208"
  end
end
