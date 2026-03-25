defmodule <%= @web_module_prefix %>.PhoenixKit.Dashboard.<%= @page_name %> do
  @moduledoc """
  User dashboard LiveView for <%= @page_title %>.
  """

  use <%= @web_module_prefix %>, :live_view

  import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]
  import PhoenixKitWeb.Components.Core.UserDashboardHeader, only: [user_dashboard_header: 1]

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, gettext("<%= @page_title %>"))
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="max-w-7xl px-4 sm:px-6 lg:px-8">
        <.user_dashboard_header
          title={@page_title}
          subtitle={gettext("<%= @description %>")}
        />

        <div class="bg-base-100 shadow-sm rounded-lg p-6">
          <div class="prose prose-sm dark:prose-invert max-w-none">
            <p class="text-base-content/70">
              This is a template for your {@page_title} dashboard page.
              You can customize this page by modifying the LiveView module.
            </p>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end
end
