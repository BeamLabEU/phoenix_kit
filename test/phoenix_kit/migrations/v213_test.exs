defmodule PhoenixKit.Migrations.Postgres.V213Test do
  @moduledoc """
  V213's smart-square sizes, run as the real SQL: that a site with no files gets
  them in the Default set, that a site with files does not, that an operator's own
  size of the same name is left alone, and a re-run and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V213
  alias PhoenixKit.Test.Repo

  @default_set "00000000-0000-7000-8000-000000000003"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp squares do
    query(
      """
      SELECT name, width, height, maintain_aspect_ratio, crop_mode, format, "order"
      FROM public.phoenix_kit_storage_dimensions
      WHERE variant_set_uuid = $1 AND name LIKE '%\\_square' ORDER BY "order"
      """,
      [Ecto.UUID.dump!(@default_set)]
    )
  end

  defp remove_squares do
    query(
      "DELETE FROM public.phoenix_kit_storage_dimensions WHERE variant_set_uuid = $1 AND name LIKE '%\\_square'",
      [Ecto.UUID.dump!(@default_set)]
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
      ["v213-#{n}.jpg", "v213#{n}"]
    )
  end

  test "the chain is at 213 or later" do
    assert String.to_integer(marker()) >= 213
  end

  test "a site with no files gets both squares in the Default set" do
    remove_squares()
    run(V213.up_statements("public"))

    assert [
             ["thumbnail_square", 150, 150, false, "focus", "jpg", 9],
             ["small_square", 300, 300, false, "focus", "jpg", 10]
           ] = squares()
  end

  test "a site with files is left alone" do
    remove_squares()
    insert_file()
    run(V213.up_statements("public"))

    assert squares() == []
  end

  test "an operator's own size of the same name is kept as it is" do
    remove_squares()

    query(
      """
      INSERT INTO public.phoenix_kit_storage_dimensions
        (name, width, height, quality, applies_to, enabled, maintain_aspect_ratio, crop_mode,
         "order", variant_set_uuid, inserted_at, updated_at)
      VALUES ('thumbnail_square', 400, 400, 85, 'image', true, false, 'focus', 0, $1, now(), now())
      """,
      [Ecto.UUID.dump!(@default_set)]
    )

    run(V213.up_statements("public"))

    assert [["thumbnail_square", 400, 400, _, "focus", _, 0], ["small_square", 300, 300 | _]] =
             squares()
  end

  test "running it again changes nothing" do
    remove_squares()
    run(V213.up_statements("public"))
    run(V213.up_statements("public"))

    assert length(squares()) == 2
  end

  test "rolls back and forward again" do
    remove_squares()
    run(V213.up_statements("public"))
    run(V213.down_statements("public"))
    assert squares() == []
    assert marker() == "212"

    run(V213.up_statements("public"))
    assert length(squares()) == 2
    assert marker() == "213"
  end
end
