defmodule PhoenixKitWeb.Controllers.ConsentConfigController do
  @moduledoc """
  API controller for cookie consent widget configuration.

  Returns the consent widget configuration as JSON for client-side initialization.
  This allows the JavaScript widget to automatically inject itself into any page
  without requiring changes to the parent application's layout.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Users.Auth.Scope

  @doc """
  Returns the consent widget configuration as JSON.

  Response format:
  ```json
  {
    "enabled": true,
    "consent_mode": "strict",
    "frameworks": ["gdpr"],
    "icon_position": "bottom-right",
    "policy_version": "1.0",
    "cookie_policy_url": "/phoenix_kit/legal/cookie-policy",
    "privacy_policy_url": "/phoenix_kit/legal/privacy-policy",
    "google_consent_mode": false,
    "hide_for_authenticated": false,
    "is_authenticated": false,
    "show_icon": true
  }
  ```
  """
  def config(conn, _params) do
    config = Legal.get_consent_widget_config()

    # Check if user is authenticated
    is_authenticated = user_authenticated?(conn)

    # Determine if widget should be shown
    should_show =
      config.enabled and
        not (config.hide_for_authenticated and is_authenticated)

    response =
      config
      |> Map.put(:is_authenticated, is_authenticated)
      |> Map.put(:should_show, should_show)

    # Use private cache if hide_for_authenticated is enabled
    cache_header =
      if config.hide_for_authenticated do
        "private, max-age=0"
      else
        "public, max-age=60"
      end

    conn
    |> put_resp_header("cache-control", cache_header)
    |> json(response)
  end

  defp user_authenticated?(conn) do
    # Check for PhoenixKit user in assigns
    case conn.assigns do
      %{phoenix_kit_current_user: user} when not is_nil(user) ->
        true

      %{phoenix_kit_current_scope: scope} when not is_nil(scope) ->
        Scope.authenticated?(scope)

      _ ->
        false
    end
  end
end
