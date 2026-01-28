defmodule PhoenixKit.Modules.Shop.Web.ImportShow do
  @moduledoc """
  LiveView for displaying import details.

  Shows:
  - Import metadata (filename, user, dates)
  - Statistics summary (imported/updated/skipped/errors)
  - List of imported products with links to edit
  - Error details (if any)
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case Shop.get_import_log(uuid, preload: [:user]) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Import not found")
         |> push_navigate(to: Routes.path("/admin/shop/imports"))}

      import_log ->
        products = load_products(import_log.product_ids || [])

        socket =
          socket
          |> assign(:page_title, "Import: #{import_log.filename}")
          |> assign(:import, import_log)
          |> assign(:products, products)

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  defp load_products([]), do: []

  defp load_products(product_ids) do
    Shop.list_products_by_ids(product_ids)
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %H:%M")
  end

  defp get_localized(nil), do: "-"
  defp get_localized(value) when is_binary(value), do: value

  defp get_localized(value) when is_map(value) do
    lang = Translations.default_language()
    Map.get(value, lang) || Map.get(value, "en") || Map.values(value) |> List.first() || "-"
  end

  defp format_price(nil), do: "-"
  defp format_price(%Decimal{} = price), do: Decimal.to_string(price)
  defp format_price(price) when is_number(price), do: to_string(price)

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
      <div class="container mx-auto px-4 py-6 max-w-4xl">
        <%!-- Header with back button --%>
        <header class="mb-6 flex items-center gap-4">
          <.link
            navigate={Routes.path("/admin/shop/imports")}
            class="btn btn-outline btn-primary btn-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
          </.link>
          <h1 class="text-2xl font-bold flex-1">Import Details</h1>
          <span class={[
            "badge",
            case @import.status do
              "pending" -> "badge-warning"
              "processing" -> "badge-info"
              "completed" -> "badge-success"
              "failed" -> "badge-error"
              _ -> "badge-ghost"
            end
          ]}>
            {@import.status}
          </span>
        </header>

        <%!-- Metadata card --%>
        <div class="card bg-base-100 shadow mb-6">
          <div class="card-body">
            <h2 class="card-title text-lg mb-4">
              <.icon name="hero-document-text" class="w-5 h-5" /> Import Information
            </h2>
            <dl class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <dt class="text-sm text-base-content/60">Filename</dt>
                <dd class="font-medium">{@import.filename}</dd>
              </div>
              <div>
                <dt class="text-sm text-base-content/60">User</dt>
                <dd class="font-medium">{if @import.user, do: @import.user.email, else: "-"}</dd>
              </div>
              <div>
                <dt class="text-sm text-base-content/60">Started At</dt>
                <dd class="font-medium">{format_datetime(@import.started_at)}</dd>
              </div>
              <div>
                <dt class="text-sm text-base-content/60">Completed At</dt>
                <dd class="font-medium">{format_datetime(@import.completed_at)}</dd>
              </div>
            </dl>
          </div>
        </div>

        <%!-- Statistics --%>
        <div class="stats shadow w-full mb-6">
          <div class="stat">
            <div class="stat-figure text-success">
              <.icon name="hero-plus-circle" class="w-8 h-8" />
            </div>
            <div class="stat-title">Imported</div>
            <div class="stat-value text-success">{@import.imported_count}</div>
            <div class="stat-desc">new products</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-info">
              <.icon name="hero-arrow-path" class="w-8 h-8" />
            </div>
            <div class="stat-title">Updated</div>
            <div class="stat-value text-info">{@import.updated_count}</div>
            <div class="stat-desc">existing products</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-warning">
              <.icon name="hero-minus-circle" class="w-8 h-8" />
            </div>
            <div class="stat-title">Skipped</div>
            <div class="stat-value text-warning">{@import.skipped_count}</div>
            <div class="stat-desc">filtered out</div>
          </div>

          <div class="stat">
            <div class="stat-figure text-error">
              <.icon name="hero-exclamation-circle" class="w-8 h-8" />
            </div>
            <div class="stat-title">Errors</div>
            <div class="stat-value text-error">{@import.error_count}</div>
            <div class="stat-desc">failed rows</div>
          </div>
        </div>

        <%!-- Products list --%>
        <%= if @products != [] do %>
          <div class="card bg-base-100 shadow mb-6">
            <div class="card-body">
              <h2 class="card-title text-lg mb-4">
                <.icon name="hero-cube" class="w-5 h-5" /> Imported Products
                <span class="badge badge-ghost">{length(@products)}</span>
              </h2>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Title</th>
                      <th>Slug</th>
                      <th>Price</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for product <- @products do %>
                      <tr class="hover">
                        <td class="font-medium max-w-[250px] truncate">
                          {get_localized(product.title)}
                        </td>
                        <td class="text-base-content/70 text-sm">
                          {get_localized(product.slug) || "-"}
                        </td>
                        <td>{format_price(product.price)}</td>
                        <td>
                          <div class="flex gap-1">
                            <.link
                              navigate={Routes.path("/admin/shop/products/#{product.id}")}
                              class="btn btn-xs btn-ghost"
                              title="View"
                            >
                              <.icon name="hero-eye" class="w-4 h-4" />
                            </.link>
                            <.link
                              navigate={Routes.path("/admin/shop/products/#{product.id}/edit")}
                              class="btn btn-xs btn-ghost"
                              title="Edit"
                            >
                              <.icon name="hero-pencil" class="w-4 h-4" />
                            </.link>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        <% else %>
          <div class="alert mb-6">
            <.icon name="hero-information-circle" class="w-6 h-6" />
            <span>
              No products tracked for this import. Product tracking was added in a later version.
            </span>
          </div>
        <% end %>

        <%!-- Errors section (if any) --%>
        <%= if @import.error_count > 0 and @import.error_details != [] do %>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg text-error mb-4">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> Errors
                <span class="badge badge-error">{@import.error_count}</span>
              </h2>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Handle</th>
                      <th>Error</th>
                      <th>Time</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for error <- Enum.take(@import.error_details, 50) do %>
                      <tr>
                        <td class="font-mono text-sm">{error["handle"]}</td>
                        <td class="text-error text-sm max-w-[300px] truncate">
                          {error["error"]}
                        </td>
                        <td class="text-xs text-base-content/60">
                          {error["timestamp"]}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
                <%= if length(@import.error_details) > 50 do %>
                  <p class="text-sm text-base-content/60 mt-2">
                    Showing first 50 of {length(@import.error_details)} errors
                  </p>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
