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
  Gets the default storage path for local file uploads.

  Returns the configured path or the default "priv/uploads" if not set.

  ## Examples

      iex> PhoenixKit.Modules.Storage.get_default_path()
      "priv/uploads"
  """
  def get_default_path do
    Settings.get_setting("storage_default_path", @default_path)
  end

  @doc """
  Updates the default storage path.

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
end
