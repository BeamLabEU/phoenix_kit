defmodule PhoenixKit.Modules.Billing.Web.InvoiceDetail.Actions do
  @moduledoc """
  Action handlers for the invoice detail LiveView.

  Contains business logic for payment recording, refunds,
  sending documents, voiding, and receipt generation.
  Each function takes a socket and returns `{:noreply, socket}`.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Utils.Routes

  def record_payment(socket) do
    %{
      invoice: invoice,
      payment_amount: amount,
      payment_description: desc,
      selected_payment_method: payment_method
    } = socket.assigns

    current_scope = socket.assigns[:phoenix_kit_current_scope]

    attrs = %{
      amount: amount,
      payment_method: payment_method,
      description: if(desc == "", do: nil, else: desc)
    }

    case Billing.record_payment(invoice, attrs, current_scope) do
      {:ok, _transaction} ->
        socket = reload_invoice(socket)

        {:noreply,
         socket
         |> Phoenix.Component.assign(:show_payment_modal, false)
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

  def pay_with_provider(socket, provider_str) do
    provider = String.to_existing_atom(provider_str)
    invoice = socket.assigns.invoice

    success_url = Routes.url("/admin/billing/invoices/#{invoice.uuid}?payment=success")
    cancel_url = Routes.url("/admin/billing/invoices/#{invoice.uuid}?payment=cancelled")

    opts = [
      success_url: success_url,
      cancel_url: cancel_url,
      currency: invoice.currency,
      metadata: %{
        invoice_id: invoice.id,
        invoice_number: invoice.invoice_number
      }
    ]

    socket = Phoenix.Component.assign(socket, :checkout_loading, provider)

    case Billing.create_checkout_session(invoice, provider, opts) do
      {:ok, %{url: checkout_url}} ->
        {:noreply, redirect(socket, external: checkout_url)}

      {:error, :provider_not_available} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:checkout_loading, nil)
         |> put_flash(:error, "Payment provider #{provider} is not available")}

      {:error, reason} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:checkout_loading, nil)
         |> put_flash(:error, "Failed to create checkout session: #{inspect(reason)}")}
    end
  end

  def record_refund(socket) do
    %{
      invoice: invoice,
      refund_amount: amount,
      refund_description: desc,
      selected_refund_payment_method: payment_method
    } = socket.assigns

    current_scope = socket.assigns[:phoenix_kit_current_scope]

    if desc == "" do
      {:noreply, put_flash(socket, :error, "Refund reason is required")}
    else
      attrs = %{
        amount: amount,
        payment_method: payment_method,
        description: desc
      }

      case Billing.record_refund(invoice, attrs, current_scope) do
        {:ok, _transaction} ->
          socket = reload_invoice(socket)

          {:noreply,
           socket
           |> Phoenix.Component.assign(:show_refund_modal, false)
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

  def send_invoice(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_email
    invoice_url = Routes.url("/admin/billing/invoices/#{invoice.uuid}/print")

    case Billing.send_invoice(invoice, invoice_url: invoice_url, to_email: email) do
      {:ok, updated_invoice} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, updated_invoice)
         |> Phoenix.Component.assign(:show_send_modal, false)
         |> put_flash(:info, "Invoice sent to #{email}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send invoice: #{reason}")}
    end
  end

  def send_receipt(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_receipt_email
    receipt_url = Routes.url("/admin/billing/invoices/#{invoice.uuid}/receipt")

    case Billing.send_receipt(invoice, receipt_url: receipt_url, to_email: email) do
      {:ok, updated_invoice} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, updated_invoice)
         |> Phoenix.Component.assign(:show_send_receipt_modal, false)
         |> put_flash(:info, "Receipt sent to #{email}")}

      {:error, :invoice_not_paid} ->
        {:noreply, put_flash(socket, :error, "Invoice must be paid before sending receipt")}

      {:error, :receipt_not_generated} ->
        {:noreply, put_flash(socket, :error, "Receipt has not been generated yet")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send receipt: #{inspect(reason)}")}
    end
  end

  def send_credit_note(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_credit_note_email
    transaction_id_str = socket.assigns.send_credit_note_transaction_id
    transaction = Enum.find(socket.assigns.transactions, &(&1.uuid == transaction_id_str))

    credit_note_url =
      Routes.url("/admin/billing/invoices/#{invoice.uuid}/credit-note/#{transaction_id_str}")

    with %{} <- transaction,
         {:ok, updated_transaction} <-
           Billing.send_credit_note(invoice, transaction,
             credit_note_url: credit_note_url,
             to_email: email
           ) do
      updated_transactions =
        update_transaction_in_list(socket.assigns.transactions, updated_transaction)

      {:noreply,
       socket
       |> Phoenix.Component.assign(:transactions, updated_transactions)
       |> Phoenix.Component.assign(:show_send_credit_note_modal, false)
       |> Phoenix.Component.assign(:send_credit_note_transaction_id, nil)
       |> put_flash(:info, "Credit note sent to #{email}")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Transaction not found")}

      {:error, :not_a_refund} ->
        {:noreply, put_flash(socket, :error, "Transaction is not a refund")}

      {:error, :no_recipient_email} ->
        {:noreply, put_flash(socket, :error, "No recipient email address")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send credit note: #{inspect(reason)}")}
    end
  end

  def send_payment_confirmation(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_payment_confirmation_email
    transaction_id_str = socket.assigns.send_payment_confirmation_transaction_id
    transaction = Enum.find(socket.assigns.transactions, &(&1.uuid == transaction_id_str))

    payment_url =
      Routes.url("/admin/billing/invoices/#{invoice.uuid}/payment/#{transaction_id_str}")

    with %{} <- transaction,
         {:ok, updated_transaction} <-
           Billing.send_payment_confirmation(invoice, transaction,
             payment_url: payment_url,
             to_email: email
           ) do
      updated_transactions =
        update_transaction_in_list(socket.assigns.transactions, updated_transaction)

      {:noreply,
       socket
       |> Phoenix.Component.assign(:transactions, updated_transactions)
       |> Phoenix.Component.assign(:show_send_payment_confirmation_modal, false)
       |> Phoenix.Component.assign(:send_payment_confirmation_transaction_id, nil)
       |> put_flash(:info, "Payment confirmation sent to #{email}")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Transaction not found")}

      {:error, :not_a_payment} ->
        {:noreply, put_flash(socket, :error, "Transaction is not a payment")}

      {:error, :no_recipient_email} ->
        {:noreply, put_flash(socket, :error, "No recipient email address")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to send payment confirmation: #{inspect(reason)}")}
    end
  end

  def void_invoice(socket) do
    case Billing.void_invoice(socket.assigns.invoice) do
      {:ok, invoice} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, invoice)
         |> put_flash(:info, "Invoice voided")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to void invoice: #{reason}")}
    end
  end

  def generate_receipt(socket) do
    case Billing.generate_receipt(socket.assigns.invoice) do
      {:ok, invoice} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, invoice)
         |> put_flash(:info, "Receipt generated: #{invoice.receipt_number}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate receipt: #{reason}")}
    end
  end

  # Private helpers

  defp reload_invoice(socket) do
    invoice = socket.assigns.invoice
    updated_invoice = Billing.get_invoice(invoice.id, preload: [:user, :order, :transactions])
    transactions = Billing.list_invoice_transactions(invoice.id)

    socket
    |> Phoenix.Component.assign(:invoice, updated_invoice)
    |> Phoenix.Component.assign(:transactions, transactions)
  end

  defp update_transaction_in_list(transactions, updated_transaction) do
    Enum.map(transactions, fn t ->
      if t.uuid == updated_transaction.uuid, do: updated_transaction, else: t
    end)
  end
end
