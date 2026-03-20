defmodule PhoenixKitWeb.Live.Dashboard.Settings do
  @moduledoc """
  Settings LiveView for PhoenixKit Dashboard.

  Delegates all settings functionality to the `PhoenixKitWeb.Live.Components.UserSettings`
  LiveComponent, which can also be used standalone in parent apps.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Auth.update_user_email(socket.assigns.phoenix_kit_current_user, token) do
        :ok ->
          socket
          |> assign(:email_success_message, gettext("Email changed successfully."))

        :error ->
          socket
          |> assign(
            :email_error_message,
            gettext("Email change link is invalid or it has expired.")
          )
      end

    {:ok, push_navigate(socket, to: Routes.path("/dashboard/settings"))}
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Settings"))
      |> assign_new(:email_success_message, fn -> nil end)
      |> assign_new(:email_error_message, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def handle_info({:phoenix_kit_user_updated, updated_user}, socket) do
    {:noreply, assign(socket, :phoenix_kit_current_user, updated_user)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="p-6">
        <.admin_page_header
          back={Routes.path("/dashboard")}
          title="Settings"
          subtitle="Manage your account settings and preferences"
        />

        <.live_component
          module={PhoenixKitWeb.Live.Components.UserSettings}
          id="dashboard-user-settings"
          user={@phoenix_kit_current_user}
          email_success_message={@email_success_message}
          email_error_message={@email_error_message}
        />
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end
end
