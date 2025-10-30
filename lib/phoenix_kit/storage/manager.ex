defmodule PhoenixKit.Storage.Manager do
  @moduledoc """
  Storage manager for handling file operations with redundancy and failover.

  This module coordinates file storage across multiple buckets with automatic
  redundancy, failover, and variant generation.
  """

  alias PhoenixKit.Storage.ProviderRegistry

  @doc """
  Stores a file across multiple buckets based on redundancy settings.

  ## Options

  - `:redundancy_copies` - Number of copies to store (default: from settings)
  - `:priority_buckets` - List of specific bucket IDs to use (default: auto-select)
  - `:generate_variants` - Whether to generate variants (default: from settings)

  ## Returns

  - `{:ok, file_result}` - File stored successfully with locations
  - `{:error, reason}` - Failed to store file
  """
  def store_file(source_path, opts \\ []) do
    try do
      # Get redundancy settings
      redundancy_copies = Keyword.get(opts, :redundancy_copies, get_redundancy_copies())
      priority_buckets = Keyword.get(opts, :priority_buckets, [])
      generate_variants = Keyword.get(opts, :generate_variants, get_auto_generate_variants())

      # Select buckets for storage
      buckets = select_buckets_for_storage(redundancy_copies, priority_buckets)

      if Enum.empty?(buckets) do
        {:error, "No available storage buckets"}
      else
        # Store file across selected buckets
        store_across_buckets(source_path, buckets, opts)
      end
    rescue
      error -> {:error, "Error storing file: #{inspect(error)}"}
    end
  end

  @doc """
  Retrieves a file from storage with failover.

  Tries each bucket in priority order until the file is found.
  """
  def retrieve_file(file_path, opts \\ []) do
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    buckets = select_buckets_for_retrieval(priority_buckets)

    retrieve_with_failover(file_path, buckets, opts)
  end

  @doc """
  Deletes a file from all storage buckets.
  """
  def delete_file(file_path, opts \\ []) do
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    buckets = select_buckets_for_retrieval(priority_buckets)

    results =
      buckets
      |> Enum.map(fn bucket ->
        provider = get_provider_for_bucket(bucket)
        provider.delete_file(bucket, file_path)
      end)

    # Return success if at least one deletion succeeded
    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, "Failed to delete file from all buckets"}
    end
  end

  @doc """
  Checks if a file exists in any storage bucket.
  """
  def file_exists?(file_path, opts \\ []) do
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    buckets = select_buckets_for_retrieval(priority_buckets)

    Enum.any?(buckets, fn bucket ->
      provider = get_provider_for_bucket(bucket)
      provider.file_exists?(bucket, file_path)
    end)
  end

  @doc """
  Gets a public URL for a file from the highest priority bucket that has it.
  """
  def public_url(file_path, opts \\ []) do
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    buckets = select_buckets_for_retrieval(priority_buckets)

    Enum.find_value(buckets, fn bucket ->
      provider = get_provider_for_bucket(bucket)

      if provider.file_exists?(bucket, file_path) do
        provider.public_url(bucket, file_path)
      else
        nil
      end
    end)
  end

  # Private functions

  defp select_buckets_for_storage(redundancy_copies, priority_buckets) do
    cond do
      not Enum.empty?(priority_buckets) ->
        # Use specified buckets
        get_enabled_buckets()
        |> Enum.filter(&(&1.id in priority_buckets))
        |> Enum.take(redundancy_copies)

      true ->
        # Auto-select buckets based on priority and available space
        get_enabled_buckets()
        |> Enum.sort_by(&bucket_priority/1)
        |> Enum.take(redundancy_copies)
    end
  end

  defp select_buckets_for_retrieval(priority_buckets) do
    cond do
      not Enum.empty?(priority_buckets) ->
        # Use specified buckets
        get_enabled_buckets()
        |> Enum.filter(&(&1.id in priority_buckets))

      true ->
        # Use all enabled buckets ordered by priority
        get_enabled_buckets()
        |> Enum.sort_by(&bucket_priority/1)
    end
  end

  defp store_across_buckets(source_path, buckets, opts) do
    # Use path_prefix if provided, otherwise generate a path
    destination_path =
      case Keyword.get(opts, :path_prefix) do
        nil -> generate_destination_path(source_path, opts)
        path_prefix -> path_prefix
      end

    results =
      buckets
      |> Enum.map(fn bucket ->
        provider = get_provider_for_bucket(bucket)
        provider.store_file(bucket, source_path, destination_path, opts)
      end)

    # Check if at least one storage succeeded
    successful_storages = Enum.count(results, &(&1 == :ok or match?({:ok, _}, &1)))

    if successful_storages > 0 do
      file_info = %{
        destination_path: destination_path,
        stored_in: length(buckets),
        successful_storages: successful_storages,
        bucket_ids: Enum.map(buckets, & &1.id)
      }

      {:ok, file_info}
    else
      {:error, "Failed to store file in any bucket"}
    end
  end

  defp retrieve_with_failover(file_path, [], _opts), do: {:error, "File not found in any bucket"}

  defp retrieve_with_failover(file_path, [bucket | remaining_buckets], opts) do
    provider = get_provider_for_bucket(bucket)
    destination_path = Keyword.get(opts, :destination_path, generate_temp_path())

    case provider.retrieve_file(bucket, file_path, destination_path) do
      :ok ->
        {:ok, destination_path}

      {:error, _reason} ->
        retrieve_with_failover(file_path, remaining_buckets, opts)
    end
  end

  defp get_provider_for_bucket(bucket) do
    {:ok, provider_module} = ProviderRegistry.get_provider(bucket.provider)
    provider_module
  end

  defp bucket_priority(bucket) do
    cond do
      bucket.priority == 0 ->
        # Random priority - use available space as tiebreaker
        used_space = PhoenixKit.Storage.calculate_bucket_usage(bucket.id)
        # Large default
        max_space = bucket.max_size_mb || 1_000_000
        free_space_ratio = (max_space - used_space) / max_space
        # Negative for descending sort
        {0, -free_space_ratio}

      true ->
        {bucket.priority, 0}
    end
  end

  defp generate_destination_path(source_path, opts) do
    original_name = Path.basename(source_path)
    extension = Path.extname(original_name)
    base_name = Path.rootname(original_name)

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    random_suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prefix = Keyword.get(opts, :path_prefix, "")
    subdir = Keyword.get(opts, :subdir, timestamp)

    Path.join([prefix, subdir, "#{base_name}_#{random_suffix}#{extension}"])
  end

  defp generate_temp_path do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_#{random_name}")
  end

  defp get_enabled_buckets do
    PhoenixKit.Storage.list_enabled_buckets()
  end

  defp repo do
    # Get the repository from application config or use a default
    Application.get_env(:phoenix_kit, :repo) || PhoenixKit.Repo
  end

  defp get_redundancy_copies do
    PhoenixKit.Settings.get_setting("storage_redundancy_copies", "2")
    |> String.to_integer()
    |> max(1)
    |> min(5)
  end

  defp get_auto_generate_variants do
    PhoenixKit.Settings.get_setting("storage_auto_generate_variants", "true") == "true"
  end
end
