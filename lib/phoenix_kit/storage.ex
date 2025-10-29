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

  alias PhoenixKit.Storage.Bucket
  alias PhoenixKit.Storage.Dimension
  alias PhoenixKit.Storage.File

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
    from(fl in PhoenixKit.Storage.FileLocation,
      join: fi in PhoenixKit.Storage.FileInstance,
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
  Gets a file by its hash.
  """
  def get_file_by_hash(hash) do
    repo().get_by(PhoenixKit.Storage.File, hash: hash)
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
    PhoenixKit.Storage.FileInstance
    |> where([fi], fi.file_id == ^file_id)
    |> order_by(asc: :variant_name)
    |> repo().all()
  end

  @doc """
  Gets a single file instance by ID.
  """
  def get_file_instance(id), do: repo().get(PhoenixKit.Storage.FileInstance, id)

  @doc """
  Gets a file instance by file ID and variant name.
  """
  def get_file_instance_by_name(file_id, variant_name) do
    repo().get_by(PhoenixKit.Storage.FileInstance, file_id: file_id, variant_name: variant_name)
  end

  @doc """
  Creates a new file instance.
  """
  def create_file_instance(attrs \\ %{}) do
    %PhoenixKit.Storage.FileInstance{}
    |> PhoenixKit.Storage.FileInstance.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a file instance.
  """
  def update_file_instance(%PhoenixKit.Storage.FileInstance{} = instance, attrs) do
    instance
    |> PhoenixKit.Storage.FileInstance.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a file instance.
  """
  def delete_file_instance(%PhoenixKit.Storage.FileInstance{} = instance) do
    repo().delete(instance)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking file instance changes.
  """
  def change_file_instance(%PhoenixKit.Storage.FileInstance{} = instance, attrs \\ %{}) do
    PhoenixKit.Storage.FileInstance.changeset(instance, attrs)
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
    PhoenixKit.Settings.update_setting("storage_default_path", relative_path)
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
    if !Elixir.File.exists?(source_path) do
      {:error, "Source file does not exist"}
    else
      # Calculate file hash
      file_hash = calculate_file_hash(source_path)

      # Check if file already exists
      case get_file_by_hash(file_hash) do
        %PhoenixKit.Storage.File{} = existing_file ->
          # File already exists, return existing file
          {:ok, existing_file}

        nil ->
          # New file, proceed with storage
          store_new_file(
            source_path,
            file_hash,
            filename,
            content_type,
            size_bytes,
            user_id,
            metadata
          )
      end
    end
  end

  @doc """
  Retrieves a file from storage by file ID.

  Will try buckets in priority order until the file is found.
  """
  def retrieve_file(file_id) do
    case get_file(file_id) do
      %PhoenixKit.Storage.File{} = file ->
        destination_path = generate_temp_path()

        case PhoenixKit.Storage.Manager.retrieve_file(file.file_name,
               destination_path: destination_path
             ) do
          :ok -> {:ok, destination_path, file}
          error -> error
        end

      nil ->
        {:error, "File not found"}
    end
  end

  @doc """
  Retrieves a file by its hash.
  """
  def retrieve_file_by_hash(hash) do
    case get_file_by_hash(hash) do
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
    case PhoenixKit.Storage.Manager.delete_file(file.file_name) do
      :ok -> :ok
      error -> error
    end
  end

  @doc """
  Gets a public URL for a file.
  """
  def get_public_url(%PhoenixKit.Storage.File{} = file) do
    PhoenixKit.Storage.Manager.public_url(file.file_name)
  end

  @doc """
  Checks if a file exists in storage.
  """
  def file_exists?(%PhoenixKit.Storage.File{} = file) do
    PhoenixKit.Storage.Manager.file_exists?(file.file_name)
  end

  # ===== HELPER FUNCTIONS =====

  defp get_default_path do
    PhoenixKit.Settings.get_setting("storage_default_path", "priv/uploads")
  end

  defp get_redundancy_copies do
    PhoenixKit.Settings.get_setting("storage_redundancy_copies", "2")
    |> String.to_integer()
    |> max(1)
    |> min(5)
  end

  def get_auto_generate_variants do
    PhoenixKit.Settings.get_setting("storage_auto_generate_variants", "true") == "true"
  end

  defp get_default_bucket_id do
    PhoenixKit.Settings.get_setting("storage_default_bucket_id", nil)
  end

  defp calculate_local_free_space(bucket) do
    try do
      case :disksup.get_disk_info() do
        [{_device, total_kb, available_kb}] ->
          total_mb = total_kb / 1024
          available_mb = available_kb / 1024
          max_used = bucket.max_size_mb || total_mb
          max(max_used - (total_mb - available_mb), 0)

        _ ->
          bucket.max_size_mb || 1000
      end
    rescue
      # :disksup module not available or other error
      UndefinedFunctionError ->
        bucket.max_size_mb || 1000

      _ ->
        bucket.max_size_mb || 1000
    end
  end

  # ===== REPO HELPERS =====

  defp repo do
    # Get the repository from application config or use a default
    Application.get_env(:phoenix_kit, :repo) || PhoenixKit.Repo
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
         file_hash,
         filename,
         content_type,
         size_bytes,
         user_id,
         metadata
       ) do
    # Store file using manager
    case PhoenixKit.Storage.Manager.store_file(source_path) do
      {:ok, storage_info} ->
        # Create database record
        file_attrs = %{
          original_file_name: filename,
          file_name: storage_info.destination_path,
          mime_type: content_type,
          file_type: determine_file_type(content_type),
          ext: Path.extname(filename),
          checksum: file_hash,
          size: size_bytes,
          # Convert to MB
          size_mb: size_bytes / (1024 * 1024),
          status: "active",
          metadata: metadata,
          user_id: user_id
        }

        case create_file(file_attrs) do
          {:ok, file} ->
            # Create original file instance
            original_instance_attrs = %{
              variant_name: "original",
              file_name: file.file_name,
              mime_type: file.mime_type,
              ext: file.ext,
              checksum: file_hash,
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
                # Generate variants if enabled
                case PhoenixKit.Storage.VariantGenerator.generate_variants(file) do
                  {:ok, _variants} ->
                    {:ok, file}

                  {:error, _reason} ->
                    # Variant generation failed, but file was stored successfully
                    # Log the error but don't fail the entire upload
                    {:ok, file}
                end

              {:error, _changeset} ->
                # Original instance creation failed, but file was stored
                # This shouldn't happen in normal circumstances
                {:ok, file}
            end

          {:error, changeset} ->
            # Clean up stored files if database creation fails
            PhoenixKit.Storage.Manager.delete_file(storage_info.destination_path)
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp calculate_file_hash(file_path) do
    file_path
    |> Elixir.File.read!()
    |> :crypto.hash(:sha256)
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
end
