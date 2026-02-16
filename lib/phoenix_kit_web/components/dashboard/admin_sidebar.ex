defmodule PhoenixKitWeb.Components.Dashboard.AdminSidebar do
  @moduledoc """
  Admin sidebar component for the PhoenixKit admin panel.

  Renders the admin navigation using registry-driven Tab structs instead of
  hardcoded HEEX. Supports:
  - Permission-gated tabs (filtered by Registry)
  - Module-enabled filtering (filtered by Registry)
  - Dynamic children for Entities and Publishing
  - Subtab expand/collapse
  - Full reuse of the TabItem component for consistent rendering

  ## Usage

      <.admin_sidebar
        current_path={@current_path}
        scope={@phoenix_kit_current_scope}
        locale={@current_locale}
      />
  """

  use Phoenix.Component

  require Logger

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKitWeb.Components.Dashboard.TabItem

  import PhoenixKit.Dashboard.TabHelpers
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders the complete admin sidebar navigation.

  ## Attributes

  - `current_path` - The current URL path for active state detection
  - `scope` - The current authentication scope for permission filtering
  - `locale` - The current locale for path generation
  - `class` - Additional CSS classes
  """
  attr :current_path, :string, default: "/admin"
  attr :scope, :any, default: nil
  attr :locale, :string, default: nil
  attr :class, :string, default: ""

  def admin_sidebar(assigns) do
    # Get admin tabs, already filtered by level, permission, and module-enabled
    # Expand dynamic children BEFORE active state so dynamic tabs get checked too
    tabs =
      :telemetry.span([:phoenix_kit, :admin_sidebar, :render], %{}, fn ->
        result =
          Registry.get_admin_tabs(scope: assigns.scope)
          |> expand_dynamic_children(assigns.scope)
          |> add_active_state(assigns.current_path)

        {result, %{tab_count: length(result)}}
      end)

    # Group tabs
    grouped_tabs = group_tabs(tabs)
    groups = Registry.get_groups()

    assigns =
      assigns
      |> assign(:tabs, tabs)
      |> assign(:grouped_tabs, grouped_tabs)
      |> assign(:groups, groups)

    ~H"""
    <nav class={["space-y-2", @class]} role="navigation" aria-label="Admin navigation">
      <%= for group <- sorted_groups(@groups, @grouped_tabs) do %>
        <.admin_tab_group
          group={group}
          tabs={Map.get(@grouped_tabs, group.id, [])}
          all_tabs={@tabs}
          locale={@locale}
        />
      <% end %>

      <%!-- Render ungrouped tabs --%>
      <%= for tab <- filter_top_level(Map.get(@grouped_tabs, nil, [])) do %>
        <.admin_tab_with_subtabs
          tab={tab}
          all_tabs={@tabs}
          locale={@locale}
        />
      <% end %>
    </nav>
    """
  end

  attr :group, :map, required: true
  attr :tabs, :list, required: true
  attr :all_tabs, :list, required: true
  attr :locale, :string, default: nil

  defp admin_tab_group(assigns) do
    ~H"""
    <div class="space-y-1" data-group-id={@group.id}>
      <%= if @group[:label] do %>
        <div class="px-3 py-2 text-xs font-semibold text-base-content/50 uppercase tracking-wider">
          <span class="flex items-center gap-2">
            <%= if @group[:icon] do %>
              <.icon name={@group[:icon]} class="w-3.5 h-3.5" />
            <% end %>
            {@group[:label]}
          </span>
        </div>
      <% end %>

      <%= for tab <- filter_top_level(@tabs) do %>
        <.admin_tab_with_subtabs
          tab={tab}
          all_tabs={@all_tabs}
          locale={@locale}
        />
      <% end %>
    </div>
    """
  end

  attr :tab, :any, required: true
  attr :all_tabs, :list, required: true
  attr :locale, :string, default: nil

  defp admin_tab_with_subtabs(assigns) do
    subtabs = get_subtabs_for(assigns.tab.id, assigns.all_tabs)
    # Check all descendants (not just direct children) for active state
    descendant_active = any_descendant_active?(assigns.tab.id, assigns.all_tabs)

    show_subtabs =
      Tab.show_subtabs?(assigns.tab, assigns.tab.active) or descendant_active

    display_tab = maybe_redirect_to_first_subtab(assigns.tab, subtabs)

    highlight_with_subtabs = Map.get(assigns.tab, :highlight_with_subtabs, false)

    parent_active =
      if descendant_active and not highlight_with_subtabs do
        false
      else
        assigns.tab.active
      end

    assigns =
      assigns
      |> assign(:subtabs, subtabs)
      |> assign(:show_subtabs, show_subtabs)
      |> assign(:has_subtabs, subtabs != [])
      |> assign(:display_tab, display_tab)
      |> assign(:parent_active, parent_active)

    ~H"""
    <div class="tab-with-subtabs" data-tab-id={@tab.id} data-has-subtabs={@has_subtabs}>
      <TabItem.tab_item
        tab={@display_tab}
        active={@parent_active}
        locale={@locale}
      />

      <%= if @has_subtabs and @show_subtabs do %>
        <div class="subtabs pl-1 border-l-2 border-base-300 ml-2 mt-1 space-y-0.5">
          <%= for subtab <- @subtabs do %>
            <.admin_subtab_item
              subtab={subtab}
              parent_tab={@tab}
              all_tabs={@all_tabs}
              locale={@locale}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :subtab, :any, required: true
  attr :parent_tab, :any, required: true
  attr :all_tabs, :list, required: true
  attr :locale, :string, default: nil

  defp admin_subtab_item(assigns) do
    children = get_subtabs_for(assigns.subtab.id, assigns.all_tabs)
    child_active = any_descendant_active?(assigns.subtab.id, assigns.all_tabs)

    show_children =
      children != [] and
        (Tab.show_subtabs?(assigns.subtab, assigns.subtab.active) or child_active)

    highlight_with_subtabs = Map.get(assigns.subtab, :highlight_with_subtabs, false)

    subtab_active =
      if child_active and not highlight_with_subtabs do
        false
      else
        assigns.subtab.active
      end

    assigns =
      assigns
      |> assign(:children, children)
      |> assign(:show_children, show_children)
      |> assign(:subtab_active, subtab_active)

    ~H"""
    <TabItem.tab_item
      tab={@subtab}
      active={@subtab_active}
      locale={@locale}
      parent_tab={@parent_tab}
    />
    <%= if @show_children do %>
      <div class="sub-subtabs pl-1 border-l-2 border-base-300 ml-2 mt-0.5 space-y-0.5">
        <%= for child <- @children do %>
          <TabItem.tab_item
            tab={child}
            active={child.active}
            locale={@locale}
            parent_tab={@subtab}
          />
        <% end %>
      </div>
    <% end %>
    """
  end

  # --- Helpers ---

  defp expand_dynamic_children(tabs, scope) do
    # Find tabs with dynamic_children and expand them
    {parents_with_dynamic, other_tabs} =
      Enum.split_with(tabs, fn tab ->
        is_function(tab.dynamic_children, 1)
      end)

    dynamic_children =
      Enum.flat_map(parents_with_dynamic, fn parent ->
        children =
          try do
            parent.dynamic_children.(scope)
          rescue
            error ->
              Logger.warning(
                "[AdminSidebar] dynamic_children for #{inspect(parent.id)} failed: #{Exception.message(error)}"
              )

              []
          end

        # Ensure children have parent set and correct level
        Enum.map(children, fn child ->
          child
          |> Map.put(:parent, child.parent || parent.id)
          |> Map.put(:level, :admin)
        end)
      end)

    # Active state is applied after this function by add_active_state/2
    other_tabs ++ parents_with_dynamic ++ dynamic_children
  end

  # Recursively checks if any descendant (children, grandchildren, etc.) is active.
  # Includes depth limit and cycle detection for safety with parent-app-registered tabs.
  defp any_descendant_active?(parent_id, all_tabs, depth \\ 0, visited \\ %{})

  defp any_descendant_active?(_parent_id, _all_tabs, depth, _visited) when depth > 5, do: false

  defp any_descendant_active?(parent_id, all_tabs, depth, visited) do
    if Map.has_key?(visited, parent_id) do
      Logger.warning("[AdminSidebar] Circular tab reference detected: #{inspect(parent_id)}")
      false
    else
      children = get_subtabs_for(parent_id, all_tabs)
      new_visited = Map.put(visited, parent_id, true)

      Enum.any?(children, fn child ->
        child.active or any_descendant_active?(child.id, all_tabs, depth + 1, new_visited)
      end)
    end
  end

  defp maybe_redirect_to_first_subtab(%{redirect_to_first_subtab: true} = tab, [
         first_subtab | _
       ]) do
    %{tab | path: first_subtab.path}
  end

  defp maybe_redirect_to_first_subtab(tab, _subtabs), do: tab
end
