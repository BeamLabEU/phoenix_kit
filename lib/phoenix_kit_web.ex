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
      use Phoenix.LiveView,
        layout: PhoenixKit.LayoutConfig.get_layout()

      use Gettext, backend: PhoenixKitWeb.Gettext

      unquote(core_components())
      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      use Gettext, backend: PhoenixKitWeb.Gettext

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
      import PhoenixKitWeb.Components.Core.Textarea
      import PhoenixKitWeb.Components.Core.Select
      import PhoenixKitWeb.Components.Core.Checkbox
      import PhoenixKitWeb.Components.Core.SimpleForm
      import PhoenixKitWeb.Components.Core.ThemeSwitcher
      import PhoenixKitWeb.Components.Core.Badge
      import PhoenixKitWeb.Components.Core.StatCard
      import PhoenixKitWeb.Components.Core.EmailStatusBadge
      import PhoenixKitWeb.Components.Core.TimeDisplay
      import PhoenixKitWeb.Components.Core.EventTimelineItem
      import PhoenixKitWeb.Components.Core.UserInfo
      import PhoenixKitWeb.Components.Core.Pagination
      import PhoenixKitWeb.Components.Core.FileDisplay
      import PhoenixKitWeb.Components.Core.EmailActivityBadges
      import PhoenixKitWeb.Components.Core.MessageTagBadge
      import PhoenixKitWeb.Components.Core.NumberFormatter
      import PhoenixKitWeb.Components.Core.TableDefault
      import PhoenixKitWeb.Components.Core.OAuthUtils
      import PhoenixKitWeb.Components.Core.OAuthProvider
      import PhoenixKitWeb.Components.Core.OAuthCheckbox
      import PhoenixKitWeb.Components.Core.AWSRegionSelect
      import PhoenixKitWeb.Components.Core.AWSCredentialsVerify
      import PhoenixKitWeb.Components.Core.Accordion
      import PhoenixKitWeb.Components.Core.FileUpload
      import PhoenixKitWeb.Components.Core.LanguageSwitcher
      import PhoenixKitWeb.Components.Core.MarkdownContent
      import PhoenixKitWeb.Components.Core.DraggableList
      import PhoenixKitWeb.Components.Core.OrderStatusBadge
      import PhoenixKitWeb.Components.Core.InvoiceStatusBadge
      import PhoenixKitWeb.Components.Core.TransactionTypeBadge
      import PhoenixKitWeb.Components.Core.CurrencyDisplay
      import PhoenixKitWeb.Components.Core.CookieConsent
      import PhoenixKitWeb.Components.Core.PkLink
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
