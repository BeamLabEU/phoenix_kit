defmodule PhoenixKit.Modules.Sitemap.FileStorage do
  @moduledoc """
  File-based storage for sitemap XML.

  Sitemaps are saved to priv/static/sitemap.xml for direct nginx/CDN serving.
  This is the primary storage - no ETS caching layer needed.

  ## Key Features

  - **Direct nginx serving** - Files in priv/static/ can be served without Phoenix
  - **ETag from mtime** - Use `get_file_stat/0` for cache validation
  - **On-demand generation** - First request generates if file missing

  ## Usage

      # Save sitemap XML
      FileStorage.save(xml_content)

      # Load sitemap XML
      case FileStorage.load() do
        {:ok, xml} -> send_resp(conn, 200, xml)
        :error -> generate_and_serve(conn)
      end

      # Check if file exists
      FileStorage.exists?()

      # Get file stats for ETag
      {:ok, mtime, size} = FileStorage.get_file_stat()

      # Delete to force regeneration
      FileStorage.delete()
  """

  require Logger

  @sitemap_file "sitemap.xml"

  @doc """
  Saves XML content to the sitemap file.

  Creates the storage directory if it doesn't exist.

  ## Examples

      iex> FileStorage.save("<?xml ...")
      :ok
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

  ## Examples

      iex> FileStorage.load()
      {:ok, "<?xml ..."}

      iex> FileStorage.load()  # when file doesn't exist
      :error
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

  ## Examples

      iex> FileStorage.exists?()
      true
  """
  @spec exists?() :: boolean()
  def exists? do
    file_path()
    |> File.exists?()
  end

  @doc """
  Returns file stats for ETag generation.

  Uses mtime and size for cache validation - more reliable than
  database-based config values.

  ## Examples

      iex> FileStorage.get_file_stat()
      {:ok, {{2025, 1, 15}, {10, 30, 0}}, 12345}

      iex> FileStorage.get_file_stat()  # file doesn't exist
      :error
  """
  @spec get_file_stat() :: {:ok, tuple(), non_neg_integer()} | :error
  def get_file_stat do
    case File.stat(file_path()) do
      {:ok, %{mtime: mtime, size: size}} ->
        {:ok, mtime, size}

      {:error, _} ->
        :error
    end
  end

  @doc """
  Deletes the sitemap file to force regeneration.

  Next request will trigger fresh generation.

  ## Examples

      iex> FileStorage.delete()
      :ok
  """
  @spec delete() :: :ok
  def delete do
    case File.rm(file_path()) do
      :ok ->
        Logger.debug("FileStorage: Deleted sitemap.xml")
        :ok

      {:error, :enoent} ->
        # File doesn't exist - that's fine
        :ok

      {:error, reason} ->
        Logger.warning("FileStorage: Failed to delete sitemap.xml: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Returns the file path for the sitemap.

  Path: priv/static/sitemap.xml (allows nginx direct serving)
  """
  @spec file_path() :: String.t()
  def file_path do
    Path.join(storage_dir(), @sitemap_file)
  end

  @doc """
  Returns the storage directory path.

  Uses priv/static for nginx/CDN compatibility.
  """
  @spec storage_dir() :: String.t()
  def storage_dir do
    case :code.priv_dir(:phoenix_kit) do
      {:error, :bad_name} ->
        # Fallback for development/test
        "priv/static"

      priv_dir ->
        Path.join(priv_dir, "static")
    end
  end

  @doc """
  Clears the sitemap file.

  Alias for `delete/0` for API consistency.
  """
  @spec clear_all() :: :ok
  def clear_all do
    delete()
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
