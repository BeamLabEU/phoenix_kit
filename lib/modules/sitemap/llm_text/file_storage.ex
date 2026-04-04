defmodule PhoenixKit.Modules.Sitemap.LLMText.FileStorage do
  @moduledoc """
  File-based storage for LLM text files.

  Stores files under the host app's `priv/static/llms/` directory:

      priv/static/llms/llms.txt          -> index file
      priv/static/llms/page.md           -> individual page file
      priv/static/llms/posts/article.md  -> nested page file

  ## Test Override

  Set `Application.put_env(:phoenix_kit, :sitemap_llm_text_test_storage_dir, "/tmp/...")` to
  override the storage directory in tests.
  """

  require Logger

  @index_filename "llms.txt"

  @doc """
  Returns the root storage directory for LLM text files.

  Uses test override if configured, otherwise resolves to the host app's
  `priv/static/llms/` directory.
  """
  @spec storage_dir() :: String.t()
  def storage_dir do
    case Application.get_env(:phoenix_kit, :sitemap_llm_text_test_storage_dir) do
      nil -> resolve_storage_dir()
      dir -> dir
    end
  end

  @doc """
  Returns the path to the llms.txt index file.
  """
  @spec index_path() :: String.t()
  def index_path do
    Path.join(storage_dir(), @index_filename)
  end

  @doc """
  Returns the full path for a relative file path within the storage directory.
  """
  @spec file_path(String.t()) :: String.t()
  def file_path(relative_path) when is_binary(relative_path) do
    Path.join(storage_dir(), relative_path)
  end

  @doc """
  Writes content to a file at the given relative path, creating directories as needed.
  """
  @spec write(String.t(), String.t()) :: :ok | {:error, term()}
  def write(relative_path, content) when is_binary(relative_path) and is_binary(content) do
    path = file_path(relative_path)

    with :ok <- ensure_directory_exists(path),
         :ok <- File.write(path, content) do
      Logger.debug(
        "Sitemap.LLMText.FileStorage: Wrote #{relative_path} (#{byte_size(content)} bytes)"
      )

      :ok
    else
      {:error, reason} = error ->
        Logger.warning(
          "Sitemap.LLMText.FileStorage: Failed to write #{relative_path}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Writes the llms.txt index file.
  """
  @spec write_index(String.t()) :: :ok | {:error, term()}
  def write_index(content) when is_binary(content) do
    path = index_path()

    with :ok <- ensure_directory_exists(path),
         :ok <- File.write(path, content) do
      Logger.debug("Sitemap.LLMText.FileStorage: Wrote llms.txt (#{byte_size(content)} bytes)")
      :ok
    else
      {:error, reason} = error ->
        Logger.warning(
          "Sitemap.LLMText.FileStorage: Failed to write llms.txt: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Deletes a file at the given relative path. Returns :ok if file does not exist.
  """
  @spec delete(String.t()) :: :ok
  def delete(relative_path) when is_binary(relative_path) do
    path = file_path(relative_path)

    case File.rm(path) do
      :ok ->
        Logger.debug("Sitemap.LLMText.FileStorage: Deleted #{relative_path}")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Sitemap.LLMText.FileStorage: Failed to delete #{relative_path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Checks if a file at the given relative path exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(relative_path) when is_binary(relative_path) do
    relative_path |> file_path() |> File.exists?()
  end

  @doc """
  Deletes the entire storage directory and all its contents.
  """
  @spec delete_all() :: :ok
  def delete_all do
    dir = storage_dir()

    case File.rm_rf(dir) do
      {:ok, _} ->
        Logger.debug("Sitemap.LLMText.FileStorage: Deleted all files in #{dir}")
        :ok

      {:error, reason, _path} ->
        Logger.warning(
          "Sitemap.LLMText.FileStorage: Failed to delete storage dir: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  # Private helpers

  defp resolve_storage_dir do
    otp_app = PhoenixKit.Config.get(:otp_app, :phoenix_kit)

    priv_dir =
      case :code.priv_dir(otp_app) do
        {:error, :bad_name} ->
          case :code.priv_dir(:phoenix_kit) do
            {:error, :bad_name} -> "priv"
            dir -> to_string(dir)
          end

        dir ->
          to_string(dir)
      end

    Path.join([priv_dir, "static", "llms"])
  end

  defp ensure_directory_exists(file_path) do
    dir = Path.dirname(file_path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end
end
