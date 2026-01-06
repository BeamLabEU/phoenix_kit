defmodule Mix.Tasks.PhoenixKit.Entities.Import do
  @shortdoc "Import entities and entity data from JSON files"

  @moduledoc """
  Mix task to import entity definitions and data from JSON files.

  Each JSON file contains both the entity definition and all its data records.

  Imports from the configured mirror path (default: priv/entities/).

  ## Usage

      # Import from default path (priv/entities/)
      mix phoenix_kit.entities.import

      # Import with specific conflict resolution
      mix phoenix_kit.entities.import --on-conflict skip
      mix phoenix_kit.entities.import --on-conflict overwrite
      mix phoenix_kit.entities.import --on-conflict merge

      # Dry-run to preview changes
      mix phoenix_kit.entities.import --dry-run

      # Import specific entity
      mix phoenix_kit.entities.import --entity brand

      # Import from custom path
      mix phoenix_kit.entities.import --input /path/to/import

  ## Options

      --on-conflict STRATEGY   How to handle conflicts: skip, overwrite, merge (default: skip)
      --dry-run               Preview what would be imported without making changes
      --entity NAME           Import specific entity only
      --input PATH            Custom input directory
      --quiet                 Suppress output messages
      -y                      Skip confirmation prompts

  ## Conflict Strategies

  - **skip** (default): Skip import if record already exists
  - **overwrite**: Replace existing record with imported data
  - **merge**: Merge imported data with existing record

  ## Conflict Detection

  - Entity definitions: matched by `name` field
  - Entity data records: matched by `entity_name` + `slug`

  ## Examples

      # Preview what would be imported
      mix phoenix_kit.entities.import --dry-run

      # Import and overwrite any conflicts
      mix phoenix_kit.entities.import --on-conflict overwrite

      # Import from a backup directory
      mix phoenix_kit.entities.import --input ./backup/entities

      # Import just the brand entity without confirmation
      mix phoenix_kit.entities.import --entity brand -y
  """

  use Mix.Task

  alias PhoenixKit.Modules.Entities.Mirror.{Importer, Storage}
  alias PhoenixKit.Settings

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    # Override path if specified
    if input_path = options[:input] do
      Settings.update_setting("entities_mirror_path", input_path)
    end

    # Parse conflict strategy
    strategy = parse_strategy(options[:on_conflict])

    cond do
      options[:dry_run] ->
        run_dry_run(options)

      options[:entity] ->
        import_single_entity(options[:entity], strategy, options)

      true ->
        import_all(strategy, options)
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          on_conflict: :string,
          dry_run: :boolean,
          entity: :string,
          input: :string,
          quiet: :boolean,
          yes: :boolean
        ],
        aliases: [
          c: :on_conflict,
          e: :entity,
          i: :input,
          q: :quiet,
          y: :yes
        ]
      )

    {Enum.into(options, %{}), remaining}
  end

  defp parse_strategy(nil), do: :skip
  defp parse_strategy("skip"), do: :skip
  defp parse_strategy("overwrite"), do: :overwrite
  defp parse_strategy("merge"), do: :merge

  defp parse_strategy(invalid) do
    Mix.shell().error("Invalid conflict strategy: #{invalid}")
    Mix.shell().error("Valid options: skip, overwrite, merge")
    exit({:shutdown, 1})
  end

  defp run_dry_run(options) do
    unless options[:quiet] do
      Mix.shell().info("Previewing import (dry-run)...")
      Mix.shell().info("Source path: #{Storage.root_path()}\n")
    end

    preview = Importer.preview_import()

    log_definition_summary(preview.summary.definitions, options)
    log_entity_details(preview.entities, options)
    log_data_summary(preview.summary.data, options)
    log_data_details(preview.entities, preview.summary.data.total, options)
    log_dry_run_footer(options)
  end

  defp log_definition_summary(summary, %{quiet: true}), do: summary

  defp log_definition_summary(summary, _options) do
    Mix.shell().info("--- Entity Definitions ---")
    Mix.shell().info("Total files: #{summary.total}")
    Mix.shell().info("New entities: #{summary.new}")
    Mix.shell().info("Identical: #{summary.identical}")
    Mix.shell().info("Changed: #{summary.conflicts}")
    summary
  end

  defp log_entity_details(_entities, %{quiet: true}), do: :ok
  defp log_entity_details([], _options), do: :ok

  defp log_entity_details(entities, _options) do
    Mix.shell().info("\nDetails:")
    Enum.each(entities, &log_entity_definition/1)
  end

  defp log_entity_definition(entity) do
    case entity.definition.action do
      :create ->
        Mix.shell().info("  [NEW] #{entity.name}")

      :identical ->
        Mix.shell().info("  [IDENTICAL] #{entity.name}")

      :conflict ->
        Mix.shell().info(
          "  [CHANGED] #{entity.name} (existing id: #{entity.definition.existing_id})"
        )

      :error ->
        Mix.shell().error("  [ERROR] #{entity.name}")
    end
  end

  defp log_data_summary(_summary, %{quiet: true}), do: :ok

  defp log_data_summary(summary, _options) do
    Mix.shell().info("\n--- Entity Data Records ---")
    Mix.shell().info("Total records: #{summary.total}")
    Mix.shell().info("New records: #{summary.new}")
    Mix.shell().info("Identical: #{summary.identical}")
    Mix.shell().info("Changed: #{summary.conflicts}")
  end

  defp log_data_details(_entities, _total, %{quiet: true}), do: :ok
  defp log_data_details(_entities, 0, _options), do: :ok

  defp log_data_details(entities, _total, _options) do
    Mix.shell().info("\nDetails:")
    Enum.each(entities, &log_entity_data_records/1)
  end

  defp log_entity_data_records(entity) do
    Enum.each(entity.data, fn record -> log_data_record(entity.name, record) end)
  end

  defp log_data_record(entity_name, record) do
    case record.action do
      :create ->
        Mix.shell().info("  [NEW] #{entity_name}/#{record.slug}")

      :identical ->
        Mix.shell().info("  [IDENTICAL] #{entity_name}/#{record.slug}")

      :conflict ->
        Mix.shell().info(
          "  [CHANGED] #{entity_name}/#{record.slug} (existing id: #{record.existing_id})"
        )

      :error ->
        Mix.shell().error("  [ERROR] #{entity_name}/#{record.slug}")
    end
  end

  defp log_dry_run_footer(%{quiet: true}), do: :ok

  defp log_dry_run_footer(_options) do
    Mix.shell().info("\n--- Summary ---")
    Mix.shell().info("To proceed with import, run without --dry-run")
    Mix.shell().info("Use --on-conflict to specify how to handle conflicts")
  end

  defp import_single_entity(entity_name, strategy, options) do
    unless Storage.entity_exists?(entity_name) do
      Mix.shell().error("File not found for entity '#{entity_name}'")
      exit({:shutdown, 1})
    end

    unless options[:yes] do
      if not confirm_import(entity_name, strategy) do
        Mix.shell().info("Import cancelled.")
        exit({:shutdown, 0})
      end
    end

    case Importer.import_entity(entity_name, strategy) do
      {:ok, %{definition: def_result, data: data_results}} ->
        log_definition_result(entity_name, def_result, options)

        Enum.each(data_results, fn result ->
          log_data_result(entity_name, result, options)
        end)

        log_summary([def_result | data_results], options)

      {:error, reason} ->
        Mix.shell().error("Import failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp import_all(strategy, options) do
    preview = Importer.preview_import()
    summary = preview.summary

    unless options[:quiet] do
      Mix.shell().info(
        "Found #{summary.definitions.total} entities with #{summary.data.total} total data records"
      )

      Mix.shell().info("Conflict strategy: #{strategy}")
    end

    unless options[:yes] do
      if not confirm_import("all entities", strategy) do
        Mix.shell().info("Import cancelled.")
        exit({:shutdown, 0})
      end
    end

    unless options[:quiet] do
      Mix.shell().info("\nImporting...")
    end

    {:ok, %{definitions: def_results, data: data_results}} = Importer.import_all(strategy)

    unless options[:quiet] do
      Mix.shell().info("\n--- Results ---")
    end

    Enum.each(def_results, fn result ->
      case result do
        {:ok, _action, entity} ->
          log_definition_result(entity.name, result, options)

        {:error, _} = err ->
          log_definition_result("unknown", err, options)
      end
    end)

    Enum.each(data_results, fn result ->
      case result do
        {:ok, _action, _record} ->
          log_data_result("", result, options)

        {:error, _} = err ->
          log_data_result("", err, options)
      end
    end)

    log_summary(def_results ++ data_results, options)
  end

  defp confirm_import(entity_name, strategy) do
    Mix.shell().yes?("Import #{entity_name} with strategy '#{strategy}'? [y/N]")
  end

  defp log_definition_result(_name, _result, %{quiet: true}), do: :ok

  defp log_definition_result(name, {:ok, :created, _}, _options) do
    Mix.shell().info("  Definition '#{name}' created")
  end

  defp log_definition_result(name, {:ok, :updated, _}, _options) do
    Mix.shell().info("  Definition '#{name}' updated")
  end

  defp log_definition_result(name, {:ok, :skipped, _}, _options) do
    Mix.shell().info("  Definition '#{name}' skipped (already exists)")
  end

  defp log_definition_result(name, {:error, reason}, _options) do
    Mix.shell().error("  Definition '#{name}' failed: #{inspect(reason)}")
  end

  defp log_data_result(_entity, _result, %{quiet: true}), do: :ok

  defp log_data_result(_entity, {:ok, :created, record}, _options) do
    Mix.shell().info("  Data '#{record.slug}' created")
  end

  defp log_data_result(_entity, {:ok, :updated, record}, _options) do
    Mix.shell().info("  Data '#{record.slug}' updated")
  end

  defp log_data_result(_entity, {:ok, :skipped, record}, _options) do
    Mix.shell().info("  Data '#{record.slug}' skipped (already exists)")
  end

  defp log_data_result(_entity, {:error, reason}, _options) do
    Mix.shell().error("  Data record failed: #{inspect(reason)}")
  end

  defp log_summary(_results, %{quiet: true}), do: :ok

  defp log_summary(results, _options) do
    created = Enum.count(results, &match?({:ok, :created, _}, &1))
    updated = Enum.count(results, &match?({:ok, :updated, _}, &1))
    skipped = Enum.count(results, &match?({:ok, :skipped, _}, &1))
    errors = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("\n--- Summary ---")
    Mix.shell().info("Created: #{created}")
    Mix.shell().info("Updated: #{updated}")
    Mix.shell().info("Skipped: #{skipped}")

    if errors > 0 do
      Mix.shell().error("Errors: #{errors}")
    end
  end
end
