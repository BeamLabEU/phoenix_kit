defmodule PhoenixKit.Migrations.Postgres.V34 do
  @moduledoc """
  PhoenixKit V34 Migration: AI Endpoints System

  This migration replaces the Accounts + Slots architecture with a unified
  Endpoints system where each endpoint contains credentials, model selection,
  and generation parameters in a single entity.

  ## Architecture Change

  ### Before (V32)
  - **Accounts Table**: Provider credentials only
  - **Slots**: Stored in Settings as JSON (4 types × 3 slots each)
  - Slots referenced account_id for credentials
  - Fallback chain: tries slot 0 → 1 → 2

  ### After (V34)
  - **Endpoints Table**: Unified configuration
    - Provider credentials (name, api_key, base_url, provider_settings)
    - Model selection (single model per endpoint)
    - Generation parameters (temperature, max_tokens, etc.)
  - No type categorization (user decides endpoint purpose)
  - No fallback chain (explicit endpoint targeting)

  ## Changes

  ### New Table: phoenix_kit_ai_endpoints
  - Unified configuration combining account + slot fields
  - All generation parameters in one place
  - Sort order for display

  ### Modified Table: phoenix_kit_ai_requests
  - Added endpoint_id for new requests
  - Added endpoint_name for denormalized history
  - Kept account_id/slot_index for backward compatibility

  ### Cleanup
  - Remove slot Settings entries (ai_text_processing_slots, etc.)
  - Keep ai_enabled setting
  - Keep accounts table for historical request references
  """
  use Ecto.Migration

  @doc """
  Run the V34 migration to add the AI Endpoints system.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===========================================
    # 1. CREATE AI ENDPOINTS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_ai_endpoints, prefix: prefix) do
      # Identity
      add :name, :string, size: 100, null: false
      add :description, :string, size: 500

      # Provider configuration
      add :provider, :string, size: 50, null: false, default: "openrouter"
      add :api_key, :text, null: false
      add :base_url, :string, size: 255
      add :provider_settings, :map, null: true, default: %{}

      # Model configuration
      add :model, :string, size: 150, null: false

      # Generation parameters
      add :temperature, :float, default: 0.7
      add :max_tokens, :integer
      add :top_p, :float
      add :top_k, :integer
      add :frequency_penalty, :float
      add :presence_penalty, :float
      add :repetition_penalty, :float
      add :stop, {:array, :string}
      add :seed, :integer

      # Image generation parameters
      add :image_size, :string, size: 20
      add :image_quality, :string, size: 20

      # Embeddings parameters
      add :dimensions, :integer

      # Status
      add :enabled, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0
      add :last_validated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Index for enabled endpoints
    create_if_not_exists index(:phoenix_kit_ai_endpoints, [:enabled],
                           name: :phoenix_kit_ai_endpoints_enabled_idx,
                           prefix: prefix
                         )

    # Index for sorting
    create_if_not_exists index(:phoenix_kit_ai_endpoints, [:sort_order],
                           name: :phoenix_kit_ai_endpoints_sort_order_idx,
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_ai_endpoints", prefix)} IS
    'AI endpoints - unified configuration combining credentials, model, and parameters'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_endpoints", prefix)}.provider_settings IS
    'Provider-specific settings (http_referer, x_title for OpenRouter, etc.)'
    """

    # ===========================================
    # 2. UPDATE AI REQUESTS TABLE
    # ===========================================
    alter table(:phoenix_kit_ai_requests, prefix: prefix) do
      add_if_not_exists :endpoint_id, :integer
      add_if_not_exists :endpoint_name, :string, size: 100
    end

    # Index for endpoint_id
    create_if_not_exists index(:phoenix_kit_ai_requests, [:endpoint_id],
                           name: :phoenix_kit_ai_requests_endpoint_id_idx,
                           prefix: prefix
                         )

    # Add foreign key to endpoints (optional - endpoint can be deleted)
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_endpoint_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
        ADD CONSTRAINT phoenix_kit_ai_requests_endpoint_id_fkey
        FOREIGN KEY (endpoint_id)
        REFERENCES #{prefix_table_name("phoenix_kit_ai_endpoints", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_requests", prefix)}.endpoint_id IS
    'Reference to AI endpoint used (new system)'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_requests", prefix)}.endpoint_name IS
    'Denormalized endpoint name for historical display'
    """

    # ===========================================
    # 3. CLEANUP OLD SLOT SETTINGS
    # ===========================================
    execute """
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key IN (
      'ai_text_processing_slots',
      'ai_vision_processing_slots',
      'ai_image_gen_slots',
      'ai_embeddings_slots'
    )
    """

    # ===========================================
    # 4. UPDATE VERSION
    # ===========================================
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '34'"
  end

  @doc """
  Rollback the V34 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop foreign key from requests
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_ai_requests_endpoint_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_ai_requests", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_ai_requests", prefix)}
        DROP CONSTRAINT phoenix_kit_ai_requests_endpoint_id_fkey;
      END IF;
    END $$;
    """

    # Drop index from requests
    drop_if_exists index(:phoenix_kit_ai_requests, [:endpoint_id],
                     name: :phoenix_kit_ai_requests_endpoint_id_idx,
                     prefix: prefix
                   )

    # Remove columns from requests
    alter table(:phoenix_kit_ai_requests, prefix: prefix) do
      remove_if_exists :endpoint_id, :integer
      remove_if_exists :endpoint_name, :string
    end

    # Drop endpoints indexes
    drop_if_exists index(:phoenix_kit_ai_endpoints, [:sort_order],
                     name: :phoenix_kit_ai_endpoints_sort_order_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_endpoints, [:enabled],
                     name: :phoenix_kit_ai_endpoints_enabled_idx,
                     prefix: prefix
                   )

    # Drop endpoints table
    drop_if_exists table(:phoenix_kit_ai_endpoints, prefix: prefix)

    # Restore default slot settings
    default_text_slots =
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
      ('ai_text_processing_slots', '#{default_text_slots}'::jsonb, 'ai', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '33'"
  end

  # Helper to build prefixed table name
  defp prefix_table_name(table, nil), do: table
  defp prefix_table_name(table, "public"), do: table
  defp prefix_table_name(table, prefix), do: "#{prefix}.#{table}"
end
