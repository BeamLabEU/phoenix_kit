defmodule PhoenixKit.Modules.Shop.Workers.CSVImportWorker do
  @moduledoc """
  Oban worker for background Shopify CSV import.

  Processes CSV files in batches with progress tracking via PubSub.

  ## Job Arguments

  - `import_log_id` - ID of the ImportLog record
  - `path` - Path to the uploaded CSV file
  - `config_id` - Optional ImportConfig ID for filtering rules

  ## Usage

  The Imports LiveView enqueues jobs after file upload:

      CSVImportWorker.new(%{
        import_log_id: log.id,
        path: "/tmp/uploads/products.csv",
        config_id: config.id  # optional
      })
      |> Oban.insert()

  ## Queue Configuration

  Add the shop_imports queue to your Oban config:

      config :my_app, Oban,
        queues: [default: 10, shop_imports: 2]
  """

  use Oban.Worker,
    queue: :shop_imports,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:import_log_id], states: :incomplete]

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Import.{CSVParser, CSVValidator, Filter, ProductTransformer}
  alias PhoenixKit.Modules.Shop.ImportConfig
  alias PhoenixKit.PubSub.Manager

  require Logger

  @progress_interval 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    import_log_id = Map.fetch!(args, "import_log_id")
    path = Map.fetch!(args, "path")
    config_id = Map.get(args, "config_id")

    Logger.info("CSVImportWorker: Starting import #{import_log_id} from #{path}")

    with {:ok, import_log} <- get_import_log(import_log_id),
         {:ok, config} <- load_config(config_id, import_log),
         :ok <- validate_file(path, config),
         {:ok, total_rows} <- count_products(path, config),
         {:ok, import_log} <- start_import(import_log, total_rows),
         {:ok, stats} <- process_file(import_log, path, config),
         {:ok, _import_log} <- complete_import(import_log, stats) do
      cleanup_file(path)
      broadcast_complete(import_log_id, stats)
      Logger.info("CSVImportWorker: Completed import #{import_log_id} - #{inspect(stats)}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("CSVImportWorker: Failed import #{import_log_id} - #{inspect(reason)}")
        handle_failure(import_log_id, reason)
        error
    end
  end

  # ============================================
  # PRIVATE HELPERS
  # ============================================

  defp get_import_log(id) do
    case Shop.get_import_log(id) do
      nil -> {:error, :import_log_not_found}
      log -> {:ok, log}
    end
  end

  defp load_config(nil, import_log) do
    # Try to load config from import_log options, or use default
    config_id = get_in(import_log.options, ["config_id"])

    if config_id do
      load_config_by_id(config_id)
    else
      # Try to get default config, fall back to nil (legacy defaults)
      case Shop.get_default_import_config() do
        nil -> {:ok, nil}
        config -> {:ok, config}
      end
    end
  end

  defp load_config(config_id, _import_log) when is_integer(config_id) do
    load_config_by_id(config_id)
  end

  defp load_config(config_id, _import_log) when is_binary(config_id) do
    load_config_by_id(String.to_integer(config_id))
  end

  defp load_config_by_id(config_id) do
    case Shop.get_import_config(config_id) do
      nil -> {:ok, nil}
      config -> {:ok, config}
    end
  end

  defp validate_file(path, config) do
    # Check file exists
    if File.exists?(path) do
      # Validate CSV structure
      required_columns = get_required_columns(config)

      case CSVValidator.validate_headers(path, required_columns) do
        {:ok, _headers} -> :ok
        {:error, reason} -> {:error, {:validation_failed, reason}}
      end
    else
      {:error, :file_not_found}
    end
  end

  defp get_required_columns(%ImportConfig{required_columns: cols}) when is_list(cols), do: cols
  defp get_required_columns(_), do: ImportConfig.default_required_columns()

  defp count_products(path, config) do
    grouped = CSVParser.parse_and_group(path)

    filtered_count =
      Enum.count(grouped, fn {_handle, rows} -> Filter.should_include?(rows, config) end)

    {:ok, filtered_count}
  rescue
    e ->
      Logger.error("CSVImportWorker: Failed to count products - #{inspect(e)}")
      {:error, {:parse_error, e}}
  end

  defp start_import(import_log, total_rows) do
    with {:ok, updated_log} <- Shop.start_import(import_log, total_rows) do
      broadcast_started(import_log.id, total_rows)
      {:ok, updated_log}
    end
  end

  defp process_file(import_log, path, config) do
    categories_map = build_categories_map()
    grouped = CSVParser.parse_and_group(path)

    stats = %{
      imported_count: 0,
      updated_count: 0,
      skipped_count: 0,
      error_count: 0,
      error_details: []
    }

    result =
      grouped
      |> Enum.filter(fn {_handle, rows} -> Filter.should_include?(rows, config) end)
      |> Enum.with_index(1)
      |> Enum.reduce(stats, fn {{handle, rows}, index}, acc ->
        result = process_product(handle, rows, categories_map, config)
        new_acc = update_stats(acc, result)

        # Broadcast progress at intervals
        if rem(index, @progress_interval) == 0 do
          broadcast_progress(import_log.id, index, import_log.total_rows, new_acc)
        end

        new_acc
      end)

    {:ok, result}
  rescue
    e ->
      Logger.error("CSVImportWorker: Failed to process file - #{inspect(e)}")
      {:error, {:process_error, e}}
  end

  defp process_product(handle, rows, categories_map, config) do
    attrs = ProductTransformer.transform(handle, rows, categories_map, config)

    case Shop.upsert_product(attrs) do
      {:ok, _product, :inserted} ->
        {:imported, handle}

      {:ok, _product, :updated} ->
        {:updated, handle}

      {:error, changeset} ->
        {:error, handle, changeset}
    end
  rescue
    e ->
      {:error, handle, e}
  end

  defp update_stats(stats, result) do
    case result do
      {:imported, _handle} ->
        %{stats | imported_count: stats.imported_count + 1}

      {:updated, _handle} ->
        %{stats | updated_count: stats.updated_count + 1}

      {:error, handle, error} ->
        error_detail = %{
          "handle" => handle,
          "error" => format_error(error),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        %{
          stats
          | error_count: stats.error_count + 1,
            error_details: [error_detail | stats.error_details]
        }
    end
  end

  defp format_error(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, ", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp format_error(error), do: inspect(error)

  defp complete_import(import_log, stats) do
    Shop.complete_import(import_log, stats)
  end

  defp handle_failure(import_log_id, reason) do
    case Shop.get_import_log(import_log_id) do
      nil ->
        :ok

      import_log ->
        Shop.fail_import(import_log, reason)
        broadcast_failed(import_log_id, reason)
    end
  end

  defp cleanup_file(path) do
    File.rm(path)
  rescue
    _ -> :ok
  end

  defp build_categories_map do
    Shop.list_categories()
    |> Enum.reduce(%{}, fn cat, acc ->
      Map.put(acc, cat.slug, cat.id)
    end)
  end

  # ============================================
  # PUBSUB BROADCASTS
  # ============================================

  defp broadcast_started(import_log_id, total) do
    broadcast(import_log_id, {:import_started, %{total: total}})
  end

  defp broadcast_progress(import_log_id, current, total, stats) do
    percent = if total > 0, do: trunc(current / total * 100), else: 0

    broadcast(
      import_log_id,
      {:import_progress,
       %{
         current: current,
         total: total,
         percent: percent,
         stats: stats
       }}
    )
  end

  defp broadcast_complete(import_log_id, stats) do
    broadcast(import_log_id, {:import_complete, stats})
  end

  defp broadcast_failed(import_log_id, reason) do
    broadcast(import_log_id, {:import_failed, %{reason: inspect(reason)}})
  end

  defp broadcast(import_log_id, message) do
    topic = "shop:import:#{import_log_id}"
    Manager.broadcast(topic, message)
  rescue
    _ -> :ok
  end
end
