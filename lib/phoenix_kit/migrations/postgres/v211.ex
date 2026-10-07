defmodule PhoenixKit.Migrations.Postgres.V211 do
  @moduledoc """
  V211: an image rendition that keeps proportions can fix its **height** instead
  of its width.

  A rendition that keeps proportions sets one side and lets the other follow
  each photo. Until now that side was always the width, which suits a vertical
  panorama (a 300 px wide column as tall as it needs to be) and not a horizontal
  one, which wants a fixed height and a width as long as it needs. `fit_by` says
  which side is fixed:

    * `width` (the default, and what every existing rendition keeps);
    * `height`: the rendition's `height` is the fixed side and its `width` is
      left empty.

  A rendition that is a fixed box has both sides set and ignores the column.
  Only `height` is part of a rendition's spec hash, so no existing rendition is
  remade by this migration.

  ## Locks

  `ALTER TABLE` on the (tiny) renditions table; the default is a constant, so no
  row is rewritten.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V211 back: the column goes, and every rendition fixes its width again."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions " <>
        "ADD COLUMN IF NOT EXISTS fit_by character varying(255) DEFAULT 'width' NOT NULL",
      "COMMENT ON TABLE #{p}phoenix_kit IS '211'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions DROP COLUMN IF EXISTS fit_by",
      "COMMENT ON TABLE #{p}phoenix_kit IS '210'"
    ]
  end
end
