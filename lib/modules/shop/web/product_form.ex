defmodule PhoenixKit.Modules.Shop.Web.ProductForm do
  @moduledoc """
  Product create/edit form LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Product
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

    socket
    |> assign(:page_title, "New Product")
    |> assign(:product, product)
    |> assign(:changeset, changeset)
    |> assign(:categories, categories)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    product = Shop.get_product!(id, preload: [:category])
    changeset = Shop.change_product(product)
    categories = Shop.category_options()

    socket
    |> assign(:page_title, "Edit #{product.title}")
    |> assign(:product, product)
    |> assign(:changeset, changeset)
    |> assign(:categories, categories)
  end

  @impl true
  def handle_event("validate", %{"product" => product_params}, socket) do
    changeset =
      socket.assigns.product
      |> Shop.change_product(product_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl true
  def handle_event("save", %{"product" => product_params}, socket) do
    save_product(socket, socket.assigns.live_action, product_params)
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
        {:noreply,
         socket
         |> put_flash(:info, "Product updated")
         |> push_navigate(to: Routes.path("/admin/shop/products/#{product.id}"))}

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
      <div class="p-6 max-w-4xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-3xl font-bold text-base-content">{@page_title}</h1>
          </div>
          <.link navigate={Routes.path("/admin/shop/products")} class="btn btn-ghost">
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
          <%!-- Basic Info --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Basic Information</h2>

              <div class="form-control">
                <label class="label"><span class="label-text">Title *</span></label>
                <input
                  type="text"
                  name="product[title]"
                  value={Ecto.Changeset.get_field(@changeset, :title)}
                  class={["input input-bordered", @changeset.errors[:title] && "input-error"]}
                  placeholder="Product title"
                  required
                />
                <%= if @changeset.errors[:title] do %>
                  <label class="label">
                    <span class="label-text-alt text-error">
                      {elem(@changeset.errors[:title], 0)}
                    </span>
                  </label>
                <% end %>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Slug</span></label>
                <input
                  type="text"
                  name="product[slug]"
                  value={Ecto.Changeset.get_field(@changeset, :slug)}
                  class="input input-bordered"
                  placeholder="Auto-generated from title"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Description</span></label>
                <textarea
                  name="product[description]"
                  class="textarea textarea-bordered h-24"
                  placeholder="Short description"
                >{Ecto.Changeset.get_field(@changeset, :description)}</textarea>
              </div>
            </div>
          </div>

          <%!-- Type & Category --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Type & Organization</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Product Type</span></label>
                  <select name="product[product_type]" class="select select-bordered">
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

                <div class="form-control">
                  <label class="label"><span class="label-text">Category</span></label>
                  <select name="product[category_id]" class="select select-bordered">
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

                <div class="form-control">
                  <label class="label"><span class="label-text">Status</span></label>
                  <select name="product[status]" class="select select-bordered">
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

                <div class="form-control">
                  <label class="label"><span class="label-text">Vendor</span></label>
                  <input
                    type="text"
                    name="product[vendor]"
                    value={Ecto.Changeset.get_field(@changeset, :vendor)}
                    class="input input-bordered"
                    placeholder="Brand or manufacturer"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Pricing --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Pricing</h2>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Price *</span></label>
                  <input
                    type="number"
                    name="product[price]"
                    value={Ecto.Changeset.get_field(@changeset, :price)}
                    class={["input input-bordered", @changeset.errors[:price] && "input-error"]}
                    step="0.01"
                    min="0"
                    required
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Compare at price</span></label>
                  <input
                    type="number"
                    name="product[compare_at_price]"
                    value={Ecto.Changeset.get_field(@changeset, :compare_at_price)}
                    class="input input-bordered"
                    step="0.01"
                    min="0"
                    placeholder="Original price"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Cost per item</span></label>
                  <input
                    type="number"
                    name="product[cost_per_item]"
                    value={Ecto.Changeset.get_field(@changeset, :cost_per_item)}
                    class="input input-bordered"
                    step="0.01"
                    min="0"
                    placeholder="Your cost"
                  />
                </div>
              </div>

              <div class="form-control mt-4">
                <label class="label cursor-pointer justify-start gap-3">
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
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
