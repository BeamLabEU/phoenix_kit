defmodule PhoenixKit.Modules.Shop.Web.CatalogProduct do
  @moduledoc """
  Public product detail page with add-to-cart functionality.

  Supports dynamic option-based pricing with fixed and percent modifiers.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  # Data URI placeholder for broken images - works without external file serving
  @placeholder_data_uri "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='400' height='400' viewBox='0 0 400 400'%3E%3Crect width='400' height='400' fill='%23e5e7eb'/%3E%3Cg fill='%239ca3af'%3E%3Crect x='160' y='140' width='80' height='60' rx='4'/%3E%3Ccircle cx='180' cy='160' r='8'/%3E%3Cpath d='M160 190 l25-20 l15 15 l20-25 l20 30 v10 h-80 z'/%3E%3C/g%3E%3C/svg%3E"

  @impl true
  def mount(%{"slug" => slug} = params, session, socket) do
    # Determine language: use URL locale param if present, otherwise default
    # This ensures /shop/... always uses default language, not session
    current_language = get_language_from_params_or_default(params)

    # Try localized slug lookup first
    case Shop.get_product_by_slug_localized(slug, current_language, preload: [:category]) do
      {:error, :not_found} ->
        # Slug not found in current language - try cross-language lookup
        handle_cross_language_redirect(slug, current_language, session, socket)

      # Hide product if its category is hidden
      {:ok, %{category: %{status: "hidden"}}} ->
        {:ok,
         socket
         |> put_flash(:error, "Product not found")
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, product} ->
        # Get session_id for guest cart
        session_id = session["shop_session_id"] || generate_session_id()
        user = get_current_user(socket)
        user_id = if user, do: user.id, else: nil

        currency = Shop.get_default_currency()

        # Check if user is authenticated
        authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

        # Build specifications from options (non-price-affecting for display)
        specifications = build_specifications(product)

        # Load price-affecting specs for dynamic pricing
        price_affecting_specs = Shop.get_price_affecting_specs(product)

        # Load ALL selectable specs for UI display (includes non-price-affecting like Color)
        selectable_specs = Shop.get_selectable_specs(product)

        # Initialize selected specs with defaults from product metadata
        # Use selectable_specs to include all options, not just price-affecting
        selected_specs = build_default_specs(selectable_specs, product.metadata || %{})

        # Calculate initial price
        calculated_price = Shop.calculate_product_price(product, selected_specs)

        # Check if product is already in cart
        cart_item = find_cart_item_with_specs(user_id, session_id, product.id, selected_specs)

        # Calculate missing required specs for UI (check all selectable specs, not just price-affecting)
        missing_required_specs = get_missing_required_specs(selected_specs, selectable_specs)

        # Build dashboard tabs with shop categories for authenticated users
        dashboard_tabs =
          if authenticated do
            categories = Shop.list_menu_categories()
            current_category = product.category

            build_dashboard_tabs_with_shop(
              categories,
              current_category,
              socket.assigns[:url_path] || "/shop",
              socket.assigns[:phoenix_kit_current_scope]
            )
          else
            nil
          end

        # Get localized content
        localized_title = Translations.get(product, :title, current_language)
        localized_description = Translations.get(product, :description, current_language)
        localized_body = Translations.get(product, :body_html, current_language)

        # Get current path for language switcher
        current_path = socket.assigns[:url_path] || Shop.product_url(product, current_language)

        socket =
          socket
          |> assign(:page_title, localized_title)
          |> assign(:product, product)
          |> assign(:current_language, current_language)
          |> assign(:localized_title, localized_title)
          |> assign(:localized_description, localized_description)
          |> assign(:localized_body, localized_body)
          |> assign(:currency, currency)
          |> assign(:quantity, 1)
          |> assign(:session_id, session_id)
          |> assign(:user_id, user_id)
          |> assign(:selected_image, first_image(product))
          |> assign(:adding_to_cart, false)
          |> assign(:authenticated, authenticated)
          |> assign(:cart_item, cart_item)
          |> assign(:specifications, specifications)
          |> assign(:price_affecting_specs, price_affecting_specs)
          |> assign(:selectable_specs, selectable_specs)
          |> assign(:selected_specs, selected_specs)
          |> assign(:calculated_price, calculated_price)
          |> assign(:missing_required_specs, missing_required_specs)
          |> assign(:dashboard_tabs, dashboard_tabs)
          |> assign(:current_path, current_path)

        {:ok, socket}
    end
  end

  # Handle cross-language slug redirect
  # When user visits with a slug from a different language, redirect to correct localized URL
  defp handle_cross_language_redirect(slug, current_language, _session, socket) do
    case Shop.get_product_by_any_slug(slug, preload: [:category]) do
      {:error, :not_found} ->
        # Product truly not found
        {:ok,
         socket
         |> put_flash(:error, "Product not found")
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, %{category: %{status: "hidden"}}, _matched_lang} ->
        # Product's category is hidden
        {:ok,
         socket
         |> put_flash(:error, "Product not found")
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, product, _matched_lang} ->
        # Found product - redirect to correct localized URL with 301
        correct_url = Shop.product_url(product, current_language)
        {:ok, push_navigate(socket, to: correct_url)}
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
  defp create_shop_parent_tab(current_category) do
    default_lang = Translations.default_language()

    tab =
      Tab.new!(
        id: :dashboard_shop,
        label: "Shop",
        icon: "hero-building-storefront",
        path: Shop.catalog_url(default_lang),
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
  def handle_event("set_quantity", %{"quantity" => quantity}, socket) do
    quantity = String.to_integer(quantity) |> max(1)
    {:noreply, assign(socket, :quantity, quantity)}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    {:noreply, assign(socket, :quantity, socket.assigns.quantity + 1)}
  end

  @impl true
  def handle_event("decrement", _params, socket) do
    quantity = max(socket.assigns.quantity - 1, 1)
    {:noreply, assign(socket, :quantity, quantity)}
  end

  @impl true
  def handle_event("select_image", %{"url" => url}, socket) do
    {:noreply, assign(socket, :selected_image, url)}
  end

  @impl true
  def handle_event("select_spec", params, socket) do
    key = params["key"] || ""
    value = params["opt"] || ""

    # Debug logging
    require Logger
    Logger.debug("select_spec params: #{inspect(params)}")
    Logger.debug("select_spec key=#{inspect(key)} value=#{inspect(value)}")

    selected_specs = Map.put(socket.assigns.selected_specs, key, value)
    product = socket.assigns.product
    selectable_specs = socket.assigns.selectable_specs

    # Recalculate price with new spec selection
    calculated_price = Shop.calculate_product_price(product, selected_specs)

    # Check for image mapping - update selected_image if mapping exists
    selected_image = get_mapped_image(product, key, value, socket.assigns.selected_image)

    # Check if this combination is in cart
    cart_item =
      find_cart_item_with_specs(
        socket.assigns.user_id,
        socket.assigns.session_id,
        product.id,
        selected_specs
      )

    # Update missing required specs for UI (check all selectable specs)
    missing_required_specs = get_missing_required_specs(selected_specs, selectable_specs)

    socket =
      socket
      |> assign(:selected_specs, selected_specs)
      |> assign(:calculated_price, calculated_price)
      |> assign(:selected_image, selected_image)
      |> assign(:cart_item, cart_item)
      |> assign(:missing_required_specs, missing_required_specs)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_storage_image", %{"id" => id}, socket) do
    url = get_storage_image_url(id, "large")
    {:noreply, assign(socket, :selected_image, url)}
  end

  @impl true
  def handle_event("add_to_cart", _params, socket) do
    do_add_to_cart(socket)
  end

  defp do_add_to_cart(socket) do
    %{
      selected_specs: selected_specs,
      selectable_specs: selectable_specs
    } = socket.assigns

    # Validate required options before proceeding (check all selectable specs)
    case validate_required_specs(selected_specs, selectable_specs) do
      :ok ->
        do_add_to_cart_impl(socket)

      {:error, missing_labels} ->
        message = "Please select: #{Enum.join(missing_labels, ", ")}"
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp do_add_to_cart_impl(socket) do
    socket = assign(socket, :adding_to_cart, true)

    # Get or create cart
    {:ok, cart} =
      Shop.get_or_create_cart(
        user_id: socket.assigns.user_id,
        session_id: socket.assigns.session_id
      )

    %{
      product: product,
      quantity: quantity,
      currency: currency,
      selected_specs: selected_specs,
      price_affecting_specs: price_affecting_specs,
      calculated_price: calculated_price
    } = socket.assigns

    # Add to cart with or without specs
    add_result =
      if price_affecting_specs != [] do
        Shop.add_to_cart(cart, product, quantity, selected_specs: selected_specs)
      else
        Shop.add_to_cart(cart, product, quantity)
      end

    case add_result do
      {:ok, updated_cart} ->
        unit_price =
          if price_affecting_specs != [] do
            calculated_price
          else
            product.price
          end

        display_name = build_cart_display_name(product, price_affecting_specs, selected_specs)

        message =
          build_cart_message(display_name, quantity, unit_price, updated_cart.total, currency)

        updated_cart_item =
          find_cart_item_after_add(
            updated_cart.items,
            product.id,
            selected_specs,
            price_affecting_specs
          )

        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> assign(:quantity, 1)
         |> assign(:cart_item, updated_cart_item)
         |> put_flash(:info, message)
         |> push_event("cart_updated", %{})}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(:error, "Failed to add to cart")}
    end
  end

  defp build_cart_display_name(product, price_affecting_specs, selected_specs) do
    # Get localized title (use default language for cart display)
    title = Translations.get(product, :title, Translations.default_language())

    if price_affecting_specs != [] && map_size(selected_specs) > 0 do
      specs_str = selected_specs |> Map.values() |> Enum.join(", ")
      "#{title} (#{specs_str})"
    else
      title
    end
  end

  defp build_cart_message(display_name, quantity, unit_price, cart_total, currency) do
    line_total = Decimal.mult(unit_price, quantity)
    line_str = format_price(line_total, currency)
    cart_total_str = format_price(cart_total, currency)
    unit_price_str = format_price(unit_price, currency)

    "#{display_name} (#{quantity} × #{unit_price_str} = #{line_str}) added to cart.\nCart total: #{cart_total_str}"
  end

  defp find_cart_item_after_add(items, product_id, selected_specs, price_affecting_specs) do
    if price_affecting_specs != [] do
      Enum.find(items, &(&1.product_id == product_id && &1.selected_specs == selected_specs))
    else
      Enum.find(items, &(&1.product_id == product_id))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shop_layout {assigns}>
      <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
        <%!-- Breadcrumbs --%>
        <div class="breadcrumbs text-sm mb-6">
          <ul>
            <li><.link navigate={Shop.catalog_url(@current_language)}>Shop</.link></li>
            <%= if @product.category do %>
              <% cat_name = Translations.get(@product.category, :name, @current_language) %>
              <li>
                <.link navigate={Shop.category_url(@product.category, @current_language)}>
                  {cat_name}
                </.link>
              </li>
            <% end %>
            <li class="font-medium truncate max-w-xs">{@localized_title}</li>
          </ul>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-12">
          <%!-- Product Images --%>
          <div class="space-y-4">
            <%!-- Main Image --%>
            <div class="aspect-square bg-base-200 rounded-lg overflow-hidden">
              <%= if @selected_image do %>
                <img
                  src={@selected_image}
                  alt={@localized_title}
                  class="w-full h-full object-cover"
                  onerror={"this.src='#{placeholder_image_url()}'"}
                />
              <% else %>
                <div class="w-full h-full flex items-center justify-center">
                  <.icon name="hero-cube" class="w-32 h-32 opacity-30" />
                </div>
              <% end %>
            </div>

            <%!-- Thumbnails from Storage --%>
            <% display_images = get_display_images(@product) %>
            <%= if display_images != [] do %>
              <div class="flex gap-2 overflow-x-auto py-2">
                <%= for image_id <- display_images do %>
                  <% thumb_url = get_storage_image_url(image_id, "thumbnail") %>
                  <% large_url = get_storage_image_url(image_id, "large") %>
                  <button
                    phx-click="select_storage_image"
                    phx-value-id={image_id}
                    class={[
                      "w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 border-2 transition-colors",
                      if(@selected_image == large_url,
                        do: "border-primary",
                        else: "border-transparent hover:border-base-300"
                      )
                    ]}
                  >
                    <img
                      src={thumb_url}
                      alt="Thumbnail"
                      class="w-full h-full object-cover"
                      onerror={"this.src='#{placeholder_image_url()}'"}
                    />
                  </button>
                <% end %>
              </div>
            <% end %>

            <%!-- Legacy URL-based thumbnails (only show if no Storage images) --%>
            <%= if has_multiple_images?(@product) and get_display_images(@product) == [] do %>
              <div class="flex gap-2 overflow-x-auto py-2">
                <%= for {image, _idx} <- Enum.with_index(@product.images || []) do %>
                  <% url = image_url(image) %>
                  <%= if url do %>
                    <button
                      phx-click="select_image"
                      phx-value-url={url}
                      class={[
                        "w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 border-2 transition-colors",
                        if(@selected_image == url,
                          do: "border-primary",
                          else: "border-transparent hover:border-base-300"
                        )
                      ]}
                    >
                      <img
                        src={url}
                        alt="Thumbnail"
                        class="w-full h-full object-cover"
                        onerror={"this.src='#{placeholder_image_url()}'"}
                      />
                    </button>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Product Info --%>
          <div class="space-y-6">
            <div>
              <h1 class="text-3xl font-bold mb-2">{@localized_title}</h1>

              <%= if @product.vendor do %>
                <p class="text-base-content/60">by {@product.vendor}</p>
              <% end %>
            </div>

            <%!-- Price --%>
            <div class="flex items-baseline gap-3">
              <%= if @price_affecting_specs != [] do %>
                <%!-- Has price-affecting specs - show calculated price --%>
                <span class="text-3xl font-bold text-primary">
                  {format_price(@calculated_price, @currency)}
                </span>
                <%= if @product.compare_at_price && Decimal.compare(@product.compare_at_price, @calculated_price) == :gt do %>
                  <span class="text-xl text-base-content/40 line-through">
                    {format_price(@product.compare_at_price, @currency)}
                  </span>
                <% end %>
              <% else %>
                <%!-- Simple product - show base price --%>
                <span class="text-3xl font-bold text-primary">
                  {format_price(@product.price, @currency)}
                </span>
                <%= if @product.compare_at_price && Decimal.compare(@product.compare_at_price, @product.price) == :gt do %>
                  <span class="text-xl text-base-content/40 line-through">
                    {format_price(@product.compare_at_price, @currency)}
                  </span>
                  <span class="badge badge-success">
                    {discount_percentage(@product)}% OFF
                  </span>
                <% end %>
              <% end %>
            </div>

            <%!-- Description --%>
            <%= if @localized_description do %>
              <div class="prose prose-sm max-w-none">
                <p>{@localized_description}</p>
              </div>
            <% end %>

            <%!-- Product Details --%>
            <div class="divider"></div>

            <div class="grid grid-cols-2 gap-4 text-sm">
              <%= if @product.weight_grams && @product.weight_grams > 0 do %>
                <div>
                  <span class="text-base-content/60">Weight:</span>
                  <span class="ml-2 font-medium">{@product.weight_grams}g</span>
                </div>
              <% end %>

              <%= if @product.category do %>
                <% cat_name = Translations.get(@product.category, :name, @current_language) %>
                <div>
                  <span class="text-base-content/60">Category:</span>
                  <.link
                    navigate={Shop.category_url(@product.category, @current_language)}
                    class="ml-2 link link-primary"
                  >
                    {cat_name}
                  </.link>
                </div>
              <% end %>
            </div>

            <%!-- Specifications Table --%>
            <%= if @specifications != [] do %>
              <div class="divider"></div>

              <h3 class="font-semibold text-lg mb-3">
                <.icon name="hero-tag" class="w-5 h-5 inline" /> Specifications
              </h3>

              <div class="overflow-x-auto">
                <table class="table table-zebra table-sm">
                  <tbody>
                    <%= for {label, value, unit} <- @specifications do %>
                      <tr>
                        <td class="font-medium w-1/3 text-base-content/70">{label}</td>
                        <td>
                          {format_spec_value(value)}
                          <%= if unit do %>
                            <span class="text-base-content/50 ml-1">{unit}</span>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <div class="divider"></div>

            <%!-- Add to Cart Section --%>
            <%= if @product.status == "active" do %>
              <div class="space-y-4">
                <%!-- Option Selector (All Selectable Options) --%>
                <%= if @selectable_specs != [] do %>
                  <div class="space-y-4">
                    <h3 class="font-semibold text-lg">
                      <.icon name="hero-adjustments-horizontal" class="w-5 h-5 inline" />
                      Choose Options
                    </h3>

                    <%= for attr <- @selectable_specs do %>
                      <% is_missing = MapSet.member?(@missing_required_specs, attr["key"]) %>
                      <% affects_price = attr["affects_price"] == true %>
                      <div class="form-control">
                        <label class="label">
                          <span class={[
                            "label-text font-medium",
                            is_missing && "text-error"
                          ]}>
                            {attr["label"]}
                          </span>
                          <%= if attr["required"] do %>
                            <span class="label-text-alt text-error">*</span>
                          <% end %>
                        </label>
                        <%= if is_missing do %>
                          <div class="text-error text-xs mb-1">Please select an option</div>
                        <% end %>
                        <div class="flex flex-wrap gap-2">
                          <%= for opt_value <- get_option_values(@product, attr) do %>
                            <%= if affects_price do %>
                              <.option_button
                                option_key={attr["key"]}
                                option_value={opt_value}
                                price={
                                  calculate_option_total_price(
                                    @product,
                                    @price_affecting_specs,
                                    @selected_specs,
                                    attr["key"],
                                    opt_value
                                  )
                                }
                                selected={@selected_specs[attr["key"]] == opt_value}
                                is_missing={is_missing}
                                currency={@currency}
                              />
                            <% else %>
                              <.option_button_simple
                                option_key={attr["key"]}
                                option_value={opt_value}
                                selected={@selected_specs[attr["key"]] == opt_value}
                                is_missing={is_missing}
                              />
                            <% end %>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Quantity Selector --%>
                <div class="form-control">
                  <label class="label"><span class="label-text">Quantity</span></label>
                  <div class="flex items-center gap-3">
                    <div class="flex items-center gap-1">
                      <button
                        type="button"
                        phx-click="decrement"
                        class="btn btn-square btn-outline btn-sm"
                        disabled={@quantity <= 1}
                      >
                        <.icon name="hero-minus" class="w-4 h-4" />
                      </button>
                      <form phx-change="set_quantity" class="inline">
                        <input
                          type="number"
                          value={@quantity}
                          name="quantity"
                          min="1"
                          class="input input-bordered w-20 text-center"
                        />
                      </form>
                      <button
                        type="button"
                        phx-click="increment"
                        class="btn btn-square btn-outline btn-sm"
                      >
                        <.icon name="hero-plus" class="w-4 h-4" />
                      </button>
                    </div>
                    <span class="text-base-content/60">×</span>
                    <span class="text-base-content/60">
                      {format_price(
                        current_display_price(@product, @calculated_price, @price_affecting_specs),
                        @currency
                      )}
                    </span>
                    <span class="text-base-content/60">=</span>
                    <span class="text-xl font-bold text-primary">
                      {format_price(
                        line_total(
                          current_display_price(@product, @calculated_price, @price_affecting_specs),
                          @quantity
                        ),
                        @currency
                      )}
                    </span>
                  </div>
                </div>

                <%!-- Already in Cart Notice --%>
                <%= if @cart_item do %>
                  <div class="alert alert-info">
                    <.icon name="hero-shopping-cart" class="w-5 h-5" />
                    <div>
                      <span class="font-medium">Already in cart:</span>
                      <span>
                        {@cart_item.quantity} × {format_price(@cart_item.unit_price, @currency)} = {format_price(
                          @cart_item.line_total,
                          @currency
                        )}
                      </span>
                    </div>
                  </div>
                <% end %>

                <%!-- Add to Cart Button --%>
                <button
                  phx-click="add_to_cart"
                  class={["btn btn-primary btn-lg w-full", @adding_to_cart && "loading"]}
                  disabled={@adding_to_cart}
                >
                  <%= if @adding_to_cart do %>
                    Adding...
                  <% else %>
                    <.icon name="hero-shopping-cart" class="w-5 h-5 mr-2" />
                    <%= if @cart_item do %>
                      Add More to Cart
                    <% else %>
                      Add to Cart
                    <% end %>
                  <% end %>
                </button>

                <%!-- View Cart Link --%>
                <.link navigate={Shop.cart_url(@current_language)} class="btn btn-outline w-full">
                  <.icon name="hero-eye" class="w-5 h-5 mr-2" /> View Cart
                </.link>
              </div>
            <% else %>
              <div class="alert alert-warning">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>This product is currently unavailable</span>
              </div>
            <% end %>

            <%!-- Tags --%>
            <%= if @product.tags && @product.tags != [] do %>
              <div class="flex flex-wrap gap-2 mt-4">
                <%= for tag <- @product.tags do %>
                  <span class="badge badge-ghost">{tag}</span>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </.shop_layout>
    """
  end

  # Option button component - isolated for better debugging
  attr :option_key, :any, required: true
  attr :option_value, :any, required: true
  attr :price, :any, required: true
  attr :selected, :boolean, default: false
  attr :is_missing, :boolean, default: false
  attr :currency, :any, required: true

  defp option_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_spec"
      phx-value-key={@option_key}
      phx-value-opt={@option_value}
      class={[
        "btn btn-sm gap-1",
        @selected && "btn-primary",
        !@selected && "btn-outline",
        !@selected && @is_missing && "btn-error btn-outline"
      ]}
    >
      {@option_value} — {format_price(@price, @currency)}
    </button>
    """
  end

  # Simple option button without price - for non-price-affecting options
  attr :option_key, :any, required: true
  attr :option_value, :any, required: true
  attr :selected, :boolean, default: false
  attr :is_missing, :boolean, default: false

  defp option_button_simple(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_spec"
      phx-value-key={@option_key}
      phx-value-opt={@option_value}
      class={[
        "btn btn-sm",
        @selected && "btn-primary",
        !@selected && "btn-outline",
        !@selected && @is_missing && "btn-error btn-outline"
      ]}
    >
      {@option_value}
    </button>
    """
  end

  # Layout wrapper - uses dashboard for authenticated, wide layout for guests
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

  # Private helpers

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # Image helpers - prefer Storage images over legacy URL-based images

  # Get mapped image URL for selected option value, or keep current image if no mapping
  # Supports both Storage IDs and legacy URLs (from Shopify imports)
  defp get_mapped_image(product, option_key, option_value, current_image) do
    case get_in(product.metadata || %{}, ["_image_mappings", option_key, option_value]) do
      nil -> current_image
      "" -> current_image
      # If it's a URL (starts with http), use directly
      "http" <> _ = url -> url
      # Otherwise it's a Storage ID
      image_id -> get_storage_image_url(image_id, "large") || current_image
    end
  end

  defp first_image(%{featured_image_id: id}) when is_binary(id) do
    get_storage_image_url(id, "large")
  end

  defp first_image(%{image_ids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "large")
  end

  defp first_image(%{images: [%{"src" => src} | _]}), do: src
  defp first_image(%{images: [first | _]}) when is_binary(first), do: first
  defp first_image(_), do: nil

  # Extract URL from image (handles both map and string formats)
  defp image_url(%{"src" => src}), do: src
  defp image_url(url) when is_binary(url), do: url
  defp image_url(_), do: nil

  defp has_storage_images?(%{featured_image_id: id}) when is_binary(id), do: true
  defp has_storage_images?(%{image_ids: [_ | _]}), do: true
  defp has_storage_images?(_), do: false

  defp has_multiple_images?(%{images: [_, _ | _]}), do: true
  defp has_multiple_images?(_), do: false

  # Get display images for gallery
  defp get_display_images(product) do
    if has_storage_images?(product) do
      product_image_ids(product)
    else
      []
    end
  end

  # Get all product Storage image IDs (featured + gallery, no duplicates)
  defp product_image_ids(%{featured_image_id: nil, image_ids: ids}), do: ids || []

  defp product_image_ids(%{featured_image_id: featured, image_ids: ids}) do
    # Ensure featured is first, but don't duplicate if already in ids
    all_ids = ids || []

    if featured in all_ids do
      # Move featured to front if not already there
      [featured | Enum.reject(all_ids, &(&1 == featured))]
    else
      [featured | all_ids]
    end
  end

  defp product_image_ids(_), do: []

  defp get_storage_image_url(nil, _variant), do: placeholder_image_url()

  defp get_storage_image_url(file_id, variant) do
    # Storage.get_file/1 returns %File{} struct or nil (not {:ok, file} tuple)
    case Storage.get_file(file_id) do
      %{id: id} = _file ->
        # Check if requested variant exists, fall back to original if not
        case Storage.get_file_instance_by_name(id, variant) do
          nil ->
            # Variant doesn't exist - try original
            case Storage.get_file_instance_by_name(id, "original") do
              nil -> placeholder_image_url()
              _instance -> URLSigner.signed_url(file_id, "original")
            end

          _instance ->
            URLSigner.signed_url(file_id, variant)
        end

      nil ->
        placeholder_image_url()
    end
  end

  defp placeholder_image_url, do: @placeholder_data_uri

  defp format_price(nil, _currency), do: "-"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end

  # Get option values for a product, with fallback to schema defaults
  # Allows per-product customization of available option values via metadata
  defp get_option_values(product, option) do
    key = option["key"]

    case product.metadata do
      %{"_option_values" => %{^key => values}} when is_list(values) and values != [] ->
        values

      _ ->
        option["options"] || []
    end
  end

  defp discount_percentage(%{price: price, compare_at_price: compare}) when not is_nil(compare) do
    diff = Decimal.sub(compare, price)
    percent = Decimal.div(diff, compare) |> Decimal.mult(100) |> Decimal.round(0)
    Decimal.to_integer(percent)
  end

  defp discount_percentage(_), do: 0

  defp line_total(price, quantity) when not is_nil(price) do
    Decimal.mult(price, quantity)
  end

  defp line_total(_, _), do: Decimal.new("0")

  defp get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{id: _} = user} -> user
      _ -> nil
    end
  end

  # Build specifications list from product options (for display only)
  defp build_specifications(product) do
    schema = Options.get_option_schema_for_product(product)
    metadata = product.metadata || %{}

    schema
    |> Enum.filter(fn opt ->
      value = Map.get(metadata, opt["key"])
      value != nil and value != "" and value != []
    end)
    |> Enum.sort_by(& &1["position"])
    |> Enum.map(fn opt ->
      {opt["label"], Map.get(metadata, opt["key"]), opt["unit"]}
    end)
  end

  # Format specification value for display
  defp format_spec_value(true), do: "Yes"
  defp format_spec_value(false), do: "No"
  defp format_spec_value("true"), do: "Yes"
  defp format_spec_value("false"), do: "No"
  defp format_spec_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp format_spec_value(value) when is_binary(value), do: value
  defp format_spec_value(value) when is_number(value), do: to_string(value)
  defp format_spec_value(value), do: inspect(value)

  # Get current display price
  defp current_display_price(_product, calculated_price, price_affecting_specs)
       when price_affecting_specs != [] do
    calculated_price
  end

  defp current_display_price(%{price: price}, _, _), do: price

  # Get set of missing required spec keys for UI highlighting
  defp get_missing_required_specs(selected_specs, price_affecting_specs) do
    price_affecting_specs
    |> Enum.filter(fn attr -> attr["required"] == true end)
    |> Enum.reject(fn attr ->
      value = Map.get(selected_specs, attr["key"])
      value != nil and value != ""
    end)
    |> Enum.map(& &1["key"])
    |> MapSet.new()
  end

  # Validate that all required specs have been selected
  defp validate_required_specs(selected_specs, price_affecting_specs) do
    missing =
      price_affecting_specs
      |> Enum.filter(fn attr -> attr["required"] == true end)
      |> Enum.reject(fn attr ->
        value = Map.get(selected_specs, attr["key"])
        value != nil and value != ""
      end)
      |> Enum.map(fn attr -> attr["label"] || attr["key"] end)

    case missing do
      [] -> :ok
      labels -> {:error, labels}
    end
  end

  # Build default specs from product metadata, schema defaults, or first option
  defp build_default_specs(price_affecting_specs, metadata) do
    Enum.reduce(price_affecting_specs, %{}, fn attr, acc ->
      key = attr["key"]
      default_value = Map.get(metadata, key)
      schema_default = attr["default"]

      cond do
        # 1. Product metadata override
        default_value && default_value != "" ->
          Map.put(acc, key, default_value)

        # 2. Schema default value
        schema_default && schema_default != "" ->
          Map.put(acc, key, schema_default)

        # 3. First option for required fields
        attr["required"] == true && is_list(attr["options"]) && attr["options"] != [] ->
          [first | _] = attr["options"]
          Map.put(acc, key, first)

        true ->
          acc
      end
    end)
  end

  # Find cart item matching selected specs
  defp find_cart_item_with_specs(user_id, session_id, product_id, selected_specs) do
    case Shop.find_active_cart(user_id: user_id, session_id: session_id) do
      %{items: items} when is_list(items) ->
        Enum.find(items, fn item ->
          item.product_id == product_id &&
            specs_match?(item.selected_specs, selected_specs)
        end)

      _ ->
        nil
    end
  end

  # Safe comparison of specs maps (handles nil and empty maps)
  defp specs_match?(nil, specs) when is_map(specs) and map_size(specs) == 0, do: true
  defp specs_match?(specs, nil) when is_map(specs) and map_size(specs) == 0, do: true
  defp specs_match?(nil, nil), do: true
  defp specs_match?(%{} = a, %{} = b), do: Map.equal?(a, b)
  defp specs_match?(_, _), do: false

  # Calculate total price when a specific option value is selected
  # This shows what the customer would pay if they select this option
  defp calculate_option_total_price(
         product,
         price_affecting_specs,
         current_selected,
         option_key,
         option_value
       ) do
    # Create a temporary specs map with the specific option selected
    temp_specs = Map.put(current_selected, option_key, option_value)

    # Fill in defaults for other required options that aren't selected
    temp_specs =
      Enum.reduce(price_affecting_specs, temp_specs, fn attr, acc ->
        key = attr["key"]

        if Map.has_key?(acc, key) and Map.get(acc, key) != nil and Map.get(acc, key) != "" do
          acc
        else
          # Use first option as default for calculation
          options = attr["options"] || []

          case options do
            [first | _] -> Map.put(acc, key, first)
            _ -> acc
          end
        end
      end)

    Shop.calculate_product_price(product, temp_specs)
  end

  # Determine language from URL params - use locale param if present, otherwise default
  # This ensures non-localized routes (/shop/...) always use default language,
  # regardless of what's stored in session from previous visits
  defp get_language_from_params_or_default(%{"locale" => locale}) when is_binary(locale) do
    # Localized route - use the locale from URL
    DialectMapper.resolve_dialect(locale, nil)
  end

  defp get_language_from_params_or_default(_params) do
    # Non-localized route - always use default language
    Translations.default_language()
  end
end
