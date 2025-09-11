defmodule PhoenixKitWeb.Integration do
  @moduledoc """
  Integration helpers for adding PhoenixKit to Phoenix applications.

  ## Basic Usage

  Add to your router:

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import PhoenixKitWeb.Integration

        # Add PhoenixKit routes
        phoenix_kit_routes()  # Default: /phoenix_kit prefix
      end

  ## Layout Integration

  Configure parent layouts in config.exs:

      config :phoenix_kit,
        repo: MyApp.Repo,
        layout: {MyAppWeb.Layouts, :app},
        root_layout: {MyAppWeb.Layouts, :root}

  ## Authentication Callbacks

  Use in your app's live_sessions:

  - `:phoenix_kit_mount_current_scope` - Mounts user and scope (recommended)
  - `:phoenix_kit_ensure_authenticated_scope` - Requires authentication
  - `:phoenix_kit_redirect_if_authenticated_scope` - Redirects if logged in

  ## Routes Created

  Authentication routes:
  - /users/register, /users/log-in, /users/magic-link
  - /users/settings, /users/reset-password, /users/confirm
  - /users/log-out (GET/DELETE)

  Admin routes (Owner/Admin only):
  - /admin/dashboard, /admin/users, /admin/roles
  - /admin/live_sessions, /admin/sessions
  - /admin/settings, /admin/modules

  ## DaisyUI Setup

  1. Install: `npm install daisyui@latest`
  2. Add to tailwind.config.js:
     - Content: `"../../deps/phoenix_kit"`
     - Plugin: `require('daisyui')`

  ## Layout Templates

  Use `{@inner_content}` not `render_slot(@inner_block)`:

      <!-- Correct -->
      <main>{@inner_content}</main>

  ## Scope Usage in Templates

      <%= if PhoenixKit.Users.Auth.Scope.authenticated?(@phoenix_kit_current_scope) do %>
        Welcome, {PhoenixKit.Users.Auth.Scope.user_email(@phoenix_kit_current_scope)}!
      <% end %>

  """
  defmacro phoenix_kit_routes() do
    url_prefix = PhoenixKit.Config.get_url_prefix()

    quote do
      # Define the auto-setup pipeline
      pipeline :phoenix_kit_auto_setup do
        plug PhoenixKitWeb.Integration, :phoenix_kit_auto_setup
      end

      pipeline :phoenix_kit_redirect_if_authenticated do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_user_is_authenticated
      end

      pipeline :phoenix_kit_require_authenticated do
        plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_require_authenticated_user
      end

      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup]

        post "/users/log-in", Users.SessionController, :create
        delete "/users/log-out", Users.SessionController, :delete
        get "/users/log-out", Users.SessionController, :get_logout
        get "/users/magic-link/:token", Users.MagicLinkController, :verify
      end

      # LiveView routes with proper authentication
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup]

        live_session :phoenix_kit_redirect_if_user_is_authenticated,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}] do
          # live "/test", TestLive, :index  # Moved to require_authenticated section
          live "/users/register", Users.RegistrationLive, :new
          live "/users/log-in", Users.LoginLive, :new
          live "/users/magic-link", Users.MagicLinkLive, :new
          live "/users/reset-password", Users.ForgotPasswordLive, :new
          live "/users/reset-password/:token", Users.ResetPasswordLive, :edit
        end

        live_session :phoenix_kit_current_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/users/confirm/:token", Users.ConfirmationLive, :edit
          live "/users/confirm", Users.ConfirmationInstructionsLive, :new
        end

        live_session :phoenix_kit_require_authenticated_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/users/settings", Users.SettingsLive, :edit
          live "/users/settings/confirm-email/:token", Users.SettingsLive, :confirm_email
        end

        live_session :phoenix_kit_admin,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/dashboard", Live.DashboardLive, :index
          live "/admin", Live.DashboardLive, :index
          live "/admin/users", Live.UsersLive, :index
          live "/admin/users/new", Users.UserFormLive, :new
          live "/admin/users/edit/:id", Users.UserFormLive, :edit
          live "/admin/roles", Live.RolesLive, :index
          live "/admin/live_sessions", Live.LiveSessionsLive, :index
          live "/admin/sessions", Live.SessionsLive, :index
          live "/admin/settings", Live.SettingsLive, :index
          live "/admin/modules", Live.ModulesLive, :index
          live "/admin/referral-codes", Live.ReferralCodesLive, :index
          live "/admin/referral-codes/new", Live.ReferralCodeFormLive, :new
          live "/admin/referral-codes/edit/:id", Live.ReferralCodeFormLive, :edit
        end
      end
    end
  end

  def init(opts) do
    opts
  end

  def call(conn, :phoenix_kit_auto_setup) do
    # Add backward compatibility for layouts that use render_slot(@inner_block)
    Plug.Conn.assign(conn, :inner_block, [])
  end
end
