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

  use PhoenixKit.Module

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Billing.PaymentOption
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
  alias PhoenixKit.Modules.Shop.ShopConfig
  alias PhoenixKit.Modules.Shop.SlugResolver
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  # ============================================
  # SYSTEM ENABLE/DISABLE
  # ============================================

  @impl PhoenixKit.Module
  @doc """
  Checks if the shop system is enabled.
  """
  def enabled? do
    Settings.get_boolean_setting("shop_enabled", false)
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the shop system.
  """
  def enable_system do
    result = Settings.update_boolean_setting_with_module("shop_enabled", true, "shop")
    refresh_dashboard_tabs()
    result
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the shop system.
  """
  def disable_system do
    result = Settings.update_boolean_setting_with_module("shop_enabled", false, "shop")
    refresh_dashboard_tabs()
    result
  end

  defp refresh_dashboard_tabs do
    if Code.ensure_loaded?(PhoenixKit.Dashboard.Registry) and
         PhoenixKit.Dashboard.Registry.initialized?() do
      PhoenixKit.Dashboard.Registry.load_defaults()
    end
  end

  @impl PhoenixKit.Module
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
  # MODULE BEHAVIOUR CALLBACKS
  # ============================================

  @impl PhoenixKit.Module
  def module_key, do: "shop"

  @impl PhoenixKit.Module
  def module_name, do: "E-Commerce"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "shop",
      label: "E-Commerce",
      icon: "hero-shopping-cart",
      description: "Product catalog, orders, and e-commerce management"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_shop,
        label: "E-Commerce",
        icon: "hero-shopping-bag",
        path: "/admin/shop",
        priority: 530,
        level: :admin,
        permission: "shop",
        match: :exact,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      ),
      Tab.new!(
        id: :admin_shop_dashboard,
        label: "Dashboard",
        icon: "hero-home",
        path: "/admin/shop",
        priority: 531,
        level: :admin,
        permission: "shop",
        parent: :admin_shop,
        match: :exact
      ),
      Tab.new!(
        id: :admin_shop_products,
        label: "Products",
        icon: "hero-cube",
        path: "/admin/shop/products",
        priority: 532,
        level: :admin,
        permission: "shop",
        parent: :admin_shop
      ),
      Tab.new!(
        id: :admin_shop_categories,
        label: "Categories",
        icon: "hero-folder",
        path: "/admin/shop/categories",
        priority: 533,
        level: :admin,
        permission: "shop",
        parent: :admin_shop
      ),
      Tab.new!(
        id: :admin_shop_shipping,
        label: "Shipping",
        icon: "hero-truck",
        path: "/admin/shop/shipping",
        priority: 534,
        level: :admin,
        permission: "shop",
        parent: :admin_shop
      ),
      Tab.new!(
        id: :admin_shop_carts,
        label: "Carts",
        icon: "hero-shopping-cart",
        path: "/admin/shop/carts",
        priority: 535,
        level: :admin,
        permission: "shop",
        parent: :admin_shop
      ),
      Tab.new!(
        id: :admin_shop_imports,
        label: "CSV Import",
        icon: "hero-cloud-arrow-up",
        path: "/admin/shop/imports",
        priority: 536,
        level: :admin,
        permission: "shop",
        parent: :admin_shop
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_shop,
        label: "E-Commerce",
        icon: "hero-shopping-bag",
        path: "/admin/shop/settings",
        priority: 927,
        level: :admin,
        parent: :admin_settings,
        permission: "shop"
      )
    ]
  end

  @impl PhoenixKit.Module
  def user_dashboard_tabs do
    [
      Tab.new!(
        id: :dashboard_shop,
        label: "Shop",
        icon: "hero-building-storefront",
        path: "/shop",
        priority: 300,
        match: :prefix,
        group: :shop
      ),
      Tab.new!(
        id: :dashboard_cart,
        label: "My Cart",
        icon: "hero-shopping-cart",
        path: "/cart",
        priority: 310,
        match: :prefix,
        group: :shop
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitWeb.Routes.ShopRoutes

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

    total = repo().aggregate(base_query, :count)

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
    if ids_are_uuids?(ids) do
      Product |> where([p], p.uuid in ^ids) |> repo().all()
    else
      Product |> where([p], p.id in ^ids) |> repo().all()
    end
  end

  # ============================================
  # STOREFRONT FILTERS
  # ============================================

  @storefront_filters_key "storefront_filters"

  @doc """
  Gets storefront filter configuration from shop_config.

  Returns a list of filter definition maps with keys:
  key, type, label, enabled, position.

  Default: price filter only.
  """
  def get_storefront_filters do
    case repo().get(ShopConfig, @storefront_filters_key) do
      %ShopConfig{value: %{"filters" => filters}} when is_list(filters) ->
        filters

      _ ->
        default_storefront_filters()
    end
  end

  @doc """
  Returns only enabled storefront filters, sorted by position.
  """
  def get_enabled_storefront_filters do
    get_storefront_filters()
    |> Enum.filter(& &1["enabled"])
    |> Enum.sort_by(& &1["position"])
  end

  @doc """
  Saves storefront filter configuration.
  """
  def update_storefront_filters(filters) when is_list(filters) do
    value = %{"filters" => filters}

    case repo().get(ShopConfig, @storefront_filters_key) do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: @storefront_filters_key, value: value})
        |> repo().insert()

      config ->
        config
        |> ShopConfig.changeset(%{value: value})
        |> repo().update()
    end
  end

  @doc """
  Aggregates filter values for sidebar display.

  Returns a map of filter_key => aggregated data.
  For price_range: %{min: Decimal, max: Decimal}
  For vendor: [%{value: "Vendor", count: 5}, ...]
  For metadata_option: [%{value: "8 inches", count: 3}, ...]

  Options:
  - `:category_uuid` - Scope aggregation to a specific category by UUID
  """
  def aggregate_filter_values(opts \\ []) do
    filters = get_enabled_storefront_filters()
    category_uuid = Keyword.get(opts, :category_uuid)

    Enum.reduce(filters, %{}, fn filter, acc ->
      Map.put(acc, filter["key"], aggregate_single_filter(filter, category_uuid))
    end)
  end

  defp aggregate_single_filter(%{"type" => "price_range"}, category_uuid) do
    query =
      Product
      |> where([p], p.status == "active")
      |> maybe_filter_category(category_uuid)

    min_price = repo().aggregate(query, :min, :price)
    max_price = repo().aggregate(query, :max, :price)
    %{min: min_price, max: max_price}
  rescue
    _ -> %{min: nil, max: nil}
  end

  defp aggregate_single_filter(%{"type" => "vendor"}, category_uuid) do
    query =
      Product
      |> where([p], p.status == "active" and not is_nil(p.vendor) and p.vendor != "")
      |> maybe_filter_category(category_uuid)
      |> group_by([p], p.vendor)
      |> select([p], %{value: p.vendor, count: count(p.uuid)})
      |> order_by([p], desc: count(p.uuid))

    repo().all(query)
  rescue
    _ -> []
  end

  defp aggregate_single_filter(%{"type" => "metadata_option", "option_key" => key}, category_uuid)
       when is_binary(key) do
    # Query distinct option values from metadata->'_option_values'->key JSONB array
    sql = """
    SELECT val AS value, COUNT(DISTINCT p.uuid) AS count
    FROM phoenix_kit_shop_products p,
         jsonb_array_elements_text(COALESCE(p.metadata->'_option_values'->$1, '[]'::jsonb)) AS val
    WHERE p.status = 'active'
    #{if category_uuid, do: "AND p.category_uuid = $2", else: ""}
    GROUP BY val
    ORDER BY count DESC
    """

    params =
      if category_uuid do
        {:ok, uuid_bin} = Ecto.UUID.dump(category_uuid)
        [key, uuid_bin]
      else
        [key]
      end

    case repo().query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [value, count] -> %{value: value, count: count} end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp aggregate_single_filter(_filter, _category_uuid), do: []

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, uuid), do: where(query, [p], p.category_uuid == ^uuid)

  @doc """
  Discovers filterable option keys from product metadata.

  Returns a list of {key, product_count} tuples sorted by count descending.
  Used by admin UI to auto-suggest available filters.
  """
  def discover_filterable_options do
    sql = """
    SELECT key, COUNT(DISTINCT p.uuid) AS product_count
    FROM phoenix_kit_shop_products p,
         jsonb_object_keys(COALESCE(p.metadata->'_option_values', '{}'::jsonb)) AS key
    WHERE p.status = 'active'
    GROUP BY key
    ORDER BY product_count DESC
    """

    case repo().query(sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [key, count] -> %{key: key, count: count} end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Returns the default storefront filter configuration.
  """
  def default_storefront_filters do
    [
      %{
        "key" => "price",
        "type" => "price_range",
        "label" => "Price",
        "enabled" => true,
        "position" => 0
      },
      %{
        "key" => "vendor",
        "type" => "vendor",
        "label" => "Vendor",
        "enabled" => false,
        "position" => 1
      }
    ]
  end

  @doc """
  Gets a product by ID or UUID.
  """
  def get_product(id, opts \\ [])

  def get_product(id, opts) when is_integer(id) do
    Product
    |> where([p], p.id == ^id)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().one()
  end

  def get_product(id, opts) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      Product
      |> where([p], p.uuid == ^id)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().one()
    else
      case Integer.parse(id) do
        {int_id, ""} -> get_product(int_id, opts)
        _ -> nil
      end
    end
  end

  def get_product(_, _opts), do: nil

  @doc """
  Gets a product by ID or UUID, raises if not found.
  """
  def get_product!(id, opts \\ []) do
    case get_product(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: Product
      product -> product
    end
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

    result =
      %Product{}
      |> Product.changeset(attrs)
      |> repo().insert()

    case result do
      {:ok, product} ->
        Events.broadcast_product_created(product)
        {:ok, product}

      error ->
        error
    end
  end

  @doc """
  Updates a product.

  Automatically normalizes metadata (price modifiers, option values)
  before saving to ensure consistent storage format.
  """
  def update_product(%Product{} = product, attrs) do
    attrs = MetadataValidator.normalize_product_attrs(attrs)

    result =
      product
      |> Product.changeset(attrs)
      |> repo().update()

    case result do
      {:ok, updated_product} ->
        Events.broadcast_product_updated(updated_product)
        {:ok, updated_product}

      error ->
        error
    end
  end

  @doc """
  Deletes a product.
  """
  def delete_product(%Product{} = product) do
    product_id = product.id

    case repo().delete(product) do
      {:ok, _} = result ->
        Events.broadcast_product_deleted(product_id)
        result

      error ->
        error
    end
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
    query =
      if ids_are_uuids?(ids) do
        Product |> where([p], p.uuid in ^ids)
      else
        Product |> where([p], p.id in ^ids)
      end

    {count, _} =
      query
      |> repo().update_all(set: [status: status, updated_at: UtilsDate.utc_now()])

    if count > 0 do
      Events.broadcast_products_bulk_status_changed(ids, status)
    end

    count
  end

  @doc """
  Bulk update product category.
  Returns count of updated products.
  """
  def bulk_update_product_category(ids, category_id) when is_list(ids) do
    {cat_int_id, cat_uuid} =
      if category_id do
        case PhoenixKit.UUID.get(Category, category_id) do
          nil -> {nil, nil}
          cat -> {cat.id, cat.uuid}
        end
      else
        {nil, nil}
      end

    # Don't unassign category if a specific category was requested but not found
    if category_id && is_nil(cat_int_id) && is_nil(cat_uuid) do
      0
    else
      query =
        if ids_are_uuids?(ids) do
          Product |> where([p], p.uuid in ^ids)
        else
          Product |> where([p], p.id in ^ids)
        end

      {count, _} =
        query
        |> repo().update_all(
          set: [
            category_id: cat_int_id,
            category_uuid: cat_uuid,
            updated_at: UtilsDate.utc_now()
          ]
        )

      count
    end
  end

  @doc """
  Bulk delete products.
  Returns count of deleted products.
  """
  def bulk_delete_products(ids) when is_list(ids) do
    query =
      if ids_are_uuids?(ids) do
        Product |> where([p], p.uuid in ^ids)
      else
        Product |> where([p], p.id in ^ids)
      end

    {count, _} = repo().delete_all(query)

    count
  end

  @doc """
  Collects all storage file UUIDs associated with a single product.
  """
  def collect_product_file_uuids(%Product{} = product) do
    [product.featured_image_uuid, product.file_uuid | product.image_ids || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Collects all storage file UUIDs for a list of product UUIDs.
  """
  def collect_products_file_uuids(product_uuids) when is_list(product_uuids) do
    from(p in Product,
      where: p.uuid in ^product_uuids,
      select: %{
        featured_image_uuid: p.featured_image_uuid,
        file_uuid: p.file_uuid,
        image_ids: p.image_ids
      }
    )
    |> repo().all()
    |> Enum.flat_map(fn p ->
      [p.featured_image_uuid, p.file_uuid | p.image_ids || []]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
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
  Returns a map of category_id => product_count for all categories.
  """
  def product_counts_by_category do
    Product
    |> where([p], not is_nil(p.category_id))
    |> group_by([p], p.category_id)
    |> select([p], {p.category_id, count(p.id)})
    |> repo().all()
    |> Map.new()
  rescue
    e ->
      Logger.warning("Failed to load product counts by category: #{inspect(e)}")
      %{}
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

    total = repo().aggregate(base_query, :count)

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
  Gets a category by ID or UUID.
  """
  def get_category(id, opts \\ [])

  def get_category(id, opts) when is_integer(id) do
    Category
    |> where([c], c.id == ^id)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().one()
  end

  def get_category(id, opts) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      Category
      |> where([c], c.uuid == ^id)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().one()
    else
      case Integer.parse(id) do
        {int_id, ""} -> get_category(int_id, opts)
        _ -> nil
      end
    end
  end

  def get_category(_, _opts), do: nil

  @doc """
  Gets a category by ID or UUID, raises if not found.
  """
  def get_category!(id, opts \\ []) do
    case get_category(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: Category
      category -> category
    end
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
    result =
      %Category{}
      |> Category.changeset(attrs)
      |> repo().insert()

    case result do
      {:ok, category} ->
        Events.broadcast_category_created(category)
        {:ok, category}

      error ->
        error
    end
  end

  @doc """
  Updates a category.
  """
  def update_category(%Category{} = category, attrs) do
    result =
      category
      |> Category.changeset(attrs)
      |> repo().update()

    case result do
      {:ok, updated_category} ->
        Events.broadcast_category_updated(updated_category)
        {:ok, updated_category}

      error ->
        error
    end
  end

  @doc """
  Lists categories that have no products assigned.
  """
  def list_empty_categories do
    subquery = from(p in Product, select: p.category_uuid, where: not is_nil(p.category_uuid))

    from(c in Category, where: c.uuid not in subquery(subquery))
    |> repo().all()
  end

  @doc """
  Deletes a category.
  """
  def delete_category(%Category{} = category) do
    category_id = category.id

    case repo().delete(category) do
      {:ok, _} = result ->
        Events.broadcast_category_deleted(category_id)
        result

      error ->
        error
    end
  end

  @doc """
  Returns a changeset for category form.
  """
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  @doc """
  Bulk update category status.
  Returns count of updated categories.
  """
  def bulk_update_category_status(ids, status) when is_list(ids) and is_binary(status) do
    query =
      if ids_are_uuids?(ids) do
        Category |> where([c], c.uuid in ^ids)
      else
        Category |> where([c], c.id in ^ids)
      end

    {count, _} =
      query
      |> repo().update_all(set: [status: status, updated_at: UtilsDate.utc_now()])

    if count > 0 do
      Events.broadcast_categories_bulk_status_changed(ids, status)
    end

    count
  end

  @doc """
  Bulk update category parent.
  Returns count of updated categories. Excludes the target parent from the update set
  to prevent self-reference. Uses a single UPDATE with subquery to resolve parent_id.
  """
  def bulk_update_category_parent(ids, parent_uuid) when is_list(ids) do
    # Exclude the target parent and its ancestors from update set to prevent cycles
    ids_to_update =
      if parent_uuid do
        ancestors = collect_ancestor_uuids(parent_uuid, %{})

        Enum.reject(ids, &(&1 == parent_uuid or Map.has_key?(ancestors, &1)))
      else
        ids
      end

    if ids_to_update == [] do
      0
    else
      now = UtilsDate.utc_now()

      {count, _} =
        if is_nil(parent_uuid) do
          # Make root — set both to nil
          Category
          |> where([c], c.uuid in ^ids_to_update)
          |> repo().update_all(set: [parent_id: nil, parent_uuid: nil, updated_at: now])
        else
          # Resolve parent_id in one query, then bulk update
          parent =
            Category
            |> where([c], c.uuid == ^parent_uuid)
            |> select([c], %{id: c.id})
            |> repo().one()

          if parent do
            Category
            |> where([c], c.uuid in ^ids_to_update)
            |> repo().update_all(
              set: [parent_id: parent.id, parent_uuid: parent_uuid, updated_at: now]
            )
          else
            {0, nil}
          end
        end

      if count > 0 do
        Events.broadcast_categories_bulk_parent_changed(ids_to_update, parent_uuid)
      end

      count
    end
  end

  defp collect_ancestor_uuids(nil, acc), do: acc

  defp collect_ancestor_uuids(uuid, acc) do
    if Map.has_key?(acc, uuid) do
      acc
    else
      case repo().get_by(Category, uuid: uuid) do
        nil -> acc
        %{parent_uuid: parent} -> collect_ancestor_uuids(parent, Map.put(acc, uuid, true))
      end
    end
  end

  @doc """
  Bulk delete categories.
  Returns count of deleted categories. Nullifies category references on orphaned products.
  """
  def bulk_delete_categories(ids) when is_list(ids) do
    uuid_ids? = ids_are_uuids?(ids)

    # Nullify category references on products to prevent orphans
    orphan_query =
      if uuid_ids? do
        Product |> where([p], p.category_uuid in ^ids)
      else
        Product |> where([p], p.category_id in ^ids)
      end

    repo().update_all(orphan_query,
      set: [category_id: nil, category_uuid: nil, updated_at: UtilsDate.utc_now()]
    )

    # Delete categories
    category_query =
      if uuid_ids? do
        Category |> where([c], c.uuid in ^ids)
      else
        Category |> where([c], c.id in ^ids)
      end

    {count, _} = repo().delete_all(category_query)

    if count > 0 do
      Events.broadcast_categories_bulk_deleted(ids)
    end

    count
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
      {Translations.get(cat, :name, default_lang), cat.uuid}
    end)
  end

  @doc """
  Ensures a category has a featured_product_id set.

  If the category has no image_id and no featured_product_id, auto-detects the
  first active product with an image and saves it. Returns the (possibly updated)
  category with :featured_product preloaded.
  """
  def ensure_featured_product(
        %Category{featured_product_id: nil, image_uuid: nil, uuid: cat_uuid} = cat
      ) do
    case find_default_featured_product(cat_uuid) do
      nil ->
        cat

      {product_id, product_uuid} ->
        {:ok, updated} =
          update_category(cat, %{
            featured_product_id: product_id,
            featured_product_uuid: product_uuid
          })

        repo().preload(updated, :featured_product)
    end
  end

  def ensure_featured_product(cat), do: cat

  defp find_default_featured_product(category_uuid) do
    from(p in Product,
      where: p.category_uuid == ^category_uuid,
      where: p.status == "active",
      where:
        not is_nil(p.featured_image_uuid) or
          (not is_nil(p.featured_image) and p.featured_image != ""),
      order_by: [asc: p.inserted_at],
      limit: 1,
      select: {p.id, p.uuid}
    )
    |> repo().one()
  end

  @doc """
  Returns a list of {name, id} tuples for products in a category that have images.
  Used for the featured product dropdown in the admin category form.
  """
  def list_category_product_options(category_id) do
    default_lang = Translations.default_language()

    query = category_product_options_query(category_id)

    if query do
      query
      |> repo().all()
      |> Enum.map(fn {title_map, uuid} ->
        name =
          case title_map do
            %{} = map -> map[default_lang] || map |> Map.values() |> List.first()
            _ -> "Product #{uuid}"
          end

        {name, uuid}
      end)
    else
      []
    end
  end

  defp category_product_options_query(category_id) when is_integer(category_id) do
    from(p in Product,
      where: p.category_id == ^category_id,
      where: p.status == "active",
      where:
        not is_nil(p.featured_image_uuid) or
          (not is_nil(p.featured_image) and p.featured_image != ""),
      order_by: [asc: p.id],
      select: {p.title, p.uuid}
    )
  end

  defp category_product_options_query(category_id) when is_binary(category_id) do
    if match?({:ok, _}, Ecto.UUID.cast(category_id)) do
      from(p in Product,
        where: p.category_uuid == ^category_id,
        where: p.status == "active",
        where:
          not is_nil(p.featured_image_uuid) or
            (not is_nil(p.featured_image) and p.featured_image != ""),
        order_by: [asc: p.id],
        select: {p.title, p.uuid}
      )
    end
  end

  defp category_product_options_query(_), do: nil

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
  Gets a shipping method by ID or UUID.
  """
  def get_shipping_method(id) when is_integer(id) do
    repo().get_by(ShippingMethod, id: id)
  end

  def get_shipping_method(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      repo().get_by(ShippingMethod, uuid: id)
    else
      case Integer.parse(id) do
        {int_id, ""} -> get_shipping_method(int_id)
        _ -> nil
      end
    end
  end

  def get_shipping_method(_), do: nil

  @doc """
  Gets a shipping method by ID or UUID, raises if not found.
  """
  def get_shipping_method!(id) do
    case get_shipping_method(id) do
      nil -> raise Ecto.NoResultsError, queryable: ShippingMethod
      method -> method
    end
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
  - `:user_uuid` - User UUID (for authenticated users)
  - `:session_id` - Session ID (for guests)
  """
  def get_or_create_cart(opts) do
    user_id = Keyword.get(opts, :user_id)
    user_uuid = Keyword.get(opts, :user_uuid)
    session_id = Keyword.get(opts, :session_id)

    case find_active_cart(user_id: user_id, session_id: session_id) do
      nil -> create_cart(user_id: user_id, user_uuid: user_uuid, session_id: session_id)
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
    user_uuid = Keyword.get(opts, :user_uuid)
    session_id = Keyword.get(opts, :session_id)

    base_query =
      Cart
      |> where([c], c.status == "active")
      |> preload([:items, :shipping_method, :payment_option])

    cond do
      not is_nil(user_uuid) ->
        # First try to find by user_uuid
        case base_query |> where([c], c.user_uuid == ^user_uuid) |> repo().one() do
          nil when not is_nil(session_id) ->
            # Fallback: try session_id (cart created before login)
            base_query |> where([c], c.session_id == ^session_id) |> repo().one()

          result ->
            result
        end

      not is_nil(user_id) ->
        # Legacy: find by user_id
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
        |> where([c], c.session_id == ^session_id and is_nil(c.user_id) and is_nil(c.user_uuid))
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
      user_uuid: Keyword.get(opts, :user_uuid),
      session_id: Keyword.get(opts, :session_id),
      currency: get_default_currency_code()
    }

    case %Cart{} |> Cart.changeset(attrs) |> repo().insert() do
      {:ok, cart} -> {:ok, repo().preload(cart, [:items, :shipping_method])}
      error -> error
    end
  end

  @doc """
  Gets a cart by ID or UUID with items preloaded.
  """
  def get_cart(id) when is_integer(id) do
    Cart
    |> where([c], c.id == ^id)
    |> preload([:items, :shipping_method, :payment_option])
    |> repo().one()
  end

  def get_cart(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      Cart
      |> where([c], c.uuid == ^id)
      |> preload([:items, :shipping_method, :payment_option])
      |> repo().one()
    else
      case Integer.parse(id) do
        {int_id, ""} -> get_cart(int_id)
        _ -> nil
      end
    end
  end

  def get_cart(_), do: nil

  @doc """
  Gets a cart by ID or UUID, raises if not found.
  """
  def get_cart!(id) do
    case get_cart(id) do
      nil -> raise Ecto.NoResultsError, queryable: Cart
      cart -> cart
    end
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
    skip_validation = Keyword.get(opts, :skip_spec_validation, false)

    # Validate selected_specs against product's option schema
    with :ok <- maybe_validate_specs(product, selected_specs, skip_validation) do
      if map_size(selected_specs) > 0 do
        add_product_with_specs_to_cart(cart, product, quantity, selected_specs)
      else
        add_simple_product_to_cart(cart, product, quantity)
      end
    end
  end

  def add_to_cart(%Cart{} = cart, %Product{} = product, quantity, _opts)
      when is_integer(quantity) do
    add_simple_product_to_cart(cart, product, quantity)
  end

  defp add_simple_product_to_cart(cart, product, quantity) do
    result =
      repo().transaction(fn ->
        # Lock product row to prevent price changes during cart update
        # This ensures price snapshot is consistent with current product state
        locked_product =
          Product
          |> where([p], p.id == ^product.id)
          |> lock("FOR UPDATE")
          |> repo().one!()

        # Use unified price calculation path (same as add_product_with_specs_to_cart)
        # With empty specs this returns base_price, but allows future extensibility
        calculated_price = calculate_product_price(locked_product, %{})

        # Check if product already in cart (without specs)
        existing = find_cart_item_by_specs(cart.uuid, product.uuid, %{})

        item =
          case existing do
            nil ->
              # Create new item with calculated price
              attrs =
                CartItem.from_product(locked_product, quantity)
                |> Map.put(:cart_id, cart.id)
                |> Map.put(:cart_uuid, cart.uuid)
                |> Map.put(:unit_price, calculated_price)

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
    result =
      repo().transaction(fn ->
        # Lock product row to prevent price/metadata changes during cart update
        locked_product =
          Product
          |> where([p], p.id == ^product.id)
          |> lock("FOR UPDATE")
          |> repo().one!()

        # Calculate price with spec modifiers using locked product state
        calculated_price = calculate_product_price(locked_product, selected_specs)

        # Check if same product with same specs already in cart
        existing = find_cart_item_by_specs(cart.uuid, product.uuid, selected_specs)

        item =
          case existing do
            nil ->
              # Create new item with specs and calculated price
              attrs =
                CartItem.from_product(locked_product, quantity)
                |> Map.put(:cart_id, cart.id)
                |> Map.put(:cart_uuid, cart.uuid)
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

  # ============================================
  # SELECTED SPECS VALIDATION
  # ============================================

  defp maybe_validate_specs(_product, _specs, true), do: :ok
  defp maybe_validate_specs(_product, specs, _skip) when specs == %{}, do: :ok

  defp maybe_validate_specs(product, selected_specs, _skip) do
    validate_selected_specs(product, selected_specs)
  end

  @doc """
  Validates selected_specs against product's option schema.

  Checks:
  - All spec keys exist in the option schema
  - All spec values are in allowed values list (if defined)
  - All required options have values

  ## Returns

  - `:ok` - All specs are valid
  - `{:error, :unknown_option_key, key}` - Key not in schema
  - `{:error, :invalid_option_value, %{key: key, value: value, allowed: list}}` - Value not allowed
  - `{:error, :missing_required_option, key}` - Required option not provided

  ## Examples

      iex> validate_selected_specs(product, %{"material" => "PETG"})
      :ok

      iex> validate_selected_specs(product, %{"material" => "Unobtainium"})
      {:error, :invalid_option_value, %{key: "material", value: "Unobtainium", allowed: ["PLA", "PETG"]}}
  """
  def validate_selected_specs(%Product{} = product, selected_specs) when is_map(selected_specs) do
    # Use full selectable specs (includes discovered options from metadata)
    # to match what the UI actually shows to users
    schema = Options.get_selectable_specs_for_product(product)

    # Build lookup map: key => option definition
    schema_map = Map.new(schema, fn opt -> {opt["key"], opt} end)

    # Check all provided keys exist and values are valid
    with :ok <- validate_spec_keys(selected_specs, schema_map),
         :ok <- validate_spec_values(selected_specs, schema_map) do
      validate_required_options(selected_specs, schema)
    end
  end

  def validate_selected_specs(_product, _specs), do: :ok

  # Validate that all provided keys exist in schema
  defp validate_spec_keys(selected_specs, schema_map) do
    invalid_key =
      Enum.find(Map.keys(selected_specs), fn key ->
        not Map.has_key?(schema_map, key)
      end)

    if invalid_key do
      {:error, :unknown_option_key, invalid_key}
    else
      :ok
    end
  end

  # Validate that all values are in allowed list (if options defined)
  defp validate_spec_values(selected_specs, schema_map) do
    invalid =
      Enum.find(selected_specs, fn {key, value} ->
        opt = Map.get(schema_map, key)
        allowed_values = opt["options"]

        # Only validate if options list is defined and non-empty
        if is_list(allowed_values) and allowed_values != [] do
          value not in allowed_values
        else
          false
        end
      end)

    case invalid do
      nil ->
        :ok

      {key, value} ->
        opt = Map.get(schema_map, key)
        {:error, :invalid_option_value, %{key: key, value: value, allowed: opt["options"]}}
    end
  end

  # Validate that all required options have values
  defp validate_required_options(selected_specs, schema) do
    missing =
      Enum.find(schema, fn opt ->
        required = opt["required"] == true
        key = opt["key"]

        required and not Map.has_key?(selected_specs, key)
      end)

    if missing do
      {:error, :missing_required_option, missing["key"]}
    else
      :ok
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

        cart =
          (item.cart_uuid && repo().get_by!(Cart, uuid: item.cart_uuid)) ||
            repo().get_by!(Cart, id: item.cart_id)

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
        cart_uuid = item.cart_uuid
        cart_id = item.cart_id
        repo().delete!(item)

        cart =
          (cart_uuid && repo().get_by!(Cart, uuid: cart_uuid)) ||
            repo().get_by!(Cart, id: cart_id)

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
        |> where([i], i.cart_uuid == ^cart.uuid)
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
            shipping_method_uuid: method.uuid,
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
  def set_cart_payment_option(%Cart{} = cart, %PaymentOption{} = option) do
    result =
      cart
      |> Cart.payment_changeset(%{
        payment_option_id: option.id,
        payment_option_uuid: option.uuid
      })
      |> repo().update()

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_payment_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  def set_cart_payment_option(%Cart{} = cart, payment_option_id)
      when is_integer(payment_option_id) do
    case Billing.get_payment_option(payment_option_id) do
      nil ->
        {:error, :payment_option_not_found}

      option ->
        set_cart_payment_option(cart, option)
    end
  end

  def set_cart_payment_option(%Cart{} = cart, nil) do
    result =
      cart
      |> Cart.payment_changeset(%{payment_option_id: nil, payment_option_uuid: nil})
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
      not is_nil(cart.payment_option_uuid) ->
        {:ok, cart}

      # No options available
      payment_options == [] ->
        {:ok, cart}

      # Only one option available - auto-select it
      length(payment_options) == 1 ->
        option = hd(payment_options)
        set_cart_payment_option(cart, option)

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
      not is_nil(cart.shipping_method_uuid) ->
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
  Accepts a user struct or user_id (integer).
  """
  def merge_guest_cart(session_id, %{id: user_id, uuid: user_uuid}) do
    do_merge_guest_cart(session_id, user_id, user_uuid)
  end

  def merge_guest_cart(session_id, user_id) when is_integer(user_id) do
    user = Auth.get_user(user_id)
    do_merge_guest_cart(session_id, user_id, user && user.uuid)
  end

  def merge_guest_cart(session_id, user_id) when is_binary(user_id) do
    user = Auth.get_user(user_id)

    if user do
      do_merge_guest_cart(session_id, user.id, user.uuid)
    else
      {:ok, nil}
    end
  end

  defp do_merge_guest_cart(session_id, user_id, user_uuid) do
    guest_cart = find_active_cart(session_id: session_id)
    user_cart = find_active_cart(user_id: user_id)

    case {guest_cart, user_cart} do
      {nil, _} ->
        {:ok, user_cart}

      {guest, nil} ->
        # Convert guest cart to user cart
        guest
        |> Cart.changeset(%{
          user_id: user_id,
          user_uuid: user_uuid,
          session_id: nil,
          expires_at: nil
        })
        |> repo().update()

      {guest, user} ->
        # Merge items into user cart
        do_merge_guest_cart_items(guest, user)
    end
  end

  defp do_merge_guest_cart_items(guest, user) do
    repo().transaction(fn ->
      # Move items from guest to user cart
      Enum.each(guest.items, fn item ->
        merge_cart_item(user, item)
      end)

      # Mark guest cart as merged
      guest
      |> Cart.status_changeset("merged", %{
        merged_into_cart_id: user.id,
        merged_into_cart_uuid: user.uuid
      })
      |> repo().update!()

      # Recalculate user cart
      recalculate_cart_totals!(user)

      repo().get_by!(Cart, uuid: user.uuid)
      |> repo().preload([:items, :shipping_method, :payment_option])
    end)
  end

  defp merge_cart_item(user_cart, item) do
    existing =
      find_cart_item_by_specs(user_cart.uuid, item.product_uuid, item.selected_specs || %{})

    case existing do
      nil ->
        attrs =
          Map.from_struct(item)
          |> Map.drop([:__meta__, :id, :uuid, :cart, :product, :inserted_at, :updated_at])
          |> Map.put(:cart_id, user_cart.id)
          |> Map.put(:cart_uuid, user_cart.uuid)

        %CartItem{}
        |> CartItem.changeset(attrs)
        |> repo().insert!()

      existing_item ->
        new_qty = existing_item.quantity + item.quantity
        existing_item |> CartItem.changeset(%{quantity: new_qty}) |> repo().update!()
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

    total = repo().aggregate(base_query, :count)

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
    |> repo().aggregate(:count)
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

  - `billing_profile_uuid: uuid` - Use existing billing profile (for logged-in users)
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

    # Wrap entire conversion in a transaction to ensure atomicity
    # If any step fails after order creation, the order is rolled back
    repo().transaction(fn ->
      # Use atomic status transition to prevent double-conversion on double-click
      # This atomically changes status from "active" to "converting" and fails
      # if another request already started conversion
      with :ok <- validate_cart_convertible(cart),
           {:ok, cart} <- try_lock_cart_for_conversion(cart),
           {:ok, user_id, cart} <- resolve_checkout_user(cart, opts),
           line_items <- build_order_line_items(cart),
           order_attrs <- build_order_attrs(cart, line_items, opts),
           {:ok, order} <- do_create_order(user_id, order_attrs),
           {:ok, _cart} <- mark_cart_converted(cart, order.id),
           :ok <- maybe_send_guest_confirmation(user_id) do
        {:ok, order}
      else
        {:error, reason} ->
          # Rollback transaction on any error, unwrapping the {:error, _} tuple
          # so the transaction returns {:error, reason} (not {:error, {:error, reason}})
          repo().rollback(reason)

        other ->
          repo().rollback(other)
      end
    end)
    # unwrap the transaction result
    |> case do
      {:ok, {:ok, order}} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_cart_convertible(%Cart{} = cart) do
    cond do
      cart.status != "active" ->
        {:error, :cart_not_active}

      Enum.empty?(cart.items) ->
        {:error, :cart_empty}

      is_nil(cart.shipping_method_id) and is_nil(cart.shipping_method_uuid) ->
        {:error, :no_shipping_method}

      true ->
        :ok
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
    billing_profile_uuid = Keyword.get(opts, :billing_profile_uuid)
    billing_data = Keyword.get(opts, :billing_data)

    # Get shipping country from billing data or cart
    shipping_country = get_shipping_country(billing_profile_uuid, billing_data, cart)

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
        "cart_uuid" => cart.uuid,
        "shipping_country" => shipping_country,
        "shipping_method_id" => cart.shipping_method_id,
        "shipping_method_uuid" => cart.shipping_method_uuid
      }
    }

    cond do
      # Logged-in user with billing profile
      not is_nil(billing_profile_uuid) ->
        Map.put(base_attrs, "billing_profile_uuid", billing_profile_uuid)

      # Guest checkout with billing data - clean up _unused_ keys from LiveView
      is_map(billing_data) ->
        cleaned_billing_data = clean_billing_data(billing_data)
        Map.put(base_attrs, "billing_snapshot", cleaned_billing_data)

      true ->
        base_attrs
    end
  end

  # Get shipping country from billing profile, billing data, or cart
  defp get_shipping_country(billing_profile_uuid, _billing_data, cart)
       when not is_nil(billing_profile_uuid) do
    case Billing.get_billing_profile(billing_profile_uuid) do
      %{country: country} when is_binary(country) -> country
      _ -> cart.shipping_country
    end
  end

  defp get_shipping_country(_billing_profile_uuid, billing_data, cart)
       when is_map(billing_data) do
    billing_data["country"] || cart.shipping_country
  end

  defp get_shipping_country(_billing_profile_uuid, _billing_data, cart) do
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
    user = Auth.get_user(user_id)

    case user && assign_cart_to_user(cart, user) do
      {:ok, updated_cart} -> {:ok, user_id, updated_cart}
      _ -> {:ok, user_id, cart}
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
        assign_cart_and_return(cart, user)

      {:error, :email_exists_unconfirmed, user} ->
        assign_cart_and_return(cart, user)

      {:error, :email_exists_confirmed} ->
        {:error, :email_already_registered}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp assign_cart_and_return(cart, %{id: user_id} = user) do
    case assign_cart_to_user(cart, user) do
      {:ok, updated_cart} -> {:ok, user_id, updated_cart}
      {:error, _} -> {:ok, user_id, cart}
    end
  end

  # Assign cart to user (for guest -> user conversion)
  defp assign_cart_to_user(%Cart{} = cart, %{id: user_id, uuid: user_uuid}) do
    cart
    |> Cart.changeset(%{user_id: user_id, user_uuid: user_uuid, session_id: nil})
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

  # Atomically transition cart from "active" to "converting" status.
  # This prevents double-conversion when user double-clicks checkout button.
  # If another request already started conversion, this returns error.
  defp try_lock_cart_for_conversion(%Cart{id: cart_id}) do
    # Use atomic UPDATE with WHERE clause to ensure only one request wins
    {count, _} =
      Cart
      |> where([c], c.id == ^cart_id and c.status == "active")
      |> repo().update_all(set: [status: "converting", updated_at: UtilsDate.utc_now()])

    if count == 1 do
      # Successfully locked - reload cart with new status
      {:ok, get_cart!(cart_id)}
    else
      # Another request already started conversion
      {:error, :cart_already_converting}
    end
  end

  defp mark_cart_converted(%Cart{} = cart, order_id) do
    cart
    |> Cart.status_changeset("converted", %{
      converted_at: UtilsDate.utc_now(),
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
    Product |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  defp count_products_by_status(status) do
    Product
    |> where([p], p.status == ^status)
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  defp count_products_by_type(product_type) do
    Product
    |> where([p], p.product_type == ^product_type)
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  defp count_categories do
    Category |> repo().aggregate(:count)
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
    |> filter_by_price_range(Keyword.get(opts, :price_min), Keyword.get(opts, :price_max))
    |> filter_by_vendors(Keyword.get(opts, :vendors))
    |> filter_by_metadata_options(Keyword.get(opts, :metadata_filters))
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [p], p.status == ^status)

  defp filter_by_product_type(query, nil), do: query
  defp filter_by_product_type(query, type), do: where(query, [p], p.product_type == ^type)

  defp filter_by_category(query, nil), do: query

  defp filter_by_category(query, id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      where(query, [p], p.category_uuid == ^id)
    else
      case Integer.parse(id) do
        {int_id, ""} -> where(query, [p], p.category_id == ^int_id)
        _ -> query
      end
    end
  end

  defp filter_by_category(query, id) when is_integer(id) do
    where(query, [p], p.category_id == ^id)
  end

  defp filter_by_visible_categories(query, false), do: query

  defp filter_by_visible_categories(query, true) do
    # Exclude products from categories with status "hidden"
    # Products from "active" and "unlisted" categories are visible
    # Use distinct to avoid duplicates from the left_join
    from(p in query,
      left_join: c in Category,
      on: c.uuid == p.category_uuid,
      where: is_nil(c.uuid) or c.status != "hidden",
      distinct: p.uuid
    )
  end

  defp filter_by_price_range(query, nil, nil), do: query
  defp filter_by_price_range(query, min, nil), do: where(query, [p], p.price >= ^min)
  defp filter_by_price_range(query, nil, max), do: where(query, [p], p.price <= ^max)

  defp filter_by_price_range(query, min, max),
    do: where(query, [p], p.price >= ^min and p.price <= ^max)

  defp filter_by_vendors(query, nil), do: query
  defp filter_by_vendors(query, []), do: query

  defp filter_by_vendors(query, vendors) when is_list(vendors),
    do: where(query, [p], p.vendor in ^vendors)

  defp filter_by_metadata_options(query, nil), do: query
  defp filter_by_metadata_options(query, []), do: query

  defp filter_by_metadata_options(query, filters) when is_list(filters) do
    Enum.reduce(filters, query, fn %{key: key, values: values}, q ->
      where(
        q,
        [p],
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'_option_values'->?, '[]'::jsonb)) elem WHERE elem = ANY(?))",
          p.metadata,
          ^key,
          ^values
        )
      )
    end)
  end

  defp filter_by_product_search(query, nil), do: query
  defp filter_by_product_search(query, ""), do: query

  defp filter_by_product_search(query, search) do
    search_term = "%#{search}%"
    default_lang = Translations.default_language()

    # Search in JSONB localized fields using PostgreSQL operators
    # Searches in default language and falls back to any language match
    where(
      query,
      [p],
      fragment(
        "(COALESCE(title->>?, '') ILIKE ? OR COALESCE(description->>?, '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_each_text(title) WHERE value ILIKE ?) OR EXISTS (SELECT 1 FROM jsonb_each_text(description) WHERE value ILIKE ?))",
        ^default_lang,
        ^search_term,
        ^default_lang,
        ^search_term,
        ^search_term,
        ^search_term
      )
    )
  end

  defp apply_category_filters(query, opts) do
    query
    |> filter_by_parent(Keyword.get(opts, :parent_id, :skip))
    |> filter_by_parent_uuid(Keyword.get(opts, :parent_uuid, :skip))
    |> filter_by_category_status(Keyword.get(opts, :status, :skip))
    |> filter_by_category_search(Keyword.get(opts, :search))
  end

  defp filter_by_parent(query, :skip), do: query
  defp filter_by_parent(query, nil), do: where(query, [c], is_nil(c.parent_id))
  defp filter_by_parent(query, id), do: where(query, [c], c.parent_id == ^id)

  defp filter_by_parent_uuid(query, :skip), do: query
  defp filter_by_parent_uuid(query, nil), do: where(query, [c], is_nil(c.parent_uuid))
  defp filter_by_parent_uuid(query, uuid), do: where(query, [c], c.parent_uuid == ^uuid)

  defp filter_by_category_status(query, :skip), do: query
  defp filter_by_category_status(query, nil), do: query

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
    default_lang = Translations.default_language()

    # Search in JSONB localized name field using PostgreSQL operators
    where(
      query,
      [c],
      fragment(
        "(COALESCE(name->>?, '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_each_text(name) WHERE value ILIKE ?))",
        ^default_lang,
        ^search_term,
        ^search_term
      )
    )
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  # Shipping filters
  defp filter_shipping_by_active(query, nil), do: query
  defp filter_shipping_by_active(query, active), do: where(query, [s], s.active == ^active)

  # Cart helpers

  # Find cart item by product and selected_specs
  defp find_cart_item_by_specs(cart_uuid, product_uuid, specs) when map_size(specs) == 0 do
    # No specs - find item without specs
    CartItem
    |> where([i], i.cart_uuid == ^cart_uuid and i.product_uuid == ^product_uuid)
    |> where([i], i.selected_specs == ^%{})
    |> repo().one()
  end

  defp find_cart_item_by_specs(cart_uuid, product_uuid, specs) when is_map(specs) do
    # With specs - find item with matching specs
    CartItem
    |> where([i], i.cart_uuid == ^cart_uuid and i.product_uuid == ^product_uuid)
    |> where([i], i.selected_specs == ^specs)
    |> repo().one()
  end

  defp recalculate_cart_totals!(%Cart{} = cart) do
    items = CartItem |> where([i], i.cart_uuid == ^cart.uuid) |> repo().all()

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

    shipping_amount = calculate_shipping(cart, subtotal, total_weight)

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

  defp calculate_shipping(cart, subtotal, total_weight) do
    if cart.shipping_method_uuid || cart.shipping_method_id do
      shipping_method =
        (cart.shipping_method_uuid &&
           repo().get_by(ShippingMethod, uuid: cart.shipping_method_uuid)) ||
          repo().get_by(ShippingMethod, id: cart.shipping_method_id)

      case shipping_method do
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
    |> where([l], l.id == ^id)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().one()
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
    case repo().get_by(ImportLog, id: id) do
      nil -> raise Ecto.NoResultsError, queryable: ImportLog
      log -> log
    end
  end

  def get_import_log!(id) when is_binary(id) do
    case get_import_log(id) do
      nil -> raise Ecto.NoResultsError, queryable: ImportLog
      log -> log
    end
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
    repo().get_by(ImportConfig, id: id)
  end

  def get_import_config(uuid) when is_binary(uuid) do
    repo().get_by(ImportConfig, uuid: uuid)
  end

  @doc """
  Gets an import config by ID, raises if not found.
  """
  def get_import_config!(id) when is_integer(id) do
    case repo().get_by(ImportConfig, id: id) do
      nil -> raise Ecto.NoResultsError, queryable: ImportConfig
      config -> config
    end
  end

  def get_import_config!(id) when is_binary(id) do
    case get_import_config(id) do
      nil -> raise Ecto.NoResultsError, queryable: ImportConfig
      config -> config
    end
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

  @doc """
  Returns a changeset for tracking import config changes.
  """
  def change_import_config(%ImportConfig{} = config, attrs \\ %{}) do
    ImportConfig.changeset(config, attrs)
  end

  @doc """
  Creates the legacy default import config if no configs exist.

  Returns `{:created, config}` if a new config was created,
  or `:exists` if configs already exist.
  """
  def ensure_default_import_config do
    if repo().aggregate(ImportConfig, :count) == 0 do
      attrs = Map.from_struct(ImportConfig.from_legacy_defaults())
      {:ok, config} = create_import_config(attrs)
      {:created, config}
    else
      :exists
    end
  end

  @doc """
  Ensures a default Prom.ua import config exists.
  Creates one if no config with name "prom_ua_default" is found.
  """
  def ensure_prom_ua_import_config do
    case repo().get_by(ImportConfig, name: "prom_ua_default") do
      nil ->
        attrs =
          ImportConfig.from_prom_ua_defaults()
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :uuid, :inserted_at, :updated_at])

        {:ok, config} = create_import_config(attrs)
        {:created, config}

      config ->
        {:exists, config}
    end
  end

  # ============================================
  # PRODUCT UPSERT
  # ============================================

  @doc """
  Creates or updates a product by slug.

  Uses explicit find-or-create pattern with proper localized field merging.
  After V47 migration, slug is a JSONB map (e.g., %{"en-US" => "my-slug"}),
  so ON CONFLICT doesn't work correctly - this function handles the lookup manually.

  Returns {:ok, product, action} where action is :inserted or :updated.

  ## Parameters

    - `attrs` - Product attributes including localized fields as maps

  ## Examples

      # Create new product
      iex> upsert_product(%{title: %{"en-US" => "Planter"}, slug: %{"en-US" => "planter"}, price: 10})
      {:ok, %Product{}, :inserted}

      # Update existing product (found by slug)
      iex> upsert_product(%{title: %{"en-US" => "Planter V2"}, slug: %{"en-US" => "planter"}, price: 15})
      {:ok, %Product{}, :updated}

      # Add translation to existing product
      iex> upsert_product(%{title: %{"es-ES" => "Maceta"}, slug: %{"es-ES" => "maceta", "en-US" => "planter"}, price: 10})
      {:ok, %Product{title: %{"en-US" => "Planter", "es-ES" => "Maceta"}}, :updated}

  """
  def upsert_product(attrs) do
    slug_map = get_attr(attrs, :slug) || %{}

    case find_product_by_slug_map(slug_map) do
      nil ->
        # New product - create it
        case create_product(attrs) do
          {:ok, product} -> {:ok, product, :inserted}
          error -> error
        end

      existing ->
        # Existing product - merge localized fields and update
        merged_attrs = merge_localized_attrs(existing, attrs)

        case update_product(existing, merged_attrs) do
          {:ok, product} -> {:ok, product, :updated}
          error -> error
        end
    end
  end

  @doc """
  Finds an existing product by any slug in the provided slug map.

  Searches through each slug value in the map to find a matching product.
  Returns the first product found, or nil if no match.

  ## Examples

      iex> find_product_by_slug_map(%{"en-US" => "planter"})
      %Product{} | nil

      iex> find_product_by_slug_map(%{"en-US" => "planter", "es-ES" => "maceta"})
      %Product{} | nil  # Finds by first matching slug
  """
  def find_product_by_slug_map(slug_map) when map_size(slug_map) == 0, do: nil

  def find_product_by_slug_map(slug_map) when is_map(slug_map) do
    # Try to find by any slug in the map
    Enum.find_value(slug_map, fn {lang, slug} ->
      case get_product_by_slug_localized(slug, lang) do
        {:ok, product} -> product
        _ -> nil
      end
    end)
  end

  @doc """
  Merges localized fields from new attributes into existing product.

  Preserves existing translations while adding new ones from attrs.
  Non-localized fields are replaced entirely.

  ## Examples

      iex> merge_localized_attrs(%Product{title: %{"en-US" => "Old"}}, %{title: %{"es-ES" => "Nuevo"}})
      %{title: %{"en-US" => "Old", "es-ES" => "Nuevo"}}
  """
  def merge_localized_attrs(existing, new_attrs) do
    localized_fields = [:title, :slug, :description, :body_html, :seo_title, :seo_description]

    # Start with all new attrs
    Enum.reduce(localized_fields, new_attrs, fn field, acc ->
      existing_map = Map.get(existing, field) || %{}
      new_map = get_attr(acc, field) || %{}

      # Only merge if there's something to merge
      if map_size(new_map) > 0 do
        # Merge: new values take precedence for same language
        merged = Map.merge(existing_map, new_map)
        put_attr(acc, field, merged)
      else
        acc
      end
    end)
  end

  # Helper to get attribute from either atom or string keyed map
  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  # Helper to put attribute preserving the map's key type
  defp put_attr(attrs, key, value) when is_atom(key) do
    cond do
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Map.has_key?(attrs, to_string(key)) -> Map.put(attrs, to_string(key), value)
      true -> Map.put(attrs, key, value)
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
      lang -> DialectMapper.extract_base(lang.code)
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

  # Checks if a list of IDs contains UUID strings (vs integers)
  defp ids_are_uuids?([]), do: false

  defp ids_are_uuids?([first | _]) when is_binary(first),
    do: match?({:ok, _}, Ecto.UUID.cast(first))

  defp ids_are_uuids?(_), do: false
end
