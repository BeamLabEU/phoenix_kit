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
  # credo:disable-for-lines:60 Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(_env) do
    quote do
      def handle_info({:tab_updated, tab}, socket) do
        tabs = update_tab_in_list(socket.assigns[:dashboard_tabs] || [], tab)
        {:noreply, assign(socket, :dashboard_tabs, tabs)}
      end

      def handle_info(:tabs_refreshed, socket) do
        {:noreply, assign(socket, :dashboard_tabs, load_dashboard_tabs(socket))}
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
  3. Subscribes to badge update topics
  4. Initializes viewer counts

  ## Options

  - `:show_presence` - Load and track presence counts (default: true)
  - `:subscribe_badges` - Subscribe to live badge topics (default: true)

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

    # Load tabs
    tabs = Registry.get_tabs_with_active(current_path, scope: scope)

    # Subscribe to updates if connected
    if Phoenix.LiveView.connected?(socket) do
      # Subscribe to tab updates
      Phoenix.PubSub.subscribe(PhoenixKit.PubSub, Registry.pubsub_topic())

      # Subscribe to presence updates
      if show_presence do
        Presence.subscribe()
      end

      # Subscribe to badge topics
      if subscribe_badges do
        subscribe_to_badge_topics(tabs)
      end
    end

    # Load viewer counts
    viewer_counts =
      if show_presence do
        Presence.get_all_tab_counts()
      else
        %{}
      end

    socket
    |> Phoenix.Component.assign(:dashboard_tabs, tabs)
    |> Phoenix.Component.assign(:tab_viewer_counts, viewer_counts)
    |> Phoenix.Component.assign(:collapsed_dashboard_groups, MapSet.new())
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
  """
  @spec refresh_dashboard_tabs(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_dashboard_tabs(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_path = socket.assigns[:url_path] || "/dashboard"

    tabs = Registry.get_tabs_with_active(current_path, scope: scope)
    Phoenix.Component.assign(socket, :dashboard_tabs, tabs)
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

  # Private helpers

  defp subscribe_to_badge_topics(tabs) do
    for tab <- tabs, tab.badge, Badge.live?(tab.badge) do
      topic = Badge.get_topic(tab.badge)

      if topic do
        Phoenix.PubSub.subscribe(PhoenixKit.PubSub, topic)
      end
    end

    :ok
  end
end
