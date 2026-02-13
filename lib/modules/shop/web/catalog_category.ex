defmodule PhoenixKit.Modules.Shop.Web.CatalogCategory do
  @moduledoc """
  Public shop category page.
  Shows products filtered by category.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.SlugResolver
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Web.Components.CatalogSidebar
  alias PhoenixKit.Modules.Shop.Web.Components.FilterHelpers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    # Determine language: use URL locale param if present, otherwise default
    # This ensures /shop/... always uses default language, not session
    current_language = get_language_from_params_or_default(params)

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
        page = parse_page(params["page"])

        # Load storefront filters
        {enabled_filters, filter_values} =
          FilterHelpers.load_filter_data(category_uuid: category.uuid)

        active_filters = FilterHelpers.parse_filter_params(params, enabled_filters)
        filter_opts = FilterHelpers.build_query_opts(active_filters, enabled_filters)

        {products, total} =
          Shop.list_products_with_count(
            [
              status: "active",
              category_id: category.id,
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

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
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
            category_id: socket.assigns.category.id,
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
        case best_redirect_language(category.slug || %{}) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Category not found")
             |> push_navigate(to: Shop.catalog_url(current_language))}

          redirect_lang ->
            slug = SlugResolver.category_slug(category, redirect_lang)

            {:ok,
             push_navigate(socket, to: build_lang_url("/shop/category/#{slug}", redirect_lang))}
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
    ~H"""
    <.shop_layout {assigns}>
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
                <.product_card
                  product={product}
                  currency={@currency}
                  language={@current_language}
                  filter_qs={@filter_qs}
                />
              <% end %>
            </div>

            <.shop_pagination
              page={@page}
              total_pages={@total_pages}
              total_products={@total_products}
              per_page={@per_page}
              category={@category}
              current_language={@current_language}
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
                    <.product_card
                      product={product}
                      currency={@currency}
                      language={@current_language}
                      filter_qs={@filter_qs}
                    />
                  <% end %>
                </div>

                <.shop_pagination
                  page={@page}
                  total_pages={@total_pages}
                  total_products={@total_products}
                  per_page={@per_page}
                  category={@category}
                  current_language={@current_language}
                  active_filters={@active_filters}
                  enabled_filters={@enabled_filters}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </.shop_layout>
    """
  end

  # Layout wrapper - uses dashboard for authenticated, app_layout for guests
  slot :inner_block, required: true

  defp shop_layout(assigns) do
    # For authenticated users, render filters + categories in dashboard sidebar
    assigns =
      if assigns.authenticated do
        assign(assigns, :sidebar_after_shop, shop_sidebar(assigns))
      else
        assigns
      end

    ~H"""
    <%= if @authenticated do %>
      <PhoenixKitWeb.Layouts.dashboard {assigns}>
        {render_slot(@inner_block)}
      </PhoenixKitWeb.Layouts.dashboard>
    <% else %>
      <.shop_public_layout {assigns}>
        {render_slot(@inner_block)}
      </.shop_public_layout>
    <% end %>
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

  # Public shop layout with wide container for guests
  slot :inner_block, required: true

  defp shop_public_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <%!-- Simple navbar for shop --%>
      <nav class="navbar bg-base-100 shadow-sm border-b border-base-200">
        <div class="navbar-start">
          <.link navigate="/" class="btn btn-ghost text-xl">
            <.icon name="hero-home" class="w-5 h-5" />
          </.link>
        </div>
        <div class="navbar-center">
          <.link navigate={Shop.catalog_url(@current_language)} class="btn btn-ghost text-xl">
            <.icon name="hero-shopping-bag" class="w-5 h-5 mr-2" /> Shop
          </.link>
        </div>
        <div class="navbar-end gap-2">
          <.language_switcher_dropdown
            current_locale={@current_language}
            current_path={@current_path}
          />
          <.link navigate={Shop.cart_url(@current_language)} class="btn btn-ghost btn-circle">
            <.icon name="hero-shopping-cart" class="w-5 h-5" />
          </.link>
          <.link navigate={Routes.path("/users/log-in")} class="btn btn-primary btn-sm">
            Sign In
          </.link>
        </div>
      </nav>

      <%!-- Flash messages --%>
      <.flash_group flash={@flash} />

      <%!-- Wide content area --%>
      <main class="py-6">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :product, :map, required: true
  attr :currency, :any, required: true
  attr :language, :string, default: "en"
  attr :filter_qs, :string, default: ""

  defp product_card(assigns) do
    # Get localized values
    assigns =
      assigns
      |> assign(:product_title, Translations.get(assigns.product, :title, assigns.language))
      |> assign(:product_url, Shop.product_url(assigns.product, assigns.language))

    ~H"""
    <.link
      navigate={@product_url <> @filter_qs}
      class="card bg-base-100 shadow-md hover:shadow-lg transition-all hover:-translate-y-1"
    >
      <figure class="h-48 bg-base-200">
        <%= if first_image(@product) do %>
          <img
            src={first_image(@product)}
            alt={@product_title}
            class="w-full h-full object-cover"
          />
        <% else %>
          <div class="w-full h-full flex items-center justify-center">
            <.icon name="hero-cube" class="w-16 h-16 opacity-30" />
          </div>
        <% end %>
      </figure>
      <div class="card-body p-4">
        <h3 class="card-title text-base line-clamp-2">{@product_title}</h3>

        <div class="flex items-center gap-2">
          <span class="text-lg font-bold text-primary">
            {format_price(@product.price, @currency)}
          </span>
          <%= if @product.compare_at_price && Decimal.compare(@product.compare_at_price, @product.price) == :gt do %>
            <span class="text-sm text-base-content/40 line-through">
              {format_price(@product.compare_at_price, @currency)}
            </span>
          <% end %>
        </div>
      </div>
    </.link>
    """
  end

  # Storage-based images (new format)
  defp first_image(%{featured_image_id: id}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  defp first_image(%{image_ids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  # Legacy URL-based images (Shopify imports)
  defp first_image(%{images: [%{"src" => src} | _]}), do: src
  defp first_image(%{images: [first | _]}) when is_binary(first), do: first
  defp first_image(_), do: nil

  # Get signed URL for Storage image
  defp get_storage_image_url(file_id, variant) do
    alias PhoenixKit.Modules.Storage
    alias PhoenixKit.Modules.Storage.URLSigner

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

  defp format_price(nil, _currency), do: "-"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end

  # Determine language from URL params - use locale param if present, otherwise default
  # This ensures non-localized routes (/shop/...) always use default language,
  # regardless of what's stored in session from previous visits
  defp get_language_from_params_or_default(%{"locale" => locale}) when is_binary(locale) do
    DialectMapper.resolve_dialect(locale, nil)
  end

  defp get_language_from_params_or_default(_params) do
    Translations.default_language()
  end

  # Find the best enabled language that has a slug for this entity.
  # Prefers the default language, then checks other enabled languages.
  defp best_redirect_language(slug_map) when slug_map == %{}, do: nil

  defp best_redirect_language(slug_map) do
    enabled = Languages.get_enabled_languages()
    default_first = Enum.sort_by(enabled, fn l -> if l["is_default"], do: 0, else: 1 end)

    Enum.find_value(default_first, fn lang ->
      code = lang["code"]
      base = DialectMapper.extract_base(code)
      if Map.has_key?(slug_map, code) or Map.has_key?(slug_map, base), do: code
    end)
  end

  # Build a localized URL path, adding language prefix for non-default languages.
  # Delegates to Routes.path which handles default vs non-default consistently.
  defp build_lang_url(path, lang) do
    base = DialectMapper.extract_base(lang)
    Routes.path(path, locale: base)
  end

  # Pagination UI component
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :total_products, :integer, required: true
  attr :per_page, :integer, required: true
  attr :category, :map, required: true
  attr :current_language, :string, required: true
  attr :active_filters, :map, default: %{}
  attr :enabled_filters, :list, default: []

  defp shop_pagination(assigns) do
    remaining = assigns.total_products - assigns.page * assigns.per_page
    base_path = Shop.category_url(assigns.category, assigns.current_language)

    assigns =
      assigns
      |> assign(:remaining, max(0, remaining))
      |> assign(:has_more, assigns.page < assigns.total_pages)
      |> assign(:base_path, base_path)

    ~H"""
    <%= if @total_pages > 1 do %>
      <div class="mt-8 space-y-4">
        <%!-- Load More Button --%>
        <%= if @has_more do %>
          <div class="flex justify-center">
            <button phx-click="load_more" class="btn btn-primary btn-lg gap-2">
              <.icon name="hero-arrow-down" class="w-5 h-5" /> Show More
              <span class="badge badge-ghost">{@remaining}</span>
            </button>
          </div>
        <% end %>

        <%!-- Page Links for SEO and direct access --%>
        <nav class="flex flex-wrap justify-center gap-2 text-sm">
          <%= for p <- 1..@total_pages do %>
            <.link
              patch={
                FilterHelpers.build_filter_url(@base_path, @active_filters, @enabled_filters, page: p)
              }
              class={[
                "px-3 py-1 rounded transition-colors",
                if(p <= @page,
                  do: "bg-primary text-primary-content",
                  else: "bg-base-200 hover:bg-base-300 text-base-content/70"
                )
              ]}
            >
              {p}
            </.link>
          <% end %>
        </nav>

        <%!-- Status text --%>
        <p class="text-center text-sm text-base-content/50">
          Showing {min(@page * @per_page, @total_products)} of {@total_products} products
        </p>
      </div>
    <% end %>
    """
  end

  # Parse page param with validation
  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {p, ""} when p > 0 -> p
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_), do: 1

  # Build category path with filter params and optional page
  defp build_filter_path(assigns, active_filters, opts \\ []) do
    base_path = Shop.category_url(assigns.category, assigns.current_language)
    page = Keyword.get(opts, :page)

    FilterHelpers.build_filter_url(base_path, active_filters, assigns.enabled_filters, page: page)
  end
end
