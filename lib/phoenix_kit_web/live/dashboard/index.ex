defmodule PhoenixKitWeb.Live.Dashboard.Index do
  @moduledoc """
  Dashboard Index LiveView for PhoenixKit.
  """
  use PhoenixKitWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Dashboard"))

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="max-w-7xl px-4 sm:px-6 lg:px-8">
        <.user_dashboard_header
          title={@page_title}
          subtitle={gettext("Welcome to your personal dashboard")}
        />

        <div class="bg-base-100 shadow-sm rounded-lg p-6">
          <div class="prose prose-sm dark:prose-invert max-w-none">
            <p class="text-base-content/70">
              {gettext(
                "Your personal dashboard is ready. Explore your account settings and manage your profile from here."
              )}
            </p>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end
end
