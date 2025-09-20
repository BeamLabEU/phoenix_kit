defmodule PhoenixKit.Migrations.Postgres.V10 do
  @moduledoc """
  PhoenixKit V10 Migration: User Registration Analytics

  This migration adds user registration analytics functionality to track geographical
  and technical information about user registrations for statistics and insights.

  ## Changes

  ### User Analytics Columns
  - Adds registration analytics columns to phoenix_kit_users table
  - Creates indexes for efficient analytics queries
  - Supports IP address tracking with privacy-focused design
  - Provides geographical data (country, region, city)

  ### New Features
  - **Registration Analytics**: Track IP and location data directly on user records
  - **Privacy Focused**: Designed for easy data purging and compliance
  - **Performance Optimized**: Efficient indexes for analytics queries
  - **Simplified Data Model**: Analytics data stored directly with user records
  - **Audit Trail**: Registration analytics linked to user accounts

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Uses string type for IP address storage (IPv4/IPv6 compatible)
  - Optimized indexes for common analytics queries
  - No additional foreign key constraints needed
  """
  use Ecto.Migration

  @doc """
  Run the V10 migration to add user registration analytics.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add registration analytics columns to existing phoenix_kit_users table
    alter table(:phoenix_kit_users, prefix: prefix) do
      # Registration IP address (stored as string for IPv4/IPv6 compatibility)
      add :registration_ip, :string, size: 45, null: true

      # Geographic information (ISO codes and names)
      # ISO 3166-1 alpha-2 country code
      add :registration_country, :string, size: 2, null: true
      # State/province/region name
      add :registration_region, :string, size: 100, null: true
      # City name
      add :registration_city, :string, size: 100, null: true
    end

    # Create indexes for efficient analytics queries on users table

    # Geographic analytics queries
    create_if_not_exists index(:phoenix_kit_users, [:registration_country, :inserted_at],
                           prefix: prefix,
                           name: :phoenix_kit_users_reg_country_date_idx
                         )

    create_if_not_exists index(:phoenix_kit_users, [:registration_region, :inserted_at],
                           prefix: prefix,
                           name: :phoenix_kit_users_reg_region_date_idx
                         )

    create_if_not_exists index(:phoenix_kit_users, [:registration_city, :inserted_at],
                           prefix: prefix,
                           name: :phoenix_kit_users_reg_city_date_idx
                         )

    # IP-based queries (for rate limiting and security)
    create_if_not_exists index(:phoenix_kit_users, [:registration_ip, :inserted_at],
                           prefix: prefix,
                           name: :phoenix_kit_users_reg_ip_date_idx
                         )

    # Composite index for geographic distribution queries
    create_if_not_exists index(
                           :phoenix_kit_users,
                           [:registration_country, :registration_region, :registration_city],
                           prefix: prefix,
                           name: :phoenix_kit_users_reg_geo_idx
                         )

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '10'"
  end

  @doc """
  Rollback the V10 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop indexes first
    drop_if_exists index(
                     :phoenix_kit_users,
                     [:registration_country, :registration_region, :registration_city],
                     prefix: prefix,
                     name: :phoenix_kit_users_reg_geo_idx
                   )

    drop_if_exists index(:phoenix_kit_users, [:registration_ip, :inserted_at],
                     prefix: prefix,
                     name: :phoenix_kit_users_reg_ip_date_idx
                   )

    drop_if_exists index(:phoenix_kit_users, [:registration_city, :inserted_at],
                     prefix: prefix,
                     name: :phoenix_kit_users_reg_city_date_idx
                   )

    drop_if_exists index(:phoenix_kit_users, [:registration_region, :inserted_at],
                     prefix: prefix,
                     name: :phoenix_kit_users_reg_region_date_idx
                   )

    drop_if_exists index(:phoenix_kit_users, [:registration_country, :inserted_at],
                     prefix: prefix,
                     name: :phoenix_kit_users_reg_country_date_idx
                   )

    # Remove analytics columns from users table
    alter table(:phoenix_kit_users, prefix: prefix) do
      remove :registration_city
      remove :registration_region
      remove :registration_country
      remove :registration_ip
    end

    # Update version comment on phoenix_kit table
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '9'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
