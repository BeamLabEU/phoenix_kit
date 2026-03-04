defmodule PhoenixKit.Migrations.Postgres.V76 do
  @moduledoc """
  V76: Rename stale `_id` columns/keys to `_uuid`.

  The UUID migration (V54–V59) renamed all DB columns from `_id` to `_uuid`,
  but a few JSONB keys, settings rows, and one column still use the old `_id`
  naming. This migration aligns them.

  ## Changes

  1. **Rename column**: `phoenix_kit_shop_products.image_ids` → `image_uuids`
  2. **Rename JSONB key**: `phoenix_kit_users.custom_fields.avatar_file_id` → `avatar_file_uuid`
  3. **Rename settings key**: `publishing_translation_endpoint_id` → `…_uuid`
  4. **Rename settings key**: `storage_default_bucket_id` → `…_uuid`
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    flush()

    # 1. Rename product column
    if column_exists?("phoenix_kit_shop_products", "image_ids", prefix) do
      execute("""
      ALTER TABLE #{prefix_table("phoenix_kit_shop_products", prefix)}
        RENAME COLUMN image_ids TO image_uuids
      """)
    end

    # 2. Rename JSONB key in users custom_fields
    execute("""
    UPDATE #{prefix_table("phoenix_kit_users", prefix)}
    SET custom_fields = custom_fields - 'avatar_file_id'
      || jsonb_build_object('avatar_file_uuid', custom_fields->'avatar_file_id')
    WHERE custom_fields ? 'avatar_file_id'
    """)

    # 3. Rename settings keys
    execute("""
    UPDATE #{prefix_table("phoenix_kit_settings", prefix)}
    SET key = 'publishing_translation_endpoint_uuid'
    WHERE key = 'publishing_translation_endpoint_id'
    """)

    execute("""
    UPDATE #{prefix_table("phoenix_kit_settings", prefix)}
    SET key = 'storage_default_bucket_uuid'
    WHERE key = 'storage_default_bucket_id'
    """)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '76'")
  end

  def down(%{prefix: prefix} = _opts) do
    # Reverse column rename
    if column_exists?("phoenix_kit_shop_products", "image_uuids", prefix) do
      execute("""
      ALTER TABLE #{prefix_table("phoenix_kit_shop_products", prefix)}
        RENAME COLUMN image_uuids TO image_ids
      """)
    end

    # Reverse JSONB key rename
    execute("""
    UPDATE #{prefix_table("phoenix_kit_users", prefix)}
    SET custom_fields = custom_fields - 'avatar_file_uuid'
      || jsonb_build_object('avatar_file_id', custom_fields->'avatar_file_uuid')
    WHERE custom_fields ? 'avatar_file_uuid'
    """)

    # Reverse settings keys
    execute("""
    UPDATE #{prefix_table("phoenix_kit_settings", prefix)}
    SET key = 'publishing_translation_endpoint_id'
    WHERE key = 'publishing_translation_endpoint_uuid'
    """)

    execute("""
    UPDATE #{prefix_table("phoenix_kit_settings", prefix)}
    SET key = 'storage_default_bucket_id'
    WHERE key = 'storage_default_bucket_uuid'
    """)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '75'")
  end

  defp column_exists?(table, column, prefix) do
    escaped_prefix = prefix || "public"

    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table}'
             AND column_name = '#{column}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
