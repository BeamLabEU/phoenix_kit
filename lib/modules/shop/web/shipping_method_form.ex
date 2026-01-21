defmodule PhoenixKit.Modules.Shop.Web.ShippingMethodForm do
  @moduledoc """
  Shipping method create/edit form LiveView.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
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
    default_currency = Billing.get_default_currency()
    default_currency_code = if default_currency, do: default_currency.code, else: "USD"

    method = %ShippingMethod{currency: default_currency_code}
    changeset = Shop.change_shipping_method(method)
    currencies = load_currencies()

    socket
    |> assign(:page_title, "New Shipping Method")
    |> assign(:method, method)
    |> assign(:changeset, changeset)
    |> assign(:currencies, currencies)
    |> assign(:default_currency, default_currency)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    method = Shop.get_shipping_method!(id)
    changeset = Shop.change_shipping_method(method)
    currencies = load_currencies()
    default_currency = Billing.get_default_currency()

    socket
    |> assign(:page_title, "Edit #{method.name}")
    |> assign(:method, method)
    |> assign(:changeset, changeset)
    |> assign(:currencies, currencies)
    |> assign(:default_currency, default_currency)
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
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/admin/shop/shipping")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">{@page_title}</h1>
              <p class="text-base-content/70 mt-1">Configure shipping method details</p>
            </div>
          </div>
        </header>

        <.form for={@changeset} phx-change="validate" phx-submit="save" class="space-y-6">
          <%!-- Basic Info --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Basic Information</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Name *</span>
                  </label>
                  <input
                    type="text"
                    name="shipping_method[name]"
                    value={Ecto.Changeset.get_field(@changeset, :name)}
                    class={[
                      "input input-bordered w-full focus:input-primary",
                      @changeset.errors[:name] && "input-error"
                    ]}
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

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Slug</span>
                  </label>
                  <input
                    type="text"
                    name="shipping_method[slug]"
                    value={Ecto.Changeset.get_field(@changeset, :slug)}
                    class="input input-bordered w-full focus:input-primary"
                    placeholder="auto-generated if empty"
                  />
                </div>

                <div class="form-control w-full md:col-span-2">
                  <label class="label">
                    <span class="label-text font-medium">Description</span>
                  </label>
                  <textarea
                    name="shipping_method[description]"
                    class="textarea textarea-bordered w-full focus:textarea-primary"
                    placeholder="Delivery in 3-5 business days"
                    rows="2"
                  >{Ecto.Changeset.get_field(@changeset, :description)}</textarea>
                </div>
              </div>
            </div>
          </div>

          <%!-- Pricing --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Pricing</h2>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Price *</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[price]"
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
                    <span class="label-text font-medium">Currency</span>
                  </label>
                  <%= if @currencies == [] do %>
                    <div class="input input-bordered flex items-center bg-base-200">
                      {if @default_currency,
                        do: "#{@default_currency.code} - #{@default_currency.name}",
                        else: "USD"}
                    </div>
                    <input
                      type="hidden"
                      name="shipping_method[currency]"
                      value={if @default_currency, do: @default_currency.code, else: "USD"}
                    />
                  <% else %>
                    <select
                      name="shipping_method[currency]"
                      class="select select-bordered w-full focus:select-primary"
                    >
                      <%= for currency <- @currencies do %>
                        <option
                          value={currency.code}
                          selected={Ecto.Changeset.get_field(@changeset, :currency) == currency.code}
                        >
                          {currency.code} - {currency.name}
                        </option>
                      <% end %>
                    </select>
                  <% end %>
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Free above</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[free_above_amount]"
                    value={Ecto.Changeset.get_field(@changeset, :free_above_amount)}
                    class="input input-bordered w-full focus:input-primary"
                    step="0.01"
                    min="0"
                    placeholder="No threshold"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Constraints --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Constraints</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Min weight (g)</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[min_weight_grams]"
                    value={Ecto.Changeset.get_field(@changeset, :min_weight_grams)}
                    class="input input-bordered w-full focus:input-primary"
                    min="0"
                    placeholder="0"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Max weight (g)</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[max_weight_grams]"
                    value={Ecto.Changeset.get_field(@changeset, :max_weight_grams)}
                    class="input input-bordered w-full focus:input-primary"
                    min="0"
                    placeholder="No limit"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Min order</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[min_order_amount]"
                    value={Ecto.Changeset.get_field(@changeset, :min_order_amount)}
                    class="input input-bordered w-full focus:input-primary"
                    step="0.01"
                    min="0"
                    placeholder="No min"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Max order</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[max_order_amount]"
                    value={Ecto.Changeset.get_field(@changeset, :max_order_amount)}
                    class="input input-bordered w-full focus:input-primary"
                    step="0.01"
                    min="0"
                    placeholder="No max"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Delivery & Status --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Delivery & Status</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Est. days (min)</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[estimated_days_min]"
                    value={Ecto.Changeset.get_field(@changeset, :estimated_days_min)}
                    class="input input-bordered w-full focus:input-primary"
                    min="0"
                    placeholder="1"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Est. days (max)</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[estimated_days_max]"
                    value={Ecto.Changeset.get_field(@changeset, :estimated_days_max)}
                    class="input input-bordered w-full focus:input-primary"
                    min="0"
                    placeholder="5"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Position</span>
                  </label>
                  <input
                    type="number"
                    name="shipping_method[position]"
                    value={Ecto.Changeset.get_field(@changeset, :position) || 0}
                    class="input input-bordered w-full focus:input-primary"
                    min="0"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Status</span>
                  </label>
                  <label class="label cursor-pointer justify-start gap-3 h-12">
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
                </div>
              </div>

              <div class="divider my-2"></div>

              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input type="hidden" name="shipping_method[tracking_supported]" value="false" />
                  <input
                    type="checkbox"
                    name="shipping_method[tracking_supported]"
                    value="true"
                    checked={Ecto.Changeset.get_field(@changeset, :tracking_supported)}
                    class="checkbox checkbox-primary"
                  />
                  <span class="label-text font-medium">Tracking supported</span>
                </label>
              </div>
            </div>
          </div>

          <%!-- Submit --%>
          <div class="flex justify-end gap-4">
            <.link navigate={Routes.path("/admin/shop/shipping")} class="btn btn-outline">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-4 h-4 mr-2" />
              {if @live_action == :new, do: "Create Method", else: "Update Method"}
            </button>
          </div>
        </.form>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp load_currencies do
    Billing.list_currencies(enabled: true)
  rescue
    _ -> []
  end
end
