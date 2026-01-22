defmodule PhoenixKit.Modules.Shop.Web.CatalogCategory do
  @moduledoc """
  Public shop category page.
  Shows products filtered by category.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    # Get current language for localized lookup
    current_language = socket.assigns[:current_locale] || Translations.default_language()

    case Shop.get_category_by_slug_localized(slug, current_language, preload: [:parent]) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Category not found")
         |> push_navigate(to: Routes.path("/shop"))}

      # Redirect if category is hidden (products not visible)
      {:ok, %{status: "hidden"}} ->
        {:ok,
         socket
         |> put_flash(:error, "Category not found")
         |> push_navigate(to: Routes.path("/shop"))}

      {:ok, category} ->
        {products, total} =
          Shop.list_products_with_count(
            status: "active",
            category_id: category.id,
            per_page: 24,
            preload: [:category]
          )

        currency = Shop.get_default_currency()
        all_categories = Shop.list_active_categories()

        # Check if user is authenticated
        authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

        # Build dashboard tabs with shop categories for authenticated users
        dashboard_tabs =
          if authenticated do
            build_dashboard_tabs_with_shop(
              all_categories,
              category,
              socket.assigns[:url_path] || "/shop",
              socket.assigns[:phoenix_kit_current_scope]
            )
          else
            nil
          end

        # Get localized category content
        localized_name = Translations.get_field(category, :name, current_language)
        localized_description = Translations.get_field(category, :description, current_language)

        socket =
          socket
          |> assign(:page_title, localized_name)
          |> assign(:category, category)
          |> assign(:current_language, current_language)
          |> assign(:localized_name, localized_name)
          |> assign(:localized_description, localized_description)
          |> assign(:products, products)
          |> assign(:total_products, total)
          |> assign(:categories, all_categories)
          |> assign(:currency, currency)
          |> assign(:authenticated, authenticated)
          |> assign(:dashboard_tabs, dashboard_tabs)

        {:ok, socket}
    end
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
  # When viewing a category page, parent tab is not active
  defp create_shop_parent_tab(_current_category) do
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

    Map.put(tab, :active, false)
  end

  # Build category subtabs for existing dashboard_shop tab
  defp build_category_subtabs(categories, current_category) do
    categories
    |> Enum.with_index()
    |> Enum.map(fn {cat, idx} ->
      tab =
        Tab.new!(
          id: String.to_atom("shop_cat_#{cat.id}"),
          label: cat.name,
          icon: "hero-folder",
          path: Routes.path("/shop/category/#{cat.slug}"),
          priority: 301 + idx,
          parent: :dashboard_shop,
          group: :shop,
          match: :prefix
        )

      Map.put(tab, :active, current_category.id == cat.id)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shop_layout {assigns}>
      <div class="p-6 max-w-7xl mx-auto">
        <%!-- Breadcrumbs --%>
        <div class="breadcrumbs text-sm mb-6">
          <ul>
            <li><.link navigate={Routes.path("/shop")}>Shop</.link></li>
            <%= if @category.parent do %>
              <li>
                <.link navigate={Routes.path("/shop/category/#{@category.parent.slug}")}>
                  {@category.parent.name}
                </.link>
              </li>
            <% end %>
            <li class="font-medium">{@category.name}</li>
          </ul>
        </div>

        <%= if @authenticated do %>
          <%!-- Authenticated layout: Categories are in dashboard sidebar --%>
          <%!-- Category Header --%>
          <div class="mb-8">
            <h1 class="text-3xl font-bold">{@category.name}</h1>
            <%= if @category.description do %>
              <p class="text-base-content/70 mt-2">{@category.description}</p>
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
                <.link navigate={Routes.path("/shop")} class="btn btn-primary">
                  Browse All Products
                </.link>
              </div>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
              <%= for product <- @products do %>
                <.product_card product={product} currency={@currency} />
              <% end %>
            </div>
          <% end %>
        <% else %>
          <%!-- Guest layout: With sidebar for category navigation --%>
          <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
            <%!-- Sidebar - Categories --%>
            <aside class="lg:col-span-1">
              <div class="card bg-base-100 shadow-lg sticky top-6">
                <div class="card-body">
                  <h2 class="card-title mb-4">Categories</h2>
                  <ul class="menu menu-compact p-0">
                    <li>
                      <.link
                        navigate={Routes.path("/shop")}
                        class="font-medium"
                      >
                        <.icon name="hero-home" class="w-4 h-4" /> All Products
                      </.link>
                    </li>
                    <%= for cat <- @categories do %>
                      <li>
                        <.link
                          navigate={Routes.path("/shop/category/#{cat.slug}")}
                          class={if cat.id == @category.id, do: "active", else: ""}
                        >
                          {cat.name}
                        </.link>
                      </li>
                    <% end %>
                  </ul>
                </div>
              </div>
            </aside>

            <%!-- Main Content --%>
            <div class="lg:col-span-3">
              <%!-- Category Header --%>
              <div class="mb-8">
                <h1 class="text-3xl font-bold">{@category.name}</h1>
                <%= if @category.description do %>
                  <p class="text-base-content/70 mt-2">{@category.description}</p>
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
                    <.link navigate={Routes.path("/shop")} class="btn btn-primary">
                      Browse All Products
                    </.link>
                  </div>
                </div>
              <% else %>
                <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-6">
                  <%= for product <- @products do %>
                    <.product_card product={product} currency={@currency} />
                  <% end %>
                </div>
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
          <.link navigate={Routes.path("/shop")} class="btn btn-ghost text-xl">
            <.icon name="hero-shopping-bag" class="w-5 h-5 mr-2" /> Shop
          </.link>
        </div>
        <div class="navbar-end gap-2">
          <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-circle">
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

  defp product_card(assigns) do
    ~H"""
    <.link
      navigate={Routes.path("/shop/product/#{@product.slug}")}
      class="card bg-base-100 shadow-md hover:shadow-lg transition-all hover:-translate-y-1"
    >
      <figure class="h-48 bg-base-200">
        <%= if first_image(@product) do %>
          <img
            src={first_image(@product)}
            alt={@product.title}
            class="w-full h-full object-cover"
          />
        <% else %>
          <div class="w-full h-full flex items-center justify-center">
            <.icon name="hero-cube" class="w-16 h-16 opacity-30" />
          </div>
        <% end %>
      </figure>
      <div class="card-body p-4">
        <h3 class="card-title text-base line-clamp-2">{@product.title}</h3>

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

  defp first_image(%{images: [%{"src" => src} | _]}), do: src
  defp first_image(%{images: [first | _]}) when is_binary(first), do: first
  defp first_image(_), do: nil

  defp format_price(nil, _currency), do: "-"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end
end
