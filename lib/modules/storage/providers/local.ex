defmodule PhoenixKit.Modules.Storage.Providers.Local do
  @moduledoc """
  Local filesystem storage provider.

  Stores files on the local filesystem using the configured endpoint path.
  Suitable for development, testing, and single-server deployments.
  """

  @behaviour PhoenixKit.Modules.Storage.Provider

  require Logger

  @impl true
  def store_file(bucket, source_path, destination_path, _opts \\ []) do
    # Build the full destination path
    full_destination = Path.join(bucket.endpoint || "priv/media", destination_path)

    Logger.info(
      "[LocalStorage] store_file: source=#{source_path}, destination=#{full_destination}"
    )

    with :ok <- validate_source_exists(source_path),
         {:ok, source_size} <- get_source_size(source_path),
         :ok <- ensure_destination_dir(full_destination),
         :ok <- copy_file(source_path, full_destination),
         :ok <- verify_copy(full_destination, source_size) do
      {:ok, full_destination}
    end
  rescue
    error ->
      Logger.error("[LocalStorage] Exception storing file: #{inspect(error)}")
      {:error, "Error storing file: #{inspect(error)}"}
  end

  defp validate_source_exists(source_path) do
    if File.exists?(source_path) do
      :ok
    else
      Logger.error("[LocalStorage] Source file does not exist: #{source_path}")
      {:error, "Source file does not exist: #{source_path}"}
    end
  end

  defp get_source_size(source_path) do
    case File.stat(source_path) do
      {:ok, %{size: size}} ->
        Logger.info("[LocalStorage] Source file size: #{size} bytes")
        {:ok, size}

      {:error, reason} ->
        Logger.error("[LocalStorage] Failed to get source file size: #{inspect(reason)}")
        {:error, "Failed to get source file size: #{inspect(reason)}"}
    end
  end

  defp ensure_destination_dir(full_destination) do
    destination_dir = Path.dirname(full_destination)

    case File.mkdir_p(destination_dir) do
      :ok ->
        Logger.debug("[LocalStorage] Created/verified directory: #{destination_dir}")
        :ok

      {:error, reason} ->
        Logger.error(
          "[LocalStorage] Failed to create directory #{destination_dir}: #{inspect(reason)}"
        )

        {:error, "Failed to create directory: #{inspect(reason)}"}
    end
  end

  defp copy_file(source_path, full_destination) do
    Logger.info("[LocalStorage] Copying #{source_path} -> #{full_destination}")

    case File.cp(source_path, full_destination) do
      :ok ->
        Logger.info("[LocalStorage] File.cp completed successfully")
        :ok

      {:error, reason} ->
        Logger.error("[LocalStorage] Failed to copy file: #{inspect(reason)}")
        {:error, "Failed to copy file: #{inspect(reason)}"}
    end
  end

  defp verify_copy(full_destination, expected_size) do
    if File.exists?(full_destination) do
      case File.stat(full_destination) do
        {:ok, %{size: dest_size}} ->
          if dest_size == expected_size do
            Logger.info("[LocalStorage] File verified: #{full_destination} (#{dest_size} bytes)")

            :ok
          else
            Logger.error(
              "[LocalStorage] Size mismatch! Expected #{expected_size}, got #{dest_size}"
            )

            {:error, "File size mismatch after copy"}
          end

        {:error, reason} ->
          Logger.error("[LocalStorage] Failed to stat destination file: #{inspect(reason)}")
          {:error, "Failed to verify destination file: #{inspect(reason)}"}
      end
    else
      Logger.error("[LocalStorage] File.cp returned :ok but file not found: #{full_destination}")

      {:error, "File copy reported success but file not found"}
    end
  end

  @impl true
  def retrieve_file(bucket, file_path, destination_path) do
    full_source = Path.join(bucket.endpoint || "priv/media", file_path)

    # Ensure destination directory exists
    destination_dir = Path.dirname(destination_path)

    case File.mkdir_p(destination_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create destination directory: #{inspect(reason)}"}
    end

    # Copy the file
    case File.cp(full_source, destination_path) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to copy file: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error retrieving file: #{inspect(error)}"}
  end

  @impl true
  def delete_file(bucket, file_path) do
    full_path = Path.join(bucket.endpoint || "priv/media", file_path)

    case File.rm(full_path) do
      :ok -> :ok
      # File doesn't exist, that's fine
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "Failed to delete file: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error deleting file: #{inspect(error)}"}
  end

  @impl true
  def file_exists?(bucket, file_path) do
    full_path = Path.join(bucket.endpoint || "priv/media", file_path)
    File.exists?(full_path)
  end

  @impl true
  def public_url(_bucket, _file_path) do
    # Local storage doesn't have public URLs by default
    # This would need to be configured with a web server path
    nil
  end

  @impl true
  def test_connection(bucket) do
    base_path = bucket.endpoint || "priv/media"

    # Test if we can create the directory
    case File.mkdir_p(base_path) do
      :ok ->
        # Test if we can write a temporary file
        test_file = Path.join(base_path, ".phoenix_kit_test")

        case File.write(test_file, "test") do
          :ok ->
            File.rm(test_file)
            :ok

          {:error, reason} ->
            {:error, "Cannot write to directory: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Cannot create directory: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error testing connection: #{inspect(error)}"}
  end
end
