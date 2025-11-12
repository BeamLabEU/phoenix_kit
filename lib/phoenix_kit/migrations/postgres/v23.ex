defmodule PhoenixKit.Migrations.Postgres.V23 do
  @moduledoc """
  PhoenixKit V23 Migration: Session Fingerprinting

  This migration adds session fingerprinting capabilities to prevent session hijacking attacks.
  It adds IP address and user agent tracking to session tokens, allowing the system to
  detect when a session token is used from a different location or device.

  ## Changes

  ### Session Security Enhancements
  - Adds ip_address field to phoenix_kit_users_tokens table for IP-based verification
  - Adds user_agent_hash field to phoenix_kit_users_tokens table for device verification
  - Session tokens can now be verified against the original connection fingerprint
  - Prevents session hijacking by detecting suspicious session usage patterns

  ## Security Features
  - IP address tracking: Detects when session is used from different IP
  - User agent hashing: Detects when session is used from different browser/device
  - Backward compatible: Existing sessions without fingerprints remain valid
  - Configurable strictness: Can log warnings or force re-authentication

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Optimized indexes for fingerprint lookups
  """
  use Ecto.Migration

  @doc """
  Run the V23 session fingerprinting migration.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add session fingerprinting columns to users_tokens table
    alter table(:phoenix_kit_users_tokens, prefix: prefix) do
      add_if_not_exists :ip_address, :string, null: true
      add_if_not_exists :user_agent_hash, :string, null: true
    end

    # Create indexes for fingerprint lookups
    create_if_not_exists index(:phoenix_kit_users_tokens, [:ip_address], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_users_tokens, [:user_agent_hash], prefix: prefix)

    # Create composite index for efficient fingerprint verification
    create_if_not_exists index(:phoenix_kit_users_tokens, [:token, :ip_address, :user_agent_hash],
                           prefix: prefix
                         )

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '23'"
  end

  @doc """
  Rollback the V23 session fingerprinting migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop indexes first
    drop_if_exists index(:phoenix_kit_users_tokens, [:token, :ip_address, :user_agent_hash],
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_users_tokens, [:user_agent_hash], prefix: prefix)
    drop_if_exists index(:phoenix_kit_users_tokens, [:ip_address], prefix: prefix)

    # Drop columns
    alter table(:phoenix_kit_users_tokens, prefix: prefix) do
      remove_if_exists :ip_address, :string
      remove_if_exists :user_agent_hash, :string
    end

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '22'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
