defmodule PhoenixKit.Modules.Publishing.Web.Editor.Collaborative do
  @moduledoc """
  Collaborative editing functionality for the publishing editor.

  Handles presence tracking, lock management, spectator mode,
  real-time form sync, and lock expiration.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing.PresenceHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers

  require Logger

  # Lock expires after 30 minutes of inactivity
  @lock_timeout_seconds 30 * 60
  # Warn 5 minutes before expiration
  @lock_warning_seconds 25 * 60
  # Check every minute
  @lock_check_interval_ms 60_000

  # ============================================================================
  # Setup Functions
  # ============================================================================

  @doc """
  Sets up collaborative editing for initial load.
  old_form_key and old_post_slug should be captured BEFORE the socket is updated.
  """
  def setup_collaborative_editing(socket, form_key, opts) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    if Phoenix.LiveView.connected?(socket) && form_key && current_user do
      do_setup_collaborative_editing(socket, form_key, current_user, opts)
    else
      assign_default_editing_state(socket)
    end
  end

  defp do_setup_collaborative_editing(socket, form_key, current_user, opts) do
    old_form_key = Keyword.get(opts, :old_form_key)
    old_post_slug = Keyword.get(opts, :old_post_slug)

    try do
      cleanup_old_presence(old_form_key, form_key, socket, old_post_slug)
      track_and_subscribe(form_key, socket, current_user)
      subscribe_to_post_translations(socket)
      subscribe_to_post_versions(socket)

      socket
      |> assign_editing_role(form_key)
      |> maybe_broadcast_editor_joined()
      |> maybe_load_spectator_state(form_key)
      |> maybe_start_lock_expiration_timer()
    rescue
      ArgumentError ->
        Logger.warning(
          "Publishing Presence not available - collaborative editing disabled. " <>
            "Ensure PhoenixKit.Supervisor starts before your Endpoint in application.ex"
        )

        assign_default_editing_state(socket)
    end
  end

  @doc """
  Used when we know the old form_key (e.g., when switching languages/versions).
  """
  def cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key, opts) do
    current_user = socket.assigns[:phoenix_kit_current_user]
    old_post_slug = Keyword.get(opts, :old_post_slug)

    if Phoenix.LiveView.connected?(socket) && new_form_key && current_user do
      try do
        # Clean up old presence tracking
        if old_form_key && old_form_key != new_form_key do
          PresenceHelpers.untrack_editing_session(old_form_key, socket)
          PresenceHelpers.unsubscribe_from_editing(old_form_key)
          PublishingPubSub.unsubscribe_from_editor_form(old_form_key)

          # Unsubscribe from old post's translation and version topics
          group_slug = socket.assigns[:group_slug]

          if group_slug && old_post_slug do
            PublishingPubSub.unsubscribe_from_post_translations(group_slug, old_post_slug)
            PublishingPubSub.unsubscribe_from_post_versions(group_slug, old_post_slug)
          end

          # Broadcast editor left for the old post to update group dashboard
          broadcast_editor_left_for_post(socket, old_post_slug)
        end

        # Track this user in Presence
        case PresenceHelpers.track_editing_session(new_form_key, socket, current_user) do
          {:ok, _ref} -> :ok
          {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
        end

        # Subscribe to presence changes and form events
        PresenceHelpers.subscribe_to_editing(new_form_key)
        PublishingPubSub.subscribe_to_editor_form(new_form_key)

        # Subscribe to post-level topics for real-time translation/version updates
        subscribe_to_post_translations(socket)
        subscribe_to_post_versions(socket)

        # Determine our role (owner or spectator) and broadcast if owner
        socket
        |> assign_editing_role(new_form_key)
        |> maybe_broadcast_editor_joined()
        |> maybe_load_spectator_state(new_form_key)
        |> maybe_start_lock_expiration_timer()
      rescue
        ArgumentError ->
          assign_default_editing_state(socket)
      end
    else
      assign_default_editing_state(socket)
    end
  end

  # ============================================================================
  # Cleanup Functions
  # ============================================================================

  defp cleanup_old_presence(old_form_key, form_key, socket, old_post_slug) do
    if old_form_key && old_form_key != form_key do
      PresenceHelpers.untrack_editing_session(old_form_key, socket)
      PresenceHelpers.unsubscribe_from_editing(old_form_key)
      PublishingPubSub.unsubscribe_from_editor_form(old_form_key)

      # Unsubscribe from old post's translation and version topics using the OLD slug
      group_slug = socket.assigns[:group_slug]

      if group_slug && old_post_slug do
        PublishingPubSub.unsubscribe_from_post_translations(group_slug, old_post_slug)
        PublishingPubSub.unsubscribe_from_post_versions(group_slug, old_post_slug)
      end

      # Broadcast editor left to group listing for the OLD post
      broadcast_editor_left_for_post(socket, old_post_slug)
    end
  end

  @doc """
  Broadcast editor left for a specific post slug (used when we've already switched posts).
  """
  def broadcast_editor_left_for_post(socket, post_slug) do
    group_slug = socket.assigns[:group_slug]

    if group_slug && post_slug do
      user_info = build_user_info(socket, nil)
      PublishingPubSub.broadcast_editor_left(group_slug, post_slug, user_info)
    end
  end

  @doc """
  Unsubscribe from current post's topics (used in terminate when LiveView closes).
  """
  def unsubscribe_from_old_post_topics(socket) do
    group_slug = socket.assigns[:group_slug]
    post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

    if group_slug && post_slug do
      PublishingPubSub.unsubscribe_from_post_translations(group_slug, post_slug)
      PublishingPubSub.unsubscribe_from_post_versions(group_slug, post_slug)
    end
  end

  # ============================================================================
  # Tracking and Subscription
  # ============================================================================

  defp track_and_subscribe(form_key, socket, current_user) do
    case PresenceHelpers.track_editing_session(form_key, socket, current_user) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
    end

    PresenceHelpers.subscribe_to_editing(form_key)
    PublishingPubSub.subscribe_to_editor_form(form_key)
  end

  defp subscribe_to_post_translations(socket) do
    case socket.assigns[:post] && socket.assigns.post[:slug] do
      post_slug when is_binary(post_slug) ->
        PublishingPubSub.subscribe_to_post_translations(socket.assigns.group_slug, post_slug)

      _ ->
        :ok
    end
  end

  defp subscribe_to_post_versions(socket) do
    case socket.assigns[:post] && socket.assigns.post[:slug] do
      post_slug when is_binary(post_slug) ->
        PublishingPubSub.subscribe_to_post_versions(socket.assigns.group_slug, post_slug)

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Role Management
  # ============================================================================

  @doc """
  Assigns the editing role (owner or spectator) based on presence.
  """
  def assign_editing_role(socket, form_key) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    case PresenceHelpers.get_editing_role(form_key, socket.id, current_user.uuid) do
      {:owner, _presences} ->
        # I'm the owner - I can edit
        socket
        |> Phoenix.Component.assign(:lock_owner?, true)
        |> Phoenix.Component.assign(:readonly?, false)
        |> populate_presence_info(form_key)

      {:spectator, _owner_meta, _presences} ->
        # Different user is the owner - I'm read-only
        socket
        |> Phoenix.Component.assign(:lock_owner?, false)
        |> Phoenix.Component.assign(:readonly?, true)
        |> populate_presence_info(form_key)
    end
  end

  @doc """
  Assigns default editing state when collaborative editing is not available.
  """
  def assign_default_editing_state(socket) do
    socket
    |> Phoenix.Component.assign(:lock_owner?, true)
    |> Phoenix.Component.assign(:readonly?, false)
    |> Phoenix.Component.assign(:lock_owner_user, nil)
    |> Phoenix.Component.assign(:spectators, [])
    |> Phoenix.Component.assign(:other_viewers, [])
  end

  defp populate_presence_info(socket, form_key) do
    presences = PresenceHelpers.get_sorted_presences(form_key)

    my_user_id =
      socket.assigns[:phoenix_kit_current_user] && socket.assigns.phoenix_kit_current_user.uuid

    {lock_owner_user, spectators, other_viewers} =
      case presences do
        [] ->
          {nil, [], []}

        [{_owner_socket_id, owner_meta} | spectator_list] ->
          spectators =
            Enum.map(spectator_list, fn {_socket_id, meta} ->
              %{
                user: meta.user,
                user_id: meta.user_id,
                user_email: meta.user_email
              }
            end)

          # Other viewers = all presences from OTHER users (not just other sockets)
          other_viewers =
            presences
            |> Enum.reject(fn {_socket_id, meta} -> meta.user_id == my_user_id end)
            |> Enum.map(fn {_socket_id, meta} ->
              %{
                user: meta.user,
                user_id: meta.user_id,
                user_email: meta.user_email
              }
            end)
            |> Enum.uniq_by(& &1.user_id)

          {owner_meta.user, spectators, other_viewers}
      end

    socket
    |> Phoenix.Component.assign(:lock_owner_user, lock_owner_user)
    |> Phoenix.Component.assign(:spectators, spectators)
    |> Phoenix.Component.assign(:other_viewers, other_viewers)
  end

  defp maybe_load_spectator_state(socket, form_key) do
    if socket.assigns.readonly?, do: load_spectator_state(socket, form_key), else: socket
  end

  defp load_spectator_state(socket, form_key) do
    # Owner might have unsaved changes - sync from their Presence metadata
    case PresenceHelpers.get_lock_owner(form_key) do
      %{form_state: form_state} when not is_nil(form_state) ->
        apply_remote_form_state(socket, form_state)

      _ ->
        socket
    end
  end

  # ============================================================================
  # Broadcasting
  # ============================================================================

  @doc """
  Only broadcast editor_joined if user is the owner (not a spectator).
  """
  def maybe_broadcast_editor_joined(socket) do
    if socket.assigns[:lock_owner?] do
      broadcast_editor_activity(socket, :joined)
    end

    socket
  end

  @doc """
  Broadcast editor activity to group listing (for showing who's editing).
  """
  def broadcast_editor_activity(socket, action, user \\ nil) do
    group_slug = socket.assigns[:group_slug]
    post = socket.assigns[:post]

    if group_slug && post && post[:slug] do
      user_info = build_user_info(socket, user)

      case action do
        :joined ->
          PublishingPubSub.broadcast_editor_joined(group_slug, post.slug, user_info)

        :left ->
          PublishingPubSub.broadcast_editor_left(group_slug, post.slug, user_info)
      end
    end
  end

  @doc """
  Broadcast form changes to spectators (only owners broadcast).
  """
  def broadcast_form_change(socket, type, payload) do
    form_key = socket.assigns[:form_key]
    is_owner = socket.assigns[:lock_owner?]

    if form_key && is_owner do
      PublishingPubSub.broadcast_editor_form_change(
        form_key,
        %{type: type, data: payload},
        source: socket.id
      )
    end
  end

  @doc """
  Build user info for broadcasts.
  """
  def build_user_info(socket, user) do
    user = user || socket.assigns[:phoenix_kit_current_user]
    # Include role to distinguish editors from spectators
    role = if socket.assigns[:lock_owner?], do: :owner, else: :spectator

    if user do
      %{
        id: user.uuid,
        email: user.email,
        socket_id: socket.id,
        role: role
      }
    else
      %{socket_id: socket.id, role: role}
    end
  end

  # ============================================================================
  # Form Sync
  # ============================================================================

  @doc """
  Apply remote form state (for spectators receiving initial sync).
  """
  def apply_remote_form_state(socket, form_state) do
    form = Map.get(form_state, :form) || Map.get(form_state, "form") || socket.assigns.form

    content =
      Map.get(form_state, :content) || Map.get(form_state, "content") || socket.assigns.content

    socket
    |> Phoenix.Component.assign(:form, form)
    |> Phoenix.Component.assign(:content, content)
    |> Phoenix.Component.assign(:has_pending_changes, true)
  end

  @doc """
  Apply remote form changes (for spectators receiving updates).
  """
  def apply_remote_form_change(socket, %{type: :meta, data: new_form}) do
    # Update language_statuses for current language when status changes
    # This ensures the language switcher reflects the editor's changes
    language = Helpers.editor_language(socket.assigns)
    new_status = new_form["status"]

    current_language_statuses = Map.get(socket.assigns.post, :language_statuses, %{})
    updated_language_statuses = Map.put(current_language_statuses, language, new_status)

    updated_post =
      socket.assigns.post
      |> Map.put(:metadata, Map.merge(socket.assigns.post.metadata, %{status: new_status}))
      |> Map.put(:language_statuses, updated_language_statuses)

    socket
    |> Phoenix.Component.assign(:form, new_form)
    |> Phoenix.Component.assign(:post, updated_post)
    |> Phoenix.LiveView.push_event("form-updated", %{form: new_form})
  end

  def apply_remote_form_change(socket, %{type: :content, data: %{content: content, form: form}}) do
    socket
    |> Phoenix.Component.assign(:content, content)
    |> Phoenix.Component.assign(:form, form)
    |> Phoenix.LiveView.push_event("set-content", %{content: content})
    |> Phoenix.LiveView.push_event("form-updated", %{form: form})
  end

  def apply_remote_form_change(socket, _payload) do
    # Ignore unrecognized payload types
    socket
  end

  # ============================================================================
  # Lock Expiration
  # ============================================================================

  @doc """
  Update activity timestamp on user interactions.
  """
  def touch_activity(socket) do
    socket
    |> Phoenix.Component.assign(:last_activity_at, System.monotonic_time(:second))
    |> Phoenix.Component.assign(:lock_warning_shown, false)
  end

  @doc """
  Conditionally start lock expiration timer after role assignment.
  """
  def maybe_start_lock_expiration_timer(socket) do
    if socket.assigns[:lock_owner?] && !socket.assigns[:readonly?] do
      socket
      |> touch_activity()
      |> start_lock_expiration_timer()
    else
      socket
    end
  end

  @doc """
  Start lock expiration timer (only for owners).
  """
  def start_lock_expiration_timer(socket) do
    if socket.assigns[:lock_owner?] do
      cancel_lock_expiration_timer(socket)
      timer_ref = Process.send_after(self(), :check_lock_expiration, @lock_check_interval_ms)
      Phoenix.Component.assign(socket, :lock_expiration_timer, timer_ref)
    else
      socket
    end
  end

  @doc """
  Cancel lock expiration timer.
  """
  def cancel_lock_expiration_timer(socket) do
    if socket.assigns[:lock_expiration_timer] do
      Process.cancel_timer(socket.assigns.lock_expiration_timer)
    end

    Phoenix.Component.assign(socket, :lock_expiration_timer, nil)
  end

  @doc """
  Check if lock should expire or warn user.
  """
  def check_lock_expiration(socket) do
    if socket.assigns[:lock_owner?] do
      now = System.monotonic_time(:second)
      last_activity = socket.assigns[:last_activity_at] || now
      inactive_seconds = now - last_activity

      cond do
        # Lock expired - release it
        inactive_seconds >= @lock_timeout_seconds ->
          release_lock_due_to_inactivity(socket)

        # Approaching expiration - warn user
        inactive_seconds >= @lock_warning_seconds && !socket.assigns[:lock_warning_shown] ->
          minutes_left = div(@lock_timeout_seconds - inactive_seconds, 60)

          socket
          |> Phoenix.Component.assign(:lock_warning_shown, true)
          |> Phoenix.LiveView.put_flash(
            :warning,
            gettext("Your editing lock will expire in %{minutes} minutes due to inactivity",
              minutes: minutes_left
            )
          )
          |> start_lock_expiration_timer()

        # Still active - schedule next check
        true ->
          start_lock_expiration_timer(socket)
      end
    else
      socket
    end
  end

  @doc """
  Release lock due to inactivity.
  """
  def release_lock_due_to_inactivity(socket) do
    form_key = socket.assigns[:form_key]

    if form_key do
      # Untrack from presence to release lock
      PresenceHelpers.untrack_editing_session(form_key, socket)

      # Broadcast editor left
      broadcast_editor_activity(socket, :left)

      # Keep subscribed but become a spectator
      socket
      |> Phoenix.Component.assign(:lock_owner?, false)
      |> Phoenix.Component.assign(:readonly?, true)
      |> Phoenix.Component.assign(:lock_warning_shown, false)
      |> cancel_lock_expiration_timer()
      |> Phoenix.LiveView.put_flash(
        :error,
        gettext("Your editing lock was released due to inactivity. Reload to reclaim it.")
      )
    else
      socket
    end
  end
end
