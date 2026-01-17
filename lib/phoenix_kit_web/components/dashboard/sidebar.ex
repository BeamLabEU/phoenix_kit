defmodule PhoenixKitWeb.Components.Dashboard.Sidebar do
  @moduledoc """
  Sidebar component for the user dashboard.

  Renders the complete dashboard navigation with:
  - Grouped tabs with headers
  - Active state highlighting
  - Badge indicators
  - Presence counts
  - Attention animations
  - Mobile bottom navigation
  - Collapsible groups
  - Context selector (when `position: :sidebar` is configured)

  ## Usage

      <.dashboard_sidebar
        current_path={@url_path}
        scope={@phoenix_kit_current_scope}
        locale={@current_locale}
      />

  ## Live Updates

  The sidebar automatically updates when tabs change if you subscribe to updates:

      def mount(_params, _session, socket) do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(PhoenixKit.PubSub, PhoenixKit.Dashboard.pubsub_topic())
        end
        {:ok, socket}
      end

      def handle_info({:tab_updated, _tab}, socket) do
        {:noreply, assign(socket, :tabs, PhoenixKit.Dashboard.get_tabs())}
      end
  """

  use Phoenix.Component

  alias PhoenixKit.Dashboard.{Presence, Registry, Tab}
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Dashboard.TabItem

  # Use the icon component from Core.Icon to avoid circular dependencies
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders the complete dashboard sidebar with all tabs.

  ## Attributes

  - `current_path` - The current URL path for active state detection
  - `scope` - The current authentication scope for visibility filtering
  - `locale` - The current locale for path generation
  - `tabs` - Optional pre-loaded tabs (defaults to loading from registry)
  - `viewer_counts` - Optional map of tab_id => viewer_count
  - `collapsed_groups` - Set of collapsed group IDs
  - `show_presence` - Show presence indicators (default: true)
  - `compact` - Render in compact mode (default: false)
  - `class` - Additional CSS classes
  - `show_context_selector` - Show context selector at top of sidebar (default: false)
  - `dashboard_contexts` - List of available contexts
  - `current_context` - Currently selected context
  - `context_selector_config` - ContextSelector config struct

  ## Multi-Selector Attributes (optional)

  - `context_selector_configs` - List of all ContextSelector configs
  - `dashboard_contexts_map` - Map of key => list of contexts
  - `current_contexts_map` - Map of key => current context
  - `show_context_selectors_map` - Map of key => boolean
  """
  attr :current_path, :string, default: "/dashboard"
  attr :scope, :any, default: nil
  attr :locale, :string, default: nil
  attr :tabs, :list, default: nil
  attr :viewer_counts, :map, default: %{}
  attr :collapsed_groups, :any, default: MapSet.new()
  attr :show_presence, :boolean, default: true
  attr :compact, :boolean, default: false
  attr :class, :string, default: ""
  attr :show_context_selector, :boolean, default: false
  attr :dashboard_contexts, :list, default: []
  attr :current_context, :any, default: nil
  attr :context_selector_config, :any, default: nil
  # Multi-selector attributes
  attr :context_selector_configs, :list, default: []
  attr :dashboard_contexts_map, :map, default: %{}
  attr :current_contexts_map, :map, default: %{}
  attr :show_context_selectors_map, :map, default: %{}

  def dashboard_sidebar(assigns) do
    # Load tabs if not provided
    tabs =
      case assigns.tabs do
        nil -> Registry.get_tabs_with_active(assigns.current_path, scope: assigns.scope)
        tabs -> add_active_state(tabs, assigns.current_path)
      end

    # Group tabs
    grouped_tabs = group_tabs(tabs)
    groups = Registry.get_groups()

    # Get viewer counts if not provided and presence is enabled
    viewer_counts =
      if assigns.show_presence and map_size(assigns.viewer_counts) == 0 do
        Presence.get_all_tab_counts()
      else
        assigns.viewer_counts
      end

    assigns =
      assigns
      |> assign(:tabs, tabs)
      |> assign(:grouped_tabs, grouped_tabs)
      |> assign(:groups, groups)
      |> assign(:viewer_counts, viewer_counts)

    # Check if multi-selector mode
    has_multi_selector = assigns.context_selector_configs != []

    assigns = assign(assigns, :has_multi_selector, has_multi_selector)

    ~H"""
    <nav class={["space-y-1", @class]} role="navigation" aria-label="Dashboard navigation">
      <%!-- Context Selector(s) at top (sub_position: :start) --%>
      <%= if @has_multi_selector do %>
        <%!-- Multi-selector mode --%>
        <PhoenixKitWeb.Components.Dashboard.MultiContextSelector.multi_context_selector_sidebar
          position={:sidebar}
          sub_position={:start}
          configs={@context_selector_configs}
          contexts_map={@dashboard_contexts_map}
          current_map={@current_contexts_map}
          show_map={@show_context_selectors_map}
        />
      <% else %>
        <%!-- Legacy single selector --%>
        <%= if show_context_selector_at?(@show_context_selector, @context_selector_config, :start) do %>
          <PhoenixKitWeb.Components.Dashboard.ContextSelector.sidebar_context_selector
            contexts={@dashboard_contexts}
            current={@current_context}
            config={@context_selector_config}
          />
        <% end %>
      <% end %>

      <%= for group <- sorted_groups(@groups, @grouped_tabs) do %>
        <.tab_group
          group={group}
          tabs={Map.get(@grouped_tabs, group.id, [])}
          viewer_counts={@viewer_counts}
          locale={@locale}
          collapsed={MapSet.member?(@collapsed_groups, group.id)}
          compact={@compact}
        />
      <% end %>

      <%!-- Render ungrouped tabs with possible context selector by priority --%>
      <.tabs_with_context_selector
        tabs={filter_top_level(Map.get(@grouped_tabs, nil, []))}
        all_tabs={Map.get(@grouped_tabs, nil, [])}
        viewer_counts={@viewer_counts}
        locale={@locale}
        compact={@compact}
        show_context_selector={
          show_context_selector_with_priority?(@show_context_selector, @context_selector_config)
        }
        dashboard_contexts={@dashboard_contexts}
        current_context={@current_context}
        context_selector_config={@context_selector_config}
      />

      <%!-- Note: Bottom context selector (sub_position: :end) is rendered by the layout, not here --%>
    </nav>
    """
  end

  @doc """
  Renders a group of tabs with optional header.
  """
  attr :group, :map, required: true
  attr :tabs, :list, required: true
  attr :viewer_counts, :map, default: %{}
  attr :locale, :string, default: nil
  attr :collapsed, :boolean, default: false
  attr :compact, :boolean, default: false

  def tab_group(assigns) do
    ~H"""
    <div
      class="space-y-1"
      data-group-id={@group.id}
      data-collapsed={@collapsed}
    >
      <%!-- Group Header (if labeled) --%>
      <%= if @group[:label] do %>
        <div
          class={[
            "px-3 py-2 text-xs font-semibold text-base-content/50 uppercase tracking-wider",
            @group[:collapsible] &&
              "cursor-pointer hover:text-base-content/70 flex items-center justify-between"
          ]}
          phx-click={@group[:collapsible] && "toggle_dashboard_group"}
          phx-value-group={@group.id}
        >
          <span class="flex items-center gap-2">
            <%= if @group[:icon] do %>
              <.icon name={@group[:icon]} class="w-3.5 h-3.5" />
            <% end %>
            {@group[:label]}
          </span>
          <%= if @group[:collapsible] do %>
            <.icon
              name={if @collapsed, do: "hero-chevron-right-mini", else: "hero-chevron-down-mini"}
              class="w-4 h-4"
            />
          <% end %>
        </div>
      <% end %>

      <%!-- Group Tabs --%>
      <div class={[@collapsed && "hidden"]}>
        <%= for tab <- filter_top_level(@tabs) do %>
          <.tab_with_subtabs
            tab={tab}
            all_tabs={@tabs}
            viewer_counts={@viewer_counts}
            locale={@locale}
            compact={@compact}
          />
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a tab along with its subtabs (if any).

  Subtabs are shown based on the parent tab's `subtab_display` setting:
  - `:when_active` - Subtabs only shown when parent is active
  - `:always` - Subtabs always visible
  """
  attr :tab, :any, required: true
  attr :all_tabs, :list, required: true
  attr :viewer_counts, :map, default: %{}
  attr :locale, :string, default: nil
  attr :compact, :boolean, default: false

  def tab_with_subtabs(assigns) do
    subtabs = get_subtabs_for(assigns.tab.id, assigns.all_tabs)

    show_subtabs =
      Tab.show_subtabs?(assigns.tab, assigns.tab.active) or any_subtab_active?(subtabs)

    assigns =
      assigns
      |> assign(:subtabs, subtabs)
      |> assign(:show_subtabs, show_subtabs)
      |> assign(:has_subtabs, subtabs != [])

    ~H"""
    <div class="tab-with-subtabs" data-tab-id={@tab.id} data-has-subtabs={@has_subtabs}>
      <%!-- Parent Tab --%>
      <TabItem.tab_item
        tab={@tab}
        active={@tab.active}
        viewer_count={Map.get(@viewer_counts, @tab.id, 0)}
        locale={@locale}
        compact={@compact}
      />

      <%!-- Subtabs --%>
      <%= if @has_subtabs and @show_subtabs do %>
        <div class="subtabs pl-2 border-l-2 border-base-300 ml-4 mt-1 space-y-0.5">
          <%= for subtab <- @subtabs do %>
            <TabItem.tab_item
              tab={subtab}
              active={subtab.active}
              viewer_count={Map.get(@viewer_counts, subtab.id, 0)}
              locale={@locale}
              compact={@compact}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders tabs with a context selector inserted at the appropriate priority position.
  """
  attr :tabs, :list, required: true
  attr :all_tabs, :list, required: true
  attr :viewer_counts, :map, default: %{}
  attr :locale, :string, default: nil
  attr :compact, :boolean, default: false
  attr :show_context_selector, :boolean, default: false
  attr :dashboard_contexts, :list, default: []
  attr :current_context, :any, default: nil
  attr :context_selector_config, :any, default: nil

  def tabs_with_context_selector(assigns) do
    context_priority = get_context_selector_priority(assigns.context_selector_config)

    # Create list of items with their priorities, including context selector if needed
    items =
      assigns.tabs
      |> Enum.map(fn tab -> {:tab, tab, tab.priority} end)
      |> maybe_add_context_selector(assigns.show_context_selector, context_priority)
      |> Enum.sort_by(fn {_type, _item, priority} -> priority end)

    assigns = assign(assigns, :items, items)

    ~H"""
    <%= for item <- @items do %>
      <%= case item do %>
        <% {:context_selector, _, _} -> %>
          <PhoenixKitWeb.Components.Dashboard.ContextSelector.sidebar_context_selector
            contexts={@dashboard_contexts}
            current={@current_context}
            config={@context_selector_config}
          />
        <% {:tab, tab, _} -> %>
          <.tab_with_subtabs
            tab={tab}
            all_tabs={@all_tabs}
            viewer_counts={@viewer_counts}
            locale={@locale}
            compact={@compact}
          />
      <% end %>
    <% end %>
    """
  end

  defp maybe_add_context_selector(items, false, _priority), do: items
  defp maybe_add_context_selector(items, true, nil), do: items

  defp maybe_add_context_selector(items, true, priority) do
    [{:context_selector, nil, priority} | items]
  end

  @doc """
  Renders a mobile-friendly bottom navigation bar.

  ## Attributes

  - `current_path` - The current URL path for active state detection
  - `scope` - The current authentication scope
  - `locale` - The current locale
  - `max_tabs` - Maximum tabs to show (default: 5)
  - `class` - Additional CSS classes
  """
  attr :current_path, :string, default: "/dashboard"
  attr :scope, :any, default: nil
  attr :locale, :string, default: nil
  attr :max_tabs, :integer, default: 5
  attr :class, :string, default: ""

  def mobile_navigation(assigns) do
    tabs =
      Registry.get_tabs_with_active(assigns.current_path, scope: assigns.scope)
      |> Enum.filter(&Tab.navigable?/1)
      |> Enum.take(assigns.max_tabs)

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <nav
      class={[
        "fixed bottom-0 left-0 right-0 bg-base-100 border-t border-base-300 z-50 lg:hidden",
        @class
      ]}
      role="navigation"
      aria-label="Mobile navigation"
    >
      <div class="flex items-center justify-around">
        <%= for tab <- @tabs do %>
          <TabItem.mobile_tab_item
            tab={tab}
            active={tab.active}
            locale={@locale}
          />
        <% end %>
        <.more_menu tabs={get_overflow_tabs(@scope, @max_tabs)} locale={@locale} />
      </div>
    </nav>
    """
  end

  @doc """
  Renders a "more" dropdown menu for overflow tabs on mobile.
  """
  attr :tabs, :list, required: true
  attr :locale, :string, default: nil

  def more_menu(assigns) do
    ~H"""
    <%= if length(@tabs) > 0 do %>
      <div class="dropdown dropdown-top dropdown-end">
        <label
          tabindex="0"
          class="flex flex-col items-center justify-center py-2 px-3 cursor-pointer text-base-content/60 hover:text-base-content"
        >
          <.icon name="hero-ellipsis-horizontal" class="w-6 h-6" />
          <span class="text-xs mt-1">More</span>
        </label>
        <ul tabindex="0" class="dropdown-content menu p-2 shadow bg-base-100 rounded-box w-52 mb-2">
          <%= for tab <- @tabs do %>
            <li>
              <.link navigate={build_path(tab.path, @locale)} class="flex items-center gap-2">
                <%= if tab.icon do %>
                  <.icon name={tab.icon} class="w-4 h-4" />
                <% end %>
                <span>{tab.label}</span>
                <%= if tab.badge do %>
                  <PhoenixKitWeb.Components.Dashboard.Badge.dashboard_badge
                    badge={tab.badge}
                    class="badge-xs"
                  />
                <% end %>
              </.link>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a floating action button for mobile that opens a tab menu.

  Includes context selector at the top if configured and user has multiple contexts.
  """
  attr :current_path, :string, default: "/dashboard"
  attr :scope, :any, default: nil
  attr :locale, :string, default: nil
  attr :class, :string, default: ""
  attr :show_context_selector, :boolean, default: false
  attr :dashboard_contexts, :list, default: []
  attr :current_context, :any, default: nil
  attr :context_selector_config, :any, default: nil
  # Multi-selector attributes
  attr :context_selector_configs, :list, default: []
  attr :dashboard_contexts_map, :map, default: %{}
  attr :current_contexts_map, :map, default: %{}
  attr :show_context_selectors_map, :map, default: %{}

  def mobile_fab_menu(assigns) do
    tabs =
      Registry.get_tabs_with_active(assigns.current_path, scope: assigns.scope)
      |> Enum.filter(&Tab.navigable?/1)

    # Check if multi-selector mode
    has_multi_selector = assigns.context_selector_configs != []

    assigns =
      assigns
      |> assign(:tabs, tabs)
      |> assign(:has_multi_selector, has_multi_selector)

    ~H"""
    <div class={["fixed bottom-4 right-4 z-50 lg:hidden", @class]}>
      <div class="dropdown dropdown-top dropdown-end">
        <label tabindex="0" class="btn btn-primary btn-circle shadow-lg">
          <.icon name="hero-bars-3" class="w-5 h-5" />
        </label>
        <div
          tabindex="0"
          class="dropdown-content shadow bg-base-100 rounded-box w-56 mb-2 border border-base-300 max-h-96 overflow-y-auto"
        >
          <%!-- Mobile Context Selector(s) --%>
          <%= if @has_multi_selector do %>
            <PhoenixKitWeb.Components.Dashboard.MultiContextSelector.multi_context_selector_mobile
              configs={@context_selector_configs}
              contexts_map={@dashboard_contexts_map}
              current_map={@current_contexts_map}
              show_map={@show_context_selectors_map}
            />
          <% else %>
            <%= if @show_context_selector and @context_selector_config && @context_selector_config.enabled do %>
              <PhoenixKitWeb.Components.Dashboard.ContextSelector.mobile_context_selector
                contexts={@dashboard_contexts}
                current={@current_context}
                config={@context_selector_config}
              />
            <% end %>
          <% end %>
          <%!-- Navigation Tabs --%>
          <ul class="menu p-2">
            <%= for tab <- @tabs do %>
              <li>
                <.link
                  navigate={build_path(tab.path, @locale)}
                  class={[
                    "flex items-center gap-3",
                    tab.active && "bg-primary text-primary-content"
                  ]}
                >
                  <%= if tab.icon do %>
                    <.icon name={tab.icon} class="w-4 h-4" />
                  <% end %>
                  <span>{tab.label}</span>
                  <%= if tab.badge do %>
                    <PhoenixKitWeb.Components.Dashboard.Badge.dashboard_badge
                      badge={tab.badge}
                      class="ml-auto badge-xs"
                    />
                  <% end %>
                </.link>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp add_active_state(tabs, current_path) do
    Enum.map(tabs, fn tab ->
      Map.put(tab, :active, Tab.matches_path?(tab, current_path))
    end)
  end

  defp group_tabs(tabs) do
    Enum.group_by(tabs, & &1.group)
  end

  defp sorted_groups(groups, grouped_tabs) do
    # Get groups that have tabs
    group_ids_with_tabs = Map.keys(grouped_tabs) |> Enum.reject(&is_nil/1)

    # Filter to groups that have tabs and sort by priority
    groups
    |> Enum.filter(&(&1.id in group_ids_with_tabs))
    |> Enum.sort_by(& &1.priority)
  end

  defp get_overflow_tabs(scope, shown_count) do
    Registry.get_tabs(scope: scope)
    |> Enum.filter(&Tab.navigable?/1)
    |> Enum.drop(shown_count)
  end

  # Always apply URL prefix via Routes.path
  # When locale is nil, use :none to skip locale prefix but still apply URL prefix
  defp build_path(path, nil), do: Routes.path(path, locale: :none)

  defp build_path(path, locale) do
    Routes.path(path, locale: locale)
  end

  # Filter to only top-level tabs (no parent)
  defp filter_top_level(tabs) do
    Enum.filter(tabs, &Tab.top_level?/1)
  end

  # Get subtabs for a given parent tab ID
  defp get_subtabs_for(parent_id, all_tabs) do
    Enum.filter(all_tabs, fn tab ->
      tab.parent == parent_id
    end)
    |> Enum.sort_by(& &1.priority)
  end

  # Check if any subtab is currently active
  defp any_subtab_active?(subtabs) do
    Enum.any?(subtabs, & &1.active)
  end

  # Check if context selector should show at a specific position
  defp show_context_selector_at?(false, _config, _position), do: false
  defp show_context_selector_at?(_show, nil, _position), do: false
  defp show_context_selector_at?(_show, %{enabled: false}, _position), do: false

  defp show_context_selector_at?(true, %{position: :sidebar, sub_position: :start}, :start),
    do: true

  defp show_context_selector_at?(_, _, _), do: false

  # Check if context selector should show with priority (among tabs)
  defp show_context_selector_with_priority?(false, _config), do: false
  defp show_context_selector_with_priority?(_show, nil), do: false
  defp show_context_selector_with_priority?(_show, %{enabled: false}), do: false

  defp show_context_selector_with_priority?(true, %{
         position: :sidebar,
         sub_position: {:priority, _}
       }),
       do: true

  defp show_context_selector_with_priority?(_, _), do: false

  # Get the priority value for the context selector
  defp get_context_selector_priority(%{sub_position: {:priority, n}}), do: n
  defp get_context_selector_priority(_), do: nil
end
