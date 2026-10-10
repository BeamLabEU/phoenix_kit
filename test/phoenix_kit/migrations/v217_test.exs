defmodule PhoenixKit.Migrations.Postgres.V217Test do
  @moduledoc """
  V217's rendition options, run as the real SQL: the `options` column, that the three
  settings that were columns were copied into it and emptied, that HDR is on for the
  standard `medium` and `large` only, and a re-run and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V217
  alias PhoenixKit.Test.Repo

  @default_set "00000000-0000-7000-8000-000000000003"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp column(name) do
    query(
      """
      SELECT data_type, column_default, is_nullable FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_dimensions'
        AND column_name = $1
      """,
      [name]
    )
  end

  defp options do
    query(
      "SELECT name, options FROM public.phoenix_kit_storage_dimensions " <>
        "WHERE variant_set_uuid = '#{@default_set}'"
    )
    |> Map.new(fn [name, options] -> {name, options} end)
  end

  test "the chain is at 217 or later, with a jsonb options object that defaults to {}" do
    assert String.to_integer(marker()) >= 217
    assert [["jsonb", default, "NO"]] = column("options")
    assert default =~ "{}"
  end

  test "crop mode, fixed side and shape were copied into options, and the columns emptied" do
    options = options()

    assert options["thumbnail_square"]["crop_mode"] == "focus"
    assert options["thumbnail_wide"]["fit_by"] == "height"
    assert options["thumbnail_wide"]["shape"] == "wide"
    assert options["large"]["crop_mode"] == "center"
    assert options["large"]["shape"] == "any"

    for name <- ~w(crop_mode fit_by shape) do
      assert [["character varying", nil, "YES"]] = column(name), "#{name} is nullable, no default"
    end

    assert [] =
             query("""
             SELECT 1 FROM public.phoenix_kit_storage_dimensions
             WHERE crop_mode IS NOT NULL OR fit_by IS NOT NULL OR shape IS NOT NULL
             """)
  end

  test "the standard medium and large keep HDR; every other size does not" do
    options = options()

    assert options["medium"]["keep_hdr"] == true
    assert options["large"]["keep_hdr"] == true

    for {name, o} <- Map.drop(options, ["medium", "large"]) do
      refute o["keep_hdr"], "#{name} does not"
    end
  end

  test "a size that is not a plain width-fit one is not given HDR" do
    query("UPDATE public.phoenix_kit_storage_dimensions SET options = '{}'")

    query("""
    UPDATE public.phoenix_kit_storage_dimensions SET options = '{"crop_mode": "focus"}'
    WHERE name = 'medium' AND variant_set_uuid = '#{@default_set}'
    """)

    run(V217.up_statements("public"))
    options = options()

    assert options["large"]["keep_hdr"] == true
    refute options["medium"]["keep_hdr"], "a size cropped around the subject cannot carry a map"
  end

  test "running it again changes nothing" do
    before = options()
    run(V217.up_statements("public"))
    run(V217.up_statements("public"))

    assert options() == before
    assert [["jsonb", _, "NO"]] = column("options")
  end

  test "rolls back (the columns get their values and rules back) and forward again" do
    before = options()
    run(V217.down_statements("public"))

    assert column("options") == []
    assert marker() == "216"
    assert [["character varying", default, "NO"]] = column("crop_mode")
    assert default =~ "center"

    assert [["thumbnail_square", "focus"]] =
             query("""
             SELECT name, crop_mode FROM public.phoenix_kit_storage_dimensions
             WHERE name = 'thumbnail_square' AND variant_set_uuid = '#{@default_set}'
             """)

    assert [["thumbnail_wide", "height", "wide"]] =
             query("""
             SELECT name, fit_by, shape FROM public.phoenix_kit_storage_dimensions
             WHERE name = 'thumbnail_wide' AND variant_set_uuid = '#{@default_set}'
             """)

    run(V217.up_statements("public"))
    assert marker() == "217"
    assert options()["thumbnail_square"]["crop_mode"] == "focus"
    assert options()["thumbnail_wide"]["shape"] == "wide"
    # HDR is not a column in the old shape, so a round trip sets it again as it was.
    assert options()["large"]["keep_hdr"] == before["large"]["keep_hdr"]
  end
end
