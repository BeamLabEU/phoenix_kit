defmodule Mix.Tasks.PhoenixKit.Entities.Export do
  @shortdoc "Export entities and entity data to JSON files"

  @moduledoc """
  Mix task to export entity definitions and data to JSON files.

  Each entity is exported as a single file containing both the definition
  and all its data records.

  Exports are stored in the configured mirror path (default: priv/entities/).

  ## Usage

      # Export all entities (definitions + data if data mirroring enabled)
      mix phoenix_kit.entities.export

      # Export specific entity
      mix phoenix_kit.entities.export --entity brand

      # Export with data included (regardless of setting)
      mix phoenix_kit.entities.export --with-data

      # Export without data (regardless of setting)
      mix phoenix_kit.entities.export --no-data

      # Custom output path
      mix phoenix_kit.entities.export --output /path/to/export

  ## Options

      --entity NAME        Export specific entity only
      --with-data          Include data records in export
      --no-data            Exclude data records from export
      --output PATH        Custom output directory (overrides settings)
      --quiet              Suppress output messages

  ## Output Structure

      priv/entities/
        brand.json       # Contains definition + all data records
        product.json     # Contains definition + all data records

  ## JSON Format

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

  ## Examples

      # Full export for version control backup
      mix phoenix_kit.entities.export --with-data

      # Export just the brand entity
      mix phoenix_kit.entities.export --entity brand

      # Export to a specific directory
      mix phoenix_kit.entities.export --output ./backup/entities
  """

  use Mix.Task

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData
  alias PhoenixKit.Entities.Mirror.Storage
  alias PhoenixKit.Settings

  @export_version "1.0"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    # Override path if specified
    if output_path = options[:output] do
      Settings.update_setting("entities_mirror_path", output_path)
    end

    # Ensure directory exists
    Storage.ensure_directory()

    cond do
      options[:entity] ->
        export_single_entity(options[:entity], options)

      true ->
        export_all(options)
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          entity: :string,
          with_data: :boolean,
          no_data: :boolean,
          output: :string,
          quiet: :boolean
        ],
        aliases: [
          e: :entity,
          o: :output,
          q: :quiet
        ]
      )

    {Enum.into(options, %{}), remaining}
  end

  defp include_data?(options) do
    cond do
      options[:with_data] -> true
      options[:no_data] -> false
      true -> Storage.data_enabled?()
    end
  end

  defp export_single_entity(entity_name, options) do
    case Entities.get_entity_by_name(entity_name) do
      nil ->
        Mix.shell().error("Entity '#{entity_name}' not found.")
        exit({:shutdown, 1})

      entity ->
        include_data = include_data?(options)
        data_records = if include_data, do: EntityData.list_data_by_entity(entity.id), else: []

        content = build_export_content(entity, data_records)
        result = Storage.write_entity(entity.name, content)

        log_result(entity_name, length(data_records), result, options)
        log_summary([result], options)
    end
  end

  defp export_all(options) do
    unless options[:quiet] do
      Mix.shell().info("Exporting all entities...")
    end

    include_data = include_data?(options)

    results =
      Entities.list_entities()
      |> Enum.map(fn entity ->
        data_records = if include_data, do: EntityData.list_data_by_entity(entity.id), else: []
        content = build_export_content(entity, data_records)
        result = Storage.write_entity(entity.name, content)

        log_result(entity.name, length(data_records), result, options)
        result
      end)

    log_summary(results, options)
  end

  defp build_export_content(entity, data_records) do
    %{
      "export_version" => @export_version,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "definition" => serialize_entity(entity),
      "data" => Enum.map(data_records, &serialize_entity_data/1)
    }
  end

  defp serialize_entity(entity) do
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

  defp serialize_entity_data(record) do
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

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_datetime(other), do: to_string(other)

  defp log_result(_name, _data_count, _result, %{quiet: true}), do: :ok

  defp log_result(name, data_count, {:ok, path}, _options) do
    data_info = if data_count > 0, do: " (#{data_count} records)", else: ""
    Mix.shell().info("  #{name}#{data_info} -> #{path}")
  end

  defp log_result(name, _data_count, {:error, reason}, _options) do
    Mix.shell().error("  #{name} failed: #{inspect(reason)}")
  end

  defp log_summary(_results, %{quiet: true}), do: :ok

  defp log_summary(results, _options) do
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("\n--- Summary ---")
    Mix.shell().info("Exported: #{success_count} entities")

    if error_count > 0 do
      Mix.shell().error("Errors: #{error_count}")
    end

    Mix.shell().info("Output path: #{Storage.root_path()}")
  end
end
