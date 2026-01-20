defmodule PhoenixKit.Modules.Shop.Web.Products do
  @moduledoc """
  Products list LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {products, total} = Shop.list_products_with_count(per_page: @per_page, preload: [:category])
    currency = Shop.get_default_currency()

    socket =
      socket
      |> assign(:page_title, "Products")
      |> assign(:products, products)
      |> assign(:total, total)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:search, "")
      |> assign(:status_filter, nil)
      |> assign(:type_filter, nil)
      |> assign(:currency, currency)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = (params["page"] || "1") |> String.to_integer()
    search = params["search"] || ""
    status = params["status"]
    type = params["type"]

    opts = [
      page: page,
      per_page: @per_page,
      search: search,
      status: status,
      product_type: type,
      preload: [:category]
    ]

    {products, total} = Shop.list_products_with_count(opts)

    socket =
      socket
      |> assign(:products, products)
      |> assign(:total, total)
      |> assign(:page, page)
      |> assign(:search, search)
      |> assign(:status_filter, status)
      |> assign(:type_filter, type)

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_params(socket.assigns, search: search, page: 1)
    {:noreply, push_patch(socket, to: Routes.path("/admin/shop/products?#{params}"))}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    params = build_params(socket.assigns, status: status, page: 1)
    {:noreply, push_patch(socket, to: Routes.path("/admin/shop/products?#{params}"))}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    type = if type == "", do: nil, else: type
    params = build_params(socket.assigns, type: type, page: 1)
    {:noreply, push_patch(socket, to: Routes.path("/admin/shop/products?#{params}"))}
  end

  @impl true
  def handle_event("view_product", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/shop/products/#{id}"))}
  end

  @impl true
  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_product", %{"id" => id}, socket) do
    product = Shop.get_product!(id)

    case Shop.delete_product(product) do
      {:ok, _} ->
        {products, total} =
          Shop.list_products_with_count(
            page: socket.assigns.page,
            per_page: @per_page,
            preload: [:category]
          )

        {:noreply,
         socket
         |> assign(:products, products)
         |> assign(:total, total)
         |> put_flash(:info, "Product deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete product")}
    end
  end

  defp build_params(assigns, overrides) do
    %{
      search: Keyword.get(overrides, :search, assigns.search),
      status: Keyword.get(overrides, :status, assigns.status_filter),
      type: Keyword.get(overrides, :type, assigns.type_filter),
      page: Keyword.get(overrides, :page, assigns.page)
    }
    |> Enum.filter(fn {_k, v} -> v && v != "" end)
    |> URI.encode_query()
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
      <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
        <%!-- Header (centered pattern) --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={Routes.path("/admin/shop")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
          </.link>
          <div class="text-center pt-10 sm:pt-0">
            <h1 class="text-4xl font-bold text-base-content mb-3">Products</h1>
            <p class="text-lg text-base-content/70">
              {if @total == 1, do: "1 product", else: "#{@total} products"}
            </p>
          </div>
        </header>

        <%!-- Controls Bar (Users pattern) --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="flex flex-col lg:flex-row gap-4">
            <%!-- Search --%>
            <div class="flex-1">
              <label class="label"><span class="label-text">Search</span></label>
              <form phx-submit="search" phx-change="search">
                <input
                  type="text"
                  name="search"
                  value={@search}
                  placeholder="Search products..."
                  class="input input-bordered w-full focus:input-primary"
                  phx-debounce="300"
                />
              </form>
            </div>

            <%!-- Status Filter --%>
            <div class="w-full lg:w-48">
              <label class="label"><span class="label-text">Status</span></label>
              <select
                class="select select-bordered w-full focus:select-primary"
                phx-change="filter_status"
                name="status"
              >
                <option value="" selected={is_nil(@status_filter)}>All Status</option>
                <option value="active" selected={@status_filter == "active"}>Active</option>
                <option value="draft" selected={@status_filter == "draft"}>Draft</option>
                <option value="archived" selected={@status_filter == "archived"}>Archived</option>
              </select>
            </div>

            <%!-- Type Filter --%>
            <div class="w-full lg:w-48">
              <label class="label"><span class="label-text">Type</span></label>
              <select
                class="select select-bordered w-full focus:select-primary"
                phx-change="filter_type"
                name="type"
              >
                <option value="" selected={is_nil(@type_filter)}>All Types</option>
                <option value="physical" selected={@type_filter == "physical"}>Physical</option>
                <option value="digital" selected={@type_filter == "digital"}>Digital</option>
              </select>
            </div>

            <%!-- Actions --%>
            <div class="w-full lg:w-auto">
              <label class="label"><span class="label-text">Actions</span></label>
              <.link navigate={Routes.path("/admin/shop/products/new")} class="btn btn-primary">
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Product
              </.link>
            </div>
          </div>
        </div>

        <%!-- Products Table --%>
        <div class="card bg-base-100 shadow-xl overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Status</th>
                  <th>Type</th>
                  <th>Category</th>
                  <th class="text-right">Price</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if Enum.empty?(@products) do %>
                  <tr>
                    <td colspan="6" class="text-center py-12 text-base-content/50">
                      <.icon name="hero-cube" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                      <p class="text-lg">No products found</p>
                      <p class="text-sm">Create your first product to get started</p>
                    </td>
                  </tr>
                <% else %>
                  <%= for product <- @products do %>
                    <tr
                      class="hover cursor-pointer"
                      phx-click="view_product"
                      phx-value-id={product.id}
                    >
                      <td>
                        <div class="flex items-center gap-3">
                          <div class="avatar placeholder">
                            <div class="bg-base-300 text-base-content/50 w-12 h-12 rounded">
                              <%= if product.featured_image do %>
                                <img src={product.featured_image} alt={product.title} />
                              <% else %>
                                <.icon name="hero-cube" class="w-6 h-6" />
                              <% end %>
                            </div>
                          </div>
                          <div>
                            <div class="font-bold">{product.title}</div>
                            <div class="text-sm text-base-content/60">{product.slug}</div>
                          </div>
                        </div>
                      </td>
                      <td>
                        <span class={status_badge_class(product.status)}>
                          {product.status}
                        </span>
                      </td>
                      <td>
                        <span class={type_badge_class(product.product_type)}>
                          {product.product_type}
                        </span>
                      </td>
                      <td>
                        <%= if product.category do %>
                          <span class="badge badge-ghost">{product.category.name}</span>
                        <% else %>
                          <span class="text-base-content/40">—</span>
                        <% end %>
                      </td>
                      <td class="text-right font-mono">
                        {format_price(product.price, @currency)}
                      </td>
                      <td class="text-right" phx-click="noop">
                        <div class="flex flex-wrap gap-1 justify-end">
                          <.link
                            navigate={Routes.path("/admin/shop/products/#{product.id}")}
                            class="btn btn-xs btn-outline btn-info"
                          >
                            <.icon name="hero-eye" class="h-4 w-4" />
                          </.link>
                          <.link
                            navigate={Routes.path("/admin/shop/products/#{product.id}/edit")}
                            class="btn btn-xs btn-outline btn-secondary"
                          >
                            <.icon name="hero-pencil" class="h-4 w-4" />
                          </.link>
                          <button
                            phx-click="delete_product"
                            phx-value-id={product.id}
                            data-confirm="Delete this product?"
                            class="btn btn-xs btn-outline btn-error"
                          >
                            <.icon name="hero-trash" class="h-4 w-4" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>

          <%!-- Pagination --%>
          <%= if @total > @per_page do %>
            <div class="card-body border-t">
              <div class="flex justify-center">
                <div class="join">
                  <%= for page <- 1..ceil(@total / @per_page) do %>
                    <.link
                      patch={Routes.path("/admin/shop/products?page=#{page}")}
                      class={["join-item btn btn-sm", if(@page == page, do: "btn-active", else: "")]}
                    >
                      {page}
                    </.link>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp status_badge_class("active"), do: "badge badge-success"
  defp status_badge_class("draft"), do: "badge badge-warning"
  defp status_badge_class("archived"), do: "badge badge-neutral"
  defp status_badge_class(_), do: "badge"

  defp type_badge_class("physical"), do: "badge badge-info badge-outline"
  defp type_badge_class("digital"), do: "badge badge-secondary badge-outline"
  defp type_badge_class(_), do: "badge badge-outline"

  defp format_price(nil, _currency), do: "—"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    # Fallback if no currency configured
    "$#{Decimal.round(price, 2)}"
  end
end
