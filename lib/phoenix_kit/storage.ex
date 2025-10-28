defmodule PhoenixKit.Storage do
  @moduledoc """
  Storage context for managing files, buckets, and dimensions.

  This is a TEMPORARY mock implementation for Phase 2 testing.
  Will be replaced with full implementation in Phase 3.
  """

  import Ecto.Query, warn: false
  alias PhoenixKit.Repo

  alias PhoenixKit.Storage.Bucket
  alias PhoenixKit.Storage.Dimension
  # alias PhoenixKit.Storage.File

  # ===== BUCKETS =====

  def list_buckets do
    # Mock data for Phase 2 testing
    [
      %{
        id: "550e8400-e29b-41d4-a716-446655440001",
        name: "Local Storage",
        provider: "local",
        endpoint: nil,
        region: nil,
        bucket_name: "uploads",
        access_key_id: nil,
        secret_access_key: nil,
        cdn_url: nil,
        path_prefix: "priv/uploads",
        enabled: true,
        priority: 1,
        max_size_mb: 1000,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "550e8400-e29b-41d4-a716-446655440002",
        name: "AWS S3 Backup",
        provider: "s3",
        endpoint: "s3.amazonaws.com",
        region: "us-east-1",
        bucket_name: "my-app-backup",
        access_key_id: "AKIA...",
        secret_access_key: "***",
        cdn_url: "https://d123.cloudfront.net",
        path_prefix: "uploads",
        enabled: false,
        priority: 2,
        max_size_mb: 5000,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ]
  end

  def get_bucket(id) when is_binary(id) do
    list_buckets()
    |> Enum.find(&(&1.id == id))
  end

  def get_bucket(_id), do: nil

  def create_bucket(attrs \\ %{}) do
    # Mock implementation - returns a changeset-like result
    mock_bucket = %{
      id: generate_mock_id(),
      name: attrs["name"] || attrs[:name] || "New Bucket",
      provider: attrs["provider"] || attrs[:provider] || "local",
      endpoint: attrs["endpoint"] || attrs[:endpoint],
      region: attrs["region"] || attrs[:region],
      bucket_name: attrs["bucket_name"] || attrs[:bucket_name],
      access_key_id: attrs["access_key_id"] || attrs[:access_key_id],
      secret_access_key: attrs["secret_access_key"] || attrs[:secret_access_key],
      cdn_url: attrs["cdn_url"] || attrs[:cdn_url],
      path_prefix: attrs["path_prefix"] || attrs[:path_prefix],
      enabled: attrs["enabled"] || attrs[:enabled] || true,
      priority: attrs["priority"] || attrs[:priority] || 1,
      max_size_mb: attrs["max_size_mb"] || attrs[:max_size_mb] || 1000,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    {:ok, mock_bucket}
  end

  def update_bucket(bucket, attrs) when is_map(bucket) do
    updated_bucket = Map.merge(bucket, Map.new(attrs))
    {:ok, %{updated_bucket | updated_at: DateTime.utc_now()}}
  end

  def delete_bucket(_bucket) do
    {:ok, %{}}
  end

  def calculate_bucket_usage(_bucket_id) do
    # Mock usage data
    :rand.uniform(100) # Returns random usage between 1-100 MB
  end

  def calculate_bucket_free_space(_bucket) do
    # Mock free space
    :rand.uniform(1000) # Returns random free space between 1-1000 MB
  end

  # ===== DIMENSIONS =====

  def list_dimensions do
    # Mock seeded dimensions
    [
      %{
        id: "750e8400-e29b-41d4-a716-446655440001",
        name: "thumbnail",
        width: 150,
        height: 150,
        quality: 85,
        format: "jpg",
        applies_to: "image",
        enabled: true,
        order: 1,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "750e8400-e29b-41d4-a716-446655440002",
        name: "small",
        width: 300,
        height: 300,
        quality: 85,
        format: nil,
        applies_to: "image",
        enabled: true,
        order: 2,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "750e8400-e29b-41d4-a716-446655440003",
        name: "medium",
        width: 800,
        height: 600,
        quality: 85,
        format: nil,
        applies_to: "image",
        enabled: true,
        order: 3,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "750e8400-e29b-41d4-a716-446655440004",
        name: "large",
        width: 1920,
        height: 1080,
        quality: 85,
        format: nil,
        applies_to: "image",
        enabled: true,
        order: 4,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "750e8400-e29b-41d4-a716-446655440005",
        name: "360p",
        width: 640,
        height: 360,
        quality: 25,
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 5,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "750e8400-e29b-41d4-a716-446655440006",
        name: "720p",
        width: 1280,
        height: 720,
        quality: 23,
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 6,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "750e8400-e29b-41d4-a716-446655440007",
        name: "1080p",
        width: 1920,
        height: 1080,
        quality: 20,
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 7,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      },
      %{
        id: "750e8400-e29b-41d4-a716-446655440008",
        name: "video_thumbnail",
        width: 640,
        height: 360,
        quality: 70,
        format: "jpg",
        applies_to: "video",
        enabled: true,
        order: 8,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ]
  end

  def get_dimension(id) when is_binary(id) do
    list_dimensions()
    |> Enum.find(&(&1.id == id))
  end

  def get_dimension(_id), do: nil

  def create_dimension(attrs \\ %{}) do
    # Mock validation for required fields
    name = attrs["name"] || attrs[:name]
    applies_to = attrs["applies_to"] || attrs[:applies_to]

    if is_nil(name) or name == "" do
      # Return error-like changeset
      {:error, %{errors: [name: {"can't be blank", []}]}}
    else
      mock_dimension = %{
        id: generate_mock_id(),
        name: name,
        width: attrs["width"] || attrs[:width],
        height: attrs["height"] || attrs[:height],
        quality: attrs["quality"] || attrs[:quality] || 85,
        format: attrs["format"] || attrs[:format],
        applies_to: applies_to || "image",
        enabled: attrs["enabled"] || attrs[:enabled] || true,
        order: attrs["order"] || attrs[:order] || 1,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, mock_dimension}
    end
  end

  def update_dimension(dimension, attrs) when is_map(dimension) do
    updated_dimension = Map.merge(dimension, Map.new(attrs))
    {:ok, %{updated_dimension | updated_at: DateTime.utc_now()}}
  end

  def delete_dimension(_dimension) do
    {:ok, %{}}
  end

  # ===== FILES =====
  # (These will be implemented in Phase 3)

  def list_files(_bucket_id \\ nil, _opts \\ []) do
    []
  end

  def get_file(_id), do: nil

  def create_file(_attrs) do
    {:ok, %{}}
  end

  def update_file(_file, _attrs) do
    {:ok, %{}}
  end

  def delete_file(_file) do
    {:ok, %{}}
  end

  # ===== CONFIGURATION =====

  def get_config do
    %{
      default_path: "priv/uploads",
      redundancy_copies: 2,
      auto_generate_variants: true,
      default_bucket_id: nil
    }
  end

  def get_absolute_path do
    config = get_config()
    Path.expand(config.default_path, File.cwd!())
  end

  def validate_and_normalize_path(path) when is_binary(path) do
    # Basic validation - in Phase 3 this will be more sophisticated
    expanded_path = Path.expand(path, File.cwd!())

    if File.exists?(expanded_path) do
      relative_path = Path.relative_to(expanded_path, File.cwd!())
      {:ok, relative_path}
    else
      {:error, :does_not_exist, expanded_path}
    end
  end

  def validate_and_normalize_path(_path), do: {:error, :invalid_path}

  def update_default_path(relative_path) when is_binary(relative_path) do
    # Mock update - in Phase 3 this will update the database
    PhoenixKit.Settings.update_setting("storage_default_path", relative_path)
  end

  def create_directory(path) when is_binary(path) do
    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_directory(_path), do: {:error, :invalid_path}

  # ===== HELPER FUNCTIONS =====

  # Generate mock UUID-like IDs for testing
  defp generate_mock_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end