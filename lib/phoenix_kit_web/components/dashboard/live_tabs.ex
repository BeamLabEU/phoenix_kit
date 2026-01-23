defmodule PhoenixKitWeb.Components.Dashboard.LiveTabs do
  @moduledoc """
  LiveView integration for dashboard tabs with real-time updates.

  This module provides hooks and helpers for LiveViews to integrate with
  the dashboard tab system, including:

  - Automatic tab subscription and updates
  - Badge value synchronization via PubSub
  - Presence tracking for viewer counts
  - Group collapse state management

  ## Usage in LiveViews

      defmodule MyAppWeb.DashboardLive do
        use MyAppWeb, :live_view
        use PhoenixKitWeb.Components.Dashboard.LiveTabs

        def mount(_params, _session, socket) do
          socket =
            socket
            |> init_dashboard_tabs()
            |> track_tab_presence(:my_tab)

          {:ok, socket}
        end

        # Tabs automatically update when badges change
      end

  ## Manual Integration

  If you prefer manual control:

      def mount(_params, _session, socket) do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(PhoenixKit.PubSub, PhoenixKit.Dashboard.pubsub_topic())

          # Subscribe to badge topics for live updates
          for tab <- PhoenixKit.Dashboard.get_tabs() do
            if tab.badge && tab.badge.subscribe do
              topic = PhoenixKit.Dashboard.Badge.get_topic(tab.badge)
              Phoenix.PubSub.subscribe(PhoenixKit.PubSub, topic)
            end
          end
        end

        {:ok, assign(socket, :dashboard_tabs, PhoenixKit.Dashboard.get_tabs())}
      end

      def handle_info({:tab_updated, _tab}, socket) do
        {:noreply, assign(socket, :dashboard_tabs, PhoenixKit.Dashboard.get_tabs())}
      end
  """

  alias PhoenixKit.Dashboard
  alias PhoenixKit.Dashboard.{Badge, Presence, Registry}

  # Get the PubSub server from the socket's endpoint configuration
  # This allows PhoenixKit to work with any parent app's PubSub server
  defp get_pubsub(socket) do
    socket.endpoint.config(:pubsub_server)
  end

  @doc """
  Use this module in a LiveView to get dashboard tab helpers.
  """
  defmacro __using__(_opts) do
    quote do
      import PhoenixKitWeb.Components.Dashboard.LiveTabs

      @before_compile PhoenixKitWeb.Components.Dashboard.LiveTabs
    end
  end

  @doc false
  # credo:disable-for-lines:100 Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(_env) do
    quote do
      alias PhoenixKit.Dashboard.Badge, as: DashboardBadge

      def handle_info({:tab_updated, tab}, socket) do
        tabs = update_tab_in_list(socket.assigns[:dashboard_tabs] || [], tab)
        # Re-apply context badge value if this tab has one
        context_badge_values = socket.assigns[:context_badge_values] || %{}
        tabs = restore_context_badge_value(tabs, tab.id, context_badge_values)
        {:noreply, assign(socket, :dashboard_tabs, tabs)}
      end

      # Restore context badge value for a specific tab after update
      defp restore_context_badge_value(tabs, tab_id, context_badge_values) do
        case Map.get(context_badge_values, tab_id) do
          nil ->
            tabs

          value ->
            Enum.map(tabs, fn tab ->
              if tab.id == tab_id and tab.badge != nil and
                   DashboardBadge.context_aware?(tab.badge) do
                updated_badge = DashboardBadge.update_value(tab.badge, value)
                %{tab | badge: updated_badge}
              else
                tab
              end
            end)
        end
      end

      def handle_info(:tabs_refreshed, socket) do
        tabs = load_dashboard_tabs(socket)
        # Re-merge context badge values to preserve per-user badge state
        context_badge_values = socket.assigns[:context_badge_values] || %{}
        tabs_with_context = merge_context_badge_values_inline(tabs, context_badge_values)
        {:noreply, assign(socket, :dashboard_tabs, tabs_with_context)}
      end

      # Inline helper to merge context values (mirrors the module function)
      defp merge_context_badge_values_inline(tabs, context_badge_values)
           when map_size(context_badge_values) == 0,
           do: tabs

      defp merge_context_badge_values_inline(tabs, context_badge_values) do
        Enum.map(tabs, fn tab ->
          case Map.get(context_badge_values, tab.id) do
            nil ->
              tab

            value when tab.badge != nil ->
              # Only update if badge is still context-aware (config might have changed)
              if DashboardBadge.context_aware?(tab.badge) do
                updated_badge = DashboardBadge.update_value(tab.badge, value)
                %{tab | badge: updated_badge}
              else
                tab
              end

            _value ->
              tab
          end
        end)
      end

      def handle_info({:tab_viewers_updated, tab_id, count}, socket) do
        viewer_counts = Map.put(socket.assigns[:tab_viewer_counts] || %{}, tab_id, count)
        {:noreply, assign(socket, :tab_viewer_counts, viewer_counts)}
      end

      def handle_info({:badge_update, tab_id, value}, socket) do
        Dashboard.update_badge(tab_id, value)
        {:noreply, socket}
      end

      def handle_event("toggle_dashboard_group", %{"group" => group_id}, socket) do
        {:noreply, toggle_collapsed_group(socket, group_id)}
      rescue
        _ -> {:noreply, socket}
      end

      defp toggle_collapsed_group(socket, group_id) do
        group_atom = String.to_existing_atom(group_id)
        collapsed = socket.assigns[:collapsed_dashboard_groups] || MapSet.new()
        updated = toggle_group_membership(collapsed, group_atom)
        assign(socket, :collapsed_dashboard_groups, updated)
      end

      defp toggle_group_membership(set, item) do
        if MapSet.member?(set, item),
          do: MapSet.delete(set, item),
          else: MapSet.put(set, item)
      end

      defp update_tab_in_list(tabs, updated_tab) do
        Enum.map(tabs, fn tab ->
          if tab.id == updated_tab.id, do: updated_tab, else: tab
        end)
      end

      defp load_dashboard_tabs(socket) do
        scope = socket.assigns[:phoenix_kit_current_scope]
        path = socket.assigns[:url_path] || "/dashboard"
        Registry.get_tabs_with_active(path, scope: scope)
      end
    end
  end

  @doc """
  Initializes dashboard tabs in a LiveView socket.

  This function:
  1. Loads tabs from the registry
  2. Subscribes to tab updates
  3. Subscribes to badge update topics (with context resolution for context-aware badges)
  4. Initializes viewer counts
  5. Loads initial values for context-aware badges

  ## Options

  - `:show_presence` - Load and track presence counts (default: true)
  - `:subscribe_badges` - Subscribe to live badge topics (default: true)

  ## Context-Aware Badges

  For badges with `context_key` set, this function:
  - Resolves topic placeholders using the current context from `current_contexts_map`
  - Loads initial badge values using the badge's loader function
  - Stores context badge values in `:context_badge_values` assign

  ## Examples

      socket = init_dashboard_tabs(socket)
      socket = init_dashboard_tabs(socket, show_presence: false)
  """
  @spec init_dashboard_tabs(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def init_dashboard_tabs(socket, opts \\ []) do
    show_presence = Keyword.get(opts, :show_presence, true)
    subscribe_badges = Keyword.get(opts, :subscribe_badges, true)

    scope = socket.assigns[:phoenix_kit_current_scope]
    current_path = socket.assigns[:url_path] || "/dashboard"

    # Get current contexts map for context-aware badges
    contexts_map = socket.assigns[:current_contexts_map] || %{}

    # Load tabs
    tabs = Registry.get_tabs_with_active(current_path, scope: scope)

    # Subscribe to updates if connected
    if Phoenix.LiveView.connected?(socket) do
      pubsub = get_pubsub(socket)

      # Subscribe to tab updates
      Phoenix.PubSub.subscribe(pubsub, Registry.pubsub_topic())

      # Subscribe to presence updates
      if show_presence do
        Presence.subscribe()
      end

      # Subscribe to badge topics (resolving context placeholders)
      if subscribe_badges do
        subscribe_to_badge_topics(tabs, contexts_map, pubsub)
      end
    end

    # Load viewer counts
    viewer_counts =
      if show_presence do
        Presence.get_all_tab_counts()
      else
        %{}
      end

    # Load initial values for context-aware badges and merge into tabs
    context_badge_values = init_context_badges(tabs, contexts_map)
    tabs_with_context_values = merge_context_badge_values(tabs, context_badge_values)

    socket
    |> Phoenix.Component.assign(:dashboard_tabs, tabs_with_context_values)
    |> Phoenix.Component.assign(:tab_viewer_counts, viewer_counts)
    |> Phoenix.Component.assign(:collapsed_dashboard_groups, MapSet.new())
    |> Phoenix.Component.assign(:context_badge_values, context_badge_values)
  end

  @doc """
  Tracks the current user's presence on a specific tab.

  Call this in mount/3 to track which tab the user is viewing.

  ## Examples

      socket = track_tab_presence(socket, :orders)
      socket = track_tab_presence(socket, :printers, meta: %{printer_id: 123})
  """
  @spec track_tab_presence(Phoenix.LiveView.Socket.t(), atom(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def track_tab_presence(socket, tab_id, opts \\ []) do
    if Phoenix.LiveView.connected?(socket) do
      current_path = socket.assigns[:url_path]
      opts = Keyword.put_new(opts, :tab_path, current_path)

      case Presence.track_tab(socket, tab_id, opts) do
        {:ok, _ref} ->
          Phoenix.Component.assign(socket, :tracked_tab, tab_id)

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  @doc """
  Untracks the current user from their tracked tab.

  Call this when leaving a tab or on terminate.
  """
  @spec untrack_tab_presence(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def untrack_tab_presence(socket) do
    case socket.assigns[:tracked_tab] do
      nil ->
        socket

      tab_id ->
        Presence.untrack_tab(socket, tab_id)
        Phoenix.Component.assign(socket, :tracked_tab, nil)
    end
  end

  @doc """
  Refreshes the dashboard tabs from the registry.

  Call this when you need to force a refresh of tab data.
  Context-aware badge values are preserved during refresh.
  """
  @spec refresh_dashboard_tabs(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_dashboard_tabs(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_path = socket.assigns[:url_path] || "/dashboard"

    tabs = Registry.get_tabs_with_active(current_path, scope: scope)

    # Re-merge context badge values to preserve per-user badge state
    context_badge_values = socket.assigns[:context_badge_values] || %{}
    tabs_with_context = merge_context_badge_values(tabs, context_badge_values)

    Phoenix.Component.assign(socket, :dashboard_tabs, tabs_with_context)
  end

  @doc """
  Updates a specific tab's badge and broadcasts the update.

  This is a convenience wrapper that updates the badge and triggers
  a broadcast to all connected LiveViews.

  ## Examples

      update_tab_badge(socket, :notifications, 5)
      update_tab_badge(socket, :alerts, count: 3, color: :error)
  """
  @spec update_tab_badge(Phoenix.LiveView.Socket.t(), atom(), any()) ::
          Phoenix.LiveView.Socket.t()
  def update_tab_badge(socket, tab_id, value) do
    Dashboard.update_badge(tab_id, value)
    socket
  end

  @doc """
  Sets attention animation on a tab.

  ## Examples

      set_tab_attention(socket, :alerts, :pulse)
  """
  @spec set_tab_attention(Phoenix.LiveView.Socket.t(), atom(), atom()) ::
          Phoenix.LiveView.Socket.t()
  def set_tab_attention(socket, tab_id, animation) do
    Dashboard.set_attention(tab_id, animation)
    socket
  end

  @doc """
  Clears attention animation from a tab.
  """
  @spec clear_tab_attention(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def clear_tab_attention(socket, tab_id) do
    Dashboard.clear_attention(tab_id)
    socket
  end

  @doc """
  Reinitializes context-aware badges when context changes.

  Call this when the user switches context (e.g., selects a different organization).
  It will:
  - Subscribe to new context-specific PubSub topics
  - Load new badge values for the new context
  - Merge updated values into dashboard tabs

  Note: Old PubSub subscriptions are not explicitly removed. They will be cleaned
  up when the LiveView process terminates. If your context switch doesn't involve
  navigation, filter incoming PubSub messages by checking the current context.

  ## Examples

      def handle_info({:context_changed, :organization, new_org}, socket) do
        socket =
          socket
          |> assign(:current_contexts_map, %{organization: new_org})
          |> reinit_context_badges()

        {:noreply, socket}
      end
  """
  @spec reinit_context_badges(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reinit_context_badges(socket) do
    tabs = socket.assigns[:dashboard_tabs] || []
    contexts_map = socket.assigns[:current_contexts_map] || %{}

    # Resubscribe to badge topics with new context
    if Phoenix.LiveView.connected?(socket) do
      pubsub = get_pubsub(socket)
      subscribe_to_badge_topics(tabs, contexts_map, pubsub)
    end

    # Reload context badge values and merge into tabs
    context_badge_values = init_context_badges(tabs, contexts_map)
    tabs_with_context_values = merge_context_badge_values(tabs, context_badge_values)

    socket
    |> Phoenix.Component.assign(:dashboard_tabs, tabs_with_context_values)
    |> Phoenix.Component.assign(:context_badge_values, context_badge_values)
  end

  @doc """
  Updates a context-aware badge value in socket assigns.

  Use this when handling PubSub messages for context-aware badges. Unlike
  `update_tab_badge/3` which updates global ETS, this updates the socket assigns
  so each user sees their own value.

  ## Examples

      def handle_info({:alert_count_update, count}, socket) do
        {:noreply, update_context_badge(socket, :alerts, count)}
      end
  """
  @spec update_context_badge(Phoenix.LiveView.Socket.t(), atom(), any()) ::
          Phoenix.LiveView.Socket.t()
  def update_context_badge(socket, tab_id, value) do
    # Update context_badge_values
    context_badge_values = socket.assigns[:context_badge_values] || %{}
    updated_values = Map.put(context_badge_values, tab_id, value)

    # Also update the tab's badge in dashboard_tabs
    tabs = socket.assigns[:dashboard_tabs] || []

    updated_tabs =
      Enum.map(tabs, fn tab ->
        if tab.id == tab_id and tab.badge do
          updated_badge = Badge.update_value(tab.badge, value)
          %{tab | badge: updated_badge}
        else
          tab
        end
      end)

    socket
    |> Phoenix.Component.assign(:context_badge_values, updated_values)
    |> Phoenix.Component.assign(:dashboard_tabs, updated_tabs)
  end

  @doc """
  Gets the badge value for a tab, checking context-aware values first.

  For context-aware badges, returns the value from `:context_badge_values`.
  For regular badges, returns the badge's stored value.

  ## Examples

      # In template
      <%= get_badge_value(@context_badge_values, tab) %>
  """
  @spec get_badge_value(map(), map()) :: any()
  def get_badge_value(context_badge_values, tab) when is_map(context_badge_values) do
    case Map.get(context_badge_values, tab.id) do
      nil -> tab.badge && tab.badge.value
      value -> value
    end
  end

  def get_badge_value(_, tab), do: tab.badge && tab.badge.value

  # Private helpers

  defp subscribe_to_badge_topics(tabs, contexts_map, pubsub) do
    for tab <- tabs, tab.badge, Badge.live?(tab.badge) do
      context = get_context_for_badge(tab.badge, contexts_map)

      # Skip subscription for context-aware badges when context is nil
      # (would result in malformed topics like "org::alerts")
      unless Badge.context_aware?(tab.badge) and is_nil(context) do
        topic = Badge.get_resolved_topic(tab.badge, context)

        if topic do
          Phoenix.PubSub.subscribe(pubsub, topic)
        end
      end
    end

    :ok
  end

  defp init_context_badges(tabs, contexts_map) do
    tabs
    |> Enum.filter(fn tab -> tab.badge && Badge.context_aware?(tab.badge) end)
    |> Enum.reduce(%{}, fn tab, acc ->
      context = get_context_for_badge(tab.badge, contexts_map)
      value = Badge.load_value(tab.badge, context)
      Map.put(acc, tab.id, value)
    end)
  end

  defp get_context_for_badge(%Badge{context_key: nil}, _contexts_map), do: nil

  defp get_context_for_badge(%Badge{context_key: key}, contexts_map) do
    Map.get(contexts_map, key)
  end

  # Merges context badge values into tabs so they're ready for rendering
  defp merge_context_badge_values(tabs, context_badge_values)
       when map_size(context_badge_values) == 0 do
    tabs
  end

  defp merge_context_badge_values(tabs, context_badge_values) do
    Enum.map(tabs, fn tab ->
      case Map.get(context_badge_values, tab.id) do
        nil ->
          tab

        # For compound badges, if loader returns a list, treat as segments
        segments when is_list(segments) and tab.badge != nil and tab.badge.type == :compound ->
          if Badge.context_aware?(tab.badge) do
            updated_badge = Badge.update_segments(tab.badge, segments)
            %{tab | badge: updated_badge}
          else
            tab
          end

        value when tab.badge != nil ->
          # Only update if badge is still context-aware (config might have changed)
          if Badge.context_aware?(tab.badge) do
            updated_badge = Badge.update_value(tab.badge, value)
            %{tab | badge: updated_badge}
          else
            tab
          end

        _value ->
          # Tab has no badge, skip update
          tab
      end
    end)
  end
end
