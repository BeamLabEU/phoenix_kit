defmodule PhoenixKit.Migrations.Postgres.V237 do
  @moduledoc """
  V237: a watermark on a variant set (`PhoenixKit.Modules.Storage.Watermark`).

  **`phoenix_kit_variant_sets.watermark`** (jsonb, nullable) — what the set
  stamps on the renditions it names: a strip along the bottom or a mark in a
  corner, with text and/or a logo (a stored file's uuid), and the names of the
  sizes that get it. NULL (every existing set) is no watermark. The original
  file is never watermarked.

  ## Locks

  One nullable column with no default: a catalog-only change. Re-runnable.

  ## Down

  Drops the column.
  """
  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    Helpers.validate_prefix!(prefix)
    Enum.each(up_statements(prefix), &execute/1)
  end

  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_variant_sets ADD COLUMN IF NOT EXISTS watermark jsonb",
      "COMMENT ON TABLE #{p}phoenix_kit IS '237'",
      "RESET lock_timeout"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_variant_sets DROP COLUMN IF EXISTS watermark",
      "COMMENT ON TABLE #{p}phoenix_kit IS '236'",
      "RESET lock_timeout"
    ]
  end
end
