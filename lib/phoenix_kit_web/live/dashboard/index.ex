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
      |> assign(:project_title, PhoenixKit.Settings.get_project_title())

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {assigns}>
      <div class="flex flex-col items-center justify-center min-h-[60vh] text-center">
        <div class="max-w-2xl mx-auto">
          <h2 class="text-4xl font-bold text-base-content mb-4">
            {gettext("Welcome to your Dashboard")}
          </h2>
          <p class="text-lg text-base-content/70">
            {gettext(
              "Your personal dashboard is ready. Explore your account settings and manage your profile from here."
            )}
          </p>
        </div>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end
end
