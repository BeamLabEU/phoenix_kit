defmodule PhoenixKit.Migrations.Postgres.V19 do
  @moduledoc """
  PhoenixKit V19 Migration: Distributed File Storage System

  Adds comprehensive distributed file storage with multi-location redundancy,
  automatic variant generation, and smart volume selection.

  ## Changes

  ### Storage Buckets Table (phoenix_kit_buckets)
  - Stores storage provider configurations (local, S3, B2, R2)
  - Priority-based volume selection (0 = random/emptiest, >0 = specific priority)
  - Tracks max capacity and credentials per bucket

  ### Files Table (phoenix_kit_files)
  - Original file uploads with metadata
  - Supports images, videos, documents, archives
  - JSONB metadata for EXIF, codec info, etc.
  - Links to user for ownership tracking

  ### File Instances Table (phoenix_kit_file_instances)
  - File variants (thumbnails, resizes, video qualities)
  - Tracks processing status per variant
  - One original + multiple generated variants

  ### File Locations Table (phoenix_kit_file_locations)
  - Physical storage locations for redundancy
  - Maps instances to specific buckets
  - Supports 1-5 redundant copies across buckets

  ### Storage Dimensions Table (phoenix_kit_storage_dimensions)
  - Admin-configurable dimension presets
  - Seeded with defaults: thumbnail, small, medium, large, 360p, 720p, 1080p
  - Applies to images, videos, or both

  ## Features

  - **UUIDv7 Primary Keys**: Time-sortable IDs for all storage tables
  - **Multi-location Redundancy**: Store files across multiple buckets
  - **Smart Volume Selection**: Priority system + emptiest drive selection
  - **Token-based URLs**: Secure file access preventing enumeration
  - **Automatic Variants**: Generate thumbnails, resizes, video qualities
  - **PostgreSQL JSONB**: Flexible metadata storage

  ## Settings

  - `storage_redundancy_copies`: How many bucket copies (default: 2)
  - `storage_auto_generate_variants`: Auto-generate thumbnails/resizes (default: true)
  - `storage_default_bucket_id`: Default bucket for uploads (optional)
  """
  use Ecto.Migration

  @doc """
  Run the V19 migration to add distributed storage system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Create storage buckets table
    create_if_not_exists table(:phoenix_kit_buckets, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :provider, :string, null: false
      add :region, :string
      add :endpoint, :string
      add :bucket_name, :string
      add :access_key_id, :string
      add :secret_access_key, :string
      add :cdn_url, :string
      add :path_prefix, :string
      add :enabled, :boolean, default: true, null: false
      add :priority, :integer, default: 0, null: false
      add :max_size_mb, :bigint

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_buckets, [:enabled], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_buckets, [:provider], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_buckets", prefix)} IS
    'Storage provider configurations (local, AWS S3, Backblaze B2, Cloudflare R2)'
    """

    # Create files table
    create_if_not_exists table(:phoenix_kit_files, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true
      add :original_file_name, :string, null: false
      add :file_name, :string, null: false
      add :mime_type, :string, null: false
      add :file_type, :string, null: false
      add :ext, :string, null: false
      add :checksum, :string, null: false
      add :size, :bigint, null: false
      add :width, :integer
      add :height, :integer
      add :duration, :integer
      add :status, :string, null: false, default: "processing"
      add :metadata, :map

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_files, [:user_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_files, [:file_type], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_files, [:status], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_files, [:inserted_at], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_files", prefix)} IS
    'Original file uploads with metadata (images, videos, documents, archives)'
    """

    # Create file instances table
    create_if_not_exists table(:phoenix_kit_file_instances, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true
      add :variant_name, :string, null: false
      add :file_name, :string, null: false
      add :mime_type, :string, null: false
      add :ext, :string, null: false
      add :checksum, :string, null: false
      add :size, :bigint, null: false
      add :width, :integer
      add :height, :integer
      add :processing_status, :string, null: false, default: "pending"

      add :file_id,
          references(:phoenix_kit_files, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_file_instances, [:file_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_file_instances, [:variant_name], prefix: prefix)

    create_if_not_exists index(:phoenix_kit_file_instances, [:processing_status], prefix: prefix)

    create_if_not_exists unique_index(:phoenix_kit_file_instances, [:file_id, :variant_name],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_file_instances", prefix)} IS
    'File variants (thumbnails, resizes, video qualities) - one original + generated variants'
    """

    # Create file locations table
    create_if_not_exists table(:phoenix_kit_file_locations, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true
      add :path, :string, null: false
      add :status, :string, null: false, default: "active"
      add :priority, :integer, default: 0, null: false
      add :last_verified_at, :naive_datetime

      add :file_instance_id,
          references(:phoenix_kit_file_instances,
            on_delete: :delete_all,
            prefix: prefix,
            type: :uuid
          ),
          null: false

      add :bucket_id,
          references(:phoenix_kit_buckets, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_file_locations, [:file_instance_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_file_locations, [:bucket_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_file_locations, [:status], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_file_locations", prefix)} IS
    'Physical storage locations for multi-location redundancy - maps instances to buckets'
    """

    # Create storage dimensions table
    create_if_not_exists table(:phoenix_kit_storage_dimensions,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :width, :integer
      add :height, :integer
      add :quality, :integer, default: 85, null: false
      add :format, :string
      add :applies_to, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :order, :integer, default: 0, null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_storage_dimensions, [:enabled], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_storage_dimensions, [:order], prefix: prefix)

    create_if_not_exists unique_index(:phoenix_kit_storage_dimensions, [:name], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_storage_dimensions", prefix)} IS
    'Admin-configurable dimension presets for automatic variant generation'
    """

    # Seed default dimensions
    seed_default_dimensions(prefix)

    # Seed default local bucket
    seed_default_bucket(prefix)

    # Add storage settings
    insert_setting(prefix, "storage_redundancy_copies", "2")
    insert_setting(prefix, "storage_auto_generate_variants", "true")
    insert_setting(prefix, "storage_default_bucket_id", nil)

    # Update version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '19'"
  end

  @doc """
  Rollback the V19 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop tables in reverse order (respecting foreign keys)
    drop_if_exists table(:phoenix_kit_file_locations, prefix: prefix)
    drop_if_exists table(:phoenix_kit_file_instances, prefix: prefix)
    drop_if_exists table(:phoenix_kit_files, prefix: prefix)
    drop_if_exists table(:phoenix_kit_storage_dimensions, prefix: prefix)
    drop_if_exists table(:phoenix_kit_buckets, prefix: prefix)

    # Remove settings
    delete_setting(prefix, "storage_redundancy_copies")
    delete_setting(prefix, "storage_auto_generate_variants")
    delete_setting(prefix, "storage_default_bucket_id")

    # Update version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '18'"
  end

  # Private helper functions

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  defp seed_default_dimensions(prefix) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    dimensions = [
      # Image dimensions
      %{
        name: "thumbnail",
        width: 150,
        height: 150,
        quality: 85,
        format: "jpg",
        applies_to: "image",
        enabled: true,
        order: 1
      },
      %{
        name: "small",
        width: 300,
        height: 300,
        quality: 85,
        format: "jpg",
        applies_to: "image",
        enabled: true,
        order: 2
      },
      %{
        name: "medium",
        width: 800,
        height: 600,
        quality: 85,
        format: "jpg",
        applies_to: "image",
        enabled: true,
        order: 3
      },
      %{
        name: "large",
        width: 1920,
        height: 1080,
        quality: 85,
        format: "jpg",
        applies_to: "image",
        enabled: true,
        order: 4
      },
      # Video quality dimensions
      %{
        name: "360p",
        width: 640,
        height: 360,
        quality: 28,
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 5
      },
      %{
        name: "720p",
        width: 1280,
        height: 720,
        quality: 28,
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 6
      },
      %{
        name: "1080p",
        width: 1920,
        height: 1080,
        quality: 28,
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 7
      },
      # Video thumbnail
      %{
        name: "video_thumbnail",
        width: 640,
        height: 360,
        quality: 85,
        format: "jpg",
        applies_to: "video",
        enabled: true,
        order: 8
      }
    ]

    Enum.each(dimensions, fn dim ->
      id = generate_uuidv7()

      execute """
      INSERT INTO #{prefix_table_name("phoenix_kit_storage_dimensions", prefix)}
      (id, name, width, height, quality, format, applies_to, enabled, "order", inserted_at, updated_at)
      VALUES ('#{id}', '#{dim.name}', #{dim.width}, #{dim.height}, #{dim.quality}, '#{dim.format}', '#{dim.applies_to}', #{dim.enabled}, #{dim.order}, '#{now}', '#{now}')
      ON CONFLICT (name) DO NOTHING
      """
    end)
  end

  defp seed_default_bucket(prefix) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    id = generate_uuidv7()

    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_buckets", prefix)}
    (id, name, provider, enabled, priority, inserted_at, updated_at)
    VALUES ('#{id}', 'Local Storage', 'local', true, 0, '#{now}', '#{now}')
    """
  end

  defp insert_setting(prefix, key, value) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    value_sql = if value == nil, do: "NULL", else: "'#{value}'"

    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)}
    (key, value, date_added, date_updated)
    VALUES ('#{key}', #{value_sql}, '#{now}', '#{now}')
    ON CONFLICT (key) DO NOTHING
    """
  end

  defp delete_setting(prefix, key) do
    execute """
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key = '#{key}'
    """
  end

  defp generate_uuidv7 do
    # Generate UUIDv7 using uuidv7 package
    UUIDv7.generate()
  end
end
