defmodule PhoenixKit.Modules.Shop.Web.ProductDetail do
  @moduledoc """
  Product detail view LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    product = Shop.get_product!(id, preload: [:category])

    socket =
      socket
      |> assign(:page_title, product.title)
      |> assign(:product, product)

    {:ok, socket}
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Shop.delete_product(socket.assigns.product) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Product deleted")
         |> push_navigate(to: Routes.path("/admin/shop/products"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete product")}
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
      <div class="p-6 max-w-4xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div class="flex items-center gap-4">
            <.link navigate={Routes.path("/admin/shop/products")} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="w-5 h-5" />
            </.link>
            <div>
              <h1 class="text-3xl font-bold text-base-content">{@product.title}</h1>
              <p class="text-base-content/60">{@product.slug}</p>
            </div>
          </div>

          <div class="flex gap-2">
            <.link
              navigate={Routes.path("/admin/shop/products/#{@product.id}/edit")}
              class="btn btn-primary"
            >
              <.icon name="hero-pencil" class="w-5 h-5 mr-2" /> Edit
            </.link>
            <button
              phx-click="delete"
              data-confirm="Are you sure you want to delete this product?"
              class="btn btn-error btn-outline"
            >
              <.icon name="hero-trash" class="w-5 h-5" />
            </button>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <%!-- Main Content --%>
          <div class="lg:col-span-2 space-y-6">
            <%!-- Details --%>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <h2 class="card-title">Product Details</h2>

                <%= if @product.description do %>
                  <p class="text-base-content/80">{@product.description}</p>
                <% end %>

                <div class="divider"></div>

                <div class="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <span class="text-base-content/60">Type:</span>
                    <span class="ml-2 font-medium capitalize">{@product.product_type}</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Vendor:</span>
                    <span class="ml-2 font-medium">{@product.vendor || "—"}</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Taxable:</span>
                    <span class="ml-2 font-medium">{if @product.taxable, do: "Yes", else: "No"}</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Weight:</span>
                    <span class="ml-2 font-medium">{@product.weight_grams || 0}g</span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Pricing --%>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <h2 class="card-title">Pricing</h2>

                <div class="grid grid-cols-3 gap-4">
                  <div class="stat p-0">
                    <div class="stat-title">Price</div>
                    <div class="stat-value text-2xl">
                      {format_price(@product.price, @product.currency)}
                    </div>
                  </div>

                  <%= if @product.compare_at_price do %>
                    <div class="stat p-0">
                      <div class="stat-title">Compare At</div>
                      <div class="stat-value text-2xl text-base-content/50 line-through">
                        {format_price(@product.compare_at_price, @product.currency)}
                      </div>
                    </div>
                  <% end %>

                  <%= if @product.cost_per_item do %>
                    <div class="stat p-0">
                      <div class="stat-title">Cost</div>
                      <div class="stat-value text-2xl text-base-content/70">
                        {format_price(@product.cost_per_item, @product.currency)}
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>

          <%!-- Sidebar --%>
          <div class="space-y-6">
            <%!-- Status --%>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <h2 class="card-title">Status</h2>
                <div class="flex items-center gap-2">
                  <span class={status_badge_class(@product.status)}>
                    {String.capitalize(@product.status)}
                  </span>
                </div>
              </div>
            </div>

            <%!-- Category --%>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <h2 class="card-title">Category</h2>
                <%= if @product.category do %>
                  <span class="badge badge-lg">{@product.category.name}</span>
                <% else %>
                  <span class="text-base-content/50">No category</span>
                <% end %>
              </div>
            </div>

            <%!-- Timestamps --%>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body text-sm">
                <h2 class="card-title">Timestamps</h2>
                <div class="space-y-2 text-base-content/70">
                  <div>
                    <span>Created:</span>
                    <span class="ml-2">
                      {Calendar.strftime(@product.inserted_at, "%Y-%m-%d %H:%M")}
                    </span>
                  </div>
                  <div>
                    <span>Updated:</span>
                    <span class="ml-2">
                      {Calendar.strftime(@product.updated_at, "%Y-%m-%d %H:%M")}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp status_badge_class("active"), do: "badge badge-success badge-lg"
  defp status_badge_class("draft"), do: "badge badge-warning badge-lg"
  defp status_badge_class("archived"), do: "badge badge-neutral badge-lg"
  defp status_badge_class(_), do: "badge badge-lg"

  defp format_price(nil, _currency), do: "—"

  defp format_price(price, currency) do
    symbol =
      case currency do
        "USD" -> "$"
        "EUR" -> "€"
        "GBP" -> "£"
        "JPY" -> "¥"
        "RUB" -> "₽"
        _ -> currency <> " "
      end

    "#{symbol}#{Decimal.round(price, 2)}"
  end
end
