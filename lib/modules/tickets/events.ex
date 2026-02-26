defmodule PhoenixKit.Modules.Tickets.Events do
  @moduledoc """
  PubSub events for PhoenixKit Tickets system.

  Broadcasts ticket-related events for real-time updates in LiveViews.
  Uses `PhoenixKit.PubSub.Manager` for self-contained PubSub operations.

  ## Topics

  - `"tickets:all"` - All tickets (for admins)
  - `"tickets:user:{user_id}"` - Tickets for specific user
  - `"tickets:{id}"` - Specific ticket (for detail view)

  ## Events

  ### Ticket Events
  - `{:ticket_created, ticket}` - New ticket created
  - `{:ticket_updated, ticket}` - Ticket updated
  - `{:ticket_status_changed, ticket, old_status, new_status}` - Status transition
  - `{:ticket_assigned, ticket, old_assignee_id, new_assignee_id}` - Assignment change
  - `{:ticket_priority_changed, ticket, old_priority, new_priority}` - Priority change
  - `{:tickets_bulk_updated, tickets, changes}` - Bulk update operation

  ### Comment Events
  - `{:comment_created, comment, ticket}` - Public comment added
  - `{:internal_note_created, comment, ticket}` - Internal note added (staff only)

  ## Usage Examples

      # Subscribe to all ticket events (admin view)
      PhoenixKit.Modules.Tickets.Events.subscribe_to_all()

      # Subscribe to user's tickets
      PhoenixKit.Modules.Tickets.Events.subscribe_to_user_tickets(user_id)

      # Subscribe to specific ticket (detail view)
      PhoenixKit.Modules.Tickets.Events.subscribe_to_ticket(ticket_id)

      # Handle in LiveView
      def handle_info({:ticket_created, ticket}, socket) do
        # Update UI
        {:noreply, socket}
      end
  """

  alias PhoenixKit.PubSub.Manager

  @all_topic "tickets:all"

  # ============================================================================
  # TOPIC BUILDERS
  # ============================================================================

  @doc """
  Returns the PubSub topic for a specific user's tickets.
  """
  def user_topic(user_id) when is_integer(user_id) do
    "tickets:user:#{user_id}"
  end

  def user_topic(user_uuid) when is_binary(user_uuid) do
    "tickets:user:#{user_uuid}"
  end

  @doc """
  Returns the PubSub topic for a specific ticket.
  """
  def ticket_topic(ticket_id) when is_binary(ticket_id) do
    "tickets:#{ticket_id}"
  end

  # ============================================================================
  # SUBSCRIPTION FUNCTIONS
  # ============================================================================

  @doc """
  Subscribes to all ticket events (for admin views).
  """
  def subscribe_to_all do
    Manager.subscribe(@all_topic)
  end

  @doc """
  Alias for subscribe_to_all/0 for consistency with naming convention.
  Subscribes to all ticket events (for admin views).
  """
  def subscribe_tickets, do: subscribe_to_all()

  @doc """
  Subscribes to ticket events for a specific user.
  """
  def subscribe_to_user_tickets(user_id) when is_integer(user_id) do
    Manager.subscribe(user_topic(user_id))
  end

  def subscribe_to_user_tickets(user_id) when is_binary(user_id) do
    Manager.subscribe(user_topic(user_id))
  end

  @doc """
  Subscribes to events for a specific ticket (for detail views).
  """
  def subscribe_to_ticket(ticket_id) when is_binary(ticket_id) do
    Manager.subscribe(ticket_topic(ticket_id))
  end

  @doc """
  Unsubscribes from all ticket events.
  """
  def unsubscribe_from_all do
    Manager.unsubscribe(@all_topic)
  end

  @doc """
  Unsubscribes from a specific user's ticket events.
  """
  def unsubscribe_from_user_tickets(user_id) when is_integer(user_id) do
    Manager.unsubscribe(user_topic(user_id))
  end

  def unsubscribe_from_user_tickets(user_id) when is_binary(user_id) do
    Manager.unsubscribe(user_topic(user_id))
  end

  @doc """
  Unsubscribes from a specific ticket's events.
  """
  def unsubscribe_from_ticket(ticket_id) when is_binary(ticket_id) do
    Manager.unsubscribe(ticket_topic(ticket_id))
  end

  # ============================================================================
  # TICKET BROADCASTS
  # ============================================================================

  @doc """
  Broadcasts ticket created event.
  """
  def broadcast_ticket_created(ticket) do
    broadcast(@all_topic, {:ticket_created, ticket})
    broadcast(user_topic(ticket.user_uuid), {:ticket_created, ticket})
    broadcast(ticket_topic(ticket.uuid), {:ticket_created, ticket})
  end

  @doc """
  Broadcasts ticket updated event.
  """
  def broadcast_ticket_updated(ticket) do
    broadcast(@all_topic, {:ticket_updated, ticket})
    broadcast(user_topic(ticket.user_uuid), {:ticket_updated, ticket})
    broadcast(ticket_topic(ticket.uuid), {:ticket_updated, ticket})
  end

  @doc """
  Broadcasts ticket status changed event.
  """
  def broadcast_ticket_status_changed(ticket, old_status, new_status) do
    message = {:ticket_status_changed, ticket, old_status, new_status}
    broadcast(@all_topic, message)
    broadcast(user_topic(ticket.user_uuid), message)
    broadcast(ticket_topic(ticket.uuid), message)
  end

  @doc """
  Broadcasts ticket assigned event.
  """
  def broadcast_ticket_assigned(ticket, old_assignee_uuid, new_assignee_uuid) do
    message = {:ticket_assigned, ticket, old_assignee_uuid, new_assignee_uuid}
    broadcast(@all_topic, message)
    broadcast(user_topic(ticket.user_uuid), message)
    broadcast(ticket_topic(ticket.uuid), message)

    # Also broadcast to the new assignee's topic if assigned
    if new_assignee_uuid do
      broadcast(user_topic(new_assignee_uuid), message)
    end
  end

  @doc """
  Broadcasts ticket priority changed event.
  """
  def broadcast_ticket_priority_changed(ticket, old_priority, new_priority) do
    message = {:ticket_priority_changed, ticket, old_priority, new_priority}
    broadcast(@all_topic, message)
    broadcast(user_topic(ticket.user_uuid), message)
    broadcast(ticket_topic(ticket.uuid), message)
  end

  @doc """
  Broadcasts tickets bulk updated event.
  """
  def broadcast_tickets_bulk_updated(tickets, changes) do
    broadcast(@all_topic, {:tickets_bulk_updated, tickets, changes})

    # Also broadcast to each affected user's topic
    tickets
    |> Enum.map(& &1.user_uuid)
    |> Enum.uniq()
    |> Enum.each(fn user_uuid ->
      broadcast(user_topic(user_uuid), {:tickets_bulk_updated, tickets, changes})
    end)
  end

  # ============================================================================
  # COMMENT BROADCASTS
  # ============================================================================

  @doc """
  Broadcasts public comment created event.
  """
  def broadcast_comment_created(comment, ticket) do
    message = {:comment_created, comment, ticket}
    broadcast(@all_topic, message)
    broadcast(user_topic(ticket.user_uuid), message)
    broadcast(ticket_topic(ticket.uuid), message)
  end

  @doc """
  Broadcasts internal note created event (staff only).
  """
  def broadcast_internal_note_created(comment, ticket) do
    message = {:internal_note_created, comment, ticket}
    # Internal notes only broadcast to admin topic and ticket topic
    # (not to user's personal topic since they shouldn't see internal notes)
    broadcast(@all_topic, message)
    broadcast(ticket_topic(ticket.uuid), message)
  end

  # ============================================================================
  # PRIVATE HELPERS
  # ============================================================================

  defp broadcast(topic, message) do
    Manager.broadcast(topic, message)
  end
end
