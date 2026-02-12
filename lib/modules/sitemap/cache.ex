defmodule PhoenixKit.Modules.Sitemap.Cache do
  @moduledoc """
  Caching layer for sitemap generation.

  Manages ETS cache for entries, per-module XML, and index XML.
  When invalidated, clears ETS cache and deletes sitemap files.

  ## Cache Key Scheme

  - `:index_xml` - The sitemapindex XML content
  - `{:module_xml, "sitemap-shop"}` - Per-module XML content
  - `{:module_entries, :shop}` - Per-module collected entries
  - `:entries` - All collected entries (legacy)
  - `:parts` - Sitemap index parts (legacy)
  """

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.FileStorage

  @table_name :sitemap_cache

  @doc """
  Initializes the ETS cache table.

  Safe to call multiple times - returns :ok if table already exists.
  """
  @spec init() :: :ok
  def init do
    unless table_exists?() do
      :ets.new(@table_name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: false
      ])
    end

    :ok
  end

  @doc """
  Retrieves a cached value by key.
  """
  @spec get(term()) :: {:ok, any()} | :error
  def get(key) do
    init()

    case :ets.lookup(@table_name, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Stores a value in cache with the given key.
  """
  @spec put(term(), any()) :: :ok
  def put(key, value) do
    init()
    :ets.insert(@table_name, {key, value})
    :ok
  end

  @doc """
  Checks if a cached value exists for the given key.
  """
  @spec has?(term()) :: boolean()
  def has?(key) do
    init()

    case :ets.lookup(@table_name, key) do
      [{^key, _}] -> true
      [] -> false
    end
  end

  @doc """
  Deletes a specific cache entry.
  """
  @spec delete(term()) :: :ok
  def delete(key) do
    if table_exists?() do
      :ets.delete(@table_name, key)
    end

    :ok
  end

  # ── Per-module cache operations ────────────────────────────────────

  @doc """
  Caches XML content for a specific module.
  """
  @spec put_module(String.t(), String.t()) :: :ok
  def put_module(filename, xml) when is_binary(filename) and is_binary(xml) do
    put({:module_xml, filename}, xml)
  end

  @doc """
  Gets cached XML content for a specific module.
  """
  @spec get_module(String.t()) :: {:ok, String.t()} | :error
  def get_module(filename) when is_binary(filename) do
    get({:module_xml, filename})
  end

  @doc """
  Invalidates all cache keys for a specific source module.
  """
  @spec invalidate_module(String.t()) :: :ok
  def invalidate_module(filename) when is_binary(filename) do
    delete({:module_xml, filename})
    :ok
  end

  # ── Full invalidation ──────────────────────────────────────────────

  @doc """
  Clears all cached data and deletes all sitemap files.

  Should be called when sitemap content changes.
  """
  @spec invalidate() :: :ok
  def invalidate do
    # Delete sitemap files (index + all module files)
    FileStorage.delete()
    FileStorage.delete_all_modules()

    # Clear generation stats
    Sitemap.clear_generation_stats()

    # Clear all ETS entries
    if table_exists?() do
      :ets.delete_all_objects(@table_name)
    end

    :ok
  end

  @doc """
  Alias for `invalidate/0`.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all, do: invalidate()

  @doc """
  Returns cache statistics.
  """
  @spec stats() :: map()
  def stats do
    if table_exists?() do
      info = :ets.info(@table_name)

      %{
        size: Keyword.get(info, :size, 0),
        memory: Keyword.get(info, :memory, 0)
      }
    else
      %{size: 0, memory: 0}
    end
  end

  # Private helpers

  defp table_exists? do
    :ets.whereis(@table_name) != :undefined
  end
end
