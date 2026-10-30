defmodule PhoenixKitWeb.Live.Users.MyApiKeys do
  @moduledoc """
  "My API keys" — the signed-in person's own API keys, at `/profile/settings/api-keys`.

  Opens for a holder of the opt-in `api_personal_keys` permission or of `api`; anyone else
  is sent back to `/profile/settings`. The page only frames
  `PhoenixKitWeb.Live.Components.PersonalApiKeys`, which holds all the rules; this page
  hands it the session's scope and whether the session is borrowed
  (`PhoenixKitWeb.Users.MultiSession.impersonated?/1`, read from the session here).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Components.PersonalApiKeys
  alias PhoenixKitWeb.Users.MultiSession

  @impl true
  def mount(_params, session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if Scope.can?(scope, "api_personal_keys") or Scope.can?(scope, "api") do
      {:ok,
       socket
       |> assign(:page_title, gettext("My API keys"))
       |> assign(:page_section, gettext("Profile Settings"))
       |> assign(:page_section_path, Routes.path("/profile/settings"))
       |> assign(:project_title, Settings.get_project_title())
       |> assign(:url_path, Routes.path("/profile/settings/api-keys"))
       |> assign(:impersonated, MultiSession.impersonated?(session))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You don't have access to API keys."))
       |> redirect(to: Routes.path("/profile/settings"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      page_title={@page_title}
      page_subtitle={gettext("Keys that let programs and AI agents act with your rights")}
      page_section={@page_section}
      page_section_path={@page_section_path}
      current_path={@url_path}
      project_title={@project_title}
      current_locale={assigns[:current_locale]}
    >
      <div class="px-4 py-6">
        <PhoenixKitWeb.Components.ProfileSettingsTabs.profile_tabs
          active="api-keys"
          scope={@phoenix_kit_current_scope}
        />
        <.live_component
          module={PersonalApiKeys}
          id="personal-api-keys"
          scope={@phoenix_kit_current_scope}
          impersonated={@impersonated}
        />
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
