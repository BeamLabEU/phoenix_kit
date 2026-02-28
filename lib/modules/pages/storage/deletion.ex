defmodule PhoenixKit.Modules.Pages.Storage.Deletion do
  @moduledoc """
  Deletion and trash operations for pages storage.

  Handles moving posts to trash, deleting language files,
  and deleting versions.
  """

  alias PhoenixKit.Modules.Pages.Storage.Paths
  alias PhoenixKit.Modules.Pages.Storage.Versions
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @doc """
  Moves a post to the trash folder.

  For slug-mode groups, moves the entire post directory (all versions and languages).
  For timestamp-mode groups, moves the time folder.

  The post directory is moved to:
    priv/pages/trash/<group_slug>/<post_identifier>-<timestamp>/
    (or priv/blogging/trash/... for legacy groups)

  Returns {:ok, trash_path} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_post(group_slug, post_identifier) do
    post_dir = resolve_post_directory(group_slug, post_identifier)

    if File.dir?(post_dir) do
      trash_dir = Path.join([Paths.root_path(), "trash", group_slug])
      File.mkdir_p!(trash_dir)

      timestamp =
        UtilsDate.utc_now()
        |> Calendar.strftime("%Y-%m-%d-%H-%M-%S")

      sanitized_id = sanitize_for_trash(post_identifier)
      new_name = "#{sanitized_id}-#{timestamp}"
      destination = Path.join(trash_dir, new_name)

      case File.rename(post_dir, destination) do
        :ok ->
          Paths.cleanup_empty_dirs(Path.dirname(post_dir))
          {:ok, "trash/#{group_slug}/#{new_name}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Moves a language file to trash (legacy operation, now just deletes).
  """
  @spec trash_language(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_language(group_slug, relative_path) do
    full_path = Paths.absolute_path(relative_path)

    if File.exists?(full_path) do
      trash_dir = Path.join([Paths.root_path(), "trash", group_slug])
      File.mkdir_p!(trash_dir)

      timestamp =
        UtilsDate.utc_now()
        |> Calendar.strftime("%Y-%m-%d-%H-%M-%S")

      new_name = "#{Path.basename(relative_path)}-#{timestamp}"
      destination = Path.join(trash_dir, new_name)

      case File.rename(full_path, destination) do
        :ok -> {:ok, "trash/#{new_name}"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Deletes a specific language file from a post.

  For versioned posts, specify the version. For legacy posts, version is ignored.
  Refuses to delete the last remaining language file.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_language(String.t(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, term()}
  def delete_language(group_slug, post_identifier, language_code, version \\ nil) do
    post_dir = resolve_post_directory(group_slug, post_identifier)

    if File.dir?(post_dir) do
      structure = Versions.detect_post_structure(post_dir)
      do_delete_language(post_dir, structure, language_code, version, group_slug, post_identifier)
    else
      {:error, :post_not_found}
    end
  end

  defp do_delete_language(
         post_dir,
         :versioned,
         language_code,
         version,
         group_slug,
         post_identifier
       ) do
    target_version = version || get_latest_version_number(group_slug, post_identifier)

    case target_version do
      nil ->
        {:error, :version_not_found}

      v ->
        version_dir = Path.join(post_dir, "v#{v}")
        delete_language_from_directory(version_dir, language_code)
    end
  end

  defp do_delete_language(post_dir, :legacy, language_code, _version, _group_slug, _post_id) do
    delete_language_from_directory(post_dir, language_code)
  end

  defp do_delete_language(_post_dir, :empty, _language_code, _version, _group_slug, _post_id) do
    {:error, :post_not_found}
  end

  defp delete_language_from_directory(dir, language_code) do
    file_path = Path.join(dir, "#{language_code}.phk")

    cond do
      not File.exists?(file_path) ->
        {:error, :language_not_found}

      last_language_file?(dir) ->
        {:error, :cannot_delete_last_language}

      true ->
        File.rm(file_path)
    end
  end

  defp last_language_file?(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        phk_count = Enum.count(files, &String.ends_with?(&1, ".phk"))
        phk_count <= 1

      {:error, _} ->
        true
    end
  end

  defp get_latest_version_number(group_slug, post_identifier) do
    case Versions.get_latest_version(group_slug, post_identifier) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  @doc """
  Deletes an entire version of a post.

  Moves the version folder to trash instead of permanent deletion.
  Refuses to delete the last remaining version or the published version.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_version(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def delete_version(group_slug, post_identifier, version) do
    post_dir = resolve_post_directory(group_slug, post_identifier)

    if File.dir?(post_dir) do
      structure = Versions.detect_post_structure(post_dir)

      case structure do
        :versioned ->
          do_delete_version(post_dir, group_slug, post_identifier, version)

        :legacy ->
          {:error, :not_versioned}

        :empty ->
          {:error, :post_not_found}
      end
    else
      {:error, :post_not_found}
    end
  end

  defp do_delete_version(post_dir, group_slug, post_identifier, version) do
    version_dir = Path.join(post_dir, "v#{version}")

    cond do
      not File.dir?(version_dir) ->
        {:error, :version_not_found}

      Versions.version_is_published?(group_slug, post_identifier, version) ->
        {:error, :cannot_delete_published_version}

      Versions.only_version?(post_dir) ->
        {:error, :cannot_delete_last_version}

      true ->
        trash_dir = Path.join([Paths.root_path(), "trash", group_slug, post_identifier])
        File.mkdir_p!(trash_dir)

        timestamp =
          UtilsDate.utc_now()
          |> Calendar.strftime("%Y-%m-%d-%H-%M-%S")

        destination = Path.join(trash_dir, "v#{version}-#{timestamp}")

        case File.rename(version_dir, destination) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Resolve the post directory path based on the identifier format
  defp resolve_post_directory(group_slug, post_identifier) do
    if String.contains?(post_identifier, "/") do
      parts = String.split(post_identifier, "/", trim: true)

      case parts do
        [date, time | _] when byte_size(date) == 10 and byte_size(time) >= 4 ->
          Path.join([Paths.group_path(group_slug), date, time])

        [slug | _] ->
          Path.join([Paths.group_path(group_slug), slug])
      end
    else
      Path.join([Paths.group_path(group_slug), post_identifier])
    end
  end

  # Sanitize identifier for use in trash folder name
  defp sanitize_for_trash(identifier) do
    identifier
    |> String.replace("/", "_")
    |> String.replace(":", "-")
  end
end
