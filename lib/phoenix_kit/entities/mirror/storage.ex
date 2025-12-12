defmodule PhoenixKit.Entities.Mirror.Storage do
  @moduledoc """
  Filesystem storage operations for entity mirror/export system.

  Stores exported JSON files in the parent app's priv/entities/ directory.
  Each entity is stored as a single file containing both the definition and all data records.

  ## Directory Structure

      priv/entities/
        brand.json       # Contains definition + all data records
        product.json     # Contains definition + all data records

  ## File Format

      {
        "export_version": "1.0",
        "exported_at": "2025-12-11T10:30:00Z",
        "definition": { ... entity schema ... },
        "data": [ ... array of data records ... ]
      }

  ## Configuration

  The export path can be configured via settings:
  - `entities_mirror_path` - Custom path (empty = use default priv/entities/)

  """

  alias PhoenixKit.Config
  alias PhoenixKit.Settings

  # ============================================================================
  # Settings Helpers
  # ============================================================================

  @doc """
  Checks if entity definitions mirroring is enabled.
  """
  @spec definitions_enabled?() :: boolean()
  def definitions_enabled? do
    Settings.get_setting("entities_mirror_definitions_enabled", "false") == "true"
  end

  @doc """
  Checks if entity data mirroring is enabled.
  """
  @spec data_enabled?() :: boolean()
  def data_enabled? do
    Settings.get_setting("entities_mirror_data_enabled", "false") == "true"
  end

  @doc """
  Enables entity definitions mirroring.
  """
  @spec enable_definitions() :: {:ok, any()} | {:error, any()}
  def enable_definitions do
    Settings.update_setting("entities_mirror_definitions_enabled", "true")
  end

  @doc """
  Disables entity definitions mirroring.
  """
  @spec disable_definitions() :: {:ok, any()} | {:error, any()}
  def disable_definitions do
    Settings.update_setting("entities_mirror_definitions_enabled", "false")
  end

  @doc """
  Enables entity data mirroring.
  """
  @spec enable_data() :: {:ok, any()} | {:error, any()}
  def enable_data do
    Settings.update_setting("entities_mirror_data_enabled", "true")
  end

  @doc """
  Disables entity data mirroring.
  """
  @spec disable_data() :: {:ok, any()} | {:error, any()}
  def disable_data do
    Settings.update_setting("entities_mirror_data_enabled", "false")
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

  @doc """
  Returns the root path for entity mirror storage.

  Uses custom path from settings if configured, otherwise defaults to
  the parent app's priv/entities/ directory.
  """
  @spec root_path() :: String.t()
  def root_path do
    case Settings.get_setting("entities_mirror_path", "") do
      path when is_binary(path) and byte_size(path) > 0 -> path
      _ -> default_path()
    end
  end

  @doc """
  Returns the default storage path in the parent app's priv directory.
  """
  @spec default_path() :: String.t()
  def default_path do
    case Config.get_parent_app() do
      nil -> Path.join([File.cwd!(), "priv", "entities"])
      app -> Application.app_dir(app, Path.join("priv", "entities"))
    end
  end

  @doc """
  Returns the file path for a specific entity.
  """
  @spec entity_path(String.t()) :: String.t()
  def entity_path(entity_name) when is_binary(entity_name) do
    Path.join(root_path(), "#{entity_name}.json")
  end

  # ============================================================================
  # Directory Management
  # ============================================================================

  @doc """
  Ensures the root directory exists.
  """
  @spec ensure_directory() :: :ok | {:error, term()}
  def ensure_directory do
    path = root_path()

    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  # ============================================================================
  # Write Operations
  # ============================================================================

  @doc """
  Writes an entity file containing definition and optionally data.

  ## Parameters
    - `entity_name` - The entity name (used as filename)
    - `content` - The full content map with definition and data

  ## Returns
    - `{:ok, file_path}` on success
    - `{:error, reason}` on failure
  """
  @spec write_entity(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_entity(entity_name, content) when is_binary(entity_name) and is_map(content) do
    with :ok <- ensure_directory() do
      file_path = entity_path(entity_name)
      write_json_file(file_path, content)
    end
  end

  defp write_json_file(file_path, content) when is_map(content) do
    case Jason.encode(content, pretty: true) do
      {:ok, json} ->
        case File.write(file_path, json) do
          :ok -> {:ok, file_path}
          {:error, reason} -> {:error, {:write_failed, file_path, reason}}
        end

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  # ============================================================================
  # Read Operations
  # ============================================================================

  @doc """
  Reads an entity file containing definition and data.

  ## Parameters
    - `entity_name` - The entity name

  ## Returns
    - `{:ok, map}` with decoded JSON on success
    - `{:error, reason}` on failure
  """
  @spec read_entity(String.t()) :: {:ok, map()} | {:error, term()}
  def read_entity(entity_name) when is_binary(entity_name) do
    file_path = entity_path(entity_name)
    read_json_file(file_path)
  end

  defp read_json_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:decode_failed, file_path, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_failed, file_path, reason}}
    end
  end

  # ============================================================================
  # Delete Operations
  # ============================================================================

  @doc """
  Deletes an entity file.
  """
  @spec delete_entity(String.t()) :: :ok | {:error, term()}
  def delete_entity(entity_name) when is_binary(entity_name) do
    file_path = entity_path(entity_name)

    case File.rm(file_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:delete_failed, file_path, reason}}
    end
  end

  # ============================================================================
  # List Operations
  # ============================================================================

  @doc """
  Lists all exported entity names.

  Returns a list of entity names (without .json extension).
  """
  @spec list_entities() :: [String.t()]
  def list_entities do
    path = root_path()

    if File.exists?(path) do
      path
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&String.replace_trailing(&1, ".json", ""))
      |> Enum.sort()
    else
      []
    end
  end

  # ============================================================================
  # Stats
  # ============================================================================

  @doc """
  Returns statistics about exported files.

  ## Returns
    Map with:
    - `definitions_count` - Number of exported entity files
    - `data_count` - Total number of data records across all entities
    - `entities_with_data` - List of entity names that have data records
    - `last_export` - Timestamp of most recent export (nil if no files)
  """
  @spec get_stats() :: map()
  def get_stats do
    entities = list_entities()

    {data_count, entities_with_data} =
      entities
      |> Enum.reduce({0, []}, fn entity_name, {count, with_data} ->
        case read_entity(entity_name) do
          {:ok, %{"data" => data}} when is_list(data) and length(data) > 0 ->
            {count + length(data), [entity_name | with_data]}

          {:ok, _} ->
            {count, with_data}

          {:error, _} ->
            {count, with_data}
        end
      end)

    last_export = get_last_export_time(entities)

    %{
      definitions_count: length(entities),
      data_count: data_count,
      entities_with_data: Enum.reverse(entities_with_data),
      last_export: last_export
    }
  end

  defp get_last_export_time([]), do: nil

  defp get_last_export_time(entities) do
    entities
    |> Enum.map(fn name -> entity_path(name) end)
    |> Enum.map(&get_file_mtime/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
    |> format_last_export()
  end

  defp get_file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp format_last_export(nil), do: nil

  defp format_last_export({{year, month, day}, {hour, minute, _second}}) do
    "#{year}-#{pad(month)}-#{pad(day)} #{pad(hour)}:#{pad(minute)}"
  end

  defp pad(num) when num < 10, do: "0#{num}"
  defp pad(num), do: "#{num}"

  @doc """
  Checks if a file exists for the given entity.
  """
  @spec entity_exists?(String.t()) :: boolean()
  def entity_exists?(entity_name) do
    file_path = entity_path(entity_name)
    File.exists?(file_path)
  end

  # Legacy compatibility aliases
  @doc false
  def list_definitions, do: list_entities()
  @doc false
  def definition_exists?(name), do: entity_exists?(name)
end
