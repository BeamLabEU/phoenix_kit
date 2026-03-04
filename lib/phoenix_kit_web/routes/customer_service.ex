defmodule PhoenixKitWeb.Routes.CustomerServiceRoutes do
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
      live "/admin/customer-service",
           PhoenixKit.Modules.CustomerService.Web.List,
           :index,
           as: :customer_service_index_localized

      live "/admin/customer-service/tickets", PhoenixKit.Modules.CustomerService.Web.List, :index,
        as: :customer_service_list_localized

      live "/admin/customer-service/tickets/new",
           PhoenixKit.Modules.CustomerService.Web.New,
           :new,
           as: :customer_service_new_localized

      live "/admin/customer-service/tickets/:id",
           PhoenixKit.Modules.CustomerService.Web.Details,
           :show,
           as: :customer_service_details_localized

      live "/admin/customer-service/tickets/:id/edit",
           PhoenixKit.Modules.CustomerService.Web.Edit,
           :edit,
           as: :customer_service_edit_localized

      live "/admin/settings/customer-service",
           PhoenixKit.Modules.CustomerService.Web.Settings,
           :index,
           as: :customer_service_settings_localized
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (non-localized).
  """
  def admin_routes do
    quote do
      live "/admin/customer-service",
           PhoenixKit.Modules.CustomerService.Web.List,
           :index,
           as: :customer_service_index

      live "/admin/customer-service/tickets", PhoenixKit.Modules.CustomerService.Web.List, :index,
        as: :customer_service_list

      live "/admin/customer-service/tickets/new",
           PhoenixKit.Modules.CustomerService.Web.New,
           :new,
           as: :customer_service_new

      live "/admin/customer-service/tickets/:id",
           PhoenixKit.Modules.CustomerService.Web.Details,
           :show,
           as: :customer_service_details

      live "/admin/customer-service/tickets/:id/edit",
           PhoenixKit.Modules.CustomerService.Web.Edit,
           :edit,
           as: :customer_service_edit

      live "/admin/settings/customer-service",
           PhoenixKit.Modules.CustomerService.Web.Settings,
           :index,
           as: :customer_service_settings
    end
  end
end
