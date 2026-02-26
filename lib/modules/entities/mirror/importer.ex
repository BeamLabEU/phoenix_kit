defmodule PhoenixKit.Modules.Entities.Mirror.Importer do
  @moduledoc """
  Handles import of entities and entity data from JSON files with conflict resolution.

  Each JSON file contains both the entity definition and all its data records.

  ## File Format

      {
        "export_version": "1.0",
        "exported_at": "2025-12-11T10:30:00Z",
        "definition": { ... entity schema ... },
        "data": [ ... array of data records ... ]
      }

  ## Conflict Strategies

  - `:skip` - Skip import if record already exists (default)
  - `:overwrite` - Replace existing record with imported data
  - `:merge` - Merge imported data with existing record (keeps existing values where new is nil)

  ## Conflict Detection

  - Entity definitions: matched by `name` field
  - Entity data records: matched by `entity_name` + `slug`
  """

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Modules.Entities.EntityData
  alias PhoenixKit.Modules.Entities.Mirror.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Slug

  @type conflict_strategy :: :skip | :overwrite | :merge
  @type import_result ::
          {:ok, :created, any()}
          | {:ok, :updated, any()}
          | {:ok, :skipped, any()}
          | {:error, term()}

  # ============================================================================
  # Import Operations
  # ============================================================================

  @doc """
  Imports an entity (definition + data) from a JSON file.

  ## Parameters
    - `entity_name` - The entity name (file name without .json)
    - `strategy` - Conflict resolution strategy (default: :skip)

  ## Returns
    - `{:ok, %{definition: result, data: [results]}}` on success
    - `{:error, reason}` on failure
  """
  @spec import_entity(String.t(), conflict_strategy()) :: {:ok, map()} | {:error, term()}
  def import_entity(entity_name, strategy \\ :skip) do
    case Storage.read_entity(entity_name) do
      {:ok, json_data} ->
        import_from_data(json_data, strategy)

      {:error, :not_found} ->
        {:error, {:file_not_found, entity_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Imports from parsed JSON data (definition + data).
  """
  @spec import_from_data(map(), conflict_strategy()) :: {:ok, map()} | {:error, term()}
  def import_from_data(%{"definition" => definition, "data" => data}, strategy)
      when is_map(definition) and is_list(data) do
    # Import definition first
    definition_result = import_definition(definition, strategy)

    # Get the entity for data import
    entity_name = definition["name"]

    data_results =
      case Entities.get_entity_by_name(entity_name) do
        nil ->
          # Entity doesn't exist, can't import data
          Enum.map(data, fn record ->
            {:error, {:entity_not_found, entity_name, record["slug"]}}
          end)

        entity ->
          Enum.map(data, fn record_data ->
            import_data_record(entity, record_data, strategy)
          end)
      end

    {:ok, %{definition: definition_result, data: data_results}}
  end

  def import_from_data(_, _), do: {:error, :invalid_format}

  # ============================================================================
  # Definition Import
  # ============================================================================

  defp import_definition(definition, strategy) do
    entity_name = definition["name"]

    case Entities.get_entity_by_name(entity_name) do
      nil ->
        create_entity_from_import(definition)

      existing_entity ->
        handle_entity_conflict(existing_entity, definition, strategy)
    end
  end

  defp create_entity_from_import(definition) do
    attrs = %{
      name: definition["name"],
      display_name: definition["display_name"],
      display_name_plural: definition["display_name_plural"],
      description: definition["description"],
      icon: definition["icon"],
      status: definition["status"] || "published",
      fields_definition: definition["fields_definition"] || [],
      settings: definition["settings"] || %{},
      created_by_uuid: get_default_user_uuid()
    }

    case Entities.create_entity(attrs) do
      {:ok, entity} -> {:ok, :created, entity}
      {:error, changeset} -> {:error, {:validation_failed, changeset}}
    end
  end

  defp handle_entity_conflict(existing_entity, _definition, :skip) do
    {:ok, :skipped, existing_entity}
  end

  defp handle_entity_conflict(existing_entity, definition, :overwrite) do
    attrs = %{
      display_name: definition["display_name"],
      display_name_plural: definition["display_name_plural"],
      description: definition["description"],
      icon: definition["icon"],
      status: definition["status"] || existing_entity.status,
      fields_definition: definition["fields_definition"] || [],
      settings: definition["settings"] || %{}
    }

    case Entities.update_entity(existing_entity, attrs) do
      {:ok, entity} -> {:ok, :updated, entity}
      {:error, changeset} -> {:error, {:validation_failed, changeset}}
    end
  end

  defp handle_entity_conflict(existing_entity, definition, :merge) do
    attrs = %{
      display_name: definition["display_name"] || existing_entity.display_name,
      display_name_plural:
        definition["display_name_plural"] || existing_entity.display_name_plural,
      description: definition["description"] || existing_entity.description,
      icon: definition["icon"] || existing_entity.icon,
      status: definition["status"] || existing_entity.status,
      fields_definition:
        merge_fields_definition(
          existing_entity.fields_definition,
          definition["fields_definition"]
        ),
      settings: deep_merge(existing_entity.settings || %{}, definition["settings"] || %{})
    }

    case Entities.update_entity(existing_entity, attrs) do
      {:ok, entity} -> {:ok, :updated, entity}
      {:error, changeset} -> {:error, {:validation_failed, changeset}}
    end
  end

  # ============================================================================
  # Data Import
  # ============================================================================

  defp import_data_record(entity, record_data, strategy) do
    slug = record_data["slug"]

    if is_nil(slug) or slug == "" do
      # Records without slugs can't be matched to existing records, so always create new
      create_data_from_import(entity, record_data)
    else
      case EntityData.get_by_slug(entity.uuid, slug) do
        nil ->
          create_data_from_import(entity, record_data)

        existing_record ->
          handle_data_conflict(existing_record, record_data, strategy)
      end
    end
  end

  defp create_data_from_import(entity, record_data) do
    # Generate slug from title if not provided
    slug = generate_slug_if_missing(entity.uuid, record_data["slug"], record_data["title"])

    attrs = %{
      entity_uuid: entity.uuid,
      title: record_data["title"],
      slug: slug,
      status: record_data["status"] || "published",
      data: record_data["data"] || %{},
      metadata: record_data["metadata"] || %{},
      created_by_uuid: get_default_user_uuid()
    }

    case EntityData.create(attrs) do
      {:ok, record} -> {:ok, :created, record}
      {:error, changeset} -> {:error, {:validation_failed, changeset}}
    end
  end

  defp generate_slug_if_missing(_entity_id, slug, _title) when is_binary(slug) and slug != "",
    do: slug

  defp generate_slug_if_missing(entity_id, _slug, title) when is_binary(title) and title != "" do
    base_slug = Slug.slugify(title)

    if base_slug == "" do
      # Title couldn't be slugified, generate a random one
      "record-#{:rand.uniform(9999)}"
    else
      Slug.ensure_unique(base_slug, &slug_exists?(entity_id, &1))
    end
  end

  defp generate_slug_if_missing(_entity_id, _slug, _title) do
    # No slug and no title, generate a random slug
    "record-#{:rand.uniform(9999)}"
  end

  defp slug_exists?(entity_id, slug) do
    EntityData.get_by_slug(entity_id, slug) != nil
  end

  # Preview what slug would be generated (without uniqueness check)
  defp preview_generated_slug(title) when is_binary(title) and title != "" do
    base_slug = Slug.slugify(title)
    if base_slug == "", do: "(auto-generated)", else: base_slug
  end

  defp preview_generated_slug(_), do: "(auto-generated)"

  # Find the next available slug for preview, considering DB and batch
  defp find_next_available_slug_preview(base_slug, _entity_id, _batch_counts)
       when base_slug in ["(auto-generated)", ""] do
    # Can't predict for auto-generated slugs
    "(auto-generated)"
  end

  defp find_next_available_slug_preview(base_slug, entity_id, batch_counts) do
    batch_count = Map.get(batch_counts, base_slug, 0)

    # Start checking from base_slug, then -2, -3, etc.
    # But account for how many we've already "claimed" in this batch
    find_available_slug_candidate(base_slug, entity_id, batch_count, 1)
  end

  defp find_available_slug_candidate(base_slug, entity_id, batch_offset, counter) do
    candidate = if counter == 1, do: base_slug, else: "#{base_slug}-#{counter}"

    # Check if this candidate exists in DB
    db_exists = entity_id && slug_exists?(entity_id, candidate)

    cond do
      db_exists ->
        # Slug exists in DB, try next number
        find_available_slug_candidate(base_slug, entity_id, batch_offset, counter + 1)

      batch_offset > 0 ->
        # This slot is taken by a previous record in this batch
        find_available_slug_candidate(base_slug, entity_id, batch_offset - 1, counter + 1)

      true ->
        # Found an available slot
        candidate
    end
  end

  defp handle_data_conflict(existing_record, _record_data, :skip) do
    {:ok, :skipped, existing_record}
  end

  defp handle_data_conflict(existing_record, record_data, :overwrite) do
    attrs = %{
      title: record_data["title"],
      slug: record_data["slug"],
      status: record_data["status"] || existing_record.status,
      data: record_data["data"] || %{},
      metadata: record_data["metadata"] || %{}
    }

    case EntityData.update(existing_record, attrs) do
      {:ok, record} -> {:ok, :updated, record}
      {:error, changeset} -> {:error, {:validation_failed, changeset}}
    end
  end

  defp handle_data_conflict(existing_record, record_data, :merge) do
    attrs = %{
      title: record_data["title"] || existing_record.title,
      slug: record_data["slug"] || existing_record.slug,
      status: record_data["status"] || existing_record.status,
      data: deep_merge(existing_record.data || %{}, record_data["data"] || %{}),
      metadata: deep_merge(existing_record.metadata || %{}, record_data["metadata"] || %{})
    }

    case EntityData.update(existing_record, attrs) do
      {:ok, record} -> {:ok, :updated, record}
      {:error, changeset} -> {:error, {:validation_failed, changeset}}
    end
  end

  # ============================================================================
  # Bulk Import
  # ============================================================================

  @doc """
  Imports all entities from the mirror directory.

  ## Parameters
    - `strategy` - Conflict resolution strategy (default: :skip)

  ## Returns
    - `{:ok, %{definitions: [...], data: [...]}}`
  """
  @spec import_all(conflict_strategy()) :: {:ok, map()}
  def import_all(strategy \\ :skip) do
    all_results =
      Storage.list_entities()
      |> Enum.map(fn entity_name ->
        case import_entity(entity_name, strategy) do
          {:ok, result} -> result
          {:error, reason} -> %{definition: {:error, reason}, data: []}
        end
      end)

    definition_results = Enum.map(all_results, & &1.definition)
    data_results = Enum.flat_map(all_results, & &1.data)

    {:ok,
     %{
       definitions: definition_results,
       data: data_results
     }}
  end

  @doc """
  Imports selected entities and records based on user selections.

  ## Parameters
    - `selections` - Map of entity_name => %{definition: action, data: %{slug => action}}
      where action is :skip, :overwrite, or :merge

  ## Example

      selections = %{
        "brand" => %{
          definition: :overwrite,
          data: %{
            "acme-corp" => :overwrite,
            "globex" => :skip
          }
        }
      }

  ## Returns
    - `{:ok, %{definitions: [...], data: [...]}}`
  """
  @spec import_selected(map()) :: {:ok, map()}
  def import_selected(selections) when is_map(selections) do
    all_results =
      selections
      |> Enum.map(fn {entity_name, entity_selections} ->
        import_entity_selective(entity_name, entity_selections)
      end)

    definition_results = Enum.map(all_results, & &1.definition)
    data_results = Enum.flat_map(all_results, & &1.data)

    {:ok,
     %{
       definitions: definition_results,
       data: data_results
     }}
  end

  defp import_entity_selective(entity_name, %{definition: def_action, data: data_actions}) do
    case Storage.read_entity(entity_name) do
      {:ok, %{"definition" => definition, "data" => data}} ->
        definition_result = import_definition_selective(definition, def_action)
        data_results = import_data_selective(definition["name"], data, data_actions)
        %{definition: definition_result, data: data_results}

      {:error, reason} ->
        %{definition: {:error, reason}, data: []}
    end
  end

  defp import_definition_selective(_definition, :skip), do: {:ok, :skipped, nil}
  defp import_definition_selective(definition, action), do: import_definition(definition, action)

  defp import_data_selective(entity_name, data, data_actions) do
    case Entities.get_entity_by_name(entity_name) do
      nil ->
        Enum.map(data, fn record ->
          {:error, {:entity_not_found, entity_name, record["slug"]}}
        end)

      entity ->
        import_data_records_with_actions(entity, data, data_actions)
    end
  end

  defp import_data_records_with_actions(entity, data, data_actions) do
    data
    |> Enum.with_index()
    |> Enum.map(fn {record_data, index} ->
      import_single_data_record(entity, record_data, index, data_actions)
    end)
  end

  defp import_single_data_record(entity, record_data, index, data_actions) do
    slug = record_data["slug"]
    selection_key = if is_nil(slug) or slug == "", do: "new-#{index}", else: slug
    action = Map.get(data_actions, selection_key, :skip)

    if action == :skip do
      {:ok, :skipped, nil}
    else
      import_data_record(entity, record_data, action)
    end
  end

  # ============================================================================
  # Preview / Dry Run
  # ============================================================================

  @doc """
  Previews what would be imported without making any changes.

  Returns data grouped by entity for the import UI, with each entity containing
  its definition preview and all data record previews.

  ## Returns

      %{
        entities: [
          %{
            name: "brand",
            definition: %{name: "brand", action: :create | :identical | :conflict},
            data: [%{slug: "acme", action: :create | :identical | :conflict}, ...]
          },
          ...
        ],
        summary: %{
          definitions: %{total: N, new: N, identical: N, conflicts: N},
          data: %{total: N, new: N, identical: N, conflicts: N}
        }
      }
  """
  @spec preview_import() :: map()
  def preview_import do
    entity_names = Storage.list_entities()

    entities =
      entity_names
      |> Enum.map(fn entity_name ->
        case Storage.read_entity(entity_name) do
          {:ok, %{"definition" => definition, "data" => data}} ->
            preview = preview_entity_file(entity_name, definition, data)

            %{
              name: entity_name,
              definition: preview.definition,
              data: preview.data
            }

          _ ->
            %{
              name: entity_name,
              definition: %{name: entity_name, action: :error},
              data: []
            }
        end
      end)

    # Calculate summary stats
    definition_previews = Enum.map(entities, & &1.definition)
    data_previews = Enum.flat_map(entities, & &1.data)

    %{
      entities: entities,
      summary: %{
        definitions: %{
          total: length(definition_previews),
          new: Enum.count(definition_previews, &(&1.action == :create)),
          identical: Enum.count(definition_previews, &(&1.action == :identical)),
          conflicts: Enum.count(definition_previews, &(&1.action == :conflict)),
          errors: Enum.count(definition_previews, &(&1.action == :error))
        },
        data: %{
          total: length(data_previews),
          new: Enum.count(data_previews, &(&1.action == :create)),
          identical: Enum.count(data_previews, &(&1.action == :identical)),
          conflicts: Enum.count(data_previews, &(&1.action == :conflict)),
          errors: Enum.count(data_previews, &(&1.action == :error))
        }
      }
    }
  end

  defp preview_entity_file(entity_name, definition, data) do
    existing_entity = Entities.get_entity_by_name(definition["name"])
    definition_preview = preview_definition(entity_name, existing_entity, definition)
    entity_id_for_slugs = if existing_entity, do: existing_entity.uuid, else: nil
    data_previews = preview_data_records(entity_name, existing_entity, entity_id_for_slugs, data)

    %{definition: definition_preview, data: data_previews}
  end

  defp preview_definition(entity_name, nil, _definition) do
    %{name: entity_name, action: :create}
  end

  defp preview_definition(entity_name, existing, definition) do
    if entity_definitions_match?(existing, definition) do
      %{name: entity_name, action: :identical, existing_uuid: existing.uuid}
    else
      %{name: entity_name, action: :conflict, existing_uuid: existing.uuid}
    end
  end

  defp preview_data_records(entity_name, existing_entity, entity_id_for_slugs, data) do
    {data_previews, _slug_counts} =
      data
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {record, index}, {previews, slug_counts} ->
        preview =
          preview_single_record(
            entity_name,
            existing_entity,
            entity_id_for_slugs,
            record,
            index,
            slug_counts
          )

        new_counts =
          if preview[:_base_slug] do
            Map.update(slug_counts, preview[:_base_slug], 1, &(&1 + 1))
          else
            slug_counts
          end

        {previews ++ [Map.delete(preview, :_base_slug)], new_counts}
      end)

    data_previews
  end

  defp preview_single_record(
         entity_name,
         _existing_entity,
         entity_id_for_slugs,
         record,
         index,
         slug_counts
       ) do
    slug = record["slug"]
    title = record["title"]

    if is_nil(slug) or slug == "" do
      preview_new_record_without_slug(entity_name, entity_id_for_slugs, title, index, slug_counts)
    else
      preview_record_with_slug(entity_name, entity_id_for_slugs, record, slug, title, slug_counts)
    end
  end

  defp preview_new_record_without_slug(
         entity_name,
         entity_id_for_slugs,
         title,
         index,
         slug_counts
       ) do
    base_slug = preview_generated_slug(title)
    import_key = "new-#{index}"

    display_generated =
      find_next_available_slug_preview(base_slug, entity_id_for_slugs, slug_counts)

    %{
      entity_name: entity_name,
      slug: import_key,
      display_slug: "(no slug)",
      title: title,
      generated_slug: display_generated,
      action: :create,
      is_new_record: true,
      _base_slug: base_slug
    }
  end

  defp preview_record_with_slug(entity_name, nil, _record, slug, title, _slug_counts) do
    # Entity will be created, so all data records will be new
    %{entity_name: entity_name, slug: slug, title: title, action: :create}
  end

  defp preview_record_with_slug(entity_name, entity_id, record, slug, title, slug_counts) do
    case EntityData.get_by_slug(entity_id, slug) do
      nil ->
        %{entity_name: entity_name, slug: slug, title: title, action: :create}

      existing ->
        new_slug_if_imported = find_next_available_slug_preview(slug, entity_id, slug_counts)
        action = if data_records_match?(existing, record), do: :identical, else: :conflict

        %{
          entity_name: entity_name,
          slug: slug,
          title: title,
          action: action,
          existing_uuid: existing.uuid,
          generated_slug: new_slug_if_imported
        }
    end
  end

  @doc """
  Detects all conflicts that would occur during import.

  ## Returns
    - `%{entity_conflicts: [...], data_conflicts: [...]}`
  """
  @spec detect_conflicts() :: map()
  def detect_conflicts do
    preview = preview_import()

    entity_conflicts =
      preview.entities
      |> Enum.filter(&(&1.definition.action == :conflict))
      |> Enum.map(& &1.name)

    data_conflicts =
      preview.entities
      |> Enum.flat_map(fn entity ->
        entity.data
        |> Enum.filter(&(&1.action == :conflict))
        |> Enum.map(&{entity.name, &1.slug})
      end)

    %{
      entity_conflicts: entity_conflicts,
      data_conflicts: data_conflicts
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_default_user_uuid do
    case get_default_user() do
      nil -> nil
      user -> user.uuid
    end
  end

  defp get_default_user do
    case Auth.get_first_admin() do
      nil -> Auth.get_first_user()
      admin -> admin
    end
  end

  defp merge_fields_definition(existing, new) when is_list(existing) and is_list(new) do
    existing_map =
      existing
      |> Enum.map(fn field -> {field["key"], field} end)
      |> Map.new()

    new
    |> Enum.reduce(existing_map, fn new_field, acc ->
      key = new_field["key"]

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, new_field)

        existing_field ->
          merged = Map.merge(existing_field, new_field)
          Map.put(acc, key, merged)
      end
    end)
    |> Map.values()
  end

  defp merge_fields_definition(_, new) when is_list(new), do: new
  defp merge_fields_definition(existing, _) when is_list(existing), do: existing
  defp merge_fields_definition(_, _), do: []

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _k, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _k, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(_left, right), do: right

  # Check if existing entity definition matches imported definition
  defp entity_definitions_match?(existing, imported) do
    existing.display_name == imported["display_name"] and
      existing.display_name_plural == imported["display_name_plural"] and
      existing.description == imported["description"] and
      existing.icon == imported["icon"] and
      to_string(existing.status) == (imported["status"] || "published") and
      normalize_list(existing.fields_definition) == normalize_list(imported["fields_definition"]) and
      normalize_map(existing.settings) == normalize_map(imported["settings"])
  end

  # Check if existing data record matches imported record
  defp data_records_match?(existing, imported) do
    existing.title == imported["title"] and
      existing.slug == imported["slug"] and
      to_string(existing.status) == (imported["status"] || "published") and
      normalize_map(existing.data) == normalize_map(imported["data"]) and
      normalize_map(existing.metadata) == normalize_map(imported["metadata"])
  end

  # Normalize nil/null to empty map for comparison
  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  # Normalize nil/null to empty list for comparison
  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_), do: []
end
