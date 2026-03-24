defmodule PhoenixKit.Migrations.Postgres.V87 do
  @moduledoc """
  V87: Add Catalogue tables.

  Creates the six tables needed by the PhoenixKitCatalogue module:
  - `phoenix_kit_cat_manufacturers` — manufacturer directory
  - `phoenix_kit_cat_suppliers` — supplier directory
  - `phoenix_kit_cat_manufacturer_suppliers` — many-to-many join
  - `phoenix_kit_cat_catalogues` — top-level catalogue groupings
  - `phoenix_kit_cat_categories` — subdivisions within a catalogue
  - `phoenix_kit_cat_items` — individual products/materials
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # ── Manufacturers ──────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_cat_manufacturers,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:website, :string, size: 500)
      add(:contact_info, :string, size: 500)
      add(:logo_url, :string, size: 500)
      add(:notes, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_manufacturers, [:status], prefix: prefix))

    # ── Suppliers ──────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_cat_suppliers,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:website, :string, size: 500)
      add(:contact_info, :string, size: 500)
      add(:notes, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_suppliers, [:status], prefix: prefix))

    # ── Manufacturer ↔ Supplier join ──────────────────────────────
    create_if_not_exists table(:phoenix_kit_cat_manufacturer_suppliers,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :manufacturer_uuid,
        references(:phoenix_kit_cat_manufacturers,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :supplier_uuid,
        references(:phoenix_kit_cat_suppliers,
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
        :phoenix_kit_cat_manufacturer_suppliers,
        [:manufacturer_uuid, :supplier_uuid],
        prefix: prefix
      )
    )

    # ── Catalogues ─────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_cat_catalogues,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_catalogues, [:status], prefix: prefix))

    # ── Categories ─────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_cat_categories,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:position, :integer, default: 0)
      add(:status, :string, default: "active", size: 20)

      add(
        :catalogue_uuid,
        references(:phoenix_kit_cat_catalogues,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_categories, [:catalogue_uuid], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_cat_categories, [:catalogue_uuid, :position], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_cat_categories, [:status], prefix: prefix))

    # ── Items ──────────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_cat_items,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:sku, :string, size: 100)
      add(:price, :decimal, precision: 12, scale: 2)
      add(:unit, :string, default: "piece", size: 20)
      add(:status, :string, default: "active", size: 20)

      add(
        :category_uuid,
        references(:phoenix_kit_cat_categories,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(
        :manufacturer_uuid,
        references(:phoenix_kit_cat_manufacturers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_cat_items, [:sku],
        prefix: prefix,
        where: "sku IS NOT NULL"
      )
    )

    create_if_not_exists(index(:phoenix_kit_cat_items, [:category_uuid], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_cat_items, [:manufacturer_uuid], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_cat_items, [:status], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '87'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_cat_items, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_categories, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_catalogues, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_manufacturer_suppliers, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_suppliers, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_manufacturers, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '86'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
