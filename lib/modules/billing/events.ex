defmodule PhoenixKit.Modules.Billing.Events do
  @moduledoc """
  PubSub events for PhoenixKit Billing system.

  Broadcasts billing-related events for real-time updates in LiveViews.

  ## Topics

  - `billing:orders` - Order events (created, updated, confirmed, paid, cancelled)
  - `billing:invoices` - Invoice events (created, sent, paid, voided)
  - `billing:profiles` - Billing profile events (created, updated, deleted)

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

  @orders_topic "billing:orders"
  @invoices_topic "billing:invoices"
  @profiles_topic "billing:profiles"

  # ============================================
  # SUBSCRIPTIONS
  # ============================================

  @doc """
  Subscribes to order events.
  """
  def subscribe_orders do
    Phoenix.PubSub.subscribe(pubsub(), @orders_topic)
  end

  @doc """
  Subscribes to invoice events.
  """
  def subscribe_invoices do
    Phoenix.PubSub.subscribe(pubsub(), @invoices_topic)
  end

  @doc """
  Subscribes to billing profile events.
  """
  def subscribe_profiles do
    Phoenix.PubSub.subscribe(pubsub(), @profiles_topic)
  end

  @doc """
  Subscribes to order events for a specific user.
  """
  def subscribe_user_orders(user_id) do
    Phoenix.PubSub.subscribe(pubsub(), "#{@orders_topic}:user:#{user_id}")
  end

  @doc """
  Subscribes to invoice events for a specific user.
  """
  def subscribe_user_invoices(user_id) do
    Phoenix.PubSub.subscribe(pubsub(), "#{@invoices_topic}:user:#{user_id}")
  end

  # ============================================
  # ORDER BROADCASTS
  # ============================================

  @doc """
  Broadcasts order created event.
  """
  def broadcast_order_created(order) do
    broadcast(@orders_topic, {:order_created, order})
    broadcast("#{@orders_topic}:user:#{order.user_id}", {:order_created, order})
  end

  @doc """
  Broadcasts order updated event.
  """
  def broadcast_order_updated(order) do
    broadcast(@orders_topic, {:order_updated, order})
    broadcast("#{@orders_topic}:user:#{order.user_id}", {:order_updated, order})
  end

  @doc """
  Broadcasts order confirmed event.
  """
  def broadcast_order_confirmed(order) do
    broadcast(@orders_topic, {:order_confirmed, order})
    broadcast("#{@orders_topic}:user:#{order.user_id}", {:order_confirmed, order})
  end

  @doc """
  Broadcasts order paid event.
  """
  def broadcast_order_paid(order) do
    broadcast(@orders_topic, {:order_paid, order})
    broadcast("#{@orders_topic}:user:#{order.user_id}", {:order_paid, order})
  end

  @doc """
  Broadcasts order cancelled event.
  """
  def broadcast_order_cancelled(order) do
    broadcast(@orders_topic, {:order_cancelled, order})
    broadcast("#{@orders_topic}:user:#{order.user_id}", {:order_cancelled, order})
  end

  # ============================================
  # INVOICE BROADCASTS
  # ============================================

  @doc """
  Broadcasts invoice created event.
  """
  def broadcast_invoice_created(invoice) do
    broadcast(@invoices_topic, {:invoice_created, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_id}", {:invoice_created, invoice})
  end

  @doc """
  Broadcasts invoice sent event.
  """
  def broadcast_invoice_sent(invoice) do
    broadcast(@invoices_topic, {:invoice_sent, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_id}", {:invoice_sent, invoice})
  end

  @doc """
  Broadcasts invoice paid event.
  """
  def broadcast_invoice_paid(invoice) do
    broadcast(@invoices_topic, {:invoice_paid, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_id}", {:invoice_paid, invoice})
  end

  @doc """
  Broadcasts invoice voided event.
  """
  def broadcast_invoice_voided(invoice) do
    broadcast(@invoices_topic, {:invoice_voided, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_id}", {:invoice_voided, invoice})
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
  # HELPERS
  # ============================================

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(pubsub(), topic, message)
  end

  defp pubsub do
    # Get PubSub from application config, fall back to common patterns
    Application.get_env(:phoenix_kit, :pubsub) ||
      Application.get_env(:phoenix_kit, :pubsub_server) ||
      detect_pubsub()
  end

  defp detect_pubsub do
    # Try to find PubSub from parent application
    case Application.get_env(:phoenix_kit, :endpoint) do
      nil ->
        # Default fallback
        :phoenix_kit_pubsub

      endpoint when is_atom(endpoint) ->
        # Extract app name from endpoint module
        endpoint
        |> Module.split()
        |> List.first()
        |> then(&Module.concat(&1, "PubSub"))
    end
  end
end
