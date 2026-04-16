defmodule PhoenixKit.Migrations.Postgres.V99 do
  @moduledoc """
  V99: Add trash support to storage files.

  Adds a `trashed_at` timestamp column to `phoenix_kit_files` for soft-delete.
  Files with status "trashed" and a `trashed_at` value are in the trash bucket
  and can be restored or permanently deleted after a configurable retention period.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_files'
          AND column_name = 'trashed_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_files
          ADD COLUMN trashed_at TIMESTAMPTZ;
      END IF;
    END $$;
    """)

    create_if_not_exists(
      index(:phoenix_kit_files, [:trashed_at],
        prefix: prefix,
        where: "trashed_at IS NOT NULL",
        name: :phoenix_kit_files_trashed_at_index
      )
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '99'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(
      index(:phoenix_kit_files, [:trashed_at],
        prefix: prefix,
        name: :phoenix_kit_files_trashed_at_index
      )
    )

    execute("ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS trashed_at")
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '98'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
