defmodule PhoenixKit.Migrations.Postgres.V17 do
  @moduledoc """
  PhoenixKit V17 Migration: Entities System (Dynamic Content Types)

  This migration adds the dynamic entities system for creating custom content types
  with flexible field schemas.
  It also introduces `display_name_plural` to improve UI labelling for collections.

  ## Changes

  ### Entities Table (phoenix_kit_entities)
  - Stores entity type definitions (content type blueprints)
  - Includes singular and plural display names
  - JSONB `fields_definition` for flexible field schemas
  - JSONB `settings` for entity-specific configuration
  - Supports dynamic content types like blog posts, products, team members, etc.

  ### Entity Data Table (phoenix_kit_entity_data)
  - Stores actual records based on entity blueprints
  - JSONB `data` column for field values
  - JSONB `metadata` for additional information
  - Generic columns for common fields (title, slug, status)

  ### Settings Seeds
  - Inserts default entities-related settings (`entities_enabled`, etc.)

  ## PostgreSQL Support
  - Leverages PostgreSQL's native JSONB data type
  - Supports prefix for schema isolation
  - Indexes on frequently queried columns
  - Foreign key relationships
  """
  use Ecto.Migration

  @doc """
  Run the V17 migration to add the entities system.
  """
  def up(%{prefix: prefix} = _opts) do
    create_if_not_exists table(:phoenix_kit_entities, prefix: prefix) do
      add :name, :string, null: false
      add :display_name, :string, null: false
      add :display_name_plural, :string
      add :description, :text
      add :icon, :string
      add :status, :string, null: false, default: "draft"
      add :fields_definition, :map, null: false, default: "[]"
      add :settings, :map, null: true
      add :created_by, :integer, null: false
      add :date_created, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :date_updated, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create_if_not_exists unique_index(:phoenix_kit_entities, [:name],
                           name: :phoenix_kit_entities_name_uidx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_entities, [:created_by],
                           name: :phoenix_kit_entities_created_by_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_entities, [:status],
                           name: :phoenix_kit_entities_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists table(:phoenix_kit_entity_data, prefix: prefix) do
      add :entity_id, :integer, null: false
      add :title, :string, null: false
      add :slug, :string
      add :status, :string, null: false, default: "draft"
      add :data, :map, null: false, default: "{}"
      add :metadata, :map, null: true
      add :created_by, :integer, null: false
      add :date_created, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :date_updated, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create_if_not_exists index(:phoenix_kit_entity_data, [:entity_id],
                           name: :phoenix_kit_entity_data_entity_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_entity_data, [:slug],
                           name: :phoenix_kit_entity_data_slug_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_entity_data, [:status],
                           name: :phoenix_kit_entity_data_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_entity_data, [:created_by],
                           name: :phoenix_kit_entity_data_created_by_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_entity_data, [:title],
                           name: :phoenix_kit_entity_data_title_idx,
                           prefix: prefix
                         )

    # Add foreign key constraint only if it doesn't exist
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_entity_data_entity_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_entity_data", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_entity_data", prefix)}
        ADD CONSTRAINT phoenix_kit_entity_data_entity_id_fkey
        FOREIGN KEY (entity_id)
        REFERENCES #{prefix_table_name("phoenix_kit_entities", prefix)}(id)
        ON DELETE CASCADE;
      END IF;
    END $$;
    """

    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)} (key, value, module, date_added, date_updated)
    VALUES
      ('entities_enabled', 'false', 'entities', NOW(), NOW()),
      ('entities_max_per_user', '100', 'entities', NOW(), NOW()),
      ('entities_allow_relations', 'true', 'entities', NOW(), NOW()),
      ('entities_file_upload', 'false', 'entities', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_entities", prefix)}.fields_definition IS
    'JSONB array of field definitions. Each field has type, key, label, validation rules.'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_entities", prefix)}.settings IS
    'JSONB storage for entity-specific settings (permissions, display options, etc.).'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_entities", prefix)}.display_name_plural IS
    'Plural form of the entity display name (e.g., "Blog Posts" for "Blog Post"). Used in UI for collections and navigation.'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_entity_data", prefix)}.data IS
    'JSONB storage for all field values based on entity definition. Structure matches fields_definition.'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_entity_data", prefix)}.metadata IS
    'JSONB storage for additional metadata (tags, categories, search keywords, etc.).'
    """

    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '17'"
  end

  @doc """
  Rollback the V17 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop foreign key constraint if it exists
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_entity_data_entity_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_entity_data", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_entity_data", prefix)}
        DROP CONSTRAINT phoenix_kit_entity_data_entity_id_fkey;
      END IF;
    END $$;
    """

    drop_if_exists index(:phoenix_kit_entity_data, [:title],
                     name: :phoenix_kit_entity_data_title_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_entity_data, [:created_by],
                     name: :phoenix_kit_entity_data_created_by_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_entity_data, [:status],
                     name: :phoenix_kit_entity_data_status_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_entity_data, [:slug],
                     name: :phoenix_kit_entity_data_slug_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_entity_data, [:entity_id],
                     name: :phoenix_kit_entity_data_entity_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_entities, [:status],
                     name: :phoenix_kit_entities_status_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_entities, [:created_by],
                     name: :phoenix_kit_entities_created_by_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_entities, [:name],
                     name: :phoenix_kit_entities_name_uidx,
                     prefix: prefix
                   )

    drop_if_exists table(:phoenix_kit_entity_data, prefix: prefix)
    drop_if_exists table(:phoenix_kit_entities, prefix: prefix)

    execute """
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key IN ('entities_enabled', 'entities_max_per_user', 'entities_allow_relations', 'entities_file_upload')
    """

    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '16'"
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
