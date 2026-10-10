defmodule PhoenixKit.Migrations.Postgres.V210Test do
  @moduledoc """
  V210's rendition crop mode, run as the real SQL: the column and its default, that
  an existing rendition keeps cropping at the center, that a re-run is harmless,
  and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V210
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
      AND column_name = 'crop_mode'
    """)
  end

  # V217 moved the setting into `options` and emptied the column (nullable, no
  # default); V210's own statements are still tested below.
  test "the chain is at 210 or later; since V217 the column is nullable, with no default" do
    assert String.to_integer(marker()) >= 210
    assert [["character varying", nil, "YES"]] = column()
  end

  test "an existing rendition still crops at the center, now recorded in options" do
    assert [["thumbnail", "center", nil]] =
             query("""
             SELECT name, options->>'crop_mode', crop_mode FROM public.phoenix_kit_storage_dimensions
             WHERE name = 'thumbnail' AND variant_set_uuid = '00000000-0000-7000-8000-000000000003'
             """)
  end

  test "a rendition written without it has no column value: the code defaults to the center" do
    [[mode]] =
      query(
        """
        INSERT INTO public.phoenix_kit_storage_dimensions
          (name, width, applies_to, enabled, \"order\", inserted_at, updated_at)
        VALUES ($1, 100, 'image', true, 99, now(), now()) RETURNING crop_mode
        """,
        ["v210_#{System.unique_integer([:positive])}"]
      )

    assert mode == nil
  end

  test "running it again changes nothing" do
    run(V210.up_statements("public"))
    run(V210.up_statements("public"))

    assert [["character varying", nil, "YES"]] = column()
    assert String.to_integer(marker()) >= 210
  end

  test "rolls back and forward again" do
    run(V210.down_statements("public"))
    assert column() == []
    assert marker() == "209"

    run(V210.up_statements("public"))
    assert [["character varying", _default, "NO"]] = column()
    assert marker() == "210"
  end
end
