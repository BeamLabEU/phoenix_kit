defmodule PhoenixKit.Migrations.Postgres.V214Test do
  @moduledoc """
  V214's rendition shape and new Default sizes, run as the real SQL: the column and
  its default, that an existing rendition is made for every picture, that a site with
  no files gets the four sizes (and one with files does not), that an operator's own
  size of the same name is kept, and a re-run and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V214
  alias PhoenixKit.Test.Repo

  @default_set "00000000-0000-7000-8000-000000000003"
  @new ~w(mini_square thumbnail_wide small_wide medium_wide)

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows
  defp set_uuid, do: Ecto.UUID.dump!(@default_set)

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp column do
    query("""
    SELECT data_type, column_default, is_nullable FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_dimensions'
      AND column_name = 'shape'
    """)
  end

  defp sizes do
    query(
      """
      SELECT name, width, height, quality, maintain_aspect_ratio, crop_mode, fit_by, shape, "order"
      FROM public.phoenix_kit_storage_dimensions
      WHERE variant_set_uuid = $1 AND name = ANY($2) ORDER BY "order"
      """,
      [set_uuid(), @new]
    )
  end

  defp remove_sizes do
    query(
      "DELETE FROM public.phoenix_kit_storage_dimensions WHERE variant_set_uuid = $1 AND name = ANY($2)",
      [set_uuid(), @new]
    )
  end

  defp insert_file do
    n = System.unique_integer([:positive])

    query(
      """
      INSERT INTO public.phoenix_kit_files
        (original_file_name, file_name, mime_type, file_type, ext, file_checksum,
         user_file_checksum, size, status, file_path, inserted_at, updated_at)
      VALUES ($1, $1, 'image/jpeg', 'image', 'jpg', $2, $2, 1, 'active', $1, now(), now())
      """,
      ["v214-#{n}.jpg", "v214#{n}"]
    )
  end

  test "the chain is at 214 or later, with the column, its default and NOT NULL" do
    assert String.to_integer(marker()) >= 214
    assert [["character varying", default, "NO"]] = column()
    assert default =~ "any"
  end

  test "an existing rendition is made for every picture" do
    assert [["medium", "any"]] =
             query(
               """
               SELECT name, shape FROM public.phoenix_kit_storage_dimensions
               WHERE name = 'medium' AND variant_set_uuid = $1
               """,
               [set_uuid()]
             )
  end

  test "a site with no files gets the mini square and the three panorama sizes" do
    remove_sizes()
    run(V214.up_statements("public"))

    assert [
             ["mini_square", 64, 64, 70, false, "focus", "width", "any", 11],
             ["thumbnail_wide", nil, 150, 85, true, "center", "height", "wide", 12],
             ["small_wide", nil, 300, 85, true, "center", "height", "wide", 13],
             ["medium_wide", nil, 800, 85, true, "center", "height", "wide", 14]
           ] = sizes()
  end

  test "a site with files is left alone" do
    remove_sizes()
    insert_file()
    run(V214.up_statements("public"))

    assert sizes() == []
  end

  test "an operator's own size of the same name is kept as it is" do
    remove_sizes()

    query(
      """
      INSERT INTO public.phoenix_kit_storage_dimensions
        (name, width, height, quality, applies_to, enabled, maintain_aspect_ratio, crop_mode,
         "order", variant_set_uuid, inserted_at, updated_at)
      VALUES ('mini_square', 48, 48, 60, 'image', true, false, 'center', 0, $1, now(), now())
      """,
      [set_uuid()]
    )

    run(V214.up_statements("public"))

    assert [["mini_square", 48, 48, 60, false, "center", "width", "any", 0] | rest] = sizes()
    assert length(rest) == 3
  end

  test "running it again changes nothing" do
    remove_sizes()
    run(V214.up_statements("public"))
    run(V214.up_statements("public"))

    assert [["character varying", _default, "NO"]] = column()
    assert length(sizes()) == 4
  end

  test "rolls back and forward again" do
    run(V214.down_statements("public"))
    assert column() == []
    assert marker() == "213"

    run(V214.up_statements("public"))
    assert [["character varying", _default, "NO"]] = column()
    assert marker() == "214"
  end
end
