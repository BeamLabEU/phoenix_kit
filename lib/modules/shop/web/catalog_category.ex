defmodule PhoenixKit.Modules.Shop.Web.CatalogCategory do
  @moduledoc """
  Public shop category page.
  Shows products filtered by category.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.SlugResolver
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Web.Components.CatalogSidebar
  alias PhoenixKit.Modules.Shop.Web.Components.FilterHelpers
  alias PhoenixKit.Modules.Shop.Web.Components.ShopCards
  alias PhoenixKit.Modules.Shop.Web.Components.ShopLayouts
  alias PhoenixKit.Modules.Shop.Web.Helpers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    # Determine language: use URL locale param if present, otherwise default
    # This ensures /shop/... always uses default language, not session
    current_language = Helpers.get_language_from_params_or_default(params)

    case Shop.get_category_by_slug_localized(slug, current_language, preload: [:parent]) do
      {:error, :not_found} ->
        # Slug not found in current language - try cross-language lookup
        handle_cross_language_redirect(slug, current_language, socket)

      # Redirect if category is hidden (products not visible)
      {:ok, %{status: "hidden"}} ->
        {:ok,
         socket
         |> put_flash(:error, "Category not found")
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, category} ->
        per_page = 24
        page = Helpers.parse_page(params["page"])

        # Load storefront filters
        {enabled_filters, filter_values} =
          FilterHelpers.load_filter_data(category_uuid: category.uuid)

        active_filters = FilterHelpers.parse_filter_params(params, enabled_filters)
        filter_opts = FilterHelpers.build_query_opts(active_filters, enabled_filters)

        {products, total} =
          Shop.list_products_with_count(
            [
              status: "active",
              category_id: category.uuid,
              page: 1,
              per_page: page * per_page,
              preload: [:category]
            ] ++ filter_opts
          )

        total_pages = max(1, ceil(total / per_page))
        page = min(page, total_pages)

        currency = Shop.get_default_currency()
        all_categories = Shop.list_active_categories(preload: [:featured_product])

        # Check if user is authenticated
        authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

        # Get localized category content
        localized_name = Translations.get(category, :name, current_language)
        localized_description = Translations.get(category, :description, current_language)

        # Get current path for language switcher
        current_path =
          socket.assigns[:url_path] ||
            "/shop/category/#{Translations.get(category, :slug, current_language)}"

        socket =
          socket
          |> assign(:page_title, localized_name)
          |> assign(:category, category)
          |> assign(:current_language, current_language)
          |> assign(:localized_name, localized_name)
          |> assign(:localized_description, localized_description)
          |> assign(:products, products)
          |> assign(:total_products, total)
          |> assign(:page, page)
          |> assign(:per_page, per_page)
          |> assign(:total_pages, total_pages)
          |> assign(:categories, all_categories)
          |> assign(:currency, currency)
          |> assign(:authenticated, authenticated)
          |> assign(:current_path, current_path)
          |> assign(:enabled_filters, enabled_filters)
          |> assign(:filter_values, filter_values)
          |> assign(:active_filters, active_filters)
          |> assign(:filter_qs, FilterHelpers.build_query_string(active_filters, enabled_filters))
          |> assign(:show_mobile_filters, false)
          |> assign(
            :category_name_wrap,
            Settings.get_setting_cached("shop_category_name_display", "truncate") == "wrap"
          )
          |> assign(
            :category_icon_mode,
            Settings.get_setting_cached("shop_category_icon_mode", "none")
          )
          |> assign(:admin_edit_url, Routes.path("/admin/shop/categories/#{category.uuid}/edit"))
          |> assign(:admin_edit_label, "Edit Category")

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = Helpers.parse_page(params["page"])
    active_filters = FilterHelpers.parse_filter_params(params, socket.assigns.enabled_filters)
    filter_opts = FilterHelpers.build_query_opts(active_filters, socket.assigns.enabled_filters)

    # Reload products if filters or page changed
    filters_changed = active_filters != socket.assigns.active_filters
    page = min(page, max(1, socket.assigns.total_pages))

    if filters_changed || page != socket.assigns.page do
      # Reset to page 1 when filters change
      effective_page = if filters_changed, do: 1, else: page

      {products, total} =
        Shop.list_products_with_count(
          [
            status: "active",
            category_id: socket.assigns.category.uuid,
            page: 1,
            per_page: effective_page * socket.assigns.per_page,
            preload: [:category]
          ] ++ filter_opts
        )

      total_pages = max(1, ceil(total / socket.assigns.per_page))

      {:noreply,
       socket
       |> assign(:page, min(effective_page, total_pages))
       |> assign(:products, products)
       |> assign(:total_products, total)
       |> assign(:total_pages, total_pages)
       |> assign(:active_filters, active_filters)
       |> assign(
         :filter_qs,
         FilterHelpers.build_query_string(active_filters, socket.assigns.enabled_filters)
       )}
    else
      {:noreply, socket}
    end
  end

  # Handle cross-language slug redirect
  # When user visits with a slug from a different language, redirect to correct localized URL
  defp handle_cross_language_redirect(slug, current_language, socket) do
    case Shop.get_category_by_any_slug(slug, preload: [:parent]) do
      {:error, :not_found} ->
        # Category truly not found
        {:ok,
         socket
         |> put_flash(:error, "Category not found")
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, %{status: "hidden"}, _matched_lang} ->
        # Category is hidden
        {:ok,
         socket
         |> put_flash(:error, "Category not found")
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, category, _matched_lang} ->
        # Found category - redirect to best enabled language that has a slug
        case Helpers.best_redirect_language(category.slug || %{}) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Category not found")
             |> push_navigate(to: Shop.catalog_url(current_language))}

          redirect_lang ->
            slug = SlugResolver.category_slug(category, redirect_lang)

            {:ok,
             push_navigate(socket,
               to: Helpers.build_lang_url("/shop/category/#{slug}", redirect_lang)
             )}
        end
    end
  end

  @impl true
  def handle_event("filter_price", params, socket) do
    filter_key = params["filter_key"] || "price"

    active_filters =
      FilterHelpers.update_price_filter(
        socket.assigns.active_filters,
        filter_key,
        params["price_min"],
        params["price_max"]
      )

    path = build_filter_path(socket.assigns, active_filters)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_filter", %{"key" => key, "val" => value}, socket) do
    active_filters = FilterHelpers.toggle_filter_value(socket.assigns.active_filters, key, value)
    path = build_filter_path(socket.assigns, active_filters)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    base_path = Shop.category_url(socket.assigns.category, socket.assigns.current_language)
    {:noreply, push_patch(socket, to: base_path)}
  end

  @impl true
  def handle_event("toggle_mobile_filters", _params, socket) do
    {:noreply, assign(socket, :show_mobile_filters, !socket.assigns.show_mobile_filters)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    path = build_filter_path(socket.assigns, socket.assigns.active_filters, page: next_page)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    assigns =
      if assigns.authenticated do
        assign(assigns, :sidebar_after_shop, shop_sidebar(assigns))
      else
        assigns
      end

    ~H"""
    <ShopLayouts.shop_layout {assigns} show_sidebar={true}>
      <div class="p-6 max-w-7xl mx-auto">
        <%!-- Breadcrumbs --%>
        <div class="breadcrumbs text-sm mb-6">
          <ul>
            <li><.link navigate={Shop.catalog_url(@current_language) <> @filter_qs}>Shop</.link></li>
            <%= if @category.parent do %>
              <% parent_name = Translations.get(@category.parent, :name, @current_language) %>
              <li>
                <.link navigate={Shop.category_url(@category.parent, @current_language) <> @filter_qs}>
                  {parent_name}
                </.link>
              </li>
            <% end %>
            <li class="font-medium">{@localized_name}</li>
          </ul>
        </div>

        <%!-- Mobile filter toggle --%>
        <div class="lg:hidden mb-4">
          <button phx-click="toggle_mobile_filters" class="btn btn-outline btn-sm gap-2">
            <.icon name="hero-funnel" class="w-4 h-4" />
            Filters <% filter_count = FilterHelpers.active_filter_count(@active_filters) %>
            <%= if filter_count > 0 do %>
              <span class="badge badge-primary badge-xs">{filter_count}</span>
            <% end %>
          </button>
        </div>

        <%!-- Mobile filter drawer --%>
        <%= if @show_mobile_filters do %>
          <div class="lg:hidden mb-6">
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body p-4">
                <CatalogSidebar.catalog_sidebar
                  filters={@enabled_filters}
                  filter_values={@filter_values}
                  active_filters={@active_filters}
                  categories={@categories}
                  current_category={@category}
                  current_language={@current_language}
                  category_icon_mode={@category_icon_mode}
                  category_name_wrap={@category_name_wrap}
                  show_categories={!@authenticated}
                  filter_qs={@filter_qs}
                />
              </div>
            </div>
          </div>
        <% end %>

        <%= if @authenticated do %>
          <%!-- Authenticated layout: Categories are in dashboard sidebar --%>
          <%!-- Category Header --%>
          <div class="mb-8">
            <h1 class="text-3xl font-bold">{@localized_name}</h1>
            <%= if @localized_description do %>
              <p class="text-base-content/70 mt-2">{@localized_description}</p>
            <% end %>
            <p class="text-sm text-base-content/50 mt-2">
              {@total_products} product(s) found
            </p>
          </div>

          <%!-- Full-width Products Grid --%>
          <%= if @products == [] do %>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body text-center py-16">
                <.icon name="hero-cube" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                <h3 class="text-xl font-medium text-base-content/60">
                  No products in this category
                </h3>
                <p class="text-base-content/50 mb-4">
                  Check back soon or browse other categories
                </p>
                <.link
                  navigate={Shop.catalog_url(@current_language) <> @filter_qs}
                  class="btn btn-primary"
                >
                  Browse All Products
                </.link>
              </div>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
              <%= for product <- @products do %>
                <ShopCards.product_card
                  product={product}
                  currency={@currency}
                  language={@current_language}
                  filter_qs={@filter_qs}
                />
              <% end %>
            </div>

            <ShopCards.shop_pagination
              page={@page}
              total_pages={@total_pages}
              total_products={@total_products}
              per_page={@per_page}
              base_path={Shop.category_url(@category, @current_language)}
              active_filters={@active_filters}
              enabled_filters={@enabled_filters}
            />
          <% end %>
        <% else %>
          <%!-- Guest layout: With sidebar for filters + category navigation --%>
          <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
            <%!-- Sidebar --%>
            <aside class="lg:col-span-1 hidden lg:block">
              <div class="card bg-base-100 shadow-lg sticky top-6 max-h-[calc(100vh-3rem)] overflow-y-auto">
                <div class="card-body p-4">
                  <CatalogSidebar.catalog_sidebar
                    filters={@enabled_filters}
                    filter_values={@filter_values}
                    active_filters={@active_filters}
                    categories={@categories}
                    current_category={@category}
                    current_language={@current_language}
                    category_icon_mode={@category_icon_mode}
                    category_name_wrap={@category_name_wrap}
                    filter_qs={@filter_qs}
                  />
                </div>
              </div>
            </aside>

            <%!-- Main Content --%>
            <div class="lg:col-span-3">
              <%!-- Category Header --%>
              <div class="mb-8">
                <h1 class="text-3xl font-bold">{@localized_name}</h1>
                <%= if @localized_description do %>
                  <p class="text-base-content/70 mt-2">{@localized_description}</p>
                <% end %>
                <p class="text-sm text-base-content/50 mt-2">
                  {@total_products} product(s) found
                </p>
              </div>

              <%!-- Products Grid --%>
              <%= if @products == [] do %>
                <div class="card bg-base-100 shadow-lg">
                  <div class="card-body text-center py-16">
                    <.icon name="hero-cube" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                    <h3 class="text-xl font-medium text-base-content/60">
                      No products in this category
                    </h3>
                    <p class="text-base-content/50 mb-4">
                      Check back soon or browse other categories
                    </p>
                    <.link
                      navigate={Shop.catalog_url(@current_language) <> @filter_qs}
                      class="btn btn-primary"
                    >
                      Browse All Products
                    </.link>
                  </div>
                </div>
              <% else %>
                <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-6">
                  <%= for product <- @products do %>
                    <ShopCards.product_card
                      product={product}
                      currency={@currency}
                      language={@current_language}
                      filter_qs={@filter_qs}
                    />
                  <% end %>
                </div>

                <ShopCards.shop_pagination
                  page={@page}
                  total_pages={@total_pages}
                  total_products={@total_products}
                  per_page={@per_page}
                  base_path={Shop.category_url(@category, @current_language)}
                  active_filters={@active_filters}
                  enabled_filters={@enabled_filters}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  defp shop_sidebar(assigns) do
    ~H"""
    <CatalogSidebar.catalog_sidebar
      filters={@enabled_filters}
      filter_values={@filter_values}
      active_filters={@active_filters}
      categories={@categories}
      current_category={@category}
      current_language={@current_language}
      category_icon_mode={@category_icon_mode}
      category_name_wrap={@category_name_wrap}
      filter_qs={@filter_qs}
    />
    """
  end

  # Build category path with filter params and optional page
  defp build_filter_path(assigns, active_filters, opts \\ []) do
    base_path = Shop.category_url(assigns.category, assigns.current_language)
    page = Keyword.get(opts, :page)

    FilterHelpers.build_filter_url(base_path, active_filters, assigns.enabled_filters, page: page)
  end
end
