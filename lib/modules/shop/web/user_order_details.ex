defmodule PhoenixKit.Modules.Shop.Web.UserOrderDetails do
  @moduledoc """
  LiveView for displaying order details to the order owner.

  Users can view their own orders with full details including:
  - Order items and totals
  - Billing information
  - Order status

  Security:
  - Users can only view their own orders (user_id check)
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    if Billing.enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      case Billing.get_order_by_uuid(uuid) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, gettext("Order not found"))
           |> push_navigate(to: Routes.path("/dashboard/orders"))}

        order ->
          if order.user_id != current_user.id do
            {:ok,
             socket
             |> put_flash(:error, gettext("Access denied"))
             |> push_navigate(to: Routes.path("/dashboard/orders"))}
          else
            {:ok, setup_order_assigns(socket, order, current_user)}
          end
      end
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/dashboard"))}
    end
  end

  defp setup_order_assigns(socket, order, current_user) do
    currency = Shop.get_default_currency()
    billing_profile = get_billing_profile(order)

    socket
    |> assign(:page_title, gettext("Order %{number}", number: order.order_number))
    |> assign(:order, order)
    |> assign(:current_user, current_user)
    |> assign(:currency, currency)
    |> assign(:billing_profile, billing_profile)
  end

  defp get_billing_profile(%{billing_profile_id: nil}), do: nil
  defp get_billing_profile(%{billing_profile_id: id}), do: Billing.get_billing_profile(id)

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  # View helpers

  defp status_badge_class("pending"), do: "badge-warning"
  defp status_badge_class("processing"), do: "badge-info"
  defp status_badge_class("completed"), do: "badge-success"
  defp status_badge_class("shipped"), do: "badge-info"
  defp status_badge_class("delivered"), do: "badge-success"
  defp status_badge_class("cancelled"), do: "badge-error"
  defp status_badge_class("refunded"), do: "badge-neutral"
  defp status_badge_class(_), do: "badge-ghost"

  defp format_date(nil), do: "-"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %H:%M")
  end

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %H:%M")
  end

  defp format_price(nil, _currency), do: "-"

  defp format_price(amount, %Currency{} = currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount, 2)}"
  end

  defp format_price_string(nil), do: "-"
  defp format_price_string(amount) when is_binary(amount), do: "$#{amount}"
  defp format_price_string(amount), do: "$#{amount}"

  defp profile_display_name(%{type: "company"} = profile) do
    profile.company_name || "#{profile.first_name} #{profile.last_name}"
  end

  defp profile_display_name(profile) do
    "#{profile.first_name} #{profile.last_name}"
  end

  defp profile_address(profile) do
    [profile.address_line1, profile.city, profile.postal_code, profile.country]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp items_count(nil), do: 0
  defp items_count([]), do: 0

  defp items_count(items) do
    items
    |> Enum.filter(&(&1["type"] != "shipping"))
    |> length()
  end
end
