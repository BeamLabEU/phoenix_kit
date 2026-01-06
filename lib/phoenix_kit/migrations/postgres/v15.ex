defmodule PhoenixKit.Migrations.Postgres.V15 do
  @moduledoc """
  PhoenixKit V15 Migration: Email Templates System

  This migration introduces a comprehensive email templates management system
  that allows storing, managing and using email templates through the admin interface.

  ## Changes

  ### Email Templates System
  - Adds phoenix_kit_email_templates table for template storage and management
  - Supports template variables with {{variable}} syntax
  - Includes template categories (system, marketing, transactional)
  - Template versioning and usage tracking
  - Integration with existing email logging system

  ### New Tables
  - **phoenix_kit_email_templates**: Template storage with metadata, variables, and usage analytics

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Optimized indexes for performance
  - JSONB fields for flexible metadata and variables storage
  """
  use Ecto.Migration

  alias Mix.Tasks.PhoenixKit.SeedTemplates

  @doc """
  Run the V15 migration to add email templates system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Create email templates table
    create_if_not_exists table(:phoenix_kit_email_templates, prefix: prefix) do
      # UUID for external references and DB sync
      add :uuid, :uuid, null: true
      # Template unique name (e.g., "magic_link", "welcome_email")
      add :name, :string, null: false
      # URL-friendly slug for template identification
      add :slug, :string, null: false
      # Human-readable display name
      add :display_name, :string, null: false
      # Template description
      add :description, :text, null: true
      # Email subject line template
      add :subject, :string, null: false
      # HTML version of email body
      add :html_body, :text, null: false
      # Plain text version of email body
      add :text_body, :text, null: false
      # Template category: system, marketing, transactional
      add :category, :string, null: false, default: "transactional"
      # Template status: active, draft, archived
      add :status, :string, null: false, default: "draft"
      # JSONB array of available template variables
      add :variables, :map, null: true, default: %{}
      # JSONB metadata for additional template information
      add :metadata, :map, null: true, default: %{}
      # Usage statistics
      add :usage_count, :integer, null: false, default: 0
      # Last time template was used
      add :last_used_at, :utc_datetime_usec, null: true
      # Template version for tracking changes
      add :version, :integer, null: false, default: 1
      # Whether this is a system template (protected from deletion)
      add :is_system, :boolean, null: false, default: false
      # FK to users who created the template
      add :created_by_user_id, :integer, null: true
      # FK to users who last updated the template
      add :updated_by_user_id, :integer, null: true

      # Timestamps for tracking record creation/update
      timestamps(type: :utc_datetime_usec)
    end

    # Create unique indexes
    create_if_not_exists unique_index(:phoenix_kit_email_templates, [:name], prefix: prefix)
    create_if_not_exists unique_index(:phoenix_kit_email_templates, [:slug], prefix: prefix)

    # Create performance indexes
    create_if_not_exists index(:phoenix_kit_email_templates, [:category], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_email_templates, [:status], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_email_templates, [:is_system], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_email_templates, [:usage_count], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_email_templates, [:last_used_at], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_email_templates, [:inserted_at], prefix: prefix)

    # Create composite indexes for common queries
    create_if_not_exists index(:phoenix_kit_email_templates, [:category, :status], prefix: prefix)

    create_if_not_exists index(:phoenix_kit_email_templates, [:status, :is_system],
                           prefix: prefix
                         )

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '15'"

    # Flush all DDL changes before seeding data
    flush()

    # Automatically seed system email templates after table creation
    seed_system_templates()
  end

  @doc """
  Rollback the V15 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop indexes first
    drop_if_exists index(:phoenix_kit_email_templates, [:status, :is_system], prefix: prefix)
    drop_if_exists index(:phoenix_kit_email_templates, [:category, :status], prefix: prefix)
    drop_if_exists index(:phoenix_kit_email_templates, [:inserted_at], prefix: prefix)
    drop_if_exists index(:phoenix_kit_email_templates, [:last_used_at], prefix: prefix)
    drop_if_exists index(:phoenix_kit_email_templates, [:usage_count], prefix: prefix)
    drop_if_exists index(:phoenix_kit_email_templates, [:is_system], prefix: prefix)
    drop_if_exists index(:phoenix_kit_email_templates, [:status], prefix: prefix)
    drop_if_exists index(:phoenix_kit_email_templates, [:category], prefix: prefix)
    drop_if_exists unique_index(:phoenix_kit_email_templates, [:slug], prefix: prefix)
    drop_if_exists unique_index(:phoenix_kit_email_templates, [:name], prefix: prefix)

    # Drop table
    drop_if_exists table(:phoenix_kit_email_templates, prefix: prefix)

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '14'"
  end

  # Private function to seed system email templates
  defp seed_system_templates do
    case Code.ensure_loaded(SeedTemplates) do
      {:module, _} ->
        try do
          SeedTemplates.run(["--quiet"])
        rescue
          error ->
            # Log the error but don't fail the migration
            IO.puts("Warning: Could not seed email templates: #{inspect(error)}")
            :ok
        end

      {:error, _} ->
        # Mix tasks may not be available in production builds
        IO.puts("Info: SeedTemplates not available - skipping template seeding")

        :ok
    end
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
