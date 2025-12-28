defmodule PhoenixKit.Migrations.Postgres.V41 do
  @moduledoc """
  PhoenixKit V41 Migration: Legal Module

  This migration introduces the Legal module infrastructure for GDPR/CCPA compliance,
  including consent tracking and legal page management.

  ## Changes

  ### Phase 1: Settings Seeds
  - legal_enabled: Module enable/disable toggle
  - legal_frameworks: Selected compliance frameworks (JSON array)
  - legal_company_info: Company information for legal pages (JSON)
  - legal_dpo_contact: Data Protection Officer contact (JSON)

  ### Phase 2 Prep: Consent Logs Table
  - phoenix_kit_consent_logs: User consent tracking for cookie banners
  - Supports both logged-in users and anonymous visitors
  - Tracks consent type, version, and user fingerprint

  ### Consent Widget Settings (Phase 2)
  - legal_consent_widget_enabled: Cookie consent banner toggle
  - legal_cookie_banner_position: Banner position (bottom, top, etc.)

  ## PostgreSQL Support
  - JSONB storage for flexible metadata
  - Optimized indexes for consent queries
  - Supports prefix for schema isolation

  ## Usage

      # Migrate up
      PhoenixKit.Migrations.Postgres.up(prefix: "public", version: 41)

      # Rollback
      PhoenixKit.Migrations.Postgres.down(prefix: "public", version: 40)
  """
  use Ecto.Migration

  @doc """
  Run the V41 migration to add the Legal module infrastructure.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===================================
    # 1. CONSENT LOGS TABLE (Phase 2 prep)
    # ===================================
    create_if_not_exists table(:phoenix_kit_consent_logs, prefix: prefix) do
      # User identification
      add :user_id, :bigint, null: true
      add :session_id, :string, size: 64, null: true

      # Consent details
      add :consent_type, :string, size: 30, null: false
      add :consent_given, :boolean, null: false, default: false
      add :consent_version, :string, size: 20, null: true

      # Fingerprinting for anonymous tracking
      add :ip_address, :string, size: 45, null: true
      add :user_agent_hash, :string, size: 64, null: true

      # Additional data
      add :metadata, :map, null: true, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for consent logs
    create_if_not_exists index(:phoenix_kit_consent_logs, [:user_id],
                           name: :phoenix_kit_consent_logs_user_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_consent_logs, [:session_id],
                           name: :phoenix_kit_consent_logs_session_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_consent_logs, [:consent_type],
                           name: :phoenix_kit_consent_logs_type_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_consent_logs, [:inserted_at],
                           name: :phoenix_kit_consent_logs_inserted_at_idx,
                           prefix: prefix
                         )

    # Composite index for user consent lookup
    create_if_not_exists index(:phoenix_kit_consent_logs, [:user_id, :consent_type],
                           name: :phoenix_kit_consent_logs_user_type_idx,
                           prefix: prefix
                         )

    # Composite index for session consent lookup
    create_if_not_exists index(:phoenix_kit_consent_logs, [:session_id, :consent_type],
                           name: :phoenix_kit_consent_logs_session_type_idx,
                           prefix: prefix
                         )

    # ===================================
    # 2. SETTINGS SEEDS
    # ===================================
    # Boolean settings use 'value' column (string)
    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)} (key, value, module, date_added, date_updated)
    VALUES
      ('legal_enabled', 'false', 'legal', NOW(), NOW()),
      ('legal_consent_widget_enabled', 'false', 'legal', NOW(), NOW()),
      ('legal_cookie_banner_position', 'bottom', 'legal', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    # JSON settings use 'value_json' column (jsonb)
    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)} (key, value_json, module, date_added, date_updated)
    VALUES
      ('legal_frameworks', '{"items": []}'::jsonb, 'legal', NOW(), NOW()),
      ('legal_company_info', '{}'::jsonb, 'legal', NOW(), NOW()),
      ('legal_dpo_contact', '{}'::jsonb, 'legal', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    # ===================================
    # 3. TABLE COMMENTS
    # ===================================
    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_consent_logs", prefix)} IS
    'User consent tracking for GDPR/CCPA compliance cookie banners'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_consent_logs", prefix)}.consent_type IS
    'Type of consent: necessary, analytics, marketing, preferences'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_consent_logs", prefix)}.consent_version IS
    'Version of privacy/cookie policy when consent was given'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_consent_logs", prefix)}.user_agent_hash IS
    'SHA256 hash of user agent for anonymous tracking without storing full UA string'
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '41'"
  end

  @doc """
  Rollback the V41 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop indexes first
    drop_if_exists index(:phoenix_kit_consent_logs, [:session_id, :consent_type],
                     name: :phoenix_kit_consent_logs_session_type_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_consent_logs, [:user_id, :consent_type],
                     name: :phoenix_kit_consent_logs_user_type_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_consent_logs, [:inserted_at],
                     name: :phoenix_kit_consent_logs_inserted_at_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_consent_logs, [:consent_type],
                     name: :phoenix_kit_consent_logs_type_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_consent_logs, [:session_id],
                     name: :phoenix_kit_consent_logs_session_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_consent_logs, [:user_id],
                     name: :phoenix_kit_consent_logs_user_id_idx,
                     prefix: prefix
                   )

    # Drop table
    drop_if_exists table(:phoenix_kit_consent_logs, prefix: prefix)

    # Remove settings
    execute """
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key IN (
      'legal_enabled',
      'legal_frameworks',
      'legal_company_info',
      'legal_dpo_contact',
      'legal_consent_widget_enabled',
      'legal_cookie_banner_position'
    )
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '40'"
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
