defmodule PhoenixKit.Migrations.Postgres.V157 do
  @moduledoc """
  V157: Widen `phoenix_kit_annotations_kind_check` for the new
  `"image"` kind.

  PR #660 exposed Etcher 0.9's `:image` tool in the media viewer's
  toolbar (`media_canvas_viewer.html.heex`) without widening the CHECK
  constraint (or the schema's `@kinds`) to match — the same regression
  V130's moduledoc warns about for `"marker"`. Without this, inserting
  an image annotation is rejected by the DB and silently fails to
  persist across a reload.

  Idempotent: each `ADD CONSTRAINT` is preceded by `DROP CONSTRAINT
  IF EXISTS` on the same prefixed table.
  """

  use Ecto.Migration

  # The DROP IF EXISTS immediately before each ADD makes the re-add
  # unconditional and safe. A `pg_constraint` existence guard would be
  # wrong here: `conname` is unique per namespace, not globally, so on a
  # multi-prefix install it would match another prefix's identically
  # named constraint and skip the add — leaving this prefix's table with
  # no kind check at all.
  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_annotations
      ADD CONSTRAINT phoenix_kit_annotations_kind_check
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line', 'marker', 'image'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '157'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_annotations
      ADD CONSTRAINT phoenix_kit_annotations_kind_check
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line', 'marker'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '156'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
