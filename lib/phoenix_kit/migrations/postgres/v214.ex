defmodule PhoenixKit.Migrations.Postgres.V214 do
  @moduledoc """
  V214: a rendition can be for wide or tall pictures only, and the Default set
  gets a mini square and three panorama sizes.

  `phoenix_kit_storage_dimensions.shape` says which pictures a rendition is made
  for:

    * `any` (the default, and what every existing rendition keeps): every picture;
    * `wide`: only a picture whose `aspect_ratio` is `Storage.Shape.wide_min/0` or
      more (a panorama), so an ordinary photo is not given a second, near-identical
      file;
    * `tall`: the same for a picture `Storage.Shape.tall_max/0` or less.

  The shape is not part of a rendition's spec hash (it does not change a pixel),
  so no existing rendition is remade by this migration.

  **The new sizes reach installs that have no files yet** (as in V213): a site with
  files gets them from "Reset to defaults", because adding a size makes every
  existing file stale. They are in the Default set:

    * `mini_square`: 64 × 64, quality 70, cropped around the subject. For the
      zoomed-out views (a month, a year) where a cell is a few dozen pixels;
    * `thumbnail_wide`, `small_wide`, `medium_wide`: 150, 300 and 800 px **tall**
      and as wide as the picture needs, for panoramas only.

  A size already in the set under that name (an operator's own) is left as it is.

  ## Locks

  `ALTER TABLE` on the (tiny) renditions table; the default is a constant, so no
  row is rewritten. Four `INSERT … SELECT` guarded by `NOT EXISTS` on
  `phoenix_kit_files`. Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  # The Default variant set (`VariantSets.default_uuid/0`, seeded by V205).
  @default_set "00000000-0000-7000-8000-000000000003"

  # `{name, width, height, quality, maintain_aspect_ratio, crop_mode, fit_by, shape, order}`:
  # the same values as `Storage.reset_dimensions_to_defaults/1`.
  @sizes [
    {"mini_square", "64", "64", 70, false, "focus", "width", "any", 11},
    {"thumbnail_wide", "NULL", "150", 85, true, "center", "height", "wide", 12},
    {"small_wide", "NULL", "300", 85, true, "center", "height", "wide", 13},
    {"medium_wide", "NULL", "800", 85, true, "center", "height", "wide", 14}
  ]

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V214 back: the four sizes and the column go."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions " <>
        "ADD COLUMN IF NOT EXISTS shape character varying(255) DEFAULT 'any' NOT NULL"
    ] ++
      Enum.map(@sizes, fn {name, width, height, quality, keeps?, crop, fit_by, shape, order} ->
        """
        INSERT INTO #{p}phoenix_kit_storage_dimensions
          (name, width, height, quality, format, applies_to, enabled, maintain_aspect_ratio,
           crop_mode, fit_by, shape, alternative_formats, "order", variant_set_uuid,
           inserted_at, updated_at)
        SELECT '#{name}', #{width}, #{height}, #{quality}, 'jpg', 'image', true, #{keeps?},
               '#{crop}', '#{fit_by}', '#{shape}', '{}'::text[], #{order}, '#{@default_set}',
               now(), now()
        WHERE NOT EXISTS (SELECT 1 FROM #{p}phoenix_kit_files)
        ON CONFLICT (variant_set_uuid, name) DO NOTHING
        """
      end) ++ ["COMMENT ON TABLE #{p}phoenix_kit IS '214'"]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)
    names = Enum.map_join(@sizes, ", ", fn size -> "'#{elem(size, 0)}'" end)

    [
      "DELETE FROM #{p}phoenix_kit_storage_dimensions " <>
        "WHERE variant_set_uuid = '#{@default_set}' AND name IN (#{names})",
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions DROP COLUMN IF EXISTS shape",
      "COMMENT ON TABLE #{p}phoenix_kit IS '213'"
    ]
  end
end
