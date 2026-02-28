defmodule PhoenixKit.Modules.Billing.Events do
  @moduledoc """
  PubSub events for PhoenixKit Billing system.

  Broadcasts billing-related events for real-time updates in LiveViews.
  Uses `PhoenixKit.PubSub.Manager` for self-contained PubSub operations.

  ## Topics

  - `phoenix_kit:billing:orders` - Order events (created, updated, confirmed, paid, cancelled)
  - `phoenix_kit:billing:invoices` - Invoice events (created, sent, paid, voided)
  - `phoenix_kit:billing:profiles` - Billing profile events (created, updated, deleted)
  - `phoenix_kit:billing:transactions` - Transaction events (created, refunded)
  - `phoenix_kit:billing:credit_notes` - Credit note events (sent, applied)

  ## Usage Examples

      # Subscribe to order events
      PhoenixKit.Modules.Billing.Events.subscribe_orders()

      # Handle in LiveView
      def handle_info({:order_created, order}, socket) do
        # Update UI
        {:noreply, socket}
      end

      # Broadcast order created
      PhoenixKit.Modules.Billing.Events.broadcast_order_created(order)
  """

  alias PhoenixKit.PubSub.Manager

  @orders_topic "phoenix_kit:billing:orders"
  @invoices_topic "phoenix_kit:billing:invoices"
  @profiles_topic "phoenix_kit:billing:profiles"
  @transactions_topic "phoenix_kit:billing:transactions"
  @credit_notes_topic "phoenix_kit:billing:credit_notes"
  @subscriptions_topic "phoenix_kit:billing:subscriptions"

  # ============================================
  # SUBSCRIPTIONS
  # ============================================

  @doc """
  Subscribes to order events.
  """
  def subscribe_orders do
    Manager.subscribe(@orders_topic)
  end

  @doc """
  Subscribes to invoice events.
  """
  def subscribe_invoices do
    Manager.subscribe(@invoices_topic)
  end

  @doc """
  Subscribes to billing profile events.
  """
  def subscribe_profiles do
    Manager.subscribe(@profiles_topic)
  end

  @doc """
  Subscribes to transaction events.
  """
  def subscribe_transactions do
    Manager.subscribe(@transactions_topic)
  end

  @doc """
  Subscribes to credit note events.
  """
  def subscribe_credit_notes do
    Manager.subscribe(@credit_notes_topic)
  end

  @doc """
  Subscribes to subscription events.
  """
  def subscribe_subscriptions do
    Manager.subscribe(@subscriptions_topic)
  end

  @doc """
  Subscribes to subscription events for a specific user.
  """
  def subscribe_user_subscriptions(user_id) do
    Manager.subscribe("#{@subscriptions_topic}:user:#{user_id}")
  end

  @doc """
  Subscribes to order events for a specific user.
  """
  def subscribe_user_orders(user_id) do
    Manager.subscribe("#{@orders_topic}:user:#{user_id}")
  end

  @doc """
  Subscribes to invoice events for a specific user.
  """
  def subscribe_user_invoices(user_id) do
    Manager.subscribe("#{@invoices_topic}:user:#{user_id}")
  end

  @doc """
  Subscribes to transaction events for a specific user.
  """
  def subscribe_user_transactions(user_id) do
    Manager.subscribe("#{@transactions_topic}:user:#{user_id}")
  end

  # ============================================
  # ORDER BROADCASTS
  # ============================================

  @doc """
  Broadcasts order created event.
  """
  def broadcast_order_created(order) do
    broadcast(@orders_topic, {:order_created, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_created, order})
  end

  @doc """
  Broadcasts order updated event.
  """
  def broadcast_order_updated(order) do
    broadcast(@orders_topic, {:order_updated, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_updated, order})
  end

  @doc """
  Broadcasts order confirmed event.
  """
  def broadcast_order_confirmed(order) do
    broadcast(@orders_topic, {:order_confirmed, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_confirmed, order})
  end

  @doc """
  Broadcasts order paid event.
  """
  def broadcast_order_paid(order) do
    broadcast(@orders_topic, {:order_paid, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_paid, order})
  end

  @doc """
  Broadcasts order cancelled event.
  """
  def broadcast_order_cancelled(order) do
    broadcast(@orders_topic, {:order_cancelled, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_cancelled, order})
  end

  # ============================================
  # INVOICE BROADCASTS
  # ============================================

  @doc """
  Broadcasts invoice created event.
  """
  def broadcast_invoice_created(invoice) do
    broadcast(@invoices_topic, {:invoice_created, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_created, invoice})
  end

  @doc """
  Broadcasts invoice sent event.
  """
  def broadcast_invoice_sent(invoice) do
    broadcast(@invoices_topic, {:invoice_sent, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_sent, invoice})
  end

  @doc """
  Broadcasts invoice paid event.
  """
  def broadcast_invoice_paid(invoice) do
    broadcast(@invoices_topic, {:invoice_paid, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_paid, invoice})
  end

  @doc """
  Broadcasts invoice voided event.
  """
  def broadcast_invoice_voided(invoice) do
    broadcast(@invoices_topic, {:invoice_voided, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_voided, invoice})
  end

  # ============================================
  # BILLING PROFILE BROADCASTS
  # ============================================

  @doc """
  Broadcasts billing profile created event.
  """
  def broadcast_profile_created(profile) do
    broadcast(@profiles_topic, {:profile_created, profile})
  end

  @doc """
  Broadcasts billing profile updated event.
  """
  def broadcast_profile_updated(profile) do
    broadcast(@profiles_topic, {:profile_updated, profile})
  end

  @doc """
  Broadcasts billing profile deleted event.
  """
  def broadcast_profile_deleted(profile) do
    broadcast(@profiles_topic, {:profile_deleted, profile})
  end

  # ============================================
  # TRANSACTION BROADCASTS
  # ============================================

  @doc """
  Broadcasts transaction created event.
  """
  def broadcast_transaction_created(transaction) do
    broadcast(@transactions_topic, {:transaction_created, transaction})

    broadcast(
      "#{@transactions_topic}:user:#{transaction.user_uuid}",
      {:transaction_created, transaction}
    )
  end

  @doc """
  Broadcasts transaction refunded event.
  """
  def broadcast_transaction_refunded(transaction) do
    broadcast(@transactions_topic, {:transaction_refunded, transaction})

    broadcast(
      "#{@transactions_topic}:user:#{transaction.user_uuid}",
      {:transaction_refunded, transaction}
    )
  end

  # ============================================
  # CREDIT NOTE BROADCASTS
  # ============================================

  @doc """
  Broadcasts credit note sent event.
  """
  def broadcast_credit_note_sent(invoice, transaction) do
    broadcast(@credit_notes_topic, {:credit_note_sent, invoice, transaction})
  end

  @doc """
  Broadcasts credit note applied event.
  """
  def broadcast_credit_note_applied(invoice, transaction, amount) do
    broadcast(@credit_notes_topic, {:credit_note_applied, invoice, transaction, amount})
  end

  # ============================================
  # SUBSCRIPTION BROADCASTS
  # ============================================

  @doc """
  Broadcasts subscription created event.
  """
  def broadcast_subscription_created(subscription) do
    broadcast(@subscriptions_topic, {:subscription_created, subscription})

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_created, subscription}
    )
  end

  @doc """
  Broadcasts subscription cancelled event.
  """
  def broadcast_subscription_cancelled(subscription) do
    broadcast(@subscriptions_topic, {:subscription_cancelled, subscription})

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_cancelled, subscription}
    )
  end

  @doc """
  Broadcasts subscription renewed event.
  """
  def broadcast_subscription_renewed(subscription) do
    broadcast(@subscriptions_topic, {:subscription_renewed, subscription})

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_renewed, subscription}
    )
  end

  @doc """
  Broadcasts subscription type changed event.
  """
  def broadcast_subscription_type_changed(subscription, old_type_id, new_type_id) do
    broadcast(
      @subscriptions_topic,
      {:subscription_type_changed, subscription, old_type_id, new_type_id}
    )

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_type_changed, subscription, old_type_id, new_type_id}
    )
  end

  @doc """
  Broadcasts subscription status changed event.
  """
  def broadcast_subscription_status_changed(subscription, old_status, new_status) do
    broadcast(
      @subscriptions_topic,
      {:subscription_status_changed, subscription, old_status, new_status}
    )

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_status_changed, subscription, old_status, new_status}
    )
  end

  # ============================================
  # HELPERS
  # ============================================

  defp broadcast(topic, message) do
    Manager.broadcast(topic, message)
  end
end
