defmodule PhoenixKit.Sitemap.Cache do
  @moduledoc """
  ETS-based caching layer for sitemap generation.

  Provides fast in-memory caching for generated XML and HTML sitemaps
  to avoid regenerating them on every request. Cache can be invalidated
  when content changes.

  ## Usage

      # Initialize cache table (usually in application startup)
      Cache.init()

      # Store generated sitemap
      Cache.put(:xml, xml_content)
      Cache.put(:html, html_content)

      # Retrieve cached sitemap
      case Cache.get(:xml) do
        {:ok, content} -> content
        :error -> generate_new_sitemap()
      end

      # Clear cache when content changes
      Cache.invalidate()

  ## Cache Keys

  - `:xml` - Full XML sitemap
  - `:html` - HTML sitemap
  - `:parts` - List of sitemap part files for sitemap index
  """

  @table_name :sitemap_cache

  @doc """
  Initializes the ETS cache table.

  Creates a public named table with read concurrency for optimal performance.
  Safe to call multiple times - returns :ok if table already exists.

  ## Examples

      iex> Cache.init()
      :ok

      iex> Cache.init()
      :ok  # Idempotent
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

  ## Examples

      iex> Cache.get(:xml)
      {:ok, "<?xml version=..."}

      iex> Cache.get(:nonexistent)
      :error
  """
  @spec get(atom()) :: {:ok, any()} | :error
  def get(key) when is_atom(key) do
    init()

    case :ets.lookup(@table_name, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Stores a value in cache with the given key.

  ## Examples

      iex> Cache.put(:xml, xml_content)
      :ok

      iex> Cache.put(:html, html_content)
      :ok
  """
  @spec put(atom(), any()) :: :ok
  def put(key, value) when is_atom(key) do
    init()
    :ets.insert(@table_name, {key, value})
    :ok
  end

  @doc """
  Clears all cached data.

  Should be called when sitemap content changes (new pages, updated content, etc).
  Clears entries cache and any legacy xml cache.

  ## Examples

      iex> Cache.invalidate()
      :ok
  """
  @spec invalidate() :: :ok
  def invalidate do
    if table_exists?() do
      # Clear entries (primary cache key)
      :ets.delete(@table_name, :entries)
      # Clear legacy keys for backward compatibility
      :ets.delete(@table_name, :xml)
      :ets.delete(@table_name, :parts)
      # Clear HTML caches
      :ets.delete(@table_name, :html_table)
      :ets.delete(@table_name, :html_cards)
      :ets.delete(@table_name, :html_minimal)
    end

    :ok
  end

  @doc """
  Checks if a cached value exists for the given key.

  ## Examples

      iex> Cache.has?(:xml)
      true

      iex> Cache.has?(:nonexistent)
      false
  """
  @spec has?(atom()) :: boolean()
  def has?(key) when is_atom(key) do
    init()

    case :ets.lookup(@table_name, key) do
      [{^key, _}] -> true
      [] -> false
    end
  end

  @doc """
  Deletes a specific cache entry.

  ## Examples

      iex> Cache.delete(:xml)
      :ok
  """
  @spec delete(atom()) :: :ok
  def delete(key) when is_atom(key) do
    if table_exists?() do
      :ets.delete(@table_name, key)
    end

    :ok
  end

  @doc """
  Returns cache statistics.

  ## Examples

      iex> Cache.stats()
      %{size: 2, memory: 1024}
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
