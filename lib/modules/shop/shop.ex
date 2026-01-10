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

  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.Product
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
      currency: Settings.get_setting_cached("shop_currency", "USD"),
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
      default_currency: Settings.get_setting("shop_currency", "USD")
    }
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

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
