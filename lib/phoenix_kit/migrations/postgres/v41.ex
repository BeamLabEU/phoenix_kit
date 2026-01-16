defmodule PhoenixKit.Migrations.Postgres.V41 do
  @moduledoc """
  PhoenixKit V41 Migration: AI Request Prompt Tracking & Reasoning Parameters

  This migration adds:
  1. Prompt tracking columns to AI requests table
  2. Reasoning/thinking parameters to AI endpoints table

  ## Changes

  ### Modified Table: phoenix_kit_ai_requests
  - Added prompt_id for linking requests to prompts
  - Added prompt_name for denormalized history display (like endpoint_name)

  ### Modified Table: phoenix_kit_ai_endpoints
  - Added reasoning_enabled (boolean) - Enable reasoning with default effort
  - Added reasoning_effort (string) - none/minimal/low/medium/high/xhigh
  - Added reasoning_max_tokens (integer) - Hard cap on thinking tokens (1024-32000)
  - Added reasoning_exclude (boolean) - Hide reasoning from response

  ## Backward Compatibility

  - Existing requests will have NULL prompt_id/prompt_name (not all requests use prompts)
  - Foreign key uses ON DELETE SET NULL to preserve history when prompts are deleted
  - Existing endpoints will have NULL reasoning values (reasoning disabled by default)
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

    # Add reasoning columns to endpoints table
    if table_exists?(:phoenix_kit_ai_endpoints, prefix) do
      alter table(:phoenix_kit_ai_endpoints, prefix: prefix) do
        add_if_not_exists :reasoning_enabled, :boolean
        add_if_not_exists :reasoning_effort, :string, size: 20
        add_if_not_exists :reasoning_max_tokens, :integer
        add_if_not_exists :reasoning_exclude, :boolean
      end

      execute """
      COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_endpoints", prefix)}.reasoning_enabled IS
      'Enable reasoning/thinking mode with default (medium) effort'
      """

      execute """
      COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_endpoints", prefix)}.reasoning_effort IS
      'Reasoning intensity: none, minimal, low, medium, high, xhigh'
      """

      execute """
      COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_endpoints", prefix)}.reasoning_max_tokens IS
      'Hard cap on reasoning/thinking tokens (1024-32000)'
      """

      execute """
      COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_endpoints", prefix)}.reasoning_exclude IS
      'Hide reasoning from response while still using it internally'
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

    # Remove reasoning columns from endpoints table
    if table_exists?(:phoenix_kit_ai_endpoints, prefix) do
      alter table(:phoenix_kit_ai_endpoints, prefix: prefix) do
        remove_if_exists :reasoning_enabled, :boolean
        remove_if_exists :reasoning_effort, :string
        remove_if_exists :reasoning_max_tokens, :integer
        remove_if_exists :reasoning_exclude, :boolean
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
