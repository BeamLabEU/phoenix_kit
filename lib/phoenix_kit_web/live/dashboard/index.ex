defmodule PhoenixKitWeb.Live.Dashboard.Index do
  @moduledoc """
  Dashboard Index LiveView for PhoenixKit.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Widgets.Loader

  @impl true
  def mount(_params, session, socket) do
    current_user = session["phoenix_kit_current_user"]

    if current_user do
      widgets = Loader.load_user_widgets(current_user)

      {:ok,
       socket
       |> assign(current_user: current_user, widgets: widgets, loading: false)}
    else
      {:error, :not_authenticated}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <header class="dashboard-header">
        <div>
          <h1>Welcome, {@current_user.email}</h1>
          <p class="subtitle">Your personalized dashboard</p>
        </div>
      </header>

      <div class="widgets-grid">
        <%= for widget <- @widgets do %>
          <div class="widget-wrapper" id={"widget-#{widget.id}"}>
            <.live_component
              module={widget.component}
              id={"component-#{widget.id}"}
              widget={widget}
              {widget.component_props}
            />
          </div>
        <% end %>

        <%= if Enum.empty?(@widgets) do %>
          <div class="empty-dashboard">
            <div class="empty-icon">
              <i class="icon-inbox"></i>
            </div>
            <h2>No Widgets Available</h2>
            <p>Enable modules in settings to see dashboard content.</p>
            <a href="/admin/modules" class="btn btn-primary">
              Manage Modules
            </a>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end
end
