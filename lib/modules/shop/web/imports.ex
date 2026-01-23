defmodule PhoenixKit.Modules.Shop.Web.Imports do
  @moduledoc """
  Admin LiveView for managing Shopify CSV imports.

  Features:
  - File upload with drag-and-drop
  - Import history table with statistics
  - Real-time progress tracking via PubSub
  - Retry failed imports
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.ImportLog
  alias PhoenixKit.Modules.Shop.Workers.CSVImportWorker
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Utils.Routes

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to import updates
      Manager.subscribe("shop:imports")
    end

    socket =
      socket
      |> assign(:page_title, "CSV Import")
      |> assign(:imports, list_imports())
      |> assign(:current_import, nil)
      |> assign(:import_progress, nil)
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
    user = socket.assigns.phoenix_kit_current_scope.user

    # Consume uploaded file
    case consume_uploaded_entries(socket, :csv_file, fn %{path: path}, entry ->
           # Copy to persistent location
           dest_dir = Path.join(System.tmp_dir!(), "shop_imports")
           File.mkdir_p!(dest_dir)

           dest_path =
             Path.join(dest_dir, "#{System.system_time(:millisecond)}_#{entry.client_name}")

           File.cp!(path, dest_path)
           {:ok, {dest_path, entry.client_name}}
         end) do
      [{dest_path, filename}] ->
        # Create import log
        case Shop.create_import_log(%{
               filename: filename,
               file_path: dest_path,
               user_id: user.id,
               options: %{}
             }) do
          {:ok, import_log} ->
            # Enqueue Oban job
            %{import_log_id: import_log.id, path: dest_path}
            |> CSVImportWorker.new()
            |> Oban.insert()

            # Subscribe to this specific import
            Manager.subscribe("shop:import:#{import_log.id}")

            socket =
              socket
              |> assign(:current_import, import_log)
              |> assign(:import_progress, %{percent: 0, current: 0, total: 0})
              |> assign(:imports, list_imports())
              |> put_flash(:info, "Import started: #{filename}")

            {:noreply, socket}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to create import log")}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "Please select a CSV file first")}
    end
  end

  @impl true
  def handle_event("retry_import", %{"id" => id}, socket) do
    case Shop.get_import_log(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Import not found")}

      import_log ->
        if import_log.status == "failed" && import_log.file_path &&
             File.exists?(import_log.file_path) do
          # Reset import log status
          {:ok, updated_log} =
            Shop.update_import_log(import_log, %{status: "pending", error_details: []})

          # Re-enqueue job
          %{import_log_id: updated_log.id, path: import_log.file_path}
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

  @impl true
  def handle_event("delete_import", %{"id" => id}, socket) do
    case Shop.get_import_log(id) do
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
      |> assign(:imports, list_imports())
      |> put_flash(:error, "Import failed: #{reason}")

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
              <p class="text-base-content/70 mt-1">Import products from Shopify CSV files</p>
            </div>
          </div>
        </header>

        <%!-- Upload Card --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-4">
              <.icon name="hero-cloud-arrow-up" class="w-6 h-6" /> Upload CSV File
            </h2>

            <%= if @current_import do %>
              <%!-- Import in Progress --%>
              <div class="alert alert-info">
                <.icon name="hero-arrow-path" class="w-6 h-6 animate-spin" />
                <div class="flex-1">
                  <h3 class="font-bold">Import in Progress</h3>
                  <p class="text-sm">{@current_import.filename}</p>
                  <%= if @import_progress do %>
                    <div class="mt-2">
                      <progress
                        value={@import_progress.percent}
                        max="100"
                        class="progress progress-primary w-full"
                      />
                      <p class="text-xs mt-1">
                        {@import_progress.current} / {@import_progress.total} products ({@import_progress.percent}%)
                      </p>
                    </div>
                  <% end %>
                </div>
              </div>
            <% else %>
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
                          Shopify products_export.csv format, max 50MB
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

                <%!-- Start Import Button --%>
                <%= if length(@uploads.csv_file.entries) > 0 do %>
                  <% entry = List.first(@uploads.csv_file.entries) %>
                  <%= if entry.done? do %>
                    <button type="submit" class="btn btn-primary btn-block mt-4">
                      <.icon name="hero-arrow-down-tray" class="w-5 h-5 mr-2" /> Start Import
                    </button>
                  <% end %>
                <% end %>
              </form>
            <% end %>
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
                          {import.filename}
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
              <li>Only 3D printed products are imported (decals and other items are filtered)</li>
              <li>Products are automatically categorized based on title</li>
              <li>Existing products with the same handle are updated</li>
              <li>Import runs in the background - you can leave this page</li>
            </ul>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

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
