defmodule PhoenixKit.Modules.Shop.Web.ProductForm do
  @moduledoc """
  Product create/edit form LiveView for Shop module.

  Includes dynamic option fields based on merged global + category schema,
  and displays option prices table for options that affect pricing.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.Product
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "New Product")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = apply_action(socket, socket.assigns.live_action, params)
    {:noreply, socket}
  end

  defp apply_action(socket, :new, _params) do
    product = %Product{}
    changeset = Shop.change_product(product)
    categories = Shop.category_options()

    # Get global options (no category selected yet)
    option_schema = Options.get_global_options()
    price_affecting_options = get_price_affecting_options(option_schema)

    socket
    |> assign(:page_title, "New Product")
    |> assign(:product, product)
    |> assign(:changeset, changeset)
    |> assign(:categories, categories)
    |> assign(:option_schema, option_schema)
    |> assign(:metadata, %{})
    |> assign(:price_affecting_options, price_affecting_options)
    |> assign(:show_media_selector, false)
    |> assign(:media_selection_mode, :single)
    |> assign(:media_selection_target, nil)
    |> assign(:featured_image_id, nil)
    |> assign(:gallery_image_ids, [])
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    product = Shop.get_product!(id, preload: [:category])
    changeset = Shop.change_product(product)
    categories = Shop.category_options()

    # Get merged option schema for the product
    option_schema = Options.get_option_schema_for_product(product)
    metadata = product.metadata || %{}
    price_affecting_options = get_price_affecting_options(option_schema)

    # Calculate price range for display (pass metadata for custom modifiers)
    base_price = product.price || Decimal.new("0")

    {min_price, max_price} =
      Options.get_price_range(price_affecting_options, base_price, metadata)

    socket
    |> assign(:page_title, "Edit #{product.title}")
    |> assign(:product, product)
    |> assign(:changeset, changeset)
    |> assign(:categories, categories)
    |> assign(:option_schema, option_schema)
    |> assign(:metadata, metadata)
    |> assign(:price_affecting_options, price_affecting_options)
    |> assign(:min_price, min_price)
    |> assign(:max_price, max_price)
    |> assign(:show_media_selector, false)
    |> assign(:media_selection_mode, :single)
    |> assign(:media_selection_target, nil)
    |> assign(:featured_image_id, product.featured_image_id)
    |> assign(:gallery_image_ids, product.image_ids || [])
  end

  @impl true
  def handle_event("validate", %{"product" => product_params}, socket) do
    changeset =
      socket.assigns.product
      |> Shop.change_product(product_params)
      |> Map.put(:action, :validate)

    # Update option schema if category changed
    new_category_id = product_params["category_id"]
    old_category_id = socket.assigns.product.category_id

    socket =
      if new_category_id != to_string(old_category_id) do
        option_schema = get_schema_for_category_id(new_category_id)
        price_affecting_options = get_price_affecting_options(option_schema)

        socket
        |> assign(:option_schema, option_schema)
        |> assign(:price_affecting_options, price_affecting_options)
      else
        socket
      end

    # Update metadata from form params
    # Convert final_price inputs to modifier values for proper preview
    base_price = parse_decimal(product_params["price"])
    raw_metadata = product_params["metadata"] || %{}
    metadata = convert_final_prices_to_modifiers(raw_metadata, base_price)

    # Update price range when price changes
    socket =
      if socket.assigns.live_action == :edit do
        new_price = product_params["price"]

        if new_price && new_price != "" do
          base_price = Decimal.new(new_price)

          {min_price, max_price} =
            Options.get_price_range(
              socket.assigns.price_affecting_options,
              base_price,
              metadata
            )

          socket
          |> assign(:min_price, min_price)
          |> assign(:max_price, max_price)
        else
          socket
        end
      else
        socket
      end

    socket
    |> assign(:changeset, changeset)
    |> assign(:metadata, metadata)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_event("save", %{"product" => product_params}, socket) do
    # Merge metadata into product params
    metadata = product_params["metadata"] || %{}
    base_price = parse_decimal(product_params["price"])

    # Convert final_price inputs to modifier values
    metadata = convert_final_prices_to_modifiers(metadata, base_price)

    # Clean up _option_values - remove entries where all values are selected
    metadata = clean_option_values(metadata, socket.assigns.option_schema)

    # Clean up metadata - convert multiselect arrays if needed
    cleaned_metadata =
      metadata
      |> Enum.map(fn
        {k, v} when is_list(v) -> {k, Enum.reject(v, &(&1 == ""))}
        {k, v} -> {k, v}
      end)
      |> Map.new()

    product_params = Map.put(product_params, "metadata", cleaned_metadata)

    # Add Storage image IDs from socket assigns
    product_params =
      product_params
      |> Map.put("featured_image_id", socket.assigns.featured_image_id)
      |> Map.put("image_ids", socket.assigns.gallery_image_ids)

    save_product(socket, socket.assigns.live_action, product_params)
  end

  # ===========================================
  # IMAGE MANAGEMENT
  # ===========================================

  def handle_event("open_media_picker", %{"target" => "featured"}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:media_selection_mode, :single)
     |> assign(:media_selection_target, :featured)}
  end

  def handle_event("open_media_picker", %{"target" => "gallery"}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:media_selection_mode, :multiple)
     |> assign(:media_selection_target, :gallery)}
  end

  def handle_event("remove_featured_image", _params, socket) do
    {:noreply, assign(socket, :featured_image_id, nil)}
  end

  def handle_event("remove_gallery_image", %{"id" => id}, socket) do
    updated = Enum.reject(socket.assigns.gallery_image_ids, &(&1 == id))
    {:noreply, assign(socket, :gallery_image_ids, updated)}
  end

  @impl true
  def handle_info({:media_selected, file_ids}, socket) do
    socket = apply_media_selection(socket, socket.assigns.media_selection_target, file_ids)

    {:noreply, assign(socket, :show_media_selector, false)}
  end

  @impl true
  def handle_info({:media_selector_closed}, socket) do
    {:noreply, assign(socket, :show_media_selector, false)}
  end

  defp apply_media_selection(socket, :featured, file_ids) do
    assign(socket, :featured_image_id, List.first(file_ids))
  end

  defp apply_media_selection(socket, :gallery, file_ids) do
    current = socket.assigns.gallery_image_ids
    new_ids = Enum.reject(file_ids, &(&1 in current))
    assign(socket, :gallery_image_ids, current ++ new_ids)
  end

  defp apply_media_selection(socket, _, _), do: socket

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp save_product(socket, :new, product_params) do
    case Shop.create_product(product_params) do
      {:ok, product} ->
        {:noreply,
         socket
         |> put_flash(:info, "Product created")
         |> push_navigate(to: Routes.path("/admin/shop/products/#{product.id}"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_product(socket, :edit, product_params) do
    case Shop.update_product(socket.assigns.product, product_params) do
      {:ok, product} ->
        changeset = Shop.change_product(product)

        {:noreply,
         socket
         |> assign(:product, product)
         |> assign(:changeset, changeset)
         |> put_flash(:info, "Product updated")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  # Get options with affects_price=true
  defp get_price_affecting_options(option_schema) do
    Enum.filter(option_schema, fn opt ->
      Map.get(opt, "affects_price", false) == true
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path}
      current_locale={@current_locale}
      page_title={@page_title}
    >
      <div class="container flex-col mx-auto px-4 py-6 max-w-4xl">
        <%!-- Header (centered pattern) --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={Routes.path("/admin/shop/products")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
          </.link>
          <div class="text-center pt-10 sm:pt-0">
            <h1 class="text-4xl font-bold text-base-content mb-3">{@page_title}</h1>
            <p class="text-lg text-base-content/70">
              {if @live_action == :new, do: "Create a new product", else: "Edit product details"}
            </p>
          </div>
        </header>

        <%!-- Form --%>
        <.form
          for={@changeset}
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <%!-- Card 1: Basic Info & Organization --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Product Details</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-4">
                <%!-- Row 1: Title + Status --%>
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Title *</span>
                  </label>
                  <input
                    type="text"
                    name="product[title]"
                    value={Ecto.Changeset.get_field(@changeset, :title)}
                    class={[
                      "input input-bordered w-full focus:input-primary",
                      @changeset.errors[:title] && "input-error"
                    ]}
                    placeholder="Product title"
                    required
                  />
                  <%= if @changeset.errors[:title] do %>
                    <label class="label py-1">
                      <span class="label-text-alt text-error">
                        {elem(@changeset.errors[:title], 0)}
                      </span>
                    </label>
                  <% end %>
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Status</span>
                  </label>
                  <select
                    name="product[status]"
                    class="select select-bordered w-full focus:select-primary"
                  >
                    <option
                      value="draft"
                      selected={Ecto.Changeset.get_field(@changeset, :status) == "draft"}
                    >
                      Draft
                    </option>
                    <option
                      value="active"
                      selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}
                    >
                      Active
                    </option>
                    <option
                      value="archived"
                      selected={Ecto.Changeset.get_field(@changeset, :status) == "archived"}
                    >
                      Archived
                    </option>
                  </select>
                </div>

                <%!-- Row 2: Slug + Vendor --%>
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Slug</span>
                  </label>
                  <input
                    type="text"
                    name="product[slug]"
                    value={Ecto.Changeset.get_field(@changeset, :slug)}
                    class="input input-bordered w-full focus:input-primary"
                    placeholder="Auto-generated from title"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Vendor</span>
                  </label>
                  <input
                    type="text"
                    name="product[vendor]"
                    value={Ecto.Changeset.get_field(@changeset, :vendor)}
                    class="input input-bordered w-full focus:input-primary"
                    placeholder="Brand or manufacturer"
                  />
                </div>

                <%!-- Row 3: Product Type + Category --%>
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Product Type</span>
                  </label>
                  <select
                    name="product[product_type]"
                    class="select select-bordered w-full focus:select-primary"
                  >
                    <option
                      value="physical"
                      selected={Ecto.Changeset.get_field(@changeset, :product_type) == "physical"}
                    >
                      Physical
                    </option>
                    <option
                      value="digital"
                      selected={Ecto.Changeset.get_field(@changeset, :product_type) == "digital"}
                    >
                      Digital
                    </option>
                  </select>
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Category</span>
                  </label>
                  <select
                    name="product[category_id]"
                    class="select select-bordered w-full focus:select-primary"
                  >
                    <option value="">No category</option>
                    <%= for {name, id} <- @categories do %>
                      <option
                        value={id}
                        selected={Ecto.Changeset.get_field(@changeset, :category_id) == id}
                      >
                        {name}
                      </option>
                    <% end %>
                  </select>
                </div>

                <%!-- Row 4: Description (full width) --%>
                <div class="form-control w-full md:col-span-2">
                  <label class="label">
                    <span class="label-text font-medium">Description</span>
                  </label>
                  <textarea
                    name="product[description]"
                    class="textarea textarea-bordered w-full h-24 focus:textarea-primary"
                    placeholder="Short product description"
                  >{Ecto.Changeset.get_field(@changeset, :description)}</textarea>
                </div>
              </div>
            </div>
          </div>

          <%!-- Card 2: Pricing --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Pricing</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-4">
                <%!-- Row 1: Base Price + Compare Price --%>
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Base Price *</span>
                  </label>
                  <input
                    type="number"
                    name="product[price]"
                    value={Ecto.Changeset.get_field(@changeset, :price)}
                    class={[
                      "input input-bordered w-full focus:input-primary",
                      @changeset.errors[:price] && "input-error"
                    ]}
                    step="0.01"
                    min="0"
                    required
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Compare at Price</span>
                  </label>
                  <input
                    type="number"
                    name="product[compare_at_price]"
                    value={Ecto.Changeset.get_field(@changeset, :compare_at_price)}
                    class="input input-bordered w-full focus:input-primary"
                    step="0.01"
                    min="0"
                    placeholder="Original price"
                  />
                </div>

                <%!-- Row 2: Cost + Taxable --%>
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Cost per Item</span>
                  </label>
                  <input
                    type="number"
                    name="product[cost_per_item]"
                    value={Ecto.Changeset.get_field(@changeset, :cost_per_item)}
                    class="input input-bordered w-full focus:input-primary"
                    step="0.01"
                    min="0"
                    placeholder="Your cost for profit calculation"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Tax Settings</span>
                  </label>
                  <label class="label cursor-pointer justify-start gap-3 h-12 px-4 bg-base-200 rounded-lg">
                    <input
                      type="checkbox"
                      name="product[taxable]"
                      value="true"
                      checked={Ecto.Changeset.get_field(@changeset, :taxable)}
                      class="checkbox checkbox-primary"
                    />
                    <span class="label-text">Charge tax on this product</span>
                  </label>
                </div>
              </div>
            </div>
          </div>

          <%!-- Available Option Values Section --%>
          <% select_options =
            Enum.filter(@option_schema, fn opt ->
              opt["type"] in ["select", "multiselect"] and length(opt["options"] || []) > 1
            end) %>
          <%= if select_options != [] and @live_action == :edit do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <.icon name="hero-adjustments-horizontal" class="w-5 h-5" /> Available Options
                </h2>
                <p class="text-sm text-base-content/60 mb-4">
                  Select which option values are available for this product.
                  Uncheck values that don't apply.
                </p>

                <div class="space-y-4">
                  <%= for option <- select_options do %>
                    <% option_key = option["key"] %>
                    <% all_values = option["options"] || [] %>
                    <% custom_values = get_custom_option_values(@metadata, option_key) %>
                    <% active_values = if custom_values, do: custom_values, else: all_values %>

                    <div class="p-4 bg-base-200 rounded-lg">
                      <div class="flex items-center justify-between mb-3">
                        <span class="font-medium">{option["label"]}</span>
                        <%= if custom_values do %>
                          <span class="badge badge-warning badge-sm">Custom selection</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">All values</span>
                        <% end %>
                      </div>
                      <div class="flex flex-wrap gap-3">
                        <%= for value <- all_values do %>
                          <label class="label cursor-pointer gap-2 p-0">
                            <input
                              type="checkbox"
                              name={"product[metadata][_option_values][#{option_key}][]"}
                              value={value}
                              checked={value in active_values}
                              class="checkbox checkbox-sm checkbox-primary"
                            />
                            <span class="label-text">{value}</span>
                          </label>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Option Price Modifiers Section --%>
          <%= if @price_affecting_options != [] do %>
            <%!-- Editable options: has allow_override flag --%>
            <% editable_options =
              Enum.filter(@price_affecting_options, fn opt ->
                opt["allow_override"] == true
              end) %>
            <%!-- Read-only options: without allow_override --%>
            <% readonly_options =
              Enum.reject(@price_affecting_options, fn opt ->
                opt["allow_override"] == true
              end) %>

            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <.icon name="hero-calculator" class="w-5 h-5" /> Option Prices
                </h2>
                <p class="text-sm text-base-content/60 mb-4">
                  Base price:
                  <span class="font-semibold">
                    {format_price(Ecto.Changeset.get_field(@changeset, :price))}
                  </span>
                  — Options that affect the final price
                </p>

                <%!-- Editable Options (Allow Override) --%>
                <%= if editable_options != [] do %>
                  <div class="mb-6">
                    <h3 class="text-sm font-semibold mb-3 flex items-center gap-2">
                      <span class="badge badge-warning badge-sm">Editable</span>
                      Per-product price modifiers
                    </h3>
                    <p class="text-xs text-base-content/60 mb-3">
                      Leave as "Default" to use global option values, or set custom values per-product.
                    </p>
                    <div class="space-y-4">
                      <%= for option <- editable_options do %>
                        <div class="p-4 bg-base-200 rounded-lg">
                          <div class="font-medium mb-3 flex items-center gap-2">
                            {option["label"]}
                            <span class="badge badge-xs badge-outline">
                              Default: {option["modifier_type"] || "fixed"}
                            </span>
                          </div>
                          <div class="overflow-x-auto">
                            <% base_price =
                              Ecto.Changeset.get_field(@changeset, :price) || Decimal.new("0") %>
                            <table class="table table-xs">
                              <thead>
                                <tr>
                                  <th>Value</th>
                                  <th>Default Price</th>
                                  <th>Custom Price</th>
                                </tr>
                              </thead>
                              <tbody>
                                <%= for opt_value <- option["options"] || [] do %>
                                  <% default_val =
                                    get_in(option, ["price_modifiers", opt_value]) || "0" %>
                                  <% default_type = option["modifier_type"] || "fixed" %>
                                  <% default_final =
                                    calculate_option_price(base_price, default_type, default_val) %>
                                  <% override =
                                    get_modifier_override(@metadata, option["key"], opt_value) %>
                                  <% custom_final =
                                    if override,
                                      do:
                                        calculate_option_price(
                                          base_price,
                                          override["type"] || "fixed",
                                          override["value"] || "0"
                                        ),
                                      else: nil %>
                                  <tr>
                                    <td class="font-medium">{opt_value}</td>
                                    <td class="text-base-content/60">
                                      {format_price(default_final)}
                                      <span class="text-xs opacity-60">
                                        (<%= if default_type == "percent" do %>
                                          +{default_val}%
                                        <% else %>
                                          +{default_val}
                                        <% end %>)
                                      </span>
                                    </td>
                                    <td>
                                      <div class="flex items-center gap-2">
                                        <input
                                          type="number"
                                          step="0.01"
                                          min="0"
                                          name={"product[metadata][_price_modifiers][#{option["key"]}][#{opt_value}][final_price]"}
                                          value={
                                            if custom_final,
                                              do: Decimal.round(custom_final, 2),
                                              else: ""
                                          }
                                          class="input input-xs input-bordered w-24"
                                          placeholder={Decimal.round(default_final, 2)}
                                        />
                                        <%= if custom_final do %>
                                          <span class="badge badge-success badge-xs">Custom</span>
                                        <% end %>
                                      </div>
                                    </td>
                                  </tr>
                                <% end %>
                              </tbody>
                            </table>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%!-- Read-only Options --%>
                <%= if readonly_options != [] do %>
                  <div class="overflow-x-auto">
                    <table class="table table-zebra table-sm">
                      <thead>
                        <tr>
                          <th>Option</th>
                          <th>Value</th>
                          <th>Modifier</th>
                          <th>Type</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for option <- readonly_options do %>
                          <%= for {value, modifier} <- option["price_modifiers"] || %{} do %>
                            <tr>
                              <td class="font-medium">{option["label"]}</td>
                              <td>{value}</td>
                              <td class={
                                if modifier != "0" && modifier != "",
                                  do: "text-success font-semibold",
                                  else: ""
                              }>
                                <%= if option["modifier_type"] == "percent" do %>
                                  +{modifier}%
                                <% else %>
                                  +{format_price(modifier)}
                                <% end %>
                              </td>
                              <td>
                                <span class="badge badge-xs badge-ghost">
                                  {option["modifier_type"] || "fixed"}
                                </span>
                              </td>
                            </tr>
                          <% end %>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>

                <%!-- Price Range Preview --%>
                <%= if @live_action == :edit && assigns[:min_price] && assigns[:max_price] do %>
                  <div class="mt-4 p-3 bg-base-200 rounded-lg">
                    <div class="flex justify-between items-center">
                      <span class="text-sm">Price Range:</span>
                      <span class="font-bold text-lg">
                        {format_price(@min_price)} — {format_price(@max_price)}
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Product Images --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">
                <.icon name="hero-photo" class="w-5 h-5" /> Product Images
              </h2>

              <%!-- Featured Image --%>
              <div class="form-control mb-6">
                <label class="label">
                  <span class="label-text font-medium">Featured Image</span>
                </label>
                <div class="flex items-center gap-4">
                  <%= if @featured_image_id do %>
                    <div class="relative group">
                      <img
                        src={get_image_url(@featured_image_id, "thumbnail")}
                        class="w-24 h-24 object-cover rounded-lg shadow"
                        alt="Featured image"
                      />
                      <button
                        type="button"
                        phx-click="remove_featured_image"
                        class="absolute -top-2 -right-2 btn btn-circle btn-xs btn-error opacity-0 group-hover:opacity-100 transition-opacity"
                      >
                        ×
                      </button>
                    </div>
                  <% else %>
                    <div class="w-24 h-24 bg-base-200 rounded-lg flex items-center justify-center border-2 border-dashed border-base-300">
                      <.icon name="hero-photo" class="w-8 h-8 text-base-content/40" />
                    </div>
                  <% end %>
                  <button
                    type="button"
                    phx-click="open_media_picker"
                    phx-value-target="featured"
                    class="btn btn-sm btn-primary"
                  >
                    <.icon name="hero-photo" class="w-4 h-4 mr-1" />
                    {if @featured_image_id, do: "Change", else: "Select Image"}
                  </button>
                </div>
              </div>

              <%!-- Gallery Images --%>
              <div class="form-control">
                <label class="label">
                  <span class="label-text font-medium">Gallery Images</span>
                </label>
                <div class="flex flex-wrap gap-3">
                  <%= for image_id <- @gallery_image_ids do %>
                    <div class="relative group">
                      <img
                        src={get_image_url(image_id, "thumbnail")}
                        class="w-20 h-20 object-cover rounded-lg shadow"
                        alt="Gallery image"
                      />
                      <button
                        type="button"
                        phx-click="remove_gallery_image"
                        phx-value-id={image_id}
                        class="absolute -top-2 -right-2 btn btn-circle btn-xs btn-error opacity-0 group-hover:opacity-100 transition-opacity"
                      >
                        ×
                      </button>
                    </div>
                  <% end %>
                  <button
                    type="button"
                    phx-click="open_media_picker"
                    phx-value-target="gallery"
                    class="w-20 h-20 border-2 border-dashed border-base-300 rounded-lg flex items-center justify-center hover:border-primary hover:bg-base-200 transition-colors"
                  >
                    <.icon name="hero-plus" class="w-6 h-6 text-base-content/60" />
                  </button>
                </div>
                <label class="label">
                  <span class="label-text-alt text-base-content/60">
                    Click images to remove, or click + to add more
                  </span>
                </label>
              </div>
            </div>
          </div>

          <%!-- Product Specifications (Options without affects_price) --%>
          <% non_price_options = Enum.reject(@option_schema, & &1["affects_price"]) %>
          <%= if non_price_options != [] do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-xl mb-6">
                  <.icon name="hero-tag" class="w-5 h-5" /> Specifications
                </h2>
                <p class="text-sm text-base-content/60 mb-4">
                  Fill in the product specifications based on global and category options.
                </p>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <%= for opt <- non_price_options do %>
                    <.option_field opt={opt} value={@metadata[opt["key"]]} />
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Submit --%>
          <div class="flex justify-end gap-4">
            <.link navigate={Routes.path("/admin/shop/products")} class="btn btn-ghost">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-5 h-5 mr-2" />
              {if @live_action == :new, do: "Create Product", else: "Update Product"}
            </button>
          </div>
        </.form>

        <%!-- Media Selector Modal --%>
        <.live_component
          module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
          id="media-selector-modal"
          show={@show_media_selector}
          mode={@media_selection_mode}
          selected_ids={
            get_current_selection(
              @media_selection_target,
              @featured_image_id,
              @gallery_image_ids
            )
          }
          phoenix_kit_current_user={@phoenix_kit_current_user}
        />
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # Get currently selected IDs based on target
  defp get_current_selection(:featured, featured_id, _gallery_ids)
       when not is_nil(featured_id) do
    [featured_id]
  end

  defp get_current_selection(:gallery, _featured_id, gallery_ids), do: gallery_ids
  defp get_current_selection(_, _, _), do: []

  # Get image URL from Storage
  defp get_image_url(nil, _variant), do: nil

  defp get_image_url(file_id, variant) do
    URLSigner.signed_url(file_id, variant)
  rescue
    _ -> nil
  end

  # Format price for display
  defp format_price(nil), do: "$0.00"
  defp format_price(""), do: "$0.00"

  defp format_price(price) when is_binary(price) do
    case Decimal.parse(price) do
      {decimal, _} -> "$#{Decimal.round(decimal, 2)}"
      :error -> "$#{price}"
    end
  end

  defp format_price(%Decimal{} = price), do: "$#{Decimal.round(price, 2)}"
  defp format_price(price), do: "$#{price}"

  # Get modifier override from product metadata (new structure with type and value)
  defp get_modifier_override(metadata, option_key, option_value) do
    case metadata do
      %{"_price_modifiers" => %{^option_key => %{^option_value => override}}}
      when is_map(override) ->
        # New structure: %{"type" => "fixed", "value" => "10"}
        if override["type"] && override["type"] != "" do
          override
        else
          nil
        end

      %{"_price_modifiers" => %{^option_key => %{^option_value => value}}}
      when is_binary(value) ->
        # Old structure (backward compat): just a value string
        # Treat as custom with inherited type
        nil

      _ ->
        nil
    end
  end

  # Get custom option values from metadata, returns nil if not customized
  defp get_custom_option_values(metadata, option_key) do
    case metadata do
      %{"_option_values" => %{^option_key => values}} when is_list(values) and values != [] ->
        values

      _ ->
        nil
    end
  end

  # Calculate final price for a single option value
  defp calculate_option_price(base_price, modifier_type, modifier_value) do
    base = if is_nil(base_price), do: Decimal.new("0"), else: base_price

    modifier =
      case Decimal.parse(modifier_value || "0") do
        {decimal, _} -> decimal
        :error -> Decimal.new("0")
      end

    case modifier_type do
      "percent" ->
        # base * (1 + modifier/100)
        multiplier = Decimal.add(Decimal.new("1"), Decimal.div(modifier, Decimal.new("100")))
        Decimal.mult(base, multiplier) |> Decimal.round(2)

      _ ->
        # fixed: base + modifier
        Decimal.add(base, modifier) |> Decimal.round(2)
    end
  end

  # Dynamic option field component
  attr :opt, :map, required: true
  attr :value, :any, default: nil

  defp option_field(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text">
          {@opt["label"]}
          <%= if @opt["required"] do %>
            <span class="text-error">*</span>
          <% end %>
          <%= if @opt["affects_price"] do %>
            <span class="badge badge-xs badge-info ml-1">$</span>
          <% end %>
        </span>
        <%= if @opt["unit"] do %>
          <span class="label-text-alt">{@opt["unit"]}</span>
        <% end %>
      </label>

      <%= case @opt["type"] do %>
        <% "text" -> %>
          <input
            type="text"
            name={"product[metadata][#{@opt["key"]}]"}
            value={@value}
            class="input input-bordered"
            placeholder={@opt["label"]}
          />
        <% "number" -> %>
          <input
            type="number"
            name={"product[metadata][#{@opt["key"]}]"}
            value={@value}
            class="input input-bordered"
            step="any"
            placeholder={@opt["label"]}
          />
        <% "boolean" -> %>
          <div class="flex items-center h-12">
            <input
              type="hidden"
              name={"product[metadata][#{@opt["key"]}]"}
              value="false"
            />
            <input
              type="checkbox"
              name={"product[metadata][#{@opt["key"]}]"}
              value="true"
              checked={@value == true or @value == "true"}
              class="checkbox checkbox-primary"
            />
            <span class="ml-2 text-sm text-base-content/70">Yes</span>
          </div>
        <% "select" -> %>
          <select
            name={"product[metadata][#{@opt["key"]}]"}
            class="select select-bordered"
          >
            <option value="">Select {String.downcase(@opt["label"])}...</option>
            <%= for opt_val <- @opt["options"] || [] do %>
              <option value={opt_val} selected={@value == opt_val}>{opt_val}</option>
            <% end %>
          </select>
        <% "multiselect" -> %>
          <div class="flex flex-wrap gap-2 p-3 bg-base-200 rounded-lg min-h-12">
            <%= for opt_val <- @opt["options"] || [] do %>
              <label class="label cursor-pointer gap-2 p-0">
                <input
                  type="checkbox"
                  name={"product[metadata][#{@opt["key"]}][]"}
                  value={opt_val}
                  checked={is_list(@value) and opt_val in @value}
                  class="checkbox checkbox-sm checkbox-primary"
                />
                <span class="label-text text-sm">{opt_val}</span>
              </label>
            <% end %>
            <%= if (@opt["options"] || []) == [] do %>
              <span class="text-sm text-base-content/50">No options defined</span>
            <% end %>
          </div>
        <% _ -> %>
          <input
            type="text"
            name={"product[metadata][#{@opt["key"]}]"}
            value={@value}
            class="input input-bordered"
          />
      <% end %>
    </div>
    """
  end

  # Get option schema based on category_id string
  defp get_schema_for_category_id(nil), do: Options.get_global_options()
  defp get_schema_for_category_id(""), do: Options.get_global_options()

  defp get_schema_for_category_id(category_id) when is_binary(category_id) do
    case Integer.parse(category_id) do
      {id, ""} ->
        category = Shop.get_category!(id)
        product = %Product{category: category, category_id: id}
        Options.get_option_schema_for_product(product)

      _ ->
        Options.get_global_options()
    end
  rescue
    _ -> Options.get_global_options()
  end

  defp get_schema_for_category_id(_), do: Options.get_global_options()

  # Clean up _option_values - remove entries where all values are selected (use defaults)
  defp clean_option_values(metadata, option_schema) do
    case metadata["_option_values"] do
      nil ->
        metadata

      option_values when is_map(option_values) ->
        # Build a map of option_key -> all_values from schema
        schema_values =
          option_schema
          |> Enum.filter(&(&1["type"] in ["select", "multiselect"]))
          |> Enum.map(&{&1["key"], &1["options"] || []})
          |> Map.new()

        # Remove entries where all values are selected
        cleaned =
          option_values
          |> Enum.map(fn {key, selected_values} ->
            all_values = Map.get(schema_values, key, [])
            selected = if is_list(selected_values), do: selected_values, else: []

            # If all values selected or none selected, use defaults (nil)
            if Enum.sort(selected) == Enum.sort(all_values) or selected == [] do
              {key, nil}
            else
              {key, selected}
            end
          end)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        if cleaned == %{} do
          Map.delete(metadata, "_option_values")
        else
          Map.put(metadata, "_option_values", cleaned)
        end

      _ ->
        metadata
    end
  end

  # Convert final_price inputs to modifier values
  # final_price - base_price = modifier (for fixed type)
  defp convert_final_prices_to_modifiers(metadata, base_price) do
    case metadata["_price_modifiers"] do
      nil ->
        metadata

      price_modifiers when is_map(price_modifiers) ->
        converted =
          Enum.map(price_modifiers, fn {option_key, option_values} ->
            converted_values =
              Enum.map(option_values, fn {opt_value, modifier_data} ->
                converted_data = convert_modifier_data(modifier_data, base_price)
                {opt_value, converted_data}
              end)
              |> Enum.reject(fn {_k, v} -> v == nil end)
              |> Map.new()

            {option_key, converted_values}
          end)
          |> Enum.reject(fn {_k, v} -> v == nil or v == %{} end)
          |> Map.new()

        if converted == %{} do
          Map.delete(metadata, "_price_modifiers")
        else
          Map.put(metadata, "_price_modifiers", converted)
        end
    end
  end

  # Convert a single modifier data entry
  defp convert_modifier_data(modifier_data, base_price) when is_map(modifier_data) do
    final_price_str = modifier_data["final_price"]

    cond do
      # If final_price is provided, calculate modifier from it
      final_price_str && final_price_str != "" ->
        final_price = parse_decimal(final_price_str)
        # modifier = final_price - base_price (always store as fixed)
        modifier = Decimal.sub(final_price, base_price)

        # Only store if it's different from 0 (otherwise use default)
        if Decimal.compare(modifier, Decimal.new("0")) == :eq do
          nil
        else
          %{
            "type" => "fixed",
            "value" => Decimal.to_string(Decimal.round(modifier, 2))
          }
        end

      # If no final_price but has explicit value, keep as-is
      modifier_data["value"] && modifier_data["value"] != "" ->
        %{
          "type" => modifier_data["type"] || "fixed",
          "value" => modifier_data["value"]
        }

      # No valid data
      true ->
        nil
    end
  end

  defp convert_modifier_data(_, _), do: nil

  # Parse string to Decimal safely
  defp parse_decimal(nil), do: Decimal.new("0")
  defp parse_decimal(""), do: Decimal.new("0")

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp parse_decimal(%Decimal{} = value), do: value
  defp parse_decimal(_), do: Decimal.new("0")
end
