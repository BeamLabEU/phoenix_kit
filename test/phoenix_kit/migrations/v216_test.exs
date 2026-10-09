defmodule PhoenixKit.Migrations.Postgres.V216Test do
  @moduledoc """
  V216's key layout of a storage profile, run as the real SQL: the column and its
  default, that every profile (the Default included) reads 1, and a re-run and a
  round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V216
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp column do
    query("""
    SELECT data_type, column_default, is_nullable FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_profiles'
      AND column_name = 'key_levels'
    """)
  end

  test "the chain is at 216 or later, with a smallint that defaults to 1" do
    assert String.to_integer(marker()) >= 216
    assert [["smallint", "1", "NO"]] = column()
  end

  test "the Default profile, and any other, keep the layout in use (1)" do
    assert [[1]] =
             query(
               "SELECT key_levels FROM public.phoenix_kit_storage_profiles WHERE is_default = true"
             )

    assert [] =
             query("SELECT 1 FROM public.phoenix_kit_storage_profiles WHERE key_levels <> 1")
  end

  test "running it again changes nothing" do
    run(V216.up_statements("public"))
    run(V216.up_statements("public"))

    assert [["smallint", "1", "NO"]] = column()
  end

  test "rolls back and forward again" do
    run(V216.down_statements("public"))
    assert column() == []
    assert marker() == "215"

    run(V216.up_statements("public"))
    assert [["smallint", "1", "NO"]] = column()
    assert marker() == "216"
  end
end
