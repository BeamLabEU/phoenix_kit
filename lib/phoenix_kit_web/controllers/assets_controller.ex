defmodule PhoenixKitWeb.AssetsController do
  @moduledoc """
  Controller for serving PhoenixKit static assets.

  This controller provides access to PhoenixKit's static assets (JS, CSS)
  for parent applications that don't have direct access to PhoenixKit's
  priv/static directory.
  """
  use PhoenixKitWeb, :controller

  @valid_assets %{
    "phoenix_kit_daisyui5.css" => {"text/css", :phoenix_kit, "phoenix_kit_daisyui5.css"},
    "phoenix_kit_consent.js" =>
      {"application/javascript", :phoenix_kit_legal, "phoenix_kit_consent.js"}
  }

  @doc """
  Serves PhoenixKit's static JS/CSS files.

  Available assets:
  - phoenix_kit_daisyui5.css - DaisyUI 5 styles
  - phoenix_kit_consent.js  - Legal consent banner (from phoenix_kit_legal package)
  - etcher-offline-sw.js    - Etcher's offline service worker, while
    `PhoenixKit.Offline.enabled?/0`
  """
  # Etcher's offline service worker (`PhoenixKit.Offline`). `no-cache`: the
  # browser checks a worker for a new version on every navigation, and a
  # cached copy would pin an old one. `service-worker-allowed`: registered for
  # the whole site from this URL; it still answers only for the pages and
  # files a viewer asked it to keep. 404 while offline annotating is off.
  def serve(conn, %{"file" => "etcher-offline-sw.js"}) do
    if PhoenixKit.Offline.enabled?() and function_exported?(Etcher, :offline_worker, 0) do
      conn
      |> put_resp_content_type("text/javascript")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("service-worker-allowed", "/")
      |> send_resp(200, Etcher.offline_worker())
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Asset not found")
    end
  end

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
