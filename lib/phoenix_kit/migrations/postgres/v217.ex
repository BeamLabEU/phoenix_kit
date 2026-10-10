defmodule PhoenixKit.Migrations.Postgres.V217 do
  @moduledoc """
  V217: the options of a rendition, in one JSON object.

  A rendition (`phoenix_kit_storage_dimensions`) had a column for each setting that
  came later: `crop_mode` (V210), `fit_by` (V211), `shape` (V214), and every new one
  would have meant another migration. V217 adds **`options`** (`jsonb`, `NOT NULL`,
  default `{}`), loaded as `PhoenixKit.Modules.Storage.DimensionOptions`, so a new
  option is a field in that struct and nothing else.

  What the migration does:

    * adds `options`;
    * **copies** `crop_mode`, `fit_by` and `shape` into it;
    * sets `keep_hdr` (a photo's HDR gain map is kept in this size,
      `Storage.HdrResize`) for the standard `medium` and `large` of every set, which
      is what they did before it was a setting, and for no other size;
    * **empties** the three columns (they become nullable and lose their default, so
      nothing writes them again). Nothing reads them from this release on; they are
      kept, empty, for a few releases so the change can be backed out, and dropped by
      a later migration.

  No rendition is remade: the options do not change what a size looks like (they are
  not part of its spec hash).

  The copy and the emptying run only on rows that still hold their old values, so
  running V217 again changes nothing.

  ## Locks

  `ADD COLUMN … NOT NULL DEFAULT '{}'` with a constant default (no rewrite), then
  updates of a few dozen rows and `DROP NOT NULL` / `DROP DEFAULT` on the three columns
  (catalog changes only). Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @moved ~w(crop_mode fit_by shape)

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V217 back: the three columns get their values and rules back, `options` goes."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)
    t = "#{p}phoenix_kit_storage_dimensions"

    [
      "ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS options jsonb DEFAULT '{}'::jsonb NOT NULL",
      # Copy, only from a row that still holds its old values.
      """
      UPDATE #{t}
      SET options = options || jsonb_strip_nulls(
        jsonb_build_object('crop_mode', crop_mode, 'fit_by', fit_by, 'shape', shape))
      WHERE crop_mode IS NOT NULL OR fit_by IS NOT NULL OR shape IS NOT NULL
      """,
      # The standard sizes the viewer shows kept the map before it was a setting.
      """
      UPDATE #{t} SET options = options || '{"keep_hdr": true}'::jsonb
      WHERE name IN ('medium', 'large') AND maintain_aspect_ratio = true
        AND COALESCE(options->>'fit_by', 'width') = 'width'
        AND COALESCE(options->>'crop_mode', 'center') = 'center'
        AND NOT (options ? 'keep_hdr')
      """
    ] ++
      Enum.map(@moved, fn column ->
        "ALTER TABLE #{t} ALTER COLUMN #{column} DROP NOT NULL, ALTER COLUMN #{column} DROP DEFAULT"
      end) ++
      [
        "UPDATE #{t} SET crop_mode = NULL, fit_by = NULL, shape = NULL " <>
          "WHERE crop_mode IS NOT NULL OR fit_by IS NOT NULL OR shape IS NOT NULL",
        "COMMENT ON TABLE #{p}phoenix_kit IS '217'"
      ]
  end

  @defaults %{"crop_mode" => "center", "fit_by" => "width", "shape" => "any"}

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)
    t = "#{p}phoenix_kit_storage_dimensions"

    assignments =
      Enum.map_join(@moved, ", ", fn column ->
        "#{column} = COALESCE(options->>'#{column}', '#{@defaults[column]}')"
      end)

    [
      "UPDATE #{t} SET #{assignments} WHERE crop_mode IS NULL OR fit_by IS NULL OR shape IS NULL"
    ] ++
      Enum.map(@moved, fn column ->
        "ALTER TABLE #{t} ALTER COLUMN #{column} SET DEFAULT '#{@defaults[column]}', " <>
          "ALTER COLUMN #{column} SET NOT NULL"
      end) ++
      [
        "ALTER TABLE #{t} DROP COLUMN IF EXISTS options",
        "COMMENT ON TABLE #{p}phoenix_kit IS '216'"
      ]
  end
end
