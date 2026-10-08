defmodule PhoenixKit.Migrations.Postgres.V213 do
  @moduledoc """
  V213: the Default variant set gets smart-square sizes, on installs that have no
  files yet.

  `thumbnail_square` (150 × 150) and `small_square` (300 × 300) are fixed boxes
  cropped around the subject of the photo (`crop_mode = 'focus'`): the squares a
  list row, a picker, an avatar or a tile grid wants, next to `thumbnail` and
  `small`, which keep proportions. They are what `Storage.reset_dimensions_to_defaults/1`
  puts back too.

  **Only an install with no files is changed.** Adding a size to a set makes every
  existing file's variants stale, and an operator who has tuned the Default set
  may not want two more renditions per photo; a site with files gets them by
  pressing "Reset to defaults" on the Default set (or adding them by hand), a
  new site gets them here. A size already in the set (an operator's own
  `thumbnail_square`, say) is left as it is.

  ## Locks

  Two `INSERT … SELECT` into the (tiny) renditions table, guarded by `NOT EXISTS`
  on `phoenix_kit_files` (an index probe). Re-runnable: the unique index on
  `(variant_set_uuid, name)` makes a second run a no-op.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  # The Default variant set (`VariantSets.default_uuid/0`, seeded by V205).
  @default_set "00000000-0000-7000-8000-000000000003"

  # `{name, side, order}`: the same values as `Storage.reset_dimensions_to_defaults/1`.
  @squares [{"thumbnail_square", 150, 9}, {"small_square", 300, 10}]

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V213 back: the two sizes go from the Default set, wherever they were added."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    Enum.map(@squares, fn {name, side, order} ->
      """
      INSERT INTO #{p}phoenix_kit_storage_dimensions
        (name, width, height, quality, format, applies_to, enabled, maintain_aspect_ratio,
         crop_mode, alternative_formats, "order", variant_set_uuid, inserted_at, updated_at)
      SELECT '#{name}', #{side}, #{side}, 85, 'jpg', 'image', true, false,
             'focus', '{}'::text[], #{order}, '#{@default_set}', now(), now()
      WHERE NOT EXISTS (SELECT 1 FROM #{p}phoenix_kit_files)
      ON CONFLICT (variant_set_uuid, name) DO NOTHING
      """
    end) ++ ["COMMENT ON TABLE #{p}phoenix_kit IS '213'"]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)
    names = Enum.map_join(@squares, ", ", fn {name, _side, _order} -> "'#{name}'" end)

    [
      "DELETE FROM #{p}phoenix_kit_storage_dimensions " <>
        "WHERE variant_set_uuid = '#{@default_set}' AND name IN (#{names})",
      "COMMENT ON TABLE #{p}phoenix_kit IS '212'"
    ]
  end
end
