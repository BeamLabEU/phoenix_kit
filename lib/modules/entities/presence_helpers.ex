defmodule PhoenixKit.Modules.Entities.PresenceHelpers do
  @moduledoc """
  Helper functions for collaborative editing with Phoenix.Presence.

  Provides utilities for tracking editing sessions, determining owner/spectator roles,
  and syncing state between users.
  """

  alias PhoenixKit.Modules.Entities.Presence

  @doc """
  Tracks the current LiveView process in a Presence topic.

  ## Parameters

  - `type`: The resource type (`:entity` or `:data`)
  - `id`: The resource ID
  - `socket`: The LiveView socket
  - `user`: The current user struct

  ## Examples

      track_editing_session(:entity, 5, socket, user)
      # => {:ok, ref}
  """
  def track_editing_session(type, id, socket, user) do
    topic = editing_topic(type, id)

    Presence.track(self(), topic, socket.id, %{
      user_uuid: user.uuid,
      user_email: user.email,
      user: user,
      joined_at: System.system_time(:millisecond),
      phx_ref: socket.id,
      # For diagnostics and dead process detection
      pid: self(),
      transport_pid: socket.transport_pid
    })
  end

  @doc """
  Determines if the current socket is the owner (first in the presence list).

  Returns `{:owner, presences}` if this socket is the owner (or same user in different tab), or
  `{:spectator, owner_meta, presences}` if a different user is the owner.

  ## Examples

      case get_editing_role(:entity, 5, socket.id, current_user.uuid) do
        {:owner, all_presences} ->
          # I can edit!

        {:spectator, owner_metadata, all_presences} ->
          # I'm read-only, sync with owner's state
      end
  """
  def get_editing_role(type, id, socket_id, current_user_uuid) do
    presences = get_sorted_presences(type, id)

    case presences do
      [] ->
        # No one here (shouldn't happen since caller is here)
        # But treat as owner to avoid blocking
        {:owner, []}

      [{^socket_id, _meta} | _rest] ->
        # I'm first! I'm the owner
        {:owner, presences}

      [{_other_socket_id, owner_meta} | _rest] ->
        # Check if same user (different tab) or different user
        if owner_meta.user_uuid == current_user_uuid do
          # Same user, different tab - treat as owner so both tabs can edit
          {:owner, presences}
        else
          # Different user - spectator mode (FIFO locking)
          {:spectator, owner_meta, presences}
        end
    end
  end

  @doc """
  Gets all presences for a resource, sorted by join time (FIFO).

  Returns a list of tuples: `[{socket_id, metadata}, ...]`

  ## Examples

      get_sorted_presences(:entity, 5)
      # => [
      #   {"phx-abc123", %{user_id: 5, joined_at: 123456, ...}},
      #   {"phx-def456", %{user_id: 7, joined_at: 123458, ...}}
      # ]
  """
  def get_sorted_presences(type, id) do
    topic = editing_topic(type, id)
    raw_presences = Presence.list(topic)

    raw_presences
    |> Enum.flat_map(fn {socket_id, %{metas: metas}} ->
      # Filter out metas with dead PIDs
      valid_metas =
        Enum.filter(metas, fn meta ->
          case Map.get(meta, :pid) do
            pid when is_pid(pid) -> Process.alive?(pid)
            # Keep metas without PID for backward compatibility
            _ -> true
          end
        end)

      # Take the first valid meta (most recent)
      case valid_metas do
        [meta | _] -> [{socket_id, meta}]
        [] -> []
      end
    end)
    |> Enum.sort_by(fn {_socket_id, meta} -> meta.joined_at end)
  end

  @doc """
  Gets the lock owner's metadata, or nil if no one is editing.

  ## Examples

      case get_lock_owner(:entity, 5) do
        nil -> # No one editing
        meta -> # meta.user, meta.joined_at, etc.
      end
  """
  def get_lock_owner(type, id) do
    case get_sorted_presences(type, id) do
      [{_socket_id, meta} | _] -> meta
      [] -> nil
    end
  end

  @doc """
  Gets all spectators (everyone except the first person).

  Returns a list of metadata for spectators only.

  ## Examples

      get_spectators(:entity, 5)
      # => [
      #   %{user_id: 7, user_email: "user@example.com", joined_at: 123458, ...},
      #   %{user_id: 9, user_email: "other@example.com", joined_at: 123460, ...}
      # ]
  """
  def get_spectators(type, id) do
    case get_sorted_presences(type, id) do
      [] -> []
      [_owner | spectators] -> Enum.map(spectators, fn {_id, meta} -> meta end)
    end
  end

  @doc """
  Counts total number of people editing (owner + spectators).
  """
  def count_editors(type, id) do
    get_sorted_presences(type, id) |> length()
  end

  @doc """
  Subscribes the current process to presence events for a resource.

  After subscribing, the process will receive:
  - `%Phoenix.Socket.Broadcast{event: "presence_diff", ...}` when users join/leave

  ## Examples

      subscribe_to_editing(:entity, 5)
      # Now will receive presence_diff messages
  """
  def subscribe_to_editing(type, id) do
    topic = editing_topic(type, id)
    Phoenix.PubSub.subscribe(:phoenix_kit_internal_pubsub, topic)
  end

  @doc """
  Generates the Presence topic name for a resource.

  ## Examples

      editing_topic(:entity, 5)
      # => "entity_edit:5"

      editing_topic(:data, 10)
      # => "data_edit:10"
  """
  def editing_topic(:entity, id), do: "entity_edit:#{id}"
  def editing_topic(:data, id), do: "data_edit:#{id}"
end
