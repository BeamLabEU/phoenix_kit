defmodule PhoenixKit.Migrations.Postgres.V73 do
  @moduledoc """
  V73: Pre-drop prerequisites for Category B tables.

  Prepares Category B tables for the eventual `DROP COLUMN id` (V74) by:

  1. **SET NOT NULL** on 7 uuid columns that currently allow NULLs
  2. **CREATE UNIQUE INDEX** on 3 tables missing unique indexes on `uuid`
  3. **ALTER INDEX RENAME** on 4 indexes to match renamed columns

  All operations are idempotent — safe to re-run.
  """

  use Ecto.Migration

  # Tables whose `uuid` column must become NOT NULL
  @set_not_null_tables ~w(
    phoenix_kit_ai_endpoints
    phoenix_kit_ai_prompts
    phoenix_kit_consent_logs
    phoenix_kit_payment_methods
    phoenix_kit_role_permissions
    phoenix_kit_subscription_types
    phoenix_kit_sync_connections
  )

  # Tables needing a unique index on `uuid`
  @create_unique_index_tables ~w(
    phoenix_kit_consent_logs
    phoenix_kit_payment_methods
    phoenix_kit_subscription_types
  )

  # {table, old_index_name, new_index_name}
  @index_renames [
    {"phoenix_kit_post_tag_assignments", "phoenix_kit_post_tag_assignments_post_id_tag_id_index",
     "phoenix_kit_post_tag_assignments_post_uuid_tag_uuid_index"},
    {"phoenix_kit_post_group_assignments",
     "phoenix_kit_post_group_assignments_post_id_group_id_index",
     "phoenix_kit_post_group_assignments_post_uuid_group_uuid_index"},
    {"phoenix_kit_post_media", "phoenix_kit_post_media_post_id_position_index",
     "phoenix_kit_post_media_post_uuid_position_index"},
    {"phoenix_kit_file_instances", "phoenix_kit_file_instances_file_id_variant_name_index",
     "phoenix_kit_file_instances_file_uuid_variant_name_index"}
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    # 1. SET NOT NULL on uuid columns
    for table <- @set_not_null_tables do
      set_not_null_if_needed(table, "uuid", prefix, escaped_prefix)
    end

    # 2. CREATE UNIQUE INDEX on uuid columns (CONCURRENTLY not available inside transaction)
    for table <- @create_unique_index_tables do
      create_unique_index_if_needed(table, "uuid", prefix, escaped_prefix)
    end

    # 3. ALTER INDEX ... RENAME
    for {table, old_name, new_name} <- @index_renames do
      rename_index_if_needed(table, old_name, new_name, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '73'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # 3. Reverse index renames
    for {table, old_name, new_name} <- @index_renames do
      rename_index_if_needed(table, new_name, old_name, prefix, escaped_prefix)
    end

    # 2. Drop unique indexes we created
    for table <- @create_unique_index_tables do
      idx_name = "#{table}_uuid_unique_index"
      drop_index_if_exists(idx_name, prefix, escaped_prefix)
    end

    # 1. Remove NOT NULL (make nullable again)
    for table <- @set_not_null_tables do
      drop_not_null_if_needed(table, "uuid", prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '72'")
  end

  # ---------------------------------------------------------------------------
  # SET NOT NULL
  # ---------------------------------------------------------------------------

  defp set_not_null_if_needed(table, column, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) and column_exists?(table, column, escaped_prefix) do
      table_name = prefix_table(table, prefix)

      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = '#{table}'
          AND table_schema = '#{escaped_prefix}'
          AND column_name = '#{column}'
          AND is_nullable = 'YES'
        ) THEN
          ALTER TABLE #{table_name} ALTER COLUMN #{column} SET NOT NULL;
        END IF;
      END $$;
      """)
    end
  end

  defp drop_not_null_if_needed(table, column, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) and column_exists?(table, column, escaped_prefix) do
      table_name = prefix_table(table, prefix)

      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = '#{table}'
          AND table_schema = '#{escaped_prefix}'
          AND column_name = '#{column}'
          AND is_nullable = 'NO'
        ) THEN
          ALTER TABLE #{table_name} ALTER COLUMN #{column} DROP NOT NULL;
        END IF;
      END $$;
      """)
    end
  end

  # ---------------------------------------------------------------------------
  # UNIQUE INDEX
  # ---------------------------------------------------------------------------

  defp create_unique_index_if_needed(table, column, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) and column_exists?(table, column, escaped_prefix) do
      table_name = prefix_table(table, prefix)
      idx_name = "#{table}_uuid_unique_index"

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE tablename = '#{table}'
          AND schemaname = '#{escaped_prefix}'
          AND indexname = '#{idx_name}'
        ) THEN
          CREATE UNIQUE INDEX #{idx_name} ON #{table_name} (#{column});
        END IF;
      END $$;
      """)
    end
  end

  defp drop_index_if_exists(idx_name, prefix, _escaped_prefix) do
    schema = prefix || "public"

    execute("""
    DROP INDEX IF EXISTS #{schema}.#{idx_name};
    """)
  end

  # ---------------------------------------------------------------------------
  # INDEX RENAME
  # ---------------------------------------------------------------------------

  defp rename_index_if_needed(table, old_name, new_name, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) do
      schema = prefix || "public"

      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE schemaname = '#{schema}'
          AND indexname = '#{old_name}'
        ) THEN
          ALTER INDEX #{schema}.#{old_name} RENAME TO #{new_name};
        END IF;
      END $$;
      """)
    end
  end

  # ---------------------------------------------------------------------------
  # Introspection Helpers
  # ---------------------------------------------------------------------------

  defp table_exists?(table, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table}'
             AND column_name = '#{column}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
