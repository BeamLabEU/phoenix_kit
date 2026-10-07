defmodule PhoenixKit.Migrations.Postgres.V211Test do
  @moduledoc """
  V211's rendition fit side, run as the real SQL: the column and its default, that an
  existing rendition keeps fixing its width, that a re-run is harmless, and a round
  trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V211
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
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_dimensions'
      AND column_name = 'fit_by'
    """)
  end

  test "the chain is at 211 or later, with the column, its default and NOT NULL" do
    assert String.to_integer(marker()) >= 211
    assert [["character varying", default, "NO"]] = column()
    assert default =~ "width"
  end

  test "an existing rendition keeps fixing its width" do
    assert [["medium", "width"]] =
             query("""
             SELECT name, fit_by FROM public.phoenix_kit_storage_dimensions
             WHERE name = 'medium' AND variant_set_uuid = '00000000-0000-7000-8000-000000000003'
             """)
  end

  test "running it again changes nothing" do
    run(V211.up_statements("public"))
    run(V211.up_statements("public"))

    assert [["character varying", _default, "NO"]] = column()
  end

  test "rolls back and forward again" do
    run(V211.down_statements("public"))
    assert column() == []
    assert marker() == "210"

    run(V211.up_statements("public"))
    assert [["character varying", _default, "NO"]] = column()
    assert marker() == "211"
  end
end
