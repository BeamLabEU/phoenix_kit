defmodule PhoenixKitWeb.Routes.TicketsRoutes do
  @moduledoc """
  Tickets module routes.

  Provides route definitions for support ticket management.
  """

  @doc """
  Returns quoted code for tickets user routes (non-admin).
  """
  def generate(url_prefix) do
    quote do
      # Localized tickets user dashboard routes
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_require_authenticated]

        live_session :phoenix_kit_tickets_user_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/dashboard/tickets", PhoenixKit.Modules.Tickets.Web.UserList, :index,
            as: :tickets_user_list_localized

          live "/dashboard/tickets/new", PhoenixKit.Modules.Tickets.Web.UserNew, :new,
            as: :tickets_user_new_localized

          live "/dashboard/tickets/:id", PhoenixKit.Modules.Tickets.Web.UserDetails, :show,
            as: :tickets_user_details_localized
        end
      end

      # Non-localized tickets user dashboard routes
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_require_authenticated]

        live_session :phoenix_kit_tickets_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/dashboard/tickets", PhoenixKit.Modules.Tickets.Web.UserList, :index,
            as: :tickets_user_list

          live "/dashboard/tickets/new", PhoenixKit.Modules.Tickets.Web.UserNew, :new,
            as: :tickets_user_new

          live "/dashboard/tickets/:id", PhoenixKit.Modules.Tickets.Web.UserDetails, :show,
            as: :tickets_user_details
        end
      end
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
