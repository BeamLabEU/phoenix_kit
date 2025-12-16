defmodule PhoenixKit.Migrations.Postgres.V32 do
  @moduledoc """
  PhoenixKit V32 Migration: AI System

  This migration introduces the AI provider account management and usage tracking system.

  ## Changes

  ### AI Accounts Table (phoenix_kit_ai_accounts)
  - Store AI provider credentials (OpenRouter, etc.)
  - Support multiple accounts per provider
  - Optional settings for provider-specific configuration
  - API key validation tracking

  ### AI Requests Table (phoenix_kit_ai_requests)
  - Track every AI API request for history and statistics
  - Token usage tracking (input, output, total)
  - Cost tracking when available
  - Latency and status monitoring
  - Per-user and per-account tracking

  ### Settings Seeds
  - AI module enable/disable
  - Text processing slots configuration (JSON)

  ## PostgreSQL Support
  - Leverages PostgreSQL's native JSONB for flexible metadata
  - Supports prefix for schema isolation
  - Optimized indexes for common queries
  """
  use Ecto.Migration

  @doc """
  Run the V32 migration to add the AI system.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===========================================
    # 1. AI ACCOUNTS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_ai_accounts, prefix: prefix) do
      add :name, :string, size: 100, null: false
      add :provider, :string, size: 50, null: false, default: "openrouter"
      add :api_key, :text, null: false
      add :base_url, :string, size: 255
      add :settings, :map, null: true, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :last_validated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:phoenix_kit_ai_accounts, [:provider],
                           name: :phoenix_kit_ai_accounts_provider_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_ai_accounts, [:enabled],
                           name: :phoenix_kit_ai_accounts_enabled_idx,
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_ai_accounts", prefix)} IS
    'AI provider accounts for text processing (OpenRouter, etc.)'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_accounts", prefix)}.api_key IS
    'Provider API key (stored in plain text like OAuth credentials)'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_accounts", prefix)}.settings IS
    'Provider-specific settings (HTTP-Referer, X-Title headers for OpenRouter, etc.)'
    """

    # ===========================================
    # 2. AI REQUESTS TABLE (Usage History)
    # ===========================================
    create_if_not_exists table(:phoenix_kit_ai_requests, prefix: prefix) do
      add :account_id, :integer
      add :user_id, :integer
      add :slot_index, :integer
      add :model, :string, size: 100
      add :request_type, :string, size: 50, null: false, default: "text_completion"
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :total_tokens, :integer, null: false, default: 0
      add :cost_cents, :integer
      add :latency_ms, :integer
      add :status, :string, size: 20, null: false, default: "success"
      add :error_message, :text
      add :metadata, :map, null: true, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:phoenix_kit_ai_requests, [:account_id],
                           name: :phoenix_kit_ai_requests_account_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_ai_requests, [:user_id],
                           name: :phoenix_kit_ai_requests_user_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_ai_requests, [:status],
                           name: :phoenix_kit_ai_requests_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_ai_requests, [:inserted_at],
                           name: :phoenix_kit_ai_requests_inserted_at_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_ai_requests, [:model],
                           name: :phoenix_kit_ai_requests_model_idx,
                           prefix: prefix
                         )

    # Add foreign key to ai_accounts (optional - account can be deleted)
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_account_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
        ADD CONSTRAINT phoenix_kit_ai_requests_account_id_fkey
        FOREIGN KEY (account_id)
        REFERENCES #{prefix_table_name("phoenix_kit_ai_accounts", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """

    # Add foreign key to users (optional - user can be deleted)
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
        ADD CONSTRAINT phoenix_kit_ai_requests_user_id_fkey
        FOREIGN KEY (user_id)
        REFERENCES #{prefix_table_name("phoenix_kit_users", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)} IS
    'AI API request history for usage tracking and statistics'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_requests", prefix)}.slot_index IS
    'Which text processing slot was used (0, 1, or 2)'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_requests", prefix)}.cost_cents IS
    'Estimated cost in cents (when available from API response)'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_requests", prefix)}.status IS
    'Request status: success, error, or timeout'
    """

    # ===========================================
    # 3. AI SETTINGS
    # ===========================================
    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)} (key, value, module, date_added, date_updated)
    VALUES
      ('ai_enabled', 'false', 'ai', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    # Default text processing slots configuration (JSON)
    default_slots =
      Jason.encode!(%{
        "slots" => [
          %{
            "name" => "Slot 1",
            "description" => "",
            "account_id" => nil,
            "model" => "",
            "temperature" => 0.7,
            "max_tokens" => 1000,
            "enabled" => false
          },
          %{
            "name" => "Slot 2",
            "description" => "",
            "account_id" => nil,
            "model" => "",
            "temperature" => 0.7,
            "max_tokens" => 2000,
            "enabled" => false
          },
          %{
            "name" => "Slot 3",
            "description" => "",
            "account_id" => nil,
            "model" => "",
            "temperature" => 0.7,
            "max_tokens" => 4000,
            "enabled" => false
          }
        ]
      })

    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)} (key, value_json, module, date_added, date_updated)
    VALUES
      ('ai_text_processing_slots', '#{default_slots}'::jsonb, 'ai', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '32'"
  end

  @doc """
  Rollback the V32 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop requests foreign keys first
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
        DROP CONSTRAINT phoenix_kit_ai_requests_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_account_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
        DROP CONSTRAINT phoenix_kit_ai_requests_account_id_fkey;
      END IF;
    END $$;
    """

    # Drop requests indexes
    drop_if_exists index(:phoenix_kit_ai_requests, [:model],
                     name: :phoenix_kit_ai_requests_model_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_requests, [:inserted_at],
                     name: :phoenix_kit_ai_requests_inserted_at_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_requests, [:status],
                     name: :phoenix_kit_ai_requests_status_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_requests, [:user_id],
                     name: :phoenix_kit_ai_requests_user_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_requests, [:account_id],
                     name: :phoenix_kit_ai_requests_account_id_idx,
                     prefix: prefix
                   )

    # Drop requests table
    drop_if_exists table(:phoenix_kit_ai_requests, prefix: prefix)

    # Drop accounts indexes
    drop_if_exists index(:phoenix_kit_ai_accounts, [:enabled],
                     name: :phoenix_kit_ai_accounts_enabled_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_accounts, [:provider],
                     name: :phoenix_kit_ai_accounts_provider_idx,
                     prefix: prefix
                   )

    # Drop accounts table
    drop_if_exists table(:phoenix_kit_ai_accounts, prefix: prefix)

    # Remove AI settings
    execute """
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key IN (
      'ai_enabled',
      'ai_text_processing_slots'
    )
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '31'"
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
