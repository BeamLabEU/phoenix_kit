defmodule PhoenixKit.Modules.Shop.Web.CategoryForm do
  @moduledoc """
  Category create/edit form LiveView for Shop module.

  Includes management of category-specific product options.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.OptionTypes
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Shop.Web.Components.TranslationTabs
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  import TranslationTabs

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "New Category")
      |> assign(:supported_types, OptionTypes.supported_types())
      |> assign(:show_media_selector, false)
      |> assign(:image_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = apply_action(socket, socket.assigns.live_action, params)
    {:noreply, socket}
  end

  defp apply_action(socket, :new, _params) do
    category = %Category{}
    changeset = Shop.change_category(category)
    parent_options = Shop.category_options()
    global_options = Options.get_enabled_global_options()

    socket
    |> assign(:page_title, "New Category")
    |> assign(:category, category)
    |> assign(:changeset, changeset)
    |> assign(:parent_options, parent_options)
    |> assign(:category_options, [])
    |> assign(:global_options, global_options)
    |> assign(:merged_preview, global_options)
    |> assign(:show_opt_modal, false)
    |> assign(:editing_opt, nil)
    |> assign(:opt_form_data, initial_opt_form_data())
    |> assign(:image_id, nil)
    |> assign(:product_options, [])
    |> assign_translation_state(%Category{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    category = Shop.get_category!(id)
    changeset = Shop.change_category(category)
    category_options = Options.get_category_options(category)
    global_options = Options.get_enabled_global_options()
    merged = Options.merge_schemas(global_options, category_options)

    # Exclude self from parent options
    parent_options =
      Shop.category_options()
      |> Enum.reject(fn {_name, parent_uuid} -> parent_uuid == category.uuid end)

    product_options = Shop.list_category_product_options(category.uuid)

    socket
    |> assign(
      :page_title,
      "Edit #{Translations.get(category, :name, TranslationTabs.get_default_language())}"
    )
    |> assign(:category, category)
    |> assign(:changeset, changeset)
    |> assign(:parent_options, parent_options)
    |> assign(:category_options, category_options)
    |> assign(:global_options, global_options)
    |> assign(:merged_preview, merged)
    |> assign(:show_opt_modal, false)
    |> assign(:editing_opt, nil)
    |> assign(:opt_form_data, initial_opt_form_data())
    |> assign(:image_id, category.image_id)
    |> assign(:product_options, product_options)
    |> assign_translation_state(category)
  end

  # Assign translation-related state (localized fields model)
  defp assign_translation_state(socket, category) do
    enabled_languages = TranslationTabs.get_enabled_languages()
    default_language = TranslationTabs.get_default_language()
    show_translations = TranslationTabs.show_translation_tabs?()

    # Build translations map from localized fields for UI
    translatable_fields = Translations.category_fields()
    translations_map = TranslationTabs.build_translations_map(category, translatable_fields)

    socket
    |> assign(:enabled_languages, enabled_languages)
    |> assign(:default_language, default_language)
    |> assign(:current_translation_language, default_language)
    |> assign(:show_translation_tabs, show_translations)
    |> assign(:category_translations, translations_map)
  end

  @impl true
  def handle_event("validate", %{"category" => category_params}, socket) do
    # Update translations from form params
    category_translations =
      merge_translation_params(
        socket.assigns[:category_translations] || %{},
        category_params["translations"]
      )

    # Build localized field attrs from main form values and translations
    category_params =
      build_localized_params(
        socket.assigns.category,
        category_params,
        category_translations,
        socket.assigns.default_language
      )

    changeset =
      socket.assigns.category
      |> Shop.change_category(category_params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:changeset, changeset)
    |> assign(:category_translations, category_translations)
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_event("save", %{"category" => category_params}, socket) do
    # Add Storage image_id from socket assigns
    category_params = Map.put(category_params, "image_id", socket.assigns.image_id)

    # Build localized field attrs from main form values and translations
    category_params =
      build_localized_params(
        socket.assigns.category,
        category_params,
        socket.assigns[:category_translations] || %{},
        socket.assigns.default_language
      )

    save_category(socket, socket.assigns.live_action, category_params)
  end

  def handle_event("switch_language", %{"language" => language}, socket) do
    {:noreply, assign(socket, :current_translation_language, language)}
  end

  # Media Picker Events

  @impl true
  def handle_event("open_media_picker", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, true)}
  end

  @impl true
  def handle_event("remove_image", _params, socket) do
    {:noreply, assign(socket, :image_id, nil)}
  end

  # Option Modal Events

  @impl true
  def handle_event("show_add_opt_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_opt_modal, true)
     |> assign(:editing_opt, nil)
     |> assign(:opt_form_data, initial_opt_form_data())}
  end

  @impl true
  def handle_event("show_edit_opt_modal", %{"key" => key}, socket) do
    option = Enum.find(socket.assigns.category_options, &(&1["key"] == key))

    if option do
      form_data = %{
        key: option["key"],
        label: option["label"],
        type: option["type"],
        options: option["options"] || [],
        required: option["required"] || false,
        unit: option["unit"] || ""
      }

      {:noreply,
       socket
       |> assign(:show_opt_modal, true)
       |> assign(:editing_opt, option)
       |> assign(:opt_form_data, form_data)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_opt_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_opt_modal, false)
     |> assign(:editing_opt, nil)
     |> assign(:opt_form_data, initial_opt_form_data())}
  end

  @impl true
  def handle_event("validate_opt_form", %{"option" => params}, socket) do
    form_data = %{
      key: params["key"] || "",
      label: params["label"] || "",
      type: params["type"] || "text",
      options: parse_options(params["options"]),
      required: params["required"] == "true",
      unit: params["unit"] || ""
    }

    # Auto-generate key from label if creating new
    form_data =
      if socket.assigns.editing_opt == nil and form_data.key == "" do
        %{form_data | key: slugify_key(form_data.label)}
      else
        form_data
      end

    {:noreply, assign(socket, :opt_form_data, form_data)}
  end

  @impl true
  def handle_event("save_category_option", %{"option" => params}, socket) do
    form_data = parse_opt_form_data(params)
    opt = build_option(form_data)

    current = socket.assigns.category_options
    editing = socket.assigns.editing_opt

    updated_opts =
      if editing do
        Enum.map(current, fn o ->
          if o["key"] == editing["key"], do: Map.merge(o, opt), else: o
        end)
      else
        opt = Map.put(opt, "position", length(current))
        current ++ [opt]
      end

    # Save to category
    case Options.update_category_options(socket.assigns.category, updated_opts) do
      {:ok, updated_category} ->
        merged = Options.merge_schemas(socket.assigns.global_options, updated_opts)

        {:noreply,
         socket
         |> assign(:category, updated_category)
         |> assign(:category_options, updated_opts)
         |> assign(:merged_preview, merged)
         |> assign(:show_opt_modal, false)
         |> assign(:editing_opt, nil)
         |> assign(:opt_form_data, initial_opt_form_data())
         |> put_flash(:info, if(editing, do: "Option updated", else: "Option added"))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_category_option", %{"key" => key}, socket) do
    updated_opts = Enum.reject(socket.assigns.category_options, &(&1["key"] == key))

    case Options.update_category_options(socket.assigns.category, updated_opts) do
      {:ok, updated_category} ->
        merged = Options.merge_schemas(socket.assigns.global_options, updated_opts)

        {:noreply,
         socket
         |> assign(:category, updated_category)
         |> assign(:category_options, updated_opts)
         |> assign(:merged_preview, merged)
         |> put_flash(:info, "Option removed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reorder_category_options", %{"ordered_ids" => ordered_keys}, socket) do
    current = socket.assigns.category_options

    reordered =
      ordered_keys
      |> Enum.with_index()
      |> Enum.map(fn {key, idx} ->
        opt = Enum.find(current, &(&1["key"] == key))
        if opt, do: Map.put(opt, "position", idx), else: nil
      end)
      |> Enum.reject(&is_nil/1)

    case Options.update_category_options(socket.assigns.category, reordered) do
      {:ok, updated_category} ->
        merged = Options.merge_schemas(socket.assigns.global_options, reordered)

        {:noreply,
         socket
         |> assign(:category, updated_category)
         |> assign(:category_options, reordered)
         |> assign(:merged_preview, merged)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reorder failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("add_opt_option", _params, socket) do
    form_data = socket.assigns.opt_form_data
    updated = %{form_data | options: form_data.options ++ [""]}
    {:noreply, assign(socket, :opt_form_data, updated)}
  end

  @impl true
  def handle_event("remove_opt_option", %{"index" => idx}, socket) do
    form_data = socket.assigns.opt_form_data
    index = String.to_integer(idx)
    updated = %{form_data | options: List.delete_at(form_data.options, index)}
    {:noreply, assign(socket, :opt_form_data, updated)}
  end

  # Media Picker Info Handlers

  @impl true
  def handle_info({:media_selected, file_ids}, socket) do
    image_id = List.first(file_ids)

    {:noreply,
     socket
     |> assign(:image_id, image_id)
     |> assign(:show_media_selector, false)}
  end

  @impl true
  def handle_info({:media_selector_closed}, socket) do
    {:noreply, assign(socket, :show_media_selector, false)}
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
              navigate={Routes.path("/admin/shop/categories")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">{@page_title}</h1>
              <p class="text-base-content/70 mt-1">
                {if @live_action == :new, do: "Create a new category", else: "Edit category details"}
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
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Basic Information</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Name *</span>
                    <%= if @show_translation_tabs do %>
                      <span class="label-text-alt text-base-content/50">
                        {String.upcase(@default_language)}
                      </span>
                    <% end %>
                  </label>
                  <input
                    type="text"
                    name="category[name]"
                    value={TranslationTabs.get_localized_value(@changeset, :name, @default_language)}
                    class={[
                      "input input-bordered w-full focus:input-primary",
                      @changeset.errors[:name] && "input-error"
                    ]}
                    placeholder="Category name"
                    required
                  />
                  <%= if @changeset.errors[:name] do %>
                    <label class="label">
                      <span class="label-text-alt text-error">
                        {elem(@changeset.errors[:name], 0)}
                      </span>
                    </label>
                  <% end %>
                </div>

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
                    name="category[slug]"
                    value={TranslationTabs.get_localized_value(@changeset, :slug, @default_language)}
                    class="input input-bordered w-full focus:input-primary"
                    placeholder="Auto-generated from name"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Parent Category</span>
                  </label>
                  <select
                    name="category[parent_uuid]"
                    class="select select-bordered w-full focus:select-primary"
                  >
                    <option value="">No parent (root category)</option>
                    <%= for {name, uuid} <- @parent_options do %>
                      <option
                        value={uuid}
                        selected={Ecto.Changeset.get_field(@changeset, :parent_uuid) == uuid}
                      >
                        {name}
                      </option>
                    <% end %>
                  </select>
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Position</span>
                  </label>
                  <input
                    type="number"
                    name="category[position]"
                    value={Ecto.Changeset.get_field(@changeset, :position) || 0}
                    class="input input-bordered w-full focus:input-primary"
                    min="0"
                    placeholder="0"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Status</span>
                  </label>
                  <select
                    name="category[status]"
                    class="select select-bordered w-full focus:select-primary"
                  >
                    <option
                      value="active"
                      selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}
                    >
                      Active — Category and products visible
                    </option>
                    <option
                      value="unlisted"
                      selected={Ecto.Changeset.get_field(@changeset, :status) == "unlisted"}
                    >
                      Unlisted — Category hidden, products still visible
                    </option>
                    <option
                      value="hidden"
                      selected={Ecto.Changeset.get_field(@changeset, :status) == "hidden"}
                    >
                      Hidden — Category and products hidden
                    </option>
                  </select>
                  <label class="label">
                    <span class="label-text-alt text-base-content/50">
                      Unlisted: products appear in search/catalog but category not in menu
                    </span>
                  </label>
                </div>

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
                    name="category[description]"
                    class="textarea textarea-bordered w-full focus:textarea-primary h-24"
                    placeholder="Category description"
                  >{TranslationTabs.get_localized_value(@changeset, :description, @default_language)}</textarea>
                </div>

                <%!-- Category Image Section --%>
                <div class="form-control w-full md:col-span-2">
                  <label class="label">
                    <span class="label-text font-medium">Category Image</span>
                  </label>
                  <div class="flex items-start gap-4">
                    <%!-- Image Preview --%>
                    <%= if @image_id do %>
                      <div class="relative group">
                        <img
                          src={get_storage_image_url(@image_id, "thumbnail")}
                          class="w-24 h-24 object-cover rounded-lg shadow"
                          alt="Category image"
                        />
                        <button
                          type="button"
                          phx-click="remove_image"
                          class="absolute -top-2 -right-2 btn btn-circle btn-xs btn-error opacity-0 group-hover:opacity-100 transition-opacity"
                        >
                          ×
                        </button>
                      </div>
                    <% else %>
                      <div class="w-24 h-24 border-2 border-dashed border-base-300 rounded-lg flex items-center justify-center">
                        <.icon name="hero-photo" class="w-8 h-8 opacity-30" />
                      </div>
                    <% end %>

                    <%!-- Select from Storage --%>
                    <div class="flex flex-col gap-2">
                      <button
                        type="button"
                        phx-click="open_media_picker"
                        class="btn btn-sm btn-primary"
                      >
                        <.icon name="hero-photo" class="w-4 h-4 mr-1" />
                        {if @image_id, do: "Change Image", else: "Select from Storage"}
                      </button>
                    </div>
                  </div>
                </div>

                <%!-- Featured Product (fallback image source) --%>
                <%= if @live_action == :edit do %>
                  <div class="form-control w-full md:col-span-2">
                    <label class="label">
                      <span class="label-text font-medium">Featured Product (image fallback)</span>
                      <%= if @image_id do %>
                        <span class="label-text-alt text-warning">Storage image has priority</span>
                      <% end %>
                    </label>
                    <%= if @product_options != [] do %>
                      <select
                        name="category[featured_product_uuid]"
                        class={[
                          "select select-bordered w-full focus:select-primary",
                          @image_id && "opacity-50"
                        ]}
                      >
                        <option value="">Auto-detect (first product with image)</option>
                        <%= for {name, uuid} <- @product_options do %>
                          <option
                            value={uuid}
                            selected={
                              Ecto.Changeset.get_field(@changeset, :featured_product_uuid) == uuid
                            }
                          >
                            {name}
                          </option>
                        <% end %>
                      </select>
                    <% else %>
                      <div class="text-sm text-base-content/50 py-2">
                        <.icon name="hero-information-circle" class="w-4 h-4 inline mr-1" />
                        No products with images in this category. Add product images to enable this option.
                      </div>
                    <% end %>
                    <label class="label">
                      <span class="label-text-alt text-base-content/50">
                        Used as category image when no Storage image is selected
                      </span>
                    </label>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Card: Translations (only show when Languages module enabled with 2+ languages) --%>
          <%= if @show_translation_tabs do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title text-xl mb-4">Translations</h2>
                <p class="text-base-content/60 text-sm mb-4">
                  Translate category content for different languages. The default language uses the main fields above.
                </p>

                <%!-- Language Tabs --%>
                <.translation_tabs
                  languages={@enabled_languages}
                  current_language={@current_translation_language}
                  translations={@category_translations}
                  translatable_fields={Translations.category_fields()}
                  on_click="switch_language"
                />

                <%!-- Translation Fields for Current Language --%>
                <div class="mt-6">
                  <.translation_fields
                    language={@current_translation_language}
                    translations={@category_translations}
                    is_default_language={@current_translation_language == @default_language}
                    form_prefix="category"
                    fields={[
                      %{
                        key: :name,
                        label: "Name",
                        type: :text,
                        placeholder: "Translated category name"
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
                        placeholder: "Translated description"
                      }
                    ]}
                  />
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Category Options (only in edit mode) --%>
          <%= if @live_action == :edit do %>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <div class="flex items-center justify-between mb-6">
                  <h2 class="card-title text-xl">
                    <.icon name="hero-tag" class="w-5 h-5" /> Category Options
                  </h2>
                  <button
                    type="button"
                    phx-click="show_add_opt_modal"
                    class="btn btn-outline btn-primary btn-sm"
                  >
                    <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Option
                  </button>
                </div>

                <p class="text-sm text-base-content/60 mb-4">
                  Define options specific to this category.
                  These override global options with the same key.
                </p>

                <%= if @category_options == [] do %>
                  <div class="text-center py-6 text-base-content/50">
                    <p>No category-specific options</p>
                    <p class="text-sm">Products will use global options only</p>
                  </div>
                <% else %>
                  <div class="flex flex-col gap-2">
                    <%= for opt <- @category_options do %>
                      <div class="flex items-center p-3 bg-base-200 rounded-lg hover:bg-base-300 transition-colors">
                        <div class="flex-1 min-w-0">
                          <div class="flex items-center gap-2">
                            <span class="font-medium text-sm">{opt["label"]}</span>
                            <span class="badge badge-ghost badge-xs">{opt["type"]}</span>
                            <%= if opt["required"] do %>
                              <span class="badge badge-warning badge-xs">Required</span>
                            <% end %>
                          </div>
                          <div class="text-xs text-base-content/50">
                            Key: <code class="bg-base-300 px-1 rounded">{opt["key"]}</code>
                          </div>
                        </div>
                        <div class="flex items-center gap-1">
                          <button
                            type="button"
                            phx-click="show_edit_opt_modal"
                            phx-value-key={opt["key"]}
                            class="btn btn-ghost btn-xs"
                          >
                            <.icon name="hero-pencil" class="w-3 h-3" />
                          </button>
                          <button
                            type="button"
                            phx-click="delete_category_option"
                            phx-value-key={opt["key"]}
                            data-confirm="Remove this option?"
                            class="btn btn-ghost btn-xs text-error"
                          >
                            <.icon name="hero-trash" class="w-3 h-3" />
                          </button>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Merged Preview --%>
                <div class="mt-4 p-3 bg-base-200/50 rounded-lg border border-base-300">
                  <h4 class="font-medium text-sm mb-2">
                    <.icon name="hero-eye" class="w-4 h-4 inline" /> Preview: Merged Schema
                  </h4>
                  <p class="text-xs text-base-content/60 mb-2">
                    Products in this category will show these options:
                  </p>
                  <div class="flex flex-wrap gap-1">
                    <%= for opt <- @merged_preview do %>
                      <span class={[
                        "badge badge-sm",
                        if(opt in @category_options, do: "badge-primary", else: "badge-ghost")
                      ]}>
                        {opt["label"]}
                        <%= if opt["required"] do %>
                          <span class="text-warning ml-1">*</span>
                        <% end %>
                      </span>
                    <% end %>
                    <%= if @merged_preview == [] do %>
                      <span class="text-xs text-base-content/50">No options defined</span>
                    <% end %>
                  </div>
                  <p class="text-xs text-base-content/50 mt-2">
                    <span class="badge badge-primary badge-xs">Blue</span>
                    = Category specific, <span class="badge badge-ghost badge-xs">Gray</span>
                    = Global
                  </p>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Submit --%>
          <div class="flex justify-end gap-4">
            <.link navigate={Routes.path("/admin/shop/categories")} class="btn btn-outline">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-4 h-4 mr-2" />
              {if @live_action == :new, do: "Create Category", else: "Update Category"}
            </button>
          </div>
        </.form>
      </div>

      <%!-- Option Modal --%>
      <%= if @show_opt_modal do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-lg">
            <h3 class="font-bold text-lg mb-4">
              {if @editing_opt, do: "Edit Option", else: "Add Category Option"}
            </h3>

            <.form
              for={%{}}
              phx-change="validate_opt_form"
              phx-submit="save_category_option"
              class="space-y-4"
            >
              <div class="form-control">
                <label class="label"><span class="label-text">Label *</span></label>
                <input
                  type="text"
                  name="option[label]"
                  value={@opt_form_data.label}
                  class="input input-bordered"
                  placeholder="e.g., Mounting Type"
                  required
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Key</span></label>
                <input
                  type="text"
                  name="option[key]"
                  value={@opt_form_data.key}
                  class="input input-bordered font-mono"
                  placeholder="Auto-generated"
                  disabled={@editing_opt != nil}
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Type *</span></label>
                <select name="option[type]" class="select select-bordered">
                  <%= for type <- @supported_types do %>
                    <option value={type} selected={@opt_form_data.type == type}>
                      {type}
                    </option>
                  <% end %>
                </select>
              </div>

              <%= if @opt_form_data.type in ["select", "multiselect"] do %>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Options *</span>
                    <button type="button" phx-click="add_opt_option" class="btn btn-ghost btn-xs">
                      <.icon name="hero-plus" class="w-4 h-4" /> Add
                    </button>
                  </label>
                  <div class="space-y-2">
                    <%= for {opt, idx} <- Enum.with_index(@opt_form_data.options) do %>
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name={"option[options][#{idx}]"}
                          value={opt}
                          class="input input-bordered input-sm flex-1"
                          placeholder="Option value"
                        />
                        <button
                          type="button"
                          phx-click="remove_opt_option"
                          phx-value-index={idx}
                          class="btn btn-ghost btn-sm text-error"
                        >
                          <.icon name="hero-x-mark" class="w-4 h-4" />
                        </button>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <div class="form-control">
                <label class="label"><span class="label-text">Unit (optional)</span></label>
                <input
                  type="text"
                  name="option[unit]"
                  value={@opt_form_data.unit}
                  class="input input-bordered input-sm w-32"
                  placeholder="e.g., cm"
                />
              </div>

              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="checkbox"
                    name="option[required]"
                    value="true"
                    checked={@opt_form_data.required}
                    class="checkbox checkbox-primary"
                  />
                  <span class="label-text">Required field</span>
                </label>
              </div>

              <div class="modal-action">
                <button type="button" phx-click="close_opt_modal" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">
                  {if @editing_opt, do: "Update", else: "Add"}
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_opt_modal"></div>
        </div>
      <% end %>

      <%!-- Media Selector Modal --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="media-selector-modal"
        show={@show_media_selector}
        mode={:single}
        selected_ids={if @image_id, do: [@image_id], else: []}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # Private action helpers

  defp save_category(socket, :new, category_params) do
    case Shop.create_category(category_params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category created")
         |> push_navigate(to: Routes.path("/admin/shop/categories"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_category(socket, :edit, category_params) do
    case Shop.update_category(socket.assigns.category, category_params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category updated")
         |> push_navigate(to: Routes.path("/admin/shop/categories"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  # Private helpers

  defp initial_opt_form_data do
    %{
      key: "",
      label: "",
      type: "text",
      options: [],
      required: false,
      unit: ""
    }
  end

  defp slugify_key(""), do: ""

  defp slugify_key(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp parse_opt_form_data(params) do
    %{
      key: params["key"] || "",
      label: params["label"] || "",
      type: params["type"] || "text",
      options: parse_options(params["options"]),
      required: params["required"] == "true",
      unit: params["unit"] || ""
    }
  end

  defp build_option(form_data) do
    key = if form_data.key == "", do: slugify_key(form_data.label), else: form_data.key

    %{
      "key" => key,
      "label" => form_data.label,
      "type" => form_data.type,
      "required" => form_data.required
    }
    |> maybe_put_options(form_data)
    |> maybe_put_unit(form_data)
  end

  defp maybe_put_options(opt, %{type: type, options: options})
       when type in ["select", "multiselect"],
       do: Map.put(opt, "options", options)

  defp maybe_put_options(opt, _), do: opt

  defp maybe_put_unit(opt, %{unit: ""}), do: opt
  defp maybe_put_unit(opt, %{unit: unit}), do: Map.put(opt, "unit", unit)

  defp parse_options(nil), do: []

  defp parse_options(options) when is_map(options) do
    options
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_options(options) when is_list(options), do: options
  defp parse_options(_), do: []

  # Get Storage image URL
  defp get_storage_image_url(nil, _variant), do: nil

  defp get_storage_image_url(file_id, variant) do
    URLSigner.signed_url(file_id, variant)
  rescue
    _ -> nil
  end

  # Merge translation params from form into existing translations (for UI state during validate)
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
    translatable_fields = Translations.category_fields()

    # Extract main form values for default language
    default_values = %{
      "name" => params["name"],
      "slug" => params["slug"],
      "description" => params["description"]
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
    |> Map.put("name", localized_attrs[:name])
    |> Map.put("slug", localized_attrs[:slug])
    |> Map.put("description", localized_attrs[:description])
  end
end
