defmodule PhoenixKitWeb.Routes.TicketsRoutes do
  @moduledoc """
  Tickets module routes.

  Provides route definitions for support ticket management.
  """

  @doc """
  Returns quoted code for tickets user routes (non-admin).

  User-facing ticket routes are now included in `phoenix_kit_authenticated_routes/1`
  in `PhoenixKitWeb.Integration` for seamless navigation with other dashboard pages.
  This function returns an empty block for backward compatibility.
  """
  def generate(_url_prefix) do
    quote do
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (localized).
  """
  def admin_locale_routes do
    quote do
      live "/admin/tickets", PhoenixKit.Modules.Tickets.Web.List, :index,
        as: :tickets_list_localized

      live "/admin/tickets/new", PhoenixKit.Modules.Tickets.Web.New, :new,
        as: :tickets_new_localized

      live "/admin/tickets/:id", PhoenixKit.Modules.Tickets.Web.Details, :show,
        as: :tickets_details_localized

      live "/admin/tickets/:id/edit", PhoenixKit.Modules.Tickets.Web.Edit, :edit,
        as: :tickets_edit_localized

      live "/admin/settings/tickets", PhoenixKit.Modules.Tickets.Web.Settings, :index,
        as: :tickets_settings_localized
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (non-localized).
  """
  def admin_routes do
    quote do
      live "/admin/tickets", PhoenixKit.Modules.Tickets.Web.List, :index, as: :tickets_list

      live "/admin/tickets/new", PhoenixKit.Modules.Tickets.Web.New, :new, as: :tickets_new

      live "/admin/tickets/:id", PhoenixKit.Modules.Tickets.Web.Details, :show,
        as: :tickets_details

      live "/admin/tickets/:id/edit", PhoenixKit.Modules.Tickets.Web.Edit, :edit,
        as: :tickets_edit

      live "/admin/settings/tickets", PhoenixKit.Modules.Tickets.Web.Settings, :index,
        as: :tickets_settings
    end
  end
end
