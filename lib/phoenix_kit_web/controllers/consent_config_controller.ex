defmodule PhoenixKitWeb.Controllers.ConsentConfigController do
  @moduledoc """
  API controller for cookie consent widget configuration.

  Returns the consent widget configuration as JSON for client-side initialization.
  This allows the JavaScript widget to automatically inject itself into any page
  without requiring changes to the parent application's layout.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Legal

  @doc """
  Returns the consent widget configuration as JSON.

  Response format:
  ```json
  {
    "enabled": true,
    "frameworks": ["gdpr"],
    "icon_position": "bottom-right",
    "policy_version": "1.0",
    "cookie_policy_url": "/phoenix_kit/legal/cookie-policy",
    "privacy_policy_url": "/phoenix_kit/legal/privacy-policy",
    "google_consent_mode": false,
    "show_icon": true
  }
  ```
  """
  def config(conn, _params) do
    config = Legal.get_consent_widget_config()

    conn
    |> put_resp_header("cache-control", "public, max-age=60")
    |> json(config)
  end
end
