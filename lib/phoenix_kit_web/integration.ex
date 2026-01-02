# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
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
  - /users/reset-password, /users/confirm
  - /users/log-out (GET/DELETE)

  User dashboard routes (if enabled, default: true):
  - /dashboard, /dashboard/settings
  - /dashboard/settings/confirm-email/:token

  Admin routes (Owner/Admin only):
  - /admin, /admin/users, /admin/users/roles
  - /admin/users/live_sessions, /admin/users/sessions
  - /admin/settings, /admin/modules

  Public pages routes (if Pages module enabled):
  - {prefix}/pages/* (explicit prefix - e.g., /phoenix_kit/pages/test)
  - /* (catch-all at root level - e.g., /test, /blog/post)
  - Both routes serve published pages from priv/static/pages/*.md
  - The catch-all can optionally serve a custom 404 markdown file when enabled
  - Example: /test or /phoenix_kit/pages/test renders test.md

  ## Configuration

  You can disable the user dashboard by setting the environment variable in your config:

      # config/dev.exs or config/runtime.exs
      config :phoenix_kit, user_dashboard_enabled: false

  This will disable all dashboard routes (/dashboard/*). Users trying to access
  the dashboard will get a 404 error.

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
        live "/admin", DashboardLive, :index
      end

      # Generates routes like:
      # /phoenix_kit/en/admin (with locale)
      # /phoenix_kit/admin (without locale, defaults to "en")
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
      alias PhoenixKit.Modules.Languages

      # Define locale validation pipeline
      pipeline :phoenix_kit_locale_validation do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_validate_and_set_locale
      end

      # Localized scope with flexible locale pattern
      # Accepts both base codes (en, es) and full dialect codes (en-US, es-MX)
      # Full dialect codes are automatically redirected to base codes by the validation plug
      # This ensures backward compatibility with old URLs while enforcing base code standard
      scope "#{unquote(url_prefix)}/:locale",
            PhoenixKitWeb,
            Keyword.put(unquote(opts), :locale, ~r/^[a-z]{2}(?:-[A-Za-z0-9]{2,})?$/) do
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
      alias PhoenixKit.Modules.Languages

      # Define the auto-setup pipeline
      pipeline :phoenix_kit_auto_setup do
        plug PhoenixKitWeb.Plugs.RequestTimer
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

      # Define API pipeline for JSON endpoints
      pipeline :phoenix_kit_api do
        plug :accepts, ["json"]
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

        # Billing webhook endpoints (no authentication - verified via signature)
        post "/webhooks/billing/stripe", Controllers.BillingWebhookController, :stripe
        post "/webhooks/billing/paypal", Controllers.BillingWebhookController, :paypal
        post "/webhooks/billing/razorpay", Controllers.BillingWebhookController, :razorpay

        # Storage API routes (file upload and serving)
        post "/api/upload", UploadController, :create
        get "/file/:file_id/:variant/:token", FileController, :show
        get "/api/files/:file_id/info", FileController, :info

        # Sitemap routes (public, no authentication required)
        get "/sitemap.xml", SitemapController, :xml
        get "/sitemap.html", SitemapController, :html
        get "/sitemaps/:index", SitemapController, :index_part
        get "/sitemap.xsl", SitemapController, :xsl_stylesheet
        get "/assets/sitemap/:style", SitemapController, :xsl_stylesheet

        # Cookie consent widget config (public API for JS auto-injection)
        get "/api/consent-config", Controllers.ConsentConfigController, :config

        # Pages routes temporarily disabled
        # get "/pages/*path", PagesController, :show
      end

      # DB Sync API routes (JSON API - accepts JSON from remote PhoenixKit sites)
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:phoenix_kit_api]

        post "/db-sync/api/register-connection",
             Controllers.DBSyncApiController,
             :register_connection

        post "/db-sync/api/delete-connection",
             Controllers.DBSyncApiController,
             :delete_connection

        post "/db-sync/api/verify-connection",
             Controllers.DBSyncApiController,
             :verify_connection

        post "/db-sync/api/update-status",
             Controllers.DBSyncApiController,
             :update_status

        post "/db-sync/api/get-connection-status",
             Controllers.DBSyncApiController,
             :get_connection_status

        post "/db-sync/api/list-tables",
             Controllers.DBSyncApiController,
             :list_tables

        post "/db-sync/api/pull-data",
             Controllers.DBSyncApiController,
             :pull_data

        post "/db-sync/api/table-schema",
             Controllers.DBSyncApiController,
             :table_schema

        post "/db-sync/api/table-records",
             Controllers.DBSyncApiController,
             :table_records

        get "/db-sync/api/status", Controllers.DBSyncApiController, :status
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

  # ============================================================================
  # Shared Route Definitions
  # ============================================================================
  # These macros generate route definitions that are shared between localized
  # and non-localized scopes. This eliminates code duplication and reduces
  # compile time by ~50% for router files.
  # ============================================================================

  # Generates authentication routes (register, login, magic-link, reset-password)
  defmacro phoenix_kit_auth_routes(suffix) do
    session_name = :"phoenix_kit_redirect_if_user_is_authenticated#{suffix}"

    quote do
      live_session unquote(session_name),
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
    end
  end

  # Generates user confirmation routes
  defmacro phoenix_kit_confirmation_routes(suffix) do
    session_name = :"phoenix_kit_current_user#{suffix}"

    quote do
      live_session unquote(session_name),
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
        live "/users/confirm/:token", Users.Confirmation, :edit, as: :user_confirmation

        live "/users/confirm", Users.ConfirmationInstructions, :new,
          as: :user_confirmation_instructions
      end
    end
  end

  # Generates all admin routes
  defmacro phoenix_kit_admin_routes(suffix) do
    session_name = :"phoenix_kit_admin#{suffix}"

    quote do
      live_session unquote(session_name),
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
        live "/admin", Live.Dashboard, :index
        live "/admin/users", Live.Users.Users, :index
        live "/admin/users/new", Users.UserForm, :new, as: :user_form
        live "/admin/users/edit/:id", Users.UserForm, :edit, as: :user_form_edit
        live "/admin/users/view/:id", Live.Users.UserDetails, :show
        live "/admin/users/roles", Live.Users.Roles, :index
        live "/admin/users/live_sessions", Live.Users.LiveSessions, :index
        live "/admin/users/sessions", Live.Users.Sessions, :index
        live "/admin/media", Live.Users.Media, :index
        live "/admin/media/:file_id", Live.Users.MediaDetail, :show
        live "/admin/media/selector", Live.Users.MediaSelector, :index
        live "/admin/settings", Live.Settings, :index
        live "/admin/settings/users", Live.Settings.Users, :index
        live "/admin/modules", Live.Modules, :index
        live "/admin/blogging", Live.Modules.Blogging.Index, :index
        live "/admin/blogging/:blog", Live.Modules.Blogging.Blog, :blog
        live "/admin/blogging/:blog/edit", Live.Modules.Blogging.Editor, :edit
        live "/admin/blogging/:blog/preview", Live.Modules.Blogging.Preview, :preview
        live "/admin/settings/blogging", Live.Modules.Blogging.Settings, :index
        live "/admin/settings/blogging/new", Live.Modules.Blogging.New, :new
        live "/admin/settings/blogging/:blog/edit", Live.Modules.Blogging.Edit, :edit

        # Posts module routes
        live "/admin/posts", Live.Modules.Posts.Posts, :index
        live "/admin/posts/new", Live.Modules.Posts.Edit, :new
        live "/admin/posts/groups", Live.Modules.Posts.Groups, :index
        live "/admin/posts/groups/new", Live.Modules.Posts.GroupEdit, :new
        live "/admin/posts/groups/:id/edit", Live.Modules.Posts.GroupEdit, :edit
        live "/admin/posts/:id", Live.Modules.Posts.Details, :show
        live "/admin/posts/:id/edit", Live.Modules.Posts.Edit, :edit
        live "/admin/settings/posts", Live.Modules.Posts.Settings, :index

        live "/admin/settings/referral-codes", Live.Modules.ReferralCodes, :index
        live "/admin/settings/emails", Live.Modules.Emails.Settings, :index
        live "/admin/settings/languages", Live.Modules.Languages, :index
        live "/admin/settings/legal", Live.Modules.Legal.Settings, :index

        live "/admin/settings/maintenance",
             Live.Modules.Maintenance.Settings,
             :index

        live "/admin/settings/seo", Live.Settings.SEO, :index
        live "/admin/settings/sitemap", Live.Modules.Sitemaps.Settings, :index

        live "/admin/settings/media", Live.Modules.Storage.Settings, :index
        live "/admin/settings/media/buckets/new", Live.Modules.Storage.BucketForm, :new
        live "/admin/settings/media/buckets/:id/edit", Live.Modules.Storage.BucketForm, :edit
        live "/admin/settings/media/dimensions", Live.Modules.Storage.Dimensions, :index

        live "/admin/settings/media/dimensions/new/image",
             Live.Modules.Storage.DimensionForm,
             :new_image

        live "/admin/settings/media/dimensions/new/video",
             Live.Modules.Storage.DimensionForm,
             :new_video

        live "/admin/settings/media/dimensions/:id/edit",
             Live.Modules.Storage.DimensionForm,
             :edit

        live "/admin/users/referral-codes", Live.Users.ReferralCodes, :index
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

        # Jobs
        live "/admin/jobs", Live.Modules.Jobs.Index, :index

        # Billing Management
        live "/admin/billing", Live.Modules.Billing.Index, :index
        live "/admin/billing/orders", Live.Modules.Billing.Orders, :index
        live "/admin/billing/orders/new", Live.Modules.Billing.OrderForm, :new
        live "/admin/billing/orders/:id", Live.Modules.Billing.OrderDetail, :show
        live "/admin/billing/orders/:id/edit", Live.Modules.Billing.OrderForm, :edit
        live "/admin/billing/invoices", Live.Modules.Billing.Invoices, :index
        live "/admin/billing/invoices/:id", Live.Modules.Billing.InvoiceDetail, :show
        live "/admin/billing/invoices/:id/print", Live.Modules.Billing.InvoicePrint, :print
        live "/admin/billing/invoices/:id/receipt", Live.Modules.Billing.ReceiptPrint, :receipt

        live "/admin/billing/invoices/:id/credit-note/:transaction_id",
             Live.Modules.Billing.CreditNotePrint,
             :credit_note

        live "/admin/billing/invoices/:id/payment/:transaction_id",
             Live.Modules.Billing.PaymentConfirmationPrint,
             :payment_confirmation

        live "/admin/billing/transactions", Live.Modules.Billing.Transactions, :index
        live "/admin/billing/subscriptions", Live.Modules.Billing.Subscriptions, :index
        live "/admin/billing/subscriptions/new", Live.Modules.Billing.SubscriptionForm, :new

        live "/admin/billing/subscriptions/:id",
             Live.Modules.Billing.SubscriptionDetail,
             :show

        live "/admin/billing/plans", Live.Modules.Billing.SubscriptionPlans, :index
        live "/admin/billing/plans/new", Live.Modules.Billing.SubscriptionPlanForm, :new
        live "/admin/billing/plans/:id/edit", Live.Modules.Billing.SubscriptionPlanForm, :edit
        live "/admin/billing/profiles", Live.Modules.Billing.BillingProfiles, :index
        live "/admin/billing/profiles/new", Live.Modules.Billing.BillingProfileForm, :new
        live "/admin/billing/profiles/:id/edit", Live.Modules.Billing.BillingProfileForm, :edit
        live "/admin/billing/currencies", Live.Modules.Billing.Currencies, :index
        live "/admin/settings/billing", Live.Modules.Billing.Settings, :settings
        live "/admin/settings/billing/providers", Live.Modules.Billing.ProviderSettings, :index

        # AI Module
        live "/admin/ai", Live.Modules.AI.Endpoints, :index
        live "/admin/ai/endpoints", Live.Modules.AI.Endpoints, :endpoints
        live "/admin/ai/usage", Live.Modules.AI.Endpoints, :usage
        live "/admin/ai/endpoints/new", Live.Modules.AI.EndpointForm, :new
        live "/admin/ai/endpoints/:id/edit", Live.Modules.AI.EndpointForm, :edit
        live "/admin/ai/prompts", Live.Modules.AI.Prompts, :index
        live "/admin/ai/prompts/new", Live.Modules.AI.PromptForm, :new
        live "/admin/ai/prompts/:id/edit", Live.Modules.AI.PromptForm, :edit

        # DB Sync Module (permanent connections only)
        live "/admin/db-sync", Live.Modules.DBSync.Index, :index
        live "/admin/db-sync/connections", Live.Modules.DBSync.ConnectionsLive, :index
        live "/admin/db-sync/history", Live.Modules.DBSync.History, :index

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
      end
    end
  end

  # Generates user dashboard routes (conditional on config)
  defmacro phoenix_kit_dashboard_routes(suffix) do
    session_name = :"phoenix_kit_user_dashboard#{suffix}"

    quote do
      if unquote(PhoenixKit.Config.user_dashboard_enabled?()) do
        live_session unquote(session_name),
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/dashboard", Live.Dashboard.Index, :index
          live "/dashboard/settings", Live.Dashboard.Settings, :edit

          live "/dashboard/settings/confirm-email/:token",
               Live.Dashboard.Settings,
               :confirm_email
        end
      end
    end
  end

  # ============================================================================
  # Route Scope Generators
  # ============================================================================

  # Helper function to generate localized routes
  defp generate_localized_routes(url_prefix, pattern) do
    quote do
      # Localized scope with locale parameter
      scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb,
        locale: ~r/^(#{unquote(pattern)})$/ do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        phoenix_kit_auth_routes(:_locale)
        phoenix_kit_confirmation_routes(:_locale)
        phoenix_kit_admin_routes(:_locale)
        phoenix_kit_dashboard_routes(:_locale)
      end
    end
  end

  # Helper function to generate non-localized routes
  defp generate_non_localized_routes(url_prefix) do
    quote do
      # Non-localized scope for backward compatibility (defaults to "en")
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        phoenix_kit_auth_routes(:"")
        phoenix_kit_confirmation_routes(:"")
        phoenix_kit_admin_routes(:"")
        phoenix_kit_dashboard_routes(:"")
      end
    end
  end

  defp generate_blog_routes(url_prefix) do
    quote do
      # Multi-language blog routes with language prefix
      blog_scope_multi =
        case unquote(url_prefix) do
          "/" -> "/:language"
          prefix -> "#{prefix}/:language"
        end

      scope blog_scope_multi, PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        # Exclude admin paths from blogging catch-all routes
        get "/:blog", BlogController, :show, constraints: %{"blog" => ~r/^(?!admin$)/}
        get "/:blog/*path", BlogController, :show, constraints: %{"blog" => ~r/^(?!admin$)/}
      end

      # Non-localized blog routes (for when url_prefix is "/")
      blog_scope_non_localized =
        case unquote(url_prefix) do
          "/" -> "/"
          prefix -> prefix
        end

      scope blog_scope_non_localized, PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        # Exclude admin paths from blogging catch-all routes
        # Language detection is handled in the controller by checking if content exists
        get "/:blog", BlogController, :show, constraints: %{"blog" => ~r/^(?!admin$)/}
        get "/:blog/*path", BlogController, :show, constraints: %{"blog" => ~r/^(?!admin$)/}
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

    # Use a generic locale pattern that accepts any valid language code format
    # This allows switching to any of the 80+ predefined languages
    # Actual validation of whether the locale is supported happens in the validation plug
    pattern = "[a-z]{2}(?:-[A-Za-z0-9]{2,})?"

    quote do
      # Generate pipeline definitions
      unquote(generate_pipelines())

      # Generate basic routes scope
      unquote(generate_basic_scope(url_prefix))

      # Generate localized routes
      unquote(generate_localized_routes(url_prefix, pattern))

      # Generate non-localized routes
      unquote(generate_non_localized_routes(url_prefix))

      # Generate blog routes (after other routes to prevent conflicts)
      unquote(generate_blog_routes(url_prefix))

      # Generate catch-all route for pages at root level (must be last)
      unquote(generate_pages_catch_all())
    end
  end

  @doc """
  Adds PhoenixKit sockets to your endpoint.

  Call this macro in your endpoint.ex to enable PhoenixKit WebSocket features
  like DB Sync.

  ## Usage

  In your endpoint.ex:

      defmodule MyAppWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :my_app
        import PhoenixKitWeb.Integration

        # Add PhoenixKit sockets (for DB Sync, etc.)
        phoenix_kit_socket()

        # ... rest of your endpoint config
      end

  This adds:
  - `/db-sync/websocket` endpoint for cross-site data sync

  ## Implementation Note

  Uses WebSock directly (via Plug) instead of Phoenix.Socket/Channel to avoid
  cross-OTP-app channel supervision issues. The WebSocket handler processes
  JSON messages in Phoenix channel format for compatibility.
  """
  defmacro phoenix_kit_socket do
    quote do
      plug PhoenixKitWeb.Plugs.DBSyncSocketPlug
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
