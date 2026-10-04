defmodule PhoenixKitWeb.Live.Users.ProfileSettings do
  @moduledoc """
  "Profile Settings" — the signed-in user's own account page.

  Email, password, connected OAuth accounts, active sessions and the rest of
  the personal account surface, all delegated to the
  `PhoenixKitWeb.Live.Components.UserSettings` LiveComponent (the same one
  parent apps can embed standalone).

  Served at `/profile/settings/<tab>` (`PhoenixKitWeb.Components.ProfileSettingsTabs`),
  in both the locale-prefixed and prefixless shapes the `locale_scope` macro
  emits; the bare `/profile/settings` opens the first tab. Replaces
  `/dashboard/settings`, which still routes but redirects here.

  Why a page of its own rather than another dashboard tab: the user dashboard
  is optional — a host can compile it out with `user_dashboard_enabled` — so
  hanging the account UI off it meant the only way to change your own email
  could vanish. This page is unconditional and wears
  `LayoutWrapper.app_layout`, so it renders the same whether it is reached
  from the admin header or from the host's own front end.

  Hosts that would rather own this surface set the `user_settings_path`
  setting; every menu entry resolves through
  `PhoenixKit.Utils.Routes.user_settings_path/1` and follows it there.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  alias PhoenixKitWeb.Components.ProfileSettingsTabs

  # Landing from the confirmation link in a change-email message. The token is
  # spent here and the result carried into the page as a message, then the URL
  # is replaced with the bare settings path so a refresh (or a shared link)
  # does not re-submit a token that is already used.
  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Auth.update_user_email(socket.assigns.phoenix_kit_current_user, token) do
        :ok ->
          assign(socket, :email_success_message, gettext("Email changed successfully."))

        :error ->
          assign(
            socket,
            :email_error_message,
            gettext("Email change link is invalid or it has expired.")
          )
      end

    {:ok, push_navigate(socket, to: Routes.path("/profile/settings"))}
  end

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Profile Settings"))
     |> assign(:project_title, Settings.get_project_title())
     # Raw session token of this browser — lets the Active Sessions section
     # mark the current device and keep it signed in on "sign out others".
     |> assign(:current_session_token, session["user_token"])
     |> assign_new(:email_success_message, fn -> nil end)
     |> assign_new(:email_error_message, fn -> nil end)}
  end

  # The tab comes from the URL. One that is not offered here (unknown, or
  # the integrations tab, which is a LiveView of its own) goes to the first.
  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || ProfileSettingsTabs.default_tab()

    if ProfileSettingsTabs.rendered_here?(tab) and
         tab in ProfileSettingsTabs.tab_ids(socket.assigns[:phoenix_kit_current_scope]) do
      {:noreply,
       socket
       |> assign(:tab, tab)
       |> assign(:sections, ProfileSettingsTabs.sections(tab) || [])
       |> assign(:url_path, ProfileSettingsTabs.path(tab))}
    else
      {:noreply,
       push_patch(socket, to: ProfileSettingsTabs.path(ProfileSettingsTabs.default_tab()))}
    end
  end

  # Broadcast by the account context whenever this user's row changes (here or
  # in another tab), so the form redraws against the saved values.
  @impl true
  def handle_info({:phoenix_kit_user_updated, updated_user}, socket) do
    {:noreply, assign(socket, :phoenix_kit_current_user, updated_user)}
  end
end
