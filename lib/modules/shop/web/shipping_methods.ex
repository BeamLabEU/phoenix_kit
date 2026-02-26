defmodule PhoenixKit.Modules.Shop.Web.ShippingMethods do
  @moduledoc """
  Shipping methods list LiveView for E-Commerce module admin.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    methods = Shop.list_shipping_methods()
    currency = Shop.get_default_currency()

    socket =
      socket
      |> assign(:page_title, "Shipping Methods")
      |> assign(:methods, methods)
      |> assign(:currency, currency)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_active", %{"uuid" => uuid}, socket) do
    method = Shop.get_shipping_method!(uuid)
    {:ok, updated} = Shop.update_shipping_method(method, %{active: !method.active})

    methods =
      Enum.map(socket.assigns.methods, fn m ->
        if m.uuid == updated.uuid, do: updated, else: m
      end)

    {:noreply, assign(socket, :methods, methods)}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    method = Shop.get_shipping_method!(uuid)

    case Shop.delete_shipping_method(method) do
      {:ok, _} ->
        methods = Enum.reject(socket.assigns.methods, &(&1.uuid == method.uuid))

        {:noreply,
         socket
         |> assign(:methods, methods)
         |> put_flash(:info, "Shipping method deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete shipping method")}
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
      <div class="p-6 max-w-6xl mx-auto">
        <.admin_page_header back={Routes.path("/admin/shop")}>
          <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">
            Shipping Methods
          </h1>
          <p class="text-sm sm:text-base text-base-content/60 mt-0.5">
            {length(@methods)} methods configured
          </p>
          <:actions>
            <.link navigate={Routes.path("/admin/shop/shipping/new")} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Method
            </.link>
          </:actions>
        </.admin_page_header>

        <div class="card bg-base-100 shadow-lg">
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Method</th>
                  <th>Price</th>
                  <th>Constraints</th>
                  <th>Delivery</th>
                  <th>Status</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if @methods == [] do %>
                  <tr>
                    <td colspan="6" class="text-center py-12 text-base-content/50">
                      <.icon name="hero-truck" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                      <p class="text-lg">No shipping methods</p>
                      <p class="text-sm">Create your first shipping method to get started</p>
                    </td>
                  </tr>
                <% else %>
                  <%= for method <- @methods do %>
                    <tr class="hover">
                      <td>
                        <div class="font-bold">{method.name}</div>
                        <%= if method.description do %>
                          <div class="text-sm text-base-content/60 max-w-xs truncate">
                            {method.description}
                          </div>
                        <% end %>
                      </td>
                      <td>
                        <div class="font-semibold">{format_price(method.price, @currency)}</div>
                        <%= if method.free_above_amount do %>
                          <div class="text-xs text-success">
                            Free above {format_price(method.free_above_amount, @currency)}
                          </div>
                        <% end %>
                      </td>
                      <td>
                        <div class="flex flex-wrap gap-1">
                          <%= if method.max_weight_grams do %>
                            <span class="badge badge-outline badge-sm">
                              Max {format_weight(method.max_weight_grams)}
                            </span>
                          <% end %>
                          <%= if method.countries != [] do %>
                            <span class="badge badge-outline badge-sm">
                              {length(method.countries)} countries
                            </span>
                          <% end %>
                          <%= if method.countries == [] && is_nil(method.max_weight_grams) do %>
                            <span class="text-base-content/50 text-sm">No limits</span>
                          <% end %>
                        </div>
                      </td>
                      <td>
                        <%= if estimate = PhoenixKit.Modules.Shop.ShippingMethod.delivery_estimate(method) do %>
                          <span class="text-sm">{estimate}</span>
                        <% else %>
                          <span class="text-base-content/50 text-sm">-</span>
                        <% end %>
                      </td>
                      <td>
                        <input
                          type="checkbox"
                          class="toggle toggle-success toggle-sm"
                          checked={method.active}
                          phx-click="toggle_active"
                          phx-value-uuid={method.uuid}
                        />
                      </td>
                      <td class="text-right">
                        <div class="flex justify-end gap-2">
                          <.link
                            navigate={Routes.path("/admin/shop/shipping/#{method.uuid}/edit")}
                            class="btn btn-ghost btn-sm"
                          >
                            <.icon name="hero-pencil" class="w-4 h-4" />
                          </.link>
                          <button
                            phx-click="delete"
                            phx-value-uuid={method.uuid}
                            data-confirm="Delete this shipping method?"
                            class="btn btn-ghost btn-sm text-error"
                          >
                            <.icon name="hero-trash" class="w-4 h-4" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp format_price(nil, _currency), do: "—"

  defp format_price(amount, %Currency{} = currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount || Decimal.new("0"), 2)}"
  end

  defp format_weight(grams) when grams >= 1000, do: "#{div(grams, 1000)} kg"
  defp format_weight(grams), do: "#{grams} g"
end
