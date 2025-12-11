defmodule PhoenixKitWeb.Live.Modules.Billing.InvoiceDetail do
  @moduledoc """
  Invoice detail LiveView for the billing module.

  Displays complete invoice information and provides actions for invoice management.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Billing.Invoice
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

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
          project_title = Settings.get_setting("project_title", "PhoenixKit")
          transactions = Billing.list_invoice_transactions(invoice.id)

          socket =
            socket
            |> assign(:page_title, "Invoice #{invoice.invoice_number}")
            |> assign(:project_title, project_title)
            |> assign(:invoice, invoice)
            |> assign(:transactions, transactions)
            |> assign(:show_payment_modal, false)
            |> assign(:show_refund_modal, false)
            |> assign(:show_send_modal, false)
            |> assign(:payment_amount, Invoice.remaining_amount(invoice) |> Decimal.to_string())
            |> assign(:refund_amount, "")
            |> assign(:payment_description, "")
            |> assign(:refund_description, "")
            |> assign(:send_email, get_default_email(invoice))

          {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  defp get_default_email(invoice) do
    cond do
      invoice.billing_details["email"] -> invoice.billing_details["email"]
      invoice.user -> invoice.user.email
      true -> ""
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

  # Form Updates
  @impl true
  def handle_event("update_payment_form", %{"amount" => amount, "description" => desc}, socket) do
    {:noreply,
     socket
     |> assign(:payment_amount, amount)
     |> assign(:payment_description, desc)}
  end

  @impl true
  def handle_event("update_refund_form", %{"amount" => amount, "description" => desc}, socket) do
    {:noreply,
     socket
     |> assign(:refund_amount, amount)
     |> assign(:refund_description, desc)}
  end

  @impl true
  def handle_event("update_send_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_email, email)}
  end

  # Actions
  @impl true
  def handle_event("record_payment", _params, socket) do
    %{invoice: invoice, payment_amount: amount, payment_description: desc} = socket.assigns
    current_scope = socket.assigns[:phoenix_kit_current_scope]

    attrs = %{
      amount: amount,
      payment_method: "bank",
      description: if(desc == "", do: nil, else: desc)
    }

    case Billing.record_payment(invoice, attrs, current_scope) do
      {:ok, _transaction} ->
        # Reload invoice with transactions
        updated_invoice = Billing.get_invoice(invoice.id, preload: [:user, :order, :transactions])
        transactions = Billing.list_invoice_transactions(invoice.id)

        {:noreply,
         socket
         |> assign(:invoice, updated_invoice)
         |> assign(:transactions, transactions)
         |> assign(:show_payment_modal, false)
         |> put_flash(:info, "Payment recorded successfully")}

      {:error, :not_payable} ->
        {:noreply, put_flash(socket, :error, "Invoice cannot receive payments in current status")}

      {:error, :exceeds_remaining} ->
        {:noreply, put_flash(socket, :error, "Payment amount exceeds remaining balance")}

      {:error, :invalid_amount} ->
        {:noreply, put_flash(socket, :error, "Invalid payment amount")}

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        {:noreply, put_flash(socket, :error, "Failed to record payment")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to record payment: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("record_refund", _params, socket) do
    %{invoice: invoice, refund_amount: amount, refund_description: desc} = socket.assigns
    current_scope = socket.assigns[:phoenix_kit_current_scope]

    if desc == "" do
      {:noreply, put_flash(socket, :error, "Refund reason is required")}
    else
      attrs = %{
        amount: amount,
        payment_method: "bank",
        description: desc
      }

      case Billing.record_refund(invoice, attrs, current_scope) do
        {:ok, _transaction} ->
          updated_invoice =
            Billing.get_invoice(invoice.id, preload: [:user, :order, :transactions])

          transactions = Billing.list_invoice_transactions(invoice.id)

          {:noreply,
           socket
           |> assign(:invoice, updated_invoice)
           |> assign(:transactions, transactions)
           |> assign(:show_refund_modal, false)
           |> put_flash(:info, "Refund recorded successfully")}

        {:error, :not_refundable} ->
          {:noreply, put_flash(socket, :error, "Invoice has no payments to refund")}

        {:error, :exceeds_paid_amount} ->
          {:noreply, put_flash(socket, :error, "Refund amount exceeds paid amount")}

        {:error, :invalid_amount} ->
          {:noreply, put_flash(socket, :error, "Invalid refund amount")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to record refund")}
      end
    end
  end

  @impl true
  def handle_event("send_invoice", _params, socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_email
    invoice_url = Routes.url("/admin/billing/invoices/#{invoice.id}/print")

    case Billing.send_invoice(invoice, invoice_url: invoice_url, to_email: email) do
      {:ok, updated_invoice} ->
        {:noreply,
         socket
         |> assign(:invoice, updated_invoice)
         |> assign(:show_send_modal, false)
         |> put_flash(:info, "Invoice sent to #{email}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send invoice: #{reason}")}
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

  # Helper functions for template

  @doc """
  Gets send history from invoice metadata.
  """
  def get_send_history(invoice) do
    case invoice.metadata do
      %{"send_history" => history} when is_list(history) -> history
      _ -> []
    end
  end

  @doc """
  Parses ISO8601 datetime string to DateTime.
  """
  def parse_datetime(nil), do: nil

  def parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  def parse_datetime(datetime), do: datetime
end
