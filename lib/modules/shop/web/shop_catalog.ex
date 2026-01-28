defmodule PhoenixKit.Modules.Shop.Web.ShopCatalog do
  @moduledoc """
  Public shop catalog main page.
  Shows categories and featured/active products.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    # Determine language: use URL locale param if present, otherwise default
    # This ensures /shop always uses default language, not session
    current_language = get_language_from_params_or_default(params)

    categories = Shop.list_active_categories(preload: [:parent])

    {products, _total} =
      Shop.list_products_with_count(
        status: "active",
        per_page: 12,
        exclude_hidden_categories: true
      )

    currency = Shop.get_default_currency()

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    # Build dashboard tabs with shop categories for authenticated users
    dashboard_tabs =
      if authenticated do
        build_dashboard_tabs_with_shop(
          categories,
          nil,
          socket.assigns[:url_path] || "/shop",
          socket.assigns[:phoenix_kit_current_scope]
        )
      else
        nil
      end

    # Get current path for language switcher
    current_path = socket.assigns[:url_path] || "/shop"

    socket =
      socket
      |> assign(:page_title, "Shop")
      |> assign(:categories, categories)
      |> assign(:products, products)
      |> assign(:currency, currency)
      |> assign(:current_language, current_language)
      |> assign(:authenticated, authenticated)
      |> assign(:dashboard_tabs, dashboard_tabs)
      |> assign(:current_path, current_path)

    {:ok, socket}
  end

  # Build dashboard tabs including shop categories as subtabs
  defp build_dashboard_tabs_with_shop(categories, current_category, current_path, scope) do
    # Get existing dashboard tabs from registry
    base_tabs = Registry.get_tabs_with_active(current_path, scope: scope)

    # Find existing shop tab and update it, or create new one if not found
    {updated_tabs, shop_exists?} = update_existing_shop_tab(base_tabs)

    # Create category subtabs
    category_tabs = build_category_subtabs(categories, current_category)

    if shop_exists? do
      # Shop tab exists - just append category subtabs
      updated_tabs ++ category_tabs
    else
      # No shop tab in registry - create one with categories
      shop_tab = create_shop_parent_tab(current_category)
      updated_tabs ++ [shop_tab | category_tabs]
    end
  end

  # Update existing dashboard_shop tab to show subtabs always
  defp update_existing_shop_tab(tabs) do
    shop_exists? = Enum.any?(tabs, &(&1.id == :dashboard_shop))

    updated_tabs =
      Enum.map(tabs, fn tab ->
        if tab.id == :dashboard_shop do
          %{tab | subtab_display: :always}
        else
          tab
        end
      end)

    {updated_tabs, shop_exists?}
  end

  # Create shop parent tab (only if not in registry)
  defp create_shop_parent_tab(current_category) do
    tab =
      Tab.new!(
        id: :dashboard_shop,
        label: "Shop",
        icon: "hero-building-storefront",
        path: Routes.path("/shop"),
        priority: 300,
        group: :shop,
        match: :prefix,
        subtab_display: :always
      )

    Map.put(tab, :active, is_nil(current_category))
  end

  # Build category subtabs for existing dashboard_shop tab
  defp build_category_subtabs(categories, current_category) do
    default_lang = Translations.default_language()

    categories
    |> Enum.with_index()
    |> Enum.map(fn {cat, idx} ->
      # Get localized name
      cat_name = Translations.get(cat, :name, default_lang)

      tab =
        Tab.new!(
          id: String.to_atom("shop_cat_#{cat.id}"),
          label: cat_name,
          icon: "hero-folder",
          path: Shop.category_url(cat, default_lang),
          priority: 301 + idx,
          parent: :dashboard_shop,
          group: :shop,
          match: :prefix
        )

      is_active = current_category && current_category.id == cat.id
      Map.put(tab, :active, is_active)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shop_layout {assigns}>
      <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
        <%!-- Hero Section --%>
        <header class="w-full relative mb-6">
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Welcome to Our Shop</h1>
            <p class="text-lg text-base-content/70">
              Browse our collection of products across various categories
            </p>
          </div>
        </header>

        <%!-- Categories Section --%>
        <div class="mb-12">
          <h2 class="text-2xl font-bold mb-6">Browse by Category</h2>
          <%= if @categories == [] do %>
            <p class="text-base-content/60">No categories available yet.</p>
          <% else %>
            <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
              <%= for category <- @categories do %>
                <% cat_name = Translations.get(category, :name, @current_language) %>
                <% cat_desc = Translations.get(category, :description, @current_language) %>
                <.link
                  navigate={Shop.category_url(category, @current_language)}
                  class="card bg-base-100 shadow-md hover:shadow-xl transition-shadow"
                >
                  <div class="card-body items-center text-center p-4">
                    <%= if image_url = Category.get_image_url(category) do %>
                      <div class="w-16 h-16 rounded-full overflow-hidden mb-2">
                        <img
                          src={image_url}
                          alt={cat_name}
                          class="w-full h-full object-cover"
                        />
                      </div>
                    <% else %>
                      <div class="w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center mb-2">
                        <.icon name="hero-folder" class="w-8 h-8 text-primary" />
                      </div>
                    <% end %>
                    <h3 class="font-semibold">{cat_name}</h3>
                    <%= if cat_desc do %>
                      <p class="text-xs text-base-content/60 line-clamp-2">
                        {cat_desc}
                      </p>
                    <% end %>
                  </div>
                </.link>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Products Section --%>
        <div>
          <div class="flex items-center justify-between mb-6">
            <h2 class="text-2xl font-bold">Products</h2>
            <.link navigate={Shop.cart_url(@current_language)} class="btn btn-outline btn-sm gap-2">
              <.icon name="hero-shopping-cart" class="w-4 h-4" /> View Cart
            </.link>
          </div>

          <%= if @products == [] do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body text-center py-16">
                <.icon name="hero-cube" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                <h3 class="text-xl font-medium text-base-content/60">No products available</h3>
                <p class="text-base-content/50">Check back soon for new arrivals</p>
              </div>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
              <%= for product <- @products do %>
                <.product_card product={product} currency={@currency} language={@current_language} />
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </.shop_layout>
    """
  end

  # Layout wrapper - uses dashboard for authenticated, app_layout for guests
  slot :inner_block, required: true

  defp shop_layout(assigns) do
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

  defp product_card(assigns) do
    # Get localized values
    assigns =
      assigns
      |> assign(:product_title, Translations.get(assigns.product, :title, assigns.language))
      |> assign(:product_url, Shop.product_url(assigns.product, assigns.language))
      |> assign(
        :category_name,
        if(assigns.product.category,
          do: Translations.get(assigns.product.category, :name, assigns.language),
          else: nil
        )
      )

    ~H"""
    <.link
      navigate={@product_url}
      class="card bg-base-100 shadow-md hover:shadow-xl transition-all hover:-translate-y-1"
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

        <%= if @category_name do %>
          <div class="mt-2">
            <span class="badge badge-ghost badge-sm">{@category_name}</span>
          </div>
        <% end %>
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
  # This ensures non-localized routes (/shop) always use default language,
  # regardless of what's stored in session from previous visits
  defp get_language_from_params_or_default(%{"locale" => locale}) when is_binary(locale) do
    DialectMapper.resolve_dialect(locale, nil)
  end

  defp get_language_from_params_or_default(_params) do
    Translations.default_language()
  end
end
