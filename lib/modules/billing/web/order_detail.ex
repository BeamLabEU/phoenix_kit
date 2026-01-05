defmodule PhoenixKit.Modules.Billing.Web.OrderDetail do
  @moduledoc """
  Order detail LiveView for the billing module.

  Displays complete order information and provides actions for order management.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_order(id, preload: [:user, :billing_profile]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Order not found")
           |> push_navigate(to: Routes.path("/admin/billing/orders"))}

        order ->
          project_title = Settings.get_setting("project_title", "PhoenixKit")
          invoices = Billing.list_invoices_for_order(order.id)

          socket =
            socket
            |> assign(:page_title, "Order #{order.order_number}")
            |> assign(:project_title, project_title)
            |> assign(:url_path, Routes.path("/admin/billing/orders/#{order.id}"))
            |> assign(:order, order)
            |> assign(:invoices, invoices)
            |> assign(:show_status_modal, false)
            |> assign(:show_invoice_modal, false)

          {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_order", _params, socket) do
    case Billing.confirm_order(socket.assigns.order) do
      {:ok, order} ->
        {:noreply,
         socket
         |> assign(:order, order)
         |> put_flash(:info, "Order confirmed successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to confirm order: #{reason}")}
    end
  end

  @impl true
  def handle_event("mark_paid", _params, socket) do
    case Billing.mark_order_paid(socket.assigns.order) do
      {:ok, order} ->
        {:noreply,
         socket
         |> assign(:order, order)
         |> put_flash(:info, "Order marked as paid")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to mark as paid: #{reason}")}
    end
  end

  @impl true
  def handle_event("cancel_order", _params, socket) do
    case Billing.cancel_order(socket.assigns.order) do
      {:ok, order} ->
        {:noreply,
         socket
         |> assign(:order, order)
         |> put_flash(:info, "Order cancelled")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel order: #{reason}")}
    end
  end

  @impl true
  def handle_event("generate_invoice", _params, socket) do
    case Billing.create_invoice_from_order(socket.assigns.order) do
      {:ok, invoice} ->
        invoices = Billing.list_invoices_for_order(socket.assigns.order.id)

        {:noreply,
         socket
         |> assign(:invoices, invoices)
         |> put_flash(:info, "Invoice #{invoice.invoice_number} created")}

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)
        {:noreply, put_flash(socket, :error, "Failed to create invoice: #{errors}")}
    end
  end

  @impl true
  def handle_event("view_invoice", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/invoices/#{id}"))}
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
  end
end
