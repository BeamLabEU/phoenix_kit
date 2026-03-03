defmodule PhoenixKit.Migrations.Postgres.V72 do
  @moduledoc """
  V72: Rename `id` → `uuid` on Category A tables + add missing FK constraints.

  Category A tables have a UUID primary key column named `id`. Ecto schemas map
  field `:uuid` → DB column `id` via `source: :id`. This migration renames the
  DB column to `uuid` so the `source: :id` mapping is no longer needed.

  ## Changes

  - Rename `id` → `uuid` on 30 Category A tables (metadata-only, instant)
  - Add 4 missing FK constraints:
    - `phoenix_kit_comments.user_uuid` → `phoenix_kit_users.uuid` (CASCADE)
    - `phoenix_kit_comments_dislikes.user_uuid` → `phoenix_kit_users.uuid` (CASCADE)
    - `phoenix_kit_comments_likes.user_uuid` → `phoenix_kit_users.uuid` (CASCADE)
    - `phoenix_kit_scheduled_jobs.created_by_uuid` → `phoenix_kit_users.uuid` (SET NULL)

  All operations are idempotent (guarded by column/constraint existence checks).

  ## Safety

  - Column renames are metadata-only in PostgreSQL — zero downtime, instant
  - 29 existing FK constraints referencing these columns auto-update on rename
  - Deploy is atomic: migration runs on startup before new code serves traffic
  """

  use Ecto.Migration

  @category_a_tables ~w(
    phoenix_kit_buckets phoenix_kit_comment_dislikes phoenix_kit_comment_likes
    phoenix_kit_comments phoenix_kit_comments_dislikes phoenix_kit_comments_likes
    phoenix_kit_file_instances phoenix_kit_file_locations phoenix_kit_files
    phoenix_kit_post_comments phoenix_kit_post_dislikes phoenix_kit_post_groups
    phoenix_kit_post_likes phoenix_kit_post_media phoenix_kit_post_mentions
    phoenix_kit_post_tags phoenix_kit_post_views phoenix_kit_posts
    phoenix_kit_scheduled_jobs phoenix_kit_storage_dimensions
    phoenix_kit_ticket_attachments phoenix_kit_ticket_comments
    phoenix_kit_ticket_status_history phoenix_kit_tickets
    phoenix_kit_user_blocks phoenix_kit_user_blocks_history
    phoenix_kit_user_connections phoenix_kit_user_connections_history
    phoenix_kit_user_follows phoenix_kit_user_follows_history
  )

  # {table, fk_column, ref_table, ref_column, on_delete}
  @missing_fk_constraints [
    {"phoenix_kit_comments", "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {"phoenix_kit_comments_dislikes", "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {"phoenix_kit_comments_likes", "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {"phoenix_kit_scheduled_jobs", "created_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"}
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    # 1. Rename id → uuid on all Category A tables
    for table <- @category_a_tables do
      if table_exists?(table, escaped_prefix) and
           column_exists?(table, "id", escaped_prefix) and
           not column_exists?(table, "uuid", escaped_prefix) do
        execute("ALTER TABLE #{prefix_table(table, prefix)} RENAME COLUMN id TO uuid")
      end
    end

    # 2. Add missing FK constraints
    for {table, fk_col, ref_table, ref_col, on_delete} <- @missing_fk_constraints do
      add_fk_constraint(table, fk_col, ref_table, ref_col, on_delete, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '72'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # 1. Drop the 4 FK constraints
    for {table, fk_col, _ref_table, _ref_col, _on_delete} <- @missing_fk_constraints do
      drop_fk_constraint(table, fk_col, prefix, escaped_prefix)
    end

    # 2. Rename uuid → id on all Category A tables
    for table <- @category_a_tables do
      if table_exists?(table, escaped_prefix) and
           column_exists?(table, "uuid", escaped_prefix) and
           not column_exists?(table, "id", escaped_prefix) do
        execute("ALTER TABLE #{prefix_table(table, prefix)} RENAME COLUMN uuid TO id")
      end
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '71'")
  end

  # ---------------------------------------------------------------------------
  # FK Constraint Helpers
  # ---------------------------------------------------------------------------

  defp add_fk_constraint(table, fk_col, ref_table, ref_col, on_delete, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) and
         column_exists?(table, fk_col, escaped_prefix) and
         table_exists?(ref_table, escaped_prefix) and
         column_exists?(ref_table, ref_col, escaped_prefix) do
      table_name = prefix_table(table, prefix)
      ref_name = prefix_table(ref_table, prefix)
      constraint = fk_constraint_name(table, fk_col)

      # Clean up orphaned FK references before adding the constraint
      cleanup_orphaned_fk_refs(table_name, fk_col, ref_name, ref_col, on_delete)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = '#{constraint}'
          AND conrelid = '#{table_name}'::regclass
        ) THEN
          ALTER TABLE #{table_name}
          ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{fk_col})
          REFERENCES #{ref_name}(#{ref_col})
          ON DELETE #{on_delete};
        END IF;
      END $$;
      """)
    end
  end

  defp cleanup_orphaned_fk_refs(table_name, fk_col, ref_name, ref_col, on_delete) do
    {action, action_sql} =
      if on_delete == "CASCADE" do
        {"DELETE",
         """
         DELETE FROM #{table_name} t
         WHERE t.#{fk_col} IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM #{ref_name} r WHERE r.#{ref_col} = t.#{fk_col}
         )
         """}
      else
        {"SET NULL",
         """
         UPDATE #{table_name} t
         SET #{fk_col} = NULL
         WHERE t.#{fk_col} IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM #{ref_name} r WHERE r.#{ref_col} = t.#{fk_col}
         )
         """}
      end

    execute("""
    DO $$
    DECLARE
      affected INTEGER;
    BEGIN
      #{action_sql};
      GET DIAGNOSTICS affected = ROW_COUNT;
      IF affected > 0 THEN
        RAISE NOTICE 'PhoenixKit V72: cleaned up % orphaned rows in %.% (action: %)',
          affected, '#{table_name}', '#{fk_col}', '#{action}';
      END IF;
    END $$;
    """)
  end

  defp drop_fk_constraint(table, fk_col, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) do
      table_name = prefix_table(table, prefix)
      constraint = fk_constraint_name(table, fk_col)

      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = '#{constraint}'
          AND conrelid = '#{table_name}'::regclass
        ) THEN
          ALTER TABLE #{table_name}
          DROP CONSTRAINT #{constraint};
        END IF;
      END $$;
      """)
    end
  end

  defp fk_constraint_name(table, fk_col) do
    short = String.replace_prefix(table, "phoenix_kit_", "")
    "fk_#{short}_#{fk_col}"
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
