defmodule PhoenixKit.Migrations.Postgres.V30 do
  @moduledoc """
  Migration V30: Move preferred_locale from column to custom_fields JSONB.

  This migration removes the dedicated `preferred_locale` column and stores
  the value in the existing `custom_fields` JSONB column instead. This reduces
  schema complexity by leveraging the flexible JSONB storage for user preferences.

  ## Changes
  - Migrates existing `preferred_locale` values into `custom_fields` JSONB
  - Drops the `preferred_locale` index
  - Drops the `preferred_locale` column

  ## Requirements
  - PostgreSQL database
  - PhoenixKit V29 or higher
  - The `custom_fields` JSONB column must exist (added in V18)

  ## Data Migration
  Existing preferred_locale values are preserved by copying them into custom_fields:
  - `user.preferred_locale = "en-GB"` becomes `user.custom_fields["preferred_locale"] = "en-GB"`
  - NULL values are not migrated (same behavior: use system default)

  ## Backward Compatibility
  - Reading: `get_in(user.custom_fields, ["preferred_locale"])` or `user.custom_fields["preferred_locale"]`
  - Writing: Merge into custom_fields map
  - NULL handling: Missing key = use system default (same as before)

  ## Rollback
  The down migration restores the column and migrates data back from custom_fields.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    # Step 1: Migrate existing preferred_locale data to custom_fields
    execute """
    UPDATE #{prefix_table_name("phoenix_kit_users", prefix)}
    SET custom_fields = COALESCE(custom_fields, '{}'::jsonb) || jsonb_build_object('preferred_locale', preferred_locale)
    WHERE preferred_locale IS NOT NULL
    """

    # Step 2: Drop the index on preferred_locale
    drop_if_exists index(:phoenix_kit_users, [:preferred_locale], prefix: prefix)

    # Step 3: Drop the preferred_locale column
    alter table(:phoenix_kit_users, prefix: prefix) do
      remove :preferred_locale
    end

    # Update version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '30'"
  end

  def down(%{prefix: prefix} = _opts) do
    # Step 1: Add the column back
    alter table(:phoenix_kit_users, prefix: prefix) do
      add :preferred_locale, :string, size: 10
    end

    # Step 2: Create the index
    create index(:phoenix_kit_users, [:preferred_locale], prefix: prefix)

    # Step 3: Migrate data from custom_fields back to the column
    execute """
    UPDATE #{prefix_table_name("phoenix_kit_users", prefix)}
    SET preferred_locale = custom_fields->>'preferred_locale'
    WHERE custom_fields->>'preferred_locale' IS NOT NULL
    """

    # Step 4: Remove the key from custom_fields
    execute """
    UPDATE #{prefix_table_name("phoenix_kit_users", prefix)}
    SET custom_fields = custom_fields - 'preferred_locale'
    WHERE custom_fields ? 'preferred_locale'
    """

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '29'"
  end

  # Helper functions

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
