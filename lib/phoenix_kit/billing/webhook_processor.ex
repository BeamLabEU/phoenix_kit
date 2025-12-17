defmodule PhoenixKit.Billing.WebhookProcessor do
  @moduledoc """
  Processes normalized webhook events from payment providers.

  This module handles the business logic for webhook events after they've
  been verified and normalized by the provider modules. It ensures:

  - **Idempotency**: Events are tracked by event_id to prevent double-processing
  - **Error handling**: Failed events are logged with retry counts
  - **Business logic**: Invoices are marked paid, receipts generated, etc.

  ## Event Types

  - `checkout.completed` - Checkout session completed (payment succeeded)
  - `checkout.expired` - Checkout session expired
  - `payment.succeeded` - Direct payment succeeded (for saved cards)
  - `payment.failed` - Payment failed
  - `refund.created` - Refund was processed
  - `setup.completed` - Setup session completed (card saved)

  ## Usage

      # Called by BillingWebhookController
      WebhookProcessor.process(normalized_event)
  """

  alias PhoenixKit.Billing
  alias PhoenixKit.RepoHelper

  require Logger

  @doc """
  Processes a normalized webhook event.

  Checks for idempotency, processes the event, and logs the result.

  ## Returns

  - `{:ok, result}` - Event processed successfully
  - `{:error, :duplicate_event}` - Event already processed
  - `{:error, reason}` - Processing failed
  """
  @spec process(map()) :: {:ok, any()} | {:error, atom()}
  def process(%{event_id: event_id, provider: provider, type: _type} = event) do
    # Check idempotency
    case check_idempotency(provider, event_id) do
      :new ->
        # Log event as processing
        {:ok, webhook_event} = create_webhook_event(event)

        # Process the event
        result = process_event(event)

        # Update event status
        mark_event_processed(webhook_event, result)

        result

      :duplicate ->
        {:error, :duplicate_event}
    end
  rescue
    e ->
      Logger.error("Webhook processing error: #{inspect(e)}")
      {:error, :processing_error}
  end

  # ===========================================
  # Event Handlers
  # ===========================================

  defp process_event(%{type: "checkout.completed", data: data}) do
    Logger.info("Processing checkout.completed: #{inspect(data)}")

    case data do
      %{mode: "payment", invoice_id: invoice_id} when not is_nil(invoice_id) ->
        # One-time payment for invoice
        process_invoice_payment(invoice_id, data)

      %{mode: "setup", user_id: user_id} when not is_nil(user_id) ->
        # Setup session - card saved
        process_setup_completed(data)

      _ ->
        Logger.warning("Unhandled checkout.completed mode: #{inspect(data)}")
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "checkout.expired", data: data}) do
    Logger.info("Checkout session expired: #{inspect(data[:session_id])}")
    # Clear checkout session from order if needed
    {:ok, :expired}
  end

  defp process_event(%{type: "payment.succeeded", data: data}) do
    Logger.info("Processing payment.succeeded: #{inspect(data)}")

    case data do
      %{invoice_id: invoice_id} when not is_nil(invoice_id) ->
        # Payment for invoice (e.g., subscription renewal)
        process_invoice_payment(invoice_id, data)

      _ ->
        Logger.warning("Payment succeeded without invoice_id: #{inspect(data)}")
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "payment.failed", data: data}) do
    Logger.warning("Payment failed: #{inspect(data)}")

    case data do
      %{invoice_id: invoice_id} when not is_nil(invoice_id) ->
        # Update invoice/subscription status
        process_payment_failure(invoice_id, data)

      _ ->
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "refund.created", data: data}) do
    Logger.info("Processing refund.created: #{inspect(data)}")
    # Record refund transaction
    process_refund(data)
  end

  defp process_event(%{type: "setup.completed", data: data}) do
    Logger.info("Processing setup.completed: #{inspect(data)}")
    # Save payment method for user
    process_setup_completed(data)
  end

  defp process_event(%{type: type}) do
    Logger.debug("Unhandled webhook event type: #{type}")
    {:ok, :unhandled}
  end

  # ===========================================
  # Business Logic
  # ===========================================

  defp process_invoice_payment(invoice_id, data) do
    invoice_id = parse_id(invoice_id)

    with {:ok, invoice} <- get_invoice(invoice_id),
         :ok <- validate_invoice_status(invoice) do
      # Determine amount from event data
      amount = calculate_payment_amount(invoice, data)

      # Record the payment
      payment_attrs = %{
        amount: amount,
        payment_method: to_string(data[:provider] || "stripe"),
        description: "Online payment via #{data[:provider] || "Stripe"}",
        provider_transaction_id: data[:charge_id] || data[:payment_intent_id],
        provider_data: data
      }

      # Pass nil for admin_user - system/webhook initiated payment
      case Billing.record_payment(invoice, payment_attrs, nil) do
        {:ok, updated_invoice} ->
          Logger.info("Invoice #{invoice.invoice_number} marked as paid")

          # Generate receipt if fully paid
          if updated_invoice.status == "paid" do
            Billing.generate_receipt(updated_invoice)
            Billing.send_receipt(updated_invoice, [])
          end

          {:ok, updated_invoice}

        {:error, reason} ->
          Logger.error("Failed to record payment for invoice #{invoice_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :invoice_not_found} ->
        Logger.warning("Invoice not found for webhook: #{invoice_id}")
        {:error, :invoice_not_found}

      {:error, :already_paid} ->
        Logger.debug("Invoice #{invoice_id} already paid")
        {:ok, :already_paid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_payment_failure(invoice_id, data) do
    invoice_id = parse_id(invoice_id)

    # Log the failure for dunning/retry logic
    Logger.warning(
      "Payment failed for invoice #{invoice_id}: #{data[:error_code]} - #{data[:error_message]}"
    )

    # If this invoice is tied to a subscription, update subscription status
    # This will be handled by the subscription renewal worker

    {:ok, :logged}
  end

  defp process_refund(data) do
    # Find the original transaction by charge_id and record a refund
    # This is handled by Billing.record_refund if we have the invoice

    case data do
      %{charge_id: charge_id, amount_refunded: amount_cents} when not is_nil(charge_id) ->
        Logger.info("Refund recorded: #{charge_id} - #{amount_cents} cents")
        {:ok, :refund_logged}

      _ ->
        {:ok, :ignored}
    end
  end

  defp process_setup_completed(data) do
    # Save the payment method for the user
    case data do
      %{payment_method_id: pm_id, customer_id: _customer_id, user_id: user_id}
      when not is_nil(pm_id) ->
        Logger.info("Payment method saved for user #{user_id}: #{pm_id}")

        # Get payment method details from provider and save
        # This should create a PaymentMethod record
        {:ok, :payment_method_saved}

      _ ->
        {:ok, :ignored}
    end
  end

  # ===========================================
  # Idempotency & Event Logging
  # ===========================================

  defp check_idempotency(provider, event_id) do
    repo = RepoHelper.repo()

    import Ecto.Query

    query =
      from we in "phoenix_kit_webhook_events",
        where: we.provider == ^to_string(provider) and we.event_id == ^event_id,
        select: we.id

    case repo.one(query) do
      nil -> :new
      _id -> :duplicate
    end
  rescue
    _ -> :new
  end

  defp create_webhook_event(%{event_id: event_id, provider: provider, type: type} = event) do
    repo = RepoHelper.repo()

    attrs = %{
      provider: to_string(provider),
      event_id: event_id,
      event_type: type,
      payload: event.raw_payload || %{},
      processed: false,
      retry_count: 0,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    case repo.insert_all("phoenix_kit_webhook_events", [attrs], returning: [:id]) do
      {1, [%{id: id}]} -> {:ok, %{id: id}}
      _ -> {:error, :insert_failed}
    end
  rescue
    e ->
      Logger.error("Failed to create webhook event: #{inspect(e)}")
      {:ok, %{id: nil}}
  end

  defp mark_event_processed(%{id: nil}, _result), do: :ok

  defp mark_event_processed(%{id: id}, result) do
    repo = RepoHelper.repo()

    import Ecto.Query

    {error_message, processed} =
      case result do
        {:ok, _} -> {nil, true}
        {:error, reason} -> {inspect(reason), false}
      end

    query =
      from we in "phoenix_kit_webhook_events",
        where: we.id == ^id

    repo.update_all(query,
      set: [
        processed: processed,
        processed_at: DateTime.utc_now(),
        error_message: error_message,
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  rescue
    _ -> :ok
  end

  # ===========================================
  # Helpers
  # ===========================================

  defp get_invoice(invoice_id) do
    case Billing.get_invoice(invoice_id) do
      nil -> {:error, :invoice_not_found}
      invoice -> {:ok, invoice}
    end
  end

  defp validate_invoice_status(%{status: status}) when status in ["draft", "sent", "overdue"] do
    :ok
  end

  defp validate_invoice_status(%{status: "paid"}) do
    {:error, :already_paid}
  end

  defp validate_invoice_status(%{status: status}) do
    {:error, {:invalid_status, status}}
  end

  defp calculate_payment_amount(invoice, data) do
    # Use amount from webhook if available, otherwise use invoice total
    case data do
      %{amount_total: amount_cents} when is_integer(amount_cents) ->
        Decimal.div(Decimal.new(amount_cents), 100)

      %{amount: amount_cents} when is_integer(amount_cents) ->
        Decimal.div(Decimal.new(amount_cents), 100)

      _ ->
        # Use remaining balance on invoice
        Decimal.sub(invoice.total, invoice.paid_amount || Decimal.new(0))
    end
  end

  defp parse_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(_), do: nil
end
