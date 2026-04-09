defmodule PhoenixKit.Migrations.Postgres.V91 do
  @moduledoc """
  V91: Add Locations tables.

  Creates the three tables needed by the PhoenixKitLocations module:
  - `phoenix_kit_location_types` — user-defined location categories (Showroom, Storage, etc.)
  - `phoenix_kit_locations` — physical locations with full address, contact, features
  - `phoenix_kit_location_type_assignments` — many-to-many join (a location can have multiple types)
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # ── Location Types ─────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_location_types,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_location_types, [:status], prefix: prefix))

    # ── Locations ──────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_locations,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:public_notes, :text)

      # Address (international standard)
      add(:address_line_1, :string, size: 500)
      add(:address_line_2, :string, size: 500)
      add(:city, :string, size: 255)
      add(:state, :string, size: 255)
      add(:postal_code, :string, size: 20)
      add(:country, :string, size: 255)

      # Contact
      add(:phone, :string, size: 50)
      add(:email, :string, size: 255)
      add(:website, :string, size: 500)

      # Internal
      add(:notes, :text)
      add(:status, :string, default: "active", size: 20)

      # Features (JSONB with boolean flags)
      add(:features, :map, default: %{})

      # Multilang translations
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_locations, [:status], prefix: prefix))

    # ── Location ↔ Type join (many-to-many) ────────────────────────
    create_if_not_exists table(:phoenix_kit_location_type_assignments,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :location_uuid,
        references(:phoenix_kit_locations,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :location_type_uuid,
        references(:phoenix_kit_location_types,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      unique_index(
        :phoenix_kit_location_type_assignments,
        [:location_uuid, :location_type_uuid],
        prefix: prefix
      )
    )

    # ── Idempotent column additions (for existing V90 installs) ────
    execute("""
    DO $$
    BEGIN
      -- Drop old columns that were renamed/removed
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'location_type_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations DROP COLUMN location_type_uuid;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'address'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations RENAME COLUMN address TO address_line_1;
      END IF;

      -- Add new columns if missing
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'description'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN description TEXT;
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'public_notes'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN public_notes TEXT;
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'address_line_2'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN address_line_2 VARCHAR(500);
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'state'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN state VARCHAR(255);
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'postal_code'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN postal_code VARCHAR(20);
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'website'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN website VARCHAR(500);
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'features'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN features JSONB NOT NULL DEFAULT '{}';
      END IF;

      -- Drop unique index on location_types.name if exists (names don't need to be unique)
      IF EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_location_types'
          AND indexname = 'phoenix_kit_location_types_name_index'
      ) THEN
        DROP INDEX #{p}phoenix_kit_location_types_name_index;
      END IF;

      -- Fix address_line_1 type if it was created as text (from early V90)
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_locations'
          AND column_name = 'address_line_1'
          AND data_type = 'text'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_locations
          ALTER COLUMN address_line_1 TYPE VARCHAR(500);
      END IF;
    END $$;
    """)

    # Index on location_uuid for type assignment lookups
    create_if_not_exists(
      index(:phoenix_kit_location_type_assignments, [:location_uuid], prefix: prefix)
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '91'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_location_type_assignments, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_locations, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_location_types, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '90'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
