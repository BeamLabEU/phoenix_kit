defmodule PhoenixKit.Modules.Shop.Web.CheckoutComplete do
  @moduledoc """
  Order confirmation page after successful checkout.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Web.Components.ShopLayouts
  alias PhoenixKit.Modules.Shop.Web.Helpers
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    user = get_current_user(socket)

    case Billing.get_order_by_uuid(uuid) do
      nil ->
        {:ok, redirect_with_error(socket, "Order not found")}

      order ->
        handle_order_access(socket, order, user)
    end
  end

  defp get_current_user(socket), do: Helpers.get_current_user(socket)

  defp handle_order_access(socket, order, user) do
    if has_order_access?(order, user) do
      {:ok, setup_order_assigns(socket, order)}
    else
      {:ok, redirect_with_error(socket, "You don't have access to this order")}
    end
  end

  defp has_order_access?(order, user) do
    cond do
      # No user_id on order - legacy guest order
      is_nil(order.user_id) -> true
      # Logged-in user owns the order
      not is_nil(user) and order.user_id == user.id -> true
      # Guest checkout - order belongs to unconfirmed user (allow access to confirmation page)
      guest_user_order?(order) -> true
      true -> false
    end
  end

  # Check if order belongs to an unconfirmed guest user
  defp guest_user_order?(%{user_id: nil}), do: false

  defp guest_user_order?(%{user_id: user_id}) do
    case Auth.get_user(user_id) do
      %{confirmed_at: nil} -> true
      _ -> false
    end
  end

  defp setup_order_assigns(socket, order) do
    currency = Shop.get_default_currency()
    billing_profile = get_billing_profile(order)
    {is_guest_order, order_email} = check_guest_order(order)

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    socket
    |> assign(:page_title, "Order Confirmed")
    |> assign(:order, order)
    |> assign(:currency, currency)
    |> assign(:billing_profile, billing_profile)
    |> assign(:is_guest_order, is_guest_order)
    |> assign(:order_email, order_email)
    |> assign(:authenticated, authenticated)
  end

  defp get_billing_profile(%{billing_profile_id: nil}), do: nil
  defp get_billing_profile(%{billing_profile_id: id}), do: Billing.get_billing_profile(id)

  defp check_guest_order(%{user_id: nil} = order) do
    email = get_in(order.billing_snapshot, ["email"])
    {not is_nil(email), email}
  end

  defp check_guest_order(%{user_id: user_id}) do
    case Auth.get_user(user_id) do
      %{confirmed_at: nil, email: email} -> {true, email}
      _ -> {false, nil}
    end
  end

  defp redirect_with_error(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_navigate(to: Routes.path("/shop"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ShopLayouts.shop_layout {assigns}>
      <div class="p-6 max-w-3xl mx-auto">
        <%!-- Success Header --%>
        <div class="text-center mb-8">
          <div class="w-20 h-20 bg-success/20 rounded-full flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-check-circle" class="w-12 h-12 text-success" />
          </div>
          <h1 class="text-3xl font-bold mb-2">Order Confirmed!</h1>
          <p class="text-base-content/60">
            Thank you for your order. We've received your order and will process it shortly.
          </p>
        </div>

        <%!-- Guest Order Email Confirmation Reminder --%>
        <%= if @is_guest_order do %>
          <div class="card bg-info/10 border border-info mb-6">
            <div class="card-body">
              <div class="flex items-start gap-4">
                <.icon name="hero-envelope" class="w-8 h-8 text-info flex-shrink-0" />
                <div>
                  <h3 class="font-semibold text-lg">Check your inbox</h3>
                  <p class="text-sm mt-1">
                    We've sent a confirmation email to <strong>{@order_email}</strong>.
                  </p>
                  <ol class="text-sm mt-3 space-y-1.5 list-decimal list-inside text-base-content/80">
                    <li>Open the email titled <strong>"Confirm your account"</strong></li>
                    <li>Click the confirmation link inside</li>
                    <li>Your account will be activated and you can track your order</li>
                  </ol>
                  <p class="text-xs text-base-content/50 mt-3">
                    Don't see it? Check your spam or junk folder. The email may take a minute to arrive.
                  </p>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Order Number --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body text-center">
            <div class="text-sm text-base-content/60">Order Number</div>
            <div class="text-2xl font-mono font-bold">{@order.order_number}</div>
            <%= unless @is_guest_order do %>
              <div class="text-sm text-base-content/60 mt-2">
                A confirmation email will be sent to your email address.
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Order Details --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <h2 class="card-title mb-4">Order Details</h2>

            <%!-- Billing Info --%>
            <%= if @billing_profile do %>
              <div class="mb-6">
                <h3 class="font-medium text-sm text-base-content/70 mb-2">Billing Information</h3>
                <div class="text-sm">
                  <div class="font-medium">{profile_display_name(@billing_profile)}</div>
                  <div class="text-base-content/60">{profile_address(@billing_profile)}</div>
                  <%= if @billing_profile.email do %>
                    <div class="text-base-content/60">{@billing_profile.email}</div>
                  <% end %>
                </div>
              </div>
            <% else %>
              <%!-- Guest order - show billing snapshot --%>
              <%= if @order.billing_snapshot && map_size(@order.billing_snapshot) > 0 do %>
                <div class="mb-6">
                  <h3 class="font-medium text-sm text-base-content/70 mb-2">Billing Information</h3>
                  <div class="text-sm">
                    <div class="font-medium">
                      {@order.billing_snapshot["first_name"]} {@order.billing_snapshot["last_name"]}
                    </div>
                    <div class="text-base-content/60">
                      {[
                        @order.billing_snapshot["address_line1"],
                        @order.billing_snapshot["city"],
                        @order.billing_snapshot["postal_code"],
                        @order.billing_snapshot["country"]
                      ]
                      |> Enum.filter(&(&1 && &1 != ""))
                      |> Enum.join(", ")}
                    </div>
                    <%= if @order.billing_snapshot["email"] do %>
                      <div class="text-base-content/60">{@order.billing_snapshot["email"]}</div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>

            <%!-- Items --%>
            <div class="mb-6">
              <h3 class="font-medium text-sm text-base-content/70 mb-2">Items</h3>
              <div class="space-y-3">
                <%= for item <- @order.line_items || [] do %>
                  <div class="flex justify-between items-center text-sm">
                    <div>
                      <span class="font-medium">{item["name"]}</span>
                      <%= if item["type"] != "shipping" do %>
                        <span class="text-base-content/60 ml-2">× {item["quantity"]}</span>
                      <% end %>
                    </div>
                    <div class="font-medium">
                      {format_price_string(item["total"])}
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Totals --%>
            <div class="border-t pt-4 space-y-2">
              <div class="flex justify-between text-sm">
                <span class="text-base-content/70">Subtotal</span>
                <span>{format_price(@order.subtotal, @currency)}</span>
              </div>

              <%= if @order.tax_amount && Decimal.compare(@order.tax_amount, Decimal.new("0")) == :gt do %>
                <div class="flex justify-between text-sm">
                  <span class="text-base-content/70">Tax</span>
                  <span>{format_price(@order.tax_amount, @currency)}</span>
                </div>
              <% end %>

              <%= if @order.discount_amount && Decimal.compare(@order.discount_amount, Decimal.new("0")) == :gt do %>
                <div class="flex justify-between text-sm text-success">
                  <span>Discount</span>
                  <span>-{format_price(@order.discount_amount, @currency)}</span>
                </div>
              <% end %>

              <div class="flex justify-between text-lg font-bold pt-2 border-t">
                <span>Total</span>
                <span>{format_price(@order.total, @currency)}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Status --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-medium">Order Status</h3>
                <p class="text-sm text-base-content/60">Your order is being processed</p>
              </div>
              <div class="badge badge-warning badge-lg capitalize">{@order.status}</div>
            </div>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex justify-center gap-4">
          <.link navigate={Routes.path("/shop")} class="btn btn-primary">
            <.icon name="hero-shopping-bag" class="w-5 h-5 mr-2" /> Continue Shopping
          </.link>
          <%= if @authenticated do %>
            <.link navigate={Routes.path("/dashboard/orders")} class="btn btn-outline">
              <.icon name="hero-clipboard-document-list" class="w-5 h-5 mr-2" /> My Orders
            </.link>
          <% end %>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  # Helpers

  defp profile_display_name(profile), do: Helpers.profile_display_name(profile)
  defp profile_address(profile), do: Helpers.profile_address(profile)
  defp format_price(amount, currency), do: Helpers.format_price(amount, currency)

  defp format_price_string(nil), do: "-"
  defp format_price_string(amount) when is_binary(amount), do: "$#{amount}"
  defp format_price_string(amount), do: "$#{amount}"
end
