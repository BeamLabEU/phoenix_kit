defmodule PhoenixKit.Migrations.Postgres.V216 do
  @moduledoc """
  V216: how deep a storage profile's keys are fanned out.

  `phoenix_kit_storage_profiles.key_levels` (smallint, `NOT NULL`, default `1`)
  is the number of two-character hash folders between a library's key prefix and
  a file's own folder:

      0   <prefix>/<md5>/…
      1   <prefix>/22/<md5>/…           (every key so far)
      2   <prefix>/22/e8/<md5>/…
      3   <prefix>/22/e8/b9/<md5>/…

  A deeper layout keeps any one directory short in a library of many millions of
  files on a local disk (`PhoenixKit.Modules.Storage.KeyLayout` has the numbers
  the Storage profiles tab shows). It applies to **new uploads** into the
  profile's libraries: a file's folder is stored on its row, so every file
  already uploaded stays where it is and is found as before.

  Every existing profile gets `1`, which is the layout in use. The column is not
  part of the profile's placement, so changing it does not bump the profile's
  `revision` and no file becomes out of date.

  ## Locks

  `ADD COLUMN … NOT NULL DEFAULT 1`: a constant default, so Postgres adds it
  without rewriting `phoenix_kit_storage_profiles` (a handful of rows in any
  case). Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V216 back: the column goes."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test.
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_profiles ADD COLUMN IF NOT EXISTS key_levels smallint NOT NULL DEFAULT 1",
      "COMMENT ON TABLE #{p}phoenix_kit IS '216'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_profiles DROP COLUMN IF EXISTS key_levels",
      "COMMENT ON TABLE #{p}phoenix_kit IS '215'"
    ]
  end
end
