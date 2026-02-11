defmodule PhoenixKit.Modules.Shop.Web.Imports do
  @moduledoc """
  Admin LiveView for managing CSV product imports.

  Supports multiple CSV formats (Shopify, Prom.ua, etc.) via the ImportFormat behaviour.
  Format is auto-detected from file headers after upload.

  Features:
  - Multi-step import wizard with format-aware steps
  - File upload with drag-and-drop
  - Option mapping UI for formats that require it (e.g. Shopify)
  - Direct import for formats that don't (e.g. Prom.ua)
  - Import history table with statistics
  - Real-time progress tracking via PubSub
  - Retry failed imports
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Import.{CSVAnalyzer, FormatDetector}
  alias PhoenixKit.Modules.Shop.ImportLog
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.Services.ImageMigration
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Workers.CSVImportWorker
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Utils.Routes

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to import updates
      Manager.subscribe("shop:imports")
      # Subscribe to image migration updates
      Manager.subscribe("shop:image_migration:batch")

      # Subscribe to any active imports (processing status)
      subscribe_to_active_imports()
    end

    # Language selection for import
    enabled_languages = Translations.enabled_languages()
    current_language = Translations.default_language()
    show_language_selector = length(enabled_languages) > 1

    # Get image migration stats
    migration_stats = ImageMigration.migration_stats()

    # Get global options for mapping UI
    global_options = Options.get_enabled_global_options()

    # Load import configs for filter selection
    import_configs = Shop.list_import_configs(active_only: true)
    default_config = Shop.get_default_import_config()

    socket =
      socket
      |> assign(:page_title, "CSV Import")
      |> assign(:imports, list_imports())
      |> assign(:current_import, nil)
      |> assign(:import_progress, nil)
      |> assign(:current_language, current_language)
      |> assign(:enabled_languages, enabled_languages)
      |> assign(:show_language_selector, show_language_selector)
      |> assign(:download_images, false)
      |> assign(:skip_empty_categories, true)
      |> assign(:migration_stats, migration_stats)
      |> assign(:migration_in_progress, migration_stats.in_progress > 0)
      |> assign(:import_configs, import_configs)
      |> assign(:selected_config, default_config)
      |> assign(:selected_config_id, if(default_config, do: default_config.id))
      # Multi-step wizard state
      |> assign(:import_step, :upload)
      |> assign(:format_mod, nil)
      |> assign(:format_name, nil)
      |> assign(:csv_analysis, nil)
      |> assign(:option_mappings, [])
      |> assign(:uploaded_file_path, nil)
      |> assign(:uploaded_filename, nil)
      |> assign(:confirm_product_count, nil)
      |> assign(:global_options, global_options)
      |> allow_upload(:csv_file,
        accept: ~w(.csv),
        max_file_size: 50_000_000,
        max_entries: 1,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :csv_file, ref)}
  end

  @impl true
  def handle_event("start_import", _params, socket) do
    # Multi-step: consume upload, detect format, then route to appropriate step
    case consume_uploaded_entries(socket, :csv_file, fn %{path: path}, entry ->
           dest_dir = Path.join(System.tmp_dir!(), "shop_imports")
           File.mkdir_p!(dest_dir)

           dest_path =
             Path.join(dest_dir, "#{System.system_time(:millisecond)}_#{entry.client_name}")

           File.cp!(path, dest_path)
           {:ok, {dest_path, entry.client_name}}
         end) do
      [{dest_path, filename}] ->
        # Detect format from file headers
        case FormatDetector.detect(dest_path) do
          {:ok, format_mod} ->
            if format_mod.requires_option_mapping?() do
              # Shopify path: analyze CSV, show mapping UI
              handle_mapping_format(socket, dest_path, filename, format_mod)
            else
              # Prom.ua path: skip configure, go to confirm
              handle_direct_format(socket, dest_path, filename, format_mod)
            end

          {:error, :unknown_format} ->
            File.rm(dest_path)
            {:noreply, put_flash(socket, :error, "Unrecognized CSV format")}

          {:error, _reason} ->
            File.rm(dest_path)
            {:noreply, put_flash(socket, :error, "Failed to read CSV file headers")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Please select a CSV file first")}
    end
  end

  @impl true
  def handle_event("confirm_import", _params, socket) do
    # Direct import from confirm step (no option mappings)
    run_import_with_mappings(socket, [])
  end

  @impl true
  def handle_event("skip_mapping", _params, socket) do
    # Skip mapping step and run import directly
    run_import_with_mappings(socket, [])
  end

  @impl true
  def handle_event("run_import", _params, socket) do
    # Run import with current mappings
    mappings = socket.assigns.option_mappings
    run_import_with_mappings(socket, mappings)
  end

  @impl true
  def handle_event("update_mapping", %{"index" => index_str} = params, socket) do
    index = String.to_integer(index_str)
    mappings = socket.assigns.option_mappings

    updated_mapping =
      mappings
      |> Enum.at(index)
      |> update_mapping_from_params(params)

    updated_mappings = List.replace_at(mappings, index, updated_mapping)

    {:noreply, assign(socket, :option_mappings, updated_mappings)}
  end

  @impl true
  def handle_event("toggle_auto_add", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    mappings = socket.assigns.option_mappings

    updated_mapping =
      mappings
      |> Enum.at(index)
      |> Map.update!(:auto_add, &(!&1))

    updated_mappings = List.replace_at(mappings, index, updated_mapping)

    {:noreply, assign(socket, :option_mappings, updated_mappings)}
  end

  @impl true
  def handle_event("back_to_upload", _params, socket) do
    if socket.assigns.uploaded_file_path do
      File.rm(socket.assigns.uploaded_file_path)
    end

    socket =
      socket
      |> assign(:import_step, :upload)
      |> assign(:format_mod, nil)
      |> assign(:format_name, nil)
      |> assign(:csv_analysis, nil)
      |> assign(:option_mappings, [])
      |> assign(:uploaded_file_path, nil)
      |> assign(:uploaded_filename, nil)
      |> assign(:confirm_product_count, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_import", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, import_id} ->
        do_retry_import(import_id, socket)

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid import ID")}
    end
  end

  @impl true
  def handle_event("delete_import", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, import_id} ->
        do_delete_import(import_id, socket)

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid import ID")}
    end
  end

  @impl true
  def handle_event("toggle_download_images", _params, socket) do
    {:noreply, assign(socket, :download_images, not socket.assigns.download_images)}
  end

  @impl true
  def handle_event("toggle_skip_empty_categories", _params, socket) do
    {:noreply, assign(socket, :skip_empty_categories, not socket.assigns.skip_empty_categories)}
  end

  @impl true
  def handle_event("select_language", %{"language" => lang}, socket) do
    {:noreply, assign(socket, :current_language, lang)}
  end

  @impl true
  def handle_event("select_config", %{"config_id" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:selected_config, nil)
     |> assign(:selected_config_id, nil)}
  end

  @impl true
  def handle_event("select_config", %{"config_id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        config = Enum.find(socket.assigns.import_configs, &(&1.id == id))

        {:noreply,
         socket
         |> assign(:selected_config, config)
         |> assign(:selected_config_id, if(config, do: config.id))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_image_migration", _params, socket) do
    user = socket.assigns.phoenix_kit_current_scope.user
    {:ok, count} = ImageMigration.queue_all_migrations(user.id)

    socket =
      socket
      |> assign(:migration_in_progress, true)
      |> assign(:migration_stats, ImageMigration.migration_stats())
      |> put_flash(:info, "Started migration for #{count} products")

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_image_migration", _params, socket) do
    case ImageMigration.cancel_pending_migrations() do
      {:ok, count} ->
        socket =
          socket
          |> assign(:migration_in_progress, false)
          |> assign(:migration_stats, ImageMigration.migration_stats())
          |> put_flash(:info, "Cancelled #{count} pending migration jobs")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_migration_stats", _params, socket) do
    stats = ImageMigration.migration_stats()

    socket =
      socket
      |> assign(:migration_stats, stats)
      |> assign(:migration_in_progress, stats.in_progress > 0)

    {:noreply, socket}
  end

  # Handle PubSub messages
  @impl true
  def handle_info({:import_started, %{total: total}}, socket) do
    socket =
      socket
      |> assign(:import_progress, %{percent: 0, current: 0, total: total})
      |> assign(:imports, list_imports())

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_progress, progress}, socket) do
    {:noreply, assign(socket, :import_progress, progress)}
  end

  @impl true
  def handle_info({:import_complete, _stats}, socket) do
    socket =
      socket
      |> assign(:current_import, nil)
      |> assign(:import_progress, nil)
      |> assign(:import_step, :upload)
      |> assign(:format_mod, nil)
      |> assign(:format_name, nil)
      |> assign(:csv_analysis, nil)
      |> assign(:option_mappings, [])
      |> assign(:uploaded_file_path, nil)
      |> assign(:uploaded_filename, nil)
      |> assign(:confirm_product_count, nil)
      |> assign(:imports, list_imports())
      |> put_flash(:info, "Import completed successfully!")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_failed, %{reason: reason}}, socket) do
    socket =
      socket
      |> assign(:current_import, nil)
      |> assign(:import_progress, nil)
      |> assign(:import_step, :upload)
      |> assign(:format_mod, nil)
      |> assign(:format_name, nil)
      |> assign(:csv_analysis, nil)
      |> assign(:option_mappings, [])
      |> assign(:uploaded_file_path, nil)
      |> assign(:uploaded_filename, nil)
      |> assign(:confirm_product_count, nil)
      |> assign(:imports, list_imports())
      |> put_flash(:error, "Import failed: #{reason}")

    {:noreply, socket}
  end

  # Image migration PubSub handlers
  @impl true
  def handle_info({:migration_started, %{total: total}}, socket) do
    Logger.info("Image migration started for #{total} products")

    socket =
      socket
      |> assign(:migration_in_progress, true)
      |> assign(:migration_stats, ImageMigration.migration_stats())

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:product_migrated, %{product_id: _product_id, images_migrated: _count}},
        socket
      ) do
    # Update stats on each product completion
    stats = ImageMigration.migration_stats()

    socket =
      socket
      |> assign(:migration_stats, stats)
      |> assign(:migration_in_progress, stats.in_progress > 0)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:migration_cancelled, %{cancelled: count}}, socket) do
    Logger.info("Image migration cancelled: #{count} jobs")

    socket =
      socket
      |> assign(:migration_in_progress, false)
      |> assign(:migration_stats, ImageMigration.migration_stats())

    {:noreply, socket}
  end

  # Catch-all for other messages
  @impl true
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  defp handle_progress(:csv_file, entry, socket) do
    if entry.done? do
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp list_imports do
    Shop.list_import_logs(limit: 20, order_by: [desc: :inserted_at])
  end

  # Subscribe to any imports currently in "processing" status
  defp subscribe_to_active_imports do
    Shop.list_import_logs(limit: 10, order_by: [desc: :inserted_at])
    |> Enum.filter(&(&1.status == "processing"))
    |> Enum.each(fn import_log ->
      Manager.subscribe("shop:import:#{import_log.id}")
    end)
  end

  # Parse ID from phx-value (comes as string from the template)
  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp do_retry_import(import_id, socket) do
    case Shop.get_import_log(import_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Import not found")}

      import_log ->
        if import_log.status == "failed" && import_log.file_path &&
             File.exists?(import_log.file_path) do
          # Reset import log status
          {:ok, updated_log} =
            Shop.update_import_log(import_log, %{status: "pending", error_details: []})

          # Re-enqueue job with language and config_id
          language = socket.assigns.current_language
          config_id = get_in(import_log.options, ["config_id"])

          worker_args = %{
            import_log_id: updated_log.id,
            path: import_log.file_path,
            language: language
          }

          worker_args =
            if config_id, do: Map.put(worker_args, :config_id, config_id), else: worker_args

          worker_args
          |> CSVImportWorker.new()
          |> Oban.insert()

          # Subscribe to updates
          Manager.subscribe("shop:import:#{updated_log.id}")

          socket =
            socket
            |> assign(:current_import, updated_log)
            |> assign(:import_progress, %{percent: 0, current: 0, total: 0})
            |> assign(:imports, list_imports())
            |> put_flash(:info, "Retrying import: #{import_log.filename}")

          {:noreply, socket}
        else
          {:noreply, put_flash(socket, :error, "Cannot retry: file no longer exists")}
        end
    end
  end

  defp do_delete_import(import_id, socket) do
    case Shop.get_import_log(import_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Import not found")}

      import_log ->
        case Shop.delete_import_log(import_log) do
          {:ok, _} ->
            socket =
              socket
              |> assign(:imports, list_imports())
              |> put_flash(:info, "Import log deleted")

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete import log")}
        end
    end
  end

  # Run import with given mappings
  defp run_import_with_mappings(socket, mappings) do
    user = socket.assigns.phoenix_kit_current_scope.user
    dest_path = socket.assigns.uploaded_file_path
    filename = socket.assigns.uploaded_filename

    # Add new values to global options if auto_add enabled
    add_new_values_to_global_options(mappings, socket.assigns.global_options)

    # Convert mappings to format expected by worker
    worker_mappings = convert_mappings_for_worker(mappings)

    # Create import log with config_id
    config_id = socket.assigns.selected_config_id

    case Shop.create_import_log(%{
           filename: filename,
           file_path: dest_path,
           user_id: user.id,
           options: %{"option_mappings" => worker_mappings, "config_id" => config_id}
         }) do
      {:ok, import_log} ->
        # Enqueue Oban job with language, mappings, config_id, and download_images option
        language = socket.assigns.current_language
        download_images = socket.assigns.download_images

        skip_empty_categories = socket.assigns[:skip_empty_categories] || false

        worker_args = %{
          import_log_id: import_log.id,
          path: dest_path,
          language: language,
          option_mappings: worker_mappings,
          download_images: download_images,
          skip_empty_categories: skip_empty_categories
        }

        worker_args =
          if config_id, do: Map.put(worker_args, :config_id, config_id), else: worker_args

        worker_args
        |> CSVImportWorker.new()
        |> Oban.insert()

        # Subscribe to this specific import
        Manager.subscribe("shop:import:#{import_log.id}")

        socket =
          socket
          |> assign(:current_import, import_log)
          |> assign(:import_progress, %{percent: 0, current: 0, total: 0})
          |> assign(:imports, list_imports())
          |> assign(:import_step, :importing)
          |> put_flash(:info, "Import started: #{filename}")

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create import log")}
    end
  end

  # Build initial mappings by matching CSV options to global options
  defp build_initial_mappings(csv_options, global_options) do
    Enum.map(csv_options, fn csv_opt ->
      # Try to find matching global option
      matching_global = find_matching_global_option(csv_opt.name, global_options)

      # Compare values if we have a match
      comparison =
        if matching_global do
          CSVAnalyzer.compare_with_global_option(csv_opt.values, matching_global)
        else
          %{existing: [], new: csv_opt.values}
        end

      %{
        csv_name: csv_opt.name,
        csv_position: csv_opt.position,
        csv_values: csv_opt.values,
        source_key: if(matching_global, do: matching_global["key"], else: nil),
        slot_key: normalize_slot_key(csv_opt.name),
        label: csv_opt.name,
        auto_add: false,
        new_values: comparison.new,
        existing_values: comparison.existing,
        global_option: matching_global
      }
    end)
  end

  # Find global option that might match the CSV option name
  defp find_matching_global_option(csv_name, global_options) do
    # Normalize names for comparison
    normalized_csv = normalize_for_comparison(csv_name)

    Enum.find(global_options, fn opt ->
      opt_key = opt["key"]
      opt_label = get_option_label(opt)

      normalized_csv == normalize_for_comparison(opt_key) or
        normalized_csv == normalize_for_comparison(opt_label) or
        String.contains?(normalized_csv, normalize_for_comparison(opt_key))
    end)
  end

  defp get_option_label(%{"label" => label}) when is_binary(label), do: label
  defp get_option_label(%{"label" => label}) when is_map(label), do: Map.get(label, "en", "")
  defp get_option_label(_), do: ""

  defp normalize_for_comparison(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/, "")
  end

  defp normalize_for_comparison(_), do: ""

  defp normalize_slot_key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/[^a-z0-9_]/, "")
  end

  # Update mapping from form params
  defp update_mapping_from_params(mapping, params) do
    mapping
    |> maybe_update(:source_key, params["source_key"])
    |> maybe_update(:slot_key, params["slot_key"])
    |> maybe_update(:label, params["label"])
  end

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, _key, ""), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  # Add new values to global options for mappings with auto_add enabled
  defp add_new_values_to_global_options(mappings, _global_options) do
    # Log all mappings to see auto_add state
    Logger.info("add_new_values_to_global_options: #{length(mappings)} mappings")

    eligible =
      mappings
      |> Enum.filter(fn m -> m.auto_add && m.source_key && m.new_values != [] end)

    Logger.info("Eligible mappings with auto_add=true: #{length(eligible)}")

    Enum.each(eligible, fn mapping ->
      Logger.info("Adding #{length(mapping.new_values)} values to #{mapping.source_key}")

      Enum.each(mapping.new_values, fn value ->
        result = Options.add_value_to_global_option(mapping.source_key, value)
        Logger.debug("Added #{value} to #{mapping.source_key}: #{inspect(result)}")
      end)
    end)
  end

  # Convert UI mappings to worker format
  defp convert_mappings_for_worker(mappings) do
    mappings
    |> Enum.filter(fn m -> m.source_key != nil end)
    |> Enum.map(fn m ->
      %{
        "csv_name" => m.csv_name,
        "slot_key" => m.slot_key,
        "source_key" => m.source_key,
        "label" => m.label,
        "auto_add" => m.auto_add
      }
    end)
  end

  # Handle format that requires option mapping (Shopify)
  defp handle_mapping_format(socket, dest_path, filename, format_mod) do
    case safe_analyze_csv(dest_path) do
      {:ok, analysis} ->
        initial_mappings =
          build_initial_mappings(analysis.options, socket.assigns.global_options)

        socket =
          socket
          |> assign(:format_mod, format_mod)
          |> assign(:format_name, FormatDetector.format_name(format_mod))
          |> assign(:uploaded_file_path, dest_path)
          |> assign(:uploaded_filename, filename)
          |> assign(:csv_analysis, analysis)
          |> assign(:option_mappings, initial_mappings)
          |> assign(:import_step, :configure)

        {:noreply, socket}

      {:error, message} ->
        File.rm(dest_path)
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Handle format that doesn't require option mapping (Prom.ua)
  defp handle_direct_format(socket, dest_path, filename, format_mod) do
    product_count =
      try do
        format_mod.count(dest_path, nil)
      rescue
        _ -> 0
      end

    socket =
      socket
      |> assign(:format_mod, format_mod)
      |> assign(:format_name, FormatDetector.format_name(format_mod))
      |> assign(:uploaded_file_path, dest_path)
      |> assign(:uploaded_filename, filename)
      |> assign(:confirm_product_count, product_count)
      |> assign(:import_step, :confirm)

    {:noreply, socket}
  end

  # Safe CSV analysis with error handling
  defp safe_analyze_csv(path) do
    CSVAnalyzer.analyze_options(path)
    |> then(&{:ok, &1})
  rescue
    e in NimbleCSV.ParseError ->
      message = parse_csv_error(e.message)
      {:error, message}

    e ->
      Logger.error("CSV analysis failed: #{inspect(e)}")
      {:error, "Failed to parse CSV file. Please check the file format."}
  end

  defp parse_csv_error(message) do
    cond do
      String.contains?(message, "unexpected escape character") ->
        "CSV format error: The file contains incorrectly escaped quotes. " <>
          "Please export directly from Shopify using 'Export > CSV for Excel'."

      String.contains?(message, "reached the end of file") ->
        "CSV format error: The file has unclosed quotes. " <>
          "Please re-export from Shopify or check for corrupted data."

      true ->
        "CSV parse error: #{String.slice(message, 0, 100)}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path}
      current_locale={@current_locale}
      page_title={@page_title}
    >
      <div class="container flex-col mx-auto px-4 py-6 max-w-6xl">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/admin/shop")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">CSV Import</h1>
              <p class="text-base-content/70 mt-1">
                Import products from CSV files
                <%= if @format_name do %>
                  <span class="badge badge-primary badge-outline badge-sm ml-2">{@format_name}</span>
                <% end %>
              </p>
            </div>
          </div>
        </header>

        <%!-- Import Wizard Card --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <%!-- Wizard Steps Indicator --%>
            <%= if @format_mod && !@format_mod.requires_option_mapping?() do %>
              <%!-- 2-step wizard for formats without option mapping --%>
              <ul class="steps steps-horizontal w-full mb-6">
                <li class={[
                  "step",
                  if(@import_step in [:upload, :confirm, :importing], do: "step-primary")
                ]}>
                  Upload
                </li>
                <li class={[
                  "step",
                  if(@import_step in [:confirm, :importing], do: "step-primary")
                ]}>
                  Confirm
                </li>
                <li class={["step", if(@import_step == :importing, do: "step-primary")]}>
                  Import
                </li>
              </ul>
            <% else %>
              <%!-- 3-step wizard for formats with option mapping --%>
              <ul class="steps steps-horizontal w-full mb-6">
                <li class={[
                  "step",
                  if(@import_step in [:upload, :configure, :importing], do: "step-primary")
                ]}>
                  Upload
                </li>
                <li class={[
                  "step",
                  if(@import_step in [:configure, :importing], do: "step-primary")
                ]}>
                  Configure
                </li>
                <li class={["step", if(@import_step == :importing, do: "step-primary")]}>
                  Import
                </li>
              </ul>
            <% end %>

            <%= case @import_step do %>
              <% :upload -> %>
                <.render_upload_step
                  uploads={@uploads}
                  show_language_selector={@show_language_selector}
                  enabled_languages={@enabled_languages}
                  current_language={@current_language}
                  download_images={@download_images}
                  skip_empty_categories={@skip_empty_categories}
                  import_configs={@import_configs}
                  selected_config={@selected_config}
                  selected_config_id={@selected_config_id}
                />
              <% :configure -> %>
                <.render_configure_step
                  csv_analysis={@csv_analysis}
                  option_mappings={@option_mappings}
                  global_options={@global_options}
                  uploaded_filename={@uploaded_filename}
                  format_name={@format_name}
                />
              <% :confirm -> %>
                <.render_confirm_step
                  format_name={@format_name}
                  uploaded_filename={@uploaded_filename}
                  confirm_product_count={@confirm_product_count}
                  download_images={@download_images}
                  skip_empty_categories={@skip_empty_categories}
                />
              <% :importing -> %>
                <.render_importing_step
                  current_import={@current_import}
                  import_progress={@import_progress}
                />
            <% end %>
          </div>
        </div>

        <%!-- Image Migration Card --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-xl">
                <.icon name="hero-photo" class="w-6 h-6" /> Image Migration
              </h2>
              <button
                type="button"
                phx-click="refresh_migration_stats"
                class="btn btn-ghost btn-sm"
                title="Refresh stats"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4" />
              </button>
            </div>

            <p class="text-base-content/70 text-sm mt-2">
              Migrate product images from external CDN URLs to the Storage module for better control and reliability.
            </p>

            <%!-- Migration Stats --%>
            <div class="stats stats-horizontal shadow mt-4 w-full">
              <div class="stat place-items-center py-3">
                <div class="stat-title text-xs">Total Products</div>
                <div class="stat-value text-2xl">{@migration_stats.total}</div>
                <div class="stat-desc text-xs">with images</div>
              </div>

              <div class="stat place-items-center py-3">
                <div class="stat-title text-xs">Migrated</div>
                <div class="stat-value text-2xl text-success">{@migration_stats.migrated}</div>
                <div class="stat-desc text-xs">in Storage</div>
              </div>

              <div class="stat place-items-center py-3">
                <div class="stat-title text-xs">Pending</div>
                <div class="stat-value text-2xl text-warning">{@migration_stats.pending}</div>
                <div class="stat-desc text-xs">legacy URLs</div>
              </div>

              <div class="stat place-items-center py-3">
                <div class="stat-title text-xs">In Progress</div>
                <div class="stat-value text-2xl text-info">{@migration_stats.in_progress}</div>
                <div class="stat-desc text-xs">jobs</div>
              </div>

              <%= if @migration_stats.failed > 0 do %>
                <div class="stat place-items-center py-3">
                  <div class="stat-title text-xs">Failed</div>
                  <div class="stat-value text-2xl text-error">{@migration_stats.failed}</div>
                  <div class="stat-desc text-xs">errors</div>
                </div>
              <% end %>
            </div>

            <%!-- Progress Bar (when migration in progress) --%>
            <%= if @migration_in_progress and @migration_stats.total > 0 do %>
              <div class="mt-4">
                <% progress_percent =
                  if @migration_stats.total > 0,
                    do: round(@migration_stats.migrated / @migration_stats.total * 100),
                    else: 0 %>
                <progress
                  value={progress_percent}
                  max="100"
                  class="progress progress-primary w-full"
                />
                <p class="text-xs text-base-content/70 mt-1 text-center">
                  {progress_percent}% complete ({@migration_stats.migrated}/{@migration_stats.total})
                </p>
              </div>
            <% end %>

            <%!-- Action Buttons --%>
            <div class="card-actions justify-end mt-4">
              <%= if @migration_in_progress do %>
                <button
                  type="button"
                  phx-click="cancel_image_migration"
                  class="btn btn-outline btn-error"
                >
                  <.icon name="hero-stop" class="w-4 h-4 mr-2" /> Cancel Migration
                </button>
              <% else %>
                <%= if @migration_stats.pending > 0 do %>
                  <button
                    type="button"
                    phx-click="start_image_migration"
                    class="btn btn-primary"
                  >
                    <.icon name="hero-arrow-down-on-square-stack" class="w-4 h-4 mr-2" />
                    Migrate {@migration_stats.pending} Products
                  </button>
                <% else %>
                  <button type="button" class="btn btn-disabled" disabled>
                    <.icon name="hero-check-circle" class="w-4 h-4 mr-2" /> All Images Migrated
                  </button>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Import History --%>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-xl mb-4">
              <.icon name="hero-clock" class="w-6 h-6" /> Import History
            </h2>

            <%= if Enum.empty?(@imports) do %>
              <div class="text-center py-8 text-base-content/70">
                <.icon name="hero-inbox" class="w-12 h-12 mx-auto mb-2 opacity-50" />
                <p>No imports yet</p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table">
                  <thead>
                    <tr>
                      <th>File</th>
                      <th>Status</th>
                      <th>Progress</th>
                      <th>Results</th>
                      <th>Date</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for import <- @imports do %>
                      <tr class="hover">
                        <td class="font-medium max-w-[200px] truncate" title={import.filename}>
                          <.link
                            navigate={Routes.path("/admin/shop/imports/#{import.uuid}")}
                            class="link link-hover"
                          >
                            {import.filename}
                          </.link>
                        </td>
                        <td>
                          <.status_badge status={import.status} />
                        </td>
                        <td>
                          <%= if import.status == "processing" do %>
                            <progress
                              value={ImportLog.progress_percent(import)}
                              max="100"
                              class="progress progress-primary w-20"
                            />
                          <% else %>
                            {ImportLog.progress_percent(import)}%
                          <% end %>
                        </td>
                        <td class="text-sm">
                          <span class="text-success">{import.imported_count} new</span>
                          <span class="text-info ml-2">{import.updated_count} updated</span>
                          <%= if import.error_count > 0 do %>
                            <span class="text-error ml-2">{import.error_count} errors</span>
                          <% end %>
                        </td>
                        <td class="text-sm text-base-content/70">
                          {format_datetime(import.inserted_at)}
                        </td>
                        <td>
                          <div class="flex gap-1">
                            <.link
                              navigate={Routes.path("/admin/shop/imports/#{import.uuid}")}
                              class="btn btn-xs btn-ghost"
                              title="View Details"
                            >
                              <.icon name="hero-eye" class="w-4 h-4" />
                            </.link>
                            <%= if import.status == "failed" do %>
                              <button
                                phx-click="retry_import"
                                phx-value-id={import.id}
                                class="btn btn-xs btn-ghost text-warning"
                                title="Retry"
                              >
                                <.icon name="hero-arrow-path" class="w-4 h-4" />
                              </button>
                            <% end %>
                            <%= if import.status in ["completed", "failed"] do %>
                              <button
                                phx-click="delete_import"
                                phx-value-id={import.id}
                                class="btn btn-xs btn-ghost text-error"
                                title="Delete"
                                data-confirm="Are you sure you want to delete this import log?"
                              >
                                <.icon name="hero-trash" class="w-4 h-4" />
                              </button>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Info Alert --%>
        <div class="alert alert-info mt-6">
          <.icon name="hero-information-circle" class="w-6 h-6" />
          <div>
            <h3 class="font-bold">About CSV Import</h3>
            <ul class="text-sm mt-1 list-disc list-inside">
              <li>Supported formats: Shopify, Prom.ua (auto-detected from file headers)</li>
              <li>Products are automatically categorized based on title or category name</li>
              <li>Existing products with the same slug are updated</li>
              <li>Import runs in the background — you can leave this page</li>
            </ul>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # ============================================
  # WIZARD STEP COMPONENTS
  # ============================================

  defp render_upload_step(assigns) do
    ~H"""
    <h2 class="card-title text-xl mb-4">
      <.icon name="hero-cloud-arrow-up" class="w-6 h-6" /> Upload CSV File
    </h2>

    <%!-- Language Selection --%>
    <%= if @show_language_selector do %>
      <div class="form-control mb-4">
        <label class="label">
          <span class="label-text font-medium">
            <.icon name="hero-language" class="w-4 h-4 inline mr-1" /> Import Language
          </span>
        </label>
        <div class="flex flex-wrap gap-2">
          <%= for lang <- @enabled_languages do %>
            <button
              type="button"
              phx-click="select_language"
              phx-value-language={lang}
              class={[
                "btn btn-sm",
                if(lang == @current_language, do: "btn-primary", else: "btn-outline")
              ]}
            >
              {String.upcase(lang)}
            </button>
          <% end %>
        </div>
        <label class="label">
          <span class="label-text-alt text-base-content/60">
            Text fields will be imported to this language
          </span>
        </label>
      </div>
    <% else %>
      <div class="flex items-center gap-2 text-sm text-base-content/70 mb-4">
        <.icon name="hero-language" class="w-4 h-4" />
        <span>Import language: <strong>{String.upcase(@current_language)}</strong></span>
      </div>
    <% end %>

    <%!-- Import Config Selector --%>
    <%= if @import_configs != [] do %>
      <div class="form-control mb-4">
        <label class="label">
          <span class="label-text font-medium">
            <.icon name="hero-funnel" class="w-4 h-4 inline mr-1" /> Import Filter
          </span>
        </label>
        <select
          class="select select-bordered w-full"
          phx-change="select_config"
          name="config_id"
        >
          <option value="">No filter (import all products)</option>
          <%= for config <- @import_configs do %>
            <option value={config.id} selected={@selected_config_id == config.id}>
              {config.name}{if config.is_default, do: " (default)"}
            </option>
          <% end %>
        </select>
        <%= if @selected_config do %>
          <div class="flex flex-wrap gap-1 mt-2">
            <%= unless @selected_config.skip_filter do %>
              <span class="badge badge-sm badge-success badge-outline">
                {length(@selected_config.include_keywords)} include
              </span>
              <span class="badge badge-sm badge-error badge-outline">
                {length(@selected_config.exclude_keywords)} exclude
              </span>
              <span class="badge badge-sm badge-info badge-outline">
                {length(@selected_config.category_rules)} category rules
              </span>
            <% else %>
              <span class="badge badge-sm badge-warning">Skip filter — all products imported</span>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>

    <%!-- File Upload Zone --%>
    <form phx-change="validate" phx-submit="start_import" id="csv-upload-form">
      <div
        class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center transition-colors cursor-pointer hover:border-primary hover:bg-primary/5"
        phx-drop-target={@uploads.csv_file.ref}
      >
        <label for={@uploads.csv_file.ref} class="cursor-pointer block">
          <div class="flex flex-col items-center gap-2">
            <.icon name="hero-document-arrow-up" class="w-12 h-12 text-primary" />
            <div>
              <p class="font-semibold text-base-content">
                Drag CSV file here or click to browse
              </p>
              <p class="text-sm text-base-content/70 mt-1">
                Shopify or Prom.ua CSV format, max 50MB
              </p>
            </div>
          </div>
        </label>
        <.live_file_input upload={@uploads.csv_file} class="hidden" />
      </div>

      <%!-- Upload Progress --%>
      <%= for entry <- @uploads.csv_file.entries do %>
        <div class="mt-4 p-4 border border-base-300 rounded-lg bg-base-50">
          <div class="flex items-center justify-between mb-2">
            <span class="font-medium">{entry.client_name}</span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="btn btn-xs btn-ghost text-error"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
          <progress
            value={entry.progress}
            max="100"
            class="progress progress-primary w-full"
          />

          <%= for err <- upload_errors(@uploads.csv_file, entry) do %>
            <p class="text-error text-sm mt-2">{error_to_string(err)}</p>
          <% end %>
        </div>
      <% end %>

      <%!-- Download Images Option --%>
      <div class="form-control mt-4">
        <label class="label cursor-pointer justify-start gap-3">
          <input
            type="checkbox"
            class="checkbox checkbox-primary"
            checked={@download_images}
            phx-click="toggle_download_images"
          />
          <span class="label-text">
            <span class="font-medium">Download images to Storage</span>
            <span class="block text-xs text-base-content/60">
              Images will be downloaded from CDN URLs and stored in the Storage module
            </span>
          </span>
        </label>
      </div>

      <div class="form-control mt-2">
        <label class="label cursor-pointer justify-start gap-3">
          <input
            type="checkbox"
            class="checkbox checkbox-primary"
            checked={@skip_empty_categories}
            phx-click="toggle_skip_empty_categories"
          />
          <span class="label-text">
            <span class="font-medium">Skip empty categories</span>
            <span class="block text-xs text-base-content/60">
              Remove auto-created categories that have no products after import
            </span>
          </span>
        </label>
      </div>

      <%!-- Start Import Button --%>
      <%= if length(@uploads.csv_file.entries) > 0 do %>
        <% entry = List.first(@uploads.csv_file.entries) %>
        <%= if entry.done? do %>
          <button type="submit" class="btn btn-primary btn-block mt-4">
            <.icon name="hero-arrow-right" class="w-5 h-5 mr-2" /> Analyze & Configure
          </button>
        <% end %>
      <% end %>
    </form>
    """
  end

  defp render_configure_step(assigns) do
    ~H"""
    <h2 class="card-title text-xl mb-4">
      <.icon name="hero-adjustments-horizontal" class="w-6 h-6" /> Configure Option Mappings
      <%= if @format_name do %>
        <span class="badge badge-primary badge-outline badge-sm">{@format_name}</span>
      <% end %>
    </h2>

    <div class="alert alert-info mb-4">
      <.icon name="hero-information-circle" class="w-5 h-5" />
      <div>
        <p class="font-medium">File: {@uploaded_filename}</p>
        <p class="text-sm">
          Found {@csv_analysis.total_products} products with {@csv_analysis.total_variants} variants
        </p>
      </div>
    </div>

    <%= if @option_mappings == [] do %>
      <div class="alert alert-warning mb-4">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span>No options found in CSV file. You can proceed with basic import.</span>
      </div>
    <% else %>
      <div class="space-y-4 mb-6">
        <%= for {mapping, index} <- Enum.with_index(@option_mappings) do %>
          <.render_mapping_card mapping={mapping} index={index} global_options={@global_options} />
        <% end %>
      </div>
    <% end %>

    <%!-- Action Buttons --%>
    <div class="flex gap-3 mt-6">
      <button type="button" phx-click="back_to_upload" class="btn btn-outline">
        <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
      </button>
      <div class="flex-1"></div>
      <%= if @option_mappings != [] do %>
        <button type="button" phx-click="skip_mapping" class="btn btn-ghost">
          Skip Mapping
        </button>
      <% end %>
      <button type="button" phx-click="run_import" class="btn btn-primary">
        <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-2" /> Start Import
      </button>
    </div>
    """
  end

  defp render_mapping_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow">
      <div class="card-body py-4">
        <div class="flex items-start gap-4">
          <%!-- CSV Option Info --%>
          <div class="flex-1">
            <h3 class="font-medium text-lg">{@mapping.csv_name}</h3>
            <p class="text-sm text-base-content/70">
              Position {@mapping.csv_position} · {@mapping.csv_values |> length()} values
            </p>
            <div class="flex flex-wrap gap-1 mt-2">
              <%= for value <- Enum.take(@mapping.csv_values, 5) do %>
                <span class="badge badge-sm badge-outline">{value}</span>
              <% end %>
              <%= if length(@mapping.csv_values) > 5 do %>
                <span class="badge badge-sm badge-ghost">
                  +{length(@mapping.csv_values) - 5} more
                </span>
              <% end %>
            </div>
          </div>

          <%!-- Mapping Config --%>
          <div class="flex-1">
            <label class="form-control">
              <div class="label py-1">
                <span class="label-text text-xs">Link to Global Option</span>
              </div>
              <select
                class="select select-bordered select-sm w-full"
                phx-change="update_mapping"
                phx-value-index={@index}
                name="source_key"
              >
                <option value="">— Standalone (no mapping) —</option>
                <%= for opt <- @global_options do %>
                  <option value={opt["key"]} selected={@mapping.source_key == opt["key"]}>
                    {opt["key"]} - {get_global_option_label(opt)}
                  </option>
                <% end %>
              </select>
            </label>

            <%= if @mapping.source_key do %>
              <label class="form-control mt-2">
                <div class="label py-1">
                  <span class="label-text text-xs">Slot Key</span>
                </div>
                <input
                  type="text"
                  class="input input-bordered input-sm w-full"
                  value={@mapping.slot_key}
                  phx-blur="update_mapping"
                  phx-value-index={@index}
                  name="slot_key"
                  placeholder="e.g., cup_color"
                />
              </label>
            <% end %>
          </div>
        </div>

        <%!-- New Values Warning --%>
        <%= if @mapping.source_key && @mapping.new_values != [] do %>
          <div class="divider my-2"></div>
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-warning font-medium">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
                {length(@mapping.new_values)} new values not in global option
              </p>
              <div class="flex flex-wrap gap-1 mt-1">
                <%= for value <- Enum.take(@mapping.new_values, 3) do %>
                  <span class="badge badge-sm badge-warning badge-outline">{value}</span>
                <% end %>
                <%= if length(@mapping.new_values) > 3 do %>
                  <span class="badge badge-sm badge-ghost">+{length(@mapping.new_values) - 3}</span>
                <% end %>
              </div>
            </div>
            <label class="label cursor-pointer gap-2">
              <span class="label-text text-sm">Auto-add</span>
              <input
                type="checkbox"
                class="toggle toggle-primary toggle-sm"
                checked={@mapping.auto_add}
                phx-click="toggle_auto_add"
                phx-value-index={@index}
              />
            </label>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_confirm_step(assigns) do
    ~H"""
    <h2 class="card-title text-xl mb-4">
      <.icon name="hero-check-circle" class="w-6 h-6" /> Confirm Import
      <span class="badge badge-primary badge-outline badge-sm">{@format_name}</span>
    </h2>

    <div class="alert alert-info mb-4">
      <.icon name="hero-information-circle" class="w-5 h-5" />
      <div>
        <p class="font-medium">File: {@uploaded_filename}</p>
        <p class="text-sm">
          Found {@confirm_product_count} products to import
        </p>
      </div>
    </div>

    <div class="bg-base-200 rounded-lg p-4 mb-4">
      <h3 class="font-medium mb-2">Import details:</h3>
      <ul class="text-sm space-y-1 text-base-content/80">
        <li>
          <.icon name="hero-document-text" class="w-4 h-4 inline mr-1" /> Format:
          <strong>{@format_name}</strong>
        </li>
        <li>
          <.icon name="hero-cube" class="w-4 h-4 inline mr-1" /> Products:
          <strong>{@confirm_product_count}</strong>
        </li>
        <li>
          <.icon name="hero-photo" class="w-4 h-4 inline mr-1" /> Download images:
          <strong>{if @download_images, do: "Yes", else: "No"}</strong>
        </li>
        <li>
          <.icon name="hero-folder" class="w-4 h-4 inline mr-1" /> Skip empty categories:
          <strong>{if @skip_empty_categories, do: "Yes", else: "No"}</strong>
        </li>
      </ul>
    </div>

    <div class="form-control mb-4">
      <label class="label cursor-pointer justify-start gap-3">
        <input
          type="checkbox"
          class="toggle toggle-sm toggle-primary"
          checked={@skip_empty_categories}
          phx-click="toggle_skip_empty_categories"
        />
        <span class="label-text">
          Skip empty categories (remove categories with no products after import)
        </span>
      </label>
    </div>

    <div class="flex gap-3 mt-6">
      <button type="button" phx-click="back_to_upload" class="btn btn-outline">
        <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
      </button>
      <div class="flex-1"></div>
      <button type="button" phx-click="confirm_import" class="btn btn-primary">
        <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-2" /> Start Import
      </button>
    </div>
    """
  end

  defp render_importing_step(assigns) do
    ~H"""
    <h2 class="card-title text-xl mb-4">
      <.icon name="hero-arrow-path" class="w-6 h-6 animate-spin" /> Import in Progress
    </h2>

    <%= if @current_import do %>
      <div class="alert alert-info">
        <div class="flex-1">
          <h3 class="font-bold">{@current_import.filename}</h3>
          <%= if @import_progress do %>
            <div class="mt-2">
              <progress
                value={@import_progress.percent}
                max="100"
                class="progress progress-primary w-full"
              />
              <p class="text-sm mt-1">
                {@import_progress.current} / {@import_progress.total} products ({@import_progress.percent}%)
              </p>
            </div>
          <% else %>
            <p class="text-sm">Preparing import...</p>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp get_global_option_label(%{"label" => label}) when is_binary(label), do: label

  defp get_global_option_label(%{"label" => label}) when is_map(label),
    do: Map.get(label, "en", "")

  defp get_global_option_label(_), do: ""

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge",
      case @status do
        "pending" -> "badge-neutral"
        "processing" -> "badge-info"
        "completed" -> "badge-success"
        "failed" -> "badge-error"
        _ -> "badge-ghost"
      end
    ]}>
      {@status}
    </span>
    """
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %H:%M")
  end

  defp error_to_string(:too_large), do: "File is too large (max 50MB)"
  defp error_to_string(:not_accepted), do: "Only CSV files are accepted"
  defp error_to_string(:too_many_files), do: "Only one file at a time"
  defp error_to_string(err), do: inspect(err)
end
