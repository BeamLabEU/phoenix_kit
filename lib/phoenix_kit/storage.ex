defmodule PhoenixKit.Storage do
  @moduledoc """
  Storage context for managing files, buckets, and dimensions.

  Provides a distributed file storage system with support for multiple storage providers
  (local filesystem, AWS S3, Backblaze B2, Cloudflare R2) with automatic redundancy
  and failover capabilities.

  ## Features

  - Multi-location storage with configurable redundancy (1-5 copies)
  - Support for local, S3, B2, and R2 storage providers
  - Automatic variant generation for images and videos
  - Priority-based storage selection
  - Built-in usage tracking and statistics
  - PostgreSQL-backed file registry
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage.Bucket
  alias PhoenixKit.Storage.Dimension
  alias PhoenixKit.Storage.FileInstance
  alias PhoenixKit.Storage.FileLocation
  alias PhoenixKit.Storage.Manager
  # NOTE: Temporary helper for blogging component system.
  # The dedicated storage/media APIs under development should replace this fallback once available.
  alias PhoenixKit.Storage.URLSigner
  alias PhoenixKit.Storage.VariantGenerator
  alias PhoenixKit.Storage.Workers.ProcessFileJob

  # ===== BUCKETS =====

  @doc """
  Returns a list of all storage buckets, ordered by priority.
  """
  def list_buckets do
    Bucket
    |> order_by(asc: :priority)
    |> repo().all()
  end

  @doc """
  Gets a single bucket by ID.

  Returns `nil` if bucket does not exist.
  """
  def get_bucket(id), do: repo().get(Bucket, id)

  @doc """
  Gets a bucket by name.
  """
  def get_bucket_by_name(name) do
    repo().get_by(Bucket, name: name)
  end

  @doc """
  Gets enabled buckets, ordered by priority.
  """
  def list_enabled_buckets do
    Bucket
    |> where([b], b.enabled == true)
    |> order_by(asc: :priority)
    |> repo().all()
  end

  @doc """
  Creates a new bucket.

  ## Examples

      iex> create_bucket(%{name: "Local Storage", provider: "local"})
      {:ok, %Bucket{}}

      iex> create_bucket(%{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_bucket(attrs \\ %{}) do
    %Bucket{}
    |> Bucket.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a bucket.

  ## Examples

      iex> update_bucket(bucket, %{name: "New Name"})
      {:ok, %Bucket{}}

      iex> update_bucket(bucket, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_bucket(%Bucket{} = bucket, attrs) do
    bucket
    |> Bucket.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a bucket.

  ## Examples

      iex> delete_bucket(bucket)
      {:ok, %Bucket{}}

      iex> delete_bucket(bucket)
      {:error, %Ecto.Changeset{}}

  """
  def delete_bucket(%Bucket{} = bucket) do
    repo().delete(bucket)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking bucket changes.
  """
  def change_bucket(%Bucket{} = bucket, attrs \\ %{}) do
    Bucket.changeset(bucket, attrs)
  end

  @doc """
  Calculates storage usage for a bucket in MB.

  Returns total size of all files stored in this bucket by summing up all
  file instances that have locations in this bucket.
  """
  def calculate_bucket_usage(bucket_id) do
    from(fl in FileLocation,
      join: fi in FileInstance,
      on: fl.file_instance_id == fi.id,
      where: fl.bucket_id == ^bucket_id and fl.status == "active",
      select: fragment("SUM(? / (1024 * 1024))", fi.size)
    )
    |> repo().one()
    |> case do
      nil -> 0
      total -> Decimal.to_float(total)
    end
  end

  @doc """
  Calculates free space for a bucket.

  For local storage, checks actual disk space.
  For cloud storage, returns the configured max_size_mb minus usage.
  """
  def calculate_bucket_free_space(%Bucket{} = bucket) do
    used_mb = calculate_bucket_usage(bucket.id)

    case bucket.provider do
      "local" ->
        calculate_local_free_space(bucket)

      _ ->
        # For cloud storage, use the configured max size
        max(bucket.max_size_mb - used_mb, 0)
    end
  end

  def calculate_bucket_free_space(bucket_id) when is_binary(bucket_id) do
    bucket = get_bucket(bucket_id)
    if bucket, do: calculate_bucket_free_space(bucket), else: 0
  end

  # ===== DIMENSIONS =====

  @doc """
  Returns a list of all dimensions, ordered by size (width x height).
  """
  def list_dimensions do
    Dimension
    |> order_by(asc: :width, asc: :height)
    |> repo().all()
  end

  @doc """
  Returns enabled dimensions for a specific file type.
  """
  def list_dimensions_for_type(file_type) when file_type in ["image", "video"] do
    Dimension
    |> where([d], d.enabled == true and (d.applies_to == ^file_type or d.applies_to == "both"))
    |> order_by(asc: :width, asc: :height)
    |> repo().all()
  end

  def list_dimensions_for_type(_), do: []

  @doc """
  Gets a single dimension by ID.
  """
  def get_dimension(id), do: repo().get(Dimension, id)

  @doc """
  Gets a dimension by name.
  """
  def get_dimension_by_name(name) do
    repo().get_by(Dimension, name: name)
  end

  @doc """
  Resets all dimensions to default seeded values.
  Deletes all current dimensions and recreates the 8 default ones.
  """
  def reset_dimensions_to_defaults do
    repo().transaction(fn ->
      # Delete all existing dimensions
      repo().delete_all(Dimension)

      # Insert default dimensions
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      default_dimensions = [
        # Image dimensions
        %{
          name: "thumbnail",
          width: 150,
          height: 150,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          order: 1,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "small",
          width: 300,
          height: 300,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          order: 2,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "medium",
          width: 800,
          height: 600,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          order: 3,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "large",
          width: 1920,
          height: 1080,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          order: 4,
          inserted_at: now,
          updated_at: now
        },
        # Video dimensions
        %{
          name: "360p",
          width: 640,
          height: 360,
          quality: 28,
          format: "mp4",
          applies_to: "video",
          enabled: true,
          order: 5,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "720p",
          width: 1280,
          height: 720,
          quality: 28,
          format: "mp4",
          applies_to: "video",
          enabled: true,
          order: 6,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "1080p",
          width: 1920,
          height: 1080,
          quality: 28,
          format: "mp4",
          applies_to: "video",
          enabled: true,
          order: 7,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "video_thumbnail",
          width: 640,
          height: 360,
          quality: 85,
          format: "jpg",
          applies_to: "video",
          enabled: true,
          order: 8,
          inserted_at: now,
          updated_at: now
        }
      ]

      # Insert all default dimensions
      Enum.each(default_dimensions, fn dim ->
        %Dimension{}
        |> Dimension.changeset(dim)
        |> repo().insert!()
      end)
    end)
  end

  @doc """
  Creates a new dimension.

  ## Examples

      iex> create_dimension(%{name: "thumbnail", width: 150, height: 150})
      {:ok, %Dimension{}}

      iex> create_dimension(%{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_dimension(attrs \\ %{}) do
    %Dimension{}
    |> Dimension.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a dimension.

  ## Examples

      iex> update_dimension(dimension, %{name: "New Name"})
      {:ok, %Dimension{}}

      iex> update_dimension(dimension, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_dimension(%Dimension{} = dimension, attrs) do
    dimension
    |> Dimension.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a dimension.

  ## Examples

      iex> delete_dimension(dimension)
      {:ok, %Dimension{}}

      iex> delete_dimension(dimension)
      {:error, %Ecto.Changeset{}}

  """
  def delete_dimension(%Dimension{} = dimension) do
    repo().delete(dimension)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking dimension changes.
  """
  def change_dimension(%Dimension{} = dimension, attrs \\ %{}) do
    Dimension.changeset(dimension, attrs)
  end

  # ===== FILES =====

  @doc """
  Returns a list of files, optionally filtered by bucket.

  ## Options

  - `:bucket_id` - Filter by bucket ID
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip
  - `:order_by` - Ordering (default: `[desc: :inserted_at]`)

  """
  def list_files(opts \\ []) do
    PhoenixKit.Storage.File
    |> maybe_filter_by_bucket(opts[:bucket_id])
    |> maybe_order_by(opts[:order_by])
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> repo().all()
  end

  @doc """
  Gets a single file by ID.
  """
  def get_file(id), do: repo().get(PhoenixKit.Storage.File, id)

  @doc """
  Calculates user-specific file checksum (salted with user_id).

  This creates a unique checksum per user+file combination for duplicate detection,
  while preserving the original file checksum for popularity queries.

  ## Parameters
    - user_id: The user ID (integer or string)
    - file_checksum: The SHA256 checksum of the file content

  ## Returns
    String representing the SHA256 checksum of "user_id + file_checksum"
  """
  def calculate_user_file_checksum(user_id, file_checksum) do
    "#{user_id}#{file_checksum}"
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Gets a file by its user-specific checksum.

  This checks for duplicates for a specific user.
  """
  def get_file_by_user_checksum(user_file_checksum) do
    repo().get_by(PhoenixKit.Storage.File, user_file_checksum: user_file_checksum)
  end

  @doc """
  Gets a file by its original content checksum (file_checksum).

  This can find files uploaded by any user with the same content.
  Useful for popularity queries.
  """
  def get_file_by_checksum(file_checksum) do
    repo().get_by(PhoenixKit.Storage.File, file_checksum: file_checksum)
  end

  @doc """
  Creates a new file record.

  This only creates the database record. Use `store_file/4` to actually
  store the file data in storage buckets.
  """
  def create_file(attrs \\ %{}) do
    %PhoenixKit.Storage.File{}
    |> PhoenixKit.Storage.File.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a file.
  """
  def update_file(%PhoenixKit.Storage.File{} = file, attrs) do
    file
    |> PhoenixKit.Storage.File.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a file.

  This only removes the database record. Use `delete_file_data/1` to
  remove the actual file data from storage buckets.
  """
  def delete_file(%PhoenixKit.Storage.File{} = file) do
    repo().delete(file)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking file changes.
  """
  def change_file(%PhoenixKit.Storage.File{} = file, attrs \\ %{}) do
    PhoenixKit.Storage.File.changeset(file, attrs)
  end

  # ===== FILE INSTANCES =====

  @doc """
  Returns a list of file instances for a given file.
  """
  def list_file_instances(file_id) do
    FileInstance
    |> where([fi], fi.file_id == ^file_id)
    |> order_by(asc: :variant_name)
    |> repo().all()
  end

  @doc """
  Gets a single file instance by ID.
  """
  def get_file_instance(id), do: repo().get(FileInstance, id)

  @doc """
  Gets a file instance by file ID and variant name.
  """
  def get_file_instance_by_name(file_id, variant_name) do
    repo().get_by(FileInstance, file_id: file_id, variant_name: variant_name)
  end

  @doc """
  Gets the bucket IDs where a file instance is stored.

  Returns a list of bucket IDs from the file_locations for the given file instance.
  """
  def get_file_instance_bucket_ids(file_instance_id) do
    import Ecto.Query

    FileLocation
    |> where([fl], fl.file_instance_id == ^file_instance_id and fl.status == "active")
    |> select([fl], fl.bucket_id)
    |> repo().all()
  end

  @doc """
  Creates a new file instance.
  """
  def create_file_instance(attrs \\ %{}) do
    %FileInstance{}
    |> FileInstance.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a file instance.
  """
  def update_file_instance(%FileInstance{} = instance, attrs) do
    instance
    |> FileInstance.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a file instance.
  """
  def delete_file_instance(%FileInstance{} = instance) do
    repo().delete(instance)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking file instance changes.
  """
  def change_file_instance(%FileInstance{} = instance, attrs \\ %{}) do
    FileInstance.changeset(instance, attrs)
  end

  @doc """
  Updates a file instance's processing status.
  """
  def update_instance_status(instance, status)
      when status in ["pending", "processing", "completed", "failed"] do
    update_file_instance(instance, %{processing_status: status})
  end

  @doc """
  Updates a file instance with file information after processing.
  """
  def update_instance_with_file_info(instance, file_path, dimensions \\ nil) do
    {:ok, stat} = Elixir.File.stat(file_path)
    size = stat.size
    checksum = calculate_file_hash(file_path)

    attrs = %{
      checksum: checksum,
      size: size
    }

    attrs =
      case dimensions do
        {width, height} ->
          Map.merge(attrs, %{width: width, height: height})

        _ ->
          attrs
      end

    update_file_instance(instance, attrs)
  end

  # ===== CONFIGURATION =====

  @doc """
  Gets the current storage configuration.
  """
  def get_config do
    %{
      default_path: get_default_path(),
      redundancy_copies: get_redundancy_copies(),
      auto_generate_variants: get_auto_generate_variants(),
      default_bucket_id: get_default_bucket_id()
    }
  end

  @doc """
  Gets the absolute path for local storage.
  """
  def get_absolute_path do
    default_path = get_default_path()
    Path.expand(default_path, Elixir.File.cwd!())
  end

  @doc """
  Validates and normalizes a storage path.

  Returns `{:ok, relative_path}` if valid, or error tuple if invalid.
  """
  def validate_and_normalize_path(path) when is_binary(path) do
    expanded_path = Path.expand(path, Elixir.File.cwd!())

    if Elixir.File.exists?(expanded_path) do
      relative_path = Path.relative_to(expanded_path, Elixir.File.cwd!())
      {:ok, relative_path}
    else
      {:error, :does_not_exist, expanded_path}
    end
  end

  def validate_and_normalize_path(_path), do: {:error, :invalid_path}

  @doc """
  Updates the default storage path.
  """
  def update_default_path(relative_path) when is_binary(relative_path) do
    Settings.update_setting("storage_default_path", relative_path)
  end

  @doc """
  Creates a directory if it doesn't exist.
  """
  def create_directory(path) when is_binary(path) do
    case Elixir.File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_directory(_path), do: {:error, :invalid_path}

  # ===== FILE STORAGE OPERATIONS =====

  @doc """
  Stores a file in the storage system.

  This will:
  1. Store the file in multiple buckets based on redundancy settings
  2. Generate variants if enabled
  3. Create database records for the file and its variants

  ## Options

  - `:filename` - Original filename (required)
  - `:content_type` - MIME type (required)
  - `:size_bytes` - File size in bytes (required)
  - `:user_id` - User ID who owns the file
  - `:metadata` - Additional metadata map

  """
  def store_file(source_path, opts \\ []) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.fetch!(opts, :content_type)
    size_bytes = Keyword.fetch!(opts, :size_bytes)
    user_id = Keyword.get(opts, :user_id)
    metadata = Keyword.get(opts, :metadata, %{})

    # Validate required fields
    if Elixir.File.exists?(source_path) do
      # Calculate file checksum
      file_checksum = calculate_file_hash(source_path)

      # Calculate user-specific checksum for duplicate detection
      user_file_checksum = calculate_user_file_checksum(user_id, file_checksum)

      # Check if this user already uploaded this file
      case get_file_by_user_checksum(user_file_checksum) do
        %PhoenixKit.Storage.File{} = existing_file ->
          # File already exists for this user, return existing file
          {:ok, existing_file}

        nil ->
          # New file for this user, proceed with storage
          store_new_file(
            source_path,
            file_checksum,
            user_file_checksum,
            filename,
            content_type,
            size_bytes,
            user_id,
            metadata
          )
      end
    else
      {:error, "Source file does not exist"}
    end
  end

  @doc """
  Retrieves a file from storage by file ID.

  Will try buckets in priority order until the file is found.
  """
  def retrieve_file(file_id) do
    case get_file(file_id) do
      %PhoenixKit.Storage.File{} = file ->
        # Look up the original variant path from file_instances table
        case get_file_instance_by_name(file_id, "original") do
          %FileInstance{file_name: file_path} ->
            destination_path = generate_temp_path()

            case Manager.retrieve_file(file_path,
                   destination_path: destination_path
                 ) do
              {:ok, _path} -> {:ok, destination_path, file}
              error -> error
            end

          nil ->
            {:error, "Original file instance not found"}
        end

      nil ->
        {:error, "File not found"}
    end
  end

  @doc """
  Retrieves a file by its hash.
  """
  def retrieve_file_by_hash(hash) do
    case get_file_by_checksum(hash) do
      %PhoenixKit.Storage.File{} = file ->
        retrieve_file(file.id)

      nil ->
        {:error, "File not found"}
    end
  end

  @doc """
  Deletes file data from all storage buckets.
  """
  def delete_file_data(%PhoenixKit.Storage.File{} = file) do
    # Look up the actual file path from file_instances where "original" variant is stored
    case get_file_instance_by_name(file.id, "original") do
      %PhoenixKit.Storage.FileInstance{file_name: file_path} ->
        case Manager.delete_file(file_path) do
          :ok -> :ok
          error -> error
        end

      nil ->
        {:error, "Original file instance not found"}
    end
  end

  @doc """
  Gets a public URL for a file.
  """
  def get_public_url(%PhoenixKit.Storage.File{} = file) do
    # Look up the actual file path from file_instances where "original" variant is stored
    case get_file_instance_by_name(file.id, "original") do
      %PhoenixKit.Storage.FileInstance{file_name: file_path} ->
        Manager.public_url(file_path) || signed_file_url(file.id, "original")

      nil ->
        nil
    end
  end

  @doc """
  Gets a public URL for a specific file variant.

  ## Variants

  For images: "original", "thumbnail", "small", "medium", "large"
  For videos: "original", "360p", "720p", "1080p", "video_thumbnail"

  ## Examples

      iex> get_public_url_by_variant(file, "thumbnail")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_thumbnail.jpg"

      iex> get_public_url_by_variant(file, "medium")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_medium.jpg"

  """
  def get_public_url_by_variant(%PhoenixKit.Storage.File{} = file, variant_name) do
    case get_file_instance_by_name(file.id, variant_name) do
      %PhoenixKit.Storage.FileInstance{file_name: file_path} ->
        Manager.public_url(file_path) || signed_file_url(file.id, variant_name)

      nil ->
        # Fallback to original if variant doesn't exist
        get_public_url(file)
    end
  end

  @doc """
  Gets a public URL for a file by file ID.

  Convenience function that fetches the file and returns its URL.

  ## Examples

      iex> get_public_url_by_id("018e3c4a-9f6b-7890-abcd-ef1234567890")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_original.jpg"

      iex> get_public_url_by_id("invalid-id")
      nil

  """
  def get_public_url_by_id(file_id) when is_binary(file_id) do
    case get_file(file_id) do
      %PhoenixKit.Storage.File{} = file ->
        get_public_url(file)

      nil ->
        nil
    end
  end

  def get_public_url_by_id(_), do: nil

  @doc """
  Gets a public URL for a specific file variant by file ID.

  ## Examples

      iex> get_public_url_by_id("018e3c4a-9f6b-7890-abcd-ef1234567890", "thumbnail")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_thumbnail.jpg"

  """
  def get_public_url_by_id(file_id, variant_name) when is_binary(file_id) do
    case get_file(file_id) do
      %PhoenixKit.Storage.File{} = file ->
        get_public_url_by_variant(file, variant_name)

      nil ->
        nil
    end
  end

  defp signed_file_url(file_id, variant_name) do
    URLSigner.signed_url(file_id, variant_name, locale: :none)
  rescue
    _ -> nil
  end

  @doc """
  Checks if a file exists in storage.
  """
  def file_exists?(%PhoenixKit.Storage.File{} = file) do
    # Look up the actual file path from file_instances where "original" variant is stored
    case get_file_instance_by_name(file.id, "original") do
      %PhoenixKit.Storage.FileInstance{file_name: file_path} ->
        Manager.file_exists?(file_path)

      nil ->
        false
    end
  end

  @doc """
  Stores a file in buckets with hierarchical path structure.

  ## Path Structure

  Files are stored using the pattern:
  `{user_id[0..1]}/{hash[0..1]}/{full_hash}/{full_hash}_{variant}.{format}`

  ## Examples

  User ID: "12345678"
  File hash: "a1b2c3d4e5f6..."
  Original: "12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_original.jpg"
  Thumbnail: "12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_thumbnail.jpg"
  """
  def store_file_in_buckets(
        source_path,
        file_type,
        user_id,
        file_checksum,
        ext,
        original_filename \\ nil
      ) do
    # Calculate user-specific hash for duplicate detection
    user_file_checksum = calculate_user_file_checksum(user_id, file_checksum)

    # Check if this user already uploaded this file
    case get_file_by_user_checksum(user_file_checksum) do
      %PhoenixKit.Storage.File{} = existing_file ->
        Logger.info("=== DUPLICATE FILE DETECTED ===")
        Logger.info("File ID: #{existing_file.id}, Checksum: #{file_checksum}")
        Logger.info("File path: #{existing_file.file_path}")

        # File already exists, but check if instances and actual files are healthy
        case get_file_instance_by_name(existing_file.id, "original") do
          %FileInstance{file_name: stored_file_path} ->
            Logger.info("Original instance record found: #{stored_file_path}")

            # Instance record exists, verify actual file exists in storage
            case verify_file_in_storage(stored_file_path) do
              :exists ->
                Logger.info("Duplicate file is healthy in storage. Queueing variant generation.")
                # File is healthy in storage, ensure other variants are generated
                _ = queue_variant_generation(existing_file, user_id, original_filename)
                {:ok, existing_file, :duplicate}

              :missing ->
                # File record exists but actual file is missing from storage
                # Need to re-store the file and recreate instances
                Logger.warning(
                  "Duplicate file detected but missing from storage: #{existing_file.id}"
                )

                restore_missing_file(
                  existing_file,
                  source_path,
                  file_checksum,
                  user_id,
                  original_filename
                )
            end

          nil ->
            # File record exists but instance record is missing
            # Need to recreate instances from the stored file
            Logger.warning(
              "Duplicate file detected but missing instance record: #{existing_file.id}"
            )

            Logger.info("Attempting to recreate instances...")

            recreate_file_instances(
              existing_file,
              source_path,
              file_checksum,
              user_id,
              original_filename
            )
        end

      nil ->
        Logger.info("New file detected (no existing hash match). Proceeding with storage.")
        # File is new, proceed with storage
        store_new_file_in_buckets(
          source_path,
          file_type,
          user_id,
          file_checksum,
          user_file_checksum,
          ext,
          original_filename
        )
    end
  end

  defp store_new_file_in_buckets(
         source_path,
         file_type,
         user_id,
         file_checksum,
         user_file_checksum,
         ext,
         original_filename
       ) do
    # Calculate MD5 hash for path structure
    md5_hash =
      source_path
      |> Elixir.File.read!()
      |> then(fn data -> :crypto.hash(:md5, data) end)
      |> Base.encode16(case: :lower)

    # Generate UUIDv7 for file ID
    file_id = generate_uuidv7()

    # Build hierarchical path - organized by user_prefix/hash_prefix/md5_hash
    user_prefix = String.slice(to_string(user_id), 0, 2)
    hash_prefix = String.slice(md5_hash, 0, 2)
    file_path = "#{user_prefix}/#{hash_prefix}/#{md5_hash}"

    # Use provided original filename or fall back to source basename
    orig_filename = original_filename || Path.basename(source_path)

    # Create file record
    file_attrs = %{
      id: file_id,
      file_name: md5_hash <> "." <> ext,
      original_file_name: orig_filename,
      file_path: file_path,
      mime_type: determine_mime_type(ext),
      file_type: file_type,
      ext: ext,
      file_checksum: file_checksum,
      user_file_checksum: user_file_checksum,
      size: get_file_size(source_path),
      status: "processing",
      user_id: user_id
    }

    case create_file(file_attrs) do
      {:ok, file} ->
        # Store in buckets with redundancy - use MD5 hash for organized structure
        original_path = "#{file_path}/#{md5_hash}_original.#{ext}"

        case Manager.store_file(source_path, path_prefix: original_path) do
          {:ok, storage_info} ->
            # Create file instance for original
            original_instance_attrs = %{
              variant_name: "original",
              file_name: original_path,
              mime_type: file.mime_type,
              ext: ext,
              checksum: file_checksum,
              size: get_file_size(source_path),
              processing_status: "completed",
              file_id: file.id
            }

            case create_file_instance(original_instance_attrs) do
              {:ok, instance} ->
                # Create file location records for each bucket where the file was stored
                _ = create_file_locations(instance.id, storage_info.bucket_ids, original_path)

                # Queue background job for variant processing
                _ =
                  %{file_id: file.id, user_id: user_id, filename: orig_filename}
                  |> ProcessFileJob.new()
                  |> Oban.insert()

                {:ok, file}

              {:error, changeset} ->
                # Clean up if instance creation fails
                Manager.delete_file(original_path)
                {:error, changeset}
            end

          {:error, reason} ->
            # Clean up file record if storage fails
            repo().delete(file)
            {:error, reason}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ===== HELPER FUNCTIONS =====

  defp queue_variant_generation(file, user_id, original_filename) do
    # Queue variant generation to ensure all variants exist for this file
    Task.start(fn ->
      %{file_id: file.id, user_id: user_id, filename: original_filename}
      |> ProcessFileJob.new()
      |> Oban.insert()
    end)
  end

  defp verify_file_in_storage(stored_file_path) do
    # Check if file actually exists in storage buckets
    Logger.info("Verifying file in storage: #{stored_file_path}")
    exists = Manager.file_exists?(stored_file_path)
    Logger.info("File exists? #{exists}")
    if exists, do: :exists, else: :missing
  end

  defp restore_missing_file(existing_file, source_path, file_hash, user_id, original_filename) do
    # File record exists but actual file is missing from storage
    # Delete broken instances and recreate them (which will also store the file)

    Logger.warning("=== RECOVERING MISSING FILE ===")
    Logger.warning("File ID: #{existing_file.id}")
    Logger.warning("File path: #{existing_file.file_path}")
    Logger.warning("Source path: #{source_path}")

    # First, delete all broken instances for this file
    deleted_count = delete_file_instances_for_file(existing_file.id)
    Logger.info("Deleted #{deleted_count} broken instances for file: #{existing_file.id}")

    # Recreate instance and store the file (combined in one operation)
    Logger.info("Recreating instances for file #{existing_file.id}")
    recreate_file_instances(existing_file, source_path, file_hash, user_id, original_filename)
  end

  defp delete_file_instances_for_file(file_id) do
    # Delete all file instances for a file (to clean up broken ones)
    {deleted_count, _} =
      from(fi in FileInstance, where: fi.file_id == ^file_id)
      |> repo().delete_all()

    Logger.info("Deleted #{deleted_count} file instances for file_id: #{file_id}")
    deleted_count
  end

  defp recreate_file_instances(file, source_path, file_checksum, user_id, original_filename) do
    # File record exists but instances are missing or broken
    # First store the file in buckets, then recreate the instance record

    Logger.info(
      "Starting recreate_file_instances for file: #{file.id}, file_path: #{file.file_path}"
    )

    {:ok, stat} = Elixir.File.stat(source_path)
    file_size = stat.size

    # Reconstruct the full storage path for the original instance
    # file.file_path is "user_prefix/hash_prefix/md5_hash"
    # We need to extract md5_hash and build the original path
    [_user_prefix, _hash_prefix, md5_hash | _rest] = String.split(file.file_path, "/")
    original_path = "#{file.file_path}/#{md5_hash}_original.#{file.ext}"

    Logger.info("Reconstructed original path for instance: #{original_path}")

    Logger.info(
      "About to store file from source_path: #{source_path} to storage path: #{original_path}"
    )

    # First, store the file in buckets using Manager
    case Manager.store_file(source_path, path_prefix: original_path) do
      {:ok, storage_info} ->
        Logger.info(
          "File stored in buckets: #{original_path}, bucket_ids: #{inspect(storage_info.bucket_ids)}"
        )

        # Now create the file instance record pointing to the stored file
        original_instance_attrs = %{
          variant_name: "original",
          file_name: original_path,
          mime_type: file.mime_type,
          ext: file.ext,
          checksum: file_checksum,
          size: file_size,
          processing_status: "completed",
          file_id: file.id
        }

        case create_file_instance(original_instance_attrs) do
          {:ok, _instance} ->
            Logger.info(
              "Recreated original instance for file: #{file.id}, path: #{original_path}"
            )

            # Delete any remaining broken variant instances BEFORE queuing ProcessFileJob
            # This ensures ProcessFileJob creates fresh instances with correct paths
            deleted_variants = delete_variant_instances(file.id)

            Logger.info(
              "Deleted #{deleted_variants} broken variant instances before regeneration"
            )

            # Queue variant generation for the recovered file
            _ = queue_variant_generation(file, user_id, original_filename)
            {:ok, file, :duplicate}

          {:error, reason} ->
            # Instance creation failed, might be duplicate constraint
            # Try deleting old broken instances and recreating
            Logger.warning(
              "Instance creation failed for file #{file.id}: #{inspect(reason)}, attempting cleanup and retry"
            )

            _ = delete_file_instances_for_file(file.id)

            case create_file_instance(original_instance_attrs) do
              {:ok, _instance} ->
                Logger.info(
                  "Recreated original instance for file (after cleanup): #{file.id}, path: #{original_path}"
                )

                # Delete any remaining broken variant instances
                deleted_variants = delete_variant_instances(file.id)

                Logger.info(
                  "Deleted #{deleted_variants} broken variant instances before regeneration"
                )

                _ = queue_variant_generation(file, user_id, original_filename)
                {:ok, file, :duplicate}

              {:error, final_reason} ->
                Logger.error(
                  "Failed to recreate instance for file #{file.id}: #{inspect(final_reason)}"
                )

                {:error, final_reason}
            end
        end

      {:error, store_error} ->
        Logger.error(
          "Failed to store file in buckets for recreate_file_instances: #{inspect(store_error)}"
        )

        {:error, store_error}
    end
  end

  defp delete_variant_instances(file_id) do
    # Delete only the variant instances (not the original), to clean up broken ones
    {deleted_count, _} =
      from(fi in FileInstance,
        where: fi.file_id == ^file_id and fi.variant_name != "original"
      )
      |> repo().delete_all()

    deleted_count
  end

  defp generate_uuidv7 do
    UUIDv7.generate()
  end

  defp get_file_size(source_path) do
    case Elixir.File.stat(source_path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  defp determine_mime_type(ext) do
    case String.downcase(ext) do
      "jpg" -> "image/jpeg"
      "jpeg" -> "image/jpeg"
      "png" -> "image/png"
      "gif" -> "image/gif"
      "webp" -> "image/webp"
      "mp4" -> "video/mp4"
      "webm" -> "video/webm"
      "mov" -> "video/quicktime"
      "avi" -> "video/x-msvideo"
      "pdf" -> "application/pdf"
      _ -> "application/octet-stream"
    end
  end

  defp get_default_path do
    Settings.get_setting("storage_default_path", "priv/uploads")
  end

  defp get_redundancy_copies do
    Settings.get_setting("storage_redundancy_copies", "1")
    |> String.to_integer()
    |> max(1)
    |> min(5)
  end

  def get_auto_generate_variants do
    Settings.get_setting("storage_auto_generate_variants", "true") == "true"
  end

  defp get_default_bucket_id do
    Settings.get_setting("storage_default_bucket_id", nil)
  end

  defp calculate_local_free_space(bucket) do
    # For local storage, return configured max_size_mb or default 1000 MB
    # Note: Real disk space monitoring should be implemented via System.cmd("df")
    # or external monitoring tools, as :disksup is not reliably available
    bucket.max_size_mb || 1000
  end

  # ===== REPO HELPERS =====

  defp repo do
    PhoenixKit.Config.get_repo()
  end

  # Query builders for file listing
  defp maybe_filter_by_bucket(query, nil), do: query

  defp maybe_filter_by_bucket(query, bucket_id) do
    where(query, [f], f.bucket_id == ^bucket_id)
  end

  defp maybe_order_by(query, nil), do: order_by(query, [f], desc: f.inserted_at)
  defp maybe_order_by(query, order_by), do: order_by(query, [f], ^order_by)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  # ===== FILE STORAGE HELPERS =====

  defp store_new_file(
         source_path,
         file_checksum,
         user_file_checksum,
         filename,
         content_type,
         size_bytes,
         user_id,
         metadata
       ) do
    # Store file using manager
    case Manager.store_file(source_path) do
      {:ok, storage_info} ->
        file_attrs =
          build_file_attrs(
            storage_info,
            filename,
            content_type,
            file_checksum,
            user_file_checksum,
            size_bytes,
            metadata,
            user_id
          )

        case create_file(file_attrs) do
          {:ok, file} ->
            # Create original instance and variants (non-critical operations)
            create_original_instance_and_variants(file, file_checksum, size_bytes)
            {:ok, file}

          {:error, changeset} ->
            # Clean up stored files if database creation fails
            Manager.delete_file(storage_info.destination_path)
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_file_attrs(
         storage_info,
         filename,
         content_type,
         file_checksum,
         user_file_checksum,
         size_bytes,
         metadata,
         user_id
       ) do
    %{
      original_file_name: filename,
      file_name: storage_info.destination_path,
      mime_type: content_type,
      file_type: determine_file_type(content_type),
      ext: Path.extname(filename),
      file_checksum: file_checksum,
      user_file_checksum: user_file_checksum,
      size: size_bytes,
      # Convert to MB
      size_mb: size_bytes / (1024 * 1024),
      status: "active",
      metadata: metadata,
      user_id: user_id
    }
  end

  defp create_original_instance_and_variants(file, file_checksum, size_bytes) do
    original_instance_attrs = %{
      variant_name: "original",
      file_name: file.file_name,
      mime_type: file.mime_type,
      ext: file.ext,
      checksum: file_checksum,
      size: size_bytes,
      # Will be populated if we can detect dimensions
      width: nil,
      # Will be populated if we can detect dimensions
      height: nil,
      processing_status: "completed",
      file_id: file.id
    }

    case create_file_instance(original_instance_attrs) do
      {:ok, _original_instance} ->
        # Generate variants if enabled (failure is non-critical)
        case VariantGenerator.generate_variants(file) do
          {:ok, _variants} -> :ok
          {:error, _reason} -> :ok
        end

      {:error, _changeset} ->
        # Original instance creation failed, but file was stored (non-critical)
        :ok
    end
  end

  defp calculate_file_hash(file_path) do
    file_path
    |> Elixir.File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") ->
        "image"

      String.starts_with?(mime_type, "video/") ->
        "video"

      String.starts_with?(mime_type, "audio/") ->
        "audio"

      String.starts_with?(mime_type, "text/") ->
        "document"

      mime_type in ["application/pdf"] ->
        "document"

      mime_type in [
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ] ->
        "document"

      String.contains?(mime_type, "zip") or String.contains?(mime_type, "archive") ->
        "archive"

      true ->
        "other"
    end
  end

  defp generate_temp_path do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_#{random_name}")
  end

  defp create_file_locations(file_instance_id, bucket_ids, file_path) do
    Enum.each(bucket_ids, fn bucket_id ->
      location_attrs = %{
        path: file_path,
        status: "active",
        priority: 0,
        file_instance_id: file_instance_id,
        bucket_id: bucket_id
      }

      repo().insert(%FileLocation{} |> FileLocation.changeset(location_attrs))
    end)

    :ok
  end
end
