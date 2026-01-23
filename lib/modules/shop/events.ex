defmodule PhoenixKit.Modules.Shop.Events do
  @moduledoc """
  PubSub event broadcasting for Shop cart synchronization.

  This module provides functions to broadcast cart changes across
  multiple browser tabs and devices for the same user/session.

  ## Topics

  - `shop:cart:user:{user_id}` - Cart events for authenticated users
  - `shop:cart:session:{session_id}` - Cart events for guest sessions

  ## Events

  ### Cart Events
  - `{:cart_updated, cart}` - Cart totals changed (generic update)
  - `{:item_added, cart, item}` - Item added to cart
  - `{:item_removed, cart, item_id}` - Item removed from cart
  - `{:quantity_updated, cart, item}` - Item quantity changed
  - `{:shipping_selected, cart}` - Shipping method selected/changed
  - `{:payment_selected, cart}` - Payment option selected/changed
  - `{:cart_cleared, cart}` - All items removed from cart

  ## Examples

      # Subscribe to cart updates for authenticated user
      Events.subscribe_to_user_cart(user_id)

      # Subscribe to cart updates for guest session
      Events.subscribe_to_session_cart(session_id)

      # Broadcast item added
      Events.broadcast_item_added(cart, item)

      # Handle in LiveView
      def handle_info({:item_added, cart, _item}, socket) do
        {:noreply, assign(socket, :cart, cart)}
      end
  """

  alias PhoenixKit.Modules.Shop.Cart
  alias PhoenixKit.PubSub.Manager

  # ============================================
  # TOPIC BUILDERS
  # ============================================

  @doc """
  Returns the PubSub topic for a user's cart.
  """
  def user_cart_topic(user_id) when not is_nil(user_id) do
    "shop:cart:user:#{user_id}"
  end

  @doc """
  Returns the PubSub topic for a session's cart.
  """
  def session_cart_topic(session_id) when not is_nil(session_id) do
    "shop:cart:session:#{session_id}"
  end

  @doc """
  Returns the appropriate topic(s) for a cart.
  """
  def cart_topics(%Cart{user_id: user_id, session_id: session_id}) do
    topics = []
    topics = if user_id, do: [user_cart_topic(user_id) | topics], else: topics
    topics = if session_id, do: [session_cart_topic(session_id) | topics], else: topics
    topics
  end

  # ============================================
  # SUBSCRIPTION FUNCTIONS
  # ============================================

  @doc """
  Subscribes to cart events for a specific cart.
  Subscribes to all relevant topics (user and/or session).
  """
  def subscribe_to_cart(%Cart{} = cart) do
    cart
    |> cart_topics()
    |> Enum.each(&Manager.subscribe/1)
  end

  @doc """
  Subscribes to cart events for an authenticated user.
  """
  def subscribe_to_user_cart(user_id) when not is_nil(user_id) do
    Manager.subscribe(user_cart_topic(user_id))
  end

  @doc """
  Subscribes to cart events for a guest session.
  """
  def subscribe_to_session_cart(session_id) when not is_nil(session_id) do
    Manager.subscribe(session_cart_topic(session_id))
  end

  @doc """
  Unsubscribes from cart events for a specific cart.
  """
  def unsubscribe_from_cart(%Cart{} = cart) do
    cart
    |> cart_topics()
    |> Enum.each(&Manager.unsubscribe/1)
  end

  @doc """
  Unsubscribes from cart events for an authenticated user.
  """
  def unsubscribe_from_user_cart(user_id) when not is_nil(user_id) do
    Manager.unsubscribe(user_cart_topic(user_id))
  end

  @doc """
  Unsubscribes from cart events for a guest session.
  """
  def unsubscribe_from_session_cart(session_id) when not is_nil(session_id) do
    Manager.unsubscribe(session_cart_topic(session_id))
  end

  # ============================================
  # BROADCAST FUNCTIONS
  # ============================================

  @doc """
  Broadcasts a generic cart update event.
  """
  def broadcast_cart_updated(%Cart{} = cart) do
    broadcast_to_cart(cart, {:cart_updated, cart})
  end

  @doc """
  Broadcasts item added event.
  """
  def broadcast_item_added(%Cart{} = cart, item) do
    broadcast_to_cart(cart, {:item_added, cart, item})
  end

  @doc """
  Broadcasts item removed event.
  """
  def broadcast_item_removed(%Cart{} = cart, item_id) do
    broadcast_to_cart(cart, {:item_removed, cart, item_id})
  end

  @doc """
  Broadcasts quantity updated event.
  """
  def broadcast_quantity_updated(%Cart{} = cart, item) do
    broadcast_to_cart(cart, {:quantity_updated, cart, item})
  end

  @doc """
  Broadcasts shipping method selected event.
  """
  def broadcast_shipping_selected(%Cart{} = cart) do
    broadcast_to_cart(cart, {:shipping_selected, cart})
  end

  @doc """
  Broadcasts payment option selected event.
  """
  def broadcast_payment_selected(%Cart{} = cart) do
    broadcast_to_cart(cart, {:payment_selected, cart})
  end

  @doc """
  Broadcasts cart cleared event.
  """
  def broadcast_cart_cleared(%Cart{} = cart) do
    broadcast_to_cart(cart, {:cart_cleared, cart})
  end

  # ============================================
  # PRIVATE FUNCTIONS
  # ============================================

  defp broadcast_to_cart(%Cart{} = cart, message) do
    cart
    |> cart_topics()
    |> Enum.each(fn topic ->
      Manager.broadcast(topic, message)
    end)
  end
end
