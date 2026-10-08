defmodule PhoenixKit.Migrations.Postgres.V212 do
  @moduledoc """
  V212: a file's shape, as a number the database keeps.

  `phoenix_kit_files.aspect_ratio` is the file's width divided by its height,
  computed by Postgres itself (`GENERATED ALWAYS … STORED`) from the two columns
  it follows. A square photo is `1.0`, a 3:2 landscape `1.5`, a panorama
  `2.0` or more, a tall pin `0.5` or less. It is `NULL` for a file with no
  usable size (a document, a video still being probed).

  It is a number, not a "panorama" flag, on purpose: where wide stops and
  panorama starts is a taste (`PhoenixKit.Modules.Storage.Shape` holds the
  defaults, `wide` from 2:1 and `tall` from 1:2), a flag would bake it into
  every row, and a number follows every later edit that crops or rotates the
  photo without a job to keep it right. Nothing writes it; `width` and `height`
  are already the displayed size, after the EXIF orientation.

  A partial index on `(library_uuid, aspect_ratio)` serves the listing filters,
  one library at a time.

  ## Locks

  Adding a `STORED` generated column **rewrites the table** under an `ACCESS
  EXCLUSIVE` lock, once. `phoenix_kit_files` holds metadata rows, never bytes, so
  that is seconds even for hundreds of thousands of files; no file is touched and
  none is remade. The index is a plain build (the chain's convention, see V193),
  so writes to the table wait while it builds. Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V212 back: the index and the column go; nothing else read it."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. The index name
  # stays bare on CREATE (it is created in its table's schema) and is qualified
  # only on DROP.
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      """
      ALTER TABLE #{p}phoenix_kit_files
      ADD COLUMN IF NOT EXISTS aspect_ratio double precision
      GENERATED ALWAYS AS (
        CASE WHEN width > 0 AND height > 0
          THEN width::double precision / height::double precision
        END
      ) STORED
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_files_library_aspect_ratio_index
      ON #{p}phoenix_kit_files (library_uuid, aspect_ratio)
      WHERE aspect_ratio IS NOT NULL
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '212'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "DROP INDEX IF EXISTS #{p}phoenix_kit_files_library_aspect_ratio_index",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS aspect_ratio",
      "COMMENT ON TABLE #{p}phoenix_kit IS '211'"
    ]
  end
end
