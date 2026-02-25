defmodule PhoenixKitWeb.Users.Auth do
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
    with at least one permission. For custom roles, also checks the specific
    permission key mapped to the current admin view. Unmapped views deny
    custom roles but allow Owner/Admin.
  - `:phoenix_kit_ensure_module_access` — For custom roles, checks that the
    feature module is both enabled and permitted. Owner/Admin bypass both
    the enabled and permission checks.

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
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.ScopeNotifier
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.SessionFingerprint

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
    shop_session_id =
      conn.cookies["shop_session_id"] || get_session(conn, :shop_session_id)

    if shop_session_id do
      try do
        Shop.merge_guest_cart(shop_session_id, user)
      rescue
        _ -> :ok
      end
    end
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn) do
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn) do
    # Preserve locale preference across session renewal
    locale_base = get_session(conn, :phoenix_kit_locale_base)

    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(fn conn ->
      if locale_base, do: put_session(conn, :phoenix_kit_locale_base, locale_base), else: conn
    end)
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)

    # Get user info before deleting token for admin notification
    user = user_token && Auth.get_user_by_session_token(user_token)

    user_token && Auth.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      broadcast_disconnect(live_socket_id)
    end

    # Notify admin panel about user logout
    if user do
      session_id = extract_session_id_from_live_socket_id(get_session(conn, :live_socket_id))
      Events.broadcast_user_session_disconnected(user.id, session_id)
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

    scope = Scope.for_user(active_user)

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
    socket = check_maintenance_mode(socket)
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
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/log-in"))

        {:halt, socket}
    end
  end

  def on_mount(:phoenix_kit_ensure_authenticated_scope, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    socket = check_maintenance_mode(socket)
    socket = attach_locale_hook(socket)
    scope = socket.assigns.phoenix_kit_current_scope

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/log-in"))

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
    socket = check_maintenance_mode(socket)

    if Scope.authenticated?(socket.assigns.phoenix_kit_current_scope) do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      socket = attach_locale_hook(socket)
      {:cont, socket}
    end
  end

  def on_mount(:phoenix_kit_ensure_owner, _params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session)
    socket = check_maintenance_mode(socket)
    scope = socket.assigns.phoenix_kit_current_scope

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/log-in"))

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
    socket = check_maintenance_mode(socket)
    scope = socket.assigns.phoenix_kit_current_scope

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/log-in"))

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
    socket = check_maintenance_mode(socket)
    scope = socket.assigns.phoenix_kit_current_scope

    # Store current module key for scope refresh checks
    socket = Phoenix.Component.assign(socket, :phoenix_kit_current_module_key, module_key)

    cond do
      not Scope.authenticated?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: Routes.path("/users/log-in"))

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
    {:halt, Phoenix.LiveView.redirect(socket, to: url)}
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

    {:cont, socket}
  end

  # Update locale assigns when navigating to a URL with a locale param
  defp maybe_update_locale_from_params(socket, %{"locale" => locale}) when is_binary(locale) do
    # Only update if locale actually changed
    current_base = socket.assigns[:current_locale_base]

    if current_base != locale and DialectMapper.valid_base_code?(locale) do
      user = socket.assigns[:phoenix_kit_current_user]
      full_dialect = DialectMapper.resolve_dialect(locale, user)

      # Update Gettext locale
      Gettext.put_locale(PhoenixKitWeb.Gettext, full_dialect)

      socket
      |> Phoenix.Component.assign(:current_locale_base, locale)
      |> Phoenix.Component.assign(:current_locale, full_dialect)
    else
      socket
    end
  end

  # No locale in params - could be:
  # 1. Default language URL (clean URL without prefix) - should use default locale
  # 2. Reserved path (admin, api, etc.) - should preserve user's session preference
  defp maybe_update_locale_from_params(socket, _params) do
    url_path = socket.assigns[:url_path] || ""

    # Check if we're on a reserved path (admin, api, etc.)
    # These paths never have locale prefix, so we should preserve user's preference
    reserved_prefixes = ~w(/admin /api /webhooks /assets /static /files /images)
    is_reserved_path = Enum.any?(reserved_prefixes, &String.contains?(url_path, &1))

    if is_reserved_path do
      # Preserve existing locale from session - don't reset to default
      # The locale was already set correctly in mount_phoenix_kit_current_scope
      socket
    else
      # Normal frontend path without locale prefix = default language URL
      default_base = Routes.get_default_admin_locale()
      current_base = socket.assigns[:current_locale_base]

      # If we're already on the default locale, no need to update
      if current_base == default_base do
        socket
      else
        # URL has no locale prefix, so we're navigating to default language
        user = socket.assigns[:phoenix_kit_current_user]
        default_dialect = DialectMapper.resolve_dialect(default_base, user)

        Gettext.put_locale(PhoenixKitWeb.Gettext, default_dialect)

        socket
        |> Phoenix.Component.assign(:current_locale_base, default_base)
        |> Phoenix.Component.assign(:current_locale, default_dialect)
      end
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

  defp mount_phoenix_kit_current_scope(socket, session, params \\ %{}) do
    socket =
      socket
      |> mount_phoenix_kit_current_user(session)
      |> maybe_attach_scope_refresh_hook()

    user = socket.assigns.phoenix_kit_current_user
    scope = Scope.for_user(user)

    # Get locale from params (URL path) first, then session, then defaults
    # This ensures locale from URL takes precedence during initial mount
    session_locale = session["phoenix_kit_locale_base"]

    current_locale_base =
      case params do
        %{"locale" => locale} when is_binary(locale) and locale != "" ->
          if DialectMapper.valid_base_code?(locale), do: locale, else: nil

        _ ->
          nil
      end ||
        session_locale ||
        Process.get(:phoenix_kit_current_locale_base) ||
        Routes.get_default_admin_locale()

    current_locale = DialectMapper.resolve_dialect(current_locale_base, user)

    # Set Gettext locale for translations
    Gettext.put_locale(PhoenixKitWeb.Gettext, current_locale)

    socket
    |> maybe_manage_scope_subscription(user)
    |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
    |> Phoenix.Component.assign(:current_locale, current_locale)
    |> Phoenix.Component.assign(:current_locale_base, current_locale_base)
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

  defp maybe_manage_scope_subscription(socket, %User{id: user_id}) when is_integer(user_id) do
    case socket.assigns[:phoenix_kit_scope_subscription_user_id] do
      ^user_id ->
        socket

      previous_id when is_integer(previous_id) ->
        ScopeNotifier.unsubscribe(previous_id)
        ScopeNotifier.subscribe(user_id)

        Phoenix.Component.assign(socket, :phoenix_kit_scope_subscription_user_id, user_id)

      _ ->
        ScopeNotifier.subscribe(user_id)
        Phoenix.Component.assign(socket, :phoenix_kit_scope_subscription_user_id, user_id)
    end
  end

  defp maybe_manage_scope_subscription(socket, _user) do
    maybe_unsubscribe_scope_updates(socket)
  end

  defp maybe_unsubscribe_scope_updates(socket) do
    if previous_id = socket.assigns[:phoenix_kit_scope_subscription_user_id] do
      ScopeNotifier.unsubscribe(previous_id)
    end

    Phoenix.Component.assign(socket, :phoenix_kit_scope_subscription_user_id, nil)
  end

  defp handle_scope_refresh({:phoenix_kit_scope_roles_updated, user_id}, socket) do
    current_scope = socket.assigns[:phoenix_kit_current_scope]

    if Scope.user_id(current_scope) == user_id do
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
  # Core views (PhoenixKitWeb.* and PhoenixKit.Modules.*) handle layout
  # via LayoutWrapper in their templates. External plugin views need it applied
  # at the session level so plugin authors don't need to wrap anything.
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
      ["PhoenixKitWeb" | _] -> false
      ["PhoenixKit" | _] -> false
      _ -> true
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
    {"tickets", "/admin/tickets"},
    {"emails", "/admin/emails"},
    {"ai", "/admin/ai"},
    {"jobs", "/admin/jobs"},
    {"sync", "/admin/sync"},
    {"db", "/admin/db"},
    {"publishing", "/admin/publishing"},
    # Settings sub-pages (lower priority landing pages)
    {"languages", "/admin/settings/languages"},
    {"seo", "/admin/settings/seo"},
    {"sitemap", "/admin/settings/sitemap"},
    {"maintenance", "/admin/settings/maintenance"},
    {"legal", "/admin/settings/legal"},
    {"referrals", "/admin/settings/referral-codes"},
    {"connections", "/admin/sync/connections"}
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

        has_perm = Scope.has_module_access?(scope, module_key)
        module_enabled = MapSet.member?(Permissions.enabled_module_keys(), module_key)

        if has_perm and (Scope.system_role?(scope) or module_enabled) do
          {:cont, socket}
        else
          deny_admin_access(socket, scope)
        end
    end
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
    PhoenixKitWeb.Live.Modules.Posts.Posts => "posts",
    PhoenixKitWeb.Live.Modules.Posts.Edit => "posts",
    PhoenixKitWeb.Live.Modules.Posts.Groups => "posts",
    PhoenixKitWeb.Live.Modules.Posts.GroupEdit => "posts",
    PhoenixKitWeb.Live.Modules.Posts.Details => "posts",
    PhoenixKitWeb.Live.Modules.Posts.Settings => "posts",
    PhoenixKitWeb.Live.Modules.Languages => "languages",
    PhoenixKitWeb.Live.Modules.Legal.Settings => "legal",
    PhoenixKitWeb.Live.Modules.Maintenance.Settings => "maintenance",
    PhoenixKitWeb.Live.Modules.Storage.Settings => "media",
    PhoenixKitWeb.Live.Modules.Storage.BucketForm => "media",
    PhoenixKitWeb.Live.Modules.Storage.Dimensions => "media",
    PhoenixKitWeb.Live.Modules.Storage.DimensionForm => "media",
    PhoenixKitWeb.Live.Modules.Jobs.Index => "jobs"
  }

  defp permission_key_for_admin_view(view_module) do
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

  # Infer permission key from PhoenixKit.Modules.<Name>.Web.* namespace
  defp infer_permission_key_from_module(view_module) do
    case Module.split(view_module) do
      ["PhoenixKit", "Modules", module_name | _rest] ->
        Macro.underscore(module_name)

      _ ->
        nil
    end
  end

  defp check_maintenance_mode(socket) do
    # Check if maintenance mode is enabled
    if Maintenance.enabled?() do
      scope = socket.assigns[:phoenix_kit_current_scope]

      # Check if this is an authentication route that should bypass maintenance
      is_auth_route = auth_route?(socket)

      cond do
        # Authentication routes (login, reset-password, etc.) always bypass maintenance
        is_auth_route ->
          Phoenix.Component.assign(socket, :show_maintenance, false)

        # Admins and owners can bypass maintenance mode
        scope && (Scope.admin?(scope) || Scope.owner?(scope)) ->
          Phoenix.Component.assign(socket, :show_maintenance, false)

        # All other users see maintenance page
        true ->
          Phoenix.Component.assign(socket, :show_maintenance, true)
      end
    else
      # Maintenance mode disabled - show normal content
      Phoenix.Component.assign(socket, :show_maintenance, false)
    end
  end

  # Check if the current socket is for an authentication route
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
      %User{id: user_id} ->
        case Auth.get_user(user_id) do
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
  defp process_locale(conn) do
    case conn.path_params do
      %{"locale" => locale} when is_binary(locale) ->
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
        # No locale in URL - check user's preferred locale first, then fall back to default
        # This supports admin paths where locale can't be in URL but user has a preference
        current_user = get_user_for_locale_resolution(conn)

        {base, dialect} =
          case get_user_preferred_locale(current_user) do
            {preferred_base, preferred_dialect} when is_binary(preferred_base) ->
              # User has a valid preferred locale - use it
              {preferred_base, preferred_dialect}

            _ ->
              # No user preference - use default admin language
              default_base = get_default_admin_language()
              default_dialect = DialectMapper.resolve_dialect(default_base, current_user)
              {default_base, default_dialect}
          end

        Gettext.put_locale(PhoenixKitWeb.Gettext, dialect)

        conn
        |> assign(:current_locale_base, base)
        |> assign(:current_locale, dialect)
        |> put_session(:phoenix_kit_locale_base, base)
    end
  end

  # Process request as default locale (for reserved path segments like "admin", "api")
  # When a reserved segment is captured as locale, redirect to remove the locale segment
  # Example: /:locale/dashboard captures /admin with locale="admin"
  # We redirect to /dashboard so the correct route can match
  defp process_as_default_locale(conn) do
    locale = conn.path_params["locale"]

    # Remove the locale segment from the path
    # /admin (with "admin" as locale) → /
    clean_path =
      conn.request_path
      |> String.replace_prefix("/#{locale}", "")
      |> then(fn
        "" -> "/"
        path -> path
      end)

    # Set locale before redirecting
    default_base = get_default_admin_language()
    current_user = get_user_for_locale_resolution(conn)
    default_dialect = DialectMapper.resolve_dialect(default_base, current_user)

    Gettext.put_locale(PhoenixKitWeb.Gettext, default_dialect)

    # Redirect to clean path so the router matches the correct route
    conn
    |> Phoenix.Controller.redirect(to: clean_path, status: 307)
    |> halt()
  end

  # Helper to get user for locale resolution
  # Checks conn assigns first, then tries to fetch from session token if available
  defp get_user_for_locale_resolution(conn) do
    case conn.assigns[:phoenix_kit_current_user] do
      nil ->
        # User not assigned yet, try to fetch from session token
        case get_session(conn, "user_token") do
          nil -> nil
          token -> Auth.get_user_by_session_token(token)
        end

      user ->
        user
    end
  end

  # Get user's preferred locale if set and valid
  # Returns {base_code, full_dialect} tuple or nil if not set/invalid
  defp get_user_preferred_locale(nil), do: nil

  defp get_user_preferred_locale(%{custom_fields: %{"preferred_locale" => preferred}})
       when is_binary(preferred) and preferred != "" do
    base = DialectMapper.extract_base(preferred)

    # Verify the preferred locale is a valid admin language
    # (admin languages are separate from frontend languages)
    if DialectMapper.valid_base_code?(base) and admin_language_enabled?(base) do
      {base, preferred}
    else
      nil
    end
  end

  defp get_user_preferred_locale(_user), do: nil

  defp locale_allowed?(base_code) do
    language_enabled?(base_code) or admin_language_enabled?(base_code)
  end

  # Check if a language (base code) is enabled as an admin language
  defp admin_language_enabled?(base_code) do
    admin_languages = get_admin_language_codes()

    if Enum.empty?(admin_languages) do
      # No admin languages configured, allow if it's a valid predefined language
      true
    else
      Enum.any?(admin_languages, fn code ->
        DialectMapper.extract_base(code) == base_code
      end)
    end
  end

  # Get the list of admin language codes from settings
  defp get_admin_language_codes do
    case PhoenixKit.Settings.get_setting_cached("admin_languages") do
      nil ->
        []

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, codes} when is_list(codes) -> codes
          _ -> []
        end
    end
  end

  # Get the default admin language base code (first in admin_languages list, or "en")
  # Extracts base code from full dialect (e.g., "en-US" -> "en")
  defp get_default_admin_language do
    case PhoenixKit.Settings.get_setting_cached("admin_languages") do
      nil ->
        # No setting exists, default is "en"
        "en"

      json when is_binary(json) ->
        case Jason.decode(json) do
          # Extract base code from full dialect (e.g., "en-US" -> "en")
          {:ok, [first | _]} -> DialectMapper.extract_base(first)
          _ -> "en"
        end
    end
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
  # Admin paths ALWAYS keep the locale in the URL to stay within the
  # :phoenix_kit_admin_locale live_session and avoid full-page reloads.
  defp process_valid_locale(conn, locale) do
    if locale == get_default_admin_language() and not admin_request?(conn) do
      redirect_default_locale_to_clean_url(conn, locale)
    else
      current_user = get_user_for_locale_resolution(conn)
      full_dialect = DialectMapper.resolve_dialect(locale, current_user)

      Gettext.put_locale(PhoenixKitWeb.Gettext, full_dialect)

      conn
      |> assign(:current_locale_base, locale)
      |> assign(:current_locale, full_dialect)
      |> put_session(:phoenix_kit_locale_base, locale)
    end
  end

  # Check if the request path is an admin path.
  # Admin paths must keep the locale in the URL to stay within the
  # :phoenix_kit_admin_locale live_session boundary.
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
  Redirects invalid locale URLs to the default locale.

  Takes the current URL path and replaces the invalid locale with the default
  locale base code, then redirects the user to the corrected URL.

  For the default language (first admin language), the locale segment is removed
  entirely to produce clean URLs (e.g., /phoenix_kit/admin).
  """
  def redirect_invalid_locale(conn, invalid_locale) do
    # Get the default admin language (first in admin_languages list, or "en")
    default_base = get_default_admin_language()

    # For default language, remove locale segment entirely for clean URLs
    # For other languages, replace with that language code
    corrected_path =
      conn.request_path
      |> String.replace("/#{invalid_locale}/", "/", global: false)
      |> then(fn path ->
        if String.ends_with?(conn.request_path, "/#{invalid_locale}") do
          String.replace_suffix(path, "/#{invalid_locale}", "")
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
