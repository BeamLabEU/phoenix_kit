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
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "New Category")
      |> assign(:supported_types, OptionTypes.supported_types())

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
    global_options = Options.get_global_options()

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
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    category = Shop.get_category!(id)
    changeset = Shop.change_category(category)
    category_options = Options.get_category_options(category)
    global_options = Options.get_global_options()
    merged = Options.merge_schemas(global_options, category_options)

    # Exclude self from parent options
    parent_options =
      Shop.category_options()
      |> Enum.reject(fn {_name, parent_id} -> parent_id == category.id end)

    socket
    |> assign(:page_title, "Edit #{category.name}")
    |> assign(:category, category)
    |> assign(:changeset, changeset)
    |> assign(:parent_options, parent_options)
    |> assign(:category_options, category_options)
    |> assign(:global_options, global_options)
    |> assign(:merged_preview, merged)
    |> assign(:show_opt_modal, false)
    |> assign(:editing_opt, nil)
    |> assign(:opt_form_data, initial_opt_form_data())
  end

  @impl true
  def handle_event("validate", %{"category" => category_params}, socket) do
    changeset =
      socket.assigns.category
      |> Shop.change_category(category_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl true
  def handle_event("save", %{"category" => category_params}, socket) do
    save_category(socket, socket.assigns.live_action, category_params)
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
      <div class="p-6 max-w-2xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-3xl font-bold text-base-content">{@page_title}</h1>
          <.link navigate={Routes.path("/admin/shop/categories")} class="btn btn-ghost">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </.link>
        </div>

        <%!-- Form --%>
        <.form
          for={@changeset}
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <div class="form-control">
                <label class="label"><span class="label-text">Name *</span></label>
                <input
                  type="text"
                  name="category[name]"
                  value={Ecto.Changeset.get_field(@changeset, :name)}
                  class={["input input-bordered", @changeset.errors[:name] && "input-error"]}
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

              <div class="form-control">
                <label class="label"><span class="label-text">Slug</span></label>
                <input
                  type="text"
                  name="category[slug]"
                  value={Ecto.Changeset.get_field(@changeset, :slug)}
                  class="input input-bordered"
                  placeholder="Auto-generated from name"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Description</span></label>
                <textarea
                  name="category[description]"
                  class="textarea textarea-bordered h-24"
                  placeholder="Category description"
                >{Ecto.Changeset.get_field(@changeset, :description)}</textarea>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Parent Category</span></label>
                <select name="category[parent_id]" class="select select-bordered">
                  <option value="">No parent (root category)</option>
                  <%= for {name, id} <- @parent_options do %>
                    <option
                      value={id}
                      selected={Ecto.Changeset.get_field(@changeset, :parent_id) == id}
                    >
                      {name}
                    </option>
                  <% end %>
                </select>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Position</span></label>
                <input
                  type="number"
                  name="category[position]"
                  value={Ecto.Changeset.get_field(@changeset, :position) || 0}
                  class="input input-bordered w-32"
                  min="0"
                />
                <label class="label">
                  <span class="label-text-alt text-base-content/60">
                    Lower numbers appear first
                  </span>
                </label>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Image URL</span></label>
                <input
                  type="url"
                  name="category[image_url]"
                  value={Ecto.Changeset.get_field(@changeset, :image_url)}
                  class="input input-bordered"
                  placeholder="https://..."
                />
              </div>
            </div>
          </div>

          <%!-- Category Options (only in edit mode) --%>
          <%= if @live_action == :edit do %>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <div class="flex items-center justify-between mb-4">
                  <h2 class="card-title">
                    <.icon name="hero-tag" class="w-5 h-5" /> Category Options
                  </h2>
                  <button
                    type="button"
                    phx-click="show_add_opt_modal"
                    class="btn btn-outline btn-sm"
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
            <.link navigate={Routes.path("/admin/shop/categories")} class="btn btn-ghost">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-5 h-5 mr-2" />
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
end
