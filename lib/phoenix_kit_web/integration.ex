# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule PhoenixKitWeb.Integration do
  @compile {:no_warn_undefined,
            [
              PhoenixKitEcommerce,
              PhoenixKitEcommerce.Web.Routes,
              PhoenixKitEcommerce.Web.Plugs.ShopSession,
              PhoenixKitEcommerce.Web.UserOrders,
              PhoenixKitEcommerce.Web.UserOrderDetails,
              PhoenixKitWeb.Live.Modules.Legal.Settings,
              PhoenixKitWeb.Controllers.ConsentConfigController
            ]}
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

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb

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
            Keyword.put(unquote(opts), :locale, ~r/^[a-z]{2,3}(?:-[A-Za-z]{2,4})?$/) do
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
    # Shop session pipeline — conditional on Shop package being installed
    shop_session_pipeline =
      if Code.ensure_loaded?(PhoenixKitEcommerce.Web.Plugs.ShopSession) do
        quote do
          pipeline :phoenix_kit_shop_session do
            plug PhoenixKitEcommerce.Web.Plugs.ShopSession
          end
        end
      else
        quote do
        end
      end

    quote do
      alias PhoenixKit.Modules.Languages

      # Define the auto-setup pipeline
      pipeline :phoenix_kit_auto_setup do
        plug PhoenixKitWeb.Plugs.RequestTimer
        plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user
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

      pipeline :phoenix_kit_optional_scope do
        plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_scope
      end

      # Define API pipeline for JSON endpoints
      pipeline :phoenix_kit_api do
        plug :accepts, ["json"]
      end

      # Define locale validation pipeline
      pipeline :phoenix_kit_locale_validation do
        plug PhoenixKitWeb.Users.Auth, :phoenix_kit_validate_and_set_locale
      end

      # Shop session pipeline (only when phoenix_kit_ecommerce is installed)
      unquote(shop_session_pipeline)
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
        post "/users/session/accounts", Users.Session, :add_account
        put "/users/session/active", Users.Session, :set_active_account
        delete "/users/session/accounts/:ref", Users.Session, :remove_account
        get "/users/magic-link/:token", Users.MagicLinkVerify, :verify

        # Dashboard context switching (multi-selector with key, must come before legacy route)
        post "/context/:key/:id", ContextController, :set
        # Dashboard context switching (legacy single selector)
        post "/context/:id", ContextController, :set

        # OAuth routes for external provider authentication
        get "/users/auth/:provider", Users.OAuth, :request
        get "/users/auth/:provider/callback", Users.OAuth, :callback

        # Magic Link Registration routes
        get "/users/register/verify/:token", Users.MagicLinkRegistrationVerify, :verify

        # Note: Email webhook moved to generate_emails_routes/1 (separate scope)

        # Storage API routes (file upload and serving)
        post "/api/upload", UploadController, :create
        get "/file/:file_uuid/:variant/:token", FileController, :show
        get "/api/files/:file_uuid/info", FileController, :info
        # Token in the path (not query string) so OpenSeadragon's tile-URL
        # derivation preserves it — OSD strips `.dzi?query=...` to build
        # `<base>_files/<level>/<col>_<row>.<ext>`, but a path-token
        # `/tiles/<token>/<uuid>.dzi` becomes a clean base of
        # `/tiles/<token>/<uuid>` and tile URLs inherit the token.
        get "/tiles/:token/:dzi_filename", FileController, :serve_manifest
        get "/tiles/:token/:files_segment/:level/:tile_filename", FileController, :serve_tile

        # Cookie consent widget config (public API for JS auto-injection)
        if Code.ensure_loaded?(PhoenixKit.Modules.Legal) do
          get "/api/consent-config", Controllers.ConsentConfigController, :config
        end
      end

      # Maintenance mode page — public LiveView, no auth required.
      # Uses :phoenix_kit_mount_current_scope to detect admin users (for preview banner).
      # The maintenance page view is in skip_maintenance_check? so it won't redirect to itself.
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:browser, :phoenix_kit_auto_setup]

        live_session :phoenix_kit_maintenance,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/maintenance", Live.Modules.Maintenance.Page, :index
        end
      end

      # Note: Email export routes moved to generate_emails_routes/1 (separate scope)

      # PhoenixKit static assets (no CSRF protection needed for static files)
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:phoenix_kit_api]

        get "/assets/:file", AssetsController, :serve
      end

      # Router-served fallback for phoenix_kit_catalogue's vendored PDF.js
      # viewer. Served at the literal `/_pdfjs` path (no prefix/locale) so it
      # matches the same URL the catalogue's iframe + endpoint `Plug.Static`
      # mount use — the endpoint mount (when present) wins because endpoint
      # plugs precede the router; this only catches the fall-through on a host
      # whose endpoint never got the mount. Compiled in only when the
      # catalogue module is loaded.
      if Code.ensure_loaded?(PhoenixKitCatalogue.Catalogue.PdfLibrary) do
        # No pipeline: these are public static assets (HTML / JS modules /
        # CSS / fonts) served by the controller, which sets its own
        # content-type. The `:phoenix_kit_api` pipeline restricts to JSON
        # (`plug :accepts, ["json"]`) and would mis-negotiate text/html and
        # text/javascript for strict Accept headers.
        scope "/_pdfjs", PhoenixKitWeb do
          get "/*path", PdfViewerController, :serve
        end
      end

      # Sitemap routes - public XML/XSL endpoints, no session/CSRF/auto_setup needed
      scope unquote(url_prefix) do
        get "/sitemap.xml", PhoenixKit.Modules.Sitemap.Web.Controller, :xml
        get "/sitemap.html", PhoenixKit.Modules.Sitemap.Web.Controller, :html
        get "/sitemaps/:filename", PhoenixKit.Modules.Sitemap.Web.Controller, :module_sitemap
        get "/sitemap.xsl", PhoenixKit.Modules.Sitemap.Web.Controller, :xsl_stylesheet
        get "/assets/sitemap/:style", PhoenixKit.Modules.Sitemap.Web.Controller, :xsl_stylesheet

        get "/assets/sitemap-index/:style",
            PhoenixKit.Modules.Sitemap.Web.Controller,
            :xsl_index_stylesheet
      end

      # Shop public routes are generated via generate_shop_public_routes/1 helper
      # This supports locale-prefixed URLs (/:locale/shop/...) with language switching
      # Shop user dashboard routes are now in phoenix_kit_authenticated_routes/1.
    end
  end

  # ============================================================================
  # Shared Route Definitions
  # ============================================================================
  # These macros generate route definitions that are shared between localized
  # and non-localized scopes. This eliminates code duplication and reduces
  # compile time by ~50% for router files.
  # ============================================================================

  # Generates the public route table (auth + confirmation + shop) for one
  # URL shape (`suffix` is `:_locale` or `:""`). Emits the `live`/`scope`
  # entries only — the wrapping `live_session :phoenix_kit_public` is
  # supplied by `generate_public_live_routes/2`, so both URL shapes share
  # a single session and a front-end locale switch stays on the
  # WebSocket instead of crossing a live_session boundary.
  #
  # Auth LiveViews handle the redirect-if-authenticated check in their own
  # mount/3, so the shared session uses the permissive
  # :phoenix_kit_mount_current_scope hook.
  defmacro phoenix_kit_public_routes(suffix) do
    # Get shop live route declarations at compile time (no scope/pipeline wrappers)
    shop_live_routes =
      if Code.ensure_loaded?(PhoenixKitEcommerce.Web.Routes) do
        if suffix == :_locale do
          PhoenixKitEcommerce.Web.Routes.public_live_locale_routes()
        else
          PhoenixKitEcommerce.Web.Routes.public_live_routes()
        end
      else
        quote do
        end
      end

    quote do
      # Auth pages — redirect-if-authenticated handled in each LiveView's mount/3
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

      # Confirmation pages — no redirect check needed
      live "/users/confirm/:token", Users.Confirmation, :edit, as: :user_confirmation

      live "/users/confirm", Users.ConfirmationInstructions, :new,
        as: :user_confirmation_instructions

      # Shop public pages — same session for seamless auth → shop navigation
      # Full module names required (no PhoenixKitWeb alias in shop namespace)
      scope "/", alias: false do
        unquote(shop_live_routes)
      end
    end
  end

  # Generates the admin route table for one URL shape (`suffix` is
  # `:_locale` or `:""`). Emits the `live`/`scope` entries only — the
  # wrapping `live_session :phoenix_kit_admin` is supplied by
  # `generate_admin_routes/2`, so both URL shapes share a single
  # session and an in-admin locale switch stays on the WebSocket
  # instead of crossing a live_session boundary (full-page reload).
  defmacro phoenix_kit_admin_routes(suffix) do
    # Auto-generate routes for custom admin tabs that specify live_view
    # Skip when compiling PhoenixKit's own dev/test router — parent modules don't exist
    custom_admin_routes = compile_custom_admin_routes(__CALLER__.module)

    # Plugin module routes get their own live_session with admin layout
    # so plugin LiveViews don't need to wrap with LayoutWrapper themselves
    plugin_admin_routes = compile_plugin_admin_routes(__CALLER__.module)

    # Shop admin routes via safe_route_call (only when phoenix_kit_ecommerce is installed)
    shop_admin =
      if suffix == :_locale do
        safe_route_call(PhoenixKitEcommerce.Web.Routes, :admin_locale_routes, [])
      else
        safe_route_call(PhoenixKitEcommerce.Web.Routes, :admin_routes, [])
      end

    # External route modules with complex routes (beyond simple admin tabs)
    external_admin_routes = compile_external_admin_routes(suffix)

    quote do
      # Core admin routes (under PhoenixKitWeb alias from parent scope)
      live "/admin", Live.Dashboard, :index
      live "/admin/users", Live.Users.Users, :index
      live "/admin/users/new", Users.UserForm, :new, as: :user_form
      live "/admin/users/edit/:id", Users.UserForm, :edit, as: :user_form_edit
      live "/admin/users/view/:id", Live.Users.UserDetails, :show
      live "/admin/users/roles", Live.Users.Roles, :index
      live "/admin/users/permissions", Live.Users.PermissionsMatrix, :index
      live "/admin/users/live_sessions", Live.Users.LiveSessions, :index
      live "/admin/users/sessions", Live.Users.Sessions, :index
      live "/admin/activity", Live.Activity.Index, :index
      live "/admin/activity/:uuid", Live.Activity.Show, :show
      live "/admin/notifications", Live.Modules.Notifications.Index, :index
      live "/admin/media", Live.Users.Media, :index
      live "/admin/media/:file_uuid", Live.Users.MediaDetail, :show
      live "/admin/media/selector", Live.Users.MediaSelector, :index
      live "/admin/settings", Live.Settings, :index
      live "/admin/settings/users", Live.Settings.Users, :index
      live "/admin/settings/authorization", Live.Settings.Authorization, :index
      live "/admin/settings/organization", Live.Settings.Organization, :index
      live "/admin/settings/integrations", Live.Settings.Integrations, :index
      live "/admin/settings/integrations/new", Live.Settings.IntegrationForm, :new
      live "/admin/settings/integrations/:uuid", Live.Settings.IntegrationForm, :edit
      live "/admin/modules", Live.Modules, :index

      live "/admin/settings/languages", Live.Modules.Languages, :index
      live "/admin/settings/languages/frontend", Live.Modules.Languages, :frontend

      live "/admin/settings/maintenance", Live.Modules.Maintenance.Settings, :index
      live "/admin/settings/seo", Live.Settings.SEO, :index
      live "/admin/settings/media", Live.Modules.Storage.Settings, :index
      live "/admin/settings/media/buckets/new", Live.Modules.Storage.BucketForm, :new
      live "/admin/settings/media/buckets/:id/edit", Live.Modules.Storage.BucketForm, :edit
      live "/admin/settings/media/dimensions", Live.Modules.Storage.Dimensions, :index
      live "/admin/settings/media/health", Live.Modules.Storage.Health, :index

      live "/admin/settings/media/dimensions/new/image",
           Live.Modules.Storage.DimensionForm,
           :new_image

      live "/admin/settings/media/dimensions/new/video",
           Live.Modules.Storage.DimensionForm,
           :new_video

      live "/admin/settings/media/dimensions/:id/edit",
           Live.Modules.Storage.DimensionForm,
           :edit

      # Jobs
      live "/admin/jobs", Live.Modules.Jobs.Index, :index

      # Module admin routes (use alias: false to prevent PhoenixKitWeb prefix
      # since these modules use their own namespaces like PhoenixKit.Modules.*)
      scope "/", alias: false do
        # Sitemap settings
        live "/admin/settings/sitemap",
             PhoenixKit.Modules.Sitemap.Web.Settings,
             :index,
             as: :sitemap_settings

        # Shop admin routes (only when phoenix_kit_ecommerce is installed)
        unquote(shop_admin)

        # Custom admin routes from :admin_dashboard_tabs config
        # Tabs with live_view: {Module, :action} get auto-generated routes
        # in the shared admin live_session for seamless navigation
        unquote_splicing(custom_admin_routes)

        # External route modules (complex multi-page routes)
        unquote_splicing(external_admin_routes)

        # Plugin module routes (in same live_session for seamless navigation).
        # Admin layout is auto-applied via on_mount for external plugin views.
        unquote_splicing(plugin_admin_routes)
      end
    end
  end

  # Generates the authenticated user route table (dashboard + shop user +
  # tickets user) for one URL shape (`suffix` is `:_locale` or `:""`).
  # Emits the `live`/`scope` entries only — the wrapping
  # `live_session :phoenix_kit_authenticated` is supplied by
  # `generate_authenticated_live_routes/2`, so both URL shapes share a
  # single session and an in-dashboard locale switch stays on the
  # WebSocket. Module routes use alias: false since they live outside
  # the PhoenixKitWeb namespace.
  defmacro phoenix_kit_authenticated_routes(suffix) do
    module_routes =
      if suffix == :_locale do
        authenticated_live_locale_routes()
      else
        authenticated_live_routes()
      end

    quote do
      # Core dashboard routes (conditional on config)
      if unquote(PhoenixKit.Config.user_dashboard_enabled?()) do
        live "/dashboard", Live.Dashboard.Index, :index
        live "/dashboard/settings", Live.Dashboard.Settings, :edit

        live "/dashboard/settings/confirm-email/:token",
             Live.Dashboard.Settings,
             :confirm_email
      end

      # Module user pages (full module names — no PhoenixKitWeb alias)
      scope "/", alias: false do
        unquote(module_routes)
      end
    end
  end

  defp authenticated_live_routes do
    shop_user_routes =
      if Code.ensure_loaded?(PhoenixKitEcommerce.Web.UserOrders) do
        quote do
          live "/dashboard/orders", PhoenixKitEcommerce.Web.UserOrders, :index,
            as: :shop_user_orders

          live "/dashboard/orders/:uuid", PhoenixKitEcommerce.Web.UserOrderDetails, :show,
            as: :shop_user_order_details
        end
      else
        quote do
        end
      end

    billing_user_routes =
      if Code.ensure_loaded?(PhoenixKitBilling.Web.UserBillingProfiles) do
        quote do
          live "/dashboard/billing-profiles",
               PhoenixKitBilling.Web.UserBillingProfiles,
               :index,
               as: :billing_user_profiles

          live "/dashboard/billing-profiles/new",
               PhoenixKitBilling.Web.UserBillingProfileForm,
               :new,
               as: :billing_user_profile_new

          live "/dashboard/billing-profiles/:uuid/edit",
               PhoenixKitBilling.Web.UserBillingProfileForm,
               :edit,
               as: :billing_user_profile_edit
        end
      else
        quote do
        end
      end

    cs_user_routes =
      if Code.ensure_loaded?(PhoenixKitCustomerSupport.Web.UserList) do
        quote do
          live "/dashboard/customer-support/tickets",
               PhoenixKitCustomerSupport.Web.UserList,
               :index,
               as: :tickets_user_list

          live "/dashboard/customer-support/tickets/new",
               PhoenixKitCustomerSupport.Web.UserNew,
               :new,
               as: :tickets_user_new

          live "/dashboard/customer-support/tickets/:id",
               PhoenixKitCustomerSupport.Web.UserDetails,
               :show,
               as: :tickets_user_details
        end
      else
        quote do
        end
      end

    quote do
      unquote(shop_user_routes)
      unquote(billing_user_routes)
      unquote(cs_user_routes)
    end
  end

  defp authenticated_live_locale_routes do
    shop_user_locale_routes =
      if Code.ensure_loaded?(PhoenixKitEcommerce.Web.UserOrders) do
        quote do
          live "/dashboard/orders", PhoenixKitEcommerce.Web.UserOrders, :index,
            as: :shop_user_orders_locale

          live "/dashboard/orders/:uuid", PhoenixKitEcommerce.Web.UserOrderDetails, :show,
            as: :shop_user_order_details_locale
        end
      else
        quote do
        end
      end

    billing_user_locale_routes =
      if Code.ensure_loaded?(PhoenixKitBilling.Web.UserBillingProfiles) do
        quote do
          live "/dashboard/billing-profiles",
               PhoenixKitBilling.Web.UserBillingProfiles,
               :index,
               as: :billing_user_profiles_locale

          live "/dashboard/billing-profiles/new",
               PhoenixKitBilling.Web.UserBillingProfileForm,
               :new,
               as: :billing_user_profile_new_locale

          live "/dashboard/billing-profiles/:uuid/edit",
               PhoenixKitBilling.Web.UserBillingProfileForm,
               :edit,
               as: :billing_user_profile_edit_locale
        end
      else
        quote do
        end
      end

    cs_user_locale_routes =
      if Code.ensure_loaded?(PhoenixKitCustomerSupport.Web.UserList) do
        quote do
          live "/dashboard/customer-support/tickets",
               PhoenixKitCustomerSupport.Web.UserList,
               :index,
               as: :tickets_user_list_locale

          live "/dashboard/customer-support/tickets/new",
               PhoenixKitCustomerSupport.Web.UserNew,
               :new,
               as: :tickets_user_new_locale

          live "/dashboard/customer-support/tickets/:id",
               PhoenixKitCustomerSupport.Web.UserDetails,
               :show,
               as: :tickets_user_details_locale
        end
      else
        quote do
        end
      end

    quote do
      unquote(shop_user_locale_routes)
      unquote(billing_user_locale_routes)
      unquote(cs_user_locale_routes)
    end
  end

  # Generates user dashboard routes (conditional on config).
  # @deprecated Use phoenix_kit_authenticated_routes/1 instead.
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

  # Reads :admin_dashboard_tabs config at compile time and generates
  # `live` route declarations for tabs that specify a `live_view` field.
  # Returns a list of quoted expressions for use with unquote_splicing.
  #
  # ## Tab config example
  #
  #     config :phoenix_kit, :admin_dashboard_tabs, [
  #       %{id: :admin_analytics, label: "Analytics", path: "analytics",
  #         live_view: {MyAppWeb.AnalyticsLive, :index}, permission: "dashboard"}
  #     ]
  #
  @doc false
  def compile_custom_admin_routes(caller_module) do
    # PhoenixKit's own router is only for dev/test — parent app modules
    # aren't available when it compiles, so skip custom route generation.
    if caller_module == PhoenixKitWeb.Router do
      []
    else
      compile_custom_admin_routes_internal()
    end
  end

  @doc false
  def compile_plugin_admin_routes(caller_module) do
    if caller_module == PhoenixKitWeb.Router do
      []
    else
      compile_module_admin_routes()
    end
  end

  defp compile_custom_admin_routes_internal do
    # Process :admin_dashboard_tabs config (new format, flat list with live_view)
    tabs_routes =
      case PhoenixKit.Config.get(:admin_dashboard_tabs) do
        {:ok, tabs} when is_list(tabs) ->
          tabs
          |> Enum.filter(fn tab ->
            is_map(tab) and Map.has_key?(tab, :live_view) and
              match?({module, _action} when is_atom(module), tab.live_view)
          end)
          |> Enum.map(&tab_to_route/1)

        _ ->
          []
      end

    # Process legacy :admin_dashboard_categories config (deprecated, hierarchical)
    # Auto-infer LiveView modules from subsection URLs
    legacy_routes = compile_legacy_admin_routes()

    tabs_routes ++ legacy_routes
  end

  # Generates routes from legacy admin_dashboard_categories config.
  # Reads categories at compile time and infers LiveView modules from URL patterns.
  defp compile_legacy_admin_routes do
    case PhoenixKit.Config.get(:admin_dashboard_categories) do
      {:ok, categories} when is_list(categories) ->
        categories
        |> Enum.flat_map(&routes_from_legacy_category/1)

      _ ->
        []
    end
  end

  # Generates routes from a single legacy category.
  defp routes_from_legacy_category(category) do
    subsections = category[:subsections] || []

    Enum.flat_map(subsections, fn subsection ->
      subsection_url = subsection[:url] || ""

      case infer_live_view_from_legacy_url_with_fallback(subsection_url) do
        {:ok, live_view} ->
          [tab_to_route_from_url(subsection_url, live_view, subsection[:id])]

        :error ->
          []
      end
    end)
  end

  # Infers LiveView module with fallback to assuming it exists during parent app compilation.
  defp infer_live_view_from_legacy_url_with_fallback("/admin/" <> path_segments) do
    app_base = Routes.phoenix_kit_app_base()

    segments =
      path_segments
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Macro.camelize/1)

    if segments == [] do
      :error
    else
      module_name =
        Module.concat(
          [
            app_base,
            "PhoenixKit",
            "Live",
            "Admin"
          ] ++ segments
        )

      # Try to load the module first
      case Code.ensure_loaded(module_name) do
        {:module, _} ->
          {:ok, module_name}

        {:error, _} ->
          # Module not yet compiled — assume it will be compiled shortly.
          # Emit a warning so devs get feedback if the module truly doesn't exist.
          IO.warn(
            "[PhoenixKit] Auto-inferred LiveView #{inspect(module_name)} from legacy URL " <>
              "\"/admin/#{path_segments}\" but module is not yet loaded. " <>
              "If this route fails at runtime, ensure the module exists."
          )

          {:ok, module_name}
      end
    end
  end

  defp infer_live_view_from_legacy_url_with_fallback(_), do: :error

  # Creates a route declaration from a URL path and LiveView module.
  defp tab_to_route_from_url(path, live_view, tab_id) do
    route_opts = if tab_id, do: [as: tab_id], else: []

    quote do
      live unquote(path), unquote(live_view), :index, unquote(route_opts)
    end
  end

  # Auto-discover admin routes from external PhoenixKit modules.
  # Uses beam file scanning (same pattern as protocol consolidation) — zero config needed.
  # Modules declare their admin tabs with live_view field for route auto-generation.
  # Collects both admin_tabs and settings_tabs for complete route coverage.
  defp compile_module_admin_routes do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.flat_map(fn mod ->
      case Code.ensure_compiled(mod) do
        {:module, _} ->
          admin = collect_module_tabs(mod, :admin_tabs)
          settings = collect_module_tabs(mod, :settings_tabs)
          admin ++ settings

        _ ->
          []
      end
    end)
  end

  # Auto-discover public (non-admin) routes from external PhoenixKit modules.
  # For each external module that implements route_module/0, calls generate(url_prefix)
  # on the returned route module. This replaces hardcoded safe_route_call() lines when
  # internal modules are extracted to separate packages.
  defp compile_module_public_routes(url_prefix) do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.flat_map(fn mod ->
      case Code.ensure_compiled(mod) do
        {:module, _} ->
          if function_exported?(mod, :route_module, 0) do
            route_mod = mod.route_module()
            compile_route_module_generate(route_mod, url_prefix)
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp compile_route_module_generate(nil, _url_prefix), do: []

  defp compile_route_module_generate(route_mod, url_prefix) do
    case Code.ensure_compiled(route_mod) do
      {:module, _} ->
        if function_exported?(route_mod, :generate, 1) do
          normalize_routes(route_mod.generate(url_prefix))
        else
          []
        end

      _ ->
        []
    end
  end

  defp collect_module_tabs(mod, callback) do
    alias PhoenixKit.Dashboard.Tab
    context = tab_callback_context(callback)

    if function_exported?(mod, callback, 0) do
      apply(mod, callback, [])
      |> Enum.map(&Tab.resolve_path(&1, context))
      |> Enum.filter(&tab_has_live_view?/1)
      |> Enum.uniq_by(fn %{path: path} -> path end)
      |> Enum.map(&tab_struct_to_route/1)
    else
      []
    end
  end

  defp tab_callback_context(:admin_tabs), do: :admin
  defp tab_callback_context(:settings_tabs), do: :settings
  defp tab_callback_context(:user_dashboard_tabs), do: :user_dashboard

  defp tab_has_live_view?(%{live_view: {mod, _action}}) when is_atom(mod) do
    case Code.ensure_compiled(mod) do
      {:module, _} ->
        true

      {:error, reason} ->
        IO.warn(
          "[PhoenixKit] Tab references LiveView #{inspect(mod)} which failed to compile: " <>
            "#{inspect(reason)}. Route will be skipped."
        )

        false
    end
  end

  defp tab_has_live_view?(_), do: false

  defp tab_struct_to_route(%{live_view: {module, action}, path: path, id: id}) do
    route_opts = if id, do: [as: id], else: []

    quote do
      live unquote(path), unquote(module), unquote(action), unquote(route_opts)
    end
  end

  defp tab_to_route(tab) do
    {module, action} = tab.live_view
    path = tab[:path] || raise "Tab #{tab[:id]} has :live_view but no :path"
    route_opts = if tab[:id], do: [as: tab[:id]], else: []

    quote do
      live unquote(path), unquote(module), unquote(action), unquote(route_opts)
    end
  end

  # Safely call a route module function at compile time.
  # Returns empty AST if the module isn't available (allows safe extraction).
  @doc false
  def safe_route_call(mod, fun, args) do
    case Code.ensure_compiled(mod) do
      {:module, _} when is_atom(fun) ->
        if function_exported?(mod, fun, length(args)),
          do: apply(mod, fun, args),
          else: quote(do: nil)

      {:error, reason} when reason in [:nofile, :unavailable] ->
        quote(do: nil)

      {:error, reason} ->
        IO.warn(
          "[PhoenixKit] Route module #{inspect(mod)} failed to compile: #{inspect(reason)}. " <>
            "Its routes will be unavailable."
        )

        quote(do: nil)
    end
  end

  # Compile admin routes from external route modules configured via:
  #   config :phoenix_kit, :route_modules, [MyApp.Routes.CustomRoutes]
  # Each module should implement admin_routes/0 or admin_locale_routes/0
  @doc false
  def compile_external_admin_routes(suffix) do
    fun = if suffix == :_locale, do: :admin_locale_routes, else: :admin_routes

    all_route_modules()
    |> Enum.flat_map(&collect_admin_routes(&1, fun))
  end

  # Collect route modules from config + auto-discovered external PhoenixKit modules.
  #
  # Uses Code.ensure_compiled/1 (not Code.ensure_loaded?/1) because this runs
  # at compile time inside macros. ensure_compiled waits for the module to finish
  # compiling if it's currently being compiled, avoiding false negatives during
  # parallel compilation. ensure_loaded? only checks if the module is already
  # loaded and would miss modules still being compiled.
  defp all_route_modules do
    config_modules = PhoenixKit.Config.get(:route_modules, [])

    discovered_route_modules =
      PhoenixKit.ModuleDiscovery.discover_external_modules()
      |> Enum.flat_map(fn mod ->
        case Code.ensure_compiled(mod) do
          {:module, _} ->
            if function_exported?(mod, :route_module, 0) do
              case mod.route_module() do
                nil -> []
                route_mod -> [route_mod]
              end
            else
              []
            end

          _ ->
            []
        end
      end)

    (config_modules ++ discovered_route_modules)
    |> Enum.uniq()
  end

  defp collect_admin_routes(mod, fun) do
    case Code.ensure_compiled(mod) do
      {:module, _} -> resolve_admin_routes(mod, fun)
      _ -> []
    end
  end

  defp resolve_admin_routes(mod, fun) do
    cond do
      function_exported?(mod, fun, 0) -> normalize_routes(apply(mod, fun, []))
      function_exported?(mod, :admin_routes, 0) -> normalize_routes(mod.admin_routes())
      true -> []
    end
  end

  # Compile public routes from external route modules.
  # Each module should implement public_routes/1 (receives url_prefix).
  @doc false
  def compile_external_public_routes(url_prefix) do
    all_route_modules()
    |> Enum.flat_map(&collect_public_routes(&1, url_prefix))
  end

  defp collect_public_routes(mod, url_prefix) do
    case Code.ensure_compiled(mod) do
      {:module, _} ->
        if function_exported?(mod, :public_routes, 1),
          do: normalize_routes(mod.public_routes(url_prefix)),
          else: []

      _ ->
        []
    end
  end

  defp normalize_routes(routes) when is_list(routes), do: routes
  defp normalize_routes(route), do: [route]

  # ============================================================================
  # Route Scope Generators
  # ============================================================================

  # Helper function to generate the localized non-live auth endpoints
  # (form POSTs, OAuth and token GETs). Every localized LiveView surface
  # lives in a unified live_session generated elsewhere.
  defp generate_localized_routes(url_prefix, pattern) do
    # Only include shop session pipeline when the package is installed
    public_pipelines =
      if Code.ensure_loaded?(PhoenixKitEcommerce.Web.Plugs.ShopSession) do
        [
          :browser,
          :phoenix_kit_auto_setup,
          :phoenix_kit_shop_session,
          :phoenix_kit_locale_validation
        ]
      else
        [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]
      end

    quote do
      # Localized scope: non-live auth endpoints only (form POSTs, OAuth
      # and token GETs). Every LiveView surface — public, admin and the
      # authenticated dashboard — lives in its own unified live_session;
      # see `generate_public_live_routes/2`, `generate_admin_routes/2`
      # and `generate_authenticated_live_routes/2`.
      scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb,
        locale: ~r/^(#{unquote(pattern)})$/ do
        pipe_through unquote(public_pipelines)

        # POST routes for authentication (needed for locale-prefixed form submissions)
        post "/users/log-in", Users.Session, :create
        delete "/users/log-out", Users.Session, :delete
        get "/users/log-out", Users.Session, :get_logout
        post "/users/session/accounts", Users.Session, :add_account
        put "/users/session/active", Users.Session, :set_active_account
        delete "/users/session/accounts/:ref", Users.Session, :remove_account
        get "/users/magic-link/:token", Users.MagicLinkVerify, :verify

        # OAuth routes
        get "/users/auth/:provider", Users.OAuth, :request
        get "/users/auth/:provider/callback", Users.OAuth, :callback

        # Magic Link Registration
        get "/users/register/verify/:token", Users.MagicLinkRegistrationVerify, :verify
      end
    end
  end

  # Builds one unified `live_session` for a PhoenixKit LiveView surface
  # (public, admin, or authenticated dashboard).
  #
  # Each surface spans two URL shapes — `/<prefix>/...` for the primary
  # language and `/<prefix>/:locale/...` for every other locale. Both
  # shapes share ONE `live_session`, so a locale switch `push_navigate`s
  # between them and stays on the WebSocket; a split session would force
  # a full-page reload (see the no-prefix plan doc).
  #
  # `route_macro` is the surface's route-table macro
  # (`phoenix_kit_admin_routes` etc.), called once per URL shape with the
  # suffix its route helpers expect.
  defp build_live_surface(url_prefix, pattern, session_name, on_mount, pipelines, route_macro) do
    localized_routes = {route_macro, [], [:_locale]}
    root_routes = {route_macro, [], [:""]}

    quote do
      live_session unquote(session_name), on_mount: unquote(on_mount) do
        scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb,
          locale: ~r/^(#{unquote(pattern)})$/ do
          pipe_through unquote(pipelines)
          unquote(localized_routes)
        end

        scope unquote(url_prefix), PhoenixKitWeb do
          pipe_through unquote(pipelines)
          unquote(root_routes)
        end
      end
    end
  end

  # Pipeline for the public and admin surfaces — neither has a plug-level
  # auth gate (admin gates via the live_session `on_mount`). The
  # shop-session plug is only present when phoenix_kit_ecommerce is.
  defp public_admin_pipelines do
    if Code.ensure_loaded?(PhoenixKitEcommerce.Web.Plugs.ShopSession) do
      [
        :browser,
        :phoenix_kit_auto_setup,
        :phoenix_kit_shop_session,
        :phoenix_kit_locale_validation
      ]
    else
      [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]
    end
  end

  # Public auth/confirmation LiveViews. The permissive
  # :phoenix_kit_mount_current_scope hook is fine — each LiveView runs
  # its own redirect-if-authenticated check in mount/3. Non-live auth
  # endpoints (form POSTs, OAuth/token GETs) stay outside this
  # live_session — in `generate_basic_scope/1` and the localized scope
  # of `generate_localized_routes/2`.
  defp generate_public_live_routes(url_prefix, pattern) do
    build_live_surface(
      url_prefix,
      pattern,
      :phoenix_kit_public,
      [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}],
      public_admin_pipelines(),
      :phoenix_kit_public_routes
    )
  end

  # Admin LiveViews. Gated by the `:phoenix_kit_ensure_admin` on_mount —
  # no plug-level auth gate, so the pipeline matches the public surface.
  defp generate_admin_routes(url_prefix, pattern) do
    build_live_surface(
      url_prefix,
      pattern,
      :phoenix_kit_admin,
      [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}],
      public_admin_pipelines(),
      :phoenix_kit_admin_routes
    )
  end

  # Authenticated dashboard LiveViews. Unlike public/admin these carry a
  # plug-level auth gate (`:phoenix_kit_require_authenticated`) plus the
  # ensure-authenticated-scope and context-provider on_mount hooks.
  defp generate_authenticated_live_routes(url_prefix, pattern) do
    build_live_surface(
      url_prefix,
      pattern,
      :phoenix_kit_authenticated,
      [
        {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
        {PhoenixKitWeb.Dashboard.ContextProvider, :default}
      ],
      [
        :browser,
        :phoenix_kit_auto_setup,
        :phoenix_kit_require_authenticated,
        :phoenix_kit_locale_validation
      ],
      :phoenix_kit_authenticated_routes
    )
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
    pattern = "[a-z]{2,3}(?:-[A-Za-z]{2,4})?"

    # External route modules with public/non-admin routes
    external_public_routes = compile_external_public_routes(url_prefix)

    # Auto-discovered public routes from external PhoenixKit modules
    module_public_routes = compile_module_public_routes(url_prefix)

    # Publishing routing-strategy integration. When the publishing module
    # (with its `RouterDispatch` helper) is in the dep tree, emit:
    #
    #   * the internal-prefix scope (`/__phoenix_kit_publishing_dispatch/...`)
    #     under which publishing's catch-all routes are registered
    #   * a `def call/2` override that path-rewrites publishing-bound URLs
    #     into that prefix so Phoenix's matcher dispatches via the standard
    #     pipeline (sessions, CSRF, locale, scope) and host routes still
    #     win for URLs that don't resolve to a known publishing group.
    #
    # See `PhoenixKitPublishing.RouterDispatch` for the full mechanism
    # (`maybe_rewrite/1`, `restore_path/2`, the `defoverridable call/2`
    # extension point on Phoenix.Router).
    publishing_routing = compile_publishing_routing(url_prefix)

    # Snapshot discovered modules so the host router auto-recompiles when deps change
    current_hash = PhoenixKit.ModuleDiscovery.module_hash()
    mix_lock_path = Path.expand("mix.lock")

    quote do
      # Recompile router when deps change (mix.lock is updated by mix deps.get)
      @external_resource unquote(mix_lock_path)

      # Precise check: only actually recompile if the set of PhoenixKit modules changed
      @doc false
      def __mix_recompile__? do
        unquote(current_hash) != PhoenixKit.ModuleDiscovery.module_hash()
      end

      # Generate pipeline definitions
      unquote(generate_pipelines())

      # Generate basic routes scope
      unquote(generate_basic_scope(url_prefix))

      # Auto-discovered public routes from external modules MUST come before publishing/localized
      # routes to prevent /:language/:group catch-alls from intercepting them (e.g., unsubscribe)
      unquote_splicing(module_public_routes)

      # Generate localized non-live auth endpoints (form POSTs, token GETs)
      unquote(generate_localized_routes(url_prefix, pattern))

      # Generate the LiveView surfaces — each a single live_session
      # spanning both URL shapes, so locale switches stay on the
      # WebSocket. All emitted before the publishing catch-all so
      # `/<prefix>/:locale/...` paths are never shadowed.
      unquote(generate_public_live_routes(url_prefix, pattern))
      unquote(generate_admin_routes(url_prefix, pattern))
      unquote(generate_authenticated_live_routes(url_prefix, pattern))

      # External route modules with public routes
      unquote_splicing(external_public_routes)

      # Publishing internal-prefix scope + call/2 override (when publishing is installed)
      unquote(publishing_routing)
    end
  end

  # Build the publishing routing-strategy AST. Returns `quote do end` (no-op)
  # when publishing is not installed, so the macro stays a single-shape
  # expansion without compile-time conditionals leaking into the host module.
  #
  # `apply/3` is the idiomatic dodge for the compile-time "undefined function"
  # warning when calling into an optional dep — the `Code.ensure_loaded?/1`
  # guard above is the runtime correctness check; `apply/3` shields the
  # compiler's static-resolution pass. (Variable indirection like
  # `mod = PhoenixKitPublishing.RouterDispatch; mod.fun()` does NOT
  # shield the warning — Elixir's compiler tracks the binding's value
  # and still emits `UndefinedFunctionError` warnings on the dispatch.
  # Verified empirically; `apply/3` is the only escape valve for this
  # specific shape.) Drop the `apply/3` calls once publishing becomes
  # a required dep (it isn't, by design — installs without publishing
  # should compile without it on the system).
  #
  # The credo `Refactor.Apply` warnings on the `apply/3` calls below are
  # intentional — see comment above for why the variable-indirection
  # alternative doesn't work.
  #
  # The `apply/3` calls also have a runtime resolution path: the host BEAM
  # compiles the macro expansion (containing literal `apply` calls into
  # `RouterDispatch`) and resolves them at request time. If a host removes
  # publishing from their deps without recompiling core, the cached BEAM
  # would `UndefinedFunctionError` at the next request. This is covered
  # by the `__mix_recompile__?/0` mechanism injected by `phoenix_kit_routes/0`
  # below — the host router's recompile-trigger hash includes the
  # discovered module set, so removing publishing flips the hash and
  # forces a recompile. The `apply` calls drop out of the regenerated AST.
  @doc false
  defp compile_publishing_routing(url_prefix) do
    if Code.ensure_loaded?(PhoenixKitPublishing.RouterDispatch) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      internal_prefix = apply(PhoenixKitPublishing.RouterDispatch, :internal_prefix, [])
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      localized_segment = apply(PhoenixKitPublishing.RouterDispatch, :localized_segment, [])
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      root_segment = apply(PhoenixKitPublishing.RouterDispatch, :root_segment, [])

      internal_scope_path =
        case url_prefix do
          "/" -> "/" <> internal_prefix
          prefix -> prefix <> "/" <> internal_prefix
        end

      localized_sub = "/" <> localized_segment
      root_sub = "/" <> root_segment

      quote do
        pipeline :phoenix_kit_publishing_internal do
          plug PhoenixKitPublishing.RouterDispatch, :restore_path
        end

        scope unquote(internal_scope_path), PhoenixKit.Modules.Publishing.Web do
          pipe_through [
            :browser,
            :phoenix_kit_auto_setup,
            :phoenix_kit_locale_validation,
            :phoenix_kit_optional_scope,
            :phoenix_kit_publishing_internal
          ]

          # Localized form — URL had a leading locale; bind :language + :group.
          scope unquote(localized_sub) do
            get "/:language/:group", Controller, :show
            get "/:language/:group/*path", Controller, :show
          end

          # Non-localized form — URL had no leading locale; bind :group only.
          # Without this discriminator scope, the localized routes above would
          # also match a 2-segment internal path (Phoenix first-match-wins),
          # binding `language=<group-slug>` and `group=<post-slug>` — which
          # then 404s in the controller because the post slug isn't a group.
          scope unquote(root_sub) do
            get "/:group", Controller, :show
            get "/:group/*path", Controller, :show
          end
        end

        # Override Phoenix.Router's call/2 (defoverridable from `use Phoenix.Router`).
        # Path-rewrites publishing-bound URLs before super() runs the matcher.
        # The workspace's url_prefix is threaded in so the dispatch keeps
        # working when PhoenixKit is mounted under a non-root path (e.g.
        # `/phoenix_kit`) — without this, the dispatch's prepended segments
        # land at the head of path_info instead of after the prefix, and
        # nothing matches the registered internal routes.
        # See PhoenixKitPublishing.RouterDispatch for the rationale.
        def call(conn, opts) do
          conn =
            case PhoenixKitPublishing.RouterDispatch.maybe_rewrite(conn, unquote(url_prefix)) do
              {:rewrite, rewritten} -> rewritten
              :pass -> conn
            end

          super(conn, opts)
        end
      end
    else
      quote do
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
