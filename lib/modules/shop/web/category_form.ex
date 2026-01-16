defmodule PhoenixKit.Modules.Shop.Web.CategoryForm do
  @moduledoc """
  Category create/edit form LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "New Category")}
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

    socket
    |> assign(:page_title, "New Category")
    |> assign(:category, category)
    |> assign(:changeset, changeset)
    |> assign(:parent_options, parent_options)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    category = Shop.get_category!(id)
    changeset = Shop.change_category(category)

    # Exclude self from parent options
    parent_options =
      Shop.category_options()
      |> Enum.reject(fn {_name, parent_id} -> parent_id == category.id end)

    socket
    |> assign(:page_title, "Edit #{category.name}")
    |> assign(:category, category)
    |> assign(:changeset, changeset)
    |> assign(:parent_options, parent_options)
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
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
