defmodule PhoenixKit.Migrations.Postgres.V215 do
  @moduledoc """
  V215: where a photo was taken, in two columns a map can ask about.

  `phoenix_kit_files.latitude` and `longitude` are the GPS position the photo's
  EXIF records, in decimal degrees (WGS 84: latitude -90..90, longitude
  -180..180), `NULL` for a file with none. They are columns, not part of the
  file's `metadata`, because a map asks "what is in this area?" and answers
  with an index.

  The index is a **GiST index on `point(longitude, latitude)`**, built into
  Postgres (no PostGIS, no extension to install, nothing to do with a named
  schema): a box on the map is one indexed lookup,

      WHERE point(longitude, latitude) <@ box(point(west, south), point(east, north))

  (`PhoenixKit.Modules.Storage.Geo` builds it, and splits a box that crosses the
  antimeridian in two). It is partial, over files that have a position, so a
  library of photos without GPS pays nothing for it.

  The rest of the EXIF a photo carries (camera, lens, exposure, dates, altitude,
  speed, direction) is kept in `metadata["exif"]`; the position is both there
  and here, this being the copy that is indexed. No existing file is changed by
  this migration: the position of a photo already uploaded is read by
  `Storage.read_exif/1`.

  ## Locks

  `ADD COLUMN` of two nullable columns (no default, no rewrite) and a plain
  index build (the chain's convention, see V193), so writes to
  `phoenix_kit_files` wait while it builds; the index is partial, so it holds
  only the files with a position, and none yet. Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V215 back: the index and the two columns go."
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
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS latitude double precision",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS longitude double precision",
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_files_geo_index
      ON #{p}phoenix_kit_files USING gist (point(longitude, latitude))
      WHERE latitude IS NOT NULL AND longitude IS NOT NULL
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '215'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "DROP INDEX IF EXISTS #{p}phoenix_kit_files_geo_index",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS longitude",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS latitude",
      "COMMENT ON TABLE #{p}phoenix_kit IS '214'"
    ]
  end
end
