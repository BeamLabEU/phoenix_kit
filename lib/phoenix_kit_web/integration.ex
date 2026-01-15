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

      # Define shop session pipeline (ensures persistent cart session)
      pipeline :phoenix_kit_shop_session do
        plug PhoenixKit.Modules.Shop.Web.Plugs.ShopSession
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

        # Dashboard context switching
        post "/context/:id", ContextController, :set

        # OAuth routes for external provider authentication
        get "/users/auth/:provider", Users.OAuth, :request
        get "/users/auth/:provider/callback", Users.OAuth, :callback

        # Magic Link Registration routes
        get "/users/register/verify/:token", Users.MagicLinkRegistrationVerify, :verify

        # Note: Email webhook moved to generate_emails_routes/1 (separate scope)

        # Storage API routes (file upload and serving)
        post "/api/upload", UploadController, :create
        get "/file/:file_id/:variant/:token", FileController, :show
        get "/api/files/:file_id/info", FileController, :info

        # Cookie consent widget config (public API for JS auto-injection)
        get "/api/consent-config", Controllers.ConsentConfigController, :config

        # Pages routes temporarily disabled
        # get "/pages/*path", PagesController, :show
      end

      # Sync API routes (JSON API - accepts JSON from remote PhoenixKit sites)
      scope unquote(url_prefix) do
        pipe_through [:phoenix_kit_api]

        post "/sync/api/register-connection",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :register_connection

        post "/sync/api/delete-connection",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :delete_connection

        post "/sync/api/verify-connection",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :verify_connection

        post "/sync/api/update-status",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :update_status

        post "/sync/api/get-connection-status",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :get_connection_status

        post "/sync/api/list-tables",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :list_tables

        post "/sync/api/pull-data",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :pull_data

        post "/sync/api/table-schema",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :table_schema

        post "/sync/api/table-records",
             PhoenixKit.Modules.Sync.Web.ApiController,
             :table_records

        get "/sync/api/status", PhoenixKit.Modules.Sync.Web.ApiController, :status
      end

      # Sync WebSocket - forward to plug for websocket upgrade handling
      # Uses url_prefix to be consistent with API routes
      forward "#{unquote(url_prefix)}/sync/websocket", PhoenixKit.Modules.Sync.Web.SocketPlug

      # Note: Email export routes moved to generate_emails_routes/1 (separate scope)

      # PhoenixKit static assets (no CSRF protection needed for static files)
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:phoenix_kit_api]

        get "/assets/:file", AssetsController, :serve
      end

      # Sitemap routes - uses PhoenixKit.Modules.Sitemap namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup]

        get "/sitemap.xml", PhoenixKit.Modules.Sitemap.Web.Controller, :xml
        get "/sitemap.html", PhoenixKit.Modules.Sitemap.Web.Controller, :html
        get "/sitemap/version", PhoenixKit.Modules.Sitemap.Web.Controller, :version
        get "/sitemaps/:index", PhoenixKit.Modules.Sitemap.Web.Controller, :index_part
        get "/sitemap.xsl", PhoenixKit.Modules.Sitemap.Web.Controller, :xsl_stylesheet
        get "/assets/sitemap/:style", PhoenixKit.Modules.Sitemap.Web.Controller, :xsl_stylesheet
      end

      # Sitemap admin settings - uses PhoenixKit.Modules.Sitemap namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_sitemap_settings,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/settings/sitemap",
               PhoenixKit.Modules.Sitemap.Web.Settings,
               :index,
               as: :sitemap_settings
        end
      end

      # Billing webhook routes - uses PhoenixKit.Modules.Billing namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:phoenix_kit_api]

        post "/webhooks/billing/stripe",
             PhoenixKit.Modules.Billing.Web.WebhookController,
             :stripe

        post "/webhooks/billing/paypal",
             PhoenixKit.Modules.Billing.Web.WebhookController,
             :paypal

        post "/webhooks/billing/razorpay",
             PhoenixKit.Modules.Billing.Web.WebhookController,
             :razorpay
      end

      # Billing admin routes - uses PhoenixKit.Modules.Billing namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_billing_admin,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          # Dashboard
          live "/admin/billing", PhoenixKit.Modules.Billing.Web.Index, :index, as: :billing_index

          # Orders
          live "/admin/billing/orders", PhoenixKit.Modules.Billing.Web.Orders, :index,
            as: :billing_orders

          live "/admin/billing/orders/new", PhoenixKit.Modules.Billing.Web.OrderForm, :new,
            as: :billing_order_new

          live "/admin/billing/orders/:id", PhoenixKit.Modules.Billing.Web.OrderDetail, :show,
            as: :billing_order_detail

          live "/admin/billing/orders/:id/edit", PhoenixKit.Modules.Billing.Web.OrderForm, :edit,
            as: :billing_order_edit

          # Invoices
          live "/admin/billing/invoices", PhoenixKit.Modules.Billing.Web.Invoices, :index,
            as: :billing_invoices

          live "/admin/billing/invoices/:id", PhoenixKit.Modules.Billing.Web.InvoiceDetail, :show,
            as: :billing_invoice_detail

          live "/admin/billing/invoices/:id/print",
               PhoenixKit.Modules.Billing.Web.InvoicePrint,
               :print,
               as: :billing_invoice_print

          live "/admin/billing/invoices/:id/receipt",
               PhoenixKit.Modules.Billing.Web.ReceiptPrint,
               :receipt,
               as: :billing_receipt_print

          live "/admin/billing/invoices/:id/credit-note/:transaction_id",
               PhoenixKit.Modules.Billing.Web.CreditNotePrint,
               :credit_note,
               as: :billing_credit_note

          live "/admin/billing/invoices/:id/payment/:transaction_id",
               PhoenixKit.Modules.Billing.Web.PaymentConfirmationPrint,
               :payment_confirmation,
               as: :billing_payment_confirmation

          # Transactions
          live "/admin/billing/transactions", PhoenixKit.Modules.Billing.Web.Transactions, :index,
            as: :billing_transactions

          # Subscriptions
          live "/admin/billing/subscriptions",
               PhoenixKit.Modules.Billing.Web.Subscriptions,
               :index,
               as: :billing_subscriptions

          live "/admin/billing/subscriptions/new",
               PhoenixKit.Modules.Billing.Web.SubscriptionForm,
               :new,
               as: :billing_subscription_new

          live "/admin/billing/subscriptions/:id",
               PhoenixKit.Modules.Billing.Web.SubscriptionDetail,
               :show,
               as: :billing_subscription_detail

          # Plans
          live "/admin/billing/plans", PhoenixKit.Modules.Billing.Web.SubscriptionPlans, :index,
            as: :billing_plans

          live "/admin/billing/plans/new",
               PhoenixKit.Modules.Billing.Web.SubscriptionPlanForm,
               :new,
               as: :billing_plan_new

          live "/admin/billing/plans/:id/edit",
               PhoenixKit.Modules.Billing.Web.SubscriptionPlanForm,
               :edit,
               as: :billing_plan_edit

          # Profiles
          live "/admin/billing/profiles", PhoenixKit.Modules.Billing.Web.BillingProfiles, :index,
            as: :billing_profiles

          live "/admin/billing/profiles/new",
               PhoenixKit.Modules.Billing.Web.BillingProfileForm,
               :new,
               as: :billing_profile_new

          live "/admin/billing/profiles/:id/edit",
               PhoenixKit.Modules.Billing.Web.BillingProfileForm,
               :edit,
               as: :billing_profile_edit

          # Currencies
          live "/admin/billing/currencies", PhoenixKit.Modules.Billing.Web.Currencies, :index,
            as: :billing_currencies

          # Settings
          live "/admin/settings/billing", PhoenixKit.Modules.Billing.Web.Settings, :settings,
            as: :billing_settings

          live "/admin/settings/billing/providers",
               PhoenixKit.Modules.Billing.Web.ProviderSettings,
               :index,
               as: :billing_provider_settings
        end
      end

      # DB Explorer routes - uses PhoenixKit.Modules.DB namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_db_explorer,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/db", PhoenixKit.Modules.DB.Web.Index, :index, as: :db_index

          live "/admin/db/activity", PhoenixKit.Modules.DB.Web.Activity, :activity,
            as: :db_activity

          live "/admin/db/:schema/:table", PhoenixKit.Modules.DB.Web.Show, :show, as: :db_show
        end
      end

      # Sync module routes - uses PhoenixKit.Modules.Sync namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_sync,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/sync", PhoenixKit.Modules.Sync.Web.Index, :index, as: :sync_index

          live "/admin/sync/connections", PhoenixKit.Modules.Sync.Web.ConnectionsLive, :index,
            as: :sync_connections

          live "/admin/sync/history", PhoenixKit.Modules.Sync.Web.History, :index,
            as: :sync_history
        end
      end

      # Entities module routes - uses PhoenixKit.Modules.Entities namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_entities,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/entities", PhoenixKit.Modules.Entities.Web.Entities, :index, as: :entities

          live "/admin/entities/new", PhoenixKit.Modules.Entities.Web.EntityForm, :new,
            as: :entities_new

          live "/admin/entities/:id/edit", PhoenixKit.Modules.Entities.Web.EntityForm, :edit,
            as: :entities_edit

          live "/admin/entities/:entity_slug/data",
               PhoenixKit.Modules.Entities.Web.DataNavigator,
               :entity,
               as: :entities_data_entity

          live "/admin/entities/:entity_slug/data/new",
               PhoenixKit.Modules.Entities.Web.DataForm,
               :new,
               as: :entities_data_new

          live "/admin/entities/:entity_slug/data/:id",
               PhoenixKit.Modules.Entities.Web.DataForm,
               :show,
               as: :entities_data_show

          live "/admin/entities/:entity_slug/data/:id/edit",
               PhoenixKit.Modules.Entities.Web.DataForm,
               :edit,
               as: :entities_data_edit

          live "/admin/settings/entities",
               PhoenixKit.Modules.Entities.Web.EntitiesSettings,
               :index,
               as: :entities_settings
        end
      end

      # Shop module routes - uses PhoenixKit.Modules.Shop namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_shop,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/shop", PhoenixKit.Modules.Shop.Web.Dashboard, :index, as: :shop_dashboard

          live "/admin/shop/products", PhoenixKit.Modules.Shop.Web.Products, :index,
            as: :shop_products

          live "/admin/shop/products/new", PhoenixKit.Modules.Shop.Web.ProductForm, :new,
            as: :shop_product_new

          live "/admin/shop/products/:id", PhoenixKit.Modules.Shop.Web.ProductDetail, :show,
            as: :shop_product_detail

          live "/admin/shop/products/:id/edit", PhoenixKit.Modules.Shop.Web.ProductForm, :edit,
            as: :shop_product_edit

          live "/admin/shop/categories", PhoenixKit.Modules.Shop.Web.Categories, :index,
            as: :shop_categories

          live "/admin/shop/categories/new", PhoenixKit.Modules.Shop.Web.CategoryForm, :new,
            as: :shop_category_new

          live "/admin/shop/categories/:id/edit", PhoenixKit.Modules.Shop.Web.CategoryForm, :edit,
            as: :shop_category_edit

          live "/admin/shop/shipping", PhoenixKit.Modules.Shop.Web.ShippingMethods, :index,
            as: :shop_shipping_methods

          live "/admin/shop/shipping/new", PhoenixKit.Modules.Shop.Web.ShippingMethodForm, :new,
            as: :shop_shipping_new

          live "/admin/shop/shipping/:id/edit",
               PhoenixKit.Modules.Shop.Web.ShippingMethodForm,
               :edit,
               as: :shop_shipping_edit

          live "/admin/shop/carts", PhoenixKit.Modules.Shop.Web.Carts, :index, as: :shop_carts

          live "/admin/shop/settings", PhoenixKit.Modules.Shop.Web.Settings, :index,
            as: :shop_settings
        end
      end

      # Shop public routes (catalog, cart - no admin auth required)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_shop_session]

        live_session :phoenix_kit_shop_public,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/shop", PhoenixKit.Modules.Shop.Web.ShopCatalog, :index, as: :shop_catalog

          live "/shop/category/:slug", PhoenixKit.Modules.Shop.Web.CatalogCategory, :show,
            as: :shop_category

          live "/shop/product/:slug", PhoenixKit.Modules.Shop.Web.CatalogProduct, :show,
            as: :shop_product

          live "/cart", PhoenixKit.Modules.Shop.Web.CartPage, :index, as: :shop_cart

          live "/checkout", PhoenixKit.Modules.Shop.Web.CheckoutPage, :index, as: :shop_checkout

          live "/checkout/complete/:uuid",
               PhoenixKit.Modules.Shop.Web.CheckoutComplete,
               :show,
               as: :shop_checkout_complete
        end
      end

      # Shop user dashboard routes (requires authentication)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_require_authenticated]

        live_session :phoenix_kit_shop_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/dashboard/orders", PhoenixKit.Modules.Shop.Web.UserOrders, :index,
            as: :shop_user_orders

          live "/dashboard/orders/:uuid", PhoenixKit.Modules.Shop.Web.UserOrderDetails, :show,
            as: :shop_user_order_details

          live "/dashboard/billing-profiles",
               PhoenixKit.Modules.Billing.Web.UserBillingProfiles,
               :index,
               as: :user_billing_profiles

          live "/dashboard/billing-profiles/new",
               PhoenixKit.Modules.Billing.Web.UserBillingProfileForm,
               :new,
               as: :user_billing_profile_new

          live "/dashboard/billing-profiles/:id/edit",
               PhoenixKit.Modules.Billing.Web.UserBillingProfileForm,
               :edit,
               as: :user_billing_profile_edit
        end
      end

      # AI module routes - uses PhoenixKit.Modules.AI namespace (no PhoenixKitWeb prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_ai,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/ai", PhoenixKit.Modules.AI.Web.Endpoints, :index, as: :ai_index

          live "/admin/ai/endpoints", PhoenixKit.Modules.AI.Web.Endpoints, :endpoints,
            as: :ai_endpoints

          live "/admin/ai/usage", PhoenixKit.Modules.AI.Web.Endpoints, :usage, as: :ai_usage

          live "/admin/ai/endpoints/new", PhoenixKit.Modules.AI.Web.EndpointForm, :new,
            as: :ai_endpoint_new

          live "/admin/ai/endpoints/:id/edit", PhoenixKit.Modules.AI.Web.EndpointForm, :edit,
            as: :ai_endpoint_edit

          live "/admin/ai/prompts", PhoenixKit.Modules.AI.Web.Prompts, :index, as: :ai_prompts

          live "/admin/ai/prompts/new", PhoenixKit.Modules.AI.Web.PromptForm, :new,
            as: :ai_prompt_new

          live "/admin/ai/prompts/:id/edit", PhoenixKit.Modules.AI.Web.PromptForm, :edit,
            as: :ai_prompt_edit
        end
      end
    end
  end

  # Helper function to generate email routes
  # Uses separate scope because PhoenixKit.Modules.* namespace can't be inside PhoenixKitWeb scope
  defp generate_emails_routes(url_prefix) do
    quote do
      # Email webhook endpoint (public - no authentication required)
      scope unquote(url_prefix) do
        pipe_through [:browser]

        post "/webhooks/email", PhoenixKit.Modules.Emails.Web.WebhookController, :handle
      end

      # Email export routes (require admin or owner role)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        get "/admin/emails/export", PhoenixKit.Modules.Emails.Web.ExportController, :export_logs

        get "/admin/emails/metrics/export",
            PhoenixKit.Modules.Emails.Web.ExportController,
            :export_metrics

        get "/admin/emails/blocklist/export",
            PhoenixKit.Modules.Emails.Web.ExportController,
            :export_blocklist

        get "/admin/emails/:id/export",
            PhoenixKit.Modules.Emails.Web.ExportController,
            :export_email_details
      end

      # Email admin LiveView routes
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_emails,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          # Email Settings
          live "/admin/settings/emails", PhoenixKit.Modules.Emails.Web.Settings, :index,
            as: :emails_settings

          # Email Dashboard and Management
          live "/admin/emails/dashboard", PhoenixKit.Modules.Emails.Web.Metrics, :index,
            as: :emails_metrics

          live "/admin/emails", PhoenixKit.Modules.Emails.Web.Emails, :index, as: :emails_index

          live "/admin/emails/email/:id", PhoenixKit.Modules.Emails.Web.Details, :show,
            as: :emails_details

          live "/admin/emails/queue", PhoenixKit.Modules.Emails.Web.Queue, :index,
            as: :emails_queue

          live "/admin/emails/blocklist", PhoenixKit.Modules.Emails.Web.Blocklist, :index,
            as: :emails_blocklist

          # Email Templates Management
          live "/admin/modules/emails/templates", PhoenixKit.Modules.Emails.Web.Templates, :index,
            as: :emails_templates

          live "/admin/modules/emails/templates/new",
               PhoenixKit.Modules.Emails.Web.TemplateEditor,
               :new,
               as: :emails_template_new

          live "/admin/modules/emails/templates/:id/edit",
               PhoenixKit.Modules.Emails.Web.TemplateEditor,
               :edit,
               as: :emails_template_edit
        end
      end
    end
  end

  # Helper function to generate referral codes routes
  # Uses separate scope because PhoenixKit.Modules.* namespace can't be inside PhoenixKitWeb scope
  defp generate_referral_codes_routes(url_prefix) do
    quote do
      # Referral codes admin LiveView routes (localized)
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_referral_codes_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/settings/referral-codes",
               PhoenixKit.Modules.Referrals.Web.Settings,
               :index,
               as: :referral_codes_settings_localized

          live "/admin/users/referral-codes",
               PhoenixKit.Modules.Referrals.Web.List,
               :index,
               as: :referral_codes_list_localized

          live "/admin/users/referral-codes/new",
               PhoenixKit.Modules.Referrals.Web.Form,
               :new,
               as: :referral_codes_new_localized

          live "/admin/users/referral-codes/edit/:id",
               PhoenixKit.Modules.Referrals.Web.Form,
               :edit,
               as: :referral_codes_edit_localized
        end
      end

      # Referral codes admin LiveView routes (non-localized)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_referral_codes,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/settings/referral-codes",
               PhoenixKit.Modules.Referrals.Web.Settings,
               :index,
               as: :referral_codes_settings

          live "/admin/users/referral-codes",
               PhoenixKit.Modules.Referrals.Web.List,
               :index,
               as: :referral_codes_list

          live "/admin/users/referral-codes/new",
               PhoenixKit.Modules.Referrals.Web.Form,
               :new,
               as: :referral_codes_new

          live "/admin/users/referral-codes/edit/:id",
               PhoenixKit.Modules.Referrals.Web.Form,
               :edit,
               as: :referral_codes_edit
        end
      end
    end
  end

  # Helper function to generate publishing routes with locale support
  # Uses separate scopes because PhoenixKit.Modules.* namespace can't be inside PhoenixKitWeb scope
  # Includes both new /admin/publishing/* routes and legacy /admin/blogging/* redirects
  defp generate_publishing_routes(url_prefix) do
    quote do
      # =======================================================================
      # NEW Publishing Routes (Primary)
      # =======================================================================

      # Localized publishing routes (with :locale prefix)
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_publishing_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
            as: :publishing_index_localized

          live "/admin/publishing/:blog", PhoenixKit.Modules.Publishing.Web.Listing, :blog,
            as: :publishing_blog_localized

          live "/admin/publishing/:blog/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
            as: :publishing_editor_localized

          live "/admin/publishing/:blog/preview",
               PhoenixKit.Modules.Publishing.Web.Preview,
               :preview,
               as: :publishing_preview_localized

          live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
            as: :publishing_settings_localized

          live "/admin/settings/publishing/new", PhoenixKit.Modules.Publishing.Web.New, :new,
            as: :publishing_new_localized

          live "/admin/settings/publishing/:blog/edit",
               PhoenixKit.Modules.Publishing.Web.Edit,
               :edit,
               as: :publishing_edit_localized
        end
      end

      # Non-localized publishing routes (without :locale prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_publishing,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
            as: :publishing_index

          live "/admin/publishing/:blog", PhoenixKit.Modules.Publishing.Web.Listing, :blog,
            as: :publishing_blog

          live "/admin/publishing/:blog/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
            as: :publishing_editor

          live "/admin/publishing/:blog/preview",
               PhoenixKit.Modules.Publishing.Web.Preview,
               :preview,
               as: :publishing_preview

          live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
            as: :publishing_settings

          live "/admin/settings/publishing/new", PhoenixKit.Modules.Publishing.Web.New, :new,
            as: :publishing_new

          live "/admin/settings/publishing/:blog/edit",
               PhoenixKit.Modules.Publishing.Web.Edit,
               :edit,
               as: :publishing_edit
        end
      end

      # =======================================================================
      # LEGACY Blogging Routes (Redirects to new publishing routes)
      # These provide backward compatibility for bookmarked URLs
      # =======================================================================

      alias PhoenixKitWeb.Controllers.Redirects.PublishingRedirectController

      # Localized legacy redirects
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser]

        get "/admin/blogging", PublishingRedirectController, :index
        get "/admin/blogging/:blog", PublishingRedirectController, :blog
        get "/admin/blogging/:blog/edit", PublishingRedirectController, :edit
        get "/admin/blogging/:blog/preview", PublishingRedirectController, :preview
        get "/admin/settings/blogging", PublishingRedirectController, :settings
        get "/admin/settings/blogging/new", PublishingRedirectController, :new
        get "/admin/settings/blogging/:blog/edit", PublishingRedirectController, :settings_edit
      end

      # Non-localized legacy redirects
      scope unquote(url_prefix) do
        pipe_through [:browser]

        get "/admin/blogging", PublishingRedirectController, :index
        get "/admin/blogging/:blog", PublishingRedirectController, :blog
        get "/admin/blogging/:blog/edit", PublishingRedirectController, :edit
        get "/admin/blogging/:blog/preview", PublishingRedirectController, :preview
        get "/admin/settings/blogging", PublishingRedirectController, :settings
        get "/admin/settings/blogging/new", PublishingRedirectController, :new
        get "/admin/settings/blogging/:blog/edit", PublishingRedirectController, :settings_edit
      end
    end
  end

  # Helper function to generate tickets routes with locale support
  # Uses separate scopes because PhoenixKit.Modules.* namespace can't be inside PhoenixKitWeb scope
  defp generate_tickets_routes(url_prefix) do
    quote do
      # Localized tickets admin routes (with :locale prefix)
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_tickets_admin_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/tickets", PhoenixKit.Modules.Tickets.Web.List, :index,
            as: :tickets_list_localized

          live "/admin/tickets/:id", PhoenixKit.Modules.Tickets.Web.Details, :show,
            as: :tickets_details_localized

          live "/admin/tickets/:id/edit", PhoenixKit.Modules.Tickets.Web.Edit, :edit,
            as: :tickets_edit_localized

          live "/admin/settings/tickets", PhoenixKit.Modules.Tickets.Web.Settings, :index,
            as: :tickets_settings_localized
        end
      end

      # Non-localized tickets admin routes
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_tickets_admin,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/tickets", PhoenixKit.Modules.Tickets.Web.List, :index, as: :tickets_list

          live "/admin/tickets/:id", PhoenixKit.Modules.Tickets.Web.Details, :show,
            as: :tickets_details

          live "/admin/tickets/:id/edit", PhoenixKit.Modules.Tickets.Web.Edit, :edit,
            as: :tickets_edit

          live "/admin/settings/tickets", PhoenixKit.Modules.Tickets.Web.Settings, :index,
            as: :tickets_settings
        end
      end

      # Localized tickets user dashboard routes (with :locale prefix)
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_require_authenticated]

        live_session :phoenix_kit_tickets_user_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/dashboard/tickets", PhoenixKit.Modules.Tickets.Web.UserList, :index,
            as: :tickets_user_list_localized

          live "/dashboard/tickets/new", PhoenixKit.Modules.Tickets.Web.UserNew, :new,
            as: :tickets_user_new_localized

          live "/dashboard/tickets/:id", PhoenixKit.Modules.Tickets.Web.UserDetails, :show,
            as: :tickets_user_details_localized
        end
      end

      # Non-localized tickets user dashboard routes
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_require_authenticated]

        live_session :phoenix_kit_tickets_user,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
          live "/dashboard/tickets", PhoenixKit.Modules.Tickets.Web.UserList, :index,
            as: :tickets_user_list

          live "/dashboard/tickets/new", PhoenixKit.Modules.Tickets.Web.UserNew, :new,
            as: :tickets_user_new

          live "/dashboard/tickets/:id", PhoenixKit.Modules.Tickets.Web.UserDetails, :show,
            as: :tickets_user_details
        end
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
        live "/admin/settings/organization", Live.Settings.Organization, :index
        live "/admin/modules", Live.Modules, :index

        # Note: Publishing routes are in generate_publishing_routes/1 with separate scopes
        # because PhoenixKit.Modules.* namespace can't be used inside PhoenixKitWeb scope

        # Posts module routes
        live "/admin/posts", Live.Modules.Posts.Posts, :index
        live "/admin/posts/new", Live.Modules.Posts.Edit, :new
        live "/admin/posts/groups", Live.Modules.Posts.Groups, :index
        live "/admin/posts/groups/new", Live.Modules.Posts.GroupEdit, :new
        live "/admin/posts/groups/:id/edit", Live.Modules.Posts.GroupEdit, :edit
        live "/admin/posts/:id", Live.Modules.Posts.Details, :show
        live "/admin/posts/:id/edit", Live.Modules.Posts.Edit, :edit
        live "/admin/settings/posts", Live.Modules.Posts.Settings, :index

        # Note: Referral codes routes moved to generate_referral_codes_routes/1 (separate scope)
        # Note: Email settings moved to generate_emails_routes/1 (separate scope)
        live "/admin/settings/languages", Live.Modules.Languages, :index
        live "/admin/settings/legal", Live.Modules.Legal.Settings, :index

        live "/admin/settings/maintenance",
             Live.Modules.Maintenance.Settings,
             :index

        live "/admin/settings/seo", Live.Settings.SEO, :index

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

        # Note: Referral codes routes moved to generate_referral_codes_routes/1 (separate scope)
        # Note: Email routes moved to generate_emails_routes/1 (separate scope)
        # because PhoenixKit.Modules.* namespace can't be used inside PhoenixKitWeb scope

        # Jobs
        live "/admin/jobs", Live.Modules.Jobs.Index, :index

        # Note: AI, Billing, Blogging, and Entities routes are defined in generate_basic_scope/1
        # using separate scopes without PhoenixKitWeb module prefix
      end
    end
  end

  # Generates user dashboard routes (conditional on config)
  defmacro phoenix_kit_dashboard_routes(suffix) do
    session_name = :"phoenix_kit_user_dashboard#{suffix}"

    quote do
      if unquote(PhoenixKit.Config.user_dashboard_enabled?()) do
        live_session unquote(session_name),
          on_mount: [
            {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
            {PhoenixKitWeb.Dashboard.ContextProvider, :default}
          ] do
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

        # POST routes for authentication (needed for locale-prefixed form submissions)
        post "/users/log-in", Users.Session, :create
        delete "/users/log-out", Users.Session, :delete
        get "/users/log-out", Users.Session, :get_logout
        get "/users/magic-link/:token", Users.MagicLinkVerify, :verify

        # OAuth routes
        get "/users/auth/:provider", Users.OAuth, :request
        get "/users/auth/:provider/callback", Users.OAuth, :callback

        # Magic Link Registration
        get "/users/register/verify/:token", Users.MagicLinkRegistrationVerify, :verify

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

      scope blog_scope_multi do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        # Exclude admin paths from blogging catch-all routes
        get "/:blog", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"blog" => ~r/^(?!admin$)/}

        get "/:blog/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"blog" => ~r/^(?!admin$)/}
      end

      # Non-localized blog routes (for when url_prefix is "/")
      blog_scope_non_localized =
        case unquote(url_prefix) do
          "/" -> "/"
          prefix -> prefix
        end

      scope blog_scope_non_localized do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        # Exclude admin paths from blogging catch-all routes
        # Language detection is handled in the controller by checking if content exists
        get "/:blog", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"blog" => ~r/^(?!admin$)/}

        get "/:blog/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"blog" => ~r/^(?!admin$)/}
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

      # Generate email routes (separate scope for PhoenixKit.Modules.* namespace)
      unquote(generate_emails_routes(url_prefix))

      # Generate referral codes routes (separate scope for PhoenixKit.Modules.* namespace)
      unquote(generate_referral_codes_routes(url_prefix))

      # Generate publishing routes (with locale support)
      unquote(generate_publishing_routes(url_prefix))

      # Generate tickets routes (with locale support)
      unquote(generate_tickets_routes(url_prefix))

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
  **DEPRECATED**: This macro is no longer needed.

  The Sync WebSocket is now automatically handled via the router when you
  use `phoenix_kit_routes()`. The websocket endpoint is available at
  `{url_prefix}/sync/websocket` without any additional configuration.

  You can safely remove this macro from your endpoint.ex if you have it.

  ## Legacy Usage (deprecated)

  Previously, this macro was required in endpoint.ex:

      defmodule MyAppWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :my_app
        import PhoenixKitWeb.Integration

        # No longer needed - remove this line
        # phoenix_kit_socket()
      end

  ## Implementation Note

  WebSocket handling is now done via `forward` in the router, which makes
  the setup fully self-contained within PhoenixKit. No endpoint modifications
  are required.
  """
  @deprecated "Sync websocket is now handled automatically via phoenix_kit_routes()"
  defmacro phoenix_kit_socket do
    quote do
      plug PhoenixKit.Modules.Sync.Web.SocketPlug
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
