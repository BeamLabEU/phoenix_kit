defmodule PhoenixKit.Migrations.Postgres.V78 do
  @moduledoc """
  V78: Add missing columns to AI tables from V41.

  V41 conditionally added columns to AI tables (reasoning columns on endpoints,
  prompt tracking on requests), but only if the tables existed at the time.
  If the AI module was enabled after V41 ran, these columns were never created.

  This migration ensures they exist. All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")

    # Reasoning columns on endpoints (from V41)
    if table_exists?(:phoenix_kit_ai_endpoints, prefix) do
      alter table(:phoenix_kit_ai_endpoints, prefix: prefix) do
        add_if_not_exists :reasoning_enabled, :boolean
        add_if_not_exists :reasoning_effort, :string, size: 20
        add_if_not_exists :reasoning_max_tokens, :integer
        add_if_not_exists :reasoning_exclude, :boolean
      end
    end

    # Prompt tracking columns on requests (from V41)
    if table_exists?(:phoenix_kit_ai_requests, prefix) do
      alter table(:phoenix_kit_ai_requests, prefix: prefix) do
        add_if_not_exists :prompt_uuid, :uuid
        add_if_not_exists :prompt_name, :string, size: 255
      end

      create_if_not_exists index(:phoenix_kit_ai_requests, [:prompt_uuid],
                             name: :phoenix_kit_ai_requests_prompt_uuid_idx,
                             prefix: prefix
                           )

      if table_exists?(:phoenix_kit_ai_prompts, prefix) do
        # V56 skips tables that don't exist yet, so ai_prompts may lack a uuid
        # column if the AI module was enabled after V56 ran. Ensure it exists.
        ensure_uuid_column(:phoenix_kit_ai_prompts, prefix)

        execute """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'phoenix_kit_ai_requests_prompt_uuid_fkey'
            AND conrelid = '#{prefix_str(prefix)}phoenix_kit_ai_requests'::regclass
          ) THEN
            ALTER TABLE #{prefix_str(prefix)}phoenix_kit_ai_requests
            ADD CONSTRAINT phoenix_kit_ai_requests_prompt_uuid_fkey
            FOREIGN KEY (prompt_uuid)
            REFERENCES #{prefix_str(prefix)}phoenix_kit_ai_prompts(uuid)
            ON DELETE SET NULL;
          END IF;
        END $$;
        """
      end
    end

    execute "COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '78'"
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")

    if table_exists?(:phoenix_kit_ai_endpoints, prefix) do
      alter table(:phoenix_kit_ai_endpoints, prefix: prefix) do
        remove_if_exists :reasoning_enabled, :boolean
        remove_if_exists :reasoning_effort, :string
        remove_if_exists :reasoning_max_tokens, :integer
        remove_if_exists :reasoning_exclude, :boolean
      end
    end

    if table_exists?(:phoenix_kit_ai_requests, prefix) do
      execute """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = 'phoenix_kit_ai_requests_prompt_uuid_fkey'
          AND conrelid = '#{prefix_str(prefix)}phoenix_kit_ai_requests'::regclass
        ) THEN
          ALTER TABLE #{prefix_str(prefix)}phoenix_kit_ai_requests
          DROP CONSTRAINT phoenix_kit_ai_requests_prompt_uuid_fkey;
        END IF;
      END $$;
      """

      drop_if_exists index(:phoenix_kit_ai_requests, [:prompt_uuid],
                       name: :phoenix_kit_ai_requests_prompt_uuid_idx,
                       prefix: prefix
                     )

      alter table(:phoenix_kit_ai_requests, prefix: prefix) do
        remove_if_exists :prompt_uuid, :uuid
        remove_if_exists :prompt_name, :string
      end
    end

    execute "COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '77'"
  end

  defp table_exists?(table_name, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = '#{prefix}'
      AND table_name = '#{table_name}'
    )
    """

    %{rows: [[exists]]} = PhoenixKit.RepoHelper.repo().query!(query)
    exists
  end

  # Idempotently adds uuid column + backfill + NOT NULL + unique index.
  # All statements use IF NOT EXISTS / IF NULL guards, safe to run on tables
  # that already have the column.
  defp ensure_uuid_column(table_name, prefix) do
    full_table = "#{prefix_str(prefix)}#{table_name}"

    execute("""
    ALTER TABLE #{full_table}
    ADD COLUMN IF NOT EXISTS uuid UUID DEFAULT uuid_generate_v7()
    """)

    execute("UPDATE #{full_table} SET uuid = uuid_generate_v7() WHERE uuid IS NULL")

    execute("ALTER TABLE #{full_table} ALTER COLUMN uuid SET NOT NULL")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{table_name}_uuid_index ON #{full_table}(uuid)
    """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
