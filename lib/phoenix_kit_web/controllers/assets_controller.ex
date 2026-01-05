defmodule PhoenixKitWeb.AssetsController do
  @moduledoc """
  Controller for serving PhoenixKit static assets.

  This controller provides access to PhoenixKit's static assets (JS, CSS)
  for parent applications that don't have direct access to PhoenixKit's
  priv/static directory.
  """
  use PhoenixKitWeb, :controller

  @valid_assets %{
    "phoenix_kit_consent.js" => {"application/javascript", "phoenix_kit_consent.js"},
    "phoenix_kit_daisyui5.js" => {"application/javascript", "phoenix_kit_daisyui5.js"},
    "phoenix_kit_daisyui5.css" => {"text/css", "phoenix_kit_daisyui5.css"}
  }

  @doc """
  Serves PhoenixKit's static JS/CSS files.

  Available assets:
  - phoenix_kit_consent.js - Cookie consent widget script
  - phoenix_kit_daisyui5.js - DaisyUI 5 theme controller
  - phoenix_kit_daisyui5.css - DaisyUI 5 styles
  """
  def serve(conn, %{"file" => file}) do
    case Map.get(@valid_assets, file) do
      {content_type, filename} ->
        asset_path = Application.app_dir(:phoenix_kit, "priv/static/assets/#{filename}")

        if File.exists?(asset_path) do
          content = File.read!(asset_path)

          conn
          |> put_resp_content_type(content_type)
          |> put_resp_header("cache-control", "public, max-age=86400")
          |> send_resp(200, content)
        else
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(404, "Asset not found")
        end

      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Invalid asset")
    end
  end
end
