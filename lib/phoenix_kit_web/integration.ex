defmodule PhoenixKitWeb.Integration do
  alias PhoenixKit.Module.Languages

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

  ## Automatic Integration

  When you run `mix phoenix_kit.install`, the following is automatically added to your
  `:browser` pipeline:

      plug PhoenixKitWeb.Plugs.Integration

  This plug handles all PhoenixKit features including maintenance mode, and ensures
  they work across your entire application

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
  - /admin/dashboard, /admin/users, /admin/users/roles
  - /admin/users/live_sessions, /admin/users/sessions
  - /admin/settings, /admin/modules

  Public pages routes (if Pages module enabled):
  - {prefix}/pages/* (explicit prefix - e.g., /phoenix_kit/pages/test)
  - /* (catch-all at root level - e.g., /test, /blog/post)
  - Both routes serve published pages from priv/static/pages/*.md
  - The catch-all can optionally serve a custom 404 markdown file when enabled
  - Example: /test or /phoenix_kit/pages/test renders test.md

  ## DaisyUI Setup

  1. Install: `npm install daisyui@latest`
  2. Add to tailwind.config.js:
     - Content: `"../../deps/phoenix_kit"`
     - Plugin: `require('daisyui')`

  ## Layout Templates

  Use `{@inner_content}` not `render_slot(@inner_block)`:

      <%!-- Correct --%>
      <main>{@inner_content}</main>

  ## Scope Usage in Templates

      <%= if PhoenixKit.Users.Auth.Scope.authenticated?(@phoenix_kit_current_scope) do %>
        Welcome, {PhoenixKit.Users.Auth.Scope.user_email(@phoenix_kit_current_scope)}!
      <% end %>

  """

  @doc """
  Creates locale-aware routing scopes based on enabled languages.

  This macro generates both a localized scope (e.g., `/en/`) and a non-localized
  scope for backward compatibility. The locale pattern is dynamically generated
  from the database-stored enabled language codes.

  ## Examples

      locale_scope do
        live "/admin/dashboard", DashboardLive, :index
      end

      # Generates routes like:
      # /phoenix_kit/en/admin/dashboard (with locale)
      # /phoenix_kit/admin/dashboard (without locale, defaults to "en")
  """
  defmacro locale_scope(opts \\ [], do: block) do
    # Get URL prefix at compile time
    raw_prefix =
      try do
        PhoenixKit.Config.get_url_prefix()
      rescue
        _ -> "/phoenix_kit"
      end

    url_prefix =
      case raw_prefix do
        "" -> "/"
        prefix -> prefix
      end

    quote do
      alias PhoenixKit.Module.Languages

      # Get enabled locales at compile time with fallback
      enabled_locales =
        try do
          Languages.enabled_locale_codes()
        rescue
          # Fallback if module not available at compile time
          _ -> ["en"]
        end

      # Create regex pattern for enabled locales
      pattern = Enum.join(enabled_locales, "|")

      # Define locale validation pipeline
      pipeline :phoenix_kit_locale_validation do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_validate_and_set_locale
      end

      # Localized scope with locale parameter
      scope "#{unquote(url_prefix)}/:locale",
            PhoenixKitWeb,
            Keyword.put(unquote(opts), :locale, ~r/^(#{pattern})$/) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        unquote(block)
      end

      # Non-localized scope for backward compatibility (defaults to "en")
      scope unquote(url_prefix), PhoenixKitWeb, unquote(opts) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        unquote(block)
      end
    end
  end

  # Helper function to generate pipeline definitions
  defp generate_pipelines do
    quote do
      alias PhoenixKit.Module.Languages

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

      pipeline :phoenix_kit_admin_only do
        plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user
        plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_scope
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_require_admin
      end

      # Define locale validation pipeline
      pipeline :phoenix_kit_locale_validation do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_validate_and_set_locale
      end
    end
  end

  # Helper function to generate basic scope routes
  defp generate_basic_scope(url_prefix) do
    quote do
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup]

        post "/users/log-in", Users.Session, :create
        delete "/users/log-out", Users.Session, :delete
        get "/users/log-out", Users.Session, :get_logout
        get "/users/magic-link/:token", Users.MagicLinkVerify, :verify

        # OAuth routes for external provider authentication
        get "/users/auth/:provider", Users.OAuth, :request
        get "/users/auth/:provider/callback", Users.OAuth, :callback

        # Magic Link Registration routes
        get "/users/register/verify/:token", Users.MagicLinkRegistrationVerify, :verify

        # Email webhook endpoint (no authentication required)
        post "/webhooks/email", Controllers.EmailWebhookController, :handle

        # Pages routes temporarily disabled
        # get "/pages/*path", PagesController, :show

        # Storage API routes (file upload and serving)
        post "/api/upload", UploadController, :create
        get "/file/:file_id/:variant/:token", FileController, :show
        get "/api/files/:file_id/info", FileController, :info
      end

      # Public blog routes
      scope "/:language/blog", PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup]

        # Catch-all route for blog posts and listings
        get "/*path", BlogController, :show
      end

      # Email export routes (require admin or owner role)
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        get "/admin/emails/export", Controllers.EmailExportController, :export_logs
        get "/admin/emails/metrics/export", Controllers.EmailExportController, :export_metrics
        get "/admin/emails/blocklist/export", Controllers.EmailExportController, :export_blocklist
        get "/admin/emails/:id/export", Controllers.EmailExportController, :export_email_details
      end
    end
  end

  # Helper function to generate catch-all root route for pages
  # This allows accessing pages from the root level (e.g., /test, /blog/post)
  # Must be placed at the end of the router to not interfere with other routes
  defp generate_pages_catch_all do
    quote do
      # Catch-all route for published pages at root level
      # This route should be last to avoid conflicting with app routes
      # scope "/", PhoenixKitWeb do
      #   pipe_through [:browser, :phoenix_kit_auto_setup]
      #
      #   # Catch-all for root-level pages (must be last route)
      #   get "/*path", PagesController, :show
      # end
    end
  end

  # Helper function to generate localized routes
  defp generate_localized_routes(url_prefix, pattern) do
    quote do
      # Localized scope with locale parameter
      scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb,
        locale: ~r/^(#{unquote(pattern)})$/ do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        live_session :phoenix_kit_redirect_if_user_is_authenticated_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}] do
          live "/users/register", Users.Registration, :new, as: :user_registration

          live "/users/register/magic-link", Users.MagicLinkRegistrationRequest, :new,
            as: :user_magic_link_registration_request

          live "/users/register/complete/:token", Users.MagicLinkRegistration, :complete,
            as: :user_magic_link_registration

          live "/users/log-in", Users.Login, :new, as: :user_login
          live "/users/magic-link", Users.MagicLink, :new, as: :user_magic_link
          live "/users/reset-password", Users.ForgotPassword, :new, as: :user_reset_password

          live "/users/reset-password/:token", Users.ResetPassword, :edit,
            as: :user_reset_password_edit
        end

        live_session :phoenix_kit_current_user_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/users/confirm/:token", Users.Confirmation, :edit, as: :user_confirmation

          live "/users/confirm", Users.ConfirmationInstructions, :new,
            as: :user_confirmation_instructions
        end

        live_session :phoenix_kit_require_authenticated_user_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/users/settings", Users.Settings, :edit, as: :user_settings

          live "/users/settings/confirm-email/:token", Users.Settings, :confirm_email,
            as: :user_settings_confirm_email
        end

        live_session :phoenix_kit_admin_locale,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/dashboard", Live.Dashboard, :index
          live "/admin", Live.Dashboard, :index
          live "/admin/users", Live.Users.Users, :index
          live "/admin/users/new", Users.UserForm, :new, as: :user_form
          live "/admin/users/edit/:id", Users.UserForm, :edit, as: :user_form_edit
          live "/admin/users/roles", Live.Users.Roles, :index
          live "/admin/users/live_sessions", Live.Users.LiveSessions, :index
          live "/admin/users/sessions", Live.Users.Sessions, :index
          live "/admin/users/media", Live.Users.Media, :index
          live "/admin/settings", Live.Settings, :index
          live "/admin/settings/users", Live.Settings.Users, :index
          live "/admin/modules", Live.Modules, :index
          live "/admin/blogging", Live.Modules.Blogging.Index, :index
          live "/admin/blogging/:blog", Live.Modules.Blogging.Blog, :blog
          live "/admin/blogging/:blog/edit", Live.Modules.Blogging.Editor, :edit
          live "/admin/blogging/:blog/preview", Live.Modules.Blogging.Preview, :preview
          live "/admin/settings/blogging", Live.Modules.Blogging.Settings, :index
          # live "/admin/settings/pages", Live.Modules.Pages.Settings, :index
          live "/admin/settings/referral-codes", Live.Modules.ReferralCodes, :index
          live "/admin/settings/email-tracking", Live.Modules.Emails.EmailTracking, :index
          live "/admin/settings/languages", Live.Modules.Languages, :index

          live "/admin/settings/maintenance",
               Live.Modules.Maintenance.Settings,
               :index

          live "/admin/settings/storage", Live.Settings.Storage, :index
          live "/admin/settings/storage/buckets/new", Live.Settings.Storage.BucketForm, :new
          live "/admin/settings/storage/buckets/:id/edit", Live.Settings.Storage.BucketForm, :edit
          live "/admin/settings/storage/dimensions", Live.Settings.Storage.Dimensions, :index

          live "/admin/settings/storage/dimensions/new/image",
               Live.Settings.Storage.DimensionForm,
               :new_image

          live "/admin/settings/storage/dimensions/new/video",
               Live.Settings.Storage.DimensionForm,
               :new_video

          live "/admin/settings/storage/dimensions/:id/edit",
               Live.Settings.Storage.DimensionForm,
               :edit

          live "/admin/users/referral-codes", Live.Users.ReferralCodes, :index
          live "/admin/users/referral-codes/new", Live.Users.ReferralCodeForm, :new
          live "/admin/users/referral-codes/edit/:id", Live.Users.ReferralCodeForm, :edit
          live "/admin/emails/dashboard", Live.Modules.Emails.Metrics, :index
          live "/admin/emails", Live.Modules.Emails.Emails, :index
          live "/admin/emails/email/:id", Live.Modules.Emails.Details, :show
          live "/admin/emails/queue", Live.Modules.Emails.Queue, :index
          live "/admin/emails/blocklist", Live.Modules.Emails.Blocklist, :index

          # Entities Management
          live "/admin/entities", Live.Modules.Entities.Entities, :index, as: :entities
          live "/admin/entities/new", Live.Modules.Entities.EntityForm, :new, as: :entities_new

          live "/admin/entities/:id/edit", Live.Modules.Entities.EntityForm, :edit,
            as: :entities_edit

          live "/admin/entities/:entity_slug/data", Live.Modules.Entities.DataNavigator, :entity,
            as: :entities_data_entity

          live "/admin/entities/:entity_slug/data/new", Live.Modules.Entities.DataForm, :new,
            as: :entities_data_new

          live "/admin/entities/:entity_slug/data/:id", Live.Modules.Entities.DataForm, :show,
            as: :entities_data_show

          live "/admin/entities/:entity_slug/data/:id/edit",
               Live.Modules.Entities.DataForm,
               :edit,
               as: :entities_data_edit

          live "/admin/settings/entities", Live.Modules.Entities.EntitiesSettings, :index,
            as: :entities_settings

          # Pages Management
          # live "/admin/pages", Live.Modules.Pages.Pages, :index
          # live "/admin/pages/view", Live.Modules.Pages.View, :view
          # live "/admin/pages/edit", Live.Modules.Pages.Editor, :edit
        end
      end
    end
  end

  # Helper function to generate non-localized routes
  defp generate_non_localized_routes(url_prefix) do
    quote do
      # Non-localized scope for backward compatibility (defaults to "en")
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        live_session :phoenix_kit_redirect_if_user_is_authenticated,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}] do
          live "/users/register", Users.Registration, :new, as: :user_registration

          live "/users/register/magic-link", Users.MagicLinkRegistrationRequest, :new,
            as: :user_magic_link_registration_request

          live "/users/register/complete/:token", Users.MagicLinkRegistration, :complete,
            as: :user_magic_link_registration

          live "/users/log-in", Users.Login, :new, as: :user_login
          live "/users/magic-link", Users.MagicLink, :new, as: :user_magic_link
          live "/users/reset-password", Users.ForgotPassword, :new, as: :user_reset_password

          live "/users/reset-password/:token", Users.ResetPassword, :edit,
            as: :user_reset_password_edit
        end

        live_session :phoenix_kit_current_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/users/confirm/:token", Users.Confirmation, :edit, as: :user_confirmation

          live "/users/confirm", Users.ConfirmationInstructions, :new,
            as: :user_confirmation_instructions
        end

        live_session :phoenix_kit_require_authenticated_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/users/settings", Users.Settings, :edit, as: :user_settings

          live "/users/settings/confirm-email/:token", Users.Settings, :confirm_email,
            as: :user_settings_confirm_email
        end

        live_session :phoenix_kit_admin,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/dashboard", Live.Dashboard, :index
          live "/admin", Live.Dashboard, :index
          live "/admin/users", Live.Users.Users, :index
          live "/admin/users/new", Users.UserForm, :new, as: :user_form
          live "/admin/users/edit/:id", Users.UserForm, :edit, as: :user_form_edit
          live "/admin/users/roles", Live.Users.Roles, :index
          live "/admin/users/live_sessions", Live.Users.LiveSessions, :index
          live "/admin/users/sessions", Live.Users.Sessions, :index
          live "/admin/users/media", Live.Users.Media, :index
          live "/admin/settings", Live.Settings, :index
          live "/admin/settings/users", Live.Settings.Users, :index
          live "/admin/modules", Live.Modules, :index
          live "/admin/blogging", Live.Modules.Blogging.Index, :index
          live "/admin/blogging/:blog", Live.Modules.Blogging.Blog, :blog
          live "/admin/blogging/:blog/edit", Live.Modules.Blogging.Editor, :edit
          live "/admin/blogging/:blog/preview", Live.Modules.Blogging.Preview, :preview
          live "/admin/settings/blogging", Live.Modules.Blogging.Settings, :index
          # live "/admin/settings/pages", Live.Modules.Pages.Settings, :index
          live "/admin/settings/referral-codes", Live.Modules.ReferralCodes, :index
          live "/admin/settings/emails", Live.Modules.Emails.Settings, :index
          live "/admin/settings/languages", Live.Modules.Languages, :index

          live "/admin/settings/maintenance",
               Live.Modules.Maintenance.Settings,
               :index

          live "/admin/settings/storage", Live.Settings.Storage, :index
          live "/admin/settings/storage/buckets/new", Live.Settings.Storage.BucketForm, :new
          live "/admin/settings/storage/buckets/:id/edit", Live.Settings.Storage.BucketForm, :edit
          live "/admin/settings/storage/dimensions", Live.Settings.Storage.Dimensions, :index

          live "/admin/settings/storage/dimensions/new/image",
               Live.Settings.Storage.DimensionForm,
               :new_image

          live "/admin/settings/storage/dimensions/new/video",
               Live.Settings.Storage.DimensionForm,
               :new_video

          live "/admin/settings/storage/dimensions/:id/edit",
               Live.Settings.Storage.DimensionForm,
               :edit

          live "/admin/users/referral-codes/new", Live.Users.ReferralCodeForm, :new
          live "/admin/users/referral-codes/edit/:id", Live.Users.ReferralCodeForm, :edit
          live "/admin/emails/dashboard", Live.Modules.Emails.Metrics, :index
          live "/admin/emails", Live.Modules.Emails.Emails, :index
          live "/admin/emails/email/:id", Live.Modules.Emails.Details, :show
          live "/admin/emails/queue", Live.Modules.Emails.Queue, :index
          live "/admin/emails/blocklist", Live.Modules.Emails.Blocklist, :index

          # Email Templates Management
          live "/admin/modules/emails/templates", Live.Modules.Emails.Templates, :index
          live "/admin/modules/emails/templates/new", Live.Modules.Emails.TemplateEditor, :new

          live "/admin/modules/emails/templates/:id/edit",
               Live.Modules.Emails.TemplateEditor,
               :edit

          # Entities Management
          live "/admin/entities", Live.Modules.Entities.Entities, :index, as: :entities
          live "/admin/entities/new", Live.Modules.Entities.EntityForm, :new, as: :entities_new

          live "/admin/entities/:id/edit", Live.Modules.Entities.EntityForm, :edit,
            as: :entities_edit

          live "/admin/entities/:entity_slug/data", Live.Modules.Entities.DataNavigator, :entity,
            as: :entities_data_entity

          live "/admin/entities/:entity_slug/data/new", Live.Modules.Entities.DataForm, :new,
            as: :entities_data_new

          live "/admin/entities/:entity_slug/data/:id", Live.Modules.Entities.DataForm, :show,
            as: :entities_data_show

          live "/admin/entities/:entity_slug/data/:id/edit",
               Live.Modules.Entities.DataForm,
               :edit,
               as: :entities_data_edit

          live "/admin/settings/entities", Live.Modules.Entities.EntitiesSettings, :index,
            as: :entities_settings

          # Pages Management
          # live "/admin/pages", Live.Modules.Pages.Pages, :index
          # live "/admin/pages/view", Live.Modules.Pages.View, :view
          # live "/admin/pages/edit", Live.Modules.Pages.Editor, :edit
        end
      end
    end
  end

  defmacro phoenix_kit_routes do
    # OAuth configuration is handled by PhoenixKit.Workers.OAuthConfigLoader
    # which runs synchronously during supervisor startup
    # No need for async spawn() here anymore

    # Get URL prefix at compile time and handle empty string case for router compatibility
    raw_prefix =
      try do
        PhoenixKit.Config.get_url_prefix()
      rescue
        # Fallback if config not available at compile time
        _ -> "/phoenix_kit"
      end

    url_prefix =
      case raw_prefix do
        "" -> "/"
        prefix -> prefix
      end

    # Get enabled locales at compile time with fallback
    enabled_locales =
      try do
        Languages.enabled_locale_codes()
      rescue
        # Fallback if module not available at compile time
        _ -> ["en"]
      end

    # Create regex pattern for enabled locales
    pattern = Enum.join(enabled_locales, "|")

    quote do
      # Generate pipeline definitions
      unquote(generate_pipelines())

      # Generate basic routes scope
      unquote(generate_basic_scope(url_prefix))

      # Generate localized routes
      unquote(generate_localized_routes(url_prefix, pattern))

      # Generate non-localized routes
      unquote(generate_non_localized_routes(url_prefix))

      # Generate catch-all route for pages at root level (must be last)
      unquote(generate_pages_catch_all())
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
