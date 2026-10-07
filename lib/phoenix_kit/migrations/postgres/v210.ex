defmodule PhoenixKit.Migrations.Postgres.V210 do
  @moduledoc """
  V210: a rendition says how it crops.

  A **fixed** image rendition is a box: the photo is scaled to fill it and the
  excess is cropped. Until now the crop was always taken from the center, which
  cuts off a subject standing at the edge of the photo. `crop_mode` lets a
  rendition choose:

    * `center` (the default, and what every existing rendition keeps): crop
      around the middle of the photo;
    * `focus`: crop around the photo's focal point (`Storage.FocalPoint`: where
      its subject is), falling back to the center when none is known.

  A rendition that keeps proportions is not cropped, so the column does nothing
  for it. Only `focus` is part of a rendition's spec hash, so no existing
  rendition is remade by this migration.

  ## Locks

  `ALTER TABLE` on the (tiny) renditions table; the default is a constant, so
  no row is rewritten.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V210 back: the column goes, and every rendition crops at the center again."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions " <>
        "ADD COLUMN IF NOT EXISTS crop_mode character varying(255) DEFAULT 'center' NOT NULL",
      "COMMENT ON TABLE #{p}phoenix_kit IS '210'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions DROP COLUMN IF EXISTS crop_mode",
      "COMMENT ON TABLE #{p}phoenix_kit IS '209'"
    ]
  end
end
