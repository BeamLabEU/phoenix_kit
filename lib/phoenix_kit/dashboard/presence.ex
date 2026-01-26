defmodule PhoenixKit.Dashboard.Presence do
  @moduledoc """
  Presence tracking for dashboard tabs.

  Tracks which users are viewing which dashboard tabs, enabling features like:
  - "2 users viewing" indicators on tabs
  - Real-time user count updates
  - Activity heatmaps
  - User awareness for collaborative features

  ## Integration with PhoenixKit Presence

  This module integrates with PhoenixKit's existing presence system to provide
  dashboard-specific tracking while sharing the underlying infrastructure.

  ## Usage in LiveViews

      def mount(_params, _session, socket) do
        if connected?(socket) do
          # Track user on this tab
          PhoenixKit.Dashboard.Presence.track_tab(socket, :orders)

          # Subscribe to presence updates
          PhoenixKit.Dashboard.Presence.subscribe()
        end

        {:ok, assign(socket, tab_viewers: Presence.get_tab_viewers(:orders))}
      end

      def handle_info({:presence_diff, _diff}, socket) do
        {:noreply, assign(socket, tab_viewers: Presence.get_tab_viewers(:orders))}
      end

  ## Configuration

      config :phoenix_kit, :dashboard_presence,
        enabled: true,
        show_user_count: true,
        show_user_names: false,  # Privacy setting
        track_anonymous: false
  """

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKit.PubSubHelper
  alias PhoenixKit.Users.Auth.Scope

  # Suppress warnings about optional PhoenixKit.Presence module
  @compile {:no_warn_undefined, PhoenixKit.Presence}

  @presence_topic "phoenix_kit:dashboard:presence"
  @tab_prefix "tab:"

  @doc """
  Tracks a user's presence on a specific dashboard tab.

  ## Options

  - `:meta` - Additional metadata to track with the presence (default: %{})
  - `:tab_path` - The full path of the tab (used for analytics)

  ## Examples

      Presence.track_tab(socket, :orders)
      Presence.track_tab(socket, :printers, meta: %{printer_id: 123})
  """
  @spec track_tab(Phoenix.LiveView.Socket.t(), atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def track_tab(socket, tab_id, opts \\ []) when is_atom(tab_id) do
    if enabled?() and connected?(socket) do
      scope = socket.assigns[:phoenix_kit_current_scope]
      user = Scope.user(scope)

      if user || track_anonymous?() do
        meta =
          %{
            tab_id: tab_id,
            tab_path: opts[:tab_path],
            user_id: user && user.id,
            user_email: user && user.email,
            joined_at: DateTime.utc_now(),
            online_at: DateTime.utc_now()
          }
          |> Map.merge(opts[:meta] || %{})

        topic = tab_topic(tab_id)

        case get_presence_module() do
          nil ->
            # Fallback: Use PubSub directly for basic tracking
            track_via_pubsub(socket, topic, meta)

          presence_mod when is_atom(presence_mod) ->
            call_presence_track(
              presence_mod,
              socket.assigns.live_socket_id || socket.id,
              topic,
              user_key(user),
              meta
            )
        end
      else
        {:ok, "anonymous_tracking_disabled"}
      end
    else
      {:ok, "presence_disabled"}
    end
  end

  @doc """
  Untracks a user from a dashboard tab.
  """
  @spec untrack_tab(Phoenix.LiveView.Socket.t(), atom()) :: :ok
  def untrack_tab(socket, tab_id) when is_atom(tab_id) do
    if enabled?() and connected?(socket) do
      topic = tab_topic(tab_id)
      scope = socket.assigns[:phoenix_kit_current_scope]
      user = Scope.user(scope)

      case get_presence_module() do
        nil ->
          # Fallback: Broadcast leave
          Phoenix.PubSub.broadcast(
            PubSubHelper.pubsub(),
            topic,
            {:presence_leave, user_key(user)}
          )

        presence_mod when is_atom(presence_mod) ->
          call_presence_untrack(
            presence_mod,
            socket.assigns.live_socket_id || socket.id,
            topic,
            user_key(user)
          )
      end
    end

    :ok
  end

  @doc """
  Gets all users currently viewing a specific tab.

  ## Options

  - `:format` - Output format: :full (default), :count, :emails, :ids

  ## Examples

      Presence.get_tab_viewers(:orders)
      # => [%{user_id: 1, user_email: "user@example.com", online_at: ~U[...]}]

      Presence.get_tab_viewers(:orders, format: :count)
      # => 3

      Presence.get_tab_viewers(:orders, format: :emails)
      # => ["user@example.com", "admin@example.com"]
  """
  @spec get_tab_viewers(atom(), keyword()) :: list() | integer()
  def get_tab_viewers(tab_id, opts \\ []) do
    format = opts[:format] || :full
    topic = tab_topic(tab_id)

    presences =
      case get_presence_module() do
        nil ->
          # Fallback: Return empty (no presence tracking without Phoenix.Presence)
          []

        presence_mod when is_atom(presence_mod) ->
          call_presence_list(presence_mod, topic)
          |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)
      end

    case format do
      :count -> length(presences)
      :emails -> Enum.map(presences, & &1[:user_email]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      :ids -> Enum.map(presences, & &1[:user_id]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      :full -> presences
    end
  end

  @doc """
  Gets viewer counts for all tabs at once.

  Returns a map of tab_id => count.

  ## Examples

      Presence.get_all_tab_counts()
      # => %{orders: 3, printers: 1, settings: 0}
  """
  @spec get_all_tab_counts() :: map()
  def get_all_tab_counts do
    Registry.get_tabs()
    |> Enum.filter(&Tab.navigable?/1)
    |> Enum.map(fn tab ->
      {tab.id, get_tab_viewers(tab.id, format: :count)}
    end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  @doc """
  Subscribes to presence updates for all dashboard tabs.

  The subscriber will receive messages in the format:
  - `{:presence_diff, %{joins: %{}, leaves: %{}}}` - When users join/leave
  - `{:tab_viewers_updated, tab_id, count}` - Simplified count update
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(PubSubHelper.pubsub(), @presence_topic)
  end

  @doc """
  Subscribes to presence updates for a specific tab.
  """
  @spec subscribe_tab(atom()) :: :ok | {:error, term()}
  def subscribe_tab(tab_id) do
    Phoenix.PubSub.subscribe(PubSubHelper.pubsub(), tab_topic(tab_id))
  end

  @doc """
  Broadcasts a tab viewer count update.

  This is called automatically when presence changes, but can also be
  called manually to force a refresh.
  """
  @spec broadcast_tab_count(atom()) :: :ok
  def broadcast_tab_count(tab_id) do
    count = get_tab_viewers(tab_id, format: :count)

    Phoenix.PubSub.broadcast(
      PubSubHelper.pubsub(),
      @presence_topic,
      {:tab_viewers_updated, tab_id, count}
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Gets the presence topic for a specific tab.
  """
  @spec tab_topic(atom()) :: String.t()
  def tab_topic(tab_id) when is_atom(tab_id) do
    "#{@presence_topic}:#{@tab_prefix}#{tab_id}"
  end

  @doc """
  Gets the main presence topic for all dashboard presence updates.
  """
  @spec presence_topic() :: String.t()
  def presence_topic, do: @presence_topic

  @doc """
  Clears the cached presence module detection.

  Call this after hot code reloading if the presence module configuration
  has changed. The next call to any presence function will re-detect.
  """
  @spec clear_presence_module_cache() :: :ok
  def clear_presence_module_cache do
    :persistent_term.erase({__MODULE__, :presence_module})
    :ok
  rescue
    # Ignore if key doesn't exist
    ArgumentError -> :ok
  end

  @doc """
  Checks if presence tracking is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:phoenix_kit, :dashboard_presence, [])
    Keyword.get(config, :enabled, true)
  end

  @doc """
  Checks if user counts should be shown.
  """
  @spec show_user_count?() :: boolean()
  def show_user_count? do
    config = Application.get_env(:phoenix_kit, :dashboard_presence, [])
    Keyword.get(config, :show_user_count, true)
  end

  @doc """
  Checks if user names/emails should be shown.
  """
  @spec show_user_names?() :: boolean()
  def show_user_names? do
    config = Application.get_env(:phoenix_kit, :dashboard_presence, [])
    Keyword.get(config, :show_user_names, false)
  end

  @doc """
  Checks if anonymous users should be tracked.
  """
  @spec track_anonymous?() :: boolean()
  def track_anonymous? do
    config = Application.get_env(:phoenix_kit, :dashboard_presence, [])
    Keyword.get(config, :track_anonymous, false)
  end

  # Private helpers

  defp connected?(%{transport_pid: pid}) when is_pid(pid), do: true
  defp connected?(_), do: false

  defp user_key(nil), do: "anonymous_#{System.unique_integer([:positive])}"
  defp user_key(user), do: "user:#{user.id}"

  # Cache key for persistent_term storage
  @presence_module_cache_key {__MODULE__, :presence_module}

  defp get_presence_module do
    # Use persistent_term to cache the result of Code.ensure_loaded?
    # This avoids ~180+ code_server calls per second on busy dashboards
    case :persistent_term.get(@presence_module_cache_key, :not_cached) do
      :not_cached ->
        module = determine_presence_module()
        :persistent_term.put(@presence_module_cache_key, module)
        module

      cached_module ->
        cached_module
    end
  end

  defp determine_presence_module do
    # Check if PhoenixKit.Presence exists and is configured
    cond do
      Code.ensure_loaded?(PhoenixKit.Presence) ->
        PhoenixKit.Presence

      Code.ensure_loaded?(Phoenix.Presence) ->
        # Check for app-specific presence module
        nil

      true ->
        nil
    end
  end

  defp track_via_pubsub(socket, topic, meta) do
    # Simple tracking using PubSub for environments without Phoenix.Presence
    socket_id = socket.assigns[:live_socket_id] || socket.id

    # Store in process dictionary as fallback
    Process.put({:dashboard_presence, topic}, meta)

    # Broadcast join
    Phoenix.PubSub.broadcast(PubSubHelper.pubsub(), topic, {:presence_join, socket_id, meta})

    {:ok, socket_id}
  rescue
    _ -> {:error, :pubsub_unavailable}
  end

  # Wrapper functions to avoid apply/3 with known argument counts
  defp call_presence_track(mod, socket_id, topic, key, meta) do
    mod.track(socket_id, topic, key, meta)
  end

  defp call_presence_untrack(mod, socket_id, topic, key) do
    mod.untrack(socket_id, topic, key)
  end

  defp call_presence_list(mod, topic) do
    mod.list(topic)
  end
end
