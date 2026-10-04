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

  ## An entry is rendered only if the visitor can open it

  The menu must never offer a page that bounces the visitor on arrival, so
  every entry is filtered against the SAME gates its destination enforces —
  see `reachable_tabs/2`. This matters because `/admin` is the guaranteed
  landing for every authenticated user: a visitor with no permissions at all
  now renders this shell, where before only a permission holder could.

  The registry already drops a tab whose `:permission` key the scope does not
  hold (`PhoenixKit.Dashboard.Registry.get_tabs/1` → `Tab.permission_granted?/2`) and a tab whose
  `:visible` function says no. Two gates it does NOT apply are added here:

    * `Scope.can_access_admin_area?/1`, the first thing
      `:phoenix_kit_ensure_admin` checks. Fail it and EVERY `/admin` page
      redirects you — including the personal ones — so the whole menu is empty.
    * `PhoenixKitWeb.Users.Auth.can_access_admin_view?/2` for an entry that
      names a `live_view:`. A tab may name a view and no permission key; the
      mount gate then treats that view as *unmapped* and admits only a scope
      holding every enabled permission, while the sidebar happily linked it for
      everyone.

  ## Usage

      <.admin_sidebar
        current_path={@current_path}
        scope={@phoenix_kit_current_scope}
        locale={@current_locale}
      />
  """

  use Phoenix.Component

  require Logger

  alias PhoenixKit.Dashboard.{Group, Registry, Tab, TabHelpers}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.Dashboard.TabItem
  alias PhoenixKitWeb.Users.Auth

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
          assigns.scope
          |> admin_tabs_for_scope(assigns[:locale])
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
    <%!-- No `<nav>` at all when nothing survived the gates: an empty
          navigation landmark is worse than none, and a shell that offers a
          visitor zero destinations should render zero chrome. --%>
    <nav
      :if={@tabs != []}
      class={["space-y-2", @class]}
      role="navigation"
      aria-label="Admin navigation"
    >
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

  @doc """
  Keeps only the entries `scope` can actually open.

  Two gates, in the order the mount hook applies them:

  1. `Scope.can_access_admin_area?/1` — the admin-area gate
     `:phoenix_kit_ensure_admin` checks before anything else. A scope that
     fails it (a `nil` scope, or an authenticated user holding no permission at
     all) is redirected off every `/admin` page, personal ones included, so the
     answer is `[]` — not "the tabs with no permission key".
  2. `PhoenixKitWeb.Users.Auth.can_access_admin_view?/2` for any entry naming a
     `live_view:` — the same function the mount gate asks. Nothing is restated
     here, so a rendered entry and its destination cannot disagree.

  An entry with no `live_view:` is left to the registry's own `:permission` /
  `:visible` filtering — `PhoenixKit.Dashboard.Registry.get_admin_tabs/1` applies both before the
  sidebar calls this. Every tab core ships is of that shape: core declares its
  admin routes in the router rather than on the tab, so there is no module to
  ask, and gate 2 is a structural no-op over core's own menu.
  """
  @spec reachable_tabs([Tab.t()], Scope.t() | nil) :: [Tab.t()]
  def reachable_tabs(tabs, scope) do
    if Scope.can_access_admin_area?(scope) do
      Enum.filter(tabs, &reachable?(&1, scope))
    else
      []
    end
  end

  # The admin-area gate is answered BEFORE the registry is consulted: building
  # a menu for a visitor who may see none of it would run `feature_enabled?/1`
  # per permission key and every module's `dynamic_children` callback, only to
  # discard the result. `reachable_tabs/2` re-applies the gate because it is
  # public and must be safe on its own — the second check is a MapSet size test.
  defp admin_tabs_for_scope(scope, locale) do
    if Scope.can_access_admin_area?(scope) do
      Registry.get_admin_tabs(scope: scope)
      |> expand_dynamic_children(scope, locale)
      |> reachable_tabs(scope)
    else
      []
    end
  end

  defp reachable?(%{live_view: {view, action}}, scope) when is_atom(view),
    do: Auth.can_access_admin_view?(scope, view, action)

  defp reachable?(%{live_view: view}, scope) when is_atom(view) and not is_nil(view),
    do: Auth.can_access_admin_view?(scope, view)

  defp reachable?(_tab, _scope), do: true

  attr :group, :map, required: true
  attr :tabs, :list, required: true
  attr :all_tabs, :list, required: true
  attr :locale, :string, default: nil

  defp admin_tab_group(assigns) do
    # `sorted_groups/2` keeps a group that still holds ANY tab, but only
    # top-level tabs render here — a group left with nothing but subtabs whose
    # parents the gates removed would otherwise emit its heading (and its
    # spacing wrapper) above nothing.
    assigns = assign(assigns, :top_level_tabs, filter_top_level(assigns.tabs))

    ~H"""
    <div :if={@top_level_tabs != []} class="space-y-1" data-group-id={@group.id}>
      <%= if Group.localized_label(@group) do %>
        <div class="pk-sidebar-group px-3 py-2 text-xs font-semibold text-base-content/50 uppercase tracking-wider">
          <span class="flex items-center gap-2">
            <%= if @group.icon do %>
              <.icon name={@group.icon} class="w-3.5 h-3.5" />
            <% end %>
            {Group.localized_label(@group)}
          </span>
        </div>
      <% end %>

      <%= for tab <- @top_level_tabs do %>
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
      # Dividers and group headers render no link, so there is nothing to hover
      # and nothing to name.
      |> assign(:flyout_id, flyout_id(assigns.tab))
      # Stated for the collapsed rail, which has no other way to show which
      # section you are in: the highlight normally lives on the active SUBTAB,
      # and compact mode hides the subtab list. Rendered unconditionally and
      # acted on by CSS only when collapsed, because whether the rail is
      # collapsed is client state the server cannot see.
      |> assign(:branch_active, to_string(descendant_active))

    ~H"""
    <div
      class="tab-with-subtabs"
      data-tab-id={@tab.id}
      data-has-subtabs={@has_subtabs}
      data-pk-flyout-id={@flyout_id}
      data-pk-branch-active={@branch_active}
    >
      <TabItem.tab_item
        tab={@display_tab}
        active={@parent_active}
        locale={@locale}
      />

      <%!-- Compact-mode flyout. Rendered for every navigable top-level entry,
            NOT only the active one: `subtab_display` defaults to `:when_active`,
            so the inline list below exists only for the section you are already
            in — which is precisely the browsing the icon rail otherwise loses.

            Always in the DOM and inert until opened: `popover` is
            `display: none` until `showPopover()`, so this costs markup rather
            than behaviour, and only the client knows whether the rail is
            collapsed.

            `popover="auto"` earns its keep three times over — the top layer
            escapes the sidebar's own `overflow-y: auto` clipping (an absolutely
            positioned panel is cut off at the rail's edge, which is what killed
            the hover tooltip this replaces), light-dismiss and Esc come free,
            and only one auto popover can be open, so moving between icons
            closes the previous flyout without any bookkeeping.

            Placed immediately after the link so Tab order walks into it: the
            top layer changes PAINTING, not the DOM tree, so focus order — and
            every descendant CSS selector — still follows this position. --%>
      <div
        :if={@flyout_id}
        id={@flyout_id}
        popover="auto"
        class="pk-sidebar-flyout"
        role="group"
        aria-label={Tab.localized_label(@tab)}
      >
        <div class="pk-sidebar-flyout-title">{Tab.localized_label(@tab)}</div>
        <%= for subtab <- @subtabs do %>
          <TabItem.tab_item tab={subtab} active={subtab.active} locale={@locale} />
        <% end %>
      </div>

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

  # A leaf entry gets a flyout too — holding just its name. In compact mode the
  # label is off-screen for every row, so without this the rail is unreadable
  # for exactly the items that have no children to explain them.
  defp flyout_id(tab) do
    if Tab.navigable?(tab), do: "pk-flyout-#{tab.id}"
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

    # A subtab may itself carry `redirect_to_first_subtab: true` (a 3-level
    # section like Settings › Integrations). Point its link at the first child
    # the user can reach, while keeping active-state off the original subtab's
    # own match — the same split the top-level tab uses.
    display_subtab = maybe_redirect_to_first_subtab(assigns.subtab, children)

    assigns =
      assigns
      |> assign(:children, children)
      |> assign(:show_children, show_children)
      |> assign(:subtab_active, subtab_active)
      |> assign(:display_subtab, display_subtab)

    ~H"""
    <TabItem.tab_item
      tab={@display_subtab}
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

  defp expand_dynamic_children(tabs, scope, locale) do
    # Find tabs with dynamic_children (arity 1 or 2) and expand them.
    # The 2-arity variant receives locale so modules can render translated
    # child labels without falling back to `Gettext.get_locale/1`.
    parents_with_dynamic =
      Enum.filter(tabs, fn tab ->
        is_function(tab.dynamic_children, 1) or is_function(tab.dynamic_children, 2)
      end)

    dynamic_children =
      Enum.flat_map(parents_with_dynamic, fn parent ->
        children =
          try do
            invoke_dynamic_children(parent.dynamic_children, scope, locale)
          rescue
            error ->
              Logger.warning(
                "[AdminSidebar] dynamic_children for #{inspect(parent.id)} failed: #{Exception.message(error)}"
              )

              []
          end

        # Ensure children have parent set, correct level, and resolved paths
        Enum.map(children, fn child ->
          child
          |> Map.put(:parent, child.parent || parent.id)
          |> Map.put(:level, :admin)
          |> Tab.resolve_path(:admin)
        end)
      end)

    # Active state is applied after this function by add_active_state/2.
    # `tabs` arrives sorted by priority; parents keep their place. Moving the
    # parents that have dynamic_children behind the other tabs drew them last
    # in their group whatever their priority (Entities and Publishing ended up
    # below Locations).
    tabs ++ dynamic_children
  end

  # Dispatches on arity so modules can opt in to locale-aware rendering
  # without breaking existing 1-arity `dynamic_children` implementations.
  defp invoke_dynamic_children(fun, scope, locale) when is_function(fun, 2),
    do: fun.(scope, locale)

  defp invoke_dynamic_children(fun, scope, _locale) when is_function(fun, 1),
    do: fun.(scope)

  @doc false
  # Test-only public delegate. The internal dispatch helper is `defp` because
  # it shouldn't be part of the runtime API; this `@doc false` wrapper lets
  # the unit suite exercise the actual arity dispatch (rather than just
  # re-asserting Elixir's call semantics on anonymous functions). Not
  # recommended for runtime callers — the contract is `dynamic_children_fn`,
  # not this wrapper.
  def __invoke_dynamic_children_for_test__(fun, scope, locale),
    do: invoke_dynamic_children(fun, scope, locale)

  # Test-only public delegate, same reasoning as above. `admin_sidebar/1` needs
  # a started Dashboard Registry to have any tabs at all, which the DB-free
  # component suite does not run; this renders one row from literal tabs so the
  # compact-mode flyout markup can be pinned without that machinery.
  @doc false
  def __tab_with_subtabs_for_test__(assigns), do: admin_tab_with_subtabs(assigns)

  # Test-only public delegate, same reasoning as above: pins the order in
  # which tabs with dynamic_children are drawn without a started registry.
  @doc false
  def __expand_dynamic_children_for_test__(tabs, scope, locale),
    do: expand_dynamic_children(tabs, scope, locale)

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

  # The rule (landing subtab first, else the first reachable by priority)
  # lives in `TabHelpers.redirect_target/2`, shared with the user sidebar and
  # the admin gate so the three cannot drift apart again.
  defp maybe_redirect_to_first_subtab(%{redirect_to_first_subtab: true} = tab, subtabs) do
    case TabHelpers.redirect_target(tab, subtabs) do
      nil -> tab
      path -> %{tab | path: path}
    end
  end

  defp maybe_redirect_to_first_subtab(tab, _subtabs), do: tab
end
