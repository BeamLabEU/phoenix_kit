defmodule PhoenixKit.Storage.Providers.Local do
  @moduledoc """
  Local filesystem storage provider.

  Stores files on the local filesystem using the configured endpoint path.
  Suitable for development, testing, and single-server deployments.
  """

  @behaviour PhoenixKit.Storage.Provider

  @impl true
  def store_file(bucket, source_path, destination_path, _opts \\ []) do
    # Build the full destination path
    full_destination = Path.join(bucket.endpoint || "priv/media", destination_path)

    # Ensure directory exists
    destination_dir = Path.dirname(full_destination)

    case File.mkdir_p(destination_dir) do
      :ok -> :ok
      {:error, reason} -> return_error("Failed to create directory: #{inspect(reason)}")
    end

    # Copy the file
    case File.cp(source_path, full_destination) do
      :ok ->
        {:ok, full_destination}

      {:error, reason} ->
        return_error("Failed to copy file: #{inspect(reason)}")
    end
  rescue
    error -> return_error("Error storing file: #{inspect(error)}")
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

  defp return_error(message), do: {:error, message}
end
