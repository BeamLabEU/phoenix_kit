defmodule PhoenixKitWeb.Live.Modules.Blogging.PresenceHelpers do
  @moduledoc """
  Helper functions for collaborative blog post editing with Phoenix.Presence.

  Provides utilities for tracking editing sessions, determining owner/spectator roles,
  and syncing state between users.
  """

  alias PhoenixKitWeb.Live.Modules.Blogging.Presence

  @doc """
  Tracks the current LiveView process in a Presence topic.

  ## Parameters

  - `form_key`: The unique key for the post being edited
  - `socket`: The LiveView socket
  - `user`: The current user struct

  ## Examples

      track_editing_session("blog:my-post/en.phk", socket, user)
      # => {:ok, ref}
  """
  def track_editing_session(form_key, socket, user) do
    topic = editing_topic(form_key)

    Presence.track(self(), topic, socket.id, %{
      user_id: user.id,
      user_email: user.email,
      user: user,
      joined_at: System.system_time(:millisecond),
      phx_ref: socket.id,
      pid: self(),
      transport_pid: socket.transport_pid
    })
  end

  @doc """
  Untracks the current LiveView process from a Presence topic.

  Call this when switching languages or versions to release the lock
  on the previous form before tracking the new one.

  ## Parameters

  - `form_key`: The unique key for the post that was being edited
  - `socket`: The LiveView socket

  ## Examples

      untrack_editing_session("blog:my-post:en", socket)
      # => :ok
  """
  def untrack_editing_session(form_key, socket) do
    topic = editing_topic(form_key)
    Presence.untrack(self(), topic, socket.id)
  end

  @doc """
  Unsubscribes from presence events and editor form events for a form.

  Call this when switching languages or versions to clean up subscriptions.
  """
  def unsubscribe_from_editing(form_key) do
    topic = editing_topic(form_key)
    Phoenix.PubSub.unsubscribe(:phoenix_kit_internal_pubsub, topic)
  end

  @doc """
  Determines if the current socket is the owner (first in the presence list).

  Returns `{:owner, presences}` if this socket is the owner (or same user in different tab), or
  `{:spectator, owner_meta, presences}` if a different user is the owner.

  ## Examples

      case get_editing_role("blog:my-post", socket.id, current_user.id) do
        {:owner, all_presences} ->
          # I can edit!

        {:spectator, owner_metadata, all_presences} ->
          # I'm read-only, sync with owner's state
      end
  """
  def get_editing_role(form_key, socket_id, current_user_id) do
    presences = get_sorted_presences(form_key)

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
        if owner_meta.user_id == current_user_id do
          # Same user, different tab - treat as owner so both tabs can edit
          {:owner, presences}
        else
          # Different user - spectator mode (FIFO locking)
          {:spectator, owner_meta, presences}
        end
    end
  end

  @doc """
  Gets all presences for a form, sorted by join time (FIFO).

  Returns a list of tuples: `[{socket_id, metadata}, ...]`
  """
  def get_sorted_presences(form_key) do
    topic = editing_topic(form_key)
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
  """
  def get_lock_owner(form_key) do
    case get_sorted_presences(form_key) do
      [{_socket_id, meta} | _] -> meta
      [] -> nil
    end
  end

  @doc """
  Gets all spectators (everyone except the first person).

  Returns a list of metadata for spectators only.
  """
  def get_spectators(form_key) do
    case get_sorted_presences(form_key) do
      [] -> []
      [_owner | spectators] -> Enum.map(spectators, fn {_id, meta} -> meta end)
    end
  end

  @doc """
  Counts total number of people editing (owner + spectators).
  """
  def count_editors(form_key) do
    get_sorted_presences(form_key) |> length()
  end

  @doc """
  Subscribes the current process to presence events for a form.

  After subscribing, the process will receive:
  - `%Phoenix.Socket.Broadcast{event: "presence_diff", ...}` when users join/leave
  """
  def subscribe_to_editing(form_key) do
    topic = editing_topic(form_key)
    Phoenix.PubSub.subscribe(:phoenix_kit_internal_pubsub, topic)
  end

  @doc """
  Generates the Presence topic name for a form.

  ## Examples

      editing_topic("blog:my-post/en.phk")
      # => "blog_edit:blog:my-post/en.phk"
  """
  def editing_topic(form_key), do: "blog_edit:#{form_key}"
end
