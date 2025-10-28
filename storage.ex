defmodule PhoenixKit.Storage do
  @moduledoc """
  Context for distributed file storage system.

  Provides CRUD operations for files, instances, locations, buckets, and dimensions.
  Includes smart bucket selection with priority system and free space calculation.

  ## Main Features

  - **File Management**: Create, read, update, delete files
  - **Instance Management**: Handle file variants (thumbnails, resizes, video qualities)
  - **Location Management**: Track physical storage across multiple buckets
  - **Bucket Management**: Configure storage providers (local, S3, B2, R2)
  - **Dimension Management**: Admin-configurable size presets
  - **Smart Selection**: Priority-based bucket selection + emptiest drive logic
  - **URL Generation**: Signed URLs with token security

  ## Usage

      # List enabled buckets
      Storage.list_enabled_buckets()

      # Smart bucket selection for upload (respects redundancy setting)
      Storage.select_buckets_for_upload()

      # Generate signed URL
      Storage.signed_file_url(file_id, "thumbnail")

      # Get file with instances and locations
      Storage.get_file_with_details(file_id)
  """

  import Ecto.Query, warn: false
  alias PhoenixKit.Repo
  alias PhoenixKit.Settings
  alias PhoenixKit.Storage.{Bucket, File, FileInstance, FileLocation, Dimension, URLSigner}

  # ===========================================================================
  # Bucket Functions
  # ===========================================================================

  @doc """
  Lists all buckets.
  """
  def list_buckets do
    Repo.all(Bucket)
  end

  @doc """
  Lists only enabled buckets.
  """
  def list_enabled_buckets do
    Bucket
    |> where([b], b.enabled == true)
    |> Repo.all()
  end

  @doc """
  Gets a single bucket.
  """
  def get_bucket(id) do
    Repo.get(Bucket, id)
  end

  @doc """
  Creates a bucket.
  """
  def create_bucket(attrs \\ %{}) do
    %Bucket{}
    |> Bucket.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a bucket.
  """
  def update_bucket(%Bucket{} = bucket, attrs) do
    bucket
    |> Bucket.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a bucket.
  """
  def delete_bucket(%Bucket{} = bucket) do
    Repo.delete(bucket)
  end

  @doc """
  Calculates used space in a bucket (in MB).

  Sums the size of all file locations in this bucket.
  """
  def calculate_bucket_usage(bucket_id) do
    query =
      from fl in FileLocation,
        join: fi in FileInstance,
        on: fl.file_instance_id == fi.id,
        where: fl.bucket_id == ^bucket_id and fl.status == "active",
        select: sum(fi.size)

    case Repo.one(query) do
      nil -> 0
      # Convert to MB
      size_bytes -> div(size_bytes, 1_024 * 1_024)
    end
  end

  @doc """
  Calculates free space in a bucket (in MB).

  Returns nil if bucket has no max_size_mb (unlimited).
  """
  def calculate_bucket_free_space(%Bucket{max_size_mb: nil}), do: nil

  def calculate_bucket_free_space(%Bucket{id: id, max_size_mb: max_size}) do
    used = calculate_bucket_usage(id)
    max(0, max_size - used)
  end

  @doc """
  Selects buckets for file upload based on priority system and redundancy setting.

  ## Algorithm

  1. Get `storage_redundancy_copies` setting (default: 2)
  2. Query all enabled buckets
  3. Separate buckets by priority:
     - Priority > 0: Specific priority buckets (sorted by priority ASC)
     - Priority = 0: Random buckets (sorted by free space DESC)
  4. Select buckets:
     - Take priority buckets first (in priority order)
     - Fill remaining slots with emptiest random buckets
  5. Return N buckets (where N = redundancy_copies)

  ## Examples

      # With priority buckets
      select_buckets_for_upload()
      # => [%Bucket{priority: 1}, %Bucket{priority: 2}]

      # Without priority buckets (uses emptiest drives)
      select_buckets_for_upload()
      # => [%Bucket{priority: 0, free: 800GB}, %Bucket{priority: 0, free: 500GB}]

      # Mixed (priority + empty drives)
      select_buckets_for_upload()
      # => [%Bucket{priority: 1}, %Bucket{priority: 0, free: 800GB}]
  """
  def select_buckets_for_upload do
    redundancy_count =
      Settings.get_setting("storage_redundancy_copies", "2")
      |> String.to_integer()

    buckets = list_enabled_buckets()

    # Separate by priority
    priority_buckets =
      buckets
      |> Enum.filter(fn b -> b.priority > 0 end)
      |> Enum.sort_by(& &1.priority)

    random_buckets =
      buckets
      |> Enum.filter(fn b -> b.priority == 0 end)
      |> Enum.map(fn bucket ->
        free_space = calculate_bucket_free_space(bucket) || 999_999_999
        {bucket, free_space}
      end)
      |> Enum.sort_by(fn {_bucket, free} -> free end, :desc)
      |> Enum.map(fn {bucket, _free} -> bucket end)

    # Combine: priority buckets first, then emptiest random buckets
    (priority_buckets ++ random_buckets)
    |> Enum.take(redundancy_count)
  end

  # ===========================================================================
  # File Functions
  # ===========================================================================

  @doc """
  Lists all files.
  """
  def list_files do
    Repo.all(File)
  end

  @doc """
  Lists files for a specific user.
  """
  def list_user_files(user_id) do
    File
    |> where([f], f.user_id == ^user_id)
    |> order_by([f], desc: f.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single file.
  """
  def get_file(id) do
    Repo.get(File, id)
  end

  @doc """
  Gets a file with preloaded instances and locations.
  """
  def get_file_with_details(id) do
    File
    |> where([f], f.id == ^id)
    |> preload([f], instances: [:locations])
    |> Repo.one()
  end

  @doc """
  Creates a file.
  """
  def create_file(attrs \\ %{}) do
    %File{}
    |> File.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a file.
  """
  def update_file(%File{} = file, attrs) do
    file
    |> File.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a file (cascades to instances and locations).
  """
  def delete_file(%File{} = file) do
    Repo.delete(file)
  end

  # ===========================================================================
  # File Instance Functions
  # ===========================================================================

  @doc """
  Lists instances for a file.
  """
  def list_file_instances(file_id) do
    FileInstance
    |> where([fi], fi.file_id == ^file_id)
    |> order_by([fi], asc: :variant_name)
    |> Repo.all()
  end

  @doc """
  Gets a single file instance.
  """
  def get_file_instance(id) do
    Repo.get(FileInstance, id)
  end

  @doc """
  Gets a file instance by file_id and variant_name.
  """
  def get_file_instance_by_variant(file_id, variant_name) do
    FileInstance
    |> where([fi], fi.file_id == ^file_id and fi.variant_name == ^variant_name)
    |> Repo.one()
  end

  @doc """
  Creates a file instance.
  """
  def create_file_instance(attrs \\ %{}) do
    %FileInstance{}
    |> FileInstance.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a file instance.
  """
  def update_file_instance(%FileInstance{} = instance, attrs) do
    instance
    |> FileInstance.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a file instance (cascades to locations).
  """
  def delete_file_instance(%FileInstance{} = instance) do
    Repo.delete(instance)
  end

  # ===========================================================================
  # File Location Functions
  # ===========================================================================

  @doc """
  Lists locations for a file instance.
  """
  def list_instance_locations(file_instance_id) do
    FileLocation
    |> where([fl], fl.file_instance_id == ^file_instance_id)
    |> order_by([fl], desc: :priority)
    |> preload(:bucket)
    |> Repo.all()
  end

  @doc """
  Gets active locations for a file instance (for retrieval).

  Orders by priority DESC (higher priority first) for failover.
  """
  def get_active_locations(file_instance_id) do
    FileLocation
    |> where([fl], fl.file_instance_id == ^file_instance_id and fl.status == "active")
    |> order_by([fl], desc: :priority)
    |> preload(:bucket)
    |> Repo.all()
  end

  @doc """
  Gets a single file location.
  """
  def get_file_location(id) do
    Repo.get(FileLocation, id)
  end

  @doc """
  Creates a file location.
  """
  def create_file_location(attrs \\ %{}) do
    %FileLocation{}
    |> FileLocation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a file location.
  """
  def update_file_location(%FileLocation{} = location, attrs) do
    location
    |> FileLocation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a file location.
  """
  def delete_file_location(%FileLocation{} = location) do
    Repo.delete(location)
  end

  # ===========================================================================
  # Dimension Functions
  # ===========================================================================

  @doc """
  Lists all dimensions.
  """
  def list_dimensions do
    Dimension
    |> order_by([d], asc: :order)
    |> Repo.all()
  end

  @doc """
  Lists enabled dimensions.
  """
  def list_enabled_dimensions do
    Dimension
    |> where([d], d.enabled == true)
    |> order_by([d], asc: :order)
    |> Repo.all()
  end

  @doc """
  Lists enabled dimensions for images.
  """
  def list_image_dimensions do
    Dimension
    |> where([d], d.enabled == true and d.applies_to in ["image", "both"])
    |> order_by([d], asc: :order)
    |> Repo.all()
  end

  @doc """
  Lists enabled dimensions for videos.
  """
  def list_video_dimensions do
    Dimension
    |> where([d], d.enabled == true and d.applies_to in ["video", "both"])
    |> order_by([d], asc: :order)
    |> Repo.all()
  end

  @doc """
  Gets a single dimension.
  """
  def get_dimension(id) do
    Repo.get(Dimension, id)
  end

  @doc """
  Gets a dimension by name.
  """
  def get_dimension_by_name(name) do
    Dimension
    |> where([d], d.name == ^name)
    |> Repo.one()
  end

  @doc """
  Creates a dimension.
  """
  def create_dimension(attrs \\ %{}) do
    %Dimension{}
    |> Dimension.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a dimension.
  """
  def update_dimension(%Dimension{} = dimension, attrs) do
    dimension
    |> Dimension.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a dimension.
  """
  def delete_dimension(%Dimension{} = dimension) do
    Repo.delete(dimension)
  end

  # ===========================================================================
  # URL Generation Functions
  # ===========================================================================

  @doc """
  Generates a signed URL for a file instance.

  ## Examples

      iex> Storage.signed_file_url("018e3c4a-...", "thumbnail")
      "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"
  """
  def signed_file_url(file_id, instance_name) do
    URLSigner.signed_url(file_id, instance_name)
  end

  @doc """
  Generates a signed URL with host.

  ## Examples

      iex> Storage.signed_file_url_with_host("018e3c4a-...", "thumbnail", "https://example.com")
      "https://example.com/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"
  """
  def signed_file_url_with_host(file_id, instance_name, host) do
    URLSigner.signed_url_with_host(file_id, instance_name, host)
  end

  @doc """
  Verifies a URL token.

  ## Examples

      iex> Storage.verify_file_token("018e3c4a-...", "thumbnail", "a3f2")
      true
  """
  def verify_file_token(file_id, instance_name, token) do
    URLSigner.verify_token(file_id, instance_name, token)
  end

  # ===========================================================================
  # Dashboard & Analytics Functions (for Phase 5)
  # ===========================================================================

  @doc """
  Gets storage statistics for admin dashboard.

  Returns total files, total size, files by type, etc.
  """
  def get_storage_stats do
    total_files = Repo.aggregate(File, :count, :id)

    total_size_bytes =
      File
      |> select([f], sum(f.size))
      |> Repo.one() || 0

    files_by_type =
      File
      |> group_by([f], f.file_type)
      |> select([f], {f.file_type, count(f.id)})
      |> Repo.all()
      |> Enum.into(%{})

    files_by_status =
      File
      |> group_by([f], f.status)
      |> select([f], {f.status, count(f.id)})
      |> Repo.all()
      |> Enum.into(%{})

    %{
      total_files: total_files,
      total_size_bytes: total_size_bytes,
      total_size_mb: div(total_size_bytes, 1_024 * 1_024),
      files_by_type: files_by_type,
      files_by_status: files_by_status
    }
  end

  @doc """
  Gets storage usage per bucket.
  """
  def get_bucket_usage_stats do
    list_buckets()
    |> Enum.map(fn bucket ->
      used_mb = calculate_bucket_usage(bucket.id)
      free_mb = calculate_bucket_free_space(bucket)

      %{
        bucket: bucket,
        used_mb: used_mb,
        free_mb: free_mb,
        max_mb: bucket.max_size_mb,
        usage_percent:
          if bucket.max_size_mb do
            round(used_mb / bucket.max_size_mb * 100)
          else
            nil
          end
      }
    end)
  end

  @doc """
  Gets top users by storage usage.
  """
  def get_user_storage_stats(limit \\ 10) do
    File
    |> group_by([f], f.user_id)
    |> select([f], %{
      user_id: f.user_id,
      file_count: count(f.id),
      total_size_bytes: sum(f.size)
    })
    |> order_by([f], desc: sum(f.size))
    |> limit(^limit)
    |> Repo.all()
  end
end
