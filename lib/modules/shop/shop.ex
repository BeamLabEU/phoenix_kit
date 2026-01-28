defmodule PhoenixKit.Modules.Shop do
  @moduledoc """
  E-commerce Shop Module for PhoenixKit.

  Provides comprehensive e-commerce functionality including products, categories,
  options-based pricing, and cart management.

  ## Features

  - **Products**: Physical and digital products with JSONB flexibility
  - **Categories**: Hierarchical product categories
  - **Options**: Product options with dynamic pricing (fixed or percent modifiers)
  - **Inventory**: Stock tracking with reservation system
  - **Cart**: Persistent shopping cart (DB-backed for cross-device support)

  ## System Enable/Disable

      # Check if shop is enabled
      PhoenixKit.Modules.Shop.enabled?()

      # Enable/disable shop system
      PhoenixKit.Modules.Shop.enable_system()
      PhoenixKit.Modules.Shop.disable_system()

  ## Integration with Billing

  Shop integrates with the Billing module for orders and payments.
  Order line_items include shop metadata for product tracking.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Shop.Cart
  alias PhoenixKit.Modules.Shop.CartItem
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.Events
  alias PhoenixKit.Modules.Shop.ImportConfig
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.Options.MetadataValidator
  alias PhoenixKit.Modules.Shop.Product
  alias PhoenixKit.Modules.Shop.ShippingMethod
  alias PhoenixKit.Modules.Shop.SlugResolver
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  # ============================================
  # SYSTEM ENABLE/DISABLE
  # ============================================

  @doc """
  Checks if the shop system is enabled.
  """
  def enabled? do
    Settings.get_setting_cached("shop_enabled", "false") == "true"
  end

  @doc """
  Enables the shop system.
  """
  def enable_system do
    Settings.update_setting("shop_enabled", "true")
    refresh_dashboard_tabs()
  end

  @doc """
  Disables the shop system.
  """
  def disable_system do
    Settings.update_setting("shop_enabled", "false")
    refresh_dashboard_tabs()
  end

  defp refresh_dashboard_tabs do
    if Code.ensure_loaded?(PhoenixKit.Dashboard.Registry) and
         PhoenixKit.Dashboard.Registry.initialized?() do
      PhoenixKit.Dashboard.Registry.load_defaults()
    end
  end

  @doc """
  Returns the current shop configuration.
  """
  def get_config do
    %{
      enabled: enabled?(),
      currency: get_default_currency_code(),
      tax_enabled: Settings.get_setting_cached("shop_tax_enabled", "true") == "true",
      tax_rate: Settings.get_setting_cached("shop_tax_rate", "20"),
      inventory_tracking:
        Settings.get_setting_cached("shop_inventory_tracking", "true") == "true",
      allow_price_override:
        Settings.get_setting_cached("shop_allow_price_override", "false") == "true",
      products_count: count_products(),
      categories_count: count_categories()
    }
  end

  @doc """
  Returns dashboard statistics for the shop.
  """
  def get_dashboard_stats do
    %{
      total_products: count_products(),
      active_products: count_products_by_status("active"),
      draft_products: count_products_by_status("draft"),
      archived_products: count_products_by_status("archived"),
      total_categories: count_categories(),
      physical_products: count_products_by_type("physical"),
      digital_products: count_products_by_type("digital"),
      default_currency: get_default_currency_code()
    }
  end

  @doc """
  Gets the default currency code from Billing module.
  Falls back to "USD" if Billing has no default currency configured.
  """
  def get_default_currency_code do
    case Billing.get_default_currency() do
      %{code: code} -> code
      nil -> "USD"
    end
  end

  @doc """
  Gets the default currency struct from Billing module.
  """
  def get_default_currency do
    Billing.get_default_currency()
  end

  # ============================================
  # PRODUCTS
  # ============================================

  @doc """
  Lists all products with optional filters.

  ## Options
  - `:status` - Filter by status (draft, active, archived)
  - `:product_type` - Filter by type (physical, digital)
  - `:category_id` - Filter by category
  - `:search` - Search in title and description
  - `:page` - Page number
  - `:per_page` - Items per page
  - `:preload` - Associations to preload
  """
  def list_products(opts \\ []) do
    Product
    |> apply_product_filters(opts)
    |> order_by([p], desc: p.inserted_at)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  @doc """
  Lists products with count for pagination.
  """
  def list_products_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page

    base_query =
      Product
      |> apply_product_filters(opts)

    total = repo().aggregate(base_query, :count, :id)

    products =
      base_query
      |> order_by([p], desc: p.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> maybe_preload(Keyword.get(opts, :preload, [:category]))
      |> repo().all()

    {products, total}
  end

  @doc """
  Lists products by their IDs.

  Returns products in the order of the provided IDs.
  """
  def list_products_by_ids([]), do: []

  def list_products_by_ids(ids) when is_list(ids) do
    Product
    |> where([p], p.id in ^ids)
    |> repo().all()
  end

  @doc """
  Gets a product by ID.
  """
  def get_product(id, opts \\ []) do
    Product
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().get(id)
  end

  @doc """
  Gets a product by ID, raises if not found.
  """
  def get_product!(id, opts \\ []) do
    Product
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().get!(id)
  end

  @doc """
  Gets a product by slug.

  Supports localized slugs stored as JSONB maps.

  ## Options

    - `:language` - Language code for slug lookup (default: system default)
    - `:preload` - Associations to preload

  ## Examples

      iex> get_product_by_slug("planter")
      %Product{}

      iex> get_product_by_slug("kashpo", language: "ru")
      %Product{}
  """
  def get_product_by_slug(slug, opts \\ []) do
    language = Keyword.get(opts, :language, Translations.default_language())
    preload = Keyword.get(opts, :preload, [])

    case SlugResolver.find_product_by_slug(slug, language, preload: preload) do
      {:ok, product} -> product
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Creates a new product.

  Automatically normalizes metadata (price modifiers, option values)
  before saving to ensure consistent storage format.
  """
  def create_product(attrs) do
    attrs = MetadataValidator.normalize_product_attrs(attrs)

    %Product{}
    |> Product.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a product.

  Automatically normalizes metadata (price modifiers, option values)
  before saving to ensure consistent storage format.
  """
  def update_product(%Product{} = product, attrs) do
    attrs = MetadataValidator.normalize_product_attrs(attrs)

    product
    |> Product.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a product.
  """
  def delete_product(%Product{} = product) do
    repo().delete(product)
  end

  @doc """
  Returns a changeset for product form.
  """
  def change_product(%Product{} = product, attrs \\ %{}) do
    Product.changeset(product, attrs)
  end

  @doc """
  Bulk update product status.
  Returns count of updated products.
  """
  def bulk_update_product_status(ids, status) when is_list(ids) and is_binary(status) do
    {count, _} =
      Product
      |> where([p], p.id in ^ids)
      |> repo().update_all(set: [status: status, updated_at: DateTime.utc_now()])

    count
  end

  @doc """
  Bulk update product category.
  Returns count of updated products.
  """
  def bulk_update_product_category(ids, category_id) when is_list(ids) do
    {count, _} =
      Product
      |> where([p], p.id in ^ids)
      |> repo().update_all(set: [category_id: category_id, updated_at: DateTime.utc_now()])

    count
  end

  @doc """
  Bulk delete products.
  Returns count of deleted products.
  """
  def bulk_delete_products(ids) when is_list(ids) do
    {count, _} =
      Product
      |> where([p], p.id in ^ids)
      |> repo().delete_all()

    count
  end

  # ============================================
  # OPTIONS-BASED PRICING
  # ============================================

  @doc """
  Calculates the final price for a product based on selected specifications.

  Applies option price modifiers (fixed and percent) to the base price.
  Fixed modifiers are applied first, then percent modifiers.

  ## Example

      product = %Product{price: Decimal.new("20.00")}
      selected_specs = %{"material" => "PETG", "finish" => "Premium"}

      # If PETG has +$10 fixed and Premium has +20% percent:
      calculate_product_price(product, selected_specs)
      # => Decimal.new("36.00")  # ($20 + $10) * 1.20
  """
  def calculate_product_price(%Product{} = product, selected_specs) when is_map(selected_specs) do
    base_price = product.price || Decimal.new("0")
    metadata = product.metadata || %{}

    # Get price-affecting options for this product
    price_affecting_specs = Options.get_price_affecting_specs_for_product(product)

    # Calculate final price with fixed and percent modifiers
    # Pass metadata to apply custom per-product price overrides
    Options.calculate_final_price(price_affecting_specs, selected_specs, base_price, metadata)
  end

  def calculate_product_price(%Product{} = product, _) do
    product.price || Decimal.new("0")
  end

  @doc """
  Gets the price range for a product based on option modifiers.

  Returns `{min_price, max_price}` where:
  - min_price = minimum possible price (base + min modifiers)
  - max_price = maximum possible price (base + max modifiers)

  ## Example

      # Product with base $20, material options (0, +5, +10), finish options (0%, +20%)
      get_price_range(product)
      # => {Decimal.new("20.00"), Decimal.new("36.00")}
  """
  def get_price_range(%Product{} = product) do
    base_price = product.price || Decimal.new("0")
    metadata = product.metadata || %{}

    # Get price-affecting options
    price_affecting_specs = Options.get_price_affecting_specs_for_product(product)

    if Enum.empty?(price_affecting_specs) do
      {base_price, base_price}
    else
      # Pass metadata to apply custom per-product price overrides
      Options.get_price_range(price_affecting_specs, base_price, metadata)
    end
  end

  @doc """
  Formats the product price for catalog display.

  Returns:
  - "$19.99" for products without price-affecting options
  - "From $19.99" if options have different price modifiers
  - "$19.99 - $38.00" for range display
  """
  def format_product_price(%Product{} = product, currency, style \\ :from) do
    {min_price, max_price} = get_price_range(product)

    format_fn = fn price ->
      case currency do
        %{} = c -> Currency.format_amount(price, c)
        nil -> "$#{Decimal.round(price, 2)}"
      end
    end

    if Decimal.compare(min_price, max_price) == :eq do
      format_fn.(min_price)
    else
      case style do
        :from -> "From #{format_fn.(min_price)}"
        :range -> "#{format_fn.(min_price)} - #{format_fn.(max_price)}"
      end
    end
  end

  @doc """
  Gets price-affecting options for a product.

  Convenience wrapper around `Options.get_price_affecting_specs_for_product/1`.
  """
  def get_price_affecting_specs(%Product{} = product) do
    Options.get_price_affecting_specs_for_product(product)
  end

  @doc """
  Gets all selectable options for a product (for UI display).

  Returns all select/multiselect options regardless of whether they affect price.
  This includes options like Color that may not have price modifiers but should
  still be selectable in the UI.

  Convenience wrapper around `Options.get_selectable_specs_for_product/1`.
  """
  def get_selectable_specs(%Product{} = product) do
    Options.get_selectable_specs_for_product(product)
  end

  # ============================================
  # CATEGORIES
  # ============================================

  @doc """
  Lists all categories.

  ## Options
  - `:parent_id` - Filter by parent (nil for root categories)
  - `:status` - Filter by status: "active", "hidden", "archived", or list of statuses
  - `:search` - Search in name
  - `:preload` - Associations to preload
  """
  def list_categories(opts \\ []) do
    Category
    |> apply_category_filters(opts)
    |> order_by([c], [c.position, c.name])
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  @doc """
  Lists root categories (no parent).
  """
  def list_root_categories(opts \\ []) do
    list_categories(Keyword.put(opts, :parent_id, nil))
  end

  @doc """
  Lists active categories only (for storefront display).
  """
  def list_active_categories(opts \\ []) do
    list_categories(Keyword.put(opts, :status, "active"))
  end

  @doc """
  Lists categories visible in storefront navigation/menu.
  Only active categories appear in menus.
  Semantic alias for list_active_categories/1.
  """
  def list_menu_categories(opts \\ []) do
    list_active_categories(opts)
  end

  @doc """
  Lists categories whose products are visible in storefront.
  Includes both active and unlisted categories.
  Use for product filtering, not for navigation menus.
  """
  def list_visible_categories(opts \\ []) do
    list_categories(Keyword.put(opts, :status, ["active", "unlisted"]))
  end

  @doc """
  Lists categories with count for pagination.
  """
  def list_categories_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page

    base_query =
      Category
      |> apply_category_filters(opts)

    total = repo().aggregate(base_query, :count, :id)

    categories =
      base_query
      |> order_by([c], [c.position, c.name])
      |> limit(^per_page)
      |> offset(^offset)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().all()

    {categories, total}
  end

  @doc """
  Gets a category by ID.
  """
  def get_category(id, opts \\ []) do
    Category
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().get(id)
  end

  @doc """
  Gets a category by ID, raises if not found.
  """
  def get_category!(id, opts \\ []) do
    Category
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().get!(id)
  end

  @doc """
  Gets a category by slug.

  Supports localized slugs stored as JSONB maps.

  ## Options

    - `:language` - Language code for slug lookup (default: system default)
    - `:preload` - Associations to preload

  ## Examples

      iex> get_category_by_slug("planters")
      %Category{}

      iex> get_category_by_slug("kashpo", language: "ru")
      %Category{}
  """
  def get_category_by_slug(slug, opts \\ []) do
    language = Keyword.get(opts, :language, Translations.default_language())
    preload = Keyword.get(opts, :preload, [])

    case SlugResolver.find_category_by_slug(slug, language, preload: preload) do
      {:ok, category} -> category
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Creates a new category.
  """
  def create_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a category.
  """
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a category.
  """
  def delete_category(%Category{} = category) do
    repo().delete(category)
  end

  @doc """
  Returns a changeset for category form.
  """
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  @doc """
  Returns categories as options for select input.
  Returns list of {localized_name, id} tuples.
  """
  def category_options do
    default_lang = Translations.default_language()

    Category
    |> order_by([c], [c.position, c.name])
    |> repo().all()
    |> Enum.map(fn cat ->
      {Translations.get(cat, :name, default_lang), cat.id}
    end)
  end

  # ============================================
  # SHIPPING METHODS
  # ============================================

  @doc """
  Lists all shipping methods.

  ## Options
  - `:active` - Filter by active status
  - `:country` - Filter by country availability
  """
  def list_shipping_methods(opts \\ []) do
    ShippingMethod
    |> filter_shipping_by_active(Keyword.get(opts, :active))
    |> order_by([s], [s.position, s.name])
    |> repo().all()
  end

  @doc """
  Gets available shipping methods for a cart.
  Filters by weight, subtotal, and country.
  """
  def get_available_shipping_methods(%Cart{} = cart) do
    ShippingMethod
    |> where([s], s.active == true)
    |> order_by([s], [s.position, s.name])
    |> repo().all()
    |> Enum.filter(fn method ->
      ShippingMethod.available_for?(method, %{
        weight_grams: cart.total_weight_grams || 0,
        subtotal: cart.subtotal || Decimal.new("0"),
        country: cart.shipping_country
      })
    end)
  end

  @doc """
  Gets a shipping method by ID.
  """
  def get_shipping_method(id) do
    repo().get(ShippingMethod, id)
  end

  @doc """
  Gets a shipping method by ID, raises if not found.
  """
  def get_shipping_method!(id) do
    repo().get!(ShippingMethod, id)
  end

  @doc """
  Gets a shipping method by slug.
  """
  def get_shipping_method_by_slug(slug) do
    ShippingMethod
    |> where([s], s.slug == ^slug)
    |> repo().one()
  end

  @doc """
  Creates a new shipping method.
  """
  def create_shipping_method(attrs) do
    %ShippingMethod{}
    |> ShippingMethod.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a shipping method.
  """
  def update_shipping_method(%ShippingMethod{} = method, attrs) do
    method
    |> ShippingMethod.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a shipping method.
  """
  def delete_shipping_method(%ShippingMethod{} = method) do
    repo().delete(method)
  end

  @doc """
  Returns a changeset for shipping method form.
  """
  def change_shipping_method(%ShippingMethod{} = method, attrs \\ %{}) do
    ShippingMethod.changeset(method, attrs)
  end

  # ============================================
  # CARTS
  # ============================================

  @doc """
  Gets or creates a cart for the current user/session.

  ## Options
  - `:user_id` - User ID (for authenticated users)
  - `:session_id` - Session ID (for guests)
  """
  def get_or_create_cart(opts) do
    user_id = Keyword.get(opts, :user_id)
    session_id = Keyword.get(opts, :session_id)

    case find_active_cart(user_id: user_id, session_id: session_id) do
      nil -> create_cart(user_id: user_id, session_id: session_id)
      cart -> {:ok, cart}
    end
  end

  @doc """
  Finds active cart by user_id or session_id.

  Search priority:
  1. If user_id is provided, search by user_id first
  2. If not found and session_id is provided, search by session_id (handles guest->login transition)
  3. If only session_id is provided, search by session_id with no user_id
  """
  def find_active_cart(opts) do
    user_id = Keyword.get(opts, :user_id)
    session_id = Keyword.get(opts, :session_id)

    base_query =
      Cart
      |> where([c], c.status == "active")
      |> preload([:items, :shipping_method, :payment_option])

    cond do
      not is_nil(user_id) ->
        # First try to find by user_id
        case base_query |> where([c], c.user_id == ^user_id) |> repo().one() do
          nil when not is_nil(session_id) ->
            # Fallback: try session_id (cart created before login)
            base_query |> where([c], c.session_id == ^session_id) |> repo().one()

          result ->
            result
        end

      not is_nil(session_id) ->
        # Guest user - search by session_id only
        base_query
        |> where([c], c.session_id == ^session_id and is_nil(c.user_id))
        |> repo().one()

      true ->
        # No identity provided
        nil
    end
  end

  @doc """
  Creates a new cart.
  """
  def create_cart(opts) do
    attrs = %{
      user_id: Keyword.get(opts, :user_id),
      session_id: Keyword.get(opts, :session_id),
      currency: get_default_currency_code()
    }

    case %Cart{} |> Cart.changeset(attrs) |> repo().insert() do
      {:ok, cart} -> {:ok, repo().preload(cart, [:items, :shipping_method])}
      error -> error
    end
  end

  @doc """
  Gets a cart by ID with items preloaded.
  """
  def get_cart(id) do
    Cart
    |> preload([:items, :shipping_method, :payment_option])
    |> repo().get(id)
  end

  @doc """
  Gets a cart by ID, raises if not found.
  """
  def get_cart!(id) do
    Cart
    |> preload([:items, :shipping_method, :payment_option])
    |> repo().get!(id)
  end

  @doc """
  Adds item to cart.

  ## Options
  - `:selected_specs` - Map of selected specifications (for dynamic pricing)

  ## Examples

      # Add simple product
      add_to_cart(cart, product, 2)

      # Add product with specification-based pricing
      add_to_cart(cart, product, 1, selected_specs: %{"material" => "PETG", "color" => "Gold"})
  """
  def add_to_cart(cart, product, quantity \\ 1, opts \\ [])

  def add_to_cart(%Cart{} = cart, %Product{} = product, quantity, opts) when is_list(opts) do
    selected_specs = Keyword.get(opts, :selected_specs, %{})

    if map_size(selected_specs) > 0 do
      add_product_with_specs_to_cart(cart, product, quantity, selected_specs)
    else
      add_simple_product_to_cart(cart, product, quantity)
    end
  end

  def add_to_cart(%Cart{} = cart, %Product{} = product, quantity, _opts)
      when is_integer(quantity) do
    add_simple_product_to_cart(cart, product, quantity)
  end

  defp add_simple_product_to_cart(cart, product, quantity) do
    result =
      repo().transaction(fn ->
        # Check if product already in cart (without specs)
        existing = find_cart_item_by_specs(cart.id, product.id, %{})

        item =
          case existing do
            nil ->
              # Create new item
              attrs = CartItem.from_product(product, quantity) |> Map.put(:cart_id, cart.id)
              %CartItem{} |> CartItem.changeset(attrs) |> repo().insert!()

            item ->
              # Update quantity
              new_qty = item.quantity + quantity
              item |> CartItem.changeset(%{quantity: new_qty}) |> repo().update!()
          end

        # Recalculate totals
        updated_cart = recalculate_cart_totals!(cart)
        {updated_cart, item}
      end)

    case result do
      {:ok, {updated_cart, item}} ->
        Events.broadcast_item_added(updated_cart, item)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  defp add_product_with_specs_to_cart(cart, product, quantity, selected_specs) do
    # Calculate price with spec modifiers
    calculated_price = calculate_product_price(product, selected_specs)

    result =
      repo().transaction(fn ->
        # Check if same product with same specs already in cart
        existing = find_cart_item_by_specs(cart.id, product.id, selected_specs)

        item =
          case existing do
            nil ->
              # Create new item with specs and calculated price
              attrs =
                CartItem.from_product(product, quantity)
                |> Map.put(:cart_id, cart.id)
                |> Map.put(:unit_price, calculated_price)
                |> Map.put(:selected_specs, selected_specs)

              %CartItem{} |> CartItem.changeset(attrs) |> repo().insert!()

            item ->
              # Update quantity (price already frozen from first add)
              new_qty = item.quantity + quantity
              item |> CartItem.changeset(%{quantity: new_qty}) |> repo().update!()
          end

        # Recalculate totals
        updated_cart = recalculate_cart_totals!(cart)
        {updated_cart, item}
      end)

    case result do
      {:ok, {updated_cart, item}} ->
        Events.broadcast_item_added(updated_cart, item)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Updates item quantity in cart.
  """
  def update_cart_item(%CartItem{} = item, quantity) when quantity > 0 do
    result =
      repo().transaction(fn ->
        updated_item =
          item
          |> CartItem.changeset(%{quantity: quantity})
          |> repo().update!()

        cart = repo().get!(Cart, item.cart_id)
        updated_cart = recalculate_cart_totals!(cart)
        {updated_cart, updated_item}
      end)

    case result do
      {:ok, {updated_cart, updated_item}} ->
        Events.broadcast_quantity_updated(updated_cart, updated_item)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  def update_cart_item(%CartItem{} = item, 0), do: remove_from_cart(item)

  @doc """
  Removes item from cart.
  """
  def remove_from_cart(%CartItem{} = item) do
    item_id = item.id

    result =
      repo().transaction(fn ->
        cart_id = item.cart_id
        repo().delete!(item)

        cart = repo().get!(Cart, cart_id)
        recalculate_cart_totals!(cart)
      end)

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_item_removed(updated_cart, item_id)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Clears all items from cart.
  """
  def clear_cart(%Cart{} = cart) do
    result =
      repo().transaction(fn ->
        CartItem
        |> where([i], i.cart_id == ^cart.id)
        |> repo().delete_all()

        recalculate_cart_totals!(cart)
      end)

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_cart_cleared(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Sets the shipping country for the cart.
  """
  def set_cart_shipping_country(%Cart{} = cart, country) do
    cart
    |> Cart.shipping_changeset(%{shipping_country: country})
    |> repo().update()
  end

  @doc """
  Sets shipping method for cart.
  """
  def set_cart_shipping(%Cart{} = cart, %ShippingMethod{} = method, country) do
    shipping_cost = ShippingMethod.calculate_cost(method, cart.subtotal || Decimal.new("0"))

    result =
      repo().transaction(fn ->
        updated_cart =
          cart
          |> Cart.shipping_changeset(%{
            shipping_method_id: method.id,
            shipping_country: country,
            shipping_amount: shipping_cost
          })
          |> repo().update!()

        recalculate_cart_totals!(updated_cart)
      end)

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_shipping_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Sets payment option for cart.
  """
  def set_cart_payment_option(%Cart{} = cart, payment_option_id)
      when is_integer(payment_option_id) do
    result =
      cart
      |> Cart.payment_changeset(%{payment_option_id: payment_option_id})
      |> repo().update()

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_payment_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  def set_cart_payment_option(%Cart{} = cart, nil) do
    result =
      cart
      |> Cart.payment_changeset(%{payment_option_id: nil})
      |> repo().update()

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_payment_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Auto-selects payment option if only one is available.

  If cart already has a payment option selected, does nothing.
  If only one option is available, selects it.
  """
  def auto_select_payment_option(%Cart{} = cart, payment_options) do
    cond do
      # Already has payment option selected
      not is_nil(cart.payment_option_id) ->
        {:ok, cart}

      # No options available
      payment_options == [] ->
        {:ok, cart}

      # Only one option available - auto-select it
      length(payment_options) == 1 ->
        option = hd(payment_options)
        set_cart_payment_option(cart, option.id)

      # Multiple options - user must choose
      true ->
        {:ok, cart}
    end
  end

  @doc """
  Auto-selects the cheapest available shipping method for a cart.

  If cart already has a shipping method selected, does nothing.
  If only one method is available, selects it.
  If multiple methods are available, selects the cheapest one.
  """
  def auto_select_shipping_method(%Cart{} = cart, shipping_methods) do
    cond do
      # Already has shipping method selected
      not is_nil(cart.shipping_method_id) ->
        {:ok, cart}

      # No items in cart
      cart.items == [] or is_nil(cart.items) ->
        {:ok, cart}

      # No shipping methods available
      shipping_methods == [] ->
        {:ok, cart}

      # One or more methods available - select cheapest
      true ->
        cheapest = find_cheapest_shipping_method(shipping_methods, cart.subtotal)
        set_cart_shipping(cart, cheapest, nil)
    end
  end

  defp find_cheapest_shipping_method(methods, subtotal) do
    subtotal = subtotal || Decimal.new("0")

    methods
    |> Enum.min_by(fn method ->
      if ShippingMethod.free_for?(method, subtotal) do
        Decimal.new("0")
      else
        method.price || Decimal.new("999999")
      end
    end)
  end

  @doc """
  Merges guest cart into user cart after login.
  """
  def merge_guest_cart(session_id, user_id) do
    guest_cart = find_active_cart(session_id: session_id)
    user_cart = find_active_cart(user_id: user_id)

    case {guest_cart, user_cart} do
      {nil, _} ->
        {:ok, user_cart}

      {guest, nil} ->
        # Convert guest cart to user cart
        guest
        |> Cart.changeset(%{user_id: user_id, session_id: nil, expires_at: nil})
        |> repo().update()

      {guest, user} ->
        # Merge items into user cart
        repo().transaction(fn ->
          # Move items from guest to user cart
          for item <- guest.items do
            # Find existing cart item with same product and specs
            existing =
              find_cart_item_by_specs(user.id, item.product_id, item.selected_specs || %{})

            case existing do
              nil ->
                attrs =
                  Map.from_struct(item)
                  |> Map.drop([:__meta__, :id, :uuid, :cart, :product, :inserted_at, :updated_at])
                  |> Map.put(:cart_id, user.id)

                %CartItem{}
                |> CartItem.changeset(attrs)
                |> repo().insert!()

              existing_item ->
                new_qty = existing_item.quantity + item.quantity
                existing_item |> CartItem.changeset(%{quantity: new_qty}) |> repo().update!()
            end
          end

          # Mark guest cart as merged
          guest
          |> Cart.status_changeset("merged", %{merged_into_cart_id: user.id})
          |> repo().update!()

          # Recalculate user cart
          recalculate_cart_totals!(user)

          repo().get!(Cart, user.id)
          |> repo().preload([:items, :shipping_method, :payment_option])
        end)
    end
  end

  @doc """
  Lists carts with filters for admin.
  """
  def list_carts_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    status = Keyword.get(opts, :status)
    search = Keyword.get(opts, :search)

    base_query = Cart

    base_query =
      if status && status != "" do
        where(base_query, [c], c.status == ^status)
      else
        base_query
      end

    base_query =
      if search && search != "" do
        search_term = "%#{search}%"

        base_query
        |> join(:left, [c], u in assoc(c, :user))
        |> where([c, u], ilike(u.email, ^search_term) or c.session_id == ^search)
      else
        base_query
      end

    total = repo().aggregate(base_query, :count, :id)

    carts =
      base_query
      |> order_by([c], desc: c.updated_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload([:user, :items])
      |> repo().all()

    {carts, total}
  end

  @doc """
  Marks abandoned carts (no activity for X days).
  """
  def mark_abandoned_carts(days \\ 7) do
    threshold = DateTime.utc_now() |> DateTime.add(-days, :day)

    {count, _} =
      Cart
      |> where([c], c.status == "active")
      |> where([c], c.updated_at < ^threshold)
      |> repo().update_all(set: [status: "abandoned"])

    {:ok, count}
  end

  @doc """
  Expires old guest carts.
  """
  def expire_old_carts do
    now = DateTime.utc_now()

    {count, _} =
      Cart
      |> where([c], c.status == "active")
      |> where([c], not is_nil(c.expires_at))
      |> where([c], c.expires_at < ^now)
      |> repo().update_all(set: [status: "expired"])

    {:ok, count}
  end

  @doc """
  Counts active carts.
  """
  def count_active_carts do
    Cart
    |> where([c], c.status == "active")
    |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  # ============================================
  # CHECKOUT / ORDER CONVERSION
  # ============================================

  @doc """
  Converts a cart to a Billing.Order.

  Takes an active cart with items and creates an Order with:
  - All cart items as line_items
  - Shipping as additional line item (if selected)
  - Billing profile snapshot (from profile_id or direct billing_data)
  - Cart marked as "converted"

  For guest checkout (no user_id on cart):
  - Creates a guest user via `Auth.create_guest_user/1`
  - Guest user has `confirmed_at = nil` until email verification
  - Sends confirmation email automatically
  - Order remains in "pending" status

  ## Options

  - `billing_profile_id: id` - Use existing billing profile (for logged-in users)
  - `billing_data: map` - Use direct billing data (for guest checkout)

  ## Returns

  - `{:ok, order}` - Order created successfully
  - `{:error, :cart_not_active}` - Cart is not active
  - `{:error, :cart_empty}` - Cart has no items
  - `{:error, :no_shipping_method}` - No shipping method selected
  - `{:error, :email_already_registered}` - Guest email belongs to confirmed user
  - `{:error, changeset}` - Validation errors
  """
  def convert_cart_to_order(%Cart{} = cart, opts) when is_list(opts) do
    cart = get_cart!(cart.id)

    with :ok <- validate_cart_convertible(cart),
         {:ok, user_id, cart} <- resolve_checkout_user(cart, opts),
         line_items <- build_order_line_items(cart),
         order_attrs <- build_order_attrs(cart, line_items, opts),
         {:ok, order} <- do_create_order(user_id, order_attrs),
         {:ok, _cart} <- mark_cart_converted(cart, order.id),
         :ok <- maybe_send_guest_confirmation(user_id) do
      {:ok, order}
    end
  end

  # Legacy support: convert_cart_to_order(cart, billing_profile_id)
  def convert_cart_to_order(%Cart{} = cart, billing_profile_id)
      when is_integer(billing_profile_id) do
    convert_cart_to_order(cart, billing_profile_id: billing_profile_id)
  end

  defp validate_cart_convertible(%Cart{} = cart) do
    cond do
      cart.status != "active" -> {:error, :cart_not_active}
      Enum.empty?(cart.items) -> {:error, :cart_empty}
      is_nil(cart.shipping_method_id) -> {:error, :no_shipping_method}
      true -> :ok
    end
  end

  defp build_order_line_items(%Cart{} = cart) do
    product_items =
      Enum.map(cart.items, fn item ->
        %{
          "name" => item.product_title,
          "description" => format_item_description(item),
          "selected_specs" => item.selected_specs || %{},
          "quantity" => item.quantity,
          "unit_price" => Decimal.to_string(item.unit_price),
          "total" => Decimal.to_string(item.line_total),
          "sku" => item.product_sku,
          "type" => "product"
        }
      end)

    shipping_item =
      if cart.shipping_method do
        [
          %{
            "name" => "Shipping: #{cart.shipping_method.name}",
            "description" => cart.shipping_method.description || "",
            "quantity" => 1,
            "unit_price" => Decimal.to_string(cart.shipping_amount || Decimal.new(0)),
            "total" => Decimal.to_string(cart.shipping_amount || Decimal.new(0)),
            "type" => "shipping"
          }
        ]
      else
        []
      end

    product_items ++ shipping_item
  end

  defp build_order_attrs(%Cart{} = cart, line_items, opts) do
    billing_profile_id = Keyword.get(opts, :billing_profile_id)
    billing_data = Keyword.get(opts, :billing_data)

    # Get shipping country from billing data or cart
    shipping_country = get_shipping_country(billing_profile_id, billing_data, cart)

    # Use string keys to match Billing.maybe_set_order_number behavior
    base_attrs = %{
      "currency" => cart.currency,
      "line_items" => line_items,
      "subtotal" => cart.subtotal,
      "tax_amount" => cart.tax_amount || Decimal.new(0),
      "tax_rate" => Decimal.new(0),
      "discount_amount" => cart.discount_amount || Decimal.new(0),
      "discount_code" => cart.discount_code,
      "total" => cart.total,
      "status" => "pending",
      "metadata" => %{
        "source" => "shop_checkout",
        "cart_id" => cart.id,
        "shipping_country" => shipping_country,
        "shipping_method_id" => cart.shipping_method_id
      }
    }

    cond do
      # Logged-in user with billing profile
      not is_nil(billing_profile_id) ->
        Map.put(base_attrs, "billing_profile_id", billing_profile_id)

      # Guest checkout with billing data - clean up _unused_ keys from LiveView
      is_map(billing_data) ->
        cleaned_billing_data = clean_billing_data(billing_data)
        Map.put(base_attrs, "billing_snapshot", cleaned_billing_data)

      true ->
        base_attrs
    end
  end

  # Get shipping country from billing profile, billing data, or cart
  defp get_shipping_country(billing_profile_id, _billing_data, cart)
       when not is_nil(billing_profile_id) do
    case Billing.get_billing_profile(billing_profile_id) do
      %{country: country} when is_binary(country) -> country
      _ -> cart.shipping_country
    end
  end

  defp get_shipping_country(_billing_profile_id, billing_data, cart) when is_map(billing_data) do
    billing_data["country"] || cart.shipping_country
  end

  defp get_shipping_country(_billing_profile_id, _billing_data, cart) do
    cart.shipping_country
  end

  # Remove _unused_ prefixed keys that Phoenix LiveView adds
  defp clean_billing_data(data) when is_map(data) do
    data
    |> Enum.reject(fn {key, _value} ->
      key_str = if is_atom(key), do: Atom.to_string(key), else: key
      String.starts_with?(key_str, "_unused_")
    end)
    |> Map.new()
  end

  # Resolve user for checkout: logged-in user or create guest user
  defp resolve_checkout_user(%Cart{user_id: user_id} = cart, _opts) when not is_nil(user_id) do
    # Cart already has a user (logged-in checkout)
    {:ok, user_id, cart}
  end

  defp resolve_checkout_user(%Cart{user_id: nil} = cart, opts) do
    # Check if logged-in user_id was passed in opts (user is logged in but has guest cart)
    case Keyword.get(opts, :user_id) do
      user_id when not is_nil(user_id) ->
        resolve_logged_in_user_with_guest_cart(cart, user_id)

      nil ->
        resolve_guest_checkout(cart, opts)
    end
  end

  defp resolve_logged_in_user_with_guest_cart(cart, user_id) do
    case assign_cart_to_user(cart, user_id) do
      {:ok, updated_cart} -> {:ok, user_id, updated_cart}
      {:error, _} -> {:ok, user_id, cart}
    end
  end

  defp resolve_guest_checkout(cart, opts) do
    billing_data = Keyword.get(opts, :billing_data)

    if valid_billing_data?(billing_data) do
      create_guest_user_and_assign_cart(cart, billing_data)
    else
      {:ok, nil, cart}
    end
  end

  defp valid_billing_data?(data), do: is_map(data) and Map.has_key?(data, "email")

  defp create_guest_user_and_assign_cart(cart, billing_data) do
    case Auth.create_guest_user(%{
           email: billing_data["email"],
           first_name: billing_data["first_name"],
           last_name: billing_data["last_name"]
         }) do
      {:ok, user} ->
        assign_cart_and_return(cart, user.id)

      {:error, :email_exists_unconfirmed, user} ->
        assign_cart_and_return(cart, user.id)

      {:error, :email_exists_confirmed} ->
        {:error, :email_already_registered}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp assign_cart_and_return(cart, user_id) do
    case assign_cart_to_user(cart, user_id) do
      {:ok, updated_cart} -> {:ok, user_id, updated_cart}
      {:error, _} -> {:ok, user_id, cart}
    end
  end

  # Assign cart to user (for guest -> user conversion)
  defp assign_cart_to_user(%Cart{} = cart, user_id) do
    cart
    |> Cart.changeset(%{user_id: user_id, session_id: nil})
    |> repo().update()
  end

  # Create order with or without user
  defp do_create_order(nil, order_attrs) do
    Billing.create_order(order_attrs)
  end

  defp do_create_order(user_id, order_attrs) do
    Billing.create_order(user_id, order_attrs)
  end

  # Send confirmation email to guest users
  defp maybe_send_guest_confirmation(nil), do: :ok

  defp maybe_send_guest_confirmation(user_id) do
    case Auth.get_user(user_id) do
      %{confirmed_at: nil} = user ->
        # Guest user - send confirmation email
        Auth.deliver_user_confirmation_instructions(
          user,
          &Routes.url("/users/confirm/#{&1}")
        )

        :ok

      _ ->
        # Already confirmed user - no action needed
        :ok
    end
  end

  defp mark_cart_converted(%Cart{} = cart, order_id) do
    cart
    |> Cart.status_changeset("converted", %{
      converted_at: DateTime.utc_now(),
      metadata: Map.put(cart.metadata || %{}, "order_id", order_id)
    })
    |> repo().update()
  end

  # ============================================
  # PRIVATE HELPERS
  # ============================================

  # Format cart item description including selected_specs
  defp format_item_description(%CartItem{product_slug: slug, selected_specs: specs})
       when specs == %{} or is_nil(specs) do
    slug
  end

  defp format_item_description(%CartItem{product_slug: slug, selected_specs: specs}) do
    specs_text =
      Enum.map_join(specs, ", ", fn {key, value} -> "#{humanize_key(key)}: #{value}" end)

    "#{slug} (#{specs_text})"
  end

  # Convert key to human-readable format: "material_type" -> "Material Type"
  defp humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_key(key), do: to_string(key)

  defp count_products do
    Product |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_products_by_status(status) do
    Product
    |> where([p], p.status == ^status)
    |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_products_by_type(product_type) do
    Product
    |> where([p], p.product_type == ^product_type)
    |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_categories do
    Category |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp apply_product_filters(query, opts) do
    query
    |> filter_by_status(Keyword.get(opts, :status))
    |> filter_by_product_type(Keyword.get(opts, :product_type))
    |> filter_by_category(Keyword.get(opts, :category_id))
    |> filter_by_product_search(Keyword.get(opts, :search))
    |> filter_by_visible_categories(Keyword.get(opts, :exclude_hidden_categories, false))
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [p], p.status == ^status)

  defp filter_by_product_type(query, nil), do: query
  defp filter_by_product_type(query, type), do: where(query, [p], p.product_type == ^type)

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, id), do: where(query, [p], p.category_id == ^id)

  defp filter_by_visible_categories(query, false), do: query

  defp filter_by_visible_categories(query, true) do
    # Exclude products from categories with status "hidden"
    # Products from "active" and "unlisted" categories are visible
    from(p in query,
      left_join: c in Category,
      on: c.id == p.category_id,
      where: is_nil(c.id) or c.status != "hidden"
    )
  end

  defp filter_by_product_search(query, nil), do: query
  defp filter_by_product_search(query, ""), do: query

  defp filter_by_product_search(query, search) do
    search_term = "%#{search}%"

    where(
      query,
      [p],
      ilike(p.title, ^search_term) or ilike(p.description, ^search_term)
    )
  end

  defp apply_category_filters(query, opts) do
    query
    |> filter_by_parent(Keyword.get(opts, :parent_id, :skip))
    |> filter_by_category_status(Keyword.get(opts, :status, :skip))
    |> filter_by_category_search(Keyword.get(opts, :search))
  end

  defp filter_by_parent(query, :skip), do: query
  defp filter_by_parent(query, nil), do: where(query, [c], is_nil(c.parent_id))
  defp filter_by_parent(query, id), do: where(query, [c], c.parent_id == ^id)

  defp filter_by_category_status(query, :skip), do: query

  defp filter_by_category_status(query, status) when is_binary(status) do
    where(query, [c], c.status == ^status)
  end

  defp filter_by_category_status(query, statuses) when is_list(statuses) do
    where(query, [c], c.status in ^statuses)
  end

  defp filter_by_category_search(query, nil), do: query
  defp filter_by_category_search(query, ""), do: query

  defp filter_by_category_search(query, search) do
    search_term = "%#{search}%"
    where(query, [c], ilike(c.name, ^search_term))
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  # Shipping filters
  defp filter_shipping_by_active(query, nil), do: query
  defp filter_shipping_by_active(query, active), do: where(query, [s], s.active == ^active)

  # Cart helpers

  # Find cart item by product and selected_specs
  defp find_cart_item_by_specs(cart_id, product_id, specs) when map_size(specs) == 0 do
    # No specs - find item without specs
    CartItem
    |> where([i], i.cart_id == ^cart_id and i.product_id == ^product_id)
    |> where([i], i.selected_specs == ^%{})
    |> repo().one()
  end

  defp find_cart_item_by_specs(cart_id, product_id, specs) when is_map(specs) do
    # With specs - find item with matching specs
    CartItem
    |> where([i], i.cart_id == ^cart_id and i.product_id == ^product_id)
    |> where([i], i.selected_specs == ^specs)
    |> repo().one()
  end

  defp recalculate_cart_totals!(%Cart{} = cart) do
    items = CartItem |> where([i], i.cart_id == ^cart.id) |> repo().all()

    subtotal =
      Enum.reduce(items, Decimal.new("0"), fn i, acc ->
        Decimal.add(acc, i.line_total || Decimal.new("0"))
      end)

    total_weight =
      Enum.reduce(items, 0, fn i, acc ->
        acc + (i.weight_grams || 0) * i.quantity
      end)

    items_count =
      Enum.reduce(items, 0, fn i, acc ->
        acc + i.quantity
      end)

    # Recalculate shipping if method selected
    shipping_amount =
      if cart.shipping_method_id do
        case repo().get(ShippingMethod, cart.shipping_method_id) do
          nil ->
            Decimal.new("0")

          method ->
            if ShippingMethod.available_for?(method, %{
                 weight_grams: total_weight,
                 subtotal: subtotal,
                 country: cart.shipping_country
               }) do
              ShippingMethod.calculate_cost(method, subtotal)
            else
              Decimal.new("0")
            end
        end
      else
        cart.shipping_amount || Decimal.new("0")
      end

    # Calculate tax
    tax_rate = get_tax_rate(cart)
    taxable_amount = Decimal.sub(subtotal, cart.discount_amount || Decimal.new("0"))
    tax_amount = Decimal.mult(taxable_amount, tax_rate) |> Decimal.round(2)

    # Calculate total
    total =
      subtotal
      |> Decimal.add(shipping_amount)
      |> Decimal.add(tax_amount)
      |> Decimal.sub(cart.discount_amount || Decimal.new("0"))

    cart
    |> Cart.totals_changeset(%{
      subtotal: subtotal,
      shipping_amount: shipping_amount,
      tax_amount: tax_amount,
      total: total,
      total_weight_grams: total_weight,
      items_count: items_count
    })
    |> repo().update!()
    |> repo().preload([:items, :shipping_method], force: true)
  end

  defp get_tax_rate(%Cart{shipping_country: nil}), do: Decimal.new("0")

  defp get_tax_rate(%Cart{shipping_country: _country}) do
    if Settings.get_setting_cached("shop_tax_enabled", "true") == "true" do
      rate = Settings.get_setting_cached("shop_tax_rate", "20")
      Decimal.div(Decimal.new(rate), Decimal.new("100"))
    else
      Decimal.new("0")
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ============================================
  # IMPORT LOGS
  # ============================================

  alias PhoenixKit.Modules.Shop.ImportLog

  @doc """
  Creates a new import log entry.
  """
  def create_import_log(attrs) do
    %ImportLog{}
    |> ImportLog.create_changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Gets an import log by ID.
  """
  def get_import_log(id, opts \\ [])

  def get_import_log(id, opts) when is_integer(id) do
    ImportLog
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().get(id)
  end

  def get_import_log(uuid, opts) when is_binary(uuid) do
    ImportLog
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().get_by(uuid: uuid)
  end

  @doc """
  Gets an import log by ID, raises if not found.
  """
  def get_import_log!(id) when is_integer(id) do
    repo().get!(ImportLog, id)
  end

  @doc """
  Lists recent import logs.
  """
  def list_import_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    ImportLog
    |> order_by([l], desc: l.inserted_at)
    |> limit(^limit)
    |> repo().all()
    |> repo().preload(:user)
  end

  @doc """
  Updates an import log.
  """
  def update_import_log(%ImportLog{} = import_log, attrs) do
    import_log
    |> ImportLog.update_changeset(attrs)
    |> repo().update()
  end

  @doc """
  Marks import as started.
  """
  def start_import(%ImportLog{} = import_log, total_rows) do
    import_log
    |> ImportLog.start_changeset(total_rows)
    |> repo().update()
  end

  @doc """
  Updates import progress.
  """
  def update_import_progress(%ImportLog{} = import_log, attrs) do
    import_log
    |> ImportLog.progress_changeset(attrs)
    |> repo().update()
  end

  @doc """
  Marks import as completed.
  """
  def complete_import(%ImportLog{} = import_log, stats) do
    import_log
    |> ImportLog.complete_changeset(stats)
    |> repo().update()
  end

  @doc """
  Marks import as failed.
  """
  def fail_import(%ImportLog{} = import_log, error) do
    import_log
    |> ImportLog.fail_changeset(error)
    |> repo().update()
  end

  @doc """
  Deletes an import log.
  """
  def delete_import_log(%ImportLog{} = import_log) do
    # Also delete the temp file if it exists
    if import_log.file_path && File.exists?(import_log.file_path) do
      File.rm(import_log.file_path)
    end

    repo().delete(import_log)
  end

  # ============================================
  # IMPORT CONFIG CRUD
  # ============================================

  @doc """
  Lists all active import configs.
  """
  def list_import_configs(opts \\ []) do
    query =
      ImportConfig
      |> order_by([c], desc: c.is_default, asc: c.name)

    query =
      if Keyword.get(opts, :active_only, true) do
        where(query, [c], c.active == true)
      else
        query
      end

    repo().all(query)
  end

  @doc """
  Gets an import config by ID.
  """
  def get_import_config(id) when is_integer(id) do
    repo().get(ImportConfig, id)
  end

  def get_import_config(uuid) when is_binary(uuid) do
    repo().get_by(ImportConfig, uuid: uuid)
  end

  @doc """
  Gets an import config by ID, raises if not found.
  """
  def get_import_config!(id) when is_integer(id) do
    repo().get!(ImportConfig, id)
  end

  @doc """
  Gets the default import config, if one exists.
  """
  def get_default_import_config do
    ImportConfig
    |> where([c], c.is_default == true and c.active == true)
    |> limit(1)
    |> repo().one()
  end

  @doc """
  Gets an import config by name.
  """
  def get_import_config_by_name(name) when is_binary(name) do
    repo().get_by(ImportConfig, name: name)
  end

  @doc """
  Creates an import config.
  """
  def create_import_config(attrs \\ %{}) do
    result =
      %ImportConfig{}
      |> ImportConfig.changeset(attrs)
      |> repo().insert()

    # If this is the new default, clear other defaults
    case result do
      {:ok, %ImportConfig{is_default: true} = config} ->
        clear_other_defaults(config.id)
        {:ok, config}

      other ->
        other
    end
  end

  @doc """
  Updates an import config.
  """
  def update_import_config(%ImportConfig{} = config, attrs) do
    result =
      config
      |> ImportConfig.changeset(attrs)
      |> repo().update()

    # If this is the new default, clear other defaults
    case result do
      {:ok, %ImportConfig{is_default: true} = updated_config} ->
        clear_other_defaults(updated_config.id)
        {:ok, updated_config}

      other ->
        other
    end
  end

  @doc """
  Deletes an import config.
  """
  def delete_import_config(%ImportConfig{} = config) do
    repo().delete(config)
  end

  defp clear_other_defaults(except_id) do
    ImportConfig
    |> where([c], c.is_default == true and c.id != ^except_id)
    |> repo().update_all(set: [is_default: false])
  end

  # ============================================
  # PRODUCT UPSERT
  # ============================================

  @doc """
  Creates or updates a product by slug.

  Uses upsert (INSERT ... ON CONFLICT) to handle existing products.
  Returns {:ok, product} with :inserted or :updated action.
  """
  def upsert_product(attrs) do
    changeset = Product.changeset(%Product{}, attrs)

    case repo().insert(changeset,
           on_conflict:
             {:replace,
              [
                :title,
                :description,
                :body_html,
                :price,
                :compare_at_price,
                :vendor,
                :tags,
                :status,
                :images,
                :featured_image,
                :seo_title,
                :seo_description,
                :metadata,
                :updated_at
              ]},
           conflict_target: :slug,
           returning: true
         ) do
      {:ok, product} ->
        # Check if this was an insert or update by checking timestamps
        action = if product.inserted_at == product.updated_at, do: :inserted, else: :updated
        {:ok, product, action}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ============================================
  # LOCALIZED API (Multi-Language Support)
  # ============================================

  alias PhoenixKit.Modules.Shop.SlugResolver
  alias PhoenixKit.Modules.Shop.Translations

  @doc """
  Gets a product by slug with language awareness.

  Searches both translated slugs and canonical slug for the specified language.

  ## Parameters

    - `slug` - The URL slug to search for
    - `language` - Language code (e.g., "es-ES" or base code "en")
    - `opts` - Options: `:preload`, `:status`

  ## Examples

      iex> Shop.get_product_by_slug_localized("maceta-geometrica", "es-ES")
      {:ok, %Product{}}

      iex> Shop.get_product_by_slug_localized("geometric-planter", "en")
      {:ok, %Product{}}
  """
  def get_product_by_slug_localized(slug, language, opts \\ []) do
    SlugResolver.find_product_by_slug(slug, language, opts)
  end

  @doc """
  Gets a category by slug with language awareness.

  Searches both translated slugs and canonical slug for the specified language.

  ## Parameters

    - `slug` - The URL slug to search for
    - `language` - Language code (e.g., "es-ES" or base code "en")
    - `opts` - Options: `:preload`, `:status`

  ## Examples

      iex> Shop.get_category_by_slug_localized("jarrones-macetas", "es-ES")
      {:ok, %Category{}}
  """
  def get_category_by_slug_localized(slug, language, opts \\ []) do
    SlugResolver.find_category_by_slug(slug, language, opts)
  end

  @doc """
  Updates translation for a specific language on a product.

  ## Parameters

    - `product` - The product struct
    - `language` - Language code (e.g., "es-ES")
    - `attrs` - Translation attributes: title, slug, description, body_html, seo_title, seo_description

  ## Examples

      iex> Shop.update_product_translation(product, "es-ES", %{
      ...>   "title" => "Maceta Geométrica",
      ...>   "slug" => "maceta-geometrica"
      ...> })
      {:ok, %Product{}}
  """
  def update_product_translation(%Product{} = product, language, attrs)
      when is_binary(language) do
    # Convert attrs to atom-keyed map for changeset_attrs_multi
    field_values =
      attrs
      |> Enum.map(fn {k, v} -> {to_atom(k), v} end)
      |> Map.new()

    translation_attrs = Translations.changeset_attrs_multi(product, language, field_values)
    update_product(product, translation_attrs)
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_existing_atom(key)

  @doc """
  Updates translation for a specific language on a category.

  ## Parameters

    - `category` - The category struct
    - `language` - Language code (e.g., "es-ES")
    - `attrs` - Translation attributes: name, slug, description

  ## Examples

      iex> Shop.update_category_translation(category, "es-ES", %{
      ...>   "name" => "Jarrones y Macetas",
      ...>   "slug" => "jarrones-macetas"
      ...> })
      {:ok, %Category{}}
  """
  def update_category_translation(%Category{} = category, language, attrs)
      when is_binary(language) do
    # Convert attrs to atom-keyed map for changeset_attrs_multi
    field_values =
      attrs
      |> Enum.map(fn {k, v} -> {to_atom(k), v} end)
      |> Map.new()

    translation_attrs = Translations.changeset_attrs_multi(category, language, field_values)
    update_category(category, translation_attrs)
  end

  @doc """
  Lists products with translated fields for a specific language.

  Returns products with an additional `:localized` virtual map containing
  translated fields with fallback to defaults.

  ## Parameters

    - `language` - Language code for translations
    - `opts` - Standard list options: `:page`, `:per_page`, `:status`, `:category_id`, etc.

  ## Examples

      iex> Shop.list_products_localized("es-ES", status: "active")
      [%Product{localized: %{title: "Maceta...", ...}}, ...]
  """
  def list_products_localized(language, opts \\ []) do
    products = list_products(opts)

    Enum.map(products, fn product ->
      Map.put(product, :localized, build_localized_product(product, language))
    end)
  end

  @doc """
  Lists categories with translated fields for a specific language.

  ## Parameters

    - `language` - Language code for translations
    - `opts` - Standard list options

  ## Examples

      iex> Shop.list_categories_localized("es-ES", status: "active")
      [%Category{localized: %{name: "Jarrones...", ...}}, ...]
  """
  def list_categories_localized(language, opts \\ []) do
    categories = list_categories(opts)

    Enum.map(categories, fn category ->
      Map.put(category, :localized, build_localized_category(category, language))
    end)
  end

  @doc """
  Gets the localized slug for a product.

  Returns translated slug if available, otherwise canonical slug.

  ## Examples

      iex> Shop.get_product_slug(product, "es-ES")
      "maceta-geometrica"
  """
  def get_product_slug(%Product{} = product, language) do
    SlugResolver.product_slug(product, language)
  end

  @doc """
  Gets the localized slug for a category.

  ## Examples

      iex> Shop.get_category_slug(category, "es-ES")
      "jarrones-macetas"
  """
  def get_category_slug(%Category{} = category, language) do
    SlugResolver.category_slug(category, language)
  end

  @doc """
  Finds a product by slug in any language.

  Searches across all translated slugs to find the product.
  Useful for cross-language redirect when user visits with a slug
  from a different language.

  ## Examples

      iex> Shop.get_product_by_any_slug("maceta-geometrica")
      {:ok, %Product{}, "es"}

      iex> Shop.get_product_by_any_slug("nonexistent")
      {:error, :not_found}
  """
  def get_product_by_any_slug(slug, opts \\ []) do
    SlugResolver.find_product_by_any_slug(slug, opts)
  end

  @doc """
  Finds a category by slug in any language.

  ## Examples

      iex> Shop.get_category_by_any_slug("jarrones-macetas")
      {:ok, %Category{}, "es"}
  """
  def get_category_by_any_slug(slug, opts \\ []) do
    SlugResolver.find_category_by_any_slug(slug, opts)
  end

  # ============================================
  # URL GENERATION
  # ============================================

  @doc """
  Generates a localized URL for a product.

  Returns the correct locale-prefixed URL with translated slug.
  The URL respects the PhoenixKit URL prefix configuration.

  ## Parameters

    - `product` - The Product struct
    - `language` - Language code (e.g., "en-US", "ru", "es-ES")

  ## Examples

      iex> Shop.product_url(product, "es-ES")
      "/es/shop/product/maceta-geometrica"

      iex> Shop.product_url(product, "ru")
      "/ru/shop/product/geometricheskoe-kashpo"

      iex> Shop.product_url(product, "en")
      "/shop/product/geometric-planter"  # Default language - no prefix
  """
  @spec product_url(Product.t(), String.t()) :: String.t()
  def product_url(%Product{} = product, language) do
    slug = SlugResolver.product_slug(product, language)
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/shop/product/#{slug}", locale: base)
  end

  @doc """
  Generates a localized URL for a category.

  Returns the correct locale-prefixed URL with translated slug.

  ## Parameters

    - `category` - The Category struct
    - `language` - Language code (e.g., "en-US", "ru", "es-ES")

  ## Examples

      iex> Shop.category_url(category, "es-ES")
      "/es/shop/category/jarrones-macetas"

      iex> Shop.category_url(category, "en")
      "/shop/category/vases-planters"  # Default language - no prefix
  """
  @spec category_url(Category.t(), String.t()) :: String.t()
  def category_url(%Category{} = category, language) do
    slug = SlugResolver.category_slug(category, language)
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/shop/category/#{slug}", locale: base)
  end

  @doc """
  Generates a localized URL for the shop catalog.

  ## Examples

      iex> Shop.catalog_url("es-ES")
      "/es/shop"

      iex> Shop.catalog_url("en")
      "/shop"
  """
  @spec catalog_url(String.t()) :: String.t()
  def catalog_url(language) do
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/shop", locale: base)
  end

  @doc """
  Generates a localized URL for the cart page.

  ## Examples

      iex> Shop.cart_url("ru")
      "/ru/cart"

      iex> Shop.cart_url("en")
      "/cart"
  """
  @spec cart_url(String.t()) :: String.t()
  def cart_url(language) do
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/cart", locale: base)
  end

  @doc """
  Generates a localized URL for the checkout page.

  ## Examples

      iex> Shop.checkout_url("ru")
      "/ru/checkout"

      iex> Shop.checkout_url("en")
      "/checkout"
  """
  @spec checkout_url(String.t()) :: String.t()
  def checkout_url(language) do
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/checkout", locale: base)
  end

  @doc """
  Gets the default language code (base code, e.g., "en").

  Reads from Languages module configuration or falls back to "en".
  """
  @spec get_default_language() :: String.t()
  def get_default_language do
    case Languages.get_default_language() do
      nil -> "en"
      lang -> DialectMapper.extract_base(lang["code"])
    end
  end

  @doc """
  Checks if a product slug exists for a language.

  Useful for validation during translation editing.

  ## Examples

      iex> Shop.product_slug_exists?("maceta-geometrica", "es-ES")
      true

      iex> Shop.product_slug_exists?("maceta-geometrica", "es-ES", exclude_id: 123)
      false
  """
  def product_slug_exists?(slug, language, opts \\ []) do
    SlugResolver.product_slug_exists?(slug, language, opts)
  end

  @doc """
  Checks if a category slug exists for a language.

  ## Examples

      iex> Shop.category_slug_exists?("jarrones-macetas", "es-ES")
      true
  """
  def category_slug_exists?(slug, language, opts \\ []) do
    SlugResolver.category_slug_exists?(slug, language, opts)
  end

  @doc """
  Returns translation helpers module for direct access.

  ## Examples

      iex> Shop.translations()
      PhoenixKit.Modules.Shop.Translations
  """
  def translations, do: Translations

  # Build localized map for a product
  defp build_localized_product(product, language) do
    %{
      title: Translations.get_field(product, :title, language),
      slug: Translations.get_field(product, :slug, language) || product.slug,
      description: Translations.get_field(product, :description, language),
      body_html: Translations.get_field(product, :body_html, language),
      seo_title: Translations.get_field(product, :seo_title, language),
      seo_description: Translations.get_field(product, :seo_description, language)
    }
  end

  # Build localized map for a category
  defp build_localized_category(category, language) do
    %{
      name: Translations.get_field(category, :name, language),
      slug: Translations.get_field(category, :slug, language) || category.slug,
      description: Translations.get_field(category, :description, language)
    }
  end
end
