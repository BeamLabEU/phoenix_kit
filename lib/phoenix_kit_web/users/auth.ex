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
  - Integration with Phoenix LiveView on_mount callbacks

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
  alias PhoenixKit.Module.Languages
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{Scope, User}
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

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
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
  """
  def fetch_phoenix_kit_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)

    # Verify session fingerprint if token exists
    fingerprint_valid? =
      if user_token do
        case Auth.verify_session_fingerprint(conn, user_token) do
          :ok ->
            true

          {:warning, reason} ->
            # Log warning but allow access (IP/UA can legitimately change)
            require Logger
            Logger.warning("PhoenixKit: Session fingerprint warning: #{reason} for token")

            # In non-strict mode, allow access despite warning
            not SessionFingerprint.strict_mode?()

          {:error, :fingerprint_mismatch} ->
            # Both IP and UA changed - likely hijacking
            require Logger

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
            require Logger
            Logger.warning("PhoenixKit: Session fingerprint warning: #{reason} for token (scope)")

            # In non-strict mode, allow access despite warning
            not SessionFingerprint.strict_mode?()

          {:error, :fingerprint_mismatch} ->
            # Both IP and UA changed - likely hijacking
            require Logger

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

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
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

  def on_mount(:phoenix_kit_mount_current_scope, _params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session)
    socket = check_maintenance_mode(socket)
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

  def on_mount(:phoenix_kit_ensure_authenticated_scope, _params, session, socket) do
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
        {:cont, socket}
    end
  end

  def on_mount(:phoenix_kit_ensure_admin, _params, session, socket) do
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

      Scope.admin?(scope) ->
        {:cont, socket}

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

  defp set_routing_info(_params, url, socket) do
    %{path: path} = URI.parse(url)

    socket = Phoenix.Component.assign(socket, :url_path, path)

    {:cont, socket}
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

  defp mount_phoenix_kit_current_scope(socket, session) do
    socket =
      socket
      |> mount_phoenix_kit_current_user(session)
      |> maybe_attach_scope_refresh_hook()

    user = socket.assigns.phoenix_kit_current_user
    scope = Scope.for_user(user)

    socket
    |> maybe_manage_scope_subscription(user)
    |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
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
        if was_admin and not Scope.admin?(new_scope) do
          socket
          |> LiveView.put_flash(:error, "You must be an admin to access this page.")
          |> LiveView.push_navigate(to: "/")
        else
          socket
        end

      {:halt, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_scope_refresh(_msg, socket), do: {:cont, socket}

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
  Used for routes that require the user to have a specific role.
  """
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
  Validates and sets the locale from the URL path parameter.

  Extracts the locale from the `:locale` path parameter, validates it against
  enabled language codes from the database, and either sets the locale or
  redirects to the default locale URL if invalid.

  ## Examples

      # Valid locale in URL
      conn = validate_and_set_locale(conn, [])  # Sets Gettext locale

      # Invalid locale in URL
      conn = validate_and_set_locale(conn, [])  # Redirects to default locale URL
  """
  def validate_and_set_locale(conn, _opts) do
    case conn.path_params do
      %{"locale" => locale} when is_binary(locale) ->
        # Accept any valid predefined language code
        # get_predefined_language() checks the static list of 80+ languages
        # regardless of whether the Language Module is enabled
        if Languages.get_predefined_language(locale) do
          # Valid language - set it and continue
          Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
          assign(conn, :current_locale, locale)
        else
          # Invalid locale - redirect to default locale URL
          redirect_invalid_locale(conn, locale)
        end

      _ ->
        # No locale in URL - set default locale
        Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
        assign(conn, :current_locale, "en")
    end
  end

  @doc """
  Redirects invalid locale URLs to the default locale.

  Takes the current URL path and replaces the invalid locale with the default
  locale ("en"), then redirects the user to the corrected URL.
  """
  def redirect_invalid_locale(conn, invalid_locale) do
    # Get the default locale (first enabled locale or "en")
    default_locale = Languages.enabled_locale_codes() |> List.first() || "en"

    # If default is "en", remove locale prefix entirely; otherwise replace
    corrected_path =
      if default_locale == "en" do
        # Remove the locale prefix completely for English
        String.replace(conn.request_path, "/#{invalid_locale}/", "/", global: false)
      else
        # Replace with non-English default locale
        String.replace(conn.request_path, "/#{invalid_locale}/", "/#{default_locale}/",
          global: false
        )
      end

    # If the invalid locale was at the end of the path, handle that case too
    corrected_path =
      if String.ends_with?(conn.request_path, "/#{invalid_locale}") do
        if default_locale == "en" do
          String.replace_suffix(corrected_path, "/#{invalid_locale}", "")
        else
          String.replace_suffix(corrected_path, "/#{invalid_locale}", "/#{default_locale}")
        end
      else
        corrected_path
      end

    # Log the invalid locale attempt for debugging
    Logger.warning(
      "Invalid locale '#{invalid_locale}' requested, redirecting to '#{default_locale}'. Path: #{conn.request_path}"
    )

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
    case get_parent_endpoint() do
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

  defp get_parent_endpoint do
    # Simple endpoint detection without external dependencies
    app_name = Application.get_application(__MODULE__)
    base_module = app_name |> to_string() |> Macro.camelize()

    potential_endpoints = [
      Module.concat([base_module <> "Web", "Endpoint"]),
      Module.concat([base_module, "Endpoint"])
    ]

    Enum.reduce_while(potential_endpoints, {:error, "No endpoint found"}, fn endpoint, _acc ->
      if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :broadcast, 3) do
        {:halt, {:ok, endpoint}}
      else
        {:cont, {:error, "No endpoint found"}}
      end
    end)
  end
end
