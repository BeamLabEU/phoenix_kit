defmodule PhoenixKit.Modules.Shop.Web.ShippingMethodForm do
  @moduledoc """
  Shipping method create/edit form LiveView.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.ShippingMethod
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = apply_action(socket, socket.assigns.live_action, params)
    {:noreply, socket}
  end

  defp apply_action(socket, :new, _params) do
    method = %ShippingMethod{}
    changeset = Shop.change_shipping_method(method)

    socket
    |> assign(:page_title, "New Shipping Method")
    |> assign(:method, method)
    |> assign(:changeset, changeset)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    method = Shop.get_shipping_method!(id)
    changeset = Shop.change_shipping_method(method)

    socket
    |> assign(:page_title, "Edit #{method.name}")
    |> assign(:method, method)
    |> assign(:changeset, changeset)
  end

  @impl true
  def handle_event("validate", %{"shipping_method" => params}, socket) do
    changeset =
      socket.assigns.method
      |> Shop.change_shipping_method(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl true
  def handle_event("save", %{"shipping_method" => params}, socket) do
    save_method(socket, socket.assigns.live_action, params)
  end

  defp save_method(socket, :new, params) do
    case Shop.create_shipping_method(params) do
      {:ok, _method} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shipping method created")
         |> push_navigate(to: Routes.path("/admin/shop/shipping"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_method(socket, :edit, params) do
    case Shop.update_shipping_method(socket.assigns.method, params) do
      {:ok, _method} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shipping method updated")
         |> push_navigate(to: Routes.path("/admin/shop/shipping"))}

      {:error, changeset} ->
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
      <div class="p-6 max-w-3xl mx-auto">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-3xl font-bold">{@page_title}</h1>
          <.link navigate={Routes.path("/admin/shop/shipping")} class="btn btn-ghost">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </.link>
        </div>

        <.form for={@changeset} phx-change="validate" phx-submit="save" class="space-y-6">
          <%!-- Basic Info --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Basic Information</h2>

              <div class="form-control">
                <label class="label"><span class="label-text">Name *</span></label>
                <input
                  type="text"
                  name="shipping_method[name]"
                  value={Ecto.Changeset.get_field(@changeset, :name)}
                  class={["input input-bordered", @changeset.errors[:name] && "input-error"]}
                  placeholder="Standard Shipping"
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
                  name="shipping_method[slug]"
                  value={Ecto.Changeset.get_field(@changeset, :slug)}
                  class="input input-bordered"
                  placeholder="standard-shipping (auto-generated if empty)"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Description</span></label>
                <textarea
                  name="shipping_method[description]"
                  class="textarea textarea-bordered"
                  placeholder="Delivery in 3-5 business days"
                  rows="2"
                >{Ecto.Changeset.get_field(@changeset, :description)}</textarea>
              </div>
            </div>
          </div>

          <%!-- Pricing --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Pricing</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Price *</span></label>
                  <input
                    type="number"
                    name="shipping_method[price]"
                    value={Ecto.Changeset.get_field(@changeset, :price)}
                    class={["input input-bordered", @changeset.errors[:price] && "input-error"]}
                    step="0.01"
                    min="0"
                    required
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Currency</span></label>
                  <select name="shipping_method[currency]" class="select select-bordered">
                    <%= for {name, code} <- currency_options() do %>
                      <option
                        value={code}
                        selected={Ecto.Changeset.get_field(@changeset, :currency) == code}
                      >
                        {name}
                      </option>
                    <% end %>
                  </select>
                </div>

                <div class="form-control md:col-span-2">
                  <label class="label"><span class="label-text">Free shipping above</span></label>
                  <input
                    type="number"
                    name="shipping_method[free_above_amount]"
                    value={Ecto.Changeset.get_field(@changeset, :free_above_amount)}
                    class="input input-bordered"
                    step="0.01"
                    min="0"
                    placeholder="Leave empty for no threshold"
                  />
                  <label class="label">
                    <span class="label-text-alt text-base-content/60">
                      Shipping becomes free when order subtotal reaches this amount
                    </span>
                  </label>
                </div>
              </div>
            </div>
          </div>

          <%!-- Constraints --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Constraints</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Min weight (grams)</span></label>
                  <input
                    type="number"
                    name="shipping_method[min_weight_grams]"
                    value={Ecto.Changeset.get_field(@changeset, :min_weight_grams)}
                    class="input input-bordered"
                    min="0"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Max weight (grams)</span></label>
                  <input
                    type="number"
                    name="shipping_method[max_weight_grams]"
                    value={Ecto.Changeset.get_field(@changeset, :max_weight_grams)}
                    class="input input-bordered"
                    min="0"
                    placeholder="No limit"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Min order amount</span></label>
                  <input
                    type="number"
                    name="shipping_method[min_order_amount]"
                    value={Ecto.Changeset.get_field(@changeset, :min_order_amount)}
                    class="input input-bordered"
                    step="0.01"
                    min="0"
                    placeholder="No minimum"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Max order amount</span></label>
                  <input
                    type="number"
                    name="shipping_method[max_order_amount]"
                    value={Ecto.Changeset.get_field(@changeset, :max_order_amount)}
                    class="input input-bordered"
                    step="0.01"
                    min="0"
                    placeholder="No maximum"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Delivery Estimate --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Delivery Estimate</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Estimated days (min)</span></label>
                  <input
                    type="number"
                    name="shipping_method[estimated_days_min]"
                    value={Ecto.Changeset.get_field(@changeset, :estimated_days_min)}
                    class="input input-bordered"
                    min="0"
                  />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Estimated days (max)</span></label>
                  <input
                    type="number"
                    name="shipping_method[estimated_days_max]"
                    value={Ecto.Changeset.get_field(@changeset, :estimated_days_max)}
                    class="input input-bordered"
                    min="0"
                  />
                </div>

                <div class="form-control md:col-span-2">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input type="hidden" name="shipping_method[tracking_supported]" value="false" />
                    <input
                      type="checkbox"
                      name="shipping_method[tracking_supported]"
                      value="true"
                      checked={Ecto.Changeset.get_field(@changeset, :tracking_supported)}
                      class="checkbox checkbox-primary"
                    />
                    <span class="label-text">Tracking supported</span>
                  </label>
                </div>
              </div>
            </div>
          </div>

          <%!-- Status --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title mb-4">Status</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input type="hidden" name="shipping_method[active]" value="false" />
                    <input
                      type="checkbox"
                      name="shipping_method[active]"
                      value="true"
                      checked={Ecto.Changeset.get_field(@changeset, :active)}
                      class="toggle toggle-success"
                    />
                    <span class="label-text">Active</span>
                  </label>
                  <label class="label">
                    <span class="label-text-alt text-base-content/60">
                      Inactive methods are not shown to customers
                    </span>
                  </label>
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Position</span></label>
                  <input
                    type="number"
                    name="shipping_method[position]"
                    value={Ecto.Changeset.get_field(@changeset, :position) || 0}
                    class="input input-bordered"
                    min="0"
                  />
                  <label class="label">
                    <span class="label-text-alt text-base-content/60">
                      Lower numbers appear first
                    </span>
                  </label>
                </div>
              </div>
            </div>
          </div>

          <%!-- Submit --%>
          <div class="flex justify-end gap-4">
            <.link navigate={Routes.path("/admin/shop/shipping")} class="btn btn-ghost">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-5 h-5 mr-2" />
              {if @live_action == :new, do: "Create Method", else: "Update Method"}
            </button>
          </div>
        </.form>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp currency_options do
    [
      {"USD - US Dollar", "USD"},
      {"EUR - Euro", "EUR"},
      {"GBP - British Pound", "GBP"},
      {"CAD - Canadian Dollar", "CAD"},
      {"AUD - Australian Dollar", "AUD"},
      {"PLN - Polish Zloty", "PLN"},
      {"SEK - Swedish Krona", "SEK"},
      {"NOK - Norwegian Krone", "NOK"},
      {"DKK - Danish Krone", "DKK"},
      {"CHF - Swiss Franc", "CHF"}
    ]
  end
end
