defmodule PhoenixKit.Migrations.Postgres.V16 do
  @moduledoc """
  PhoenixKit V16 Migration: OAuth Providers System & Magic Link Registration

  This migration introduces OAuth authentication support for external providers
  like Google, Apple, GitHub, and others using the Ueberauth framework.
  It also modifies the tokens table to support magic link registration.

  ## Changes

  ### OAuth Providers System
  - Adds phoenix_kit_user_oauth_providers table for OAuth provider linking
  - Supports multiple OAuth providers per user (Google, Apple, GitHub, etc.)
  - Stores OAuth tokens with encryption support
  - Account linking by email address
  - Audit trail with insertion timestamps

  ### Magic Link Registration Support
  - Allows null user_id in phoenix_kit_users_tokens for magic_link_registration context
  - Adds check constraint to ensure user_id is required for non-registration contexts

  ### New Tables
  - **phoenix_kit_user_oauth_providers**: OAuth provider associations with users

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Optimized indexes for performance
  - Unique constraints to prevent duplicate provider links
  - JSONB field for flexible OAuth data storage
  """
  use Ecto.Migration

  @doc """
  Run the V16 migration to add OAuth providers system and magic link registration support.
  """
  def up(%{prefix: prefix} = _opts) do
    # Modify tokens table to allow null user_id for magic link registration
    alter_tokens_table_user_id_nullable(prefix)
    add_user_id_check_constraint(prefix)

    # Create OAuth providers table
    create_if_not_exists table(:phoenix_kit_user_oauth_providers, prefix: prefix) do
      # Foreign key to users table
      add :user_id,
          references(:phoenix_kit_users,
            prefix: prefix,
            on_delete: :delete_all,
            on_update: :update_all
          ),
          null: false

      # OAuth provider name (google, apple, github, etc.)
      add :provider, :string, null: false

      # OAuth provider's unique user identifier
      add :provider_uid, :string, null: false

      # Email address from OAuth provider (for audit trail)
      add :provider_email, :string, null: true

      # OAuth access token (should be encrypted in production)
      add :access_token, :text, null: true

      # OAuth refresh token (should be encrypted in production)
      add :refresh_token, :text, null: true

      # Token expiration timestamp
      add :token_expires_at, :utc_datetime_usec, null: true

      # JSONB field for additional OAuth data (avatar_url, locale, etc.)
      add :raw_data, :map, null: true, default: %{}

      # Timestamps for tracking record creation/update
      timestamps(type: :utc_datetime_usec)
    end

    # Unique constraint: one provider per user (user can't have multiple Google accounts)
    create_if_not_exists unique_index(:phoenix_kit_user_oauth_providers, [:user_id, :provider],
                           prefix: prefix,
                           name: :phoenix_kit_oauth_providers_user_provider_idx
                         )

    # Unique constraint: provider_uid must be unique per provider
    create_if_not_exists unique_index(
                           :phoenix_kit_user_oauth_providers,
                           [:provider, :provider_uid],
                           prefix: prefix,
                           name: :phoenix_kit_oauth_providers_provider_uid_idx
                         )

    # Performance index for searching by provider email
    create_if_not_exists index(:phoenix_kit_user_oauth_providers, [:provider_email],
                           prefix: prefix
                         )

    # Performance index for searching by provider
    create_if_not_exists index(:phoenix_kit_user_oauth_providers, [:provider], prefix: prefix)

    # Performance index for searching by user_id
    create_if_not_exists index(:phoenix_kit_user_oauth_providers, [:user_id], prefix: prefix)

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '16'"
  end

  @doc """
  Rollback the V16 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop OAuth indexes first
    drop_if_exists index(:phoenix_kit_user_oauth_providers, [:user_id], prefix: prefix)
    drop_if_exists index(:phoenix_kit_user_oauth_providers, [:provider], prefix: prefix)
    drop_if_exists index(:phoenix_kit_user_oauth_providers, [:provider_email], prefix: prefix)

    drop_if_exists unique_index(
                     :phoenix_kit_user_oauth_providers,
                     [:provider, :provider_uid],
                     prefix: prefix,
                     name: :phoenix_kit_oauth_providers_provider_uid_idx
                   )

    drop_if_exists unique_index(:phoenix_kit_user_oauth_providers, [:user_id, :provider],
                     prefix: prefix,
                     name: :phoenix_kit_oauth_providers_user_provider_idx
                   )

    # Drop OAuth table
    drop_if_exists table(:phoenix_kit_user_oauth_providers, prefix: prefix)

    # Revert tokens table changes
    drop_user_id_check_constraint(prefix)
    alter_tokens_table_user_id_not_null(prefix)

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '15'"
  end

  # Private helper functions

  defp alter_tokens_table_user_id_nullable(prefix) do
    execute(
      """
      ALTER TABLE #{prefix_table_name("phoenix_kit_users_tokens", prefix)}
      ALTER COLUMN user_id DROP NOT NULL
      """,
      # Rollback: Make user_id NOT NULL again (down migration)
      """
      ALTER TABLE #{prefix_table_name("phoenix_kit_users_tokens", prefix)}
      ALTER COLUMN user_id SET NOT NULL
      """
    )
  end

  defp alter_tokens_table_user_id_not_null(prefix) do
    table_name = prefix_table_name("phoenix_kit_users_tokens", prefix)

    # First, delete any tokens with NULL user_id (magic link registration tokens)
    execute(
      """
      DELETE FROM #{table_name}
      WHERE user_id IS NULL AND context = 'magic_link_registration'
      """,
      # Rollback: No need to restore deleted tokens
      "SELECT 1"
    )

    # Then set NOT NULL constraint
    execute(
      """
      ALTER TABLE #{table_name}
      ALTER COLUMN user_id SET NOT NULL
      """,
      # Rollback: Allow NULL again (up migration)
      """
      ALTER TABLE #{table_name}
      ALTER COLUMN user_id DROP NOT NULL
      """
    )
  end

  defp add_user_id_check_constraint(prefix) do
    constraint_name = "user_id_required_for_non_registration_tokens"
    table_name = prefix_table_name("phoenix_kit_users_tokens", prefix)

    execute(
      """
      ALTER TABLE #{table_name}
      ADD CONSTRAINT #{constraint_name}
      CHECK (
        CASE
          WHEN context = 'magic_link_registration' THEN true
          ELSE user_id IS NOT NULL
        END
      )
      """,
      # Rollback: Drop the constraint
      """
      ALTER TABLE #{table_name}
      DROP CONSTRAINT IF EXISTS #{constraint_name}
      """
    )
  end

  defp drop_user_id_check_constraint(prefix) do
    constraint_name = "user_id_required_for_non_registration_tokens"
    table_name = prefix_table_name("phoenix_kit_users_tokens", prefix)

    execute(
      """
      ALTER TABLE #{table_name}
      DROP CONSTRAINT IF EXISTS #{constraint_name}
      """,
      # Rollback: Recreate the constraint (up migration)
      """
      ALTER TABLE #{table_name}
      ADD CONSTRAINT #{constraint_name}
      CHECK (
        CASE
          WHEN context = 'magic_link_registration' THEN true
          ELSE user_id IS NOT NULL
        END
      )
      """
    )
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
