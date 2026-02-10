defmodule PhoenixKit.Modules.Shop.Workers.CSVImportWorker do
  @moduledoc """
  Oban worker for background CSV import.

  Processes CSV files with automatic format detection via the ImportFormat behaviour.
  Supports Shopify, Prom.ua, and other formats transparently.

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
  alias PhoenixKit.Modules.Shop.Import.{CSVValidator, FormatDetector}
  alias PhoenixKit.Modules.Shop.ImportConfig
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Workers.ImageMigrationWorker
  alias PhoenixKit.PubSub.Manager

  require Logger

  @progress_interval 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    import_log_id = Map.fetch!(args, "import_log_id")
    path = Map.fetch!(args, "path")
    config_id = Map.get(args, "config_id")
    language = Map.get(args, "language") || default_import_language()
    option_mappings = Map.get(args, "option_mappings", [])
    download_images = Map.get(args, "download_images", false)
    skip_empty_categories = Map.get(args, "skip_empty_categories", false)

    Logger.info("CSVImportWorker: Starting import #{import_log_id} from #{path}")

    with {:ok, import_log} <- get_import_log(import_log_id),
         {:ok, config} <- load_config(config_id, import_log),
         {:ok, format_mod} <- detect_format(path),
         :ok <- validate_file(path, format_mod, config),
         {:ok, total_rows} <- count_products(path, format_mod, config),
         {:ok, import_log} <- start_import(import_log, total_rows, format_mod),
         {:ok, stats} <-
           process_file(
             import_log,
             path,
             format_mod,
             config,
             language,
             option_mappings,
             download_images
           ),
         {:ok, _import_log} <- complete_import(import_log, stats) do
      if skip_empty_categories, do: cleanup_empty_categories(stats)
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
    config_id = get_in(import_log.options, ["config_id"])

    if config_id do
      load_config_by_id(config_id)
    else
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

  defp detect_format(path) do
    case FormatDetector.detect(path) do
      {:ok, format_mod} ->
        Logger.info("CSVImportWorker: Detected format: #{FormatDetector.format_name(format_mod)}")

        {:ok, format_mod}

      {:error, :unknown_format} ->
        {:error, {:validation_failed, :unknown_format}}

      {:error, _} = error ->
        error
    end
  end

  defp validate_file(path, format_mod, config) do
    if File.exists?(path) do
      required_columns = get_required_columns(format_mod, config)

      case CSVValidator.validate_headers(path, required_columns) do
        {:ok, _headers} -> :ok
        {:error, reason} -> {:error, {:validation_failed, reason}}
      end
    else
      {:error, :file_not_found}
    end
  end

  defp get_required_columns(format_mod, config) do
    # Use format-specific required columns from default_config_attrs
    # rather than the loaded config (which may be for a different format)
    format_defaults = format_mod.default_config_attrs()
    format_required = Map.get(format_defaults, :required_columns, [])

    if format_required != [] do
      format_required
    else
      case config do
        %ImportConfig{required_columns: cols} when is_list(cols) -> cols
        _ -> ImportConfig.default_required_columns()
      end
    end
  end

  defp count_products(path, format_mod, config) do
    {:ok, format_mod.count(path, config)}
  rescue
    e ->
      Logger.error("CSVImportWorker: Failed to count products - #{inspect(e)}")
      {:error, {:parse_error, e}}
  end

  defp start_import(import_log, total_rows, format_mod) do
    with {:ok, updated_log} <- Shop.start_import(import_log, total_rows) do
      broadcast_started(import_log.id, total_rows)

      Logger.info(
        "CSVImportWorker: Format #{FormatDetector.format_name(format_mod)}, #{total_rows} products"
      )

      {:ok, updated_log}
    end
  end

  defp process_file(
         import_log,
         path,
         format_mod,
         config,
         language,
         option_mappings,
         download_images_arg
       ) do
    categories_map = build_categories_map()
    download_images = download_images_arg || should_download_images?(config)
    user_id = import_log.user_id

    opts = [language: language, option_mappings: option_mappings]

    stats = %{
      imported_count: 0,
      updated_count: 0,
      skipped_count: 0,
      error_count: 0,
      error_details: [],
      image_jobs_queued: 0,
      product_ids: []
    }

    result =
      format_mod.parse_and_transform(path, categories_map, config, opts)
      |> Enum.with_index(1)
      |> Enum.reduce(stats, fn {attrs, index}, acc ->
        result = upsert_product(attrs)
        new_acc = update_stats(acc, result)
        new_acc = maybe_queue_image_migration(new_acc, result, download_images, user_id)

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

  defp upsert_product(attrs) do
    case Shop.upsert_product(attrs) do
      {:ok, product, :inserted} ->
        {:imported, nil, product}

      {:ok, product, :updated} ->
        {:updated, nil, product}

      {:error, changeset} ->
        {:error, nil, changeset}
    end
  rescue
    e ->
      {:error, nil, e}
  end

  defp update_stats(stats, result) do
    case result do
      {:imported, _handle, product} ->
        %{
          stats
          | imported_count: stats.imported_count + 1,
            product_ids: [product.id | stats.product_ids]
        }

      {:updated, _handle, product} ->
        %{
          stats
          | updated_count: stats.updated_count + 1,
            product_ids: [product.id | stats.product_ids]
        }

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

  defp should_download_images?(%ImportConfig{download_images: true}), do: true
  defp should_download_images?(_), do: false

  defp maybe_queue_image_migration(stats, result, download_images, user_id) do
    if download_images do
      case result do
        {:imported, _handle, product} ->
          queue_image_job(product, user_id)
          %{stats | image_jobs_queued: stats.image_jobs_queued + 1}

        {:updated, _handle, product} ->
          queue_image_job(product, user_id)
          %{stats | image_jobs_queued: stats.image_jobs_queued + 1}

        _ ->
          stats
      end
    else
      stats
    end
  end

  defp queue_image_job(product, user_id) do
    has_legacy = has_legacy_images?(product)
    has_storage = has_storage_images?(product)

    if has_legacy and not has_storage do
      ImageMigrationWorker.new(%{
        product_id: product.id,
        user_id: user_id
      })
      |> Oban.insert()
    end
  end

  defp has_legacy_images?(product) do
    (is_list(product.images) and product.images != []) or
      (is_binary(product.featured_image) and String.starts_with?(product.featured_image, "http"))
  end

  defp has_storage_images?(product) do
    not is_nil(product.featured_image_id) or
      (is_list(product.image_ids) and product.image_ids != [])
  end

  defp complete_import(import_log, stats) do
    corrected_stats = Map.update!(stats, :product_ids, &Enum.reverse/1)
    Shop.complete_import(import_log, corrected_stats)
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

  defp cleanup_empty_categories(_stats) do
    empty_categories = Shop.list_empty_categories()

    Enum.each(empty_categories, fn cat ->
      case Shop.delete_category(cat) do
        {:ok, _} ->
          Logger.info("CSVImportWorker: Removed empty category: #{cat.id}")

        {:error, _} ->
          Logger.warning("CSVImportWorker: Failed to remove empty category: #{cat.id}")
      end
    end)

    if empty_categories != [] do
      Logger.info("CSVImportWorker: Cleaned up #{length(empty_categories)} empty categories")
    end
  rescue
    e ->
      Logger.warning("CSVImportWorker: Category cleanup failed - #{inspect(e)}")
  end

  defp cleanup_file(path) do
    File.rm(path)
  rescue
    _ -> :ok
  end

  defp build_categories_map do
    lang = Translations.default_language()

    Shop.list_categories()
    |> Enum.reduce(%{}, fn cat, acc ->
      slug = Translations.get(cat, :slug, lang)

      if slug && slug != "" do
        Map.put(acc, slug, cat.id)
      else
        acc
      end
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
    broadcast_general({:import_complete, %{import_log_id: import_log_id, stats: stats}})
  end

  defp broadcast_failed(import_log_id, reason) do
    broadcast(import_log_id, {:import_failed, %{reason: inspect(reason)}})
    broadcast_general({:import_failed, %{import_log_id: import_log_id, reason: inspect(reason)}})
  end

  defp broadcast(import_log_id, message) do
    topic = "shop:import:#{import_log_id}"
    Manager.broadcast(topic, message)
  rescue
    _ -> :ok
  end

  defp broadcast_general(message) do
    Manager.broadcast("shop:imports", message)
  rescue
    _ -> :ok
  end

  defp default_import_language do
    Translations.default_language()
  end
end
