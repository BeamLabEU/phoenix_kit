defmodule PhoenixKitWeb.Users.Auth do
  @compile {:no_warn_undefined, [PhoenixKitEcommerce, PhoenixKitWeb.Live.Modules.Legal.Settings]}
  @moduledoc """
  Authentication and authorization plugs for PhoenixKit user management.

  This module provides plugs and functions for handling user authentication,
  session management, and access control in Phoenix applications using PhoenixKit.

  ## Key Features

  - User authentication with email and password
  - Remember me functionality with secure cookies
  - Session-based authentication
  - Route protection and access control
  - Module-level permission enforcement via on_mount hooks
  - Integration with Phoenix LiveView on_mount callbacks

  ## on_mount Hooks

  - `:phoenix_kit_ensure_admin` — Requires Owner/Admin role, or a custom role
    with at least one permission. Every role is then checked against the
    permission key mapped to the current admin view: Owner passes because its
    scope holds every key by construction; Admin holds keys as real,
    Owner-revocable rows (seeded/auto-granted by default). Disabled modules
    block everyone. Views that resolve to no permission key allow Owner/Admin
    and deny custom roles (fail-closed where a key could exist).
  - `:phoenix_kit_ensure_module_access` — Checks that the feature module is
    permitted for the scope and (for custom roles) enabled.

  ## Usage

  The plugs in this module are automatically configured when using
  `PhoenixKitWeb.Integration.phoenix_kit_routes/0` macro in your router.
  """
  use PhoenixKitWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView, only: [attach_hook: 4]

  require Logger

  alias Phoenix.LiveView
  alias PhoenixKit.Admin.Events
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Modules.SEO
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.ScopeNotifier
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.SessionFingerprint
  alias PhoenixKitWeb.Users.MultiSession

  # Make the remember me cookie valid for 60 days.
  # If you want bump or reduce this value, also change
  # the token expiry itself in UserToken.
  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_phoenix_kit_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_age,
    same_site: "Lax",
    http_only: true,
    secure: true
  ]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out. The line can be safely removed
  if you are not using LiveView.

  ## Session Fingerprinting

  When session fingerprinting is enabled, this function captures the user's
  IP address and user agent to create a session fingerprint. This helps
  detect session hijacking attempts.
  """
  def log_in_user(conn, user, params \\ %{}) do
    # Create session fingerprint if enabled
    opts =
      if SessionFingerprint.fingerprinting_enabled?() do
        fingerprint = SessionFingerprint.create_fingerprint(conn)
        [fingerprint: fingerprint]
      else
        []
      end

    token = Auth.generate_user_session_token(user, opts)
    user_return_to = get_session(conn, :user_return_to)

    # Merge guest cart into user cart before session renewal clears session data.
    # The shop_session_id cookie survives renew_session (only session data is cleared).
    maybe_merge_guest_cart(conn, user)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  defp maybe_merge_guest_cart(conn, user) do
    if Code.ensure_loaded?(PhoenixKitEcommerce) do
      shop_session_id =
        conn.cookies["shop_session_id"] || get_session(conn, :shop_session_id)

      if shop_session_id do
        try do
          # credo:disable-for-next-line Credo.Check.Design.AliasUsage
          PhoenixKitEcommerce.merge_guest_cart(shop_session_id, user)
        rescue
          _ -> :ok
        end
      end
    end

    conn
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. Locale is no longer kept in
  # session (URL is authoritative; logged-in users persist preference
  # on `user.custom_fields["preferred_locale"]`), so there's nothing
  # to preserve across renewal.
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)

    # Get user info before deleting any token, for the admin notification below.
    user = user_token && Auth.get_user_by_session_token(user_token)

    # Invalidate the active token AND every secondary multi-session account in
    # the stack (stack_tokens/1 falls back to just the active token when no
    # stack is set, so this covers the ordinary single-session logout too).
    # Centralising the drain here means every logout path is covered by
    # construction — and it runs AFTER the user lookup above so the
    # session-disconnect broadcast can still resolve the user.
    MultiSession.delete_all_stack_tokens(conn)

    if live_socket_id = get_session(conn, :live_socket_id) do
      broadcast_disconnect(live_socket_id)
    end

    # Notify admin panel about user logout
    if user do
      session_id = extract_session_id_from_live_socket_id(get_session(conn, :live_socket_id))
      Events.broadcast_user_session_disconnected(user.uuid, session_id)
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: "/")
  end

  @doc """
  Logs out a specific user by invalidating all their session tokens and broadcasting disconnect to their LiveView sessions.

  This function is useful when user roles or permissions change and you need to force re-authentication
  to ensure the user gets updated permissions in their session.

  ## Parameters

  - `user`: The user to log out from all sessions

  ## Examples

      iex> log_out_user_from_all_sessions(user)
      :ok
  """
  def log_out_user_from_all_sessions(user) do
    # Get all session tokens before deleting them
    user_tokens = Auth.get_all_user_session_tokens(user)

    # Broadcast disconnect to all LiveView sessions for this user
    # Each session token creates a unique live_socket_id
    Enum.each(user_tokens, fn token ->
      live_socket_id = "phoenix_kit_sessions:#{Base.url_encode64(token.token)}"
      broadcast_disconnect(live_socket_id)
    end)

    # Delete all session tokens for this user
    Auth.delete_all_user_session_tokens(user)

    :ok
  end

  @doc """
  Authenticates the user by looking into the session
  and remember me token.

  Also verifies session fingerprints if enabled to detect session hijacking attempts.

  This plug is idempotent - if the user has already been fetched, it returns early
  to avoid duplicate database queries.
  """
  def fetch_phoenix_kit_current_user(conn, _opts) do
    # Early return if user already fetched (idempotent)
    if Map.has_key?(conn.assigns, :phoenix_kit_current_user) do
      conn
    else
      do_fetch_phoenix_kit_current_user(conn)
    end
  end

  defp do_fetch_phoenix_kit_current_user(conn) do
    {user_token, conn} = ensure_user_token(conn)

    # Verify session fingerprint if token exists
    fingerprint_valid? =
      if user_token do
        case Auth.verify_session_fingerprint(conn, user_token) do
          :ok ->
            true

          {:warning, reason} ->
            # Log warning but allow access (IP/UA can legitimately change)
            Logger.warning("PhoenixKit: Session fingerprint warning: #{reason} for token")

            # In non-strict mode, allow access despite warning
            not SessionFingerprint.strict_mode?()

          {:error, :fingerprint_mismatch} ->
            # Both IP and UA changed - likely hijacking
            Logger.error(
              "PhoenixKit: Session fingerprint mismatch detected - possible hijacking attempt"
            )

            # Strict mode: deny access; non-strict: log but allow
            not SessionFingerprint.strict_mode?()

          {:error, :token_not_found} ->
            # Token expired or invalid
            false
        end
      else
        true
      end

    user =
      if fingerprint_valid? do
        user_token && Auth.get_user_by_session_token(user_token)
      else
        # Fingerprint verification failed in strict mode
        nil
      end

    # Check if user is active using centralized function
    active_user = Auth.ensure_active_user(user)

    assign(conn, :phoenix_kit_current_user, active_user)
  end

  @doc """
  Fetches the current user and creates a scope for authentication context.

  This plug combines user fetching with scope creation, providing a
  structured way to handle authentication state in your application.

  The scope is assigned to `:phoenix_kit_current_scope` and includes
  both the user and authentication status.

  Also verifies session fingerprints if enabled to detect session hijacking attempts.
  """
  def fetch_phoenix_kit_current_scope(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)

    # Verify session fingerprint if token exists
    fingerprint_valid? =
      if user_token do
        case Auth.verify_session_fingerprint(conn, user_token) do
          :ok ->
            true

          {:warning, reason} ->
            # Log warning but allow access (IP/UA can legitimately change)
            Logger.warning("PhoenixKit: Session fingerprint warning: #{reason} for token (scope)")

            # In non-strict mode, allow access despite warning
            not SessionFingerprint.strict_mode?()

          {:error, :fingerprint_mismatch} ->
            # Both IP and UA changed - likely hijacking
            Logger.error(
              "PhoenixKit: Session fingerprint mismatch detected in scope - possible hijacking"
            )

            # Strict mode: deny access; non-strict: log but allow
            not SessionFingerprint.strict_mode?()

          {:error, :token_not_found} ->
            # Token expired or invalid
            false
        end
      else
        true
      end

    user =
      if fingerprint_valid? do
        user_token && Auth.get_user_by_session_token(user_token)
      else
        # Fingerprint verification failed in strict mode
        nil
      end

    # Check if user is active using centralized function
    active_user = Auth.ensure_active_user(user)

    session = get_session(conn)
    {multi_session_allowed?, multi_session_accounts} = MultiSession.scope_fields(session)

    scope = %{
      Scope.for_user(active_user)
      | multi_session_accounts: multi_session_accounts,
        multi_session_allowed?: multi_session_allowed?
    }

    conn
    |> assign(:phoenix_kit_current_user, active_user)
    |> assign(:phoenix_kit_current_scope, scope)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      case conn.cookies[@remember_me_cookie] do
        token when is_binary(token) -> {token, put_token_in_session(conn, token)}
        _ -> {nil, conn}
      end
    end
  end

  @doc """
  Checks if the current user is authenticated and returns a redirect socket if so.

  Used by auth pages (login, register, etc.) that should not be accessible
  to already-authenticated users when placed in a shared public live_session.

  Returns `{:redirect, redirected_socket}` if authenticated (caller should halt),
  or `:cont` if not authenticated (caller should proceed with normal mount).
  """
  def maybe_redirect_authenticated(socket) do
    if Scope.authenticated?(socket.assigns[:phoenix_kit_current_scope]) do
      {:redirect, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      :cont
    end
  end

  @doc """
  Handles mounting and authenticating the phoenix_kit_current_user in LiveViews.

  ## `on_mount` arguments

    * `:phoenix_kit_mount_current_user` - Assigns phoenix_kit_current_user
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:phoenix_kit_mount_current_scope` - Assigns both phoenix_kit_current_user
      and phoenix_kit_current_scope to socket assigns. The scope provides
      structured access to authentication state.

    * `:phoenix_kit_ensure_authenticated` - Authenticates the user from the session,
      and assigns the phoenix_kit_current_user to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:phoenix_kit_ensure_authenticated_scope` - Authenticates the user via scope system,
      assigns both phoenix_kit_current_user and phoenix_kit_current_scope.

    * `:phoenix_kit_ensure_owner` - Ensures the user has owner role,
      and redirects to the home page if not.

    * `:phoenix_kit_ensure_admin` - Ensures the user has admin or owner role,
      and redirects to the home page if not.
      Redirects to login page if there's no logged user.

    * `:phoenix_kit_redirect_if_user_is_authenticated` - Authenticates the user from the session.
      Redirects to signed_in_path if there's a logged user.

    * `:phoenix_kit_redirect_if_authenticated_scope` - Checks authentication via scope system.
      Redirects to signed_in_path if there's a logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the current_user:

      defmodule PhoenixKitWeb.PageLive do
        use PhoenixKitWeb, :live_view

        on_mount {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_user}
        ...
      end

  Or use the scope system for better encapsulation:

      defmodule PhoenixKitWeb.PageLive do
        use PhoenixKitWeb, :live_view

        on_mount {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:phoenix_kit_mount_current_user, _params, session, socket) do
    {:cont, mount_phoenix_kit_current_user(socket, session)}
  end

  def on_mount(:phoenix_kit_mount_current_scope, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    socket = attach_locale_hook(socket)
    {:cont, socket}
  end

  def on_mount(:phoenix_kit_ensure_authenticated, _params, session, socket) do
    socket = mount_phoenix_kit_current_user(socket, session)

    case socket.assigns.phoenix_kit_current_user do
      %{confirmed_at: nil} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "Please confirm your email before accessing the application."
          )
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/confirm"))

        {:halt, socket}

      %{} ->
        {:cont, socket}

      nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: login_path_with_return_to(socket))

        {:halt, socket}
    end
  end

  def on_mount(:phoenix_kit_ensure_authenticated_scope, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    socket = attach_locale_hook(socket)
    scope = socket.assigns.phoenix_kit_current_scope

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: login_path_with_return_to(socket))

        {:halt, socket}

      Scope.authenticated?(scope) and not email_confirmed?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "Please confirm your email before accessing the application."
          )
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/confirm"))

        {:halt, socket}

      true ->
        {:cont, socket}
    end
  end

  def on_mount(:phoenix_kit_redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_phoenix_kit_current_user(socket, session)

    if socket.assigns.phoenix_kit_current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  def on_mount(:phoenix_kit_redirect_if_authenticated_scope, _params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session)

    if Scope.authenticated?(socket.assigns.phoenix_kit_current_scope) do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      socket = attach_locale_hook(socket)
      {:cont, socket}
    end
  end

  def on_mount(:phoenix_kit_ensure_owner, _params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session)
    scope = socket.assigns.phoenix_kit_current_scope

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: login_path_with_return_to(socket))

        {:halt, socket}

      Scope.authenticated?(scope) and not email_confirmed?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "Please confirm your email before accessing the application."
          )
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/confirm"))

        {:halt, socket}

      not Scope.owner?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must be an owner to access this page.")
          |> Phoenix.LiveView.redirect(to: "/")

        {:halt, socket}

      true ->
        socket = attach_locale_hook(socket)
        {:cont, socket}
    end
  end

  def on_mount(:phoenix_kit_ensure_admin, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    scope = socket.assigns.phoenix_kit_current_scope

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: login_path_with_return_to(socket))

        {:halt, socket}

      Scope.authenticated?(scope) and not email_confirmed?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "Please confirm your email before accessing the application."
          )
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/confirm"))

        {:halt, socket}

      Scope.admin?(scope) ->
        socket = attach_locale_hook(socket)
        socket = maybe_subscribe_to_module_events(socket)
        socket = maybe_apply_plugin_layout(socket)
        enforce_admin_view_permission(socket, scope)

      true ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "You do not have the required role to access this page."
          )
          |> Phoenix.LiveView.redirect(to: "/")

        {:halt, socket}
    end
  end

  def on_mount({:phoenix_kit_ensure_module_access, module_key}, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    scope = socket.assigns.phoenix_kit_current_scope

    # Store current module key for scope refresh checks
    socket = Phoenix.Component.assign(socket, :phoenix_kit_current_module_key, module_key)

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: login_path_with_return_to(socket))

        {:halt, socket}

      Scope.authenticated?(scope) and not email_confirmed?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "Please confirm your email before accessing the application."
          )
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/confirm"))

        {:halt, socket}

      not Scope.admin?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "You do not have the required role to access this page."
          )
          |> Phoenix.LiveView.redirect(to: "/")

        {:halt, socket}

      Scope.has_module_access?(scope, module_key) and
          (Scope.system_role?(scope) or
             MapSet.member?(Permissions.enabled_module_keys(), module_key)) ->
        socket = attach_locale_hook(socket)
        {:cont, socket}

      true ->
        redirect_to = best_available_admin_path(scope)

        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "You do not have permission to access this section."
          )
          |> Phoenix.LiveView.redirect(to: redirect_to)

        {:halt, socket}
    end
  end

  # Attach a hook to handle locale switching events from language switcher
  defp attach_locale_hook(socket) do
    # Check if hook is already attached to avoid duplicates
    if socket.assigns[:phoenix_kit_locale_hook_attached?] do
      socket
    else
      socket
      |> Phoenix.Component.assign(:phoenix_kit_locale_hook_attached?, true)
      |> Phoenix.LiveView.attach_hook(
        :phoenix_kit_locale_handler,
        :handle_event,
        &handle_locale_event/3
      )
    end
  end

  defp handle_locale_event("phoenix_kit_set_locale", %{"locale" => locale, "url" => url}, socket) do
    save_user_locale_preference(socket.assigns, locale)

    # `push_navigate` rather than `redirect`: admin's two URL shapes
    # (`/admin/*` and `/:locale/admin/*`) now share one `live_session`
    # (`:phoenix_kit_admin`), so an in-admin locale switch stays on the
    # WebSocket. For targets in a different live_session (e.g. front-end
    # pages, whose public sessions are still split) `push_navigate`
    # degrades to a full-page load on its own — so it is safe here
    # unconditionally.
    {:halt, Phoenix.LiveView.push_navigate(socket, to: url)}
  end

  defp handle_locale_event(_event, _params, socket), do: {:cont, socket}

  defp save_user_locale_preference(%{phoenix_kit_current_user: %{} = user}, locale)
       when not is_nil(user) do
    Auth.update_user_locale_preference(user, locale)
  end

  defp save_user_locale_preference(%{phoenix_kit_current_scope: scope}, locale) do
    case Scope.user(scope) do
      %{} = user -> Auth.update_user_locale_preference(user, locale)
      _ -> :ok
    end
  end

  defp save_user_locale_preference(_assigns, _locale), do: :ok

  defp set_routing_info(params, url, socket) do
    %{path: path} = URI.parse(url)

    socket =
      socket
      |> Phoenix.Component.assign(:url_path, path)
      |> maybe_update_locale_from_params(params)
      # This hook fires on `handle_params` for every LiveView mounted through
      # PhoenixKit's on_mount chain (admin and host-app public pages alike),
      # so it is the one place that can guarantee `:seo_no_index` reaches
      # root.html.heex's noindex meta tag before the first render — unlike
      # LayoutWrapper.app_layout_inner/1, which only wraps admin/plugin views
      # and never runs for a host app's own public LiveViews. assign_new is
      # a no-op if LayoutWrapper already set it, so this is safe either way.
      |> Phoenix.Component.assign_new(:seo_no_index, fn -> SEO.no_index_enabled?() end)

    {:cont, socket}
  end

  # Update locale assigns when navigating to a URL with a locale param
  defp maybe_update_locale_from_params(socket, %{"locale" => locale}) when is_binary(locale) do
    # Only update if locale actually changed
    current_base = socket.assigns[:current_locale_base]

    if current_base != locale and DialectMapper.valid_base_code?(locale) do
      # URL-driven dialect: `DialectMapper.resolve_dialect/1` maps the base
      # code straight to its default dialect. It deliberately takes no user
      # — a user's `preferred_locale` would otherwise upgrade base "en" →
      # "en-GB", contradicting the URL-is-authoritative semantic we now hold
      # across both the LV mount and the HTTP plug. `preferred_locale` is
      # still written by the switcher hook but no longer read for routing
      # (base or dialect).
      full_dialect = DialectMapper.resolve_dialect(locale)

      # Update Gettext locale — set both the backend-specific value (for
      # PhoenixKitWeb.Gettext callers that look it up explicitly) and the
      # process-global default (so feature modules with their own backends,
      # e.g. PhoenixKitProjects.Gettext, also pick up the new locale without
      # needing per-backend wiring).
      Gettext.put_locale(PhoenixKitWeb.Gettext, full_dialect)
      Gettext.put_locale(full_dialect)

      socket
      |> Phoenix.Component.assign(:current_locale_base, locale)
      |> Phoenix.Component.assign(:current_locale, full_dialect)
    else
      socket
    end
  end

  # No locale in URL = primary language. Snap Gettext + assigns to default.
  #
  # Pre-fix this branch special-cased reserved paths (`/admin`, `/api`, …)
  # to "preserve session locale" — back when admin URLs always carried a
  # locale prefix, the reserved-path snap was unreachable. Now that
  # `Routes.admin_path/2` emits prefixless URLs for the primary language,
  # the reserved-path branch was active and pinned a stale session locale
  # to every prefixless admin navigation (sticky-Estonian bug). Removing
  # the special case restores the URL-is-authoritative semantics.
  defp maybe_update_locale_from_params(socket, _params) do
    default_base = Routes.get_default_admin_locale()
    current_base = socket.assigns[:current_locale_base]

    if current_base == default_base do
      socket
    else
      # URL-driven dialect (see sibling clause above for the rationale —
      # `preferred_locale` is intentionally ignored for routing).
      default_dialect = DialectMapper.resolve_dialect(default_base)

      Gettext.put_locale(PhoenixKitWeb.Gettext, default_dialect)
      Gettext.put_locale(default_dialect)

      socket
      |> Phoenix.Component.assign(:current_locale_base, default_base)
      |> Phoenix.Component.assign(:current_locale, default_dialect)
    end
  end

  defp mount_phoenix_kit_current_user(socket, session) do
    socket =
      attach_hook(
        socket,
        :current_page,
        :handle_params,
        &set_routing_info(&1, &2, &3)
      )

    Phoenix.Component.assign_new(socket, :phoenix_kit_current_user, fn ->
      case session["user_token"] do
        nil -> nil
        user_token -> get_active_user_from_token(user_token)
      end
    end)
  end

  defp get_active_user_from_token(user_token) do
    user = Auth.get_user_by_session_token(user_token)
    Auth.ensure_active_user(user)
  end

  @doc """
  Reconstructs and assigns the current user + scope on an **embedded**
  LiveView mount from a host-supplied `session["current_user_uuid"]`.

  A LiveView rendered via `live_render/3` mounts with
  `:not_mounted_at_router`, so it never runs a router `live_session`'s
  `on_mount` hook (e.g. `:phoenix_kit_ensure_admin`) — leaving
  `:phoenix_kit_current_scope` / `:phoenix_kit_current_user` absent, which
  blinds any user-aware embedded UI (comment composers, activity-actor
  attribution). The host bridges identity across the `live_render`
  process boundary by passing its own authenticated user's UUID as
  `session["current_user_uuid"]` — a **string**, never the `%User{}`
  struct (a signed-but-not-encrypted `live_render` session would expose
  it to the client). This helper reloads that user and assigns both
  `:phoenix_kit_current_user` and `:phoenix_kit_current_scope`.

    * No-op when `:phoenix_kit_current_scope` is already assigned (router
      mount — the `on_mount` hook ran, before `mount/3`). Never clobbers
      the canonical scope.
    * An active user → assigns it + `Scope.for_user(user)`.
    * Absent / unknown / inactive uuid, or a transient DB error →
      anonymous (`nil` user + `Scope.for_user(nil)`), never raising.

  > This reconstructs **identity** (audit, comment authorship), not
  > **authorization** — it performs no role check. The UUID must come
  > from the host's trusted server-side scope, never request params; and
  > a host embedding an admin LiveView must gate the embedding page
  > itself (the `on_mount` admin gate does not run for embeds).

  Generic across embeddable feature modules — `phoenix_kit_projects` is
  the reference consumer.
  """
  @spec assign_embedded_current_user(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def assign_embedded_current_user(socket, session) when is_map(session) do
    if is_nil(socket.assigns[:phoenix_kit_current_scope]) do
      {user, scope} = reconstruct_embedded_identity(Map.get(session, "current_user_uuid"))

      socket
      |> Phoenix.Component.assign(:phoenix_kit_current_user, user)
      |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
    else
      socket
    end
  end

  def assign_embedded_current_user(socket, _session), do: socket

  defp reconstruct_embedded_identity(uuid) when is_binary(uuid) and uuid != "" do
    user = uuid |> Auth.get_user() |> Auth.ensure_active_user()

    if is_nil(user) do
      Logger.warning(
        "[phoenix_kit] embedded current_user_uuid=#{inspect(uuid)} did not resolve " <>
          "to an active user — embedded UI degrades to anonymous"
      )
    end

    {user, Scope.for_user(user)}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning(
        "[phoenix_kit] failed to load embedded user #{inspect(uuid)}: " <>
          Exception.message(e) <> " — degrading to anonymous"
      )

      {nil, Scope.for_user(nil)}
  end

  defp reconstruct_embedded_identity(_), do: {nil, Scope.for_user(nil)}

  defp mount_phoenix_kit_current_scope(socket, session, params \\ %{}) do
    socket =
      socket
      |> mount_phoenix_kit_current_user(session)
      |> maybe_attach_scope_refresh_hook()

    user = socket.assigns.phoenix_kit_current_user
    {multi_session_allowed?, multi_session_accounts} = MultiSession.scope_fields(session)

    scope = %{
      Scope.for_user(user)
      | multi_session_accounts: multi_session_accounts,
        multi_session_allowed?: multi_session_allowed?
    }

    # Locale is URL-driven: the URL's `:locale` segment wins; absent
    # that, we fall straight to the default. The previous session-locale
    # fallback ("remember the last-picked locale across prefixless URLs")
    # caused a sticky-locale bug after `Routes.path/2` was changed to
    # emit prefixless URLs for the primary language — e.g. visiting
    # `/foo/et/...` once stashed `"et"` in the session, then every
    # primary-prefixless URL inherited Estonian forever. Pure URL→default
    # makes prefixless URL ≡ primary language, which matches what the
    # URL helpers now emit.
    current_locale_base =
      case params do
        %{"locale" => locale} when is_binary(locale) and locale != "" ->
          if DialectMapper.valid_base_code?(locale), do: locale, else: nil

        _ ->
          nil
      end ||
        Routes.get_default_admin_locale()

    # URL-driven dialect: `resolve_dialect/1` returns the default mapping
    # for this base. The user's preferred_locale is intentionally NOT
    # consulted for routing (see `maybe_update_locale_from_params/2` for
    # the matching rationale).
    current_locale = DialectMapper.resolve_dialect(current_locale_base)

    # Set Gettext locale for translations (backend-specific + global, so
    # module backends like PhoenixKitProjects.Gettext sync too).
    Gettext.put_locale(PhoenixKitWeb.Gettext, current_locale)
    Gettext.put_locale(current_locale)

    socket
    |> maybe_manage_scope_subscription(user)
    |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
    |> Phoenix.Component.assign(:current_locale, current_locale)
    |> Phoenix.Component.assign(:current_locale_base, current_locale_base)
    # Fold the maintenance check into the shared scope mount so any new
    # live_session that uses a scope-mounting hook can't forget it.
    |> check_maintenance_mode()
  end

  defp maybe_attach_scope_refresh_hook(
         %{assigns: %{phoenix_kit_scope_hook_attached?: true}} = socket
       ),
       do: socket

  defp maybe_attach_scope_refresh_hook(socket) do
    socket
    |> attach_hook(:phoenix_kit_scope_refresh, :handle_info, &handle_scope_refresh/2)
    |> Phoenix.Component.assign(:phoenix_kit_scope_hook_attached?, true)
  end

  defp maybe_manage_scope_subscription(socket, %User{uuid: user_uuid})
       when is_binary(user_uuid) do
    case socket.assigns[:phoenix_kit_scope_subscription_user_uuid] do
      ^user_uuid ->
        socket

      previous_uuid when is_binary(previous_uuid) ->
        ScopeNotifier.unsubscribe(previous_uuid)
        ScopeNotifier.subscribe(user_uuid)

        Phoenix.Component.assign(socket, :phoenix_kit_scope_subscription_user_uuid, user_uuid)

      _ ->
        ScopeNotifier.subscribe(user_uuid)
        Phoenix.Component.assign(socket, :phoenix_kit_scope_subscription_user_uuid, user_uuid)
    end
  end

  defp maybe_manage_scope_subscription(socket, _user) do
    maybe_unsubscribe_scope_updates(socket)
  end

  defp maybe_unsubscribe_scope_updates(socket) do
    if previous_uuid = socket.assigns[:phoenix_kit_scope_subscription_user_uuid] do
      ScopeNotifier.unsubscribe(previous_uuid)
    end

    Phoenix.Component.assign(socket, :phoenix_kit_scope_subscription_user_uuid, nil)
  end

  defp handle_scope_refresh({:phoenix_kit_scope_roles_updated, user_uuid}, socket) do
    current_scope = socket.assigns[:phoenix_kit_current_scope]

    if Scope.user_uuid(current_scope) == user_uuid do
      was_admin = Scope.admin?(current_scope)
      {socket, new_scope} = refresh_scope_assigns(socket)

      socket =
        cond do
          # Lost admin role entirely
          was_admin and not Scope.admin?(new_scope) ->
            socket
            |> LiveView.put_flash(:error, "You must be an admin to access this page.")
            |> LiveView.push_navigate(to: "/")

          # Still admin but lost access to current module
          Scope.admin?(new_scope) and
              not has_current_module_access?(socket, new_scope) ->
            redirect_to = best_available_admin_path(new_scope)

            socket
            |> LiveView.put_flash(
              :error,
              "You no longer have permission to access this section."
            )
            |> LiveView.push_navigate(to: redirect_to)

          true ->
            socket
        end

      {:halt, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_scope_refresh(_msg, socket), do: {:cont, socket}

  # Subscribe to module enable/disable events so the admin sidebar updates
  # in real-time when modules are toggled. Follows the scope refresh pattern.
  defp maybe_subscribe_to_module_events(
         %{assigns: %{phoenix_kit_module_hook_attached?: true}} = socket
       ),
       do: socket

  defp maybe_subscribe_to_module_events(socket) do
    Events.subscribe_to_modules()

    socket
    |> attach_hook(:phoenix_kit_module_refresh, :handle_info, &handle_module_refresh/2)
    |> Phoenix.Component.assign(:phoenix_kit_module_hook_attached?, true)
  end

  defp handle_module_refresh({:module_enabled, _key}, socket) do
    {:halt,
     Phoenix.Component.assign(socket, :phoenix_kit_modules_version, System.unique_integer())}
  end

  defp handle_module_refresh({:module_disabled, _key}, socket) do
    {:halt,
     Phoenix.Component.assign(socket, :phoenix_kit_modules_version, System.unique_integer())}
  end

  defp handle_module_refresh(_msg, socket), do: {:cont, socket}

  # Auto-apply admin layout for external plugin LiveViews.
  # Core views (PhoenixKitWeb.* and PhoenixKit.Modules.* bundled in :phoenix_kit)
  # handle layout via LayoutWrapper in their templates. External plugin views
  # (from extracted packages like :phoenix_kit_ecommerce, or parent app views)
  # need it applied at the session level so plugin authors don't need to wrap anything.
  defp maybe_apply_plugin_layout(socket) do
    view = socket.view

    if external_plugin_view?(view) do
      put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :admin})
    else
      socket
    end
  end

  defp external_plugin_view?(view) do
    case Module.split(view) do
      ["PhoenixKitWeb" | _] ->
        false

      ["PhoenixKit", "Modules", _, "Web" | _] ->
        # Only treat as external if the module comes from a separate package.
        # Core modules bundled in :phoenix_kit handle their own layout via
        # LayoutWrapper.app_layout in their templates.
        not core_phoenix_kit_module?(view)

      ["PhoenixKit" | _] ->
        false

      _ ->
        true
    end
  end

  defp core_phoenix_kit_module?(view) do
    case :application.get_application(view) do
      {:ok, :phoenix_kit} -> true
      _ -> false
    end
  end

  # Priority-ordered list of admin sections to try when redirecting
  # a user who lacks access to the requested page.
  # Priority-ordered fallback routes for redirecting users who lack access.
  # Top-level module pages first, then settings sub-pages.
  @admin_fallback_routes [
    # Core admin sections
    {"dashboard", "/admin"},
    {"users", "/admin/users"},
    {"settings", "/admin/settings"},
    {"modules", "/admin/modules"},
    {"media", "/admin/media"},
    # Top-level feature module pages
    {"shop", "/admin/shop"},
    {"posts", "/admin/posts"},
    {"comments", "/admin/comments"},
    {"billing", "/admin/billing"},
    {"entities", "/admin/entities"},
    {"customer_support", "/admin/customer-support/tickets"},
    {"emails", "/admin/emails"},
    {"ai", "/admin/ai"},
    {"jobs", "/admin/jobs"},
    {"db", "/admin/db"},
    {"publishing", "/admin/publishing"},
    # Settings sub-pages (lower priority landing pages)
    {"languages", "/admin/settings/languages"},
    {"seo", "/admin/settings/seo"},
    {"sitemap", "/admin/settings/sitemap"},
    {"maintenance", "/admin/settings/maintenance"},
    {"legal", "/admin/settings/legal"},
    {"referrals", "/admin/settings/referral-codes"}
  ]

  # Find the best admin page the user has access to, falling back to "/"
  # Checks both permission (user can access) AND enabled status (module is active)
  # to prevent redirect loops when a user has permission for a disabled module.
  defp best_available_admin_path(scope) do
    enabled = Permissions.enabled_module_keys()

    # Built-in routes first, then custom extension routes from admin tab config
    all_routes = @admin_fallback_routes ++ custom_admin_fallback_routes()

    Enum.find_value(all_routes, "/", fn {key, path} ->
      if Scope.has_module_access?(scope, key) and MapSet.member?(enabled, key),
        do: Routes.path(path)
    end)
  end

  # Builds fallback routes from custom admin tabs that have extension permission keys.
  # Only includes top-level tabs (no parent) with a permission not in the built-in set.
  defp custom_admin_fallback_routes do
    builtin = MapSet.new(Enum.map(@admin_fallback_routes, &elem(&1, 0)))

    case Application.get_env(:phoenix_kit, :admin_dashboard_tabs) do
      tabs when is_list(tabs) ->
        tabs
        |> Enum.filter(fn tab ->
          is_map(tab) and is_binary(tab[:permission]) and
            tab[:parent] == nil and
            not MapSet.member?(builtin, tab[:permission])
        end)
        |> Enum.sort_by(& &1[:priority])
        |> Enum.map(fn tab -> {tab.permission, tab.path} end)

      _ ->
        []
    end
  end

  # Enforces module-level permission checks for admin views.
  # Extracted from on_mount(:phoenix_kit_ensure_admin) to reduce complexity.
  defp enforce_admin_view_permission(socket, scope) do
    case permission_key_for_admin_view(socket.view) do
      nil ->
        # Unmapped views: fail-closed for custom roles, allow Admin/Owner
        Logger.debug(
          "[Auth] Admin view #{inspect(socket.view)} has no permission mapping — " <>
            "allowing system roles, denying custom roles"
        )

        if Scope.system_role?(scope) do
          {:cont, socket}
        else
          deny_admin_access(socket, scope)
        end

      module_key ->
        socket =
          Phoenix.Component.assign(socket, :phoenix_kit_current_module_key, module_key)

        module_enabled = Permissions.feature_enabled?(module_key)

        cond do
          # Disabled modules are blocked for all roles (including Owner/Admin)
          not module_enabled ->
            deny_module_disabled(socket, module_key)

          # Every role — Admin included — needs the permission key. Owner
          # passes because its scope holds every key by construction; Admin
          # holds keys as real rows (seeded/auto-granted, Owner-revocable).
          # The old system-role bypass here made Owner's revocations on the
          # Admin role effective everywhere EXCEPT fresh mounts — sidebar,
          # plugs, and the mid-session PubSub kick all honored them already.
          Scope.has_module_access?(scope, module_key) ->
            {:cont, socket}

          true ->
            deny_admin_access(socket, scope)
        end
    end
  end

  defp deny_module_disabled(socket, module_key) do
    label = Permissions.module_label(module_key)

    socket =
      socket
      |> Phoenix.LiveView.put_flash(:error, "#{label} module is not enabled")
      |> Phoenix.LiveView.redirect(to: Routes.path("/admin/modules"))

    {:halt, socket}
  end

  defp deny_admin_access(socket, scope) do
    redirect_to = best_available_admin_path(scope)

    socket =
      socket
      |> Phoenix.LiveView.put_flash(
        :error,
        "You do not have permission to access this section."
      )
      |> Phoenix.LiveView.redirect(to: redirect_to)

    {:halt, socket}
  end

  # Check if user still has access to the currently viewed module
  defp has_current_module_access?(socket, scope) do
    case socket.assigns[:phoenix_kit_current_module_key] do
      nil -> true
      module_key -> Scope.has_module_access?(scope, module_key)
    end
  end

  # Maps admin LiveView modules to their permission keys.
  # Used by :phoenix_kit_ensure_admin to enforce module-level permissions
  # on core admin routes that share the same live_session.
  # Returns nil for unmapped views (allows access by default for backward compat).
  @admin_view_permissions %{
    PhoenixKitWeb.Live.Dashboard => "dashboard",
    PhoenixKitWeb.Live.Modules => "modules",
    PhoenixKitWeb.Live.Users.Users => "users",
    PhoenixKitWeb.Users.UserForm => "users",
    PhoenixKitWeb.Live.Users.UserDetails => "users",
    PhoenixKitWeb.Live.Users.Roles => "users",
    PhoenixKitWeb.Live.Users.PermissionsMatrix => "users",
    PhoenixKitWeb.Live.Users.LiveSessions => "users",
    PhoenixKitWeb.Live.Users.Sessions => "users",
    PhoenixKitWeb.Live.Users.Media => "media",
    PhoenixKitWeb.Live.Users.MediaDetail => "media",
    PhoenixKitWeb.Live.Users.MediaSelector => "media",
    PhoenixKitWeb.Live.Settings => "settings",
    PhoenixKitWeb.Live.Settings.Users => "settings",
    PhoenixKitWeb.Live.Settings.Organization => "settings",
    PhoenixKitWeb.Live.Settings.SEO => "seo",
    PhoenixKitWeb.Live.Modules.Languages => "languages",
    PhoenixKitWeb.Live.Modules.Maintenance.Settings => "maintenance",
    PhoenixKitWeb.Live.Modules.Storage.Settings => "media",
    PhoenixKitWeb.Live.Modules.Storage.BucketForm => "media",
    PhoenixKitWeb.Live.Modules.Storage.Dimensions => "media",
    PhoenixKitWeb.Live.Modules.Storage.DimensionForm => "media",
    PhoenixKitWeb.Live.Modules.Jobs.Index => "jobs"
  }

  # Resolve a LiveView module to its permission key.
  #
  # Resolution order (first non-nil wins):
  #
  #   1. `@admin_view_permissions` static map — core admin views.
  #   2. `infer_permission_from_custom_tabs/1` — modules that registered
  #      admin tabs with a `live_view:` field.
  #   3. `PhoenixKit.Modules.<X>.Web.*` namespace inference — internal
  #      modules under the core namespace.
  #   4. Plugin top-level namespace via `ModuleRegistry` — external
  #      packages whose top-level module name matches a registered
  #      module (e.g. `PhoenixKitEntities` → `"entities"`).
  #
  # Returns `nil` for views that don't resolve through any path —
  # callers must apply their own fail-closed default.
  #
  # Exposed as `@doc false def` (rather than `defp`) so unit tests can
  # exercise the resolution layers directly without LiveView mounting
  # machinery. Not part of the public API.
  @doc false
  def permission_key_for_admin_view(view_module) do
    case Map.get(@admin_view_permissions, view_module) do
      nil ->
        infer_permission_from_custom_tabs(view_module) ||
          infer_permission_key_from_module(view_module)

      key ->
        key
    end
  end

  # Looks up permission key from cached custom view → permission mapping.
  # This mapping is populated at Registry init time from :admin_dashboard_tabs config.
  defp infer_permission_from_custom_tabs(view_module) do
    Permissions.custom_view_permissions()
    |> Map.get(view_module)
  end

  # Infer permission key from `PhoenixKit.Modules.<Name>.Web.*` (core) or from a
  # registered external plugin's top-level namespace
  # (`PhoenixKitEntities.*`, `PhoenixKitBilling.*`, …) via `ModuleRegistry`.
  defp infer_permission_key_from_module(view_module) do
    case Module.split(view_module) do
      ["PhoenixKit", "Modules", module_name | _rest] ->
        Macro.underscore(module_name)

      [top | _rest] ->
        ModuleRegistry.get_module_key_for_namespace(top)
    end
  end

  # Applies maintenance mode layout for non-admin users when maintenance is active.
  # Instead of redirecting, overrides the LiveView's layout so the maintenance page
  # renders in place of whatever page the user is on. URL never changes.
  # Also attaches a PubSub hook so that when maintenance status changes,
  # the page updates automatically without requiring navigation.
  #
  # Called from mount_phoenix_kit_current_scope/3 so every live_session that uses
  # a scope-mounting on_mount hook automatically inherits maintenance mode
  # enforcement. New on_mount hooks don't need to remember to call this.
  defp check_maintenance_mode(socket) do
    # Clean up stale state if the scheduled end time has passed
    Maintenance.cleanup_expired_schedule()

    if Maintenance.active?() do
      scope = socket.assigns[:phoenix_kit_current_scope]

      cond do
        # Auth routes must always be accessible (login, password reset, etc.)
        auth_route?(socket) ->
          maybe_attach_maintenance_hook(socket)

        # Admins and owners bypass maintenance mode
        scope && (Scope.admin?(scope) || Scope.owner?(scope)) ->
          maybe_attach_maintenance_hook(socket)

        # Everyone else gets the maintenance layout
        true ->
          socket
          |> save_original_layout()
          |> put_in([Access.key(:private), :live_layout], {PhoenixKitWeb.Layouts, :maintenance})
          |> maybe_attach_maintenance_hook()
      end
    else
      socket
      |> save_original_layout()
      |> maybe_attach_maintenance_hook()
    end
  end

  # Save the current layout so we can restore it when maintenance ends
  defp save_original_layout(socket) do
    if socket.assigns[:phoenix_kit_original_layout] do
      socket
    else
      Phoenix.Component.assign(socket, :phoenix_kit_original_layout, socket.private[:live_layout])
    end
  end

  # Attach a PubSub hook that listens for maintenance status changes.
  # When maintenance toggles on/off, forces a remount so the layout is re-evaluated.
  #
  # on_mount runs twice: disconnected (HTTP) then connected (WebSocket).
  # The hook is attached on the first run, but PubSub subscription must happen
  # on the connected mount — so we track them with separate flags.
  defp maybe_attach_maintenance_hook(socket) do
    socket =
      if Phoenix.LiveView.connected?(socket) and
           !socket.assigns[:phoenix_kit_maintenance_subscribed?] do
        Maintenance.subscribe()

        socket
        |> Phoenix.Component.assign(:phoenix_kit_maintenance_subscribed?, true)
        |> reschedule_maintenance_end_timer()
      else
        socket
      end

    if socket.assigns[:phoenix_kit_maintenance_hook_attached?] do
      socket
    else
      socket
      |> attach_hook(:phoenix_kit_maintenance, :handle_info, &handle_maintenance_change/2)
      |> Phoenix.Component.assign(:phoenix_kit_maintenance_hook_attached?, true)
    end
  end

  # Erlang's Process.send_after/3 takes at most a 32-bit timeout in ms (~24.8 days).
  # validate_schedule/2 caps schedules at 1 year, but clamp here defensively.
  @max_timer_ms 2_147_483_647

  # Cancels any stale timer and schedules a new one for the current scheduled end.
  # Called on connected mount and whenever the schedule changes via PubSub.
  # This handles the case where a user is sitting on a maintenance-blocked page
  # and the scheduled end time arrives — they get unblocked automatically.
  defp reschedule_maintenance_end_timer(socket) do
    # Cancel any existing timer so we don't leak a fire-after-schedule-changed signal.
    case socket.assigns[:phoenix_kit_maintenance_timer_ref] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    timer_ref =
      case Maintenance.get_scheduled_end() do
        %DateTime{} = end_dt ->
          seconds = DateTime.diff(end_dt, DateTime.utc_now())

          if seconds > 0 do
            timeout_ms = min(seconds * 1000, @max_timer_ms)

            Process.send_after(
              self(),
              {:maintenance_status_changed, %{active: false}},
              timeout_ms
            )
          end

        _ ->
          nil
      end

    Phoenix.Component.assign(socket, :phoenix_kit_maintenance_timer_ref, timer_ref)
  end

  defp handle_maintenance_change({:maintenance_status_changed, _payload}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && (Scope.admin?(scope) || Scope.owner?(scope)) do
      {:cont, socket}
    else
      # Schedule may have changed — re-read the end time and reset the auto-off timer.
      # Note: we intentionally distrust the payload's :active value and re-check via
      # Maintenance.active?/0 so late-arriving stale messages don't drive the UI.
      socket = reschedule_maintenance_end_timer(socket)

      if Maintenance.active?() do
        # Swap to maintenance layout — LiveView keeps running, form state preserved.
        # Must also touch an assign to trigger a re-render (private changes alone don't).
        # HACK: socket.private[:live_layout] is Phoenix LiveView internals (same pattern
        # used by maybe_apply_plugin_layout). Revisit if Phoenix.LiveView 1.x changes.
        socket =
          socket
          |> put_in([Access.key(:private), :live_layout], {PhoenixKitWeb.Layouts, :maintenance})
          |> Phoenix.Component.assign(:phoenix_kit_maintenance_active, true)

        {:halt, socket}
      else
        # Restore the original layout — form state still preserved in assigns.
        # If original was nil (no layout set), remove the key entirely instead of
        # setting it to nil, which would crash the renderer.
        original = socket.assigns[:phoenix_kit_original_layout]

        socket =
          if original do
            put_in(socket.private[:live_layout], original)
          else
            %{socket | private: Map.delete(socket.private, :live_layout)}
          end

        socket = Phoenix.Component.assign(socket, :phoenix_kit_maintenance_active, false)

        {:halt, socket}
      end
    end
  end

  defp handle_maintenance_change(_msg, socket), do: {:cont, socket}

  # Auth views that must always be accessible during maintenance
  defp auth_route?(socket) do
    case socket.view do
      PhoenixKitWeb.Users.Login -> true
      PhoenixKitWeb.Users.ForgotPassword -> true
      PhoenixKitWeb.Users.ResetPassword -> true
      PhoenixKitWeb.Users.MagicLink -> true
      PhoenixKitWeb.Users.MagicLinkRegistrationRequest -> true
      PhoenixKitWeb.Users.MagicLinkRegistration -> true
      PhoenixKitWeb.Users.Confirmation -> true
      PhoenixKitWeb.Users.ConfirmationInstructions -> true
      _ -> false
    end
  end

  defp refresh_scope_assigns(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %User{uuid: user_uuid} ->
        case Auth.get_user(user_uuid) do
          %User{} = user ->
            scope = Scope.for_user(user)

            socket =
              socket
              |> Phoenix.Component.assign(:phoenix_kit_current_user, user)
              |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
              |> maybe_manage_scope_subscription(user)

            {socket, scope}

          nil ->
            scope = Scope.for_user(nil)

            socket =
              socket
              |> Phoenix.Component.assign(:phoenix_kit_current_user, nil)
              |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
              |> maybe_unsubscribe_scope_updates()

            {socket, scope}
        end

      _ ->
        scope = socket.assigns[:phoenix_kit_current_scope] || Scope.for_user(nil)
        {socket, scope}
    end
  end

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, :fetch_phoenix_kit_current_user),
    do: fetch_phoenix_kit_current_user(conn, [])

  @doc false
  def call(conn, :fetch_phoenix_kit_current_scope),
    do: fetch_phoenix_kit_current_scope(conn, [])

  @doc false
  def call(conn, :phoenix_kit_redirect_if_user_is_authenticated),
    do: redirect_if_user_is_authenticated(conn, [])

  @doc false
  def call(conn, :phoenix_kit_require_authenticated_user),
    do: require_authenticated_user(conn, [])

  @doc false
  def call(conn, :phoenix_kit_require_authenticated_scope),
    do: require_authenticated_scope(conn, [])

  @doc false
  def call(conn, :phoenix_kit_validate_and_set_locale),
    do: validate_and_set_locale(conn, [])

  @doc false
  def call(conn, :phoenix_kit_require_admin),
    do: require_admin(conn, [])

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:phoenix_kit_current_user] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  Enforces email confirmation before allowing access to the application.
  """
  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{confirmed_at: nil} ->
        conn
        |> put_flash(:error, "Please confirm your email before accessing the application.")
        |> redirect(to: Routes.path("/users/confirm"))
        |> halt()

      %{} ->
        conn

      nil ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> maybe_store_return_to()
        |> redirect(to: Routes.path("/users/log-in"))
        |> halt()
    end
  end

  @doc """
  Used for routes that require the user to be authenticated via scope.

  This function checks authentication status through the scope system,
  providing a more structured approach to authentication checks.

  Enforces email confirmation before allowing access to the application.
  """
  def require_authenticated_scope(conn, _opts) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope ->
        cond do
          not Scope.authenticated?(scope) ->
            conn
            |> put_flash(:error, "You must log in to access this page.")
            |> maybe_store_return_to()
            |> redirect(to: Routes.path("/users/log-in"))
            |> halt()

          Scope.authenticated?(scope) and not email_confirmed?(scope) ->
            conn
            |> put_flash(:error, "Please confirm your email before accessing the application.")
            |> redirect(to: Routes.path("/users/confirm"))
            |> halt()

          true ->
            conn
        end

      _ ->
        # Scope not found, try to create it from current_user
        conn
        |> fetch_phoenix_kit_current_scope([])
        |> require_authenticated_scope([])
    end
  end

  defp email_confirmed?(%Scope{user: %{confirmed_at: confirmed_at}})
       when not is_nil(confirmed_at),
       do: true

  defp email_confirmed?(_), do: false

  @doc """
  Used for routes that require the user to be an owner.

  If you want to enforce the owner requirement without
  redirecting to the login page, consider using
  `:phoenix_kit_require_authenticated_scope` instead.
  """
  def require_owner(conn, _opts) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope ->
        if Scope.owner?(scope) do
          conn
        else
          conn
          |> put_flash(:error, "You must be an owner to access this page.")
          |> redirect(to: "/")
          |> halt()
        end

      _ ->
        # Scope not found, try to create it from current_user
        conn
        |> fetch_phoenix_kit_current_scope([])
        |> require_owner([])
    end
  end

  @doc """
  Used for routes that require the user to be an admin or owner.

  If you want to enforce the admin requirement without
  redirecting to the login page, consider using
  `:phoenix_kit_require_authenticated_scope` instead.
  """
  def require_admin(conn, _opts) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope ->
        cond do
          Scope.admin?(scope) ->
            conn

          Scope.authenticated?(scope) ->
            conn
            |> put_flash(:error, "You do not have the required role to access this page.")
            |> redirect(to: "/")
            |> halt()

          true ->
            conn
            |> put_flash(:error, "You must log in to access this page.")
            |> redirect(to: Routes.path("/users/log-in"))
            |> halt()
        end

      _ ->
        conn
        |> fetch_phoenix_kit_current_scope([])
        |> require_admin([])
    end
  end

  @doc """
  Used for routes that require the user to have module-level permission.
  """
  def require_module_access(conn, module_key) when is_binary(module_key) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope ->
        cond do
          not Scope.admin?(scope) ->
            conn
            |> put_flash(:error, "You do not have the required role to access this page.")
            |> redirect(to: "/")
            |> halt()

          Scope.has_module_access?(scope, module_key) and
              (Scope.system_role?(scope) or
                 MapSet.member?(Permissions.enabled_module_keys(), module_key)) ->
            conn

          true ->
            conn
            |> put_flash(:error, "You do not have permission to access this section.")
            |> redirect(to: best_available_admin_path(scope))
            |> halt()
        end

      _ ->
        conn
        |> fetch_phoenix_kit_current_scope([])
        |> require_module_access(module_key)
    end
  end

  def require_role(conn, role_name) when is_binary(role_name) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope ->
        if Scope.has_role?(scope, role_name) do
          conn
        else
          conn
          |> put_flash(:error, "You must have the #{role_name} role to access this page.")
          |> redirect(to: "/")
          |> halt()
        end

      _ ->
        # Scope not found, try to create it from current_user
        conn
        |> fetch_phoenix_kit_current_scope([])
        |> require_role(role_name)
    end
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  # LiveView counterpart to maybe_store_return_to/1: builds a login URL
  # carrying the original request path as a ?return_to= query param.
  # The login LiveView reads it (sanitize_return_to/1), the form posts
  # it back, session.ex stashes it as :user_return_to, log_in_user/3
  # redirects there. We skip the param when the URI isn't available or
  # the user is already on the login page (guards against self-loops).
  #
  # The self-loop check trims trailing slashes on both sides so
  # `/users/log-in` and `/users/log-in/` are treated as the same path —
  # without the trim, a hand-typed trailing-slash URL would round-trip
  # back to itself via `?return_to=`.
  defp login_path_with_return_to(socket) do
    login_path = Routes.path("/users/log-in")
    login_path_canonical = String.trim_trailing(login_path, "/")

    case Phoenix.LiveView.get_connect_info(socket, :uri) do
      %URI{path: path} = uri when is_binary(path) ->
        if String.trim_trailing(path, "/") == login_path_canonical do
          login_path
        else
          query = if uri.query, do: "?" <> uri.query, else: ""
          login_path <> "?return_to=" <> URI.encode_www_form(path <> query)
        end

      _ ->
        login_path
    end
  end

  defp signed_in_path(_conn), do: "/"

  @doc """
  Validates and sets the locale for the current request.

  This function is called as a plug in the router to validate locale codes in the URL path.
  It implements PhoenixKit's simplified URL architecture:

  - URLs use base language codes (en, es, fr) for simplicity
  - Full dialect codes (en-US, es-MX) are redirected to base codes (301)
  - User preferences determine which dialect variant to use for translations
  - Translation system uses full dialect codes internally

  ## Data Flow

  1. Check if URL contains full dialect code → redirect to base
  2. Validate base code exists in predefined language list
  3. Resolve to full dialect using user preference or default mapping
  4. Set Gettext to full dialect for translations
  5. Store both base code (for URLs) and full dialect (for translations)

  ## Examples

      # Base code in URL (preferred format)
      conn = validate_and_set_locale(conn, [])
      # Sets: current_locale_base="en", current_locale="en-US"

      # Full dialect in URL (legacy/bookmarks)
      conn = validate_and_set_locale(%{path_params: %{"locale" => "en-US"}}, [])
      # Redirects 301 to: /en/...

      # Invalid locale in URL
      conn = validate_and_set_locale(%{path_params: %{"locale" => "xx"}}, [])
      # Redirects to default locale URL
  """
  def validate_and_set_locale(conn, _opts) do
    # Direct locale processing - dialect preferences are handled via LiveView events
    process_locale(conn)
  end

  # Reserved path segments that should never be treated as locale codes
  # These are valid URL path components that happen to match the locale pattern position
  @reserved_path_segments ~w(admin api webhooks assets static files images dashboard users)

  # Locale processing logic
  #
  # The locale segment normally binds as `path_params["locale"]`, but
  # `phoenix_kit_publishing`'s internal localized-content routes
  # (`integration.ex`'s `get "/:language/:group"` scope) bind the same
  # segment as `path_params["language"]` instead. Accept either so
  # Gettext gets set correctly on those routes too — otherwise this
  # falls through to the default-locale branch and headers/translations
  # silently render in the site default language regardless of the URL.
  defp process_locale(conn) do
    locale_param = conn.path_params["locale"] || conn.path_params["language"]

    case locale_param do
      locale when is_binary(locale) ->
        cond do
          # Check if this is a reserved path segment (admin, api, etc.)
          # These should be treated as regular paths, not locale codes
          locale in @reserved_path_segments ->
            process_as_default_locale(conn)

          # Check if this is a full dialect code (contains hyphen) → redirect to base
          String.contains?(locale, "-") ->
            redirect_to_base_locale(conn, locale)

          # Validate base code exists in predefined language list AND is enabled
          DialectMapper.valid_base_code?(locale) and locale_allowed?(locale) ->
            process_valid_locale(conn, locale)

          # Valid predefined but not enabled → redirect to default
          DialectMapper.valid_base_code?(locale) ->
            redirect_invalid_locale(conn, locale)

          # Invalid base code → redirect to default
          true ->
            redirect_invalid_locale(conn, locale)
        end

      _ ->
        # No locale in URL → primary language. Pure URL → default, matching
        # the LV mount path (`mount_phoenix_kit_current_scope/3`). Previously
        # this branch consulted `user.custom_fields["preferred_locale"]`
        # before the default, but the LV mount doesn't read it — a
        # logged-in user with preferred_locale=de visiting `/admin/foo`
        # would see German for the initial HTTP response and then English
        # after the LV mount snapped to default. The two paths now agree:
        # URL is the only source of truth. The preferred_locale field is
        # still written by the switcher (so the data is preserved for any
        # future feature that wants to re-enable it) but never read for
        # routing — and that includes dialect resolution: `resolve_dialect/1`
        # takes no user, so user-preferred dialect upgrades (e.g. base
        # "en" → "en-GB" via custom_fields) cannot sneak back in.
        default_base = Routes.get_default_admin_locale()
        default_dialect = DialectMapper.resolve_dialect(default_base)

        Gettext.put_locale(PhoenixKitWeb.Gettext, default_dialect)
        Gettext.put_locale(default_dialect)

        conn
        |> assign(:current_locale_base, default_base)
        |> assign(:current_locale, default_dialect)
    end
  end

  # Process request as default locale (for reserved path segments like "admin", "api")
  # When a reserved segment is captured as locale, redirect to remove the locale segment
  # Example: /:locale/dashboard captures /admin with locale="admin"
  # We redirect to /dashboard so the correct route can match
  defp process_as_default_locale(conn) do
    locale = conn.path_params["locale"] || conn.path_params["language"]

    # Remove the locale segment from the path
    # /admin (with "admin" as locale) → /
    clean_path =
      conn.request_path
      |> String.replace_prefix("/#{locale}", "")
      |> then(fn
        "" -> "/"
        path -> path
      end)

    # Set locale before redirecting. URL-driven dialect — no user (see
    # `process_valid_locale/2` for the rationale).
    default_base = Routes.get_default_admin_locale()
    default_dialect = DialectMapper.resolve_dialect(default_base)

    Gettext.put_locale(PhoenixKitWeb.Gettext, default_dialect)
    Gettext.put_locale(default_dialect)

    # Redirect to clean path so the router matches the correct route
    conn
    |> Phoenix.Controller.redirect(to: clean_path, status: 307)
    |> halt()
  end

  defp locale_allowed?(base_code) do
    language_enabled?(base_code)
  end

  # Check if a language (base code) is enabled in the system
  # Returns true if the language is in the enabled languages list or if Languages module is disabled
  defp language_enabled?(base_code) do
    case Languages.get_enabled_languages() do
      [] ->
        # No languages enabled, allow all predefined languages
        true

      enabled_languages ->
        # Check if base_code matches any enabled language
        Enum.any?(enabled_languages, fn lang ->
          lang_base = DialectMapper.extract_base(lang.code)
          lang_base == base_code
        end)
    end
  end

  # Process a validated and enabled locale.
  # For non-admin paths: redirect default locale to clean URL (no prefix needed).
  # Admin paths: do NOT redirect — both `/phoenix_kit/admin/*` and
  # `/phoenix_kit/<default>/admin/*` are valid (the dual-scope router
  # emission accepts both), and `Routes.admin_path/2` emits the
  # prefixless shape by default. We honor whichever URL shape the user
  # typed; both shapes resolve into the same `live_session
  # :phoenix_kit_admin`, so there is no boundary to canonicalize away.
  defp process_valid_locale(conn, locale) do
    if locale == Routes.get_default_admin_locale() and not admin_request?(conn) and
         prefixless_primary?() do
      redirect_default_locale_to_clean_url(conn, locale)
    else
      # URL-driven dialect — no user (see `process_as_default_locale/1`
      # for the rationale matching the LV mount path).
      full_dialect = DialectMapper.resolve_dialect(locale)

      Gettext.put_locale(PhoenixKitWeb.Gettext, full_dialect)
      Gettext.put_locale(full_dialect)

      conn
      |> assign(:current_locale_base, locale)
      |> assign(:current_locale, full_dialect)
    end
  end

  # Reads the site-wide `default_language_no_prefix` setting. When ON,
  # primary-language URLs are emitted prefixless and this plug
  # 301-redirects `/<default>/...` to the prefixless shape to keep one
  # canonical URL. When OFF (the default), the `/<default>/...` shape
  # IS the canonical URL and must NOT be redirected — a 301 would
  # discard any POST body. Defers to the canonical boot-safe wrapper
  # on `Languages` so this plug + `Routes` share one rescue policy.
  defp prefixless_primary?, do: PhoenixKit.Modules.Languages.prefixless_primary_safe?()

  # Check if the request path is an admin path. Used by
  # `process_valid_locale/2` to skip the default-locale-redirect so
  # both `/phoenix_kit/admin/*` and `/phoenix_kit/<default>/admin/*`
  # render whichever shape the user typed.
  defp admin_request?(conn) do
    String.contains?(conn.request_path, "/admin")
  end

  # Redirects default language URLs to clean URLs (no locale prefix)
  # Example: /phoenix_kit/en/dashboard → /phoenix_kit/dashboard
  # Uses 301 permanent redirect for SEO - tells browsers/search engines the clean URL is canonical
  defp redirect_default_locale_to_clean_url(conn, locale) do
    # Remove /en/ from path: /phoenix_kit/en/admin → /phoenix_kit/admin
    clean_path =
      conn.request_path
      |> String.replace("/#{locale}/", "/", global: false)
      |> then(fn path ->
        # Handle case where locale is at end of path: /phoenix_kit/en → /phoenix_kit
        if String.ends_with?(conn.request_path, "/#{locale}") do
          String.replace_suffix(path, "/#{locale}", "")
        else
          path
        end
      end)

    # Ensure we have a valid path (not empty)
    clean_path = if clean_path == "", do: "/", else: clean_path

    conn
    |> Phoenix.Controller.redirect(to: clean_path, status: 301)
    |> halt()
  end

  @doc """
  Redirects full dialect code URLs to base language URLs (301 permanent).

  This function handles backward compatibility by redirecting old URLs with
  full dialect codes (en-US, es-MX) to the new simplified base code URLs (en, es).

  Uses 301 Permanent redirect to tell browsers and search engines to update bookmarks
  and indexed URLs. This is SEO-friendly and provides clean URL migration.

  ## Examples

      iex> redirect_to_base_locale(conn, "en-US")
      # /phoenix_kit/en-US/admin → /phoenix_kit/en/admin

      iex> redirect_to_base_locale(conn, "es-MX")
      # /phoenix_kit/es-MX/users?page=2 → /phoenix_kit/es/users?page=2

  ## Preservation

  - Query parameters preserved
  - URL fragments preserved
  - Request method unchanged (GET → GET)
  - Full path structure maintained

  ## Notes

  - Status code 301 (Permanent) tells clients to update bookmarks
  - Halts conn pipeline (no further processing)
  - Logged for monitoring migration patterns
  """
  def redirect_to_base_locale(conn, full_dialect) do
    base_code = DialectMapper.extract_base(full_dialect)

    # Replace first occurrence of full dialect with base code
    # Handles: /phoenix_kit/en-US/admin → /phoenix_kit/en/admin
    corrected_path =
      String.replace(
        conn.request_path,
        "/#{full_dialect}/",
        "/#{base_code}/",
        global: false
      )

    # Handle case where dialect is at end of path
    # Handles: /phoenix_kit/en-US → /phoenix_kit/en
    corrected_path =
      if String.ends_with?(conn.request_path, "/#{full_dialect}") do
        String.replace_suffix(corrected_path, "/#{full_dialect}", "/#{base_code}")
      else
        corrected_path
      end

    # Log redirect for monitoring (helps track migration patterns)
    Logger.info("""
    [PhoenixKit Locale] Redirecting full dialect URL to base code
    - Full dialect: #{full_dialect}
    - Base code: #{base_code}
    - Original path: #{conn.request_path}
    - Corrected path: #{corrected_path}
    """)

    conn
    |> Phoenix.Controller.redirect(to: corrected_path, status: 301)
    |> halt()
  end

  @doc """
  Redirects invalid locale URLs to the canonical default-locale shape.

  Takes the current URL path and replaces the invalid locale segment so
  the redirect target matches the rest of the app's URL emission:

  - With `default_language_no_prefix?` ON → strip the segment entirely
    (the canonical primary shape is prefixless, e.g. `/phoenix_kit/admin`).
  - With the setting OFF (default) → swap the invalid segment for the
    primary base code so the canonical prefixed shape is preserved
    (e.g. `/phoenix_kit/xx/admin` → `/phoenix_kit/en/admin`).
  """
  def redirect_invalid_locale(conn, invalid_locale) do
    # Get the default language
    default_base = Routes.get_default_admin_locale()

    # Single read of the setting — the two replacement variants always
    # flip together (prefixless ↔ prefixed), so evaluating the flag
    # twice would just risk torn reads if a concurrent setting flip
    # landed between the two calls.
    {replacement_segment, replacement_suffix} =
      if prefixless_primary?(),
        do: {"/", ""},
        else: {"/#{default_base}/", "/#{default_base}"}

    corrected_path =
      conn.request_path
      |> String.replace("/#{invalid_locale}/", replacement_segment, global: false)
      |> then(fn path ->
        if String.ends_with?(conn.request_path, "/#{invalid_locale}") do
          String.replace_suffix(path, "/#{invalid_locale}", replacement_suffix)
        else
          path
        end
      end)

    # Log the invalid locale attempt for debugging
    Logger.warning("""
    [PhoenixKit Locale] Invalid locale requested, redirecting to default
    - Invalid locale: #{invalid_locale}
    - Default base: #{default_base}
    - Original path: #{conn.request_path}
    - Corrected path: #{corrected_path}
    """)

    # Redirect to the corrected URL
    conn
    |> redirect(to: corrected_path)
    |> halt()
  end

  defp extract_session_id_from_live_socket_id(live_socket_id) do
    case live_socket_id do
      "phoenix_kit_sessions:" <> encoded_token ->
        # Use first 8 chars of encoded token as session_id for admin display
        String.slice(encoded_token, 0, 8)

      _ ->
        "unknown"
    end
  end

  @doc false
  def broadcast_disconnect_for_socket(live_socket_id), do: broadcast_disconnect(live_socket_id)

  defp broadcast_disconnect(live_socket_id) do
    case get_endpoint() do
      {:ok, endpoint} ->
        try do
          endpoint.broadcast(live_socket_id, "disconnect", %{})
        rescue
          error ->
            Logger.warning("[PhoenixKit] Failed to broadcast disconnect: #{inspect(error)}")
        end

      {:error, reason} ->
        Logger.warning("[PhoenixKit] Could not find parent endpoint for broadcast: #{reason}")
    end
  end

  def get_endpoint do
    if Code.ensure_loaded?(PhoenixKitWeb.Endpoint) and
         function_exported?(PhoenixKitWeb.Endpoint, :broadcast, 3) do
      {:ok, PhoenixKitWeb.Endpoint}
    else
      {:error, "No endpoint found"}
    end
  end
end
