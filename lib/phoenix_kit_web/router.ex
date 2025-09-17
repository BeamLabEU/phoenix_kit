defmodule PhoenixKitWeb.Router do
  use PhoenixKitWeb, :router

  import PhoenixKitWeb.Integration
  import PhoenixKitWeb.Users.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: PhoenixKit.LayoutConfig.get_root_layout()
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_phoenix_kit_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PhoenixKitWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  phoenix_kit_routes()

  # Other scopes may use custom stacks.
  # scope "/api", PhoenixKitWeb do
  #   pipe_through :api
  # end

  # LiveDashboard routes removed - this is a library module
  # Parent applications should include their own LiveDashboard configuration

  ## Authentication routes are now handled by AuthRouter via forward
  ## All PhoenixKit routes are available under your configured URL prefix (default: /phoenix_kit/)
end
