defmodule PhoenixKitWeb.Live.Modules.Billing.OrderForm do
  @moduledoc """
  Order form LiveView for creating and editing orders.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")
      %{users: users} = Auth.list_users_paginated(limit: 100)
      currencies = Billing.list_currencies(enabled: true)
      default_currency = Settings.get_setting("billing_default_currency", "EUR")

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:users, users)
        |> assign(:currencies, currencies)
        |> assign(:default_currency, default_currency)
        |> assign(:billing_profiles, [])
        |> load_order(params["id"])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  defp load_order(socket, nil) do
    # New order
    changeset =
      Billing.change_order(%Billing.Order{
        currency: socket.assigns.default_currency,
        payment_method: "bank",
        line_items: [%{"name" => "", "quantity" => 1, "unit_price" => "0.00", "total" => "0.00"}]
      })

    socket
    |> assign(:page_title, "New Order")
    |> assign(:order, nil)
    |> assign(:form, to_form(changeset))
    |> assign(:line_items, [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}])
    |> assign(:selected_user_id, nil)
  end

  defp load_order(socket, id) do
    case Billing.get_order(id, preload: [:user, :billing_profile]) do
      nil ->
        socket
        |> put_flash(:error, "Order not found")
        |> push_navigate(to: Routes.path("/admin/billing/orders"))

      order ->
        changeset = Billing.change_order(order)
        line_items = parse_line_items(order.line_items)

        billing_profiles =
          if order.user_id, do: Billing.list_user_billing_profiles(order.user_id), else: []

        socket
        |> assign(:page_title, "Edit Order #{order.order_number}")
        |> assign(:order, order)
        |> assign(:form, to_form(changeset))
        |> assign(:line_items, line_items)
        |> assign(:selected_user_id, order.user_id)
        |> assign(:billing_profiles, billing_profiles)
    end
  end

  defp parse_line_items(nil),
    do: [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}]

  defp parse_line_items([]),
    do: [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}]

  defp parse_line_items(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      %{
        id: idx,
        name: item["name"] || "",
        description: item["description"] || "",
        quantity: item["quantity"] || 1,
        unit_price: item["unit_price"] || "0.00"
      }
    end)
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_user", %{"user_id" => user_id}, socket) do
    user_id = if user_id == "", do: nil, else: String.to_integer(user_id)
    billing_profiles = if user_id, do: Billing.list_user_billing_profiles(user_id), else: []

    {:noreply,
     socket
     |> assign(:selected_user_id, user_id)
     |> assign(:billing_profiles, billing_profiles)}
  end

  @impl true
  def handle_event("add_line_item", _params, socket) do
    new_id = length(socket.assigns.line_items)
    new_item = %{id: new_id, name: "", description: "", quantity: 1, unit_price: "0.00"}
    {:noreply, assign(socket, :line_items, socket.assigns.line_items ++ [new_item])}
  end

  @impl true
  def handle_event("remove_line_item", %{"id" => id}, socket) do
    id = String.to_integer(id)
    items = Enum.reject(socket.assigns.line_items, &(&1.id == id))

    items =
      if Enum.empty?(items),
        do: [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}],
        else: items

    {:noreply, assign(socket, :line_items, items)}
  end

  @impl true
  def handle_event("update_line_item", params, socket) do
    id = String.to_integer(params["id"])
    field = String.to_existing_atom(params["field"])
    value = params["value"]

    items =
      Enum.map(socket.assigns.line_items, fn item ->
        if item.id == id do
          Map.put(item, field, value)
        else
          item
        end
      end)

    {:noreply, assign(socket, :line_items, items)}
  end

  @impl true
  def handle_event("save", %{"order" => order_params}, socket) do
    line_items =
      socket.assigns.line_items
      |> Enum.filter(&(&1.name != ""))
      |> Enum.map(fn item ->
        quantity = parse_number(item.quantity, 1)
        unit_price = parse_decimal(item.unit_price)
        total = Decimal.mult(unit_price, quantity)

        %{
          "name" => item.name,
          "description" => item.description,
          "quantity" => quantity,
          "unit_price" => Decimal.to_string(unit_price),
          "total" => Decimal.to_string(total)
        }
      end)

    subtotal =
      Enum.reduce(line_items, Decimal.new(0), fn item, acc ->
        Decimal.add(acc, Decimal.new(item["total"]))
      end)

    order_params =
      order_params
      |> Map.put("line_items", line_items)
      |> Map.put("subtotal", Decimal.to_string(subtotal))
      |> Map.put("total", Decimal.to_string(subtotal))
      |> Map.put("user_id", socket.assigns.selected_user_id)

    save_order(socket, order_params)
  end

  defp save_order(socket, params) do
    result =
      if socket.assigns.order do
        Billing.update_order(socket.assigns.order, params)
      else
        Billing.create_order(params)
      end

    case result do
      {:ok, order} ->
        {:noreply,
         socket
         |> put_flash(:info, "Order saved successfully")
         |> push_navigate(to: Routes.path("/admin/billing/orders/#{order.id}"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp parse_number(value, _default) when is_integer(value), do: value

  defp parse_number(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_number(_, default), do: default

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> Decimal.new(0)
    end
  end

  defp parse_decimal(_), do: Decimal.new(0)
end
