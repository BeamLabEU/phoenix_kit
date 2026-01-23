defmodule PhoenixKit.Modules.Shop.Web.ProductForm do
  @moduledoc """
  Product create/edit form LiveView for Shop module.

  Includes dynamic option fields based on merged global + category schema,
  and displays option prices table for options that affect pricing.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.Product
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Web.Components.TranslationTabs
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  import TranslationTabs

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
    currency = Shop.get_default_currency()

    # Get global options (no category selected yet)
    option_schema = Options.get_global_options()
    price_affecting_options = get_price_affecting_options(option_schema)

    socket
    |> assign(:page_title, "New Product")
    |> assign(:product, product)
    |> assign(:changeset, changeset)
    |> assign(:categories, categories)
    |> assign(:currency, currency)
    |> assign(:option_schema, option_schema)
    |> assign(:metadata, %{})
    |> assign(:price_affecting_options, price_affecting_options)
    |> assign(:show_media_selector, false)
    |> assign(:media_selection_mode, :single)
    |> assign(:media_selection_target, nil)
    |> assign(:featured_image_id, nil)
    |> assign(:gallery_image_ids, [])
    |> assign(:new_value_inputs, %{})
    |> assign(:selected_option_values, %{})
    |> assign(:original_option_values, %{})
    |> assign(:add_option_key, "")
    |> assign(:add_option_value, "")
    |> assign_translation_state(%Product{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    product = Shop.get_product!(id, preload: [:category])
    changeset = Shop.change_product(product)
    categories = Shop.category_options()
    currency = Shop.get_default_currency()

    # Get merged option schema for the product
    option_schema = Options.get_option_schema_for_product(product)
    metadata = product.metadata || %{}
    price_affecting_options = get_price_affecting_options(option_schema)

    # Build list of valid image IDs for this product
    gallery_ids = product.image_ids || []
    featured_id = product.featured_image_id
    valid_image_ids = if featured_id, do: [featured_id | gallery_ids], else: gallery_ids

    # Clean stale image mappings (images that no longer exist)
    {metadata, had_stale_mappings} = clean_stale_image_mappings(metadata, valid_image_ids)

    # Calculate price range for display (pass metadata for custom modifiers)
    base_price = product.price || Decimal.new("0")

    {min_price, max_price} =
      Options.get_price_range(price_affecting_options, base_price, metadata)

    # Store original option values for UI (so unchecking all doesn't hide the section)
    original_option_values = metadata["_option_values"] || %{}

    # Selected option values - managed in assigns, not in form
    selected_option_values = metadata["_option_values"] || %{}

    product_title = Translations.get(product, :title, TranslationTabs.get_default_language())

    socket
    |> assign(:page_title, "Edit #{product_title}")
    |> assign(:product, product)
    |> assign(:changeset, changeset)
    |> assign(:categories, categories)
    |> assign(:currency, currency)
    |> assign(:option_schema, option_schema)
    |> assign(:metadata, metadata)
    |> assign(:original_option_values, original_option_values)
    |> assign(:price_affecting_options, price_affecting_options)
    |> assign(:min_price, min_price)
    |> assign(:max_price, max_price)
    |> assign(:show_media_selector, false)
    |> assign(:media_selection_mode, :single)
    |> assign(:media_selection_target, nil)
    |> assign(:featured_image_id, product.featured_image_id)
    |> assign(:gallery_image_ids, gallery_ids)
    |> assign(:new_value_inputs, %{})
    |> assign(:selected_option_values, selected_option_values)
    |> assign(:add_option_key, "")
    |> assign(:add_option_value, "")
    |> assign_translation_state(product)
    |> maybe_warn_stale_mappings(had_stale_mappings)
  end

  # Assign translation-related state (localized fields model)
  defp assign_translation_state(socket, product) do
    enabled_languages = TranslationTabs.get_enabled_languages()
    default_language = TranslationTabs.get_default_language()
    show_translations = TranslationTabs.show_translation_tabs?()

    # Build translations map from localized fields for UI
    translatable_fields = Translations.product_fields()
    translations_map = TranslationTabs.build_translations_map(product, translatable_fields)

    socket
    |> assign(:enabled_languages, enabled_languages)
    |> assign(:default_language, default_language)
    |> assign(:current_translation_language, default_language)
    |> assign(:show_translation_tabs, show_translations)
    |> assign(:product_translations, translations_map)
  end

  @impl true
  def handle_event("validate", %{"product" => product_params} = params, socket) do
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

    # Extract _new_option_value_* fields from root params (not product_params!)
    new_value_inputs =
      params
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "_new_option_value_") end)
      |> Enum.map(fn {k, v} ->
        key = String.replace_prefix(k, "_new_option_value_", "")
        {key, v}
      end)
      |> Map.new()

    # Merge with existing tracked values (keep old if new is empty)
    new_value_inputs =
      Map.merge(socket.assigns[:new_value_inputs] || %{}, new_value_inputs, fn _k, old, new ->
        if new == "", do: old, else: new
      end)

    # Extract add_option inputs from root params
    add_option_key = params["_add_option_key"] || ""
    add_option_value = params["_add_option_first_value"] || ""

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

    # Update translations from form params
    product_translations =
      merge_translation_params(
        socket.assigns[:product_translations] || %{},
        product_params["translations"]
      )

    socket
    |> assign(:changeset, changeset)
    |> assign(:metadata, metadata)
    |> assign(:new_value_inputs, new_value_inputs)
    |> assign(:add_option_key, add_option_key)
    |> assign(:add_option_value, add_option_value)
    |> assign(:product_translations, product_translations)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_event("save", %{"product" => product_params}, socket) do
    # Remove helper fields from params (they're just UI helpers)
    product_params =
      product_params
      |> Enum.reject(fn {k, _v} ->
        String.starts_with?(k, "_new_option_value_") or
          String.starts_with?(k, "_add_option_")
      end)
      |> Map.new()

    # Merge metadata into product params
    metadata = product_params["metadata"] || %{}
    base_price = parse_decimal(product_params["price"])

    # Convert final_price inputs to modifier values
    metadata = convert_final_prices_to_modifiers(metadata, base_price)

    # Remove _option_values from form metadata (may have garbage from Phoenix)
    metadata = Map.delete(metadata, "_option_values")

    # Add _option_values from socket assigns (managed via phx-click)
    selected_option_values = socket.assigns.selected_option_values

    metadata =
      if selected_option_values == %{} do
        metadata
      else
        Map.put(metadata, "_option_values", selected_option_values)
      end

    # Clean up _option_values - remove entries where all values are selected
    metadata =
      clean_option_values(
        metadata,
        socket.assigns.option_schema,
        socket.assigns[:original_option_values] || %{}
      )

    # Clean up _image_mappings - remove empty values and invalid image IDs
    valid_image_ids = build_valid_image_ids(socket.assigns)
    metadata = clean_image_mappings(metadata, valid_image_ids)

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

    # Build localized field attrs from main form values and translations
    product_params =
      build_localized_params(
        socket.assigns.product,
        product_params,
        socket.assigns[:product_translations] || %{},
        socket.assigns.default_language
      )

    save_product(socket, socket.assigns.live_action, product_params)
  end

  # ===========================================
  # TRANSLATION LANGUAGE SWITCHING
  # ===========================================

  def handle_event("switch_language", %{"language" => language}, socket) do
    {:noreply, assign(socket, :current_translation_language, language)}
  end

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

  # ===========================================
  # OPTION VALUES MANAGEMENT
  # ===========================================

  # Toggle option value selection (managed in socket assigns, not form)
  # all_values is passed as JSON to know what "all selected" means
  def handle_event(
        "toggle_option_value",
        %{"key" => option_key, "opt-value" => value, "all-values" => all_values_json},
        socket
      ) do
    selected = socket.assigns.selected_option_values
    all_values = Jason.decode!(all_values_json)

    # If this key doesn't exist in selected, it means "all are selected"
    # We need to initialize it properly when user starts toggling
    current_for_key =
      if Map.has_key?(selected, option_key) do
        Map.get(selected, option_key, [])
      else
        # Key not in selected = all values are implicitly selected
        all_values
      end

    updated_for_key =
      if value in current_for_key do
        # Remove this value
        Enum.reject(current_for_key, &(&1 == value))
      else
        # Add this value
        current_for_key ++ [value]
      end

    # If updated list equals all values, remove the key (implicit "all selected")
    updated_selected =
      cond do
        updated_for_key == [] ->
          # None selected - keep explicit empty list
          Map.put(selected, option_key, [])

        Enum.sort(updated_for_key) == Enum.sort(all_values) ->
          # All selected - remove key to indicate "all"
          Map.delete(selected, option_key)

        true ->
          Map.put(selected, option_key, updated_for_key)
      end

    {:noreply, assign(socket, :selected_option_values, updated_selected)}
  end

  # Track input value changes for add new value fields
  def handle_event("update_new_value_input", %{"key" => key, "value" => value}, socket) do
    new_inputs = Map.put(socket.assigns[:new_value_inputs] || %{}, key, value)
    {:noreply, assign(socket, :new_value_inputs, new_inputs)}
  end

  # Handle Enter key in add value input
  def handle_event("add_option_value_keydown", %{"key" => option_key}, socket) do
    new_inputs = socket.assigns[:new_value_inputs] || %{}
    value = Map.get(new_inputs, option_key, "") |> String.trim()
    do_add_option_value(socket, option_key, value)
  end

  # Handle click on Add button - get value from tracked inputs
  def handle_event("add_option_value_click", %{"key" => option_key}, socket) do
    new_inputs = socket.assigns[:new_value_inputs] || %{}
    value = Map.get(new_inputs, option_key, "") |> String.trim()
    do_add_option_value(socket, option_key, value)
  end

  def handle_event("add_option_value", %{"key" => option_key, "new_value" => value}, socket) do
    value = String.trim(value)

    if value == "" do
      {:noreply, socket}
    else
      # Check in both original and current values
      original_values = socket.assigns[:original_option_values] || %{}
      original_for_key = Map.get(original_values, option_key, [])

      metadata = socket.assigns.metadata
      option_values = metadata["_option_values"] || %{}
      current_values = Map.get(option_values, option_key, [])

      # Also check schema values
      schema_opt = Enum.find(socket.assigns.option_schema, &(&1["key"] == option_key))
      schema_values = (schema_opt && schema_opt["options"]) || []

      all_existing = Enum.uniq(original_for_key ++ current_values ++ schema_values)

      if value in all_existing do
        {:noreply, put_flash(socket, :error, "Value '#{value}' already exists")}
      else
        # Add to original_option_values
        updated_original = Map.put(original_values, option_key, original_for_key ++ [value])

        # Add to selected_option_values (new value is selected by default)
        # If key doesn't exist in selected, initialize with all values first
        selected = socket.assigns.selected_option_values

        current_selected =
          if Map.has_key?(selected, option_key) do
            Map.get(selected, option_key, [])
          else
            # Key not present = all values implicitly selected
            Enum.uniq(schema_values ++ original_for_key)
          end

        updated_selected = Map.put(selected, option_key, current_selected ++ [value])

        {:noreply,
         socket
         |> assign(:original_option_values, updated_original)
         |> assign(:selected_option_values, updated_selected)}
      end
    end
  end

  def handle_event("add_option_value", %{"key" => _option_key}, socket) do
    # No value provided
    {:noreply, socket}
  end

  # Handle click on Add button for new option (reads from assigns)
  def handle_event("add_new_option_click", _params, socket) do
    key =
      (socket.assigns[:add_option_key] || "")
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/, "_")

    value = (socket.assigns[:add_option_value] || "") |> String.trim()
    do_add_new_option(socket, key, value)
  end

  # Handle form submit for new option (legacy, reads from form params)
  def handle_event("add_new_option", %{"option_key" => key, "first_value" => value}, socket) do
    key = key |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "_")
    value = String.trim(value)
    do_add_new_option(socket, key, value)
  end

  def handle_event("remove_option_value", %{"key" => option_key, "opt-value" => value}, socket) do
    # Remove from original_option_values (available values)
    original_values = socket.assigns[:original_option_values] || %{}
    original_for_key = Map.get(original_values, option_key, [])
    updated_original_for_key = Enum.reject(original_for_key, &(&1 == value))

    updated_original =
      if updated_original_for_key == [] do
        Map.delete(original_values, option_key)
      else
        Map.put(original_values, option_key, updated_original_for_key)
      end

    # Remove from selected_option_values (selected values)
    selected = socket.assigns.selected_option_values
    current_selected = Map.get(selected, option_key, [])
    updated_selected_for_key = Enum.reject(current_selected, &(&1 == value))

    updated_selected =
      if updated_selected_for_key == [] do
        Map.delete(selected, option_key)
      else
        Map.put(selected, option_key, updated_selected_for_key)
      end

    # Also remove price modifier for this value if exists
    metadata = socket.assigns.metadata
    updated_metadata = remove_price_modifier_for_value(metadata, option_key, value)

    {:noreply,
     socket
     |> assign(:metadata, updated_metadata)
     |> assign(:original_option_values, updated_original)
     |> assign(:selected_option_values, updated_selected)}
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

  # Shared logic for adding option value
  defp do_add_option_value(socket, option_key, value) do
    if value == "" do
      {:noreply, put_flash(socket, :error, "Please enter a value first")}
    else
      original_values = socket.assigns[:original_option_values] || %{}
      original_for_key = Map.get(original_values, option_key, [])

      metadata = socket.assigns.metadata
      option_values = metadata["_option_values"] || %{}
      current_values = Map.get(option_values, option_key, [])

      # Also check schema values
      schema_opt = Enum.find(socket.assigns.option_schema, &(&1["key"] == option_key))
      schema_values = (schema_opt && schema_opt["options"]) || []

      all_existing = Enum.uniq(original_for_key ++ current_values ++ schema_values)

      if value in all_existing do
        {:noreply, put_flash(socket, :error, "Value '#{value}' already exists")}
      else
        # Add to original_option_values (tracks all available values)
        updated_original = Map.put(original_values, option_key, original_for_key ++ [value])

        # Add to selected_option_values (new value is selected by default)
        # If key doesn't exist in selected, initialize with all schema values first
        selected = socket.assigns.selected_option_values

        current_selected =
          if Map.has_key?(selected, option_key) do
            Map.get(selected, option_key, [])
          else
            # Key not present = all values implicitly selected
            # Initialize with schema values + original values
            Enum.uniq(schema_values ++ original_for_key)
          end

        updated_selected = Map.put(selected, option_key, current_selected ++ [value])

        # Clear the input field
        new_inputs = socket.assigns[:new_value_inputs] || %{}
        new_inputs = Map.put(new_inputs, option_key, "")

        {:noreply,
         socket
         |> assign(:original_option_values, updated_original)
         |> assign(:selected_option_values, updated_selected)
         |> assign(:new_value_inputs, new_inputs)
         |> put_flash(:info, "Value '#{value}' added")}
      end
    end
  end

  defp do_add_new_option(socket, key, value) do
    if key == "" or value == "" do
      {:noreply, put_flash(socket, :error, "Option key and value are required")}
    else
      original_values = socket.assigns[:original_option_values] || %{}
      current_values = socket.assigns.metadata["_option_values"] || %{}

      # Check if option already exists - if so, add value to it
      existing_original = Map.get(original_values, key, [])
      existing_current = Map.get(current_values, key, [])
      all_existing = Enum.uniq(existing_original ++ existing_current)

      # Also check schema values
      schema_opt = Enum.find(socket.assigns.option_schema, &(&1["key"] == key))
      schema_values = (schema_opt && schema_opt["options"]) || []
      all_existing = Enum.uniq(all_existing ++ schema_values)

      # Get current selected_option_values
      selected = socket.assigns.selected_option_values
      current_selected = Map.get(selected, key, [])

      cond do
        # Value already exists in this option
        value in all_existing ->
          {:noreply, put_flash(socket, :error, "Value '#{value}' already exists in '#{key}'")}

        # Option exists - add value to it
        all_existing != [] ->
          # Initialize selected with all existing values if not already set
          init_selected = if current_selected == [], do: all_existing, else: current_selected
          updated_original = Map.put(original_values, key, existing_original ++ [value])
          updated_selected = Map.put(selected, key, init_selected ++ [value])

          {:noreply,
           socket
           |> assign(:original_option_values, updated_original)
           |> assign(:selected_option_values, updated_selected)
           |> assign(:add_option_key, "")
           |> assign(:add_option_value, "")
           |> put_flash(:info, "Value '#{value}' added to '#{key}'")}

        # New option - create it
        true ->
          updated_original = Map.put(original_values, key, [value])
          updated_selected = Map.put(selected, key, [value])

          {:noreply,
           socket
           |> assign(:original_option_values, updated_original)
           |> assign(:selected_option_values, updated_selected)
           |> assign(:add_option_key, "")
           |> assign(:add_option_value, "")
           |> put_flash(:info, "Option '#{key}' created")}
      end
    end
  end

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
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/admin/shop/products")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">{@page_title}</h1>
              <p class="text-base-content/70 mt-1">
                {if @live_action == :new, do: "Create a new product", else: "Edit product details"}
              </p>
            </div>
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
                    <%= if @show_translation_tabs do %>
                      <span class="label-text-alt text-base-content/50">
                        {String.upcase(@default_language)}
                      </span>
                    <% end %>
                  </label>
                  <input
                    type="text"
                    name="product[title]"
                    value={TranslationTabs.get_localized_value(@changeset, :title, @default_language)}
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
                    <%= if @show_translation_tabs do %>
                      <span class="label-text-alt text-base-content/50">
                        {String.upcase(@default_language)}
                      </span>
                    <% end %>
                  </label>
                  <input
                    type="text"
                    name="product[slug]"
                    value={TranslationTabs.get_localized_value(@changeset, :slug, @default_language)}
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
                    <%= if @show_translation_tabs do %>
                      <span class="label-text-alt text-base-content/50">
                        {String.upcase(@default_language)}
                      </span>
                    <% end %>
                  </label>
                  <textarea
                    name="product[description]"
                    class="textarea textarea-bordered w-full h-24 focus:textarea-primary"
                    placeholder="Short product description"
                  >{TranslationTabs.get_localized_value(@changeset, :description, @default_language)}</textarea>
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

          <%!-- Card: Translations (only show when Languages module enabled with 2+ languages) --%>
          <%= if @show_translation_tabs do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-xl mb-4">Translations</h2>
                <p class="text-base-content/60 text-sm mb-4">
                  Translate product content for different languages. The default language uses the main fields above.
                </p>

                <%!-- Language Tabs --%>
                <.translation_tabs
                  languages={@enabled_languages}
                  current_language={@current_translation_language}
                  translations={@product_translations}
                  translatable_fields={Translations.product_fields()}
                  on_click="switch_language"
                />

                <%!-- Translation Fields for Current Language --%>
                <div class="mt-6">
                  <.translation_fields
                    language={@current_translation_language}
                    translations={@product_translations}
                    is_default_language={@current_translation_language == @default_language}
                    form_prefix="product"
                    fields={[
                      %{
                        key: :title,
                        label: "Title",
                        type: :text,
                        placeholder: "Translated product title"
                      },
                      %{
                        key: :slug,
                        label: "URL Slug",
                        type: :text,
                        placeholder: "translated-url-slug",
                        hint: "SEO-friendly URL for this language"
                      },
                      %{
                        key: :description,
                        label: "Description",
                        type: :textarea,
                        placeholder: "Short translated description"
                      },
                      %{
                        key: :body_html,
                        label: "Full Description (HTML)",
                        type: :html,
                        placeholder: "<p>Full translated description...</p>"
                      },
                      %{
                        key: :seo_title,
                        label: "SEO Title",
                        type: :text,
                        placeholder: "Page title for search engines (max 60 chars)"
                      },
                      %{
                        key: :seo_description,
                        label: "SEO Description",
                        type: :text,
                        placeholder: "Meta description for search engines (max 160 chars)"
                      }
                    ]}
                  />
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Available Option Values Section --%>
          <% # Use original_option_values for showing all available values (persists across unchecks)
          # Use current metadata for determining which are currently selected
          original_values = assigns[:original_option_values] || %{}
          current_option_values = @metadata["_option_values"] || %{}

          # Merge original + current to get all known values
          all_known_values =
            Map.merge(original_values, current_option_values, fn _k, orig, curr ->
              Enum.uniq(orig ++ curr)
            end)

          # 1. ALL select/multiselect options from schema (even with empty options list)
          # This allows adding custom values to options defined in category schema
          schema_options =
            Enum.filter(@option_schema, fn opt ->
              opt["type"] in ["select", "multiselect"]
            end)

          # 2. Options from _option_values (imported) that are NOT already in schema
          schema_keys_with_values = Enum.map(schema_options, & &1["key"])

          imported_options =
            all_known_values
            |> Enum.reject(fn {key, _} -> key in schema_keys_with_values end)
            |> Enum.map(fn {key, values} ->
              # Find option in schema (may exist but with empty options list)
              schema_opt = Enum.find(@option_schema, &(&1["key"] == key))

              %{
                "key" => key,
                "label" => (schema_opt && schema_opt["label"]) || String.capitalize(key),
                "type" => (schema_opt && schema_opt["type"]) || "select",
                "options" => values,
                "imported" => true
              }
            end)

          # Combine: schema options first, then imported-only options
          all_select_options = schema_options ++ imported_options %>
          <%= if @live_action == :edit do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <.icon name="hero-adjustments-horizontal" class="w-5 h-5" /> Available Options
                </h2>
                <p class="text-sm text-base-content/60 mb-4">
                  <%= if all_select_options != [] do %>
                    Select which option values are available for this product.
                  <% else %>
                    Add custom options for this product.
                  <% end %>
                </p>

                <div class="space-y-4">
                  <%= for option <- all_select_options do %>
                    <% option_key = option["key"] %>
                    <% # Determine all available values
                    schema_values = option["options"] || []
                    original_imported = Map.get(original_values, option_key, [])
                    current_imported = Map.get(current_option_values, option_key, [])
                    # Also include manually added values from socket assigns
                    manually_added = Map.get(@original_option_values, option_key, [])

                    # All values = schema values + manually added OR merged original+current imported
                    all_values =
                      if schema_values != [] do
                        Enum.uniq(schema_values ++ manually_added)
                      else
                        Enum.uniq(original_imported ++ current_imported ++ manually_added)
                      end

                    # Active values = from socket assigns (managed via phx-click, not form)
                    # If selected_option_values has this key, use it; otherwise all are active
                    active_values = Map.get(@selected_option_values, option_key, all_values)

                    is_imported = option["imported"] == true

                    is_editable =
                      is_imported or schema_values == [] or option["allow_override"] == true

                    has_custom_selection = Map.has_key?(@selected_option_values, option_key) %>

                    <div class="p-4 bg-base-200 rounded-lg">
                      <div class="flex items-center justify-between mb-3">
                        <span class="font-medium">
                          {option["label"]}
                          <%= if is_imported do %>
                            <span class="badge badge-info badge-xs ml-2">Imported</span>
                          <% end %>
                        </span>
                        <%= if has_custom_selection do %>
                          <span class="badge badge-warning badge-sm">Custom selection</span>
                        <% else %>
                          <span class="badge badge-ghost badge-sm">All values</span>
                        <% end %>
                      </div>

                      <%!-- Option values as toggleable badges --%>
                      <div class="flex flex-wrap gap-2 mb-3">
                        <%= for value <- all_values do %>
                          <% is_selected = value in active_values %>
                          <div class="flex items-center gap-1">
                            <button
                              type="button"
                              phx-click="toggle_option_value"
                              phx-value-key={option_key}
                              phx-value-opt-value={value}
                              phx-value-all-values={Jason.encode!(all_values)}
                              class={[
                                "flex items-center gap-2 px-3 py-1.5 rounded-lg border transition-colors",
                                if(is_selected,
                                  do: "bg-primary/10 border-primary text-primary",
                                  else:
                                    "bg-base-200 border-base-300 text-base-content/50 hover:border-base-400"
                                )
                              ]}
                            >
                              <span class={[
                                "w-4 h-4 rounded border-2 flex items-center justify-center text-xs",
                                if(is_selected,
                                  do: "bg-primary border-primary text-primary-content",
                                  else: "border-current"
                                )
                              ]}>
                                <%= if is_selected do %>
                                  <.icon name="hero-check" class="w-3 h-3" />
                                <% end %>
                              </span>
                              <span class="text-sm">{value}</span>
                            </button>
                            <%= if is_editable do %>
                              <button
                                type="button"
                                phx-click="remove_option_value"
                                phx-value-key={option_key}
                                phx-value-opt-value={value}
                                class="btn btn-ghost btn-xs px-1 text-error hover:bg-error/20"
                              >
                                <.icon name="hero-x-mark" class="w-3 h-3" />
                              </button>
                            <% end %>
                          </div>
                        <% end %>
                      </div>

                      <%!-- Add new value input --%>
                      <%= if is_editable do %>
                        <% input_value = Map.get(assigns[:new_value_inputs] || %{}, option_key, "") %>
                        <div class="flex gap-2 items-center mt-2 pt-2 border-t border-base-300">
                          <input
                            type="text"
                            id={"new_option_value_#{option_key}"}
                            name={"_new_option_value_#{option_key}"}
                            value={input_value}
                            placeholder="Add new value..."
                            class="input input-sm input-bordered flex-1 max-w-xs"
                            autocomplete="off"
                            phx-keydown="add_option_value_keydown"
                            phx-key="Enter"
                            phx-value-key={option_key}
                          />
                          <button
                            type="button"
                            class="btn btn-sm btn-primary"
                            phx-click="add_option_value_click"
                            phx-value-key={option_key}
                          >
                            <.icon name="hero-plus" class="w-4 h-4" /> Add
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <%!-- Add Option/Value Section --%>
                <div class="divider text-sm text-base-content/50">Add Option or Value</div>
                <p class="text-xs text-base-content/50 mb-2">
                  Enter an existing option key to add a new value, or a new key to create a new option.
                </p>
                <div class="flex flex-wrap gap-3 items-end">
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Option Key</span>
                    </label>
                    <input
                      type="text"
                      name="_add_option_key"
                      placeholder="e.g. size, color"
                      class="input input-sm input-bordered w-40"
                      autocomplete="off"
                    />
                  </div>
                  <div class="form-control flex-1">
                    <label class="label py-1">
                      <span class="label-text text-xs">Value</span>
                    </label>
                    <input
                      type="text"
                      name="_add_option_first_value"
                      placeholder="e.g. 14 inches, Red"
                      class="input input-sm input-bordered min-w-32"
                      autocomplete="off"
                    />
                  </div>
                  <button
                    type="button"
                    class="btn btn-sm btn-outline btn-primary"
                    phx-click="add_new_option_click"
                  >
                    <.icon name="hero-plus" class="w-4 h-4" /> Add
                  </button>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Option Price Modifiers Section --%>
          <% # Filter to only options that have actual values to display
          price_options_with_values =
            Enum.filter(@price_affecting_options, fn opt ->
              (opt["options"] || []) != []
            end)

          # Editable options: has allow_override flag AND has options
          editable_options =
            Enum.filter(price_options_with_values, fn opt ->
              opt["allow_override"] == true
            end)

          # Read-only options: without allow_override AND has price_modifiers
          readonly_options =
            price_options_with_values
            |> Enum.reject(fn opt -> opt["allow_override"] == true end)
            |> Enum.filter(fn opt -> (opt["price_modifiers"] || %{}) != %{} end)

          # Only show section if there's something to display
          has_schema_price_content = editable_options != [] or readonly_options != [] %>
          <%= if has_schema_price_content do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <.icon name="hero-calculator" class="w-5 h-5" /> Option Prices
                </h2>
                <p class="text-sm text-base-content/60 mb-4">
                  Base price:
                  <span class="font-semibold">
                    {format_price(Ecto.Changeset.get_field(@changeset, :price), @currency)}
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
                            <% # Combine schema values with manually added values
                            schema_values = option["options"] || []
                            manually_added = Map.get(@original_option_values, option["key"], [])
                            all_option_values = Enum.uniq(schema_values ++ manually_added)
                            # Calculate min modifier for suggesting price for added values
                            price_modifiers = option["price_modifiers"] || %{}

                            min_modifier =
                              price_modifiers
                              |> Map.values()
                              |> Enum.map(&parse_decimal/1)
                              |> Enum.min(fn -> Decimal.new("0") end) %>
                            <table class="table table-xs">
                              <thead>
                                <tr>
                                  <th>Value</th>
                                  <th>Default Price</th>
                                  <th>Custom Price</th>
                                </tr>
                              </thead>
                              <tbody>
                                <%= for opt_value <- all_option_values do %>
                                  <% is_from_schema = opt_value in schema_values %>
                                  <% # For schema values use their modifier; for added values use min modifier
                                  default_val =
                                    if is_from_schema do
                                      get_in(option, ["price_modifiers", opt_value]) || "0"
                                    else
                                      Decimal.to_string(min_modifier)
                                    end %>
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
                                    <td class="font-medium">
                                      {opt_value}
                                    </td>
                                    <td class="text-base-content/60">
                                      {format_price(default_final, @currency)}
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
                                        <%= if is_from_schema do %>
                                          <%!-- Schema values: use [final_price] suffix for map structure --%>
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
                                        <% else %>
                                          <%!-- Added values: use simple format like imported --%>
                                          <% # Check if there's already a stored modifier for this value
                                          stored_mod =
                                            get_in(@metadata, [
                                              "_price_modifiers",
                                              option["key"],
                                              opt_value
                                            ])

                                          display_final =
                                            if is_binary(stored_mod) do
                                              Decimal.add(base_price, parse_decimal(stored_mod))
                                            else
                                              default_final
                                            end %>
                                          <input
                                            type="number"
                                            step="0.01"
                                            min="0"
                                            name={"product[metadata][_price_modifiers][#{option["key"]}][#{opt_value}]"}
                                            value={Decimal.round(display_final, 2)}
                                            class="input input-xs input-bordered w-28"
                                          />
                                          <span class="text-xs text-base-content/50">
                                            {currency_symbol(@currency)}
                                          </span>
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
                                  +{format_price(modifier, @currency)}
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
                        {format_price(@min_price, @currency)} — {format_price(@max_price, @currency)}
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Imported Option Prices Section --%>
          <% # Use original_option_values to ensure we show all values even if some unchecked
          price_original_values = assigns[:original_option_values] || %{}
          imported_price_modifiers = @metadata["_price_modifiers"] || %{}

          # Use original_option_values directly (it contains all available values)
          all_price_values = price_original_values

          # Find options that exist in _option_values but NOT in price_affecting_options schema
          schema_price_keys = Enum.map(@price_affecting_options, & &1["key"])

          imported_price_options =
            all_price_values
            |> Enum.reject(fn {key, _} -> key in schema_price_keys end)
            |> Enum.map(fn {key, values} ->
              %{
                "key" => key,
                "label" => String.capitalize(String.replace(key, "_", " ")),
                "values" => values,
                "modifiers" => Map.get(imported_price_modifiers, key, %{})
              }
            end) %>
          <%= if imported_price_options != [] and @live_action == :edit do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <.icon name="hero-currency-dollar" class="w-5 h-5" /> Imported Option Prices
                  <span class="badge badge-info badge-sm">From Import</span>
                </h2>
                <p class="text-sm text-base-content/60 mb-4">
                  Set prices for each option value. Enter the final price (base price + modifier).
                </p>

                <% base_price = Ecto.Changeset.get_field(@changeset, :price) || Decimal.new("0") %>

                <div class="space-y-4">
                  <%= for opt <- imported_price_options do %>
                    <div class="p-4 bg-base-200 rounded-lg">
                      <div class="font-medium mb-3 flex items-center gap-2">
                        {opt["label"]}
                        <span class="badge badge-xs badge-info">Imported</span>
                      </div>
                      <div class="overflow-x-auto">
                        <table class="table table-xs">
                          <thead>
                            <tr>
                              <th>Value</th>
                              <th>Current Modifier</th>
                              <th>Final Price</th>
                            </tr>
                          </thead>
                          <tbody>
                            <%= for value <- opt["values"] do %>
                              <% # Get existing modifier (stored as string like "12.01")
                              stored_modifier = opt["modifiers"][value]

                              modifier_value =
                                if is_binary(stored_modifier), do: stored_modifier, else: "0"

                              modifier_decimal = parse_decimal(modifier_value)
                              final_price = Decimal.add(base_price, modifier_decimal) %>
                              <tr>
                                <td class="font-medium">{value}</td>
                                <td class="text-base-content/60">
                                  <%= if modifier_decimal != Decimal.new("0") do %>
                                    <span class="text-success">+{modifier_value}</span>
                                  <% else %>
                                    <span class="text-base-content/40">+0</span>
                                  <% end %>
                                </td>
                                <td>
                                  <div class="flex items-center gap-2">
                                    <input
                                      type="number"
                                      step="0.01"
                                      min="0"
                                      name={"product[metadata][_price_modifiers][#{opt["key"]}][#{value}]"}
                                      value={Decimal.round(final_price, 2)}
                                      class="input input-xs input-bordered w-28"
                                    />
                                    <span class="text-xs text-base-content/50">
                                      {currency_symbol(@currency)}
                                    </span>
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
            </div>
          <% end %>

          <%!-- Variant Images Section --%>
          <%= if @gallery_image_ids != [] and has_mappable_options?(assigns) do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">
                  <.icon name="hero-photo" class="w-5 h-5" /> Variant Images
                </h2>
                <p class="text-sm text-base-content/60 mb-4">
                  Link images to option values. When a customer selects an option, the corresponding image displays.
                </p>

                <%= for {option_key, option_values} <- get_mappable_options(assigns) do %>
                  <div class="p-4 bg-base-200 rounded-lg mb-4">
                    <h3 class="font-medium mb-3">{humanize_key(option_key)}</h3>
                    <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
                      <%= for value <- option_values do %>
                        <div class="flex flex-col gap-2">
                          <span class="text-sm font-medium">{value}</span>
                          <select
                            name={"product[metadata][_image_mappings][#{option_key}][#{value}]"}
                            class="select select-bordered select-sm"
                          >
                            <option value="">No image</option>
                            <%= for {image_id, idx} <- Enum.with_index(@gallery_image_ids) do %>
                              <option
                                value={image_id}
                                selected={get_image_mapping(@metadata, option_key, value) == image_id}
                              >
                                Gallery image #{idx + 1}
                              </option>
                            <% end %>
                            <%= if @featured_image_id do %>
                              <option
                                value={@featured_image_id}
                                selected={
                                  get_image_mapping(@metadata, option_key, value) ==
                                    @featured_image_id
                                }
                              >
                                Featured image
                              </option>
                            <% end %>
                          </select>
                          <%!-- Preview thumbnail --%>
                          <%= if mapping = get_image_mapping(@metadata, option_key, value) do %>
                            <img
                              src={get_image_url(mapping, "thumbnail")}
                              class="w-16 h-16 object-cover rounded"
                              alt={"Preview for #{value}"}
                            />
                          <% end %>
                        </div>
                      <% end %>
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
                    <.option_field opt={opt} value={@metadata[opt["key"]]} currency={@currency} />
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

  # Format price for display with currency
  defp format_price(nil, _currency), do: "—"
  defp format_price("", _currency), do: "—"

  defp format_price(price, %Currency{} = currency) when is_binary(price) do
    case Decimal.parse(price) do
      {decimal, _} -> Currency.format_amount(decimal, currency)
      :error -> Currency.format_amount(Decimal.new("0"), currency)
    end
  end

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end

  # Get currency symbol for display
  defp currency_symbol(%Currency{symbol: symbol}), do: symbol
  defp currency_symbol(_), do: "$"

  # Get modifier override from product metadata
  # Handles both formats:
  # - String format (unified): "10.00" -> %{"type" => "fixed", "value" => "10.00"}
  # - Object format (legacy): %{"type" => "fixed", "value" => "10.00"} -> returned as-is
  defp get_modifier_override(metadata, option_key, option_value) do
    case metadata do
      %{"_price_modifiers" => %{^option_key => %{^option_value => override}}}
      when is_map(override) ->
        # Object format (legacy): %{"type" => "fixed", "value" => "10"}
        if (override["type"] && override["type"] != "") or
             (override["value"] && override["value"] != "") do
          %{
            "type" => override["type"] || "fixed",
            "value" => override["value"] || "0"
          }
        else
          nil
        end

      %{"_price_modifiers" => %{^option_key => %{^option_value => value}}}
      when is_binary(value) and value != "" ->
        # String format (unified): convert to object for UI display
        %{"type" => "fixed", "value" => value}

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
  attr :currency, :any, default: nil

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
            <span class="badge badge-xs badge-info ml-1">{currency_symbol(@currency)}</span>
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
  defp clean_option_values(metadata, option_schema, original_option_values) do
    case metadata["_option_values"] do
      nil ->
        metadata

      option_values when is_map(option_values) ->
        schema_values = build_schema_values_map(option_schema)

        cleaned =
          option_values
          |> Enum.map(fn {key, selected_values} ->
            schema_for_key = Map.get(schema_values, key, [])
            original_for_key = Map.get(original_option_values, key, [])
            clean_option_entry(key, selected_values, schema_for_key, original_for_key)
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

  # Build a map of option_key -> available values from schema
  defp build_schema_values_map(option_schema) do
    option_schema
    |> Enum.filter(&(&1["type"] in ["select", "multiselect"]))
    |> Enum.map(&{&1["key"], &1["options"] || []})
    |> Map.new()
  end

  # Determine whether to keep an option entry or discard it (nil)
  defp clean_option_entry(key, selected_values, schema_for_key, original_for_key) do
    all_values = Enum.uniq(schema_for_key ++ original_for_key)
    selected = if is_list(selected_values), do: selected_values, else: []
    has_custom_values = original_for_key != [] and original_for_key != schema_for_key

    cond do
      # Has custom values - always keep to preserve the added values
      has_custom_values and selected != [] ->
        {key, selected}

      # All selected from schema only - can be nil
      Enum.sort(selected) == Enum.sort(all_values) ->
        {key, nil}

      # None selected - nil
      selected == [] ->
        {key, nil}

      # Partial selection - keep
      true ->
        {key, selected}
    end
  end

  # Remove price modifier for a specific option value when it's deleted
  defp remove_price_modifier_for_value(metadata, option_key, value) do
    case metadata["_price_modifiers"] do
      nil ->
        metadata

      price_modifiers when is_map(price_modifiers) ->
        case Map.get(price_modifiers, option_key) do
          nil ->
            metadata

          option_modifiers when is_map(option_modifiers) ->
            updated_option_modifiers = Map.delete(option_modifiers, value)

            updated_price_modifiers =
              if updated_option_modifiers == %{} do
                Map.delete(price_modifiers, option_key)
              else
                Map.put(price_modifiers, option_key, updated_option_modifiers)
              end

            if updated_price_modifiers == %{} do
              Map.delete(metadata, "_price_modifiers")
            else
              Map.put(metadata, "_price_modifiers", updated_price_modifiers)
            end

          _ ->
            metadata
        end

      _ ->
        metadata
    end
  end

  # Convert final_price inputs to modifier values
  # final_price - base_price = modifier (for fixed type)
  # Handles two formats:
  # 1. Schema options: %{"final_price" => "123.45"} -> %{"type" => "fixed", "value" => "23.45"}
  # 2. Imported options: "123.45" -> "23.45" (simple string modifier)
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
  # Handle map format (from schema options with final_price key)
  # Always returns string format for consistency with imports
  defp convert_modifier_data(modifier_data, base_price) when is_map(modifier_data) do
    final_price_str = modifier_data["final_price"]

    cond do
      # If final_price is provided, calculate modifier from it
      final_price_str && final_price_str != "" ->
        final_price = parse_decimal(final_price_str)
        # modifier = final_price - base_price
        modifier = Decimal.sub(final_price, base_price)

        # Only store if it's different from 0 (otherwise use default)
        if Decimal.compare(modifier, Decimal.new("0")) == :eq do
          nil
        else
          # Return simple string (unified format)
          Decimal.to_string(Decimal.round(modifier, 2))
        end

      # If no final_price but has explicit value, extract and return as string
      modifier_data["value"] && modifier_data["value"] != "" ->
        # Return just the value string (unified format)
        modifier_data["value"]

      # No valid data
      true ->
        nil
    end
  end

  # Handle string format (from imported options where input sends final_price directly)
  defp convert_modifier_data(final_price_str, base_price) when is_binary(final_price_str) do
    if final_price_str == "" do
      nil
    else
      final_price = parse_decimal(final_price_str)
      # modifier = final_price - base_price
      modifier = Decimal.sub(final_price, base_price)

      # Store as string for consistency with import format
      modifier_str = Decimal.to_string(Decimal.round(modifier, 2))

      # Return as simple string (import format) not map
      modifier_str
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

  # Merge translation params from form into existing translations
  defp merge_translation_params(existing, nil), do: existing

  defp merge_translation_params(existing, new_params) when is_map(new_params) do
    Enum.reduce(new_params, existing, fn {lang, fields}, acc ->
      existing_lang = Map.get(acc, lang, %{})
      merged_lang = Map.merge(existing_lang, fields || %{})
      # Remove empty values
      cleaned_lang = Enum.reject(merged_lang, fn {_k, v} -> v == "" end) |> Map.new()
      if cleaned_lang == %{}, do: Map.delete(acc, lang), else: Map.put(acc, lang, cleaned_lang)
    end)
  end

  defp merge_translation_params(existing, _), do: existing

  # Build localized field params from main form values and translations
  defp build_localized_params(entity, params, translations_map, default_language) do
    translatable_fields = Translations.product_fields()

    # Extract main form values for default language
    default_values = %{
      "title" => params["title"],
      "slug" => params["slug"],
      "description" => params["description"],
      "body_html" => params["body_html"],
      "seo_title" => params["seo_title"],
      "seo_description" => params["seo_description"]
    }

    # Merge translations into localized field maps
    localized_attrs =
      TranslationTabs.merge_translations_to_attrs(
        entity,
        translations_map,
        default_values,
        default_language,
        translatable_fields
      )

    # Replace simple field values with localized maps
    params
    |> Map.put("title", localized_attrs[:title])
    |> Map.put("slug", localized_attrs[:slug])
    |> Map.put("description", localized_attrs[:description])
    |> Map.put("body_html", localized_attrs[:body_html])
    |> Map.put("seo_title", localized_attrs[:seo_title])
    |> Map.put("seo_description", localized_attrs[:seo_description])
  end

  # ===========================================
  # IMAGE MAPPING HELPERS
  # ===========================================

  # Build list of valid image IDs from socket assigns
  defp build_valid_image_ids(assigns) do
    gallery_ids = assigns[:gallery_image_ids] || []
    featured_id = assigns[:featured_image_id]

    if featured_id do
      [featured_id | gallery_ids]
    else
      gallery_ids
    end
  end

  # Clean up _image_mappings - remove empty values and invalid image IDs
  defp clean_image_mappings(metadata, valid_image_ids) do
    case metadata["_image_mappings"] do
      nil ->
        metadata

      mappings when is_map(mappings) ->
        cleaned =
          mappings
          |> Enum.map(fn {option_key, value_mappings} ->
            cleaned_values =
              value_mappings
              |> Enum.reject(fn {_v, image_id} ->
                image_id == "" or image_id == nil or image_id not in valid_image_ids
              end)
              |> Map.new()

            {option_key, cleaned_values}
          end)
          |> Enum.reject(fn {_k, v} -> v == %{} end)
          |> Map.new()

        if cleaned == %{} do
          Map.delete(metadata, "_image_mappings")
        else
          Map.put(metadata, "_image_mappings", cleaned)
        end

      _ ->
        metadata
    end
  end

  # Clean stale image mappings on product load, returns {cleaned_metadata, had_stale?}
  defp clean_stale_image_mappings(metadata, valid_ids) do
    case metadata["_image_mappings"] do
      nil ->
        {metadata, false}

      mappings when is_map(mappings) ->
        # Count original mappings
        original_count =
          Enum.reduce(mappings, 0, fn {_k, v}, acc ->
            acc + map_size(v)
          end)

        # Clean mappings
        cleaned =
          Enum.map(mappings, fn {key, value_map} ->
            filtered = Enum.filter(value_map, fn {_v, id} -> id in valid_ids end) |> Map.new()
            {key, filtered}
          end)
          |> Enum.reject(fn {_k, v} -> v == %{} end)
          |> Map.new()

        # Count cleaned mappings
        cleaned_count =
          Enum.reduce(cleaned, 0, fn {_k, v}, acc ->
            acc + map_size(v)
          end)

        had_stale = cleaned_count < original_count

        updated_metadata =
          if cleaned == %{},
            do: Map.delete(metadata, "_image_mappings"),
            else: Map.put(metadata, "_image_mappings", cleaned)

        {updated_metadata, had_stale}

      _ ->
        {metadata, false}
    end
  end

  # Show warning if stale mappings were cleaned
  defp maybe_warn_stale_mappings(socket, false), do: socket

  defp maybe_warn_stale_mappings(socket, true) do
    put_flash(
      socket,
      :warning,
      "Some variant image mappings were removed because the linked images no longer exist."
    )
  end

  # Check if product has mappable options (select/multiselect with values)
  defp has_mappable_options?(assigns) do
    assigns[:original_option_values] != %{} or
      Enum.any?(assigns[:option_schema] || [], fn opt ->
        opt["type"] in ["select", "multiselect"] and (opt["options"] || []) != []
      end)
  end

  # Get all mappable options with their values
  # Combines schema options with product-specific option values
  defp get_mappable_options(assigns) do
    # Get options from schema
    schema_options =
      (assigns[:option_schema] || [])
      |> Enum.filter(&(&1["type"] in ["select", "multiselect"]))
      |> Enum.map(&{&1["key"], &1["options"] || []})
      |> Map.new()

    # Get product-specific option values (from imports or manual additions)
    product_options = assigns[:original_option_values] || %{}

    # Merge: schema provides base, product overrides/extends
    Map.merge(schema_options, product_options, fn _k, schema, product ->
      Enum.uniq(schema ++ product)
    end)
    |> Enum.reject(fn {_k, v} -> v == [] end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  # Get image mapping for option key + value from metadata
  defp get_image_mapping(metadata, option_key, value) do
    get_in(metadata, ["_image_mappings", option_key, value])
  end

  # Humanize option key for display (color -> Color, frame_material -> Frame material)
  defp humanize_key(key) do
    key
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
