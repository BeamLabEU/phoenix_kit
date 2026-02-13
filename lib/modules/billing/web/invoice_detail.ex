defmodule PhoenixKit.Modules.Billing.Web.InvoiceDetail do
  @moduledoc """
  Invoice detail LiveView for the billing module.

  Displays complete invoice information and provides actions for invoice management.
  Complex business logic is delegated to `Actions`, and template helpers live in `Helpers`.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Invoice
  alias PhoenixKit.Modules.Billing.Providers
  alias PhoenixKit.Modules.Billing.Web.InvoiceDetail.Actions
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  import PhoenixKit.Modules.Billing.Web.InvoiceDetail.Helpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_invoice(id, preload: [:user, :order, :transactions]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Invoice not found")
           |> push_navigate(to: Routes.path("/admin/billing/invoices"))}

        invoice ->
          project_title = Settings.get_project_title()
          transactions = Billing.list_invoice_transactions(invoice.id)

          available_providers = Providers.list_available_providers()

          socket =
            socket
            |> assign(:page_title, "Invoice #{invoice.invoice_number}")
            |> assign(:project_title, project_title)
            |> assign(:url_path, Routes.path("/admin/billing/invoices/#{invoice.uuid}"))
            |> assign(:invoice, invoice)
            |> assign(:transactions, transactions)
            |> assign(:available_providers, available_providers)
            |> assign(:checkout_loading, nil)
            |> assign(:show_payment_modal, false)
            |> assign(:show_refund_modal, false)
            |> assign(:show_send_modal, false)
            |> assign(:show_send_receipt_modal, false)
            |> assign(:show_send_credit_note_modal, false)
            |> assign(:show_send_payment_confirmation_modal, false)
            |> assign(:payment_amount, Invoice.remaining_amount(invoice) |> Decimal.to_string())
            |> assign(:refund_amount, "")
            |> assign(:payment_description, "")
            |> assign(:refund_description, "")
            |> assign(:available_payment_methods, Billing.available_payment_methods())
            |> assign(:selected_payment_method, "bank")
            |> assign(:selected_refund_payment_method, "bank")
            |> assign(:send_email, get_default_email(invoice))
            |> assign(:send_receipt_email, get_default_email(invoice))
            |> assign(:send_credit_note_email, get_default_email(invoice))
            |> assign(:send_credit_note_transaction_id, nil)
            |> assign(:send_payment_confirmation_email, get_default_email(invoice))
            |> assign(:send_payment_confirmation_transaction_id, nil)

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

  # Modal Controls

  @impl true
  def handle_event("open_payment_modal", _params, socket) do
    remaining = Invoice.remaining_amount(socket.assigns.invoice)

    {:noreply,
     socket
     |> assign(:show_payment_modal, true)
     |> assign(:payment_amount, Decimal.to_string(remaining))
     |> assign(:payment_description, "")}
  end

  @impl true
  def handle_event("close_payment_modal", _params, socket) do
    {:noreply, assign(socket, :show_payment_modal, false)}
  end

  @impl true
  def handle_event("open_refund_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_refund_modal, true)
     |> assign(:refund_amount, "")
     |> assign(:refund_description, "")}
  end

  @impl true
  def handle_event("close_refund_modal", _params, socket) do
    {:noreply, assign(socket, :show_refund_modal, false)}
  end

  @impl true
  def handle_event("open_send_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_modal, true)
     |> assign(:send_email, get_default_email(socket.assigns.invoice))}
  end

  @impl true
  def handle_event("close_send_modal", _params, socket) do
    {:noreply, assign(socket, :show_send_modal, false)}
  end

  @impl true
  def handle_event("open_send_receipt_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_receipt_modal, true)
     |> assign(:send_receipt_email, get_default_email(socket.assigns.invoice))}
  end

  @impl true
  def handle_event("close_send_receipt_modal", _params, socket) do
    {:noreply, assign(socket, :show_send_receipt_modal, false)}
  end

  @impl true
  def handle_event("open_send_credit_note_modal", %{"transaction-id" => transaction_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_send_credit_note_modal, true)
     |> assign(:send_credit_note_email, get_default_email(socket.assigns.invoice))
     |> assign(:send_credit_note_transaction_id, transaction_id)}
  end

  @impl true
  def handle_event("close_send_credit_note_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_credit_note_modal, false)
     |> assign(:send_credit_note_transaction_id, nil)}
  end

  @impl true
  def handle_event(
        "open_send_payment_confirmation_modal",
        %{"transaction-id" => transaction_id},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:show_send_payment_confirmation_modal, true)
     |> assign(:send_payment_confirmation_email, get_default_email(socket.assigns.invoice))
     |> assign(:send_payment_confirmation_transaction_id, transaction_id)}
  end

  @impl true
  def handle_event("close_send_payment_confirmation_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_payment_confirmation_modal, false)
     |> assign(:send_payment_confirmation_transaction_id, nil)}
  end

  # Form Updates

  @impl true
  def handle_event("update_payment_form", params, socket) do
    socket =
      socket
      |> assign(:payment_amount, params["amount"] || socket.assigns.payment_amount)
      |> assign(:payment_description, params["description"] || socket.assigns.payment_description)

    socket =
      if params["payment_method"] do
        assign(socket, :selected_payment_method, params["payment_method"])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_refund_form", params, socket) do
    socket =
      socket
      |> assign(:refund_amount, params["amount"] || socket.assigns.refund_amount)
      |> assign(:refund_description, params["description"] || socket.assigns.refund_description)

    socket =
      if params["payment_method"] do
        assign(socket, :selected_refund_payment_method, params["payment_method"])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_send_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_email, email)}
  end

  @impl true
  def handle_event("update_send_receipt_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_receipt_email, email)}
  end

  @impl true
  def handle_event("update_send_credit_note_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_credit_note_email, email)}
  end

  @impl true
  def handle_event("update_send_payment_confirmation_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_payment_confirmation_email, email)}
  end

  # Action Delegators

  @impl true
  def handle_event("record_payment", _params, socket), do: Actions.record_payment(socket)

  @impl true
  def handle_event("pay_with_provider", %{"provider" => provider}, socket),
    do: Actions.pay_with_provider(socket, provider)

  @impl true
  def handle_event("record_refund", _params, socket), do: Actions.record_refund(socket)

  @impl true
  def handle_event("send_invoice", _params, socket), do: Actions.send_invoice(socket)

  @impl true
  def handle_event("send_receipt", _params, socket), do: Actions.send_receipt(socket)

  @impl true
  def handle_event("send_credit_note", _params, socket), do: Actions.send_credit_note(socket)

  @impl true
  def handle_event("send_payment_confirmation", _params, socket),
    do: Actions.send_payment_confirmation(socket)

  @impl true
  def handle_event("void_invoice", _params, socket), do: Actions.void_invoice(socket)

  @impl true
  def handle_event("generate_receipt", _params, socket), do: Actions.generate_receipt(socket)
end
