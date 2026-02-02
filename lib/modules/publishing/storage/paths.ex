defmodule PhoenixKit.Modules.Publishing.Storage.Paths do
  @moduledoc """
  Path management for publishing storage.

  Handles root paths, group paths, legacy/new path resolution,
  and path utilities for the filesystem storage system.
  """

  @doc """
  Returns the root path for reading content.
  Prefers new "publishing" path, falls back to legacy "blogging" path.
  For writing new content, use `write_root_path/0` instead.
  """
  @spec root_path() :: String.t()
  def root_path do
    base_priv = get_parent_app_priv()
    new_path = Path.join(base_priv, "publishing")
    legacy_path = Path.join(base_priv, "blogging")

    cond do
      File.dir?(new_path) -> new_path
      File.dir?(legacy_path) -> legacy_path
      true -> new_path
    end
  end

  @doc """
  Returns the path for a specific publishing group, checking both new and legacy locations.
  Returns the path where the group actually exists, or the new path if it doesn't exist yet.
  """
  @spec group_path(String.t()) :: String.t()
  def group_path(group_slug) do
    base_priv = get_parent_app_priv()
    new_group_path = Path.join([base_priv, "publishing", group_slug])
    legacy_group_path = Path.join([base_priv, "blogging", group_slug])

    cond do
      File.dir?(new_group_path) -> new_group_path
      File.dir?(legacy_group_path) -> legacy_group_path
      true -> new_group_path
    end
  end

  @doc """
  Returns the write root path for creating new groups.
  Always returns the new "publishing" path.
  """
  @spec write_root_path() :: String.t()
  def write_root_path do
    base_priv = get_parent_app_priv()
    path = Path.join(base_priv, "publishing")
    File.mkdir_p!(path)
    path
  end

  @doc """
  Returns the new publishing root path.
  """
  @spec new_root_path() :: String.t()
  def new_root_path do
    base_priv = get_parent_app_priv()
    Path.join(base_priv, "publishing")
  end

  @doc """
  Returns the legacy blogging root path.
  """
  @spec legacy_root_path() :: String.t()
  def legacy_root_path do
    base_priv = get_parent_app_priv()
    Path.join(base_priv, "blogging")
  end

  @doc """
  Checks if a specific publishing group is stored in the legacy "blogging" directory.
  """
  @spec legacy_group?(String.t()) :: boolean()
  def legacy_group?(group_slug) do
    legacy_path = Path.join(legacy_root_path(), group_slug)
    new_path = Path.join(new_root_path(), group_slug)

    File.dir?(legacy_path) and not File.dir?(new_path)
  end

  @doc """
  Migrates a publishing group from the legacy "blogging" directory to the new "publishing" directory.
  Returns {:ok, new_path} on success, {:error, reason} on failure.
  """
  @spec migrate_group(String.t()) :: {:ok, String.t()} | {:error, term()}
  def migrate_group(group_slug) do
    legacy_path = Path.join(legacy_root_path(), group_slug)
    new_path = Path.join(new_root_path(), group_slug)

    cond do
      File.dir?(new_path) ->
        {:error, :already_migrated}

      not File.dir?(legacy_path) ->
        {:error, :not_found}

      true ->
        File.mkdir_p!(new_root_path())

        case File.rename(legacy_path, new_path) do
          :ok ->
            cleanup_empty_legacy_root()
            {:ok, new_path}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Removes the legacy root directory if it's empty.
  """
  @spec cleanup_empty_legacy_root() :: :ok
  def cleanup_empty_legacy_root do
    legacy_root = legacy_root_path()

    if File.dir?(legacy_root) do
      case File.ls(legacy_root) do
        {:ok, []} -> File.rmdir(legacy_root)
        _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Returns whether there are any publishing groups still in the legacy location.
  """
  @spec has_legacy_groups?() :: boolean()
  def has_legacy_groups? do
    legacy_root = legacy_root_path()

    if File.dir?(legacy_root) do
      case File.ls(legacy_root) do
        {:ok, entries} -> Enum.any?(entries, &File.dir?(Path.join(legacy_root, &1)))
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Ensures the folder for a publishing group exists.
  For new groups, creates in the new "publishing" directory.
  For existing groups, uses their current location.
  """
  @spec ensure_group_root(String.t()) :: :ok | {:error, term()}
  def ensure_group_root(group_slug) do
    group_path(group_slug)
    |> File.mkdir_p()
  end

  @doc """
  Returns the absolute path for a relative blogging path.
  Handles per-blog legacy/new path resolution.
  """
  @spec absolute_path(String.t()) :: String.t()
  def absolute_path(relative_path) do
    trimmed = String.trim_leading(relative_path, "/")

    case String.split(trimmed, "/", parts: 2) do
      [group_slug, rest] ->
        Path.join(group_path(group_slug), rest)

      [group_slug] ->
        group_path(group_slug)
    end
  end

  @doc """
  Cleans up empty directories going up from a path.
  Stops at the publishing/blogging root.
  """
  @spec cleanup_empty_dirs(String.t()) :: :ok
  def cleanup_empty_dirs(path) do
    new_root = new_root_path()
    legacy_root = legacy_root_path()

    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(fn dir ->
      String.starts_with?(dir, new_root) or String.starts_with?(dir, legacy_root)
    end)
    |> Enum.each(fn dir ->
      case File.ls(dir) do
        {:ok, []} -> File.rmdir(dir)
        _ -> :ok
      end
    end)

    :ok
  end

  # Gets the parent application's priv directory
  defp get_parent_app_priv do
    parent_app =
      case PhoenixKit.Config.get_parent_app() do
        nil ->
          raise """
          PhoenixKit parent app not configured.
          Cannot determine storage path for publishing module.

          Please add the following to your config/config.exs:

              config :phoenix_kit, parent_app_name: :your_app_name
          """

        app ->
          app
      end

    Application.app_dir(parent_app, "priv")
  end
end
