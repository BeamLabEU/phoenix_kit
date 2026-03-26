# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule PhoenixKitWeb.Integration do
  @compile {:no_warn_undefined,
            [
              PhoenixKit.Modules.Shop,
              PhoenixKit.Modules.Shop.Web.Routes,
              PhoenixKit.Modules.Shop.Web.Plugs.ShopSession,
              PhoenixKit.Modules.Shop.Web.UserOrders,
              PhoenixKit.Modules.Shop.Web.UserOrderDetails
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

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb
  alias PhoenixKitWeb.Routes.CustomerServiceRoutes
  alias PhoenixKitWeb.Routes.ReferralsRoutes

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
      if Code.ensure_loaded?(PhoenixKit.Modules.Shop.Web.Plugs.ShopSession) do
        quote do
          pipeline :phoenix_kit_shop_session do
            plug PhoenixKit.Modules.Shop.Web.Plugs.ShopSession
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

        # Cookie consent widget config (public API for JS auto-injection)
        get "/api/consent-config", Controllers.ConsentConfigController, :config

        # Pages routes temporarily disabled
        # get "/pages/*path", PagesController, :show
      end

      # Note: Email export routes moved to generate_emails_routes/1 (separate scope)

      # PhoenixKit static assets (no CSRF protection needed for static files)
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [:phoenix_kit_api]

        get "/assets/:file", AssetsController, :serve
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

  # Generates unified public routes (auth + confirmation + shop) in a single live_session.
  # Auth LiveViews handle the redirect-if-authenticated check in their own mount/3,
  # so the shared session uses the permissive :phoenix_kit_mount_current_scope hook.
  # Shop routes are included here so all public pages share one WebSocket session,
  # enabling seamless LiveView navigation across auth, confirmation, and shop pages.
  defmacro phoenix_kit_public_routes(suffix) do
    session_name = :"phoenix_kit_public#{suffix}"

    # Get shop live route declarations at compile time (no scope/pipeline wrappers)
    shop_live_routes =
      if Code.ensure_loaded?(PhoenixKit.Modules.Shop.Web.Routes) do
        if suffix == :_locale do
          PhoenixKit.Modules.Shop.Web.Routes.public_live_locale_routes()
        else
          PhoenixKit.Modules.Shop.Web.Routes.public_live_routes()
        end
      else
        quote do
        end
      end

    quote do
      live_session unquote(session_name),
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
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
  end

  # Generates all admin routes
  defmacro phoenix_kit_admin_routes(suffix) do
    session_name = :"phoenix_kit_admin#{suffix}"

    # Auto-generate routes for custom admin tabs that specify live_view
    # Skip when compiling PhoenixKit's own dev/test router — parent modules don't exist
    custom_admin_routes = compile_custom_admin_routes(__CALLER__.module)

    # Plugin module routes get their own live_session with admin layout
    # so plugin LiveViews don't need to wrap with LayoutWrapper themselves
    plugin_admin_routes = compile_plugin_admin_routes(__CALLER__.module)

    {tickets_admin, referrals_admin} =
      if suffix == :_locale do
        {
          safe_route_call(CustomerServiceRoutes, :admin_locale_routes, []),
          safe_route_call(ReferralsRoutes, :admin_locale_routes, [])
        }
      else
        {
          safe_route_call(CustomerServiceRoutes, :admin_routes, []),
          safe_route_call(ReferralsRoutes, :admin_routes, [])
        }
      end

    # Shop admin routes via safe_route_call (only when phoenix_kit_ecommerce is installed)
    shop_admin =
      if suffix == :_locale do
        safe_route_call(PhoenixKit.Modules.Shop.Web.Routes, :admin_locale_routes, [])
      else
        safe_route_call(PhoenixKit.Modules.Shop.Web.Routes, :admin_routes, [])
      end

    # External route modules with complex routes (beyond simple admin tabs)
    external_admin_routes = compile_external_admin_routes(suffix)

    quote do
      live_session unquote(session_name),
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
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
        live "/admin/media", Live.Users.Media, :index
        live "/admin/media/:file_uuid", Live.Users.MediaDetail, :show
        live "/admin/media/selector", Live.Users.MediaSelector, :index
        live "/admin/settings", Live.Settings, :index
        live "/admin/settings/users", Live.Settings.Users, :index
        live "/admin/settings/authorization", Live.Settings.Authorization, :index
        live "/admin/settings/organization", Live.Settings.Organization, :index
        live "/admin/modules", Live.Modules, :index

        live "/admin/settings/languages", Live.Modules.Languages, :index
        live "/admin/settings/languages/frontend", Live.Modules.Languages, :frontend
        live "/admin/settings/languages/backend", Live.Modules.Languages, :backend
        live "/admin/settings/legal", Live.Modules.Legal.Settings, :index
        live "/admin/settings/maintenance", Live.Modules.Maintenance.Settings, :index
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

          # DB Explorer routes
          live "/admin/db", PhoenixKit.Modules.DB.Web.Index, :index, as: :db_index

          live "/admin/db/activity", PhoenixKit.Modules.DB.Web.Activity, :activity,
            as: :db_activity

          live "/admin/db/:schema/:table", PhoenixKit.Modules.DB.Web.Show, :show, as: :db_show

          # Shop admin routes (only when phoenix_kit_ecommerce is installed)
          unquote(shop_admin)

          # Routes from external route modules
          unquote(tickets_admin)
          unquote(referrals_admin)

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
  end

  # Generates unified authenticated user routes: dashboard + shop user + tickets user.
  # All routes share one live_session for seamless navigation within the user dashboard.
  # Module routes use alias: false since they live outside the PhoenixKitWeb namespace.
  defmacro phoenix_kit_authenticated_routes(suffix) do
    session_name = :"phoenix_kit_authenticated#{suffix}"

    module_routes =
      if suffix == :_locale do
        authenticated_live_locale_routes()
      else
        authenticated_live_routes()
      end

    quote do
      live_session unquote(session_name),
        on_mount: [
          {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
          {PhoenixKitWeb.Dashboard.ContextProvider, :default}
        ] do
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
  end

  defp authenticated_live_routes do
    shop_user_routes =
      if Code.ensure_loaded?(PhoenixKit.Modules.Shop.Web.UserOrders) do
        quote do
          live "/dashboard/orders", PhoenixKit.Modules.Shop.Web.UserOrders, :index,
            as: :shop_user_orders

          live "/dashboard/orders/:uuid", PhoenixKit.Modules.Shop.Web.UserOrderDetails, :show,
            as: :shop_user_order_details
        end
      else
        quote do
        end
      end

    quote do
      unquote(shop_user_routes)

      # Tickets user pages
      live "/dashboard/customer-service/tickets",
           PhoenixKit.Modules.CustomerService.Web.UserList,
           :index,
           as: :tickets_user_list

      live "/dashboard/customer-service/tickets/new",
           PhoenixKit.Modules.CustomerService.Web.UserNew,
           :new,
           as: :tickets_user_new

      live "/dashboard/customer-service/tickets/:id",
           PhoenixKit.Modules.CustomerService.Web.UserDetails,
           :show,
           as: :tickets_user_details
    end
  end

  defp authenticated_live_locale_routes do
    shop_user_locale_routes =
      if Code.ensure_loaded?(PhoenixKit.Modules.Shop.Web.UserOrders) do
        quote do
          live "/dashboard/orders", PhoenixKit.Modules.Shop.Web.UserOrders, :index,
            as: :shop_user_orders_locale

          live "/dashboard/orders/:uuid", PhoenixKit.Modules.Shop.Web.UserOrderDetails, :show,
            as: :shop_user_order_details_locale
        end
      else
        quote do
        end
      end

    quote do
      unquote(shop_user_locale_routes)

      # Tickets user pages (locale variants)
      live "/dashboard/customer-service/tickets",
           PhoenixKit.Modules.CustomerService.Web.UserList,
           :index,
           as: :tickets_user_list_locale

      live "/dashboard/customer-service/tickets/new",
           PhoenixKit.Modules.CustomerService.Web.UserNew,
           :new,
           as: :tickets_user_new_locale

      live "/dashboard/customer-service/tickets/:id",
           PhoenixKit.Modules.CustomerService.Web.UserDetails,
           :show,
           as: :tickets_user_details_locale
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
  #       %{id: :admin_analytics, label: "Analytics", path: "/admin/analytics",
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

  # Helper function to generate localized routes
  defp generate_localized_routes(url_prefix, pattern) do
    # Only include shop session pipeline when the package is installed
    public_pipelines =
      if Code.ensure_loaded?(PhoenixKit.Modules.Shop.Web.Plugs.ShopSession) do
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
      # Localized scope: public routes (no plug-level auth check) + admin
      scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb,
        locale: ~r/^(#{unquote(pattern)})$/ do
        pipe_through unquote(public_pipelines)

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

        phoenix_kit_public_routes(:_locale)
        phoenix_kit_admin_routes(:_locale)
      end

      # Localized scope: authenticated user routes (plug-level auth check)
      scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb,
        locale: ~r/^(#{unquote(pattern)})$/ do
        pipe_through [
          :browser,
          :phoenix_kit_auto_setup,
          :phoenix_kit_require_authenticated,
          :phoenix_kit_locale_validation
        ]

        phoenix_kit_authenticated_routes(:_locale)
      end
    end
  end

  # Helper function to generate non-localized routes
  defp generate_non_localized_routes(url_prefix) do
    # Only include shop session pipeline when the package is installed
    public_pipelines =
      if Code.ensure_loaded?(PhoenixKit.Modules.Shop.Web.Plugs.ShopSession) do
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
      # Non-localized scope: public routes (no plug-level auth check) + admin
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through unquote(public_pipelines)

        phoenix_kit_public_routes(:"")
        phoenix_kit_admin_routes(:"")
      end

      # Non-localized scope: authenticated user routes (plug-level auth check)
      scope unquote(url_prefix), PhoenixKitWeb do
        pipe_through [
          :browser,
          :phoenix_kit_auto_setup,
          :phoenix_kit_require_authenticated,
          :phoenix_kit_locale_validation
        ]

        phoenix_kit_authenticated_routes(:"")
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
    pattern = "[a-z]{2,3}(?:-[A-Za-z]{2,4})?"

    # Call route generators BEFORE quote block (aliases work in this context)
    # Uses safe_route_call/3 so modules can be safely extracted to separate packages
    customer_service_routes = safe_route_call(CustomerServiceRoutes, :generate, [url_prefix])

    # External route modules with public/non-admin routes
    external_public_routes = compile_external_public_routes(url_prefix)

    # Auto-discovered public routes from external PhoenixKit modules
    module_public_routes = compile_module_public_routes(url_prefix)

    quote do
      # Generate pipeline definitions
      unquote(generate_pipelines())

      # Generate basic routes scope
      unquote(generate_basic_scope(url_prefix))

      # Auto-discovered public routes from external modules MUST come before publishing/localized
      # routes to prevent /:language/:group catch-alls from intercepting them (e.g., unsubscribe)
      unquote_splicing(module_public_routes)

      # Generate module routes from separate files (improves compilation time)
      unquote(customer_service_routes)

      # Generate localized routes
      unquote(generate_localized_routes(url_prefix, pattern))

      # Generate non-localized routes
      unquote(generate_non_localized_routes(url_prefix))

      # External route modules with public routes
      unquote_splicing(external_public_routes)

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
