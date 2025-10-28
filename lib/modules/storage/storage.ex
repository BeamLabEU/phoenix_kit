defmodule PhoenixKit.Modules.Storage do
  @moduledoc """
  Storage Module for PhoenixKit.

  This module provides a distributed file storage system with redundancy support.
  Files can be stored across multiple locations (local, S3, remote servers) with
  automatic failover if a storage location becomes unavailable.

  ## Features

  - **Multi-location storage**: Store files in 1-5 redundant locations
  - **Automatic failover**: If one location fails, automatically use another
  - **Local storage**: Default storage to `priv/uploads`
  - **S3 support**: Optional AWS S3 integration (future)
  - **Remote servers**: Support for distributed storage across multiple servers (future)

  ## Module Status

  This module is **always enabled** and cannot be disabled. It provides core
  functionality for file management across PhoenixKit.

  ## Configuration

  The module uses the following settings stored in the database:
  - `storage_default_path` - Default local storage path (default: "priv/uploads")

  ## Usage

      # Get storage configuration
      config = PhoenixKit.Modules.Storage.get_config()
      # => %{default_path: "priv/uploads"}

      # Get default storage path
      path = PhoenixKit.Modules.Storage.get_default_path()
      # => "priv/uploads"
  """

  alias PhoenixKit.Settings

  @default_path "priv/uploads"

  @doc """
  Checks if the Storage module is enabled.

  This module is always enabled and cannot be disabled.

  ## Examples

      iex> PhoenixKit.Modules.Storage.module_enabled?()
      true
  """
  def module_enabled?, do: true

  @doc """
  Gets the default storage path for local file uploads (relative path).

  Returns the configured relative path or the default "priv/uploads" if not set.

  ## Examples

      iex> PhoenixKit.Modules.Storage.get_default_path()
      "priv/uploads"
  """
  def get_default_path do
    Settings.get_setting("storage_default_path", @default_path)
  end

  @doc """
  Gets the absolute storage path for local file uploads.

  Expands the relative path from settings to an absolute path.

  ## Examples

      iex> PhoenixKit.Modules.Storage.get_absolute_path()
      "/Users/don/Projects/pk/phoenix_kit/priv/uploads"
  """
  def get_absolute_path do
    relative_path = get_default_path()
    Path.expand(relative_path, File.cwd!())
  end

  @doc """
  Validates and normalizes a storage path.

  Takes a path (absolute or relative), validates it exists and is writable,
  and returns the relative path for storage.

  ## Examples

      iex> PhoenixKit.Modules.Storage.validate_and_normalize_path("/full/path/to/storage")
      {:ok, "relative/path/to/storage"}

      iex> PhoenixKit.Modules.Storage.validate_and_normalize_path("/nonexistent")
      {:error, "Directory does not exist: /nonexistent"}
  """
  def validate_and_normalize_path(path) when is_binary(path) do
    # Expand to absolute path for validation
    absolute_path = Path.expand(path, File.cwd!())

    cond do
      not File.exists?(absolute_path) ->
        # Return special tuple to indicate directory can be created
        {:error, :does_not_exist, absolute_path}

      not File.dir?(absolute_path) ->
        {:error, "Path is not a directory: #{absolute_path}"}

      not writable?(absolute_path) ->
        {:error, "Directory is not writable: #{absolute_path}"}

      true ->
        # Convert to relative path for storage
        relative_path = Path.relative_to(absolute_path, File.cwd!())
        {:ok, relative_path}
    end
  end

  @doc """
  Creates a directory at the specified path.

  Creates all parent directories if they don't exist (mkdir -p behavior).

  ## Examples

      iex> PhoenixKit.Modules.Storage.create_directory("/path/to/new/dir")
      {:ok, "/path/to/new/dir"}

      iex> PhoenixKit.Modules.Storage.create_directory("/invalid/path")
      {:error, "Failed to create directory: eacces"}
  """
  def create_directory(path) when is_binary(path) do
    absolute_path = Path.expand(path, File.cwd!())

    case File.mkdir_p(absolute_path) do
      :ok -> {:ok, absolute_path}
      {:error, reason} -> {:error, "Failed to create directory: #{reason}"}
    end
  end

  @doc """
  Updates the default storage path (stores relative path).

  ## Examples

      iex> PhoenixKit.Modules.Storage.update_default_path("uploads")
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  def update_default_path(path) when is_binary(path) do
    Settings.update_setting("storage_default_path", path)
  end

  @doc """
  Gets the configuration for the Storage module.

  Returns a map with:
  - `module_enabled` - Always true (non-disablable module)
  - `default_path` - Default local storage path

  ## Examples

      iex> PhoenixKit.Modules.Storage.get_config()
      %{
        module_enabled: true,
        default_path: "priv/uploads"
      }
  """
  def get_config do
    %{
      module_enabled: true,
      default_path: get_default_path()
    }
  end

  # Private helper to check if directory is writable
  defp writable?(path) do
    test_file = Path.join(path, ".phoenix_kit_write_test")

    case File.write(test_file, "test") do
      :ok ->
        File.rm(test_file)
        true

      {:error, _} ->
        false
    end
  end
end
