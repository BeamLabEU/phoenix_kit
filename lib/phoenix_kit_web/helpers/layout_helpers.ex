defmodule PhoenixKitWeb.LayoutHelpers do
  @moduledoc """
  Helper functions for working with PhoenixKit layouts efficiently.

  ## Performance: Avoiding Unnecessary Layout Diffs

  When using the dashboard layout, **do not pass all assigns**:

      # ❌ BAD - triggers layout diff on ANY assign change
      <PhoenixKitWeb.Layouts.dashboard {assigns}>

      # ✅ GOOD - only passes assigns the layout uses
      <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>

  The `dashboard_assigns/1` function extracts only the assigns the layout
  actually needs, preventing unnecessary network traffic when other assigns
  (like application-specific data) change.
  """

  # Keys used by the dashboard layout
  @dashboard_layout_keys [
    # Branding (usually from config, but can be overridden)
    :project_title,
    :project_title_suffix,
    :project_logo,
    :project_icon,
    :project_logo_height,
    :project_logo_class,
    :project_home_url,
    :show_title_with_logo,
    # Core layout assigns
    :page_title,
    :flash,
    :url_path,
    :phoenix_kit_current_scope,
    :current_locale,
    :current_locale_base,
    # Tab navigation
    :dashboard_tabs,
    :tab_viewer_counts,
    :collapsed_dashboard_groups,
    # Context selector (legacy single)
    :show_context_selector,
    :dashboard_contexts,
    :current_context,
    :context_selector_config,
    # Context selector (multi)
    :context_selector_configs,
    :dashboard_contexts_map,
    :current_contexts_map,
    :show_context_selectors_map,
    # Slot content
    :inner_block,
    # Optional extra sidebar content after shop tabs
    :sidebar_after_shop,
    # Admin quick-edit link shown in user dropdown
    :admin_edit_url,
    :admin_edit_label
  ]

  @doc """
  Extracts only the assigns needed by the dashboard layout.

  Use this to avoid unnecessary layout diffs when other assigns change:

      def render(assigns) do
        ~H\"\"\"
        <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
          <.my_content data={@data} />
        </PhoenixKitWeb.Layouts.dashboard>
        \"\"\"
      end

  This prevents the layout from re-rendering when assigns like `@data`
  change, since the layout doesn't use `@data`.

  ## Performance Impact

  Without this optimization, a LiveView receiving 7 updates/second can
  send ~84KB/sec of redundant layout HTML. With this optimization,
  layout diffs only occur when layout-relevant assigns actually change.
  """
  @spec dashboard_assigns(map()) :: map()
  def dashboard_assigns(assigns) when is_map(assigns) do
    Map.take(assigns, @dashboard_layout_keys)
  end

  @doc """
  Returns the list of assign keys used by the dashboard layout.

  Useful for debugging or extending the layout with custom assigns.
  """
  @spec dashboard_layout_keys() :: [atom()]
  def dashboard_layout_keys, do: @dashboard_layout_keys
end
