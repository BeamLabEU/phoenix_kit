defmodule PhoenixKit.Sitemap.Cache do
  @moduledoc """
  Caching layer for sitemap generation.

  Manages both ETS cache (for entries/HTML) and file storage (for XML).
  When invalidated, clears both ETS cache and deletes the sitemap file,
  forcing regeneration on next request.

  ## Architecture

  - **XML Storage**: File-based (`priv/static/sitemap.xml`)
  - **Entries Cache**: ETS (in-memory, cleared on invalidate)
  - **HTML Cache**: Generated on-demand, not persisted

  ## Usage

      # Clear cache when content changes (deletes file + clears ETS)
      Cache.invalidate()

      # Check if ETS cache has entries
      Cache.has?(:entries)

  ## Cache Keys

  - `:entries` - Collected sitemap entries
  - `:parts` - Sitemap index parts for large sitemaps
  """

  alias PhoenixKit.Sitemap.FileStorage

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
  Clears all cached data and deletes the sitemap file.

  Should be called when sitemap content changes (new pages, updated content, etc).
  Next request to sitemap.xml will trigger fresh generation.

  ## Examples

      iex> Cache.invalidate()
      :ok
  """
  @spec invalidate() :: :ok
  def invalidate do
    # Delete sitemap file (primary XML storage)
    FileStorage.delete()

    # Clear generation stats (last_generated, url_count)
    # This indicates sitemap doesn't exist until regenerated
    PhoenixKit.Sitemap.clear_generation_stats()

    # Clear ETS caches
    if table_exists?() do
      # Clear entries (primary cache key)
      :ets.delete(@table_name, :entries)
      # Clear parts for sitemap index
      :ets.delete(@table_name, :parts)
      # Clear legacy keys for backward compatibility
      :ets.delete(@table_name, :xml)
      :ets.delete(@table_name, :html_table)
      :ets.delete(@table_name, :html_cards)
      :ets.delete(@table_name, :html_minimal)
      :ets.delete(@table_name, :xml_table)
      :ets.delete(@table_name, :xml_cards)
      :ets.delete(@table_name, :xml_minimal)
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
