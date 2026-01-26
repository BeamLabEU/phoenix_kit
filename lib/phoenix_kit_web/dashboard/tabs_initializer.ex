defmodule PhoenixKitWeb.Dashboard.TabsInitializer do
  @moduledoc """
  LiveView on_mount hook for initializing dashboard tabs with context-aware badge values.

  This hook should run AFTER `ContextProvider` to ensure context data is available.
  It automatically initializes dashboard tabs and loads badge values for context-aware
  badges, eliminating the need for custom on_mount hooks in most applications.

  ## Usage

  Add to your live_session after authentication and context hooks:

      live_session :dashboard,
        on_mount: [
          {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
          {PhoenixKitWeb.Dashboard.ContextProvider, :default},
          {PhoenixKitWeb.Dashboard.TabsInitializer, :default}
        ] do
        live "/dashboard", DashboardLive.Index
      end

  ## Mount Options

  - `:default` - Initialize tabs with presence tracking and badge subscriptions
  - `:minimal` - Initialize tabs without presence tracking (lower overhead)
  - `:badges_only` - Only initialize badge values, no presence tracking

  ## Assigns Set

  This hook sets the following assigns:

  - `@dashboard_tabs` - List of Tab structs with badge values loaded
  - `@tab_viewer_counts` - Map of tab_id => viewer count (unless `:minimal` or `:badges_only`)
  - `@collapsed_dashboard_groups` - MapSet of collapsed group IDs
  - `@context_badge_values` - Map of tab_id => badge value for context-aware badges

  ## How It Works

  1. Normalizes `current_contexts_map` for legacy single-selector configurations
     (builds `%{:default => current_context}` if `current_contexts_map` is not set)
  2. Calls `LiveTabs.init_dashboard_tabs/2` which:
     - Loads tabs from the Registry
     - Subscribes to tab update PubSub topics
     - Subscribes to badge update topics (with context placeholder resolution)
     - Loads initial values for context-aware badges via their loaders
     - Merges context values into tab badges

  ## Legacy Single-Selector Compatibility

  For apps using the legacy `:dashboard_context_selector` configuration,
  this hook automatically builds `current_contexts_map` from `current_context`:

      # Legacy config sets these:
      @current_context = %{id: 1, name: "My Farm"}
      @context_selector_config = %{key: :farm, ...}

      # This hook normalizes to:
      @current_contexts_map = %{farm: %{id: 1, name: "My Farm"}}

  This allows context-aware badges with `context_key: :farm` to work correctly.

  ## Manual Alternative

  If you need custom initialization logic, skip this hook and use
  `PhoenixKitWeb.Components.Dashboard.LiveTabs.init_dashboard_tabs/2` in your mount:

      def mount(_params, _session, socket) do
        socket = init_dashboard_tabs(socket)
        {:ok, socket}
      end

  ## Example with Context-Aware Badges

      # config.exs
      config :phoenix_kit, :user_dashboard_tabs, [
        %{
          id: :alerts,
          label: "Alerts",
          path: "/dashboard/alerts",
          badge: %{
            type: :count,
            context_key: :farm,  # Must match selector key
            loader: {MyApp.Alerts, :count_for_farm},
            color: :error
          }
        }
      ]

      # router.ex
      live_session :dashboard,
        on_mount: [
          {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
          {PhoenixKitWeb.Dashboard.ContextProvider, :default},
          {PhoenixKitWeb.Dashboard.TabsInitializer, :default}
        ] do
        live "/dashboard", DashboardLive.Index
      end

      # The badge will automatically show the correct count for the selected farm
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKitWeb.Components.Dashboard.LiveTabs

  @doc """
  On mount hook that initializes dashboard tabs with badge values.

  ## Options

  - `:default` - Full initialization with presence tracking
  - `:minimal` - Skip presence tracking for lower overhead
  - `:badges_only` - Only initialize badge values
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> ensure_contexts_map()
      |> LiveTabs.init_dashboard_tabs(show_presence: true, subscribe_badges: true)

    {:cont, socket}
  end

  def on_mount(:minimal, _params, _session, socket) do
    socket =
      socket
      |> ensure_contexts_map()
      |> LiveTabs.init_dashboard_tabs(show_presence: false, subscribe_badges: true)

    {:cont, socket}
  end

  def on_mount(:badges_only, _params, _session, socket) do
    socket =
      socket
      |> ensure_contexts_map()
      |> LiveTabs.init_dashboard_tabs(show_presence: false, subscribe_badges: true)

    {:cont, socket}
  end

  # Ensures current_contexts_map is set, even in legacy single-selector mode.
  # This is necessary because:
  # - Multi-selector mode: ContextProvider sets current_contexts_map directly
  # - Legacy single-selector mode: ContextProvider only sets current_context
  # - Context-aware badges look for context in current_contexts_map[context_key]
  defp ensure_contexts_map(socket) do
    case socket.assigns[:current_contexts_map] do
      map when is_map(map) and map_size(map) > 0 ->
        # Already has contexts_map, nothing to do
        socket

      _ ->
        # Build from legacy assigns
        current_context = socket.assigns[:current_context]
        config = socket.assigns[:context_selector_config]

        # Use config key if available, otherwise :default
        key =
          cond do
            is_map(config) and Map.has_key?(config, :key) and config.key != nil -> config.key
            is_struct(config) and Map.has_key?(config, :key) and config.key != nil -> config.key
            true -> :default
          end

        contexts_map =
          if current_context do
            %{key => current_context}
          else
            %{}
          end

        assign(socket, :current_contexts_map, contexts_map)
    end
  end
end
