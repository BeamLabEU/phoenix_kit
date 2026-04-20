defmodule PhoenixKitWeb.AssetsController do
  @moduledoc """
  Controller for serving PhoenixKit static assets.

  This controller provides access to PhoenixKit's static assets (JS, CSS)
  for parent applications that don't have direct access to PhoenixKit's
  priv/static directory.
  """
  use PhoenixKitWeb, :controller

  @valid_assets %{
    "phoenix_kit_daisyui5.js" =>
      {"application/javascript", :phoenix_kit, "phoenix_kit_daisyui5.js"},
    "phoenix_kit_daisyui5.css" => {"text/css", :phoenix_kit, "phoenix_kit_daisyui5.css"},
    "phoenix_kit_consent.js" =>
      {"application/javascript", :phoenix_kit_legal, "phoenix_kit_consent.js"}
  }

  @doc """
  Serves PhoenixKit's static JS/CSS files.

  Available assets:
  - phoenix_kit_daisyui5.js - DaisyUI 5 theme controller
  - phoenix_kit_daisyui5.css - DaisyUI 5 styles
  - phoenix_kit_consent.js  - Legal consent banner (from phoenix_kit_legal package)
  """
  def serve(conn, %{"file" => file}) do
    case Map.get(@valid_assets, file) do
      {content_type, app, filename} ->
        asset_path =
          try do
            Application.app_dir(app, "priv/static/assets/#{filename}")
          rescue
            ArgumentError -> nil
          end

        if asset_path && File.exists?(asset_path) do
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
