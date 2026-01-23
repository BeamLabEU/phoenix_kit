defmodule PhoenixKit.Modules.Shop.Import.ShopifyCSV do
  @moduledoc """
  Main orchestrator for Shopify CSV import.

  Coordinates CSV parsing, validation, filtering, transformation, and product creation.

  ## Usage

      # Dry run - see what would be imported
      ShopifyCSV.import("/path/to/products.csv", dry_run: true)

      # Full import
      ShopifyCSV.import("/path/to/products.csv")

      # Import with custom config
      config = Shop.get_import_config!(config_id)
      ShopifyCSV.import("/path/to/products.csv", config: config)

      # Import to specific category
      category = Shop.get_category_by_slug("shelves")
      ShopifyCSV.import("/path/to/products.csv", category_id: category.id)
  """

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Import.{CSVParser, CSVValidator, Filter, ProductTransformer}
  alias PhoenixKit.Modules.Shop.ImportConfig

  require Logger

  @doc """
  Import products from Shopify CSV file.

  ## Options

  - `:dry_run` - If true, don't create products, just return what would be created
  - `:category_id` - Override category for all products
  - `:skip_existing` - If true, skip products with existing slugs (default: true)
  - `:update_existing` - If true, update existing products instead of skipping (default: false)
  - `:config` - ImportConfig struct for filtering/categorization (nil = use defaults)
  - `:validate` - If true, validate CSV before import (default: true)

  Note: When `update_existing: true`, `skip_existing` is ignored.

  ## Returns

  Summary map with:
  - `:imported` - count of newly created products
  - `:updated` - count of updated existing products
  - `:skipped` - count of skipped (existing or filtered out)
  - `:errors` - count of failed imports
  - `:dry_run` - count of products in dry run
  - `:error_details` - list of error tuples
  - `:validation_report` - CSV validation report (if validate: true)
  """
  def import(file_path, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    category_id = Keyword.get(opts, :category_id)
    skip_existing = Keyword.get(opts, :skip_existing, true)
    update_existing = Keyword.get(opts, :update_existing, false)
    config = Keyword.get(opts, :config)
    validate = Keyword.get(opts, :validate, true)
    language = Keyword.get(opts, :language)

    # Get required columns from config if provided
    required_columns = get_required_columns(config)

    # Validate CSV first if requested
    validation_result =
      if validate do
        case CSVValidator.validate_headers(file_path, required_columns) do
          {:ok, _headers} ->
            {:ok,
             CSVValidator.get_validation_report(file_path, required_columns: required_columns)}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:ok, nil}
      end

    case validation_result do
      {:error, reason} ->
        %{
          imported: 0,
          updated: 0,
          dry_run: 0,
          skipped: 0,
          errors: 1,
          error_details: [{:validation_failed, format_validation_error(reason)}],
          validation_report: nil
        }

      {:ok, validation_report} ->
        do_import(file_path, %{
          dry_run: dry_run,
          category_id: category_id,
          skip_existing: skip_existing,
          update_existing: update_existing,
          config: config,
          validation_report: validation_report,
          language: language
        })
    end
  end

  defp get_required_columns(%ImportConfig{required_columns: cols}) when is_list(cols), do: cols
  defp get_required_columns(_), do: ImportConfig.default_required_columns()

  defp format_validation_error({:missing_columns, cols}),
    do: "Missing columns: #{Enum.join(cols, ", ")}"

  defp format_validation_error(:file_not_found), do: "File not found"
  defp format_validation_error(:empty_file), do: "File is empty"
  defp format_validation_error({:parse_error, msg}), do: "CSV parse error: #{msg}"
  defp format_validation_error(other), do: inspect(other)

  defp do_import(file_path, opts) do
    %{
      dry_run: dry_run,
      category_id: category_id,
      skip_existing: skip_existing,
      update_existing: update_existing,
      config: config,
      validation_report: validation_report,
      language: language
    } = opts

    # Build categories map for auto-assignment
    categories_map = build_categories_map()

    # Parse and group CSV
    Logger.info("Parsing CSV: #{file_path}")
    grouped = CSVParser.parse_and_group(file_path)
    Logger.info("Found #{map_size(grouped)} unique handles")

    # Filter and import
    results =
      grouped
      |> Enum.map(fn {handle, rows} ->
        process_product(handle, rows, %{
          dry_run: dry_run,
          category_id: category_id,
          categories_map: categories_map,
          skip_existing: skip_existing,
          update_existing: update_existing,
          config: config,
          language: language
        })
      end)

    summary = summarize(results)
    Map.put(summary, :validation_report, validation_report)
  end

  @doc """
  Quick dry run - just parse and filter, show what would be imported.
  """
  def preview(file_path, opts \\ []) do
    config = Keyword.get(opts, :config)

    grouped = CSVParser.parse_and_group(file_path)

    filtered =
      grouped
      |> Enum.filter(fn {_handle, rows} -> Filter.should_include?(rows, config) end)

    Logger.info("Total products in CSV: #{map_size(grouped)}")
    Logger.info("Would import (matching filter): #{length(filtered)}")
    Logger.info("Would skip (filtered out): #{map_size(grouped) - length(filtered)}")

    # Show sample
    filtered
    |> Enum.take(5)
    |> Enum.each(fn {handle, rows} ->
      first = List.first(rows)
      category = Filter.categorize(first["Title"] || "", config)
      Logger.info("  #{handle} -> #{category}")
    end)

    %{
      total: map_size(grouped),
      would_import: length(filtered),
      would_skip: map_size(grouped) - length(filtered)
    }
  end

  @doc """
  Validates CSV file without importing.

  Returns validation report with headers, row count, and any warnings.
  """
  def validate(file_path, opts \\ []) do
    config = Keyword.get(opts, :config)
    required_columns = get_required_columns(config)

    CSVValidator.get_validation_report(file_path, required_columns: required_columns)
  end

  # Private helpers

  defp build_categories_map do
    Shop.list_categories()
    |> Enum.reduce(%{}, fn cat, acc ->
      Map.put(acc, cat.slug, cat.id)
    end)
  end

  defp process_product(handle, rows, opts) do
    config = opts.config

    if Filter.should_include?(rows, config) do
      do_process_product(handle, rows, opts)
    else
      {:skipped, handle, :filtered}
    end
  end

  defp do_process_product(handle, rows, opts) do
    %{
      dry_run: dry_run,
      category_id: override_category_id,
      categories_map: categories_map,
      config: config,
      language: language
    } = opts

    # Transform with config and language
    transform_opts = if language, do: [language: language], else: []
    attrs = ProductTransformer.transform(handle, rows, categories_map, config, transform_opts)

    # Override category if specified
    attrs =
      if override_category_id do
        Map.put(attrs, :category_id, override_category_id)
      else
        attrs
      end

    if dry_run do
      {:dry_run, handle, attrs}
    else
      save_product(handle, attrs, opts)
    end
  end

  defp save_product(handle, attrs, opts) do
    %{skip_existing: skip_existing, update_existing: update_existing} = opts

    cond do
      update_existing ->
        upsert_product(handle, attrs)

      skip_existing && product_exists?(handle) ->
        {:skipped, handle, :exists}

      true ->
        create_product(handle, attrs)
    end
  end

  defp product_exists?(slug) do
    case Shop.get_product_by_slug(slug) do
      nil -> false
      _ -> true
    end
  end

  defp create_product(handle, attrs) do
    case Shop.create_product(attrs) do
      {:ok, product} ->
        Logger.debug("Created: #{handle}")
        {:ok, product}

      {:error, changeset} ->
        Logger.warning("Failed: #{handle} - #{inspect(changeset.errors)}")
        {:error, handle, changeset}
    end
  end

  defp upsert_product(handle, attrs) do
    case Shop.upsert_product(attrs) do
      {:ok, product, :inserted} ->
        Logger.debug("Created: #{handle}")
        {:ok, product}

      {:ok, product, :updated} ->
        Logger.debug("Updated: #{handle}")
        {:updated, product}

      {:error, changeset} ->
        Logger.warning("Failed: #{handle} - #{inspect(changeset.errors)}")
        {:error, handle, changeset}
    end
  end

  defp summarize(results) do
    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    updated_count = Enum.count(results, &match?({:updated, _}, &1))
    dry_count = Enum.count(results, &match?({:dry_run, _, _}, &1))
    skipped_count = Enum.count(results, &match?({:skipped, _, _}, &1))
    errors = Enum.filter(results, &match?({:error, _, _}, &1))

    summary = %{
      imported: ok_count,
      updated: updated_count,
      dry_run: dry_count,
      skipped: skipped_count,
      errors: length(errors),
      error_details: errors
    }

    Logger.info(
      "Import complete: #{ok_count} imported, #{updated_count} updated, #{dry_count} dry run, #{skipped_count} skipped, #{length(errors)} errors"
    )

    summary
  end
end
