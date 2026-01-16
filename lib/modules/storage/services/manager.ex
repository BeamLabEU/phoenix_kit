defmodule PhoenixKit.Modules.Storage.Manager do
  @moduledoc """
  Storage manager for handling file operations with redundancy and failover.

  This module coordinates file storage across multiple buckets with automatic
  redundancy, failover, and variant generation.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ProviderRegistry
  alias PhoenixKit.Settings

  # Cache TTL for bucket list (5 minutes)
  @buckets_cache_ttl 300_000

  @doc """
  Stores a file across multiple buckets based on redundancy settings.

  ## Options

  - `:redundancy_copies` - Number of copies to store (default: from settings)
  - `:priority_buckets` - List of specific bucket IDs to use (default: auto-select)
  - `:force_bucket_ids` - List of specific bucket IDs to use (overrides priority_buckets)
  - `:generate_variants` - Whether to generate variants (default: from settings)

  ## Returns

  - `{:ok, file_result}` - File stored successfully with locations
  - `{:error, reason}` - Failed to store file
  """
  def store_file(source_path, opts \\ []) do
    # Get redundancy settings
    redundancy_copies = Keyword.get(opts, :redundancy_copies, get_redundancy_copies())
    force_bucket_ids = Keyword.get(opts, :force_bucket_ids, [])
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    _generate_variants = Keyword.get(opts, :generate_variants, get_auto_generate_variants())

    # Use force_bucket_ids if provided, otherwise use priority_buckets
    buckets_to_use =
      if Enum.empty?(force_bucket_ids), do: priority_buckets, else: force_bucket_ids

    # Select buckets for storage
    buckets = select_buckets_for_storage(redundancy_copies, buckets_to_use)

    if Enum.empty?(buckets) do
      {:error, "No available storage buckets"}
    else
      # Store file across selected buckets
      store_across_buckets(source_path, buckets, opts)
    end
  rescue
    error -> {:error, "Error storing file: #{inspect(error)}"}
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
    if Enum.empty?(priority_buckets) do
      # Get fresh bucket list from database (don't use cache for selection)
      # This ensures we get the current state and can shuffle properly
      all_buckets = Storage.list_enabled_buckets()

      # Separate buckets by priority
      {auto_priority_buckets, fixed_priority_buckets} =
        Enum.split_with(all_buckets, &(&1.priority == 0))

      # Shuffle auto-priority buckets (priority = 0) for random distribution
      # Fixed priority buckets are deterministic
      shuffled_auto = Enum.shuffle(auto_priority_buckets)

      # Combine: fixed priority buckets first (sorted), then shuffled auto-priority
      (Enum.sort_by(fixed_priority_buckets, & &1.priority) ++ shuffled_auto)
      |> Enum.take(redundancy_copies)
    else
      # Use specified buckets
      Storage.list_enabled_buckets()
      |> Enum.filter(&(&1.id in priority_buckets))
      |> Enum.take(redundancy_copies)
    end
  end

  defp select_buckets_for_retrieval(priority_buckets) do
    if Enum.empty?(priority_buckets) do
      # Use all enabled buckets ordered by priority (simple sort, no usage calculation needed for retrieval)
      get_enabled_buckets()
      |> Enum.sort_by(& &1.priority)
    else
      # Use specified buckets
      get_enabled_buckets()
      |> Enum.filter(&(&1.id in priority_buckets))
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

  defp retrieve_with_failover(_file_path, [], _opts), do: {:error, "File not found in any bucket"}

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
    # Cache bucket list to avoid querying on every file request
    cache_key = :phoenix_kit_buckets_cache
    current_time = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {timestamp, buckets} when current_time - timestamp < @buckets_cache_ttl ->
        # Cache hit - return cached buckets
        buckets

      _ ->
        # Cache miss or expired - fetch fresh buckets
        buckets = Storage.list_enabled_buckets()
        :persistent_term.put(cache_key, {current_time, buckets})
        buckets
    end
  end

  defp get_redundancy_copies do
    Settings.get_setting_cached("storage_redundancy_copies", "1")
    |> String.to_integer()
    |> max(1)
    |> min(5)
  end

  defp get_auto_generate_variants do
    Settings.get_setting_cached("storage_auto_generate_variants", "true") == "true"
  end
end
