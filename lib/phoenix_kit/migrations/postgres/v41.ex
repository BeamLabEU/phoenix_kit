defmodule PhoenixKit.Migrations.Postgres.V41 do
  @moduledoc """
  PhoenixKit V41 Migration: AI Request Prompt Tracking

  This migration adds prompt tracking columns to the AI requests table,
  enabling tracking of which prompts are used in AI completions.

  ## Changes

  ### Modified Table: phoenix_kit_ai_requests
  - Added prompt_id for linking requests to prompts
  - Added prompt_name for denormalized history display (like endpoint_name)

  ## Backward Compatibility

  - Existing requests will have NULL prompt_id/prompt_name (not all requests use prompts)
  - Foreign key uses ON DELETE SET NULL to preserve history when prompts are deleted
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")

    # Check if AI requests table exists (module may not be enabled)
    if table_exists?(:phoenix_kit_ai_requests, prefix) do
      # Add prompt tracking columns to requests table
      alter table(:phoenix_kit_ai_requests, prefix: prefix) do
        add_if_not_exists :prompt_id, :integer
        add_if_not_exists :prompt_name, :string, size: 255
      end

      # Index for prompt_id
      create_if_not_exists index(:phoenix_kit_ai_requests, [:prompt_id],
                             name: :phoenix_kit_ai_requests_prompt_id_idx,
                             prefix: prefix
                           )

      # Foreign key constraint (only if prompts table exists)
      if table_exists?(:phoenix_kit_ai_prompts, prefix) do
        execute """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = 'phoenix_kit_ai_requests_prompt_id_fkey'
            AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
          ) THEN
            ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
            ADD CONSTRAINT phoenix_kit_ai_requests_prompt_id_fkey
            FOREIGN KEY (prompt_id)
            REFERENCES #{prefix_table_name("phoenix_kit_ai_prompts", prefix)}(id)
            ON DELETE SET NULL;
          END IF;
        END $$;
        """
      end

      # Add column comments
      execute """
      COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_requests", prefix)}.prompt_id IS
      'Reference to AI prompt used (if request was made via ask_with_prompt or similar)'
      """

      execute """
      COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_requests", prefix)}.prompt_name IS
      'Denormalized prompt name for historical display'
      """
    end

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '41'"
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")

    if table_exists?(:phoenix_kit_ai_requests, prefix) do
      # Drop foreign key constraint
      execute """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = 'phoenix_kit_ai_requests_prompt_id_fkey'
          AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
        ) THEN
          ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
          DROP CONSTRAINT phoenix_kit_ai_requests_prompt_id_fkey;
        END IF;
      END $$;
      """

      # Drop index
      drop_if_exists index(:phoenix_kit_ai_requests, [:prompt_id],
                       name: :phoenix_kit_ai_requests_prompt_id_idx,
                       prefix: prefix
                     )

      # Remove columns
      alter table(:phoenix_kit_ai_requests, prefix: prefix) do
        remove_if_exists :prompt_id, :integer
        remove_if_exists :prompt_name, :string
      end
    end

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '40'"
  end

  # Helper to check if a table exists
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

  defp prefix_table_name(table, "public"), do: "public.#{table}"
  defp prefix_table_name(table, prefix), do: "#{prefix}.#{table}"
end
