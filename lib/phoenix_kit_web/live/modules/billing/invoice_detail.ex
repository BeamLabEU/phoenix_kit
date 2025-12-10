defmodule PhoenixKitWeb.Live.Modules.Billing.InvoiceDetail do
  @moduledoc """
  Invoice detail LiveView for the billing module.

  Displays complete invoice information and provides actions for invoice management.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_invoice(id, preload: [:user, :order]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Invoice not found")
           |> push_navigate(to: Routes.path("/admin/billing/invoices"))}

        invoice ->
          project_title = Settings.get_setting("project_title", "PhoenixKit")

          socket =
            socket
            |> assign(:page_title, "Invoice #{invoice.invoice_number}")
            |> assign(:project_title, project_title)
            |> assign(:invoice, invoice)

          {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_invoice", _params, socket) do
    invoice = socket.assigns.invoice
    # Generate full URL using Routes.url() which handles site_url from Settings
    invoice_url = Routes.url("/admin/billing/invoices/#{invoice.id}/print")

    case Billing.send_invoice(invoice, invoice_url: invoice_url) do
      {:ok, updated_invoice} ->
        {:noreply,
         socket
         |> assign(:invoice, updated_invoice)
         |> put_flash(:info, "Invoice sent successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send invoice: #{reason}")}
    end
  end

  @impl true
  def handle_event("mark_paid", _params, socket) do
    case Billing.mark_invoice_paid(socket.assigns.invoice) do
      {:ok, invoice} ->
        {:noreply,
         socket
         |> assign(:invoice, invoice)
         |> put_flash(:info, "Invoice marked as paid")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to mark as paid: #{reason}")}
    end
  end

  @impl true
  def handle_event("void_invoice", _params, socket) do
    case Billing.void_invoice(socket.assigns.invoice) do
      {:ok, invoice} ->
        {:noreply,
         socket
         |> assign(:invoice, invoice)
         |> put_flash(:info, "Invoice voided")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to void invoice: #{reason}")}
    end
  end

  @impl true
  def handle_event("generate_receipt", _params, socket) do
    case Billing.generate_receipt(socket.assigns.invoice) do
      {:ok, invoice} ->
        {:noreply,
         socket
         |> assign(:invoice, invoice)
         |> put_flash(:info, "Receipt generated: #{invoice.receipt_number}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate receipt: #{reason}")}
    end
  end
end
