defmodule PhoenixKit.Modules.Shop.Web.Products do
  @moduledoc """
  Products list LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Events
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_products()
      Events.subscribe_inventory()
    end

    {products, total} = Shop.list_products_with_count(per_page: @per_page, preload: [:category])
    currency = Shop.get_default_currency()
    categories = Shop.list_categories()

    # Get current language for admin (use default language)
    current_language = Translations.default_language()

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
      |> assign(:category_filter, nil)
      |> assign(:categories, categories)
      |> assign(:currency, currency)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:show_bulk_modal, nil)
      |> assign(:current_language, current_language)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = (params["page"] || "1") |> String.to_integer()
    search = params["search"] || ""
    status = if params["status"] in ["", nil], do: nil, else: params["status"]
    type = if params["type"] in ["", nil], do: nil, else: params["type"]
    category_id = parse_category_id(params["category"])

    opts = [
      page: page,
      per_page: @per_page,
      search: search,
      status: status,
      product_type: type,
      category_id: category_id,
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
      |> assign(:category_filter, category_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> assign(:page, 1)
      |> load_products()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status

    socket =
      socket
      |> assign(:status_filter, status)
      |> assign(:page, 1)
      |> load_products()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    type = if type == "", do: nil, else: type

    socket =
      socket
      |> assign(:type_filter, type)
      |> assign(:page, 1)
      |> load_products()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    category_id = parse_category_id(category)

    socket =
      socket
      |> assign(:category_filter, category_id)
      |> assign(:page, 1)
      |> load_products()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_products()

    {:noreply, socket}
  end

  @impl true
  def handle_event("view_product", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/shop/products/#{uuid}"))}
  end

  @impl true
  def handle_event("delete_product", %{"uuid" => uuid}, socket) do
    product = Shop.get_product!(uuid)

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

  # Bulk selection events
  @impl true
  def handle_event("toggle_select", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.selected_ids

    selected =
      if MapSet.member?(selected, uuid) do
        MapSet.delete(selected, uuid)
      else
        MapSet.put(selected, uuid)
      end

    {:noreply, assign(socket, :selected_ids, selected)}
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    all_uuids = Enum.map(socket.assigns.products, & &1.uuid) |> MapSet.new()
    current = socket.assigns.selected_ids

    selected =
      if MapSet.subset?(all_uuids, current) do
        MapSet.difference(current, all_uuids)
      else
        MapSet.union(current, all_uuids)
      end

    {:noreply, assign(socket, :selected_ids, selected)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  # Bulk action modals
  @impl true
  def handle_event("show_bulk_modal", %{"action" => action}, socket) do
    {:noreply, assign(socket, :show_bulk_modal, action)}
  end

  @impl true
  def handle_event("close_bulk_modal", _params, socket) do
    {:noreply, assign(socket, :show_bulk_modal, nil)}
  end

  # Bulk actions
  @impl true
  def handle_event("bulk_change_status", %{"status" => status}, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)
    count = Shop.bulk_update_product_status(ids, status)

    socket = load_products(socket)

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:show_bulk_modal, nil)
     |> put_flash(:info, "#{count} products updated to #{status}")}
  end

  @impl true
  def handle_event("bulk_change_category", %{"category_id" => category_id}, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)
    category_id = if category_id == "", do: nil, else: category_id
    count = Shop.bulk_update_product_category(ids, category_id)

    socket = load_products(socket)

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:show_bulk_modal, nil)
     |> put_flash(:info, "#{count} products moved")}
  end

  @impl true
  def handle_event("bulk_delete", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)
    count = Shop.bulk_delete_products(ids)

    socket = load_products(socket)

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:show_bulk_modal, nil)
     |> put_flash(:info, "#{count} products deleted")}
  end

  defp load_products(socket) do
    {products, total} =
      Shop.list_products_with_count(
        page: socket.assigns.page,
        per_page: @per_page,
        search: socket.assigns.search,
        status: socket.assigns.status_filter,
        product_type: socket.assigns.type_filter,
        category_id: socket.assigns.category_filter,
        preload: [:category]
      )

    socket
    |> assign(:products, products)
    |> assign(:total, total)
  end

  # PubSub event handlers
  @impl true
  def handle_info({:product_created, _product}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:product_updated, _product}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:product_deleted, _product_id}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:products_bulk_status_changed, _ids, _status}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:inventory_updated, _product_id, _change}, socket) do
    {:noreply, load_products(socket)}
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
              <h1 class="text-3xl font-bold text-base-content">Products</h1>
              <p class="text-base-content/70 mt-1">
                {if @total == 1, do: "1 product", else: "#{@total} products"}
              </p>
            </div>
          </div>
        </header>

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-6 gap-4 items-end">
            <%!-- Search --%>
            <div class="lg:col-span-2">
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
            <div>
              <label class="label"><span class="label-text">Status</span></label>
              <form phx-change="filter_status">
                <select class="select select-bordered w-full focus:select-primary" name="status">
                  <option value="" selected={is_nil(@status_filter)}>All Status</option>
                  <option value="active" selected={@status_filter == "active"}>Active</option>
                  <option value="draft" selected={@status_filter == "draft"}>Draft</option>
                  <option value="archived" selected={@status_filter == "archived"}>Archived</option>
                </select>
              </form>
            </div>

            <%!-- Type Filter --%>
            <div>
              <label class="label"><span class="label-text">Type</span></label>
              <form phx-change="filter_type">
                <select class="select select-bordered w-full focus:select-primary" name="type">
                  <option value="" selected={is_nil(@type_filter)}>All Types</option>
                  <option value="physical" selected={@type_filter == "physical"}>Physical</option>
                  <option value="digital" selected={@type_filter == "digital"}>Digital</option>
                </select>
              </form>
            </div>

            <%!-- Category Filter --%>
            <div>
              <label class="label"><span class="label-text">Category</span></label>
              <form phx-change="filter_category">
                <select class="select select-bordered w-full focus:select-primary" name="category">
                  <option value="" selected={is_nil(@category_filter)}>All Categories</option>
                  <%= for category <- @categories do %>
                    <option value={category.uuid} selected={@category_filter == category.uuid}>
                      {Translations.get(category, :name, @current_language)}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>

            <%!-- Add Button --%>
            <div>
              <label class="label"><span class="label-text">&nbsp;</span></label>
              <.link
                navigate={Routes.path("/admin/shop/products/new")}
                class="btn btn-primary w-full"
              >
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Product
              </.link>
            </div>
          </div>
        </div>

        <%!-- Bulk Actions Bar --%>
        <%= if MapSet.size(@selected_ids) > 0 do %>
          <div class="bg-primary/10 border border-primary/30 rounded-lg p-4 mb-6">
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="flex items-center gap-2">
                <span class="badge badge-primary badge-lg">
                  {MapSet.size(@selected_ids)} selected
                </span>
                <button phx-click="clear_selection" class="btn btn-ghost btn-sm">
                  Clear selection
                </button>
              </div>
              <div class="flex flex-wrap gap-2">
                <button
                  phx-click="show_bulk_modal"
                  phx-value-action="status"
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Change Status
                </button>
                <button
                  phx-click="show_bulk_modal"
                  phx-value-action="category"
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-folder" class="w-4 h-4 mr-1" /> Move to Category
                </button>
                <button
                  phx-click="show_bulk_modal"
                  phx-value-action="delete"
                  class="btn btn-sm btn-outline btn-error"
                >
                  <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Delete
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Products Table --%>
        <div class="card bg-base-100 shadow-xl overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th class="w-12">
                    <label class="cursor-pointer">
                      <input
                        type="checkbox"
                        class="checkbox checkbox-sm"
                        phx-click="select_all"
                        checked={all_selected?(@products, @selected_ids)}
                      />
                    </label>
                  </th>
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
                    <td colspan="7" class="text-center py-12 text-base-content/50">
                      <.icon name="hero-cube" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                      <p class="text-lg">No products found</p>
                      <p class="text-sm">Create your first product to get started</p>
                    </td>
                  </tr>
                <% else %>
                  <%= for product <- @products do %>
                    <tr class={[
                      "hover",
                      if(MapSet.member?(@selected_ids, product.uuid), do: "bg-primary/5", else: "")
                    ]}>
                      <td>
                        <label class="cursor-pointer">
                          <input
                            type="checkbox"
                            class="checkbox checkbox-sm"
                            phx-click="toggle_select"
                            phx-value-uuid={product.uuid}
                            checked={MapSet.member?(@selected_ids, product.uuid)}
                          />
                        </label>
                      </td>
                      <td
                        class="cursor-pointer"
                        phx-click="view_product"
                        phx-value-uuid={product.uuid}
                      >
                        <div class="flex items-center gap-3">
                          <% product_title = Translations.get(product, :title, @current_language) %>
                          <% product_slug = Translations.get(product, :slug, @current_language) %>
                          <div class="avatar placeholder">
                            <div class="bg-base-300 text-base-content/50 w-12 h-12 rounded">
                              <%= if thumb_url = get_product_thumbnail(product) do %>
                                <img src={thumb_url} alt={product_title} />
                              <% else %>
                                <.icon name="hero-cube" class="w-6 h-6" />
                              <% end %>
                            </div>
                          </div>
                          <div>
                            <div class="font-bold">{product_title}</div>
                            <div class="text-sm text-base-content/60">{product_slug}</div>
                          </div>
                        </div>
                      </td>
                      <td
                        class="cursor-pointer"
                        phx-click="view_product"
                        phx-value-uuid={product.uuid}
                      >
                        <span class={status_badge_class(product.status)}>
                          {product.status}
                        </span>
                      </td>
                      <td
                        class="cursor-pointer"
                        phx-click="view_product"
                        phx-value-uuid={product.uuid}
                      >
                        <span class={type_badge_class(product.product_type)}>
                          {product.product_type}
                        </span>
                      </td>
                      <td
                        class="cursor-pointer"
                        phx-click="view_product"
                        phx-value-uuid={product.uuid}
                      >
                        <%= if product.category do %>
                          <span class="badge badge-ghost">
                            {Translations.get(product.category, :name, @current_language)}
                          </span>
                        <% else %>
                          <span class="text-base-content/40">—</span>
                        <% end %>
                      </td>
                      <td
                        class="text-right font-mono cursor-pointer"
                        phx-click="view_product"
                        phx-value-uuid={product.uuid}
                      >
                        {format_price(product.price, @currency)}
                      </td>
                      <td class="text-right">
                        <div class="flex flex-wrap gap-1 justify-end">
                          <.link
                            navigate={Routes.path("/admin/shop/products/#{product.uuid}")}
                            class="btn btn-xs btn-outline btn-info"
                          >
                            <.icon name="hero-eye" class="h-4 w-4" />
                          </.link>
                          <.link
                            navigate={Routes.path("/admin/shop/products/#{product.uuid}/edit")}
                            class="btn btn-xs btn-outline btn-secondary"
                          >
                            <.icon name="hero-pencil" class="h-4 w-4" />
                          </.link>
                          <button
                            phx-click="delete_product"
                            phx-value-uuid={product.uuid}
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
                    <button
                      phx-click="change_page"
                      phx-value-page={page}
                      class={["join-item btn btn-sm", if(@page == page, do: "btn-active", else: "")]}
                    >
                      {page}
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Bulk Status Change Modal --%>
      <%= if @show_bulk_modal == "status" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Change Status</h3>
            <p class="text-base-content/70 mb-4">
              Update status for {MapSet.size(@selected_ids)} selected products
            </p>
            <div class="flex flex-col gap-2">
              <button
                phx-click="bulk_change_status"
                phx-value-status="active"
                class="btn btn-success btn-outline justify-start"
              >
                <.icon name="hero-check-circle" class="w-5 h-5 mr-2" /> Set Active
              </button>
              <button
                phx-click="bulk_change_status"
                phx-value-status="draft"
                class="btn btn-warning btn-outline justify-start"
              >
                <.icon name="hero-pencil-square" class="w-5 h-5 mr-2" /> Set Draft
              </button>
              <button
                phx-click="bulk_change_status"
                phx-value-status="archived"
                class="btn btn-neutral btn-outline justify-start"
              >
                <.icon name="hero-archive-box" class="w-5 h-5 mr-2" /> Set Archived
              </button>
            </div>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">Cancel</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>

      <%!-- Bulk Category Change Modal --%>
      <%= if @show_bulk_modal == "category" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Move to Category</h3>
            <p class="text-base-content/70 mb-4">
              Move {MapSet.size(@selected_ids)} selected products to a category
            </p>
            <div class="flex flex-col gap-2">
              <button
                phx-click="bulk_change_category"
                phx-value-category_id=""
                class="btn btn-ghost justify-start"
              >
                <.icon name="hero-x-mark" class="w-5 h-5 mr-2" /> No Category
              </button>
              <%= for category <- @categories do %>
                <button
                  phx-click="bulk_change_category"
                  phx-value-category_id={category.uuid}
                  class="btn btn-outline justify-start"
                >
                  <.icon name="hero-folder" class="w-5 h-5 mr-2" /> {Translations.get(
                    category,
                    :name,
                    @current_language
                  )}
                </button>
              <% end %>
            </div>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">Cancel</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>

      <%!-- Bulk Delete Confirmation Modal --%>
      <%= if @show_bulk_modal == "delete" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg text-error mb-4">Delete Products</h3>
            <p class="text-base-content/70 mb-4">
              Are you sure you want to delete {MapSet.size(@selected_ids)} products?
              This action cannot be undone.
            </p>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">Cancel</button>
              <button phx-click="bulk_delete" class="btn btn-error">
                <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete Products
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp all_selected?(products, selected_ids) do
    products != [] and
      Enum.all?(products, fn p -> MapSet.member?(selected_ids, p.uuid) end)
  end

  defp parse_category_id(nil), do: nil
  defp parse_category_id(""), do: nil
  defp parse_category_id(id) when is_binary(id), do: id

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

  # Get product thumbnail - prefers Storage images over legacy URLs
  defp get_product_thumbnail(%{featured_image_id: id}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  defp get_product_thumbnail(%{image_ids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  defp get_product_thumbnail(%{featured_image: url}) when is_binary(url) and url != "" do
    url
  end

  defp get_product_thumbnail(%{images: [%{"src" => src} | _]}), do: src
  defp get_product_thumbnail(%{images: [first | _]}) when is_binary(first), do: first
  defp get_product_thumbnail(_), do: nil

  defp get_storage_image_url(file_id, variant) do
    case Storage.get_file(file_id) do
      %{id: id} ->
        case Storage.get_file_instance_by_name(id, variant) do
          nil ->
            case Storage.get_file_instance_by_name(id, "original") do
              nil -> nil
              _instance -> URLSigner.signed_url(file_id, "original")
            end

          _instance ->
            URLSigner.signed_url(file_id, variant)
        end

      nil ->
        nil
    end
  end
end
