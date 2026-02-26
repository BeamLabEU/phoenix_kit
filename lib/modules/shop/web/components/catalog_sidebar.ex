defmodule PhoenixKit.Modules.Shop.Web.Components.CatalogSidebar do
  @moduledoc """
  Reusable sidebar component for the shop storefront.

  Renders collapsible filter sections and category tree navigation.
  Uses native HTML `<details>/<summary>` for collapse behavior.
  """

  use Phoenix.Component

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Web.Components.FilterHelpers
  alias PhoenixKitWeb.Components.Core.Icon

  @doc """
  Renders the full catalog sidebar with filters and category tree.

  ## Attributes
  - `filters` - List of enabled filter definitions
  - `filter_values` - Map of aggregated values per filter key
  - `active_filters` - Map of currently active filter selections
  - `categories` - List of active categories for navigation
  - `current_category` - Currently selected category (or nil)
  - `current_language` - Current language code
  - `category_icon_mode` - Icon mode setting
  - `category_name_wrap` - Whether to wrap category names
  - `show_categories` - Whether to show category tree (default: true)
  - `show_filters` - Whether to show filter sections (default: true)
  """
  attr :filters, :list, required: true
  attr :filter_values, :map, required: true
  attr :active_filters, :map, required: true
  attr :categories, :list, default: []
  attr :current_category, :any, default: nil
  attr :current_language, :string, default: "en"
  attr :category_icon_mode, :string, default: "none"
  attr :category_name_wrap, :boolean, default: false
  attr :show_categories, :boolean, default: true
  attr :show_filters, :boolean, default: true
  attr :filter_qs, :string, default: ""

  def catalog_sidebar(assigns) do
    assigns =
      assigns
      |> assign(:has_active, FilterHelpers.has_active_filters?(assigns.active_filters))
      |> assign(:categories_open, true)

    ~H"""
    <div class="space-y-1">
      <%!-- FILTERS (price, vendor, metadata) --%>
      <%= if @show_filters do %>
        <%!-- Active filters summary + clear button --%>
        <%= if @has_active do %>
          <div class="mb-3">
            <button phx-click="clear_filters" class="btn btn-outline btn-error btn-xs w-full gap-1">
              <.icon name="hero-x-mark" class="w-3 h-3" /> Clear all filters
            </button>
          </div>
        <% end %>

        <%!-- Filter sections --%>
        <%= for filter <- @filters do %>
          <.filter_section
            filter={filter}
            values={Map.get(@filter_values, filter["key"], %{})}
            active={Map.get(@active_filters, filter["key"])}
          />
        <% end %>
      <% end %>

      <%!-- CATEGORY NAVIGATION (separate from filters) --%>
      <%= if @show_categories && @categories != [] do %>
        <details open={@categories_open} class="group border-t border-base-200 pt-2 mt-2">
          <summary class="cursor-pointer font-semibold text-sm py-2 select-none flex items-center gap-1">
            <.icon
              name="hero-chevron-right"
              class="w-3 h-3 transition-transform group-open:rotate-90"
            /> Categories <span class="badge badge-ghost badge-xs ml-1">{length(@categories)}</span>
          </summary>
          <div class="pt-1 max-h-64 overflow-y-auto">
            <ul class="menu menu-sm p-0">
              <li>
                <.link
                  navigate={Shop.catalog_url(@current_language) <> @filter_qs}
                  class={if is_nil(@current_category), do: "active", else: ""}
                >
                  <.icon name="hero-home" class="w-4 h-4" /> All Products
                </.link>
              </li>
              <%= for cat <- @categories do %>
                <% cat_name = Translations.get(cat, :name, @current_language) %>
                <li>
                  <.link
                    navigate={Shop.category_url(cat, @current_language) <> @filter_qs}
                    class={
                      if @current_category && cat.uuid == @current_category.uuid,
                        do: "active",
                        else: ""
                    }
                  >
                    <.sidebar_cat_icon mode={@category_icon_mode} category={cat} />
                    <span class={
                      if(@category_name_wrap,
                        do: "break-words leading-tight",
                        else: "truncate block"
                      )
                    }>
                      {cat_name}
                    </span>
                  </.link>
                </li>
              <% end %>
            </ul>
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders only the category navigation tree (no filters).

  Lightweight component for pages where filters don't apply (e.g. product detail).

  ## Attributes
  - `categories` - List of active categories for navigation
  - `current_category` - Currently selected category (or nil)
  - `current_language` - Current language code
  - `category_icon_mode` - Icon mode setting
  - `category_name_wrap` - Whether to wrap category names
  - `open` - Whether the details element is open (default: true)
  """
  attr :categories, :list, required: true
  attr :current_category, :any, default: nil
  attr :current_language, :string, default: "en"
  attr :category_icon_mode, :string, default: "none"
  attr :category_name_wrap, :boolean, default: false
  attr :open, :boolean, default: true
  attr :filter_qs, :string, default: ""

  def category_nav(assigns) do
    ~H"""
    <%= if @categories != [] do %>
      <details open={@open} class="group">
        <summary class="cursor-pointer font-semibold text-sm py-2 select-none flex items-center gap-1">
          <.icon
            name="hero-chevron-right"
            class="w-3 h-3 transition-transform group-open:rotate-90"
          /> Categories <span class="badge badge-ghost badge-xs ml-1">{length(@categories)}</span>
        </summary>
        <div class="pt-1 max-h-64 overflow-y-auto">
          <ul class="menu menu-sm p-0">
            <li>
              <.link
                navigate={Shop.catalog_url(@current_language) <> @filter_qs}
                class={if is_nil(@current_category), do: "active", else: ""}
              >
                <.icon name="hero-home" class="w-4 h-4" /> All Products
              </.link>
            </li>
            <%= for cat <- @categories do %>
              <% cat_name = Translations.get(cat, :name, @current_language) %>
              <li>
                <.link
                  navigate={Shop.category_url(cat, @current_language) <> @filter_qs}
                  class={
                    if @current_category && cat.uuid == @current_category.uuid, do: "active", else: ""
                  }
                >
                  <.sidebar_cat_icon mode={@category_icon_mode} category={cat} />
                  <span class={
                    if(@category_name_wrap,
                      do: "break-words leading-tight",
                      else: "truncate block"
                    )
                  }>
                    {cat_name}
                  </span>
                </.link>
              </li>
            <% end %>
          </ul>
        </div>
      </details>
    <% end %>
    """
  end

  @doc """
  Renders a single filter section.

  Dispatches to the correct sub-component based on filter type.
  """
  attr :filter, :map, required: true
  attr :values, :any, required: true
  attr :active, :any, default: nil

  def filter_section(%{filter: %{"type" => "price_range"}} = assigns) do
    min_val = if assigns.active, do: assigns.active[:min]
    max_val = if assigns.active, do: assigns.active[:max]
    range = assigns.values

    assigns =
      assigns
      |> assign(:min_val, min_val)
      |> assign(:max_val, max_val)
      |> assign(:range_min, range[:min])
      |> assign(:range_max, range[:max])

    ~H"""
    <details
      open
      class="group border-t border-base-200 pt-2 mt-2 first:border-t-0 first:mt-0 first:pt-0"
    >
      <summary class="cursor-pointer font-semibold text-sm py-2 select-none flex items-center gap-1">
        <.icon name="hero-chevron-right" class="w-3 h-3 transition-transform group-open:rotate-90" />
        {@filter["label"]}
      </summary>
      <div class="pt-1 pb-2">
        <form phx-submit="filter_price" class="space-y-2">
          <input type="hidden" name="filter_key" value={@filter["key"]} />
          <div class="flex gap-2 items-center">
            <input
              type="number"
              name="price_min"
              value={@min_val && Decimal.to_string(@min_val)}
              placeholder={
                if @range_min, do: Decimal.round(@range_min, 0) |> Decimal.to_string(), else: "Min"
              }
              class="input input-sm w-full"
              min="0"
              step="any"
            />
            <span class="text-base-content/50">—</span>
            <input
              type="number"
              name="price_max"
              value={@max_val && Decimal.to_string(@max_val)}
              placeholder={
                if @range_max, do: Decimal.round(@range_max, 0) |> Decimal.to_string(), else: "Max"
              }
              class="input input-sm w-full"
              min="0"
              step="any"
            />
          </div>
          <%= if @range_min && @range_max do %>
            <p class="text-xs text-base-content/50">
              Range: {Decimal.round(@range_min, 2) |> Decimal.to_string()} – {Decimal.round(
                @range_max,
                2
              )
              |> Decimal.to_string()}
            </p>
          <% end %>
          <button type="submit" class="btn btn-primary btn-xs w-full gap-1">
            <.icon name="hero-funnel" class="w-3 h-3" /> Apply
          </button>
        </form>
      </div>
    </details>
    """
  end

  def filter_section(%{filter: %{"type" => type}} = assigns)
      when type in ["vendor", "metadata_option"] do
    values = if is_list(assigns.values), do: assigns.values, else: []
    active_list = assigns.active || []
    assigns = assign(assigns, values: values, active_list: active_list)

    ~H"""
    <details
      open
      class="group border-t border-base-200 pt-2 mt-2 first:border-t-0 first:mt-0 first:pt-0"
    >
      <summary class="cursor-pointer font-semibold text-sm py-2 select-none flex items-center gap-1">
        <.icon name="hero-chevron-right" class="w-3 h-3 transition-transform group-open:rotate-90" />
        {@filter["label"]}
        <%= if @active_list != [] do %>
          <span class="badge badge-primary badge-xs ml-1">{length(@active_list)}</span>
        <% end %>
      </summary>
      <div class="pt-1 pb-2 max-h-48 overflow-y-auto space-y-1">
        <%= if @values == [] do %>
          <p class="text-xs text-base-content/40 italic">No options available</p>
        <% else %>
          <%= for item <- @values do %>
            <label class="flex items-center gap-2 cursor-pointer hover:bg-base-200 rounded px-1 py-0.5">
              <input
                type="checkbox"
                class="checkbox checkbox-primary checkbox-xs"
                checked={item.value in @active_list}
                phx-click="toggle_filter"
                phx-value-key={@filter["key"]}
                phx-value-val={item.value}
              />
              <span class="text-sm flex-1 truncate">{item.value}</span>
              <span class="badge badge-ghost badge-xs">{item.count}</span>
            </label>
          <% end %>
        <% end %>
      </div>
    </details>
    """
  end

  def filter_section(assigns) do
    ~H"""
    """
  end

  @doc """
  Renders a compact filter list for the dashboard sidebar.

  Simplified version without category tree, designed to fit
  below the dashboard tab navigation.
  """
  attr :filters, :list, required: true
  attr :filter_values, :map, required: true
  attr :active_filters, :map, required: true

  def dashboard_filters(assigns) do
    assigns =
      assign(assigns, :has_active, FilterHelpers.has_active_filters?(assigns.active_filters))

    ~H"""
    <div class="space-y-1">
      <%= if @has_active do %>
        <button phx-click="clear_filters" class="btn btn-outline btn-error btn-xs w-full gap-1 mb-1">
          <.icon name="hero-x-mark" class="w-3 h-3" /> Clear filters
        </button>
      <% end %>

      <%= for filter <- @filters do %>
        <.filter_section
          filter={filter}
          values={Map.get(@filter_values, filter["key"], %{})}
          active={Map.get(@active_filters, filter["key"])}
        />
      <% end %>
    </div>
    """
  end

  # Category icon component for sidebar
  attr :mode, :string, required: true
  attr :category, :any, required: true

  def sidebar_cat_icon(%{mode: "folder"} = assigns) do
    ~H"""
    <.icon name="hero-folder" class="w-4 h-4 shrink-0" />
    """
  end

  def sidebar_cat_icon(%{mode: "category"} = assigns) do
    image_url = Category.get_image_url(assigns.category, size: "thumbnail")
    assigns = assign(assigns, :image_url, image_url)

    ~H"""
    <%= if @image_url do %>
      <img src={@image_url} alt="" class="w-4 h-4 rounded object-cover shrink-0" />
    <% end %>
    """
  end

  def sidebar_cat_icon(assigns) do
    ~H"""
    """
  end

  defp icon(assigns) do
    Icon.icon(assigns)
  end
end
