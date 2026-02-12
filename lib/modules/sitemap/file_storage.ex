defmodule PhoenixKit.Modules.Sitemap.FileStorage do
  @moduledoc """
  File-based storage for sitemap XML files.

  Supports both a single index file and per-module sitemap files:

      priv/static/sitemap.xml                     -> sitemapindex (index)
      priv/static/sitemaps/sitemap-static.xml     -> static pages
      priv/static/sitemaps/sitemap-routes.xml     -> router discovery
      priv/static/sitemaps/sitemap-publishing.xml -> publishing posts
      priv/static/sitemaps/sitemap-shop.xml       -> shop products
      priv/static/sitemaps/sitemap-entities.xml   -> entity records

  ## Key Features

  - **Direct nginx serving** - Files in priv/static/ can be served without Phoenix
  - **ETag from mtime** - Use `get_file_stat/0` for cache validation
  - **On-demand generation** - First request generates if file missing
  - **Per-module files** - Independent generation and caching per source
  """

  require Logger

  @sitemap_file "sitemap.xml"
  @sitemaps_subdir "sitemaps"

  # ── Index file operations (sitemap.xml) ────────────────────────────

  @doc """
  Saves XML content to the index sitemap file.
  """
  @spec save_index(String.t()) :: :ok | {:error, term()}
  def save_index(xml_content), do: save(xml_content)

  @doc """
  Loads XML content from the index sitemap file.
  """
  @spec load_index() :: {:ok, String.t()} | :error
  def load_index, do: load()

  @doc """
  Checks if the index sitemap file exists.
  """
  @spec index_exists?() :: boolean()
  def index_exists?, do: exists?()

  # ── Per-module file operations (sitemaps/*.xml) ────────────────────

  @doc """
  Saves XML content for a specific module sitemap file.

  Filename should NOT include the `.xml` extension.

  ## Examples

      FileStorage.save_module("sitemap-shop", xml_content)
      # Saves to priv/static/sitemaps/sitemap-shop.xml
  """
  @spec save_module(String.t(), String.t()) :: :ok | {:error, term()}
  def save_module(filename, xml_content)
      when is_binary(filename) and is_binary(xml_content) do
    path = module_file_path(filename)

    with :ok <- ensure_directory_exists(path),
         :ok <- File.write(path, xml_content) do
      Logger.debug("FileStorage: Saved #{filename}.xml (#{byte_size(xml_content)} bytes)")

      :ok
    else
      {:error, reason} = error ->
        Logger.warning("FileStorage: Failed to save #{filename}.xml: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Loads XML content for a specific module sitemap file.
  """
  @spec load_module(String.t()) :: {:ok, String.t()} | :error
  def load_module(filename) when is_binary(filename) do
    path = module_file_path(filename)

    case File.read(path) do
      {:ok, content} ->
        Logger.debug("FileStorage: Loaded #{filename}.xml from file")
        {:ok, content}

      {:error, :enoent} ->
        :error

      {:error, reason} ->
        Logger.warning("FileStorage: Failed to read #{filename}.xml: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Checks if a specific module sitemap file exists.
  """
  @spec module_exists?(String.t()) :: boolean()
  def module_exists?(filename) when is_binary(filename) do
    filename |> module_file_path() |> File.exists?()
  end

  @doc """
  Deletes a specific module sitemap file.
  """
  @spec delete_module(String.t()) :: :ok
  def delete_module(filename) when is_binary(filename) do
    path = module_file_path(filename)

    case File.rm(path) do
      :ok ->
        Logger.debug("FileStorage: Deleted #{filename}.xml")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("FileStorage: Failed to delete #{filename}.xml: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Returns file stats for a specific module sitemap file.
  """
  @spec get_module_stat(String.t()) :: {:ok, tuple(), non_neg_integer()} | :error
  def get_module_stat(filename) when is_binary(filename) do
    case File.stat(module_file_path(filename)) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, mtime, size}
      {:error, _} -> :error
    end
  end

  @doc """
  Lists all `.xml` files in the sitemaps subdirectory.

  Returns list of filenames without the `.xml` extension.
  """
  @spec list_module_files() :: [String.t()]
  def list_module_files do
    dir = sitemaps_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".xml"))
      |> Enum.map(&String.trim_trailing(&1, ".xml"))
      |> Enum.sort()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Deletes all module sitemap files in the sitemaps subdirectory.
  """
  @spec delete_all_modules() :: :ok
  def delete_all_modules do
    dir = sitemaps_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".xml"))
      |> Enum.each(fn file ->
        File.rm(Path.join(dir, file))
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Returns the path to the sitemaps subdirectory.
  """
  @spec sitemaps_dir() :: String.t()
  def sitemaps_dir do
    Path.join(storage_dir(), @sitemaps_subdir)
  end

  @doc """
  Returns the full path for a module sitemap file.
  """
  @spec module_file_path(String.t()) :: String.t()
  def module_file_path(filename) when is_binary(filename) do
    Path.join(sitemaps_dir(), "#{filename}.xml")
  end

  # ── Legacy / backward-compatible API ───────────────────────────────

  @doc """
  Saves XML content to the sitemap file.

  Creates the storage directory if it doesn't exist.
  """
  @spec save(String.t()) :: :ok | {:error, term()}
  def save(xml_content) when is_binary(xml_content) do
    path = file_path()

    with :ok <- ensure_directory_exists(path),
         :ok <- File.write(path, xml_content) do
      Logger.debug("FileStorage: Saved sitemap.xml (#{byte_size(xml_content)} bytes)")
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("FileStorage: Failed to save sitemap.xml: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Loads XML content from the sitemap file.
  """
  @spec load() :: {:ok, String.t()} | :error
  def load do
    path = file_path()

    case File.read(path) do
      {:ok, content} ->
        Logger.debug("FileStorage: Loaded sitemap.xml from file")
        {:ok, content}

      {:error, :enoent} ->
        :error

      {:error, reason} ->
        Logger.warning("FileStorage: Failed to read sitemap.xml: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Checks if the sitemap file exists.
  """
  @spec exists?() :: boolean()
  def exists? do
    file_path() |> File.exists?()
  end

  @doc """
  Returns file stats for ETag generation.
  """
  @spec get_file_stat() :: {:ok, tuple(), non_neg_integer()} | :error
  def get_file_stat do
    case File.stat(file_path()) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, mtime, size}
      {:error, _} -> :error
    end
  end

  @doc """
  Deletes the sitemap file to force regeneration.
  """
  @spec delete() :: :ok
  def delete do
    case File.rm(file_path()) do
      :ok ->
        Logger.debug("FileStorage: Deleted sitemap.xml")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("FileStorage: Failed to delete sitemap.xml: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Returns the file path for the sitemap.
  """
  @spec file_path() :: String.t()
  def file_path do
    Path.join(storage_dir(), @sitemap_file)
  end

  @doc """
  Returns the storage directory path.
  """
  @spec storage_dir() :: String.t()
  def storage_dir do
    case :code.priv_dir(:phoenix_kit) do
      {:error, :bad_name} -> "priv/static"
      priv_dir -> Path.join(priv_dir, "static")
    end
  end

  @doc """
  Clears the sitemap file. Alias for `delete/0`.
  """
  @spec clear_all() :: :ok
  def clear_all do
    delete()
    delete_all_modules()
  end

  # Legacy API compatibility - style parameter ignored

  @doc false
  @spec save(String.t(), String.t()) :: :ok | {:error, term()}
  def save(_style, xml_content), do: save(xml_content)

  @doc false
  @spec load(String.t()) :: {:ok, String.t()} | :error
  def load(_style), do: load()

  @doc false
  @spec exists?(String.t()) :: boolean()
  def exists?(_style), do: exists?()

  @doc false
  @spec file_path(String.t()) :: String.t()
  def file_path(_style), do: file_path()

  # Private helpers

  defp ensure_directory_exists(file_path) do
    dir = Path.dirname(file_path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end
end
