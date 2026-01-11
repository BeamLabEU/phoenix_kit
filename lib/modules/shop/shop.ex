defmodule PhoenixKit.Modules.Shop do
  @moduledoc """
  E-commerce Shop Module for PhoenixKit.

  Provides comprehensive e-commerce functionality including products, categories,
  variants, inventory, and cart management.

  ## Features

  - **Products**: Physical and digital products with JSONB flexibility
  - **Categories**: Hierarchical product categories
  - **Variants**: Product variants (size, color, etc.) with individual pricing
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
  alias PhoenixKit.Modules.Shop.Cart
  alias PhoenixKit.Modules.Shop.CartItem
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.Product
  alias PhoenixKit.Modules.Shop.ShippingMethod
  alias PhoenixKit.Settings

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
  end

  @doc """
  Disables the shop system.
  """
  def disable_system do
    Settings.update_setting("shop_enabled", "false")
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
  """
  def get_product_by_slug(slug, opts \\ []) do
    Product
    |> where([p], p.slug == ^slug)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().one()
  end

  @doc """
  Creates a new product.
  """
  def create_product(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a product.
  """
  def update_product(%Product{} = product, attrs) do
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

  # ============================================
  # CATEGORIES
  # ============================================

  @doc """
  Lists all categories.

  ## Options
  - `:parent_id` - Filter by parent (nil for root categories)
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
  """
  def get_category_by_slug(slug, opts \\ []) do
    Category
    |> where([c], c.slug == ^slug)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().one()
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
  """
  def category_options do
    Category
    |> order_by([c], [c.position, c.name])
    |> select([c], {c.name, c.id})
    |> repo().all()
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
  """
  def find_active_cart(opts) do
    user_id = Keyword.get(opts, :user_id)
    session_id = Keyword.get(opts, :session_id)

    query = Cart |> where([c], c.status == "active")

    query =
      cond do
        not is_nil(user_id) ->
          where(query, [c], c.user_id == ^user_id)

        not is_nil(session_id) ->
          where(query, [c], c.session_id == ^session_id and is_nil(c.user_id))

        true ->
          # No identity provided, return nil
          where(query, [c], false)
      end

    query
    |> preload([:items, :shipping_method])
    |> repo().one()
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
    |> preload([:items, :shipping_method])
    |> repo().get(id)
  end

  @doc """
  Gets a cart by ID, raises if not found.
  """
  def get_cart!(id) do
    Cart
    |> preload([:items, :shipping_method])
    |> repo().get!(id)
  end

  @doc """
  Adds item to cart.
  """
  def add_to_cart(%Cart{} = cart, %Product{} = product, quantity \\ 1) do
    repo().transaction(fn ->
      # Check if product already in cart
      existing = find_cart_item(cart.id, product.id)

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
      recalculate_cart_totals!(cart)
    end)
  end

  @doc """
  Updates item quantity in cart.
  """
  def update_cart_item(%CartItem{} = item, quantity) when quantity > 0 do
    repo().transaction(fn ->
      item
      |> CartItem.changeset(%{quantity: quantity})
      |> repo().update!()

      cart = repo().get!(Cart, item.cart_id)
      recalculate_cart_totals!(cart)
    end)
  end

  def update_cart_item(%CartItem{} = item, 0), do: remove_from_cart(item)

  @doc """
  Removes item from cart.
  """
  def remove_from_cart(%CartItem{} = item) do
    repo().transaction(fn ->
      cart_id = item.cart_id
      repo().delete!(item)

      cart = repo().get!(Cart, cart_id)
      recalculate_cart_totals!(cart)
    end)
  end

  @doc """
  Clears all items from cart.
  """
  def clear_cart(%Cart{} = cart) do
    repo().transaction(fn ->
      CartItem
      |> where([i], i.cart_id == ^cart.id)
      |> repo().delete_all()

      recalculate_cart_totals!(cart)
    end)
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
            existing = find_cart_item(user.id, item.product_id)

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

          repo().get!(Cart, user.id) |> repo().preload([:items, :shipping_method])
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
  # PRIVATE HELPERS
  # ============================================

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
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [p], p.status == ^status)

  defp filter_by_product_type(query, nil), do: query
  defp filter_by_product_type(query, type), do: where(query, [p], p.product_type == ^type)

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, id), do: where(query, [p], p.category_id == ^id)

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
    |> filter_by_category_search(Keyword.get(opts, :search))
  end

  defp filter_by_parent(query, :skip), do: query
  defp filter_by_parent(query, nil), do: where(query, [c], is_nil(c.parent_id))
  defp filter_by_parent(query, id), do: where(query, [c], c.parent_id == ^id)

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
  defp find_cart_item(cart_id, product_id) do
    CartItem
    |> where([i], i.cart_id == ^cart_id and i.product_id == ^product_id)
    |> where([i], is_nil(i.variant_id))
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
end
