defmodule PhoenixKit.Cache do
  @moduledoc """
  Generic caching system for PhoenixKit with ETS-backed storage.

  This module provides a flexible caching foundation that can be used for:
  - Settings caching
  - User roles and permissions
  - Module configurations
  - Any frequently accessed data

  ## Features

  - ETS-backed storage for high-performance lookups
  - Automatic cache warming
  - TTL support for expiring data
  - Statistics tracking
  - Robust fallback mechanisms
  - Multiple cache instances via registry

  ## Usage

      # Start a cache instance
      {:ok, pid} = PhoenixKit.Cache.start_link(name: :my_cache, warmer: &MyApp.load_data/0)

      # Basic operations
      PhoenixKit.Cache.put(:my_cache, "key", "value")
      PhoenixKit.Cache.get(:my_cache, "key", "default")
      PhoenixKit.Cache.invalidate(:my_cache, "key")

      # Batch operations
      PhoenixKit.Cache.get_multiple(:my_cache, ["key1", "key2"], %{"key1" => "default1"})
      PhoenixKit.Cache.invalidate_multiple(:my_cache, ["key1", "key2"])

  ## Configuration

  Cache instances can be configured with:

  - `:name` - Unique name for the cache instance
  - `:warmer` - Function to warm the cache on startup
  - `:ttl` - Time-to-live for cache entries (optional)
  - `:max_size` - Maximum number of entries (optional)

  """

  use GenServer
  require Logger

  @type cache_name :: atom()
  @type cache_key :: any()
  @type cache_value :: any()
  @type default_value :: any()
  @type warmer_fun :: (-> map() | nil)

  @type options :: [
          name: cache_name(),
          warmer: warmer_fun(),
          ttl: pos_integer() | nil,
          max_size: pos_integer() | nil
        ]

  defstruct [
    :name,
    :table,
    :warmer,
    :ttl,
    :max_size,
    stats: %{
      hits: 0,
      misses: 0,
      puts: 0,
      invalidations: 0
    }
  ]

  @doc """
  Starts a new cache instance.

  ## Options

  - `:name` - Required. Unique name for the cache instance
  - `:warmer` - Optional. Function to warm the cache on startup
  - `:ttl` - Optional. Time-to-live for cache entries in milliseconds
  - `:max_size` - Optional. Maximum number of entries before eviction

  ## Examples

      {:ok, pid} = PhoenixKit.Cache.start_link(name: :settings)
      {:ok, pid} = PhoenixKit.Cache.start_link(name: :user_roles, warmer: &MyApp.load_user_roles/0)

  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  @doc """
  Gets a value from the cache.

  Returns the default value if the key is not found or the cache is unavailable.

  ## Examples

      PhoenixKit.Cache.get(:settings, "date_format", "Y-m-d")
      PhoenixKit.Cache.get(:user_roles, user_id, [])

  """
  @spec get(cache_name(), cache_key(), default_value()) :: cache_value()
  def get(cache_name, key, default \\ nil) do
    GenServer.call(via_tuple(cache_name), {:get, key, default}, 5000)
  rescue
    error in [ArgumentError, RuntimeError] ->
      # Only log if not during compilation (when registry doesn't exist)
      unless compilation_or_test_mode?() do
        Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      end

      default
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Cache #{cache_name} timeout")
      default

    :exit, {:noproc, _} ->
      # Only log if not during compilation
      unless compilation_or_test_mode?() do
        Logger.warning("Cache #{cache_name} not started")
      end

      default
  end

  @doc """
  Gets multiple values from the cache.

  Returns a map with the requested keys and their values, using defaults for missing keys.

  ## Examples

      defaults = %{"date_format" => "Y-m-d", "time_format" => "H:i"}
      PhoenixKit.Cache.get_multiple(:settings, ["date_format", "time_format"], defaults)

  """
  @spec get_multiple(cache_name(), [cache_key()], map()) :: map()
  def get_multiple(cache_name, keys, defaults \\ %{}) do
    GenServer.call(via_tuple(cache_name), {:get_multiple, keys, defaults}, 5000)
  rescue
    error in [ArgumentError, RuntimeError] ->
      unless compilation_or_test_mode?() do
        Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      end

      defaults
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Cache #{cache_name} timeout")
      defaults

    :exit, {:noproc, _} ->
      unless compilation_or_test_mode?() do
        Logger.warning("Cache #{cache_name} not started")
      end

      defaults
  end

  @doc """
  Puts a value in the cache.

  ## Examples

      PhoenixKit.Cache.put(:settings, "date_format", "m/d/Y")
      PhoenixKit.Cache.put(:user_roles, user_id, ["admin", "user"])

  """
  @spec put(cache_name(), cache_key(), cache_value()) :: :ok
  def put(cache_name, key, value) do
    GenServer.cast(via_tuple(cache_name), {:put, key, value})
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      :ok
  catch
    :exit, {:noproc, _} ->
      Logger.warning("Cache #{cache_name} not started")
      :ok
  end

  @doc """
  Puts multiple values in the cache.

  ## Examples

      PhoenixKit.Cache.put_multiple(:settings, %{"date_format" => "m/d/Y", "time_format" => "h:i A"})

  """
  @spec put_multiple(cache_name(), map()) :: :ok
  def put_multiple(cache_name, key_values) do
    GenServer.cast(via_tuple(cache_name), {:put_multiple, key_values})
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      :ok
  catch
    :exit, {:noproc, _} ->
      Logger.warning("Cache #{cache_name} not started")
      :ok
  end

  @doc """
  Invalidates a key in the cache.

  ## Examples

      PhoenixKit.Cache.invalidate(:settings, "date_format")

  """
  @spec invalidate(cache_name(), cache_key()) :: :ok
  def invalidate(cache_name, key) do
    GenServer.cast(via_tuple(cache_name), {:invalidate, key})
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      :ok
  catch
    :exit, {:noproc, _} ->
      Logger.warning("Cache #{cache_name} not started")
      :ok
  end

  @doc """
  Invalidates multiple keys in the cache.

  ## Examples

      PhoenixKit.Cache.invalidate_multiple(:settings, ["date_format", "time_format"])

  """
  @spec invalidate_multiple(cache_name(), [cache_key()]) :: :ok
  def invalidate_multiple(cache_name, keys) do
    GenServer.cast(via_tuple(cache_name), {:invalidate_multiple, keys})
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      :ok
  catch
    :exit, {:noproc, _} ->
      Logger.warning("Cache #{cache_name} not started")
      :ok
  end

  @doc """
  Clears all entries from the cache.

  ## Examples

      PhoenixKit.Cache.clear(:settings)

  """
  @spec clear(cache_name()) :: :ok
  def clear(cache_name) do
    GenServer.cast(via_tuple(cache_name), :clear)
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      :ok
  catch
    :exit, {:noproc, _} ->
      Logger.warning("Cache #{cache_name} not started")
      :ok
  end

  @doc """
  Gets cache statistics.

  ## Examples

      PhoenixKit.Cache.stats(:settings)
      # => %{hits: 150, misses: 5, puts: 20, invalidations: 3, hit_rate: 0.97}

  """
  @spec stats(cache_name()) :: map()
  def stats(cache_name) do
    GenServer.call(via_tuple(cache_name), :stats, 5000)
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Cache #{cache_name} timeout")
      %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}

    :exit, {:noproc, _} ->
      Logger.warning("Cache #{cache_name} not started")
      %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}
  end

  @doc """
  Warms the cache using the configured warmer function.

  ## Examples

      PhoenixKit.Cache.warm(:settings)

  """
  @spec warm(cache_name()) :: :ok
  def warm(cache_name) do
    GenServer.cast(via_tuple(cache_name), :warm)
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Cache #{cache_name} unavailable: #{inspect(error)}")
      :ok
  catch
    :exit, {:noproc, _} ->
      Logger.warning("Cache #{cache_name} not started")
      :ok
  end

  # GenServer Callbacks

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    warmer = Keyword.get(opts, :warmer)
    ttl = Keyword.get(opts, :ttl)
    max_size = Keyword.get(opts, :max_size)

    table =
      :ets.new(:"cache_#{name}", [:set, :protected, :named_table, {:read_concurrency, true}])

    state = %__MODULE__{
      name: name,
      table: table,
      warmer: warmer,
      ttl: ttl,
      max_size: max_size
    }

    # Warm cache if warmer function is provided
    if warmer do
      send(self(), :warm_cache)
    end

    Logger.info("Started cache #{name} with table #{table}")
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:get, key, default}, _from, %{table: table, stats: stats} = state) do
    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] when is_integer(expires_at) ->
        if System.monotonic_time(:millisecond) < expires_at do
          new_stats = %{stats | hits: stats.hits + 1}
          {:reply, value, %{state | stats: new_stats}}
        else
          :ets.delete(table, key)
          new_stats = %{stats | misses: stats.misses + 1}
          {:reply, default, %{state | stats: new_stats}}
        end

      [{^key, value}] ->
        new_stats = %{stats | hits: stats.hits + 1}
        {:reply, value, %{state | stats: new_stats}}

      [] ->
        new_stats = %{stats | misses: stats.misses + 1}
        {:reply, default, %{state | stats: new_stats}}
    end
  end

  @impl GenServer
  def handle_call({:get_multiple, keys, defaults}, _from, %{table: table, stats: stats} = state) do
    {result, hits, misses} =
      Enum.reduce(keys, {%{}, 0, 0}, fn key, {acc, hits, misses} ->
        case :ets.lookup(table, key) do
          [{^key, value, expires_at}] when is_integer(expires_at) ->
            if System.monotonic_time(:millisecond) < expires_at do
              {Map.put(acc, key, value), hits + 1, misses}
            else
              :ets.delete(table, key)
              default_value = Map.get(defaults, key)
              {Map.put(acc, key, default_value), hits, misses + 1}
            end

          [{^key, value}] ->
            {Map.put(acc, key, value), hits + 1, misses}

          [] ->
            default_value = Map.get(defaults, key)
            {Map.put(acc, key, default_value), hits, misses + 1}
        end
      end)

    new_stats = %{stats | hits: stats.hits + hits, misses: stats.misses + misses}
    {:reply, result, %{state | stats: new_stats}}
  end

  @impl GenServer
  def handle_call(:stats, _from, %{stats: stats} = state) do
    total = stats.hits + stats.misses
    hit_rate = if total > 0, do: stats.hits / total, else: 0.0

    response = Map.put(stats, :hit_rate, hit_rate)
    {:reply, response, state}
  end

  @impl GenServer
  def handle_cast({:put, key, value}, %{table: table, ttl: ttl, stats: stats} = state) do
    entry =
      if ttl do
        {key, value, System.monotonic_time(:millisecond) + ttl}
      else
        {key, value}
      end

    :ets.insert(table, entry)
    new_stats = %{stats | puts: stats.puts + 1}

    {:noreply, maybe_evict(%{state | stats: new_stats})}
  end

  @impl GenServer
  def handle_cast({:put_multiple, key_values}, %{table: table, ttl: ttl, stats: stats} = state) do
    entries =
      if ttl do
        expires_at = System.monotonic_time(:millisecond) + ttl
        Enum.map(key_values, fn {key, value} -> {key, value, expires_at} end)
      else
        Enum.map(key_values, fn {key, value} -> {key, value} end)
      end

    :ets.insert(table, entries)
    new_stats = %{stats | puts: stats.puts + map_size(key_values)}

    {:noreply, maybe_evict(%{state | stats: new_stats})}
  end

  @impl GenServer
  def handle_cast({:invalidate, key}, %{table: table, stats: stats} = state) do
    :ets.delete(table, key)
    new_stats = %{stats | invalidations: stats.invalidations + 1}
    {:noreply, %{state | stats: new_stats}}
  end

  @impl GenServer
  def handle_cast({:invalidate_multiple, keys}, %{table: table, stats: stats} = state) do
    Enum.each(keys, &:ets.delete(table, &1))
    new_stats = %{stats | invalidations: stats.invalidations + length(keys)}
    {:noreply, %{state | stats: new_stats}}
  end

  @impl GenServer
  def handle_cast(:clear, %{table: table, stats: stats} = state) do
    count = :ets.info(table, :size)
    :ets.delete_all_objects(table)
    new_stats = %{stats | invalidations: stats.invalidations + count}
    {:noreply, %{state | stats: new_stats}}
  end

  @impl GenServer
  def handle_cast(:warm, %{warmer: nil} = state) do
    Logger.warning("Cannot warm cache #{state.name}: no warmer function configured")
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:warm, %{warmer: warmer} = state) do
    case safe_warm(warmer) do
      {:ok, data} when is_map(data) ->
        put_multiple(state.name, data)
        Logger.info("Warmed cache #{state.name} with #{map_size(data)} entries")

      {:error, error} ->
        Logger.warning("Failed to warm cache #{state.name}: #{inspect(error)}")

      _ ->
        Logger.warning("Warmer for cache #{state.name} returned invalid data (expected map)")
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:warm_cache, state) do
    handle_cast(:warm, state)
  end

  # Private Functions

  defp via_tuple(name) do
    PhoenixKit.Cache.Registry.via_tuple(name)
  end

  defp safe_warm(warmer) when is_function(warmer, 0) do
    {:ok, warmer.()}
  rescue
    error -> {:error, error}
  end

  defp maybe_evict(%{max_size: nil} = state), do: state

  defp maybe_evict(%{table: table, max_size: max_size} = state) do
    current_size = :ets.info(table, :size)

    if current_size > max_size do
      # Simple FIFO eviction - delete oldest entries
      excess = current_size - max_size

      :ets.first(table)
      |> evict_n_entries(table, excess)
    end

    state
  end

  defp evict_n_entries(_key, _table, 0), do: :ok
  defp evict_n_entries(:"$end_of_table", _table, _n), do: :ok

  defp evict_n_entries(key, table, n) do
    next_key = :ets.next(table, key)
    :ets.delete(table, key)
    evict_n_entries(next_key, table, n - 1)
  end

  # Check if we're in compilation or test mode where cache infrastructure may not be available
  defp compilation_or_test_mode? do
    # During compilation, the application environment is not fully loaded
    # Check if we're in a context where the registry hasn't been started
    case Registry.whereis_name({PhoenixKit.Cache.Registry, :settings}) do
      :undefined -> true
      pid when is_pid(pid) -> false
    end
  rescue
    # If Registry module isn't available or any error occurs, assume compilation mode
    _ -> true
  end
end
