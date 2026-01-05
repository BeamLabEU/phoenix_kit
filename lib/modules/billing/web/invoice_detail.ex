defmodule PhoenixKit.Modules.Billing.Web.InvoiceDetail do
  @moduledoc """
  Invoice detail LiveView for the billing module.

  Displays complete invoice information and provides actions for invoice management.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Invoice
  alias PhoenixKit.Modules.Billing.Providers
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

          available_providers = Providers.list_available_providers()

          socket =
            socket
            |> assign(:page_title, "Invoice #{invoice.invoice_number}")
            |> assign(:project_title, project_title)
            |> assign(:url_path, Routes.path("/admin/billing/invoices/#{invoice.id}"))
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

  # Actions
  @impl true
  def handle_event("record_payment", _params, socket) do
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
  def handle_event("pay_with_provider", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)
    invoice = socket.assigns.invoice

    # Build success/cancel URLs
    success_url = Routes.url("/admin/billing/invoices/#{invoice.id}?payment=success")
    cancel_url = Routes.url("/admin/billing/invoices/#{invoice.id}?payment=cancelled")

    opts = [
      success_url: success_url,
      cancel_url: cancel_url,
      currency: invoice.currency,
      metadata: %{
        invoice_id: invoice.id,
        invoice_number: invoice.invoice_number
      }
    ]

    socket = assign(socket, :checkout_loading, provider)

    case Billing.create_checkout_session(invoice, provider, opts) do
      {:ok, %{url: checkout_url}} ->
        {:noreply, redirect(socket, external: checkout_url)}

      {:error, :provider_not_available} ->
        {:noreply,
         socket
         |> assign(:checkout_loading, nil)
         |> put_flash(:error, "Payment provider #{provider} is not available")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:checkout_loading, nil)
         |> put_flash(:error, "Failed to create checkout session: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("record_refund", _params, socket) do
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

  # Receipt Email Modal Controls
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
  def handle_event("update_send_receipt_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_receipt_email, email)}
  end

  @impl true
  def handle_event("send_receipt", _params, socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_receipt_email
    receipt_url = Routes.url("/admin/billing/invoices/#{invoice.id}/receipt")

    case Billing.send_receipt(invoice, receipt_url: receipt_url, to_email: email) do
      {:ok, updated_invoice} ->
        {:noreply,
         socket
         |> assign(:invoice, updated_invoice)
         |> assign(:show_send_receipt_modal, false)
         |> put_flash(:info, "Receipt sent to #{email}")}

      {:error, :invoice_not_paid} ->
        {:noreply, put_flash(socket, :error, "Invoice must be paid before sending receipt")}

      {:error, :receipt_not_generated} ->
        {:noreply, put_flash(socket, :error, "Receipt has not been generated yet")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send receipt: #{inspect(reason)}")}
    end
  end

  # Credit Note Email Modal Controls
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
  def handle_event("update_send_credit_note_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_credit_note_email, email)}
  end

  @impl true
  def handle_event("send_credit_note", _params, socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_credit_note_email
    transaction_id_str = socket.assigns.send_credit_note_transaction_id
    transaction_id = parse_transaction_id(transaction_id_str)
    transaction = Enum.find(socket.assigns.transactions, &(&1.id == transaction_id))

    credit_note_url =
      Routes.url("/admin/billing/invoices/#{invoice.id}/credit-note/#{transaction_id}")

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
       |> assign(:transactions, updated_transactions)
       |> assign(:show_send_credit_note_modal, false)
       |> assign(:send_credit_note_transaction_id, nil)
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

  # Payment Confirmation Email Modal Controls
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

  @impl true
  def handle_event("update_send_payment_confirmation_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_payment_confirmation_email, email)}
  end

  @impl true
  def handle_event("send_payment_confirmation", _params, socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_payment_confirmation_email
    transaction_id_str = socket.assigns.send_payment_confirmation_transaction_id
    transaction_id = parse_transaction_id(transaction_id_str)
    transaction = Enum.find(socket.assigns.transactions, &(&1.id == transaction_id))

    payment_url =
      Routes.url("/admin/billing/invoices/#{invoice.id}/payment/#{transaction_id}")

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
       |> assign(:transactions, updated_transactions)
       |> assign(:show_send_payment_confirmation_modal, false)
       |> assign(:send_payment_confirmation_transaction_id, nil)
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
  Gets receipt send history from invoice receipt_data.
  """
  def get_receipt_send_history(invoice) do
    case invoice.receipt_data do
      %{"send_history" => history} when is_list(history) -> history
      _ -> []
    end
  end

  @doc """
  Gets credit note send history from transaction metadata.
  """
  def get_credit_note_send_history(transaction) do
    case transaction.metadata do
      %{"credit_note_send_history" => history} when is_list(history) -> history
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

  @doc """
  Builds a sorted timeline of all invoice events.
  Returns a list of maps with :type, :datetime, and :data keys, sorted by datetime.
  """
  def build_timeline_events(invoice, transactions) do
    events = []

    # 1. Created event
    events = [%{type: :created, datetime: invoice.inserted_at, data: nil} | events]

    # 2. Invoice sent events
    invoice_sends =
      get_send_history(invoice)
      |> Enum.map(fn entry ->
        %{
          type: :invoice_sent,
          datetime: parse_datetime(entry["sent_at"]),
          data: entry
        }
      end)

    events = events ++ invoice_sends

    # Fallback for old invoices without send_history
    events =
      if invoice.sent_at && Enum.empty?(get_send_history(invoice)) do
        [%{type: :invoice_sent_legacy, datetime: invoice.sent_at, data: nil} | events]
      else
        events
      end

    # 3. Payment transactions (positive amounts)
    payment_events =
      transactions
      |> Enum.filter(&Decimal.positive?(&1.amount))
      |> Enum.map(fn txn ->
        %{type: :payment, datetime: txn.inserted_at, data: txn}
      end)

    events = events ++ payment_events

    # 4. Paid event (when fully paid)
    events =
      if invoice.paid_at do
        [%{type: :paid, datetime: invoice.paid_at, data: nil} | events]
      else
        events
      end

    # 5. Receipt generated
    events =
      if invoice.receipt_number do
        [
          %{
            type: :receipt_generated,
            datetime: invoice.receipt_generated_at,
            data: invoice.receipt_number
          }
          | events
        ]
      else
        events
      end

    # 6. Receipt sent events
    receipt_sends =
      get_receipt_send_history(invoice)
      |> Enum.map(fn entry ->
        %{
          type: :receipt_sent,
          datetime: parse_datetime(entry["sent_at"]),
          data: entry
        }
      end)

    events = events ++ receipt_sends

    # 7. Refund transactions and their credit note sends
    refund_events =
      transactions
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.flat_map(fn txn ->
        # Refund event itself
        refund_event = %{type: :refund, datetime: txn.inserted_at, data: txn}

        # Credit note send events for this refund
        credit_note_sends =
          get_credit_note_send_history(txn)
          |> Enum.map(fn entry ->
            %{
              type: :credit_note_sent,
              datetime: parse_datetime(entry["sent_at"]),
              data: Map.put(entry, "transaction", txn)
            }
          end)

        [refund_event | credit_note_sends]
      end)

    events = events ++ refund_events

    # 8. Voided event
    events =
      if invoice.voided_at do
        [%{type: :voided, datetime: invoice.voided_at, data: nil} | events]
      else
        events
      end

    # Sort by datetime (nil datetimes go to the end)
    events
    |> Enum.sort_by(
      fn event ->
        case event.datetime do
          nil -> {1, 0}
          dt -> {0, DateTime.to_unix(dt, :microsecond)}
        end
      end,
      :asc
    )
  end

  @doc """
  Checks if invoice is fully refunded.
  """
  def fully_refunded?(invoice, transactions) do
    total_refunded =
      transactions
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      |> Decimal.abs()

    Decimal.gt?(total_refunded, Decimal.new(0)) &&
      Decimal.gte?(total_refunded, invoice.total)
  end

  defp parse_transaction_id(id_str) do
    case Integer.parse(id_str || "") do
      {id, _} -> id
      :error -> nil
    end
  end

  defp update_transaction_in_list(transactions, updated_transaction) do
    Enum.map(transactions, fn t ->
      if t.id == updated_transaction.id, do: updated_transaction, else: t
    end)
  end

  @doc """
  Formats payment method name for display.
  """
  def format_payment_method_name("bank"), do: "Bank Transfer"
  def format_payment_method_name("stripe"), do: "Stripe"
  def format_payment_method_name("paypal"), do: "PayPal"
  def format_payment_method_name("razorpay"), do: "Razorpay"
  def format_payment_method_name(other) when is_binary(other), do: String.capitalize(other)
  def format_payment_method_name(_), do: "Unknown"
end
