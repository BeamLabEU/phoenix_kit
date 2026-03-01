defmodule PhoenixKit.Modules.Shop.Events do
  @moduledoc """
  PubSub event broadcasting for Shop module.

  This module provides functions to broadcast cart changes across
  multiple browser tabs and devices for the same user/session, as well
  as product, category, and inventory updates for real-time admin dashboards.

  ## Topics

  - `shop:cart:user:{user_uuid}` - Cart events for authenticated users
  - `shop:cart:session:{session_id}` - Cart events for guest sessions
  - `shop:products` - Product events (created, updated, deleted)
  - `shop:categories` - Category events (created, updated, deleted)
  - `shop:inventory` - Inventory events (stock changes)
  - `shop:products:{product_uuid}` - Individual product events

  ## Events

  ### Cart Events
  - `{:cart_updated, cart}` - Cart totals changed (generic update)
  - `{:item_added, cart, item}` - Item added to cart
  - `{:item_removed, cart, item_uuid}` - Item removed from cart
  - `{:quantity_updated, cart, item}` - Item quantity changed
  - `{:shipping_selected, cart}` - Shipping method selected/changed
  - `{:payment_selected, cart}` - Payment option selected/changed
  - `{:cart_cleared, cart}` - All items removed from cart

  ### Product Events
  - `{:product_created, product}` - New product created
  - `{:product_updated, product}` - Product updated
  - `{:product_deleted, product_uuid}` - Product deleted
  - `{:products_bulk_status_changed, product_uuids, status}` - Bulk status update

  ### Category Events
  - `{:category_created, category}` - New category created
  - `{:category_updated, category}` - Category updated
  - `{:category_deleted, category_uuid}` - Category deleted

  ### Inventory Events
  - `{:inventory_updated, product_uuid, stock_change}` - Stock level changed

  ## Examples

      # Subscribe to cart updates for authenticated user
      Events.subscribe_to_user_cart(user_uuid)

      # Subscribe to cart updates for guest session
      Events.subscribe_to_session_cart(session_id)

      # Subscribe to product updates (admin dashboard)
      Events.subscribe_products()

      # Broadcast item added
      Events.broadcast_item_added(cart, item)

      # Broadcast product created
      Events.broadcast_product_created(product)

      # Handle in LiveView
      def handle_info({:item_added, cart, _item}, socket) do
        {:noreply, assign(socket, :cart, cart)}
      end
  """

  alias PhoenixKit.Modules.Shop.Cart
  alias PhoenixKit.PubSub.Manager

  # ============================================
  # TOPIC CONSTANTS
  # ============================================

  @products_topic "shop:products"
  @categories_topic "shop:categories"
  @inventory_topic "shop:inventory"

  # ============================================
  # TOPIC GETTERS
  # ============================================

  @doc """
  Returns the PubSub topic for all products.
  """
  def products_topic, do: @products_topic

  @doc """
  Returns the PubSub topic for all categories.
  """
  def categories_topic, do: @categories_topic

  @doc """
  Returns the PubSub topic for inventory events.
  """
  def inventory_topic, do: @inventory_topic

  # ============================================
  # TOPIC BUILDERS
  # ============================================

  @doc """
  Returns the PubSub topic for a user's cart.
  """
  def user_cart_topic(user_uuid) when not is_nil(user_uuid) do
    "shop:cart:user:#{user_uuid}"
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
  def cart_topics(%Cart{user_uuid: user_uuid, session_id: session_id}) do
    topics = []
    topics = if user_uuid, do: [user_cart_topic(user_uuid) | topics], else: topics
    topics = if session_id, do: [session_cart_topic(session_id) | topics], else: topics
    topics
  end

  @doc """
  Returns the PubSub topic for a specific product.
  """
  def product_topic(product_uuid) when not is_nil(product_uuid) do
    "#{@products_topic}:#{product_uuid}"
  end

  # ============================================
  # SUBSCRIPTION FUNCTIONS
  # ============================================

  # --------------------------------------------
  # Product Subscriptions
  # --------------------------------------------

  @doc """
  Subscribes to product events.
  """
  def subscribe_products do
    Manager.subscribe(@products_topic)
  end

  @doc """
  Subscribes to events for a specific product.
  """
  def subscribe_product(product_uuid) when not is_nil(product_uuid) do
    Manager.subscribe(product_topic(product_uuid))
  end

  # --------------------------------------------
  # Category Subscriptions
  # --------------------------------------------

  @doc """
  Subscribes to category events.
  """
  def subscribe_categories do
    Manager.subscribe(@categories_topic)
  end

  # --------------------------------------------
  # Inventory Subscriptions
  # --------------------------------------------

  @doc """
  Subscribes to inventory events.
  """
  def subscribe_inventory do
    Manager.subscribe(@inventory_topic)
  end

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
  def subscribe_to_user_cart(user_uuid) when not is_nil(user_uuid) do
    Manager.subscribe(user_cart_topic(user_uuid))
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
  def unsubscribe_from_user_cart(user_uuid) when not is_nil(user_uuid) do
    Manager.unsubscribe(user_cart_topic(user_uuid))
  end

  @doc """
  Unsubscribes from cart events for a guest session.
  """
  def unsubscribe_from_session_cart(session_id) when not is_nil(session_id) do
    Manager.unsubscribe(session_cart_topic(session_id))
  end

  # ============================================
  # PRODUCT BROADCAST FUNCTIONS
  # ============================================

  @doc """
  Broadcasts product created event.
  """
  def broadcast_product_created(product) do
    broadcast(@products_topic, {:product_created, product})
  end

  @doc """
  Broadcasts product updated event.
  """
  def broadcast_product_updated(product) do
    broadcast(@products_topic, {:product_updated, product})
    broadcast(product_topic(product.uuid), {:product_updated, product})
  end

  @doc """
  Broadcasts product deleted event.
  """
  def broadcast_product_deleted(product_uuid) do
    broadcast(@products_topic, {:product_deleted, product_uuid})
  end

  @doc """
  Broadcasts bulk product status changed event.
  """
  def broadcast_products_bulk_status_changed(product_uuids, status) do
    broadcast(@products_topic, {:products_bulk_status_changed, product_uuids, status})
  end

  # ============================================
  # CATEGORY BROADCAST FUNCTIONS
  # ============================================

  @doc """
  Broadcasts category created event.
  """
  def broadcast_category_created(category) do
    broadcast(@categories_topic, {:category_created, category})
  end

  @doc """
  Broadcasts category updated event.
  """
  def broadcast_category_updated(category) do
    broadcast(@categories_topic, {:category_updated, category})
  end

  @doc """
  Broadcasts category deleted event.
  """
  def broadcast_category_deleted(category_uuid) do
    broadcast(@categories_topic, {:category_deleted, category_uuid})
  end

  @doc """
  Broadcasts bulk category status changed event.
  """
  def broadcast_categories_bulk_status_changed(category_ids, status) do
    broadcast(@categories_topic, {:categories_bulk_status_changed, category_ids, status})
  end

  @doc """
  Broadcasts bulk category parent changed event.
  """
  def broadcast_categories_bulk_parent_changed(category_ids, parent_uuid) do
    broadcast(@categories_topic, {:categories_bulk_parent_changed, category_ids, parent_uuid})
  end

  @doc """
  Broadcasts bulk category deleted event.
  """
  def broadcast_categories_bulk_deleted(category_ids) do
    broadcast(@categories_topic, {:categories_bulk_deleted, category_ids})
  end

  # ============================================
  # INVENTORY BROADCAST FUNCTIONS
  # ============================================

  @doc """
  Broadcasts inventory updated event.
  """
  def broadcast_inventory_updated(product_uuid, stock_change) do
    broadcast(@inventory_topic, {:inventory_updated, product_uuid, stock_change})
    broadcast(product_topic(product_uuid), {:inventory_updated, product_uuid, stock_change})
  end

  # ============================================
  # CART BROADCAST FUNCTIONS
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
  def broadcast_item_removed(%Cart{} = cart, item_uuid) do
    broadcast_to_cart(cart, {:item_removed, cart, item_uuid})
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

  defp broadcast(topic, message) do
    Manager.broadcast(topic, message)
  end
end
