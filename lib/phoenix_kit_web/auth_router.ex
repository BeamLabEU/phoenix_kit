defmodule PhoenixKitWeb.AuthRouter do
  @moduledoc """
  Legacy authentication router for PhoenixKit.

  **DEPRECATED**: This module is kept for backward compatibility.
  Use `PhoenixKitWeb.Integration.phoenix_kit_routes/0` macro instead.

  This router provides basic forwarding to authentication routes but lacks
  the advanced features and proper pipeline configuration of the Integration module.

  ## Migration Path

  Replace usage of this router with the Integration macro:

      # Instead of:
      forward "/auth", PhoenixKitWeb.AuthRouter

      # Use:
      import PhoenixKitWeb.Integration
      phoenix_kit_routes()
  """
  use Phoenix.Router
  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
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

  pipeline :phoenix_kit_redirect_if_authenticated do
    plug PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_user_is_authenticated
  end

  pipeline :require_authenticated do
    plug PhoenixKitWeb.Users.Auth, :phoenix_kit_require_authenticated_user
  end

  scope "/" do
    pipe_through [:browser, :phoenix_kit_redirect_if_authenticated]

    # Test LiveView routes moved to integration.ex for proper parent app support

    # LiveView routes for authentication
    live "/register", PhoenixKitWeb.Users.Registration, :new, as: :user_registration
    live "/log_in", PhoenixKitWeb.Users.Login, :new, as: :user_login

    post "/log_in", PhoenixKitWeb.Users.Session, :create

    live "/reset_password", PhoenixKitWeb.Users.ForgotPassword, :new, as: :user_reset_password

    live "/reset_password/:token", PhoenixKitWeb.Users.ResetPassword, :edit,
      as: :user_reset_password
  end

  scope "/" do
    pipe_through [:browser]

    delete "/log_out", PhoenixKitWeb.Users.Session, :delete
    get "/log_out", PhoenixKitWeb.Users.Session, :get_logout

    live "/confirm/:token", PhoenixKitWeb.Users.Confirmation, :edit, as: :user_confirmation

    live "/confirm", PhoenixKitWeb.Users.ConfirmationInstructions, :new,
      as: :user_confirmation_instructions
  end

  if PhoenixKit.Config.user_dashboard_enabled?() do
    scope "/" do
      pipe_through [:browser, :require_authenticated]

      live "/settings", PhoenixKitWeb.Live.Dashboard.Settings, :edit, as: :user_settings

      live "/settings/confirm_email/:token",
           PhoenixKitWeb.Live.Dashboard.Settings,
           :confirm_email,
           as: :user_settings
    end
  end
end
