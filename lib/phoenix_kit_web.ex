defmodule PhoenixKitWeb do
  @moduledoc """
  The web interface for PhoenixKit.

  This module provides the base functionality for web components
  including controllers, live views, and components used for
  user authentication and management.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      use Gettext, backend: PhoenixKitWeb.Gettext
    end
  end

  def controller do
    quote do
      {layout_module, _} = PhoenixKit.LayoutConfig.get_layout()

      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: layout_module]

      import Plug.Conn
      use Gettext, backend: PhoenixKitWeb.Gettext

      # PhoenixKit Routes helper for prefix-aware path building
      alias PhoenixKit.Utils.Routes

      unquote(core_components())
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      # The native `:layout` is a pure passthrough (`PhoenixKitWeb.Layouts.app`
      # renders only `{@inner_content}`). PhoenixKit LiveViews apply the host's
      # configured `config :phoenix_kit, layout:` themselves, once, via
      # `LayoutWrapper.app_layout` in their render — so routing `:layout` at the
      # host layout too would render the host chrome twice. Keeping `:layout` a
      # passthrough makes `app_layout` the single owner of the host layout.
      use Phoenix.LiveView,
        layout: {PhoenixKitWeb.Layouts, :app}

      use Gettext, backend: PhoenixKitWeb.Gettext

      unquote(core_components())
      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      use Gettext, backend: PhoenixKitWeb.Gettext

      unquote(core_components())
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      use Gettext, backend: PhoenixKitWeb.Gettext

      unquote(core_components())
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.HTML.Form
      import Phoenix.LiveView.Helpers

      # PhoenixKit Routes helper for prefix-aware path building
      alias PhoenixKit.Utils.Routes

      # Layout helper for extracting only layout-relevant assigns (performance)
      import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]

      unquote(verified_routes())
    end
  end

  def core_components do
    quote do
      import PhoenixKitWeb.Components.Core.Button
      import PhoenixKitWeb.Components.Core.Flash
      import PhoenixKitWeb.Components.Core.Header
      import PhoenixKitWeb.Components.Core.Icon
      import PhoenixKitWeb.Components.Core.FormFieldLabel
      import PhoenixKitWeb.Components.Core.FormFieldError
      import PhoenixKitWeb.Components.Core.Input
      import PhoenixKitWeb.Components.Core.DecimalInput
      import PhoenixKitWeb.Components.Core.DateInput, only: [date_input: 1]
      import PhoenixKitWeb.Components.Core.Textarea
      import PhoenixKitWeb.Components.Core.Select
      import PhoenixKitWeb.Components.Core.Checkbox
      import PhoenixKitWeb.Components.Core.SimpleForm
      import PhoenixKitWeb.Components.Core.ThemeSwitcher
      import PhoenixKitWeb.Components.Core.Badge
      import PhoenixKitWeb.Components.Core.StatCard
      import PhoenixKitWeb.Components.Core.Chart
      # `only:` for the same reason as NavTabs below: a later helper on the
      # module must not silently join every LiveView's namespace.
      import PhoenixKitWeb.Components.Core.ChartLanes, only: [chart_lanes: 1]
      import PhoenixKitWeb.Components.Core.StatusDot
      import PhoenixKitWeb.Components.Core.ConnectAccountButton
      # Only the component. This module also exports `format_status/1` and
      # `status_class/1`, and blanket-importing those puts two of the most
      # generic names imaginable into every LiveView in the ecosystem — any
      # consumer with its own `format_status/1` fails to compile with
      # "imported ... conflicts with local function", pointing at code that
      # never mentioned email. phoenix_kit_posts hit exactly that. Core's own
      # caller (EmailActivityBadges) qualifies them, so nothing needs them
      # unqualified.
      import PhoenixKitWeb.Components.Core.EmailStatusBadge, only: [email_status_badge: 1]
      import PhoenixKitWeb.Components.Core.TimeDisplay
      import PhoenixKitWeb.Components.Core.EventTimelineItem
      import PhoenixKitWeb.Components.Core.UserInfo
      import PhoenixKitWeb.Components.Core.Pagination
      import PhoenixKitWeb.Components.Core.FileDisplay
      import PhoenixKitWeb.Components.Core.ResourceLink
      import PhoenixKitWeb.Components.Core.EmailActivityBadges
      import PhoenixKitWeb.Components.Core.MessageTagBadge
      import PhoenixKitWeb.Components.Core.NumberFormatter
      import PhoenixKitWeb.Components.Core.TableDefault
      import PhoenixKitWeb.Components.Core.TreeTable
      import PhoenixKitWeb.Components.Core.TableRowMenu
      import PhoenixKitWeb.Components.Core.ContextMenu
      import PhoenixKitWeb.Components.Core.BulkSelect
      import PhoenixKitWeb.Components.Core.Sortable
      import PhoenixKitWeb.Components.Core.ReorderModal
      import PhoenixKitWeb.Components.Core.ColumnSettings
      import PhoenixKitWeb.Components.Core.OAuthUtils
      import PhoenixKitWeb.Components.Core.OAuthProvider
      import PhoenixKitWeb.Components.Core.OAuthCheckbox
      import PhoenixKitWeb.Components.Core.AWSRegionSelect
      import PhoenixKitWeb.Components.Core.AWSCredentialsVerify
      import PhoenixKitWeb.Components.Core.Accordion
      import PhoenixKitWeb.Components.Core.FileUpload
      import PhoenixKitWeb.Components.Core.LanguageSwitcher
      import PhoenixKitWeb.Components.Core.MarkdownContent
      import PhoenixKitWeb.Components.Core.Markdown
      import PhoenixKitWeb.Components.Core.DraggableList
      import PhoenixKitWeb.Components.Core.PkLink
      import PhoenixKitWeb.Components.Core.Modal
      import PhoenixKitWeb.Components.Core.PopoverPanel
      import PhoenixKitWeb.Components.Core.SearchPicker
      import PhoenixKitWeb.Components.Core.MediaThumbnail
      import PhoenixKitWeb.Components.Core.AdminPageHeader
      import PhoenixKitWeb.Components.Core.UserDashboardHeader
      import PhoenixKitWeb.Components.Core.DevNotice
      import PhoenixKitWeb.Components.Core.PhoenixKitGlobals
      # Also exports tab_class/{1,2} and tablist_class/{0,1,2} so tab-styled
      # markup that is not a tab strip can share one daisyUI definition.
      # Those names now live in every LiveView — a local function of the
      # same name and arity will fail the consumer's compile (this is how
      # core 2.0's bar_chart/1 broke phoenix_kit_web_analytics). `only:`
      # so a later helper on this module does not silently join the global
      # namespace; same pattern as EmailStatusBadge above.
      import PhoenixKitWeb.Components.Core.NavTabs,
        only: [
          nav_tabs: 1,
          tab_class: 1,
          tab_class: 2,
          tablist_class: 0,
          tablist_class: 1,
          tablist_class: 2
        ]

      import PhoenixKitWeb.Components.Core.IntegrationPicker
      import PhoenixKitWeb.Components.Core.EmptyState
      import PhoenixKitWeb.Components.Core.SortSelector
      import PhoenixKitWeb.Components.Core.FormSection
      import PhoenixKitWeb.Components.Core.FormActions
      import PhoenixKitWeb.Components.Core.BulkActionsBar
      import PhoenixKitWeb.Components.Core.AdminEditLink
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: PhoenixKitWeb.Endpoint,
        router: PhoenixKitWeb.Router,
        statics: PhoenixKitWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
