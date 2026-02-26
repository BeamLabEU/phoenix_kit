defmodule PhoenixKit.Modules.Entities.Mirror.Exporter do
  @moduledoc """
  Exports entities and their data to JSON files.

  Each entity is exported as a single file containing:
  - The entity definition (schema)
  - All data records for that entity (when data mirroring is enabled)

  ## File Format

      {
        "export_version": "1.0",
        "exported_at": "2025-12-11T10:30:00Z",
        "definition": {
          "name": "brand",
          "display_name": "Brand",
          ...
        },
        "data": [
          {"title": "Acme Corp", "slug": "acme-corp", ...},
          {"title": "Globex", "slug": "globex", ...}
        ]
      }

  """

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Modules.Entities.EntityData
  alias PhoenixKit.Modules.Entities.Mirror.Storage
  alias PhoenixKit.Modules.Entities.Multilang

  @export_version "1.0"

  # ============================================================================
  # Export Operations
  # ============================================================================

  @doc """
  Exports a single entity with its definition and optionally data.

  ## Parameters
    - `entity` - Entity struct or entity name string

  ## Returns
    - `{:ok, file_path}` on success
    - `{:error, reason}` on failure
  """
  @spec export_entity(struct() | String.t()) ::
          {:ok, String.t(), :with_data | :definition_only} | {:error, term()}
  def export_entity(%{name: name} = entity) do
    # Check per-entity mirror_data setting
    include_data = Entities.mirror_data_enabled?(entity)
    data_records = if include_data, do: get_entity_data(entity), else: []

    content = build_export_content(entity, data_records)

    case Storage.write_entity(name, content) do
      {:ok, path} -> {:ok, path, if(include_data, do: :with_data, else: :definition_only)}
      {:error, reason} -> {:error, reason}
    end
  end

  def export_entity(entity_name) when is_binary(entity_name) do
    case Entities.get_entity_by_name(entity_name) do
      nil -> {:error, :entity_not_found}
      entity -> export_entity(entity)
    end
  end

  @doc """
  Exports a single entity data record.

  This re-exports the entire entity file with updated data.
  """
  @spec export_entity_data(struct()) :: {:ok, String.t()} | {:error, term()}
  def export_entity_data(%{entity_uuid: entity_uuid} = _entity_data) do
    case Entities.get_entity(entity_uuid) do
      nil -> {:error, :entity_not_found}
      entity -> export_entity(entity)
    end
  end

  @doc """
  Exports all entities (definitions only, no data).
  """
  @spec export_all_entities() :: {:ok, [result]} when result: {:ok, String.t()} | {:error, term()}
  def export_all_entities do
    results =
      Entities.list_entities()
      |> Enum.map(fn entity ->
        content = build_export_content(entity, [])
        Storage.write_entity(entity.name, content)
      end)

    {:ok, results}
  end

  @doc """
  Exports all data for all entities.

  Re-exports each entity file with its data included.
  """
  @spec export_all_data() :: {:ok, [result]} when result: {:ok, String.t()} | {:error, term()}
  def export_all_data do
    results =
      Entities.list_entities()
      |> Enum.map(fn entity ->
        data_records = get_entity_data(entity)
        content = build_export_content(entity, data_records)
        Storage.write_entity(entity.name, content)
      end)

    {:ok, results}
  end

  @doc """
  Exports all entities with their data (full export).

  Returns definition count and data record count.
  """
  @spec export_all() :: {:ok, %{definitions: non_neg_integer(), data: non_neg_integer()}}
  def export_all do
    include_data = Storage.data_enabled?()

    {def_count, data_count} =
      Entities.list_entities()
      |> Enum.reduce({0, 0}, fn entity, {defs, data} ->
        data_records = if include_data, do: get_entity_data(entity), else: []
        content = build_export_content(entity, data_records)

        case Storage.write_entity(entity.name, content) do
          {:ok, _} -> {defs + 1, data + length(data_records)}
          {:error, _} -> {defs, data}
        end
      end)

    {:ok, %{definitions: def_count, data: data_count}}
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  @doc """
  Serializes an entity struct to a map suitable for JSON export.
  """
  @spec serialize_entity(struct()) :: map()
  def serialize_entity(entity) do
    %{
      "name" => entity.name,
      "display_name" => entity.display_name,
      "display_name_plural" => entity.display_name_plural,
      "description" => entity.description,
      "icon" => entity.icon,
      "status" => to_string(entity.status),
      "fields_definition" => entity.fields_definition,
      "settings" => entity.settings,
      "date_created" => format_datetime(entity.date_created),
      "date_updated" => format_datetime(entity.date_updated)
    }
  end

  @doc """
  Serializes an entity data record to a map suitable for JSON export.
  """
  @spec serialize_entity_data(struct()) :: map()
  def serialize_entity_data(record) do
    %{
      "title" => record.title,
      "slug" => record.slug,
      "status" => to_string(record.status),
      "data" => record.data,
      "metadata" => record.metadata,
      "date_created" => format_datetime(record.date_created),
      "date_updated" => format_datetime(record.date_updated)
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_export_content(entity, data_records) do
    base = %{
      "export_version" => @export_version,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "definition" => serialize_entity(entity),
      "data" => Enum.map(data_records, &serialize_entity_data/1)
    }

    if Multilang.enabled?() do
      Map.put(base, "multilang", %{
        "enabled" => true,
        "primary_language" => Multilang.primary_language(),
        "languages" => Multilang.enabled_languages()
      })
    else
      base
    end
  end

  defp get_entity_data(entity) do
    EntityData.list_data_by_entity(entity.uuid)
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    NaiveDateTime.to_iso8601(ndt)
  end

  defp format_datetime(other), do: to_string(other)
end
