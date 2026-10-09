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
    block everyone. Views that resolve to no permission key allow only a scope
    holding every enabled permission — role-agnostic, so a named Admin whose
    keys an Owner has partially revoked is denied too. The first mount of such a
    view logs a warning, whoever mounts it, so the missing mapping surfaces
    before a colleague hits the 403.
  - `:phoenix_kit_ensure_module_access` — Checks that the feature module is
    permitted for the scope and (for custom roles) enabled.

  Every scope-mounting hook above — `:phoenix_kit_mount_current_scope` and
  every `:phoenix_kit_ensure_*`/`{:phoenix_kit_ensure_module_access, _}` hook,
  which all go through it — also tracks the visitor's presence on a connected,
  authenticated mount, and keeps `current_page` current on every navigation.
  This is what makes any LiveView mounted through PhoenixKit's on_mount chain,
  admin or host app alike, show up in "Live sessions". The two legacy
  user-only hooks that do NOT go through the scope mount —
  `:phoenix_kit_mount_current_user` and `:phoenix_kit_ensure_authenticated` —
  are not covered; a page that needs presence tracking should use their
  scope-based equivalents instead. Details: `PhoenixKit.Admin.Presence`.

  ## Usage

  The plugs in this module are automatically configured when using
  `PhoenixKitWeb.Integration.phoenix_kit_routes/0` macro in your router.
  """
  use PhoenixKitWeb, :verified_routes
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView, only: [attach_hook: 4]

  require Logger

  alias Phoenix.LiveView
  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Dashboard.Registry, as: TabRegistry
  alias PhoenixKit.Dashboard.TabHelpers
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.LoginAlerts
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Users.ScopeNotifier
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Users.TimeZoneAlert
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.SessionFingerprint
  alias PhoenixKit.Utils.UserAgent
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate}
  alias PhoenixKitWeb.Components.Dashboard.AdminSidebar
  alias PhoenixKitWeb.Plugs.WebsiteAccess, as: AccessPlug
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
  The name of the remember-me cookie, for a plug that has to know whether one
  is present without verifying it.
  """
  def remember_me_cookie, do: @remember_me_cookie

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
  def log_in_user(conn, user, params \\ %{})

  # A deactivated account gets no session, whichever door it arrives at. The
  # password controller checked `is_active` itself, but magic-link verification,
  # QR-login completion and the OAuth callback all call this function directly
  # and did not — they minted a token for an account the operator had switched
  # off. The fetch plugs then resolved it to nil, so the practical result was a
  # confusing dead session rather than access; putting the check on the shared
  # funnel means no future entry point has to remember it.
  def log_in_user(conn, %Auth.User{is_active: false} = user, _params) do
    Logger.warning("PhoenixKit: refused sign-in for deactivated user #{user.uuid}")

    conn
    |> Phoenix.Controller.put_flash(
      :error,
      gettext("This account is not active. Contact an administrator.")
    )
    |> Phoenix.Controller.redirect(to: Routes.path("/users/log-in"))
    |> halt()
  end

  def log_in_user(conn, user, params) do
    # Create session fingerprint if enabled
    opts =
      if SessionFingerprint.fingerprinting_enabled?() do
        fingerprint = SessionFingerprint.create_fingerprint(conn)
        [fingerprint: fingerprint]
      else
        []
      end

    # Readable device name for the sessions UI, captured at login independent
    # of fingerprinting (which keeps only the hashed UA) and of the alerts
    # setting. The raw UA isn't stored — only the parsed browser/OS.
    ua = List.first(get_req_header(conn, "user-agent"))
    opts = Keyword.merge(opts, browser: UserAgent.browser(ua), os: UserAgent.os(ua))

    token = Auth.generate_user_session_token(user, opts)

    # Destination: an explicit `return_to` in params wins, then whatever a gate
    # stashed in the session, then the `after_login_path` setting. Honoring the
    # param matters because callers pass it (the OAuth callback has always
    # passed `"return_to"` here, and it was silently dropped — session renewal
    # below then wiped the session copy too, so an OAuth login started from a
    # protected page landed on the default).
    #
    # Resolved by `post_auth_path/2` rather than a local guard so this shares
    # ONE rule with the confirmation pages: local-path only AND never a
    # sign-in page. A bare `local_path?` check let `?return_to=/users/log-out`
    # through — a real GET route, so the user was signed back out the instant
    # they signed in.
    #
    # `context:`/`scope:` cover the tail of that chain: with no `return_to` and
    # no `after_login_path`, the destination is `"/"` only where the host proves
    # it routes one, and a core-owned landing everywhere else. The subject is
    # the user being logged IN — `conn.assigns` still describes whoever the
    # pipeline saw, which for a fresh login is nobody.
    # The user's own "start on this page" preference sits AFTER an explicit
    # return_to — going back to the page you were actually trying to reach
    # beats a standing preference — and BEFORE the configured default, which
    # is the thing a personal choice is meant to override.
    user_return_to =
      Routes.post_auth_path(
        [params["return_to"], get_session(conn, :user_return_to)] ++ start_page_candidates(user),
        context: conn,
        scope: Scope.for_user(user)
      )

    # Merge guest cart into user cart before session renewal clears session data.
    # The shop_session_id cookie survives renew_session (only session data is cleared).
    maybe_merge_guest_cart(conn, user)

    # New-device login alert. Every login path (password, magic link,
    # OAuth, QR) funnels through here, so this is the single integration
    # point. No-ops when new_login_alert_enabled is off; never raises.
    LoginAlerts.check(user, conn)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    # A login starts a single-account stack. `renew_session/1` cleared the
    # session copy; this clears the durable mirror, so the accounts a PREVIOUS
    # user of this browser had stacked cannot be restored under the new login.
    |> MultiSession.forget_persisted_accounts()
    |> redirect(to: user_return_to)
  end

  defp maybe_merge_guest_cart(conn, user) do
    if Code.ensure_loaded?(PhoenixKitEcommerce) do
      # Session FIRST, cookie only as a fallback.
      #
      # The shop session cookie is signed, so `conn.cookies["shop_session_id"]`
      # here is the signed envelope ("SFMyNTY...."), not the id — `:browser`
      # fetches cookies unsigned, and only `fetch_cookies(conn, signed: [...])`
      # inside the shop plug verifies it. The envelope is truthy, so reading
      # the cookie first meant `||` never fell through to the session, which
      # is the one place the real id lives. `merge_guest_cart(<envelope>, user)`
      # then matched no cart and returned quietly: every guest who filled a
      # cart and logged in silently lost it.
      #
      # The shop plug mirrors the resolved id into the session on every
      # request, so the session is both authoritative and already verified.
      # The cookie fallback stays for a host that wires the routes without
      # the shop plug.
      shop_session_id =
        get_session(conn, :shop_session_id) || conn.cookies["shop_session_id"]

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

  # The site-wide `remember_me_enabled` policy is enforced HERE rather than at
  # each caller, so it holds by construction: with it off, no flow — not a
  # forged param, not OAuth, not a future login path — can leave a persistent
  # cookie.
  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    if remember_me_enabled?() do
      put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
    else
      conn
    end
  end

  # Not a remembered login — clear any cookie this browser still holds. Logging
  # in mints a new token and (on a password change) deletes the old ones, so a
  # carried-over cookie would point at a dead token: it survives until the
  # browser drops its session cookie, then silently signs the user out and
  # keeps failing for the cookie's full 60 days.
  defp maybe_write_remember_me_cookie(conn, _token, _params) do
    delete_resp_cookie(conn, @remember_me_cookie)
  end

  @doc """
  Lifetime of a persistent session, in seconds.

  Exposed so `PhoenixKitWeb.Users.MultiSession`'s durable stack cookie expires
  with the remember-me cookie it hangs off instead of carrying a second copy of
  the number.
  """
  @spec remember_me_max_age() :: pos_integer()
  def remember_me_max_age, do: @max_age

  @doc """
  Whether the site allows persistent ("remember me") sessions at all.

  Site-wide policy via the `remember_me_enabled` setting (default `true`).
  When false the checkbox is hidden on every auth form and no flow can write
  the persistent cookie — logins last only as long as the browser session.
  """
  @spec remember_me_enabled?() :: boolean()
  def remember_me_enabled? do
    PhoenixKit.Settings.get_boolean_setting("remember_me_enabled", true)
  end

  @doc """
  Whether signing in with a magic link is available.

  Gates the request page, and the token endpoint that emailed links point at.
  Turning it off is a security-posture decision ("password and 2FA only"), so it
  has to close the route rather than only hide the button — an admin who
  switches it off on the Authorization settings page will reasonably believe
  nobody can still sign in this way.

  In-flight links stop working too. Disabling passwordless login means no more
  magic-link sign-ins, not no new ones from today; the tokens are short-lived,
  so the window this affects is small.
  """
  @spec magic_link_login_enabled?() :: boolean()
  def magic_link_login_enabled? do
    PhoenixKit.Settings.get_boolean_setting("magic_link_login_enabled", true)
  end

  @doc """
  Whether registering via a magic link is available.

  Gates the request page and the completion page, for the same reason as
  `magic_link_login_enabled?/0`: the setting has to close the route, not just
  hide the entry point.
  """
  @spec magic_link_registration_enabled?() :: boolean()
  def magic_link_registration_enabled? do
    PhoenixKit.Settings.get_boolean_setting("magic_link_registration_enabled", true)
  end

  @doc """
  Whether the "remember me" checkbox starts checked.

  Site-wide default via the `remember_me_default` setting (default `true`) —
  users can still untick it per login. Flows with no UI to tick (magic-link
  login, OAuth) follow this value directly. Always false when
  `remember_me_enabled?/0` is false.
  """
  @spec remember_me_default?() :: boolean()
  def remember_me_default? do
    remember_me_enabled?() and
      PhoenixKit.Settings.get_boolean_setting("remember_me_default", true)
  end

  @doc """
  The params a no-UI login flow (magic link, OAuth) should pass to
  `log_in_user/3` to follow the site's persistence policy.
  """
  @spec remember_me_params() :: map()
  def remember_me_params do
    if remember_me_default?(), do: %{"remember_me" => "true"}, else: %{}
  end

  @doc """
  Whether this request already carries a persistent remember-me cookie.

  Lets a re-login flow that has no checkbox of its own (the password-change
  handoff) preserve the choice the user already made, instead of silently
  downgrading them to a session-only login.
  """
  @spec remembered?(Plug.Conn.t()) :: boolean()
  def remembered?(conn), do: is_binary(remembered_token(conn))

  @doc """
  The session token this browser's remember-me cookie holds, or `nil`.

  The token itself, not just its presence, because
  `PhoenixKitWeb.Users.MultiSession` binds its durable stack to the identity
  that built it — see `restore_persisted_accounts/2`.
  """
  @spec remembered_token(Plug.Conn.t()) :: binary() | nil
  def remembered_token(conn) do
    conn = fetch_cookies(conn, signed: [@remember_me_cookie])

    case conn.cookies[@remember_me_cookie] do
      token when is_binary(token) -> token
      _ -> nil
    end
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

    # `scope: nil` is passed EXPLICITLY. `renew_session/1` has already cleared
    # the session, but `conn.assigns[:phoenix_kit_current_user]` is still
    # populated from the pipeline — inferring the subject from assigns here
    # would treat a just-logged-out visitor as signed in.
    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> MultiSession.forget_persisted_accounts()
    |> redirect(to: Routes.safe_destination(conn, scope: nil))
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
    # The drain disconnects the sockets itself, so every caller of it — role
    # changes, deactivation — gets the same treatment as this one without
    # having to remember the broadcast.
    Auth.delete_all_user_session_tokens(user)
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
    {conn, fingerprint_valid?} = check_fingerprint_once(conn, user_token)

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

  # Verify the session fingerprint at most ONCE per request, whatever the
  # pipeline shape. The shipped `:phoenix_kit_admin_only` pipeline runs BOTH
  # fetch plugs, and each used to verify independently — so every mismatch
  # was checked twice and `verify_fingerprint/4` logged its line twice. The
  # first verification's result is cached on the conn and reused.
  #
  # No logging here on any branch, deliberately: `verify_fingerprint/4` has
  # already logged what changed, for which session, at a level that matches
  # whether the request is about to be refused — extra lines here said only
  # "for token", naming neither, and doubled (or tripled) the volume of the
  # noisiest thing in the log.
  defp check_fingerprint_once(conn, nil), do: {conn, true}

  defp check_fingerprint_once(conn, user_token) do
    case conn.private[:phoenix_kit_fingerprint_valid] do
      nil ->
        result = Auth.verify_session_fingerprint(conn, user_token)
        valid? = fingerprint_allows_access?(result)
        {Plug.Conn.put_private(conn, :phoenix_kit_fingerprint_valid, valid?), valid?}

      valid? ->
        {conn, valid?}
    end
  end

  defp fingerprint_allows_access?(:ok), do: true

  defp fingerprint_allows_access?({:warning, _reason}),
    do: not SessionFingerprint.strict_mode?()

  defp fingerprint_allows_access?({:error, :fingerprint_mismatch}),
    do: not SessionFingerprint.strict_mode?()

  # Token expired or invalid
  defp fingerprint_allows_access?({:error, :token_not_found}), do: false

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

    # Shares the once-per-request verification (and its no-extra-logging
    # policy) with `fetch_phoenix_kit_current_user` — this plug used to
    # carry its own copy of the old logging, so a pipeline running both
    # plugs logged every mismatch three times, including an `:error`
    # "possible hijacking" line for requests that were then served.
    {conn, fingerprint_valid?} = check_fingerprint_once(conn, user_token)

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
        token when is_binary(token) ->
          # Honor the master switch on READ too, not just on write. Blocking new
          # cookies while still accepting old ones would let every cookie issued
          # before the switch was turned off keep restoring sessions for its
          # full 60 days — the opposite of what turning it off means.
          if remember_me_enabled?() do
            # This is the ONE place a real session is rebuilt from cookies
            # alone, so it is also where the multi-account stack has to come
            # back. Restoring only the remembered token left the switcher
            # holding a single row and silently dropped every account the user
            # had added — the session copy of the stack dies with the host's
            # session cookie, which on a stock `mix phx.new` endpoint means at
            # browser restart.
            {token,
             conn
             |> put_token_in_session(token)
             |> MultiSession.restore_persisted_accounts(token)}
          else
            {nil,
             conn
             |> delete_resp_cookie(@remember_me_cookie)
             |> MultiSession.forget_persisted_accounts()}
          end

        # No remembered identity — a stack has nothing to hang off, so drop any
        # mirror this browser is still carrying.
        _ ->
          {nil, MultiSession.forget_persisted_accounts(conn)}
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

    * `{:phoenix_kit_require, requirement}` - **Checks only; mounts nothing.**
      `requirement` is `:authenticated`, `:owner`, `:admin` or
      `{:module, key}`, with exactly the rules of the matching `ensure_*`
      hook. It reads the scope an earlier `:phoenix_kit_mount_current_scope`
      put on the socket, and raises if there is none — that is a wiring
      mistake, not an anonymous visitor.

  ## Two verbs: mount, then require

  Every hook does one or both of two things: **mount** the scope (the
  current user, locale, and the hooks that keep them fresh) and **require**
  something of it. The `ensure_*` hooks do both, which is convenient for a
  `live_session` whose pages all have the same requirement. When pages with
  different requirements share one `live_session` — public and signed-in
  pages together, so navigating between them stays on the socket — mount once
  for the session and require per page:

      live_session :app,
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
        live "/", HomeLive              # public
        live "/account", AccountLive    # signed in, see below
      end

      defmodule MyAppWeb.AccountLive do
        use MyAppWeb, :live_view
        on_mount {PhoenixKitWeb.Users.Auth, {:phoenix_kit_require, :authenticated}}
      end

  | Where | Hook |
  |---|---|
  | a `live_session` whose pages differ | `:phoenix_kit_mount_current_scope` |
  | a page in it with a requirement | `{:phoenix_kit_require, requirement}` |
  | a `live_session` whose pages all share one requirement | the matching `:phoenix_kit_ensure_*` |

  Stacking is safe in any order — every hook the mount attaches is attached
  once — but mounting twice does the work twice, so prefer the pairing above.
  The website access gate runs before every hook, including the check-only
  one.

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
  def on_mount(hook, params, session, socket) do
    # The password gate comes before every hook: a session that has not
    # passed it may not mount a LiveView, whatever the LiveView is. The HTTP
    # request already met the gate in the browser pipeline; this catches a
    # live navigation after a relock and the connected mount of a session
    # that was unlocked under an old epoch.
    case website_access_gate(session, socket) do
      {:halt, socket} -> {:halt, socket}
      {:cont, socket} -> mount_hook(hook, params, session, socket)
    end
  end

  defp mount_hook(:phoenix_kit_mount_current_user, _params, session, socket) do
    {:cont, mount_phoenix_kit_current_user(socket, session)}
  end

  defp mount_hook(:phoenix_kit_mount_current_scope, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    socket = attach_locale_hook(socket)
    {:cont, socket}
  end

  defp mount_hook(:phoenix_kit_ensure_authenticated, _params, session, socket) do
    socket = mount_phoenix_kit_current_user(socket, session)
    user = socket.assigns.phoenix_kit_current_user

    if is_nil(user) do
      {:halt, redirect_to_login(socket)}
    else
      live_account_gate(socket, user)
    end
  end

  defp mount_hook(:phoenix_kit_ensure_authenticated_scope, params, session, socket) do
    socket =
      socket
      |> mount_phoenix_kit_current_scope(session, params)
      |> attach_locale_hook()

    require_scope(:authenticated, socket, socket.assigns.phoenix_kit_current_scope)
  end

  defp mount_hook(:phoenix_kit_redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_phoenix_kit_current_user(socket, session)

    if socket.assigns.phoenix_kit_current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  defp mount_hook(:phoenix_kit_redirect_if_authenticated_scope, _params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session)

    if Scope.authenticated?(socket.assigns.phoenix_kit_current_scope) do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      socket = attach_locale_hook(socket)
      {:cont, socket}
    end
  end

  defp mount_hook(:phoenix_kit_ensure_owner, _params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session)
    require_scope(:owner, socket, socket.assigns.phoenix_kit_current_scope)
  end

  defp mount_hook(:phoenix_kit_ensure_admin, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    require_scope(:admin, socket, socket.assigns.phoenix_kit_current_scope)
  end

  defp mount_hook({:phoenix_kit_ensure_module_access, module_key}, params, session, socket) do
    socket = mount_phoenix_kit_current_scope(socket, session, params)
    require_scope({:module, module_key}, socket, socket.assigns.phoenix_kit_current_scope)
  end

  # The check-only verb: it reads the scope a session-level
  # `:phoenix_kit_mount_current_scope` already put on the socket and mounts
  # nothing itself. That is what a host with public and signed-in pages in ONE
  # live_session needs (one live_session keeps navigation between them on the
  # socket): mount once for the session, require per LiveView.
  defp mount_hook({:phoenix_kit_require, requirement}, _params, _session, socket) do
    require_scope(requirement, socket, mounted_scope!(socket, requirement))
  end

  defp mount_hook(hook, _params, _session, _socket) do
    raise ArgumentError,
          "unknown PhoenixKitWeb.Users.Auth on_mount hook #{inspect(hook)}. " <>
            "See the on_mount/4 docs for the supported hooks."
  end

  # A `{:phoenix_kit_require, _}` with no scope on the socket is a wiring
  # mistake, not an anonymous visitor: treating the missing assign as "not
  # signed in" would bounce a signed-in user to the login page with no hint
  # why. A scope that IS present with no user is the anonymous case, and is
  # redirected as usual.
  defp mounted_scope!(socket, requirement) do
    case Map.fetch(socket.assigns, :phoenix_kit_current_scope) do
      {:ok, scope} ->
        scope

      :error ->
        raise ArgumentError, """
        on_mount {PhoenixKitWeb.Users.Auth, {:phoenix_kit_require, #{inspect(requirement)}}} \
        found no scope on the socket. It only checks — mount the scope first, e.g.

            live_session :app,
              on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
              live "/account", AccountLive  # with on_mount {PhoenixKitWeb.Users.Auth, {:phoenix_kit_require, :authenticated}}
            end

        or use a hook that does both, such as :phoenix_kit_ensure_authenticated_scope.
        """
    end
  end

  # What each requirement demands of an already-mounted scope. The legacy
  # `:phoenix_kit_ensure_*` hooks mount and then call these, so the two
  # entry points cannot drift apart.
  defp require_scope(:authenticated, socket, scope) do
    with {:cont, socket} <- require_authenticated_live(socket, scope) do
      live_account_gate(socket, scope)
    end
  end

  defp require_scope(:owner, socket, scope) do
    with {:cont, socket} <- require_authenticated_live(socket, scope),
         {:cont, socket} <- live_account_gate(socket, scope) do
      if Scope.owner?(scope) do
        {:cont, attach_locale_hook(socket)}
      else
        socket =
          socket
          # No `skip_admin`: the rejected visitor may well be an Admin, who
          # legitimately belongs in `/admin` — that area is gated by
          # `:phoenix_kit_ensure_admin`, not by this hook, so there is no loop.
          |> Phoenix.LiveView.put_flash(
            :error,
            gettext("You must be an owner to access this page.")
          )
          |> Phoenix.LiveView.redirect(to: Routes.safe_destination(socket, scope: scope))

        {:halt, socket}
      end
    end
  end

  defp require_scope(:admin, socket, scope) do
    with {:cont, socket} <- require_authenticated_live(socket, scope),
         {:cont, socket} <- live_account_gate(socket, scope) do
      case admin_gate_decision(scope, socket.view) do
        :landing ->
          {:cont, prepare_admin_mount(socket, Scope.can_access_admin_area?(scope))}

        :enforce_view ->
          socket
          |> prepare_admin_mount(true)
          |> enforce_admin_view_permission(scope)

        :deny ->
          {:halt, deny_admin_area(socket, scope)}
      end
    end
  end

  defp require_scope({:module, module_key}, socket, scope) do
    # Store current module key for scope refresh checks
    socket = Phoenix.Component.assign(socket, :phoenix_kit_current_module_key, module_key)

    with {:cont, socket} <- require_authenticated_live(socket, scope),
         {:cont, socket} <- live_account_gate(socket, scope) do
      cond do
        not Scope.can_access_admin_area?(scope) ->
          socket =
            socket
            |> Phoenix.LiveView.put_flash(
              :error,
              gettext("You do not have the required permission to access this page.")
            )
            |> Phoenix.LiveView.redirect(
              to: Routes.safe_destination(socket, scope: scope, skip_admin: true)
            )

          {:halt, socket}

        # A disabled module's admin surface is blocked for EVERYONE, Owner
        # included — matching `enforce_admin_view_permission/2`. (Previously Owner
        # bypassed enablement here but not on fresh LV mounts, so the same user
        # saw a disabled module's page through one hook and a redirect through
        # another. Enablement is now uniform across all three gates.)
        Scope.has_module_access?(scope, module_key) and
            MapSet.member?(Permissions.enabled_module_keys(), module_key) ->
          socket = attach_locale_hook(socket)
          {:cont, socket}

        true ->
          redirect_to = best_available_admin_path(socket, scope)

          socket =
            socket
            |> Phoenix.LiveView.put_flash(
              :error,
              gettext("You do not have permission to access this section.")
            )
            |> Phoenix.LiveView.redirect(to: redirect_to)

          {:halt, socket}
      end
    end
  end

  defp require_scope(requirement, _socket, _scope) do
    raise ArgumentError,
          "unknown requirement #{inspect(requirement)} for {:phoenix_kit_require, _}; " <>
            "expected :authenticated, :owner, :admin or {:module, key}"
  end

  # The `/admin` index. Named ONCE, here, because three things have to agree
  # about it and they are in three different files: the route declaration
  # (`PhoenixKitWeb.Integration.phoenix_kit_admin_routes/1`), the gate
  # exception in `:phoenix_kit_ensure_admin`, and the terminal of
  # `PhoenixKit.Utils.Routes.safe_destination/2`.
  @landing_view PhoenixKitWeb.Live.Dashboard

  @doc """
  Whether `view` is the guaranteed landing — the one admin LiveView that
  `:phoenix_kit_ensure_admin` opens to EVERY authenticated visitor, whatever
  permissions they hold.

  That view is `PhoenixKitWeb.Live.Dashboard`, the `/admin` index. It is the
  terminal of `PhoenixKit.Utils.Routes.safe_destination/2`: the page core
  promises any signed-in visitor can be redirected to. A terminal that rejects
  its own visitor is an infinite redirect rather than a fallback, so the gate
  has to admit them — and the page is built for it, gating every operator block
  behind `can_access_admin_view?/2` and showing a permission-less visitor the
  welcome block and nothing else.

  Admission is NOT unconditional: authentication, the account gate (email
  confirmation, maintenance mode, blocked accounts) and the locale hook all run
  first, exactly as for any other admin view. Only the admin-area gate and the
  per-view permission check are skipped.

      iex> PhoenixKitWeb.Users.Auth.landing_view?(PhoenixKitWeb.Live.Dashboard)
      true

      iex> PhoenixKitWeb.Users.Auth.landing_view?(PhoenixKitWeb.Live.Users.Users)
      false
  """
  @spec landing_view?(module() | nil) :: boolean()
  def landing_view?(view), do: view == @landing_view

  # Which arm of `:phoenix_kit_ensure_admin` a visitor takes once authentication
  # and the account gate have passed. Pure — no socket, no flash, no redirect —
  # so the branch ORDER, which is the load-bearing part, is unit-testable
  # without a database. The hook maps each atom to its side effects and nothing
  # else.
  #
  #   * `:landing` — the `/admin` index, for ANY authenticated visitor. It is
  #     the terminal of `PhoenixKit.Utils.Routes.safe_destination/2`, the page
  #     core promises a signed-in visitor can be redirected to, and a terminal
  #     that bounces its own visitor is an infinite redirect rather than a
  #     fallback.
  #   * `:enforce_view` — every other admin view, for a scope that clears the
  #     admin-area gate: `enforce_admin_view_permission/2` then applies the
  #     per-view permission exactly as before.
  #   * `:deny` — no admin rights, and not the landing.
  #
  # The order is not interchangeable. `Scope.can_access_admin_area?/1` is true
  # for any holder of a single permission, but the landing view maps to the
  # `"dashboard"` key — so checking the admin area first would send a client
  # holding only `client_portal` into `:enforce_view`, which would refuse them
  # the very page the resolver had just guaranteed. Landing is asked first, and
  # is the only view for which either permission check is skipped.
  #
  # The landing branch is a PERMISSION exemption, never an authentication one,
  # and it says so itself rather than resting on call-site ordering. Today
  # `require_authenticated_live/2` runs first in the `with`, so an unauthenticated
  # scope can never reach here — but a future caller that forgets, or a host
  # calling this predicate to decide whether to render a link, would otherwise
  # be told the landing is open to nobody-in-particular. `scope_refresh_decision/4`
  # defends its own landing branch the same way, for the same reason.
  #
  # This is a GATE exception, deliberately not a route one: the `/admin` route
  # stays in `live_session :phoenix_kit_admin` with every other `/admin/*` page.
  # Moving it to another live_session would admit the same visitors and cost a
  # full page reload on every navigation into and out of the admin area
  # (LiveView cannot live-navigate across live_sessions — see
  # `lib/phoenix_kit/dashboard/ADMIN_README.md`), while subjecting the
  # guaranteed landing to that session's own hooks, which are free to halt and
  # redirect. A gate exception cannot drift that way.
  #
  # Exposed as `@doc false def` (rather than `defp`) so unit tests can exercise
  # the branches with literal scopes, without LiveView mounting machinery. Not
  # part of the public API.
  @doc false
  @spec admin_gate_decision(Scope.t() | nil, module() | nil) :: :landing | :enforce_view | :deny
  def admin_gate_decision(scope, view) do
    cond do
      landing_view?(view) and Scope.authenticated?(scope) -> :landing
      Scope.can_access_admin_area?(scope) -> :enforce_view
      true -> :deny
    end
  end

  # Everything an admitted admin mount gets once the gates have passed.
  #
  # `admin_area?` is `Scope.can_access_admin_area?/1`, and it is false for
  # exactly one caller: a permission-less visitor on the landing view. It gates
  # the modules subscription and nothing else — `Events.subscribe_to_modules/0`
  # exists so the admin SIDEBAR re-renders when an Owner toggles a module, and
  # a visitor who is shown no admin navigation has nothing to re-render.
  # Subscribing them would put every signed-in user of the application on that
  # topic for the lifetime of the socket.
  #
  # `maybe_apply_plugin_layout/1` is a no-op for the landing view (it only
  # rewrites the layout for views outside the `PhoenixKitWeb.*` and
  # core-`PhoenixKit.Modules.*` namespaces), so both clauses can run it and the
  # difference between them stays exactly the one line it should be.
  defp prepare_admin_mount(socket, true) do
    socket
    |> attach_locale_hook()
    |> maybe_subscribe_to_module_events()
    |> maybe_apply_plugin_layout()
  end

  defp prepare_admin_mount(socket, false) do
    socket
    |> attach_locale_hook()
    |> maybe_apply_plugin_layout()
  end

  # The admin-area rejection: authenticated, past the account gate, but holding
  # no permission at all — and not on the landing view, which is checked first.
  defp deny_admin_area(socket, scope) do
    socket
    |> Phoenix.LiveView.put_flash(
      :error,
      gettext("You do not have the required permission to access this page.")
    )
    # `skip_admin: true` states the invariant at the call site: this is the
    # admin-area rejection, so the destination must never be an admin page the
    # visitor was just refused. It suppresses the `/admin` CANDIDATE, not the
    # terminal — the terminal is the landing this hook admits everyone to, so
    # arriving there is a render, not a second bounce.
    |> Phoenix.LiveView.redirect(
      to: Routes.safe_destination(socket, scope: scope, skip_admin: true)
    )
  end

  # Shared first step for every `ensure_*` scope hook: `{:cont, socket}` for an
  # authenticated visitor, otherwise a halt to the login page carrying the
  # originally requested path.
  defp require_authenticated_live(socket, scope) do
    if Scope.authenticated?(scope) do
      {:cont, socket}
    else
      {:halt, redirect_to_login(socket)}
    end
  end

  defp redirect_to_login(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, gettext("You must log in to access this page."))
    |> Phoenix.LiveView.redirect(to: login_path_with_return_to(socket))
  end

  # LiveView side of `account_gate/1`. The account is authenticated; this is
  # everything it must additionally satisfy before it may use the application.
  defp live_account_gate(socket, subject) do
    case account_gate(subject) do
      :ok ->
        {:cont, socket}

      {:halt, kind, message, target} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(kind, message)
          |> Phoenix.LiveView.redirect(to: path_with_return_to(socket, target))

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
    # Read before the assign below overwrites it — used only to skip a
    # same-path presence update (a query-string-only patch, e.g. sorting or
    # searching on the same admin page) further down this pipe.
    previous_path = socket.assigns[:url_path]

    socket =
      socket
      |> Phoenix.Component.assign(:url_path, path)
      |> maybe_update_locale_from_params(params)
      # This hook fires on `handle_params` for every LiveView mounted through
      # PhoenixKit's on_mount chain (admin and host-app public pages alike),
      # so it is the one place that can publish `:crawlers_no_index` to a host
      # app's own public LiveViews — LayoutWrapper.app_layout_inner/1 only
      # wraps admin/plugin views. assign_new is a no-op if LayoutWrapper
      # already set it, so this is safe either way.
      #
      # The head metas no longer read it: `Core.CrawlerMetas` reads the
      # settings itself so it works in a HOST root layout too. This assign
      # stays as the published read-only signal for host templates that want
      # to branch on the directive. Deliberately just the one — a second
      # assign for the verification metas would be two more settings reads on
      # every navigation with nothing to read them.
      |> Phoenix.Component.assign_new(:crawlers_no_index, fn -> Crawlers.no_index_enabled?() end)
      |> maybe_update_presence_current_page(path, previous_path)

    {:cont, socket}
  end

  # Reports every navigation (not just the initial mount) to Presence, so
  # "Live sessions" shows where an authenticated visitor actually is right
  # now rather than the page they first connected on.
  defp maybe_update_presence_current_page(
         %{assigns: %{phoenix_kit_presence_tracked?: true} = assigns} = socket,
         path,
         previous_path
       ) do
    scope = assigns[:phoenix_kit_current_scope]

    # `handle_params` fires on a query-string-only patch too (sorting,
    # searching, paginating on the same page) — skip the GenServer call and
    # the `presence_stats` broadcast it triggers when the path itself did not
    # change, rather than repeating a no-op update on every such patch.
    if path != previous_path && scope && Scope.authenticated?(scope) do
      Presence.update_current_page(
        Scope.user_uuid(scope),
        assigns[:phoenix_kit_presence_session_id],
        path
      )
    end

    socket
  end

  defp maybe_update_presence_current_page(socket, _path, _previous_path), do: socket

  # Sets the process Gettext locale (backend-specific + global for
  # feature-module backends) from a resolved dialect, downgrading to the
  # BASE code when the backend ships no catalog for the full dialect.
  # The po directories across the ecosystem are bare base codes ("fr"),
  # while the locale pipeline resolves URLs to full dialects ("fr-FR") —
  # putting the dialect straight into Gettext silently rendered the
  # whole interface in English msgids for every dialect-mapped language.
  # `current_locale` assigns keep the full dialect; only Gettext gets
  # the downgraded code.
  # Resolves a base code to the dialect the HOST actually enabled,
  # falling back to the hardcoded default-dialect table. Without this,
  # a host that enables only "en-CA" still resolved /en/ to "en-US" —
  # an assign no stored translation or Gettext catalog matched.
  @doc false
  def resolve_active_dialect(base) when is_binary(base) do
    hard = DialectMapper.resolve_dialect(base)

    enabled_codes =
      if Languages.enabled?() do
        Enum.map(Languages.get_enabled_languages(), & &1.code)
      else
        []
      end

    cond do
      enabled_codes == [] ->
        hard

      hard in enabled_codes ->
        hard

      code = Enum.find(Enum.sort(enabled_codes), &(DialectMapper.extract_base(&1) == base)) ->
        code

      true ->
        hard
    end
  end

  @doc false
  def put_gettext_locale(dialect) when is_binary(dialect), do: put_gettext_locale(dialect, nil)

  @doc false
  # `view` is the LiveView module the hook runs for (nil from a plug). With
  # `config :phoenix_kit, host_live_view_locale: :leave`, a HOST LiveView —
  # one outside the kit's and its modules' namespaces — gets only the kit's
  # own backend set: the process-global Gettext locale, which the host's
  # backend reads, is left to the host. The default, `:set`, sets both for
  # every view, as always.
  def put_gettext_locale(dialect, view) when is_binary(dialect) do
    # The same choice as everything rendered for a recipient (emails,
    # notifications), so the web and the mail cannot disagree on a language.
    locale = RecipientLocale.gettext_locale(dialect)

    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)

    unless leave_host_locale?(view), do: Gettext.put_locale(locale)

    # The undowngraded dialect, for per-language content (see
    # `Languages.put_request_locale/1`).
    Languages.put_request_locale(dialect)
    locale
  end

  @doc false
  def leave_host_locale?(nil), do: false

  def leave_host_locale?(view) when is_atom(view) do
    Application.get_env(:phoenix_kit, :host_live_view_locale, :set) == :leave and
      not kit_view?(view)
  end

  # The kit's own LiveViews and its modules' (PhoenixKitWeb.*, PhoenixKit*.*)
  # read the global locale through their backends and always get it.
  defp kit_view?(view), do: view |> Atom.to_string() |> String.starts_with?("Elixir.PhoenixKit")

  # Update locale assigns when navigating to a URL with a locale param
  defp maybe_update_locale_from_params(socket, %{"locale" => locale}) when is_binary(locale) do
    # Only update if locale actually changed
    current_base = socket.assigns[:current_locale_base]

    cond do
      # Full-dialect URL (/en-GB/): the HTTP plug accepts these via the
      # enabled-languages list, so the LiveView lifecycle must too — a
      # base-only guard made live navigation ignore them and snapped a
      # dead render's dialect back to the default on WS connect.
      dialect = String.contains?(locale, "-") && enabled_full_dialect(locale) ->
        if socket.assigns[:current_locale] == dialect do
          socket
        else
          put_gettext_locale(dialect, socket.view)

          socket
          |> Phoenix.Component.assign(:current_locale_base, DialectMapper.extract_base(dialect))
          |> Phoenix.Component.assign(:current_locale, dialect)
        end

      current_base != locale and DialectMapper.valid_base_code?(locale) ->
        update_locale_from_base(socket, locale)

      true ->
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
      default_dialect = resolve_active_dialect(default_base)

      put_gettext_locale(default_dialect, socket.view)

      socket
      |> Phoenix.Component.assign(:current_locale_base, default_base)
      |> Phoenix.Component.assign(:current_locale, default_dialect)
    end
  end

  # URL-driven dialect: the base code maps to the host's ACTIVE dialect
  # (see `resolve_active_dialect/1`). Deliberately takes no user — a
  # user's `preferred_locale` would otherwise upgrade base "en" →
  # "en-GB", contradicting the URL-is-authoritative semantic held
  # across both the LV mount and the HTTP plug.
  defp update_locale_from_base(socket, locale) do
    full_dialect = resolve_active_dialect(locale)

    # Set both the backend-specific Gettext value and the process-global
    # default (feature modules with their own backends pick it up too).
    put_gettext_locale(full_dialect, socket.view)

    socket
    |> Phoenix.Component.assign(:current_locale_base, locale)
    |> Phoenix.Component.assign(:current_locale, full_dialect)
  end

  defp mount_phoenix_kit_current_user(socket, session) do
    socket = maybe_attach_current_page_hook(socket)

    # The raw session token is kept on the socket so the scope refresh can
    # reload the user THROUGH it (`refresh_scope_assigns/1`): the role a
    # session acts as rides on the token (`PhoenixKit.Users.ActiveRole`), and
    # a reload by uuid would drop it. Server-side only; never rendered.
    socket
    |> Phoenix.Component.assign_new(:phoenix_kit_session_token, fn -> session["user_token"] end)
    |> Phoenix.Component.assign_new(:phoenix_kit_current_user, fn ->
      case session["user_token"] do
        nil -> nil
        user_token -> get_active_user_from_token(user_token)
      end
    end)
  end

  # Guarded like the locale, scope-refresh and timezone hooks: LiveView raises
  # on a second attach with the same id, and this mount step runs once per
  # scope-mounting hook — so `:phoenix_kit_mount_current_scope` followed by any
  # `:phoenix_kit_ensure_*` hook (or `{:phoenix_kit_require, _}`) used to crash
  # with "existing hook :current_page already attached".
  defp maybe_attach_current_page_hook(
         %{assigns: %{phoenix_kit_current_page_hook_attached?: true}} = socket
       ),
       do: socket

  defp maybe_attach_current_page_hook(socket) do
    socket
    |> attach_hook(:current_page, :handle_params, &set_routing_info(&1, &2, &3))
    |> Phoenix.Component.assign(:phoenix_kit_current_page_hook_attached?, true)
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
  # Deliberately does NOT attach the timezone `handle_event` hook. This runs
  # outside the LiveView lifecycle (that is the point of an embed), so
  # `attach_hook/4` has no lifecycle to attach to. The layout gates the
  # detector on the flag the attachment sets, so an embedded page simply does
  # not render it rather than pushing an event nothing can handle.
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
      |> maybe_attach_timezone_hook()

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
    current_locale = resolve_active_dialect(current_locale_base)

    # Set Gettext locale for translations (backend-specific + global, so
    # module backends like PhoenixKitProjects.Gettext sync too).
    put_gettext_locale(current_locale, socket.view)

    socket
    |> maybe_manage_scope_subscription(user)
    |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
    |> Phoenix.Component.assign(:current_locale, current_locale)
    |> Phoenix.Component.assign(:current_locale_base, current_locale_base)
    # Fold the maintenance check into the shared scope mount so any new
    # live_session that uses a scope-mounting hook can't forget it.
    |> check_maintenance_mode()
    # Same reasoning as maintenance mode above: folded into the shared scope
    # mount so every live_session built on a scope-mounting hook — admin,
    # feature modules, and a host app's own authenticated pages alike — is
    # tracked in "Live sessions" without remembering to call Presence itself.
    |> maybe_track_presence()
  end

  # Guarded like the neighboring maybe_attach_*_hook steps: this mount step
  # runs once per scope-mounting hook, and a second
  # `:phoenix_kit_ensure_*`/`{:phoenix_kit_require, _}` following
  # `:phoenix_kit_mount_current_scope` in the same live_session must not track
  # the same connected process twice.
  defp maybe_track_presence(%{assigns: %{phoenix_kit_presence_tracked?: true}} = socket),
    do: socket

  defp maybe_track_presence(socket) do
    # Read back off the socket (like check_maintenance_mode/1 above) rather
    # than taking scope as an argument — Dialyzer flags the locally-built
    # struct-update value as an opaque-subterm mismatch against Scope.user/1's
    # spec at this call site; the assign, already set by the pipe step just
    # above, does not trigger it.
    scope = socket.assigns[:phoenix_kit_current_scope]

    # Only a CONNECTED mount — the static/disconnected render's process is
    # thrown away before it could ever disconnect, so tracking it would leak
    # a presence row no `:DOWN` will ever clean up.
    if Phoenix.LiveView.connected?(socket) and Scope.authenticated?(scope) do
      session_id = presence_session_id(socket)

      # `current_page` starts nil (unknown until `set_routing_info/3` runs on
      # this same connected mount's initial `handle_params`) rather than
      # omitted — `Presence.get_presence_stats/0` reads `.current_page` on
      # every tracked row, and a row without the key would crash the first
      # stats read from ANY subscribed LiveView, not just this one.
      Presence.track_user(Scope.user(scope), %{
        connected_at: UtilsDate.utc_now(),
        session_id: session_id,
        ip_address: IpAddress.extract_from_socket(socket),
        user_agent: Phoenix.LiveView.get_connect_info(socket, :user_agent),
        current_page: nil
      })

      socket
      |> Phoenix.Component.assign(:phoenix_kit_presence_tracked?, true)
      |> Phoenix.Component.assign(:phoenix_kit_presence_session_id, session_id)
    else
      socket
    end
  end

  # A SHA-256 digest of the session token, not `Sessions.live_socket_id/1`'s
  # `"phoenix_kit_sessions:" <> Base.url_encode64(token)` (reversible back to
  # the raw token by anyone who reads it) or the raw token itself. Presence
  # rows, their PubSub events, and — before this — the `catch :exit` log line
  # in `SimplePresence` all carry `session_id`; hashing it means none of them
  # can leak a working session credential. Still stable per login (same token
  # in, same digest out), so multi-tab idempotency in `SimplePresence` is
  # unaffected — just no longer reversible.
  defp presence_session_id(socket) do
    case socket.assigns[:phoenix_kit_session_token] do
      token when is_binary(token) ->
        :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

      _ ->
        nil
    end
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

  # The TimezoneDetector hook reports the browser's zone from the layout, so it
  # fires on whatever page the person happens to open. Handling it here — once,
  # on the shared authenticated mount path — means no individual LiveView needs
  # to know the event exists.
  defp maybe_attach_timezone_hook(
         %{assigns: %{phoenix_kit_timezone_hook_attached?: true}} = socket
       ),
       do: socket

  defp maybe_attach_timezone_hook(socket) do
    socket
    |> attach_hook(:phoenix_kit_timezone_detected, :handle_event, &handle_timezone_detected/3)
    |> Phoenix.Component.assign(:phoenix_kit_timezone_hook_attached?, true)
  end

  defp handle_timezone_detected("phoenix_kit:timezone_detected", %{"name" => name}, socket)
       when is_binary(name) do
    TimeZoneAlert.observe(socket.assigns[:phoenix_kit_current_user], name)
    {:halt, socket}
  end

  defp handle_timezone_detected(_event, _params, socket), do: {:cont, socket}

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

  defp handle_scope_refresh({:phoenix_kit_scope_roles_updated, user_uuid}, socket),
    do: refresh_scope(user_uuid, :roles_updated, socket)

  # The user switched the role they act as (`PhoenixKit.Users.ActiveRole`),
  # possibly in another tab or on another device. Refreshed identically; only
  # the copy shown if the page must be left differs.
  defp handle_scope_refresh(
         {:phoenix_kit_scope_roles_updated, user_uuid, :active_role_changed},
         socket
       ),
       do: refresh_scope(user_uuid, :active_role_changed, socket)

  defp handle_scope_refresh(_msg, socket), do: {:cont, socket}

  defp refresh_scope(user_uuid, reason, socket) do
    current_scope = socket.assigns[:phoenix_kit_current_scope]

    if Scope.user_uuid(current_scope) == user_uuid do
      was_admin? = Scope.can_access_admin_area?(current_scope)
      {socket, new_scope} = refresh_scope_assigns(socket)

      # Re-derive the page's own scope-dependent state BEFORE deciding whether
      # to move the visitor. Order is load-bearing in the eviction case too:
      # this is where the dashboard releases the operator PubSub subscriptions a
      # revoked visitor no longer justifies, and that has to happen whether or
      # not they are also navigated away.
      socket =
        socket
        |> refresh_view_scope_assigns()
        |> maybe_subscribe_promoted_landing(new_scope)

      decision =
        scope_refresh_decision(
          was_admin?,
          new_scope,
          socket.view,
          socket.assigns[:phoenix_kit_current_module_key]
        )

      {:halt, apply_scope_refresh_decision(socket, decision, new_scope, reason)}
    else
      {:cont, socket}
    end
  end

  # What a mid-session permission change does to the page the visitor is on.
  # Pure — no socket, no flash, no navigation — so the branches are unit
  # testable without a database, and so the landing exemption is stated once
  # rather than being buried in a `cond` beside its side effects.
  #
  #   * `:evict_admin_area` — held admin access, holds none now, and is NOT on
  #     the guaranteed landing.
  #   * `:evict_module` — still in the admin area, but lost the permission the
  #     current view resolved to.
  #   * `:stay` — nothing to do.
  #
  # The landing exemption is the whole point of the first branch's second
  # condition. `landing_view?/1` is the same predicate `:phoenix_kit_ensure_admin`
  # uses to admit EVERY authenticated visitor to `/admin`, and
  # `PhoenixKit.Utils.Routes.safe_destination/2` terminates there precisely
  # because of that. Evicting a demoted user from it would push them off the one
  # page core guarantees them — and toward a destination whose terminal is that
  # same page. It is the bounce the resolver asserts cannot happen, so it must
  # not happen here either. Every other admin page evicts exactly as before; the
  # landing instead recomputes its own gates in place
  # (`PhoenixKitWeb.Live.Dashboard.Overview.assign_scope_gates/1`), so the
  # demoted visitor keeps the page and loses the operator content on it.
  #
  # The exemption is NOT an authentication exemption, exactly as it is not one
  # at the mount gate: `require_authenticated_live/2` runs before
  # `admin_gate_decision/2` there, and here the scope must still be
  # authenticated to keep the page. A scope that came back unauthenticated means
  # the user row is gone from under the socket, and the landing is no more
  # theirs than any other page.
  #
  # The second branch cannot fire on the landing anyway — `:landing` skips
  # `enforce_admin_view_permission/2`, so `:phoenix_kit_current_module_key` is
  # never assigned there and `module_access?/2` answers `true` for `nil`. That
  # is a consequence, not a guarantee; the first branch states the exemption.
  #
  # Exposed as `@doc false def` (like `admin_gate_decision/2`) so tests can
  # drive the branches with literal scopes. Not part of the public API.
  @doc false
  @spec scope_refresh_decision(boolean(), Scope.t() | nil, module() | nil, String.t() | nil) ::
          :evict_admin_area | :evict_module | :stay
  def scope_refresh_decision(was_admin?, new_scope, view, module_key) do
    cond do
      was_admin? and not Scope.can_access_admin_area?(new_scope) ->
        if landing_view?(view) and Scope.authenticated?(new_scope),
          do: :stay,
          else: :evict_admin_area

      Scope.can_access_admin_area?(new_scope) and not module_access?(new_scope, module_key) ->
        :evict_module

      true ->
        :stay
    end
  end

  # The landing is the one admin page a visitor can be sitting on WITHOUT the
  # modules subscription: `prepare_admin_mount/2` deliberately skips it for a
  # visitor who is shown no admin navigation. Being granted a permission
  # mid-session gives them that navigation, so from this moment they have a
  # sidebar that must re-render when an Owner toggles a module. Every other
  # admin page subscribed at mount — reaching it required the admin area.
  #
  # `maybe_subscribe_to_module_events/1` is idempotent (it short-circuits on
  # `phoenix_kit_module_hook_attached?`), so a repeated grant costs nothing.
  defp maybe_subscribe_promoted_landing(socket, new_scope) do
    if landing_view?(socket.view) and Scope.can_access_admin_area?(new_scope) do
      maybe_subscribe_to_module_events(socket)
    else
      socket
    end
  end

  defp apply_scope_refresh_decision(socket, :evict_admin_area, new_scope, reason) do
    socket
    |> LiveView.put_flash(:error, eviction_message(:evict_admin_area, reason))
    |> LiveView.push_navigate(
      to: Routes.safe_destination(socket, scope: new_scope, skip_admin: true)
    )
  end

  defp apply_scope_refresh_decision(socket, :evict_module, new_scope, reason) do
    socket
    |> LiveView.put_flash(:error, eviction_message(:evict_module, reason))
    |> LiveView.push_navigate(to: best_available_admin_path(socket, new_scope))
  end

  defp apply_scope_refresh_decision(socket, :stay, _new_scope, _reason), do: socket

  # "You must be an admin" reads as an accusation to someone who just chose to
  # act as another role, so a switch gets its own copy.
  defp eviction_message(_decision, :active_role_changed),
    do: gettext("This page is not available in the role you switched to.")

  defp eviction_message(:evict_admin_area, _reason),
    do: gettext("You must be an admin to access this page.")

  defp eviction_message(:evict_module, _reason),
    do: gettext("You no longer have permission to access this section.")

  # Lets a LiveView re-derive whatever it computed from the scope, now that the
  # scope has changed under it.
  #
  # Gates computed once in `mount/3` go stale the moment a permission is granted
  # or revoked, and on the guaranteed landing — which nobody is evicted from —
  # stale is where they stay for the life of the socket. A page opts in by
  # exporting `phoenix_kit_scope_changed/1`; `use PhoenixKitWeb.Live.Dashboard.Overview`
  # injects it, and it must recompute EVERY gate in one place so a future gate
  # cannot be forgotten here.
  #
  # Deliberately a duck-typed callback rather than a hardcoded call to the
  # dashboard: this hook is attached to every PhoenixKit LiveView, and a host
  # admin page with its own permission-derived assigns has the same problem.
  # `Code.ensure_loaded?/1` guards `function_exported?/2`, which answers false
  # for a module that has not been loaded yet (releases load lazily).
  #
  # Exposed as `@doc false def` so the wiring — hook → callback → the page's own
  # gate recomputation — is testable without the database `handle_scope_refresh/2`
  # needs to re-read the user. Not part of the public API.
  @doc false
  @spec refresh_view_scope_assigns(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_view_scope_assigns(socket) do
    view = socket.view

    if is_atom(view) and not is_nil(view) and Code.ensure_loaded?(view) and
         function_exported?(view, :phoenix_kit_scope_changed, 1) do
      view.phoenix_kit_scope_changed(socket)
    else
      socket
    end
  end

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
    {:halt, module_toggled(socket)}
  end

  defp handle_module_refresh({:module_disabled, _key}, socket) do
    {:halt, module_toggled(socket)}
  end

  defp handle_module_refresh(_msg, socket), do: {:cont, socket}

  # A module toggle changes what a page may show without changing anyone's
  # scope, so the version bump alone is not enough: gates derived from a
  # permission key ask `Permissions.feature_enabled?/1` too, and a page that
  # only re-renders would keep offering a card for a module that was just
  # switched off. The landing is where this matters most — it is the one admin
  # page nobody is ever evicted from, so a stale gate there survives until the
  # visitor navigates away by hand.
  defp module_toggled(socket) do
    socket
    |> refresh_view_scope_assigns()
    |> Phoenix.Component.assign(:phoenix_kit_modules_version, System.unique_integer())
  end

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
    # A user granted only "notifications" (their own inbox+settings) has no
    # "dashboard" access, so landing them here — not "/" — is their first
    # reachable admin page.
    {"notifications", "/admin/notifications"},
    # A user granted only "storage" uses their own storage libraries. While
    # user libraries are off that page sends them to their profile settings,
    # never back to /admin, so this cannot loop.
    {"storage", "/admin/libraries"},
    # The personal "integrations" key has no /admin page anymore ("My
    # Integrations" moved to /profile/settings/integrations) — a holder of
    # only that key falls through to the skip_admin default below instead.
    {"integrations_system", "/admin/settings/integrations"},
    # Settings sub-pages (lower priority landing pages)
    {"languages", "/admin/settings/languages"},
    {"crawlers", "/admin/settings/crawlers"},
    {"sitemap", "/admin/settings/sitemap"},
    {"legal", "/admin/settings/legal"},
    {"referrals", "/admin/settings/referral-codes"}
  ]

  # Find the best admin page the user has access to.
  # Checks both permission (user can access) AND enabled status (module is active)
  # to prevent redirect loops when a user has permission for a disabled module.
  #
  # `skip_admin: true` on the fall-through is MANDATORY, not defensive. This
  # default is only reached by a user who lacks the "dashboard" permission (the
  # first entry in @admin_fallback_routes is `{"dashboard", "/admin"}`) — yet
  # such a user still passes `can_access_admin_area?/1` on any other permission,
  # so the resolver's `/admin` step would send them to a page that denies them
  # and lands right back here. `source` is the conn/socket the redirect is being
  # built for; it carries the router used to prove the destination exists.
  defp best_available_admin_path(source, scope) do
    enabled = Permissions.enabled_module_keys()

    # Built-in routes first, then custom extension routes from admin tab config
    all_routes = @admin_fallback_routes ++ custom_admin_fallback_routes()

    Enum.find_value(all_routes, fn {key, path} ->
      if Scope.has_module_access?(scope, key) and MapSet.member?(enabled, key),
        do: Routes.path(path)
    end) || Routes.safe_destination(source, scope: scope, skip_admin: true)
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

  @doc """
  Whether `scope` may open the admin LiveView `view_module` — the SAME decision
  `:phoenix_kit_ensure_admin` enforces on mount, exposed as a pure boolean.

  Use it to decide whether to *render* a link, card or nav entry pointing at an
  admin view. "A card is visible iff the visitor can open what it links to"
  then holds by construction: both the card and its destination route through
  this one function, so the two cannot drift.

  Pure — no flash, no redirect, no logging. The on_mount hook keeps those side
  effects (including the one-time "unmapped admin view" warning) and asks this
  same decision for the verdict.

  Pass `live_action` whenever you have it. Admin-tab permissions are cached
  by `{module, live_action}` (a tab registered as `live_view: {Mod, :action}`
  is only found under that key), so a module-only call answers for a tab
  registered without an action and reports *unmapped* for one registered
  with an action — the mount gate always has the action, and so does any
  caller resolving a route through `Phoenix.Router.route_info/4`.

  ## The decision, branch by branch

  1. **Admin-area gate** — `Scope.can_access_admin_area?/1` must hold (Owner,
     Admin, or any holder of at least one permission). Every `/admin` page
     mounts through `:phoenix_kit_ensure_admin`, which bounces a failing scope
     before any per-view check — every page but the landing, which is the one
     deliberate difference between this function and the gate (see below). So a
     card must respect it too: a `nil` scope, and an authenticated user with no
     permissions at all, stop here.
  2. **Personal admin views** — the views in `@personal_admin_views` (your own
     notification inbox / preferences) show a user their OWN data rather than
     granting an administrative capability, so branch 1 is the whole gate.
  3. **Mapped view** — `permission_key_for_admin_view/2` resolved a key:
     * the module behind the key must be enabled
       (`PhoenixKit.Users.Permissions.feature_enabled?/1`) — a disabled module
       is blocked for EVERYONE, Owner included;
     * a dotted SUB-permission key is checked with `Scope.can?/2` (which also
       requires the base key — a raw sub-key without its base is an orphan);
       a flat key with `Scope.has_module_access?/2`.
  4. **Unmapped view** — the key resolved to `nil`: allowed ONLY for a scope
     that holds every enabled permission (`Scope.holds_all_enabled_permissions?/1`).
     This is the fail-CLOSED branch, and it is role-agnostic: Owner passes (it
     holds every key by construction), so does the `"*"` superadmin key and any
     role granted the whole operator baseline; a partially-revoked Admin or a
     narrow custom role does not. Hiding such a card from everyone but a
     full-access scope is exactly right — anyone else is redirected on arrival.

  What this deliberately does NOT answer: authentication, email confirmation
  and the account gate (`require_authenticated_live/2` and `live_account_gate/2`
  run earlier in the hook). Those bounce a visitor before any view-permission
  question is asked; a page deciding what to render has already passed them.

  ## The one view where this is stricter than the mount gate

  `landing_view?/1` — the `/admin` index — is admitted by
  `:phoenix_kit_ensure_admin` for EVERY authenticated visitor, because it is the
  destination `PhoenixKit.Utils.Routes.safe_destination/2` guarantees. This
  function still answers `false` for a scope that fails branch 1, and that is
  deliberate: the landing is somewhere a visitor is *sent*, not somewhere a menu
  should *offer* them. A permission-less visitor who lands there is greeted and
  shown no navigation at all
  (`PhoenixKitWeb.Components.Dashboard.AdminSidebar.reachable_tabs/2` returns
  `[]` for exactly the same scopes), so answering `true` would render a link to
  a page they are already on, inside a shell built for operators.

  Every other view answers identically here and at the gate, which is what makes
  "a card is visible iff its destination admits you" true — a visible card is
  never a redirect, and the only page that admits more than it advertises is the
  one no card points at.

  ## Examples

      # compute in the LiveView, keep HEEx declarative
      assign(socket,
        show_users_card?:
          Auth.can_access_admin_view?(scope, PhoenixKitWeb.Live.Users.Users)
      )
  """
  @spec can_access_admin_view?(Scope.t() | nil, module(), atom() | nil) :: boolean()
  def can_access_admin_view?(scope, view_module, live_action \\ nil)
      when is_atom(view_module) do
    cond do
      not Scope.can_access_admin_area?(scope) ->
        false

      personal_admin_view?(view_module) ->
        true

      true ->
        admin_view_permission_check(
          scope,
          permission_key_for_admin_view(view_module, live_action)
        ) == :ok
    end
  end

  # Enforces module-level permission checks for admin views.
  # Extracted from on_mount(:phoenix_kit_ensure_admin) to reduce complexity.
  defp enforce_admin_view_permission(socket, scope) do
    if personal_admin_view?(socket.view) do
      {:cont, socket}
    else
      enforce_mapped_admin_view_permission(socket, scope)
    end
  end

  # Admin-chrome views showing a user their OWN data rather than granting an
  # administrative capability. Reaching admin chrome at all already requires
  # `can_access_admin_area?/1`, so this is not a hole — it says that once you
  # are in, reading your own mail is not a separate privilege.
  #
  # ⚠️ This has to be an explicit list, not an absence. Simply dropping these
  # views from `@admin_view_permissions` would make them *unmapped*, and the
  # unmapped fallback below is deliberately Owner-only — the opposite of the
  # intent.
  # A plain list, not a MapSet: a MapSet in a module attribute is inlined as a
  # literal, which leaks its internal representation past the opaque type.
  @personal_admin_views [
    PhoenixKitWeb.Live.Notifications.Inbox,
    PhoenixKitWeb.Live.Notifications.Settings
  ]

  defp personal_admin_view?(view), do: view in @personal_admin_views

  # One warning per unmapped view, for ANY role — not only on a denial.
  #
  # This used to be a single `Logger.debug`, which meant a host could ship an
  # admin page, test it as Owner, see it work, and learn about the missing
  # mapping when a colleague hit a 403. Warning on the first mount regardless of
  # who mounts it surfaces the misconfiguration while the author is still
  # looking at the page.
  #
  # Deduped through `:persistent_term` keyed by the view module. That is
  # naturally bounded — it holds only the distinct unmapped LiveView modules
  # that ever mount, and module atoms are permanent in the BEAM anyway. The
  # process dictionary would not work: a LiveView is its own process, so it
  # would re-log on every mount.
  defp warn_unmapped_admin_view_once(view) do
    key = {__MODULE__, :unmapped_admin_view, view}

    case :persistent_term.get(key, :unseen) do
      :unseen ->
        :persistent_term.put(key, :warned)

        Logger.warning("""
        [PhoenixKit] Admin view #{inspect(view)} has no permission mapping.

        Only a scope holding every enabled permission can reach it — so it works
        for an Owner and 403s for everyone else, including a named Admin whose
        keys have been partially revoked.

        Map it by giving its admin tab a `permission:` key, or by declaring the
        key in `config :phoenix_kit, :custom_permission_keys` and registering the
        view through a tab's `live_view:`.
        """)

      :warned ->
        :ok
    end
  end

  # The enforcement side: same decision as `can_access_admin_view?/2`, plus the
  # side effects a mount needs (the unmapped-view warning, the current-module
  # assign, and the two different denials). The verdict itself is NOT recomputed
  # here — it comes from `admin_view_permission_check/2`, the single
  # implementation both callers share.
  defp enforce_mapped_admin_view_permission(socket, scope) do
    module_key =
      permission_key_for_admin_view(socket.view, socket.assigns[:live_action])

    socket =
      case module_key do
        nil ->
          warn_unmapped_admin_view_once(socket.view)
          socket

        key ->
          Phoenix.Component.assign(socket, :phoenix_kit_current_module_key, key)
      end

    case admin_view_permission_check(scope, module_key) do
      :ok ->
        {:cont, socket}

      {:denied, {:module_disabled, key}} ->
        deny_module_disabled(socket, key)

      {:denied, _reason} ->
        case settings_landing_redirect(socket, scope) do
          nil -> deny_admin_access(socket, scope)
          path -> {:halt, LiveView.redirect(socket, to: Routes.path(path))}
        end
    end
  end

  # Settings → General (`/admin/settings`) is gated on `"settings"` alone, but
  # the Settings entry is shown to anyone holding any settings subtab's key
  # (`AdminTabs.settings_visible?/1`). The sidebar already links such a
  # visitor to a subtab they can open (#851); every OTHER way here — a
  # settings page's section header, the Sitemap page's button, a bookmark, a
  # typed URL — still landed on General and was refused. Send them where the
  # sidebar would, instead of refusing, and without an error: nothing they
  # asked for was withheld.
  defp settings_landing_redirect(
         %{view: PhoenixKitWeb.Live.Settings, assigns: %{live_action: :index}},
         scope
       ) do
    TabRegistry.get_admin_tabs(scope: scope)
    |> AdminSidebar.reachable_tabs(scope)
    |> settings_landing_path()
  end

  defp settings_landing_redirect(_socket, _scope), do: nil

  @settings_landing "/admin/settings"

  @doc false
  # Where a visitor refused General should go, from the admin tabs they can
  # reach: the first settings subtab, by the same rule the sidebar follows
  # (`TabHelpers.redirect_target/2`). `nil` when there is none — or when that
  # rule names General itself, which the gate has just refused: redirecting
  # there would loop.
  def settings_landing_path(reachable_tabs) do
    subtabs = TabHelpers.get_subtabs_for(:admin_settings, reachable_tabs)

    case TabHelpers.redirect_target(%{path: @settings_landing}, subtabs) do
      @settings_landing -> nil
      path -> path
    end
  end

  # THE gate for "may a scope open a view that resolves to `module_key`".
  #
  # Every caller — the on_mount enforcement above and the public
  # `can_access_admin_view?/2` used to decide whether to render a link at all —
  # routes through here, so a visible card and its destination cannot disagree.
  # Returns `:ok`, or `{:denied, reason}` where the reason only selects which
  # denial the enforcement renders; it never widens or narrows the decision.
  #
  # Unmapped views (a host custom admin LV with no permission mapping): allow
  # ONLY a scope that can reach everything, fail closed for partial roles.
  # `holds_all_enabled_permissions?/1` is fully role-AGNOSTIC — it is satisfied
  # by Owner (all keys by construction), by the explicit `"*"` superadmin key,
  # and by any role granted every grantable permission.
  #
  # The former `or system_role?` arm was REMOVED: it let a named Admin whose
  # keys an Owner had partially revoked still reach unmapped views, violating
  # "no role is special for feature access". A default Admin still passes
  # because `holds_all_enabled_permissions?/1` compares against the operator
  # baseline (enabled keys MINUS opt-in ones), and Admin auto-holds every one of
  # those. To keep a deliberately-stripped role's blanket access, an Owner
  # grants it the `"*"` key — the drift-immune, role-agnostic way.
  defp admin_view_permission_check(scope, nil) do
    if Scope.holds_all_enabled_permissions?(scope) do
      :ok
    else
      {:denied, :unmapped_view}
    end
  end

  defp admin_view_permission_check(scope, module_key) do
    cond do
      # Disabled modules are blocked for all roles (including Owner/Admin)
      not Permissions.feature_enabled?(module_key) ->
        {:denied, {:module_disabled, module_key}}

      # Every role — Admin included — needs the permission key. Owner
      # passes because its scope holds every key by construction; Admin
      # holds keys as real rows (seeded/auto-granted, Owner-revocable).
      # The old system-role bypass here made Owner's revocations on the
      # Admin role effective everywhere EXCEPT fresh mounts — sidebar,
      # plugs, and the mid-session PubSub kick all honored them already.
      #
      # A tab may resolve to a dotted SUB-permission, and a raw sub-key
      # without its base is an orphan (`has_module_access?/2` leaves that
      # check to its caller). `can?/2` applies it, so route dotted keys
      # there rather than admitting an orphan the sidebar already hides.
      view_permission_held?(scope, module_key) ->
        :ok

      true ->
        {:denied, :missing_permission}
    end
  end

  defp view_permission_held?(scope, module_key) do
    if Permissions.parent_key(module_key) do
      Scope.can?(scope, module_key)
    else
      Scope.has_module_access?(scope, module_key)
    end
  end

  defp deny_module_disabled(socket, module_key) do
    label = Permissions.localized_module_label(module_key)

    # The label is localized, so the sentence around it must be too — an
    # English frame around a translated name reads worse than either alone.
    message =
      gettext("%{label} module is not enabled",
        label: label
      )

    socket =
      socket
      |> Phoenix.LiveView.put_flash(:error, message)
      # The Disabled tab, where the module's card and its switch are. The
      # default Active tab does not list it at all.
      |> Phoenix.LiveView.redirect(to: Routes.path("/admin/modules?tab=disabled"))

    {:halt, socket}
  end

  defp deny_admin_access(socket, scope) do
    redirect_to = best_available_admin_path(socket, scope)

    socket =
      socket
      |> Phoenix.LiveView.put_flash(
        :error,
        gettext("You do not have permission to access this section.")
      )
      |> Phoenix.LiveView.redirect(to: redirect_to)

    {:halt, socket}
  end

  # Does the scope still hold the key the currently viewed module resolved to?
  # `nil` means the view never resolved to one — an unmapped view, or the
  # landing, which skips the enforcement that assigns it — and there is then no
  # module permission to have lost.
  defp module_access?(_scope, nil), do: true
  defp module_access?(scope, module_key), do: Scope.has_module_access?(scope, module_key)

  # Maps admin LiveView modules to their permission keys.
  # Used by :phoenix_kit_ensure_admin to enforce module-level permissions
  # on core admin routes that share the same live_session, and by
  # `can_access_admin_view?/2` to decide whether to render a link to one.
  # A view absent from every resolution layer resolves to nil and is treated as
  # UNMAPPED — which fails closed (full-access scopes only), not open. The
  # "allows access by default for backward compat" this comment used to claim
  # stopped being true when the `or system_role?` arm was removed.
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
    PhoenixKitWeb.Live.Users.MediaStorage => "media.manage",
    PhoenixKitWeb.Live.Users.MediaSelector => "media",
    PhoenixKitWeb.Live.Users.Libraries => "storage",
    PhoenixKitWeb.Live.Settings => "settings",
    PhoenixKitWeb.Live.Settings.Users => "settings",
    PhoenixKitWeb.Live.Settings.Organization => "settings",
    # Login / OAuth / authorization settings — maps to the `settings` key. Like
    # the other Settings.* pages it resolves through no inference layer, so an
    # explicit entry is required or it falls through to the unmapped fallback.
    PhoenixKitWeb.Live.Settings.Authorization => "settings",
    # Website access (password gate, redirect, closed page, noindex, allow list).
    PhoenixKitWeb.Live.Settings.WebsiteAccess => "settings",
    # Integrations + Emails Transactional/Bulk settings pages: none of these resolve
    # through the later inference layers (their PhoenixKitWeb namespace has no
    # ModuleRegistry entry), so an explicit mapping is required — unmapped
    # views fail closed and custom roles holding the "settings" permission
    # were denied pages whose nav links they could see.
    # System (website-wide) integrations moved off the broad `settings` key to
    # their own independent `integrations_system` key (grantable on its own).
    PhoenixKitWeb.Live.Settings.Integrations => "integrations_system",
    PhoenixKitWeb.Live.Settings.IntegrationForm => "integrations_system",
    # Personal per-user integrations moved to /profile/settings/integrations
    # (the :phoenix_kit_authenticated session, not this admin gate) — each
    # LiveView checks the `integrations` permission itself in mount/3 now,
    # so no entry belongs in this admin-gate map.
    PhoenixKitWeb.Live.Settings.EmailSending => "settings",
    PhoenixKitWeb.Live.Settings.EmailPreview => "settings",
    PhoenixKitWeb.Live.Settings.SendProfiles => "settings",
    PhoenixKitWeb.Live.Settings.SendProfileForm => "settings",
    PhoenixKitWeb.Live.Settings.Crawlers => "crawlers",
    PhoenixKitWeb.Live.Modules.Languages => "languages",
    PhoenixKitWeb.Live.Modules.Storage.Settings => "media.manage",
    PhoenixKitWeb.Live.Modules.Storage.BucketForm => "media.manage",
    PhoenixKitWeb.Live.Modules.Storage.BucketPage => "media.manage",
    PhoenixKitWeb.Live.Modules.Storage.LibraryPage => "media.manage",
    PhoenixKitWeb.Live.Modules.Storage.Dimensions => "media.manage",
    PhoenixKitWeb.Live.Modules.Storage.DimensionForm => "media.manage",
    # Media health dashboard — same `media.manage` key as the other Storage admin LVs.
    # (Its `PhoenixKitWeb.Live.Modules.Storage.*` namespace resolves through no
    # inference branch, so without this it fell through to the unmapped
    # fallback and a `media`-only custom role was wrongly denied it.)
    PhoenixKitWeb.Live.Modules.Storage.Health => "media.manage",
    PhoenixKitWeb.Live.Modules.Jobs.Index => "jobs",
    # Notifications' two personal pages are NOT here — they are in
    # `@personal_admin_views`, because reading your own inbox is not an
    # administrative capability. The `notifications` key is reserved for an
    # all-users/moderation view (its context API survives for that rebuild:
    # `Notifications.admin_list/1`, `admin_stats/0`).
    # Activity feed / audit log — gated by `dashboard` (its admin tab is too).
    # These `PhoenixKitWeb.Live.Activity.*` modules resolve through no inference
    # layer, so without an explicit entry they hit the unmapped fallback — which
    # (post-fix) only a full-access scope passes, wrongly denying a custom role
    # that legitimately holds only `dashboard`.
    PhoenixKitWeb.Live.Activity.Index => "dashboard",
    PhoenixKitWeb.Live.Activity.Show => "dashboard"
  }

  # Resolve a LiveView module (optionally scoped to a live_action) to its
  # permission key.
  #
  # Resolution order (first non-nil wins):
  #
  #   1. `@admin_view_permissions` static map — core admin views.
  #   2. `infer_permission_from_custom_tabs/2` — modules that registered
  #      admin tabs with a `live_view:` field. A tab naming
  #      `{module, action}` caches under that exact key, so two tabs
  #      sharing a module but gated on different actions resolve
  #      independently instead of one overwriting the other (#844); a
  #      tab that named no action falls back to the bare module key.
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
  def permission_key_for_admin_view(view_module, live_action \\ nil) do
    case Map.get(@admin_view_permissions, view_module) do
      nil ->
        case infer_permission_from_custom_tabs(view_module, live_action) do
          {:ok, key} -> key
          # Tabs name this module and disagree. Namespace inference would
          # hand an untabbed action the module's own key (`PhoenixKit.Modules.
          # Reports.Web` → `"reports"`), which anyone holding either tab
          # already has. Stay unmapped so the view fails closed.
          :unmapped -> nil
          :miss -> infer_permission_key_from_module(view_module)
        end

      key ->
        key
    end
  end

  # Looks up the permission key from the cached custom view → permission
  # mapping. Populated at Registry init time from :admin_dashboard_tabs
  # config.
  #
  #   * the exact `{module, action}` key, when a tab named that action
  #   * the bare module key, when a tab named the module without an action —
  #     that tab claims every action no other tab names, its own landing
  #     action included
  #   * the module's one tab permission, when every action-specific tab
  #     agrees — an untabbed `:show` / `:edit` is guarded by it
  #   * `:unmapped` when those tabs disagree (#844: a landing redirector and
  #     the page behind it, gated differently): no safe answer for an action
  #     neither names, so it fails closed
  #   * `:miss` when nothing is cached, so the caller may infer from the
  #     module's namespace
  defp infer_permission_from_custom_tabs(view_module, live_action) do
    custom = Permissions.custom_view_permissions()

    with :error <- Map.fetch(custom, {view_module, live_action}),
         :error <- Map.fetch(custom, view_module) do
      case action_permission_keys(custom, view_module) do
        [key] -> {:ok, key}
        [_ | _] -> :unmapped
        [] -> :miss
      end
    end
  end

  defp action_permission_keys(custom, view_module) do
    for {{^view_module, action}, key} <- custom, is_atom(action), uniq: true, do: key
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
  # ── Website access: the password gate ──────────────────────────────

  # The relock hook is attached whether or not the gate is on right now: a
  # page opened while it was off must still be sent to the gate when an
  # admin switches it on (panel finding — otherwise an idle tab kept full
  # access until its next full page load).
  defp website_access_gate(session, socket) do
    # What the session held at mount rides on the socket for the relock
    # handler, whether or not the gate is on now: the unlock token (a relock
    # that did not change the epoch — the allowed list was edited — must not
    # throw out a visitor who typed the password) and the address the plug
    # remembered for an allowed visitor.
    socket =
      Phoenix.Component.assign(socket, %{
        phoenix_kit_website_access_unlock: Map.get(session, Atom.to_string(Gate.session_key())),
        phoenix_kit_website_access_address: remembered_address(session, socket)
      })

    cond do
      not Gate.enabled?() ->
        {:cont, maybe_attach_website_access_hook(socket)}

      Gate.session_unlocked?(session) or logged_in_session_passes?(session) or
          allowed_socket?(socket) ->
        {:cont, maybe_attach_website_access_hook(socket)}

      true ->
        {:halt, Phoenix.LiveView.redirect(socket, to: gate_path())}
    end
  end

  # The address the plug remembered on the HTTP request — kept only when the
  # live connection agrees. A tab carried to another network reconnects with
  # the old session and must not keep the office's pass, so a socket that can
  # tell where it comes from (a public peer, or forwarded headers in the
  # connect info) has to name the same address; one that cannot (behind a
  # proxy with `:peer_data` only) leaves the plug's verdict standing.
  defp remembered_address(session, socket) do
    with address when is_binary(address) <-
           Map.get(session, Atom.to_string(AccessPlug.allowed_session_key())),
         true <-
           not Phoenix.LiveView.connected?(socket) or
             IpAddress.client_address_from_socket(socket) in [nil, address] do
      address
    else
      _ -> nil
    end
  end

  # An allowed visitor, now: the remembered address is still on the list.
  # Read again on every relock, so an address taken off the list loses its
  # open pages too.
  defp allowed_socket?(socket) do
    case socket.assigns[:phoenix_kit_website_access_address] do
      address when is_binary(address) -> AllowedAddresses.allowed?(address)
      _ -> false
    end
  end

  # The plug stamps a logged-in user's session as unlocked on the HTTP
  # request, so this lookup only runs where the plug did not — a host without
  # `PhoenixKitWeb.Plugs.Integration` in its browser pipeline, or a test.
  defp logged_in_session_passes?(session) do
    Gate.users_pass?() and
      case Map.get(session, "user_token") do
        nil -> false
        token -> token |> Auth.get_user_by_session_token() |> Auth.ensure_active_user() != nil
      end
  end

  defp gate_path, do: AccessPlug.gate_path()

  # Subscribed on the connected mount (once per process); the handle_info
  # hook is attached on the first mount. A relock — the password changed, the
  # gate switched on, "relock everyone" — sends every open page to the gate.
  defp maybe_attach_website_access_hook(socket) do
    socket =
      if Phoenix.LiveView.connected?(socket) and
           !socket.assigns[:phoenix_kit_website_access_subscribed?] do
        Gate.subscribe()
        Phoenix.Component.assign(socket, :phoenix_kit_website_access_subscribed?, true)
      else
        socket
      end

    if socket.assigns[:phoenix_kit_website_access_hook_attached?] do
      socket
    else
      socket
      |> attach_hook(:phoenix_kit_website_access, :handle_info, &handle_website_access_relock/2)
      |> track_website_access_uri()
      |> Phoenix.Component.assign(:phoenix_kit_website_access_hook_attached?, true)
    end
  end

  # Remembers the page's path so a relock can send the visitor back to it
  # after the gate. Only a router-mounted LiveView has handle_params.
  defp track_website_access_uri(%{router: nil} = socket), do: socket

  defp track_website_access_uri(socket) do
    attach_hook(socket, :phoenix_kit_website_access_uri, :handle_params, fn _params,
                                                                            uri,
                                                                            socket ->
      {:cont, Phoenix.Component.assign(socket, :phoenix_kit_website_access_uri, uri)}
    end)
  end

  # A relock reaches every connected page. One that may stay — the gate is
  # off, or this is a logged-in user and logged-in users pass — stays; the
  # rest go through the gate and back to where they were.
  defp handle_website_access_relock({:website_access, :relock}, socket) do
    user = socket.assigns[:phoenix_kit_current_user]

    if not Gate.enabled?() or (Gate.users_pass?() and user != nil) or
         Gate.token_current?(socket.assigns[:phoenix_kit_website_access_unlock]) or
         allowed_socket?(socket) do
      {:halt, socket}
    else
      to =
        case socket.assigns[:phoenix_kit_website_access_uri] do
          uri when is_binary(uri) ->
            %URI{path: path, query: query} = URI.parse(uri)
            if query, do: "#{path}?#{query}", else: path || "/"

          _ ->
            "/"
        end

      {:halt,
       Phoenix.LiveView.redirect(socket,
         to: gate_path() <> "?" <> URI.encode_query(%{"to" => to})
       )}
    end
  end

  defp handle_website_access_relock(_message, socket), do: {:cont, socket}

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
        scope && (Scope.can_access_admin_area?(scope) || Scope.owner?(scope)) ->
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

    if scope && (Scope.can_access_admin_area?(scope) || Scope.owner?(scope)) do
      # HALT, not cont: for an admin the message is fully handled — maintenance
      # never blocks them, so there is nothing further to do. Continuing handed
      # the message to the LiveView's own handle_info, and any LV without a
      # clause for it (most of them) died in FunctionClauseError the moment a
      # maintenance toggle broadcast — or this hook's own end-of-window timer —
      # fired while an admin had the page open.
      {:halt, socket}
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
        case reload_session_user(socket, user_uuid) do
          %User{} = user ->
            scope =
              user
              |> Scope.for_user()
              |> carry_multi_session_fields(socket.assigns[:phoenix_kit_current_scope])

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

  # Through the session token when the mount kept one (the role the session
  # acts as lives on the token — `PhoenixKit.Users.ActiveRole`); by uuid for
  # an embedded mount that only ever had a `current_user_uuid`. A token that
  # no longer resolves (revoked, expired) is `nil` here, which the caller
  # treats as "the user is gone" — exactly what a revocation means. Both
  # branches go through `ensure_active_user/1` like every other token/user
  # resolution in this module: this refresh fires on a role-change broadcast,
  # and a deactivated user must not be handed a fresh authenticated scope by
  # the one path that re-reads them from the database.
  defp reload_session_user(socket, user_uuid) do
    case socket.assigns[:phoenix_kit_session_token] do
      token when is_binary(token) ->
        case token |> Auth.get_user_by_session_token() |> Auth.ensure_active_user() do
          %User{uuid: ^user_uuid} = user -> user
          _ -> nil
        end

      _ ->
        user_uuid |> Auth.get_user() |> Auth.ensure_active_user()
    end
  end

  # `Scope.for_user/1` knows nothing of the session, so the account switcher's
  # fields come over from the scope being replaced. Rebuilding without them
  # emptied the header's account list after every role or permission change
  # until the next full page load.
  defp carry_multi_session_fields(%Scope{} = scope, %Scope{} = previous) do
    %{
      scope
      | multi_session_accounts: previous.multi_session_accounts,
        multi_session_allowed?: previous.multi_session_allowed?
    }
  end

  defp carry_multi_session_fields(scope, _previous), do: scope

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
    user = conn.assigns[:phoenix_kit_current_user]

    if is_nil(user) do
      conn
      |> put_flash(:error, gettext("You must log in to access this page."))
      |> maybe_store_return_to()
      |> redirect(to: Routes.path("/users/log-in"))
      |> halt()
    else
      case account_gate(user) do
        :ok ->
          conn

        {:halt, kind, message, target} ->
          conn
          |> put_flash(kind, message)
          |> maybe_store_return_to()
          |> redirect(to: Routes.path(target))
          |> halt()
      end
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
        if Scope.authenticated?(scope) do
          case enforce_account_gate(conn, scope) do
            {:halt, conn} -> conn
            :cont -> conn
          end
        else
          conn
          |> put_flash(:error, gettext("You must log in to access this page."))
          |> maybe_store_return_to()
          |> redirect(to: Routes.path("/users/log-in"))
          |> halt()
        end

      _ ->
        # Scope not found, try to create it from current_user
        conn
        |> fetch_phoenix_kit_current_scope([])
        |> require_authenticated_scope([])
    end
  end

  defp email_confirmed?(%Scope{user: user}), do: email_confirmed?(user)

  defp email_confirmed?(%{confirmed_at: confirmed_at}) when not is_nil(confirmed_at), do: true

  defp email_confirmed?(_), do: false

  # Everything an already-authenticated account must satisfy before it may use
  # the application, in the order the user should be walked through them. This
  # is the single definition behind all five `on_mount` hooks and all four
  # role/permission plugs — a gate added here is enforced everywhere at once,
  # which is how the invite-only gate reached eleven call sites without eleven
  # copies of the rule.
  #
  # Returns `:ok`, or `{:halt, flash_kind, flash_message, path}` where `path`
  # is the page that will unblock the user. Callers turn that into a conn or
  # socket redirect and are responsible for carrying `return_to`.
  #
  # Both halts are `:warning`, not `:error`: the account is fine and the user
  # is being asked to do one routine thing ("check your inbox", "enter your
  # code"). Error styling made a first visit to the app look like a failure
  # (reported from topp.ee).
  defp account_gate(subject) do
    cond do
      not email_confirmed?(subject) and confirmation_required?() ->
        {:halt, :warning, gettext("Please confirm your email before accessing the application."),
         "/users/confirm"}

      not Referrals.access_satisfied?(subject) ->
        {:halt, :warning, gettext("Enter your referral code to continue."), "/users/referral"}

      true ->
        :ok
    end
  end

  # Whether unconfirmed accounts are blocked from authenticated routes.
  # Host-configurable via the `require_email_confirmation` setting (default
  # true = historical behavior). Confirmation emails still send when off —
  # only enforcement is gated.
  defp confirmation_required? do
    PhoenixKit.Settings.get_boolean_setting("require_email_confirmation", true)
  end

  # Conn side of `account_gate/1`, for the role-based plugs. They check the role
  # but never the account state, and the shipped `:phoenix_kit_admin_only`
  # pipeline runs `require_admin` with NO preceding `require_authenticated_*` —
  # so a host controller route behind it enforced confirmation nowhere, even at
  # the default. Returns `:cont` or an already-halted conn.
  #
  # An anonymous visitor passes straight through: each caller has its own
  # not-logged-in branch, and parking a visitor with no account on a page that
  # asks them to satisfy their account is nonsense.
  defp enforce_account_gate(conn, scope) do
    with true <- Scope.authenticated?(scope),
         {:halt, kind, message, target} <- account_gate(scope) do
      {:halt,
       conn
       |> put_flash(kind, message)
       |> maybe_store_return_to()
       |> redirect(to: Routes.path(target))
       |> halt()}
    else
      _ -> :cont
    end
  end

  @doc """
  Used for routes that require the user to be an owner.

  If you want to enforce the owner requirement without
  redirecting to the login page, consider using
  `:phoenix_kit_require_authenticated_scope` instead.
  """
  def require_owner(conn, _opts) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope ->
        case enforce_account_gate(conn, scope) do
          {:halt, conn} ->
            conn

          :cont ->
            if Scope.owner?(scope) do
              conn
            else
              conn
              |> put_flash(:error, gettext("You must be an owner to access this page."))
              |> redirect(to: Routes.safe_destination(conn, scope: scope))
              |> halt()
            end
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
        case enforce_account_gate(conn, scope) do
          {:halt, conn} ->
            conn

          :cont ->
            cond do
              Scope.can_access_admin_area?(scope) ->
                conn

              Scope.authenticated?(scope) ->
                conn
                |> put_flash(
                  :error,
                  gettext("You do not have the required permission to access this page.")
                )
                |> redirect(to: Routes.safe_destination(conn, scope: scope, skip_admin: true))
                |> halt()

              true ->
                conn
                |> put_flash(:error, gettext("You must log in to access this page."))
                |> redirect(to: Routes.path("/users/log-in"))
                |> halt()
            end
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
        case enforce_account_gate(conn, scope) do
          {:halt, conn} ->
            conn

          :cont ->
            cond do
              not Scope.can_access_admin_area?(scope) ->
                conn
                |> put_flash(
                  :error,
                  gettext("You do not have the required permission to access this page.")
                )
                |> redirect(to: Routes.safe_destination(conn, scope: scope, skip_admin: true))
                |> halt()

              # Disabled modules are blocked for everyone (Owner included), matching
              # the LiveView mount and plug gates.
              Scope.has_module_access?(scope, module_key) and
                  MapSet.member?(Permissions.enabled_module_keys(), module_key) ->
                conn

              true ->
                conn
                |> put_flash(
                  :error,
                  gettext("You do not have permission to access this section.")
                )
                |> redirect(to: best_available_admin_path(conn, scope))
                |> halt()
            end
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
        case enforce_account_gate(conn, scope) do
          {:halt, conn} ->
            conn

          :cont ->
            if Scope.has_role?(scope, role_name) do
              conn
            else
              conn
              |> put_flash(
                :error,
                gettext("You must have the %{role_name} role to access this page.",
                  role_name: role_name
                )
              )
              |> redirect(to: Routes.safe_destination(conn, scope: scope))
              |> halt()
            end
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
    |> put_session(:live_socket_id, Sessions.live_socket_id(token))
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
  defp login_path_with_return_to(socket) do
    path_with_return_to(socket, "/users/log-in")
  end

  # The self-loop check trims trailing slashes on both sides so
  # `/users/log-in` and `/users/log-in/` are treated as the same path —
  # without the trim, a hand-typed trailing-slash URL would round-trip
  # back to itself via `?return_to=`.
  defp path_with_return_to(socket, target) do
    target_path = Routes.path(target)
    target_path_canonical = String.trim_trailing(target_path, "/")

    case Phoenix.LiveView.get_connect_info(socket, :uri) do
      %URI{path: path} = uri when is_binary(path) ->
        if String.trim_trailing(path, "/") == target_path_canonical do
          target_path
        else
          # `""` is truthy in Elixir, so a plain `if uri.query` turned a
          # query-less-but-present query string into a bare `"?"` — and the URI
          # comes from the browser's location, which carries one after a
          # fieldless GET submit or a `push_patch` with no params. Captured
          # once, it round-trips back into the URL and perpetuates itself.
          query = if uri.query in [nil, ""], do: "", else: "?" <> uri.query
          target_path <> "?return_to=" <> URI.encode_www_form(path <> query)
        end

      _ ->
        target_path
    end
  end

  # Default post-login destination — the `after_login_path` setting, guarded.
  # An explicit :user_return_to (stashed by the gates above or passed by the
  # login form) is applied by `log_in_user/3` and wins over this default.
  #
  # The conn/socket is forwarded as `:context` so the `"/"` tail of that chain
  # is proven to resolve before anyone is sent to it. This is the return leg of
  # `safe_destination/2`: its anonymous terminal is `/users/log-in`, whose
  # on_mount hooks bounce an authenticated visitor right back through here, so
  # a blind `"/"` here would undo the guarantee one hop later.
  defp signed_in_path(source) do
    Routes.post_auth_path(start_page_candidates(source.assigns[:phoenix_kit_current_user]),
      context: source,
      scope: source_scope(source)
    )
  end

  # The visitor's own "start on this page" preference, offered as the FIRST
  # candidate so it wins over the configured default — and offered as a
  # candidate rather than returned directly, so it inherits every check the
  # chain already applies (local, not an auth page, routable in this host).
  # A preference naming a page that has since been removed simply fails those
  # and the chain carries on to the usual landing, which is why a stale one
  # cannot strand anyone.
  defp start_page_candidates(%User{} = user) do
    case Auth.user_start_page(user) do
      nil -> []
      path -> [Routes.path(path)]
    end
  rescue
    _ -> []
  end

  defp start_page_candidates(_user), do: []

  # `:phoenix_kit_redirect_if_user_is_authenticated` assigns only the user, the
  # scope variants assign a scope, and `redirect_if_user_is_authenticated/2`
  # runs on a conn — all three are handled here rather than at each call site.
  # No catch-all clause: every caller holds a conn or a socket, and a fallback
  # for a shape that cannot arrive is a Dialyzer failure, not a safety net.
  defp source_scope(%{assigns: assigns}) do
    case assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope -> scope
      _ -> Scope.for_user(assigns[:phoenix_kit_current_user])
    end
  end

  @doc """
  Validates and sets the locale for the current request.

  This function is called as a plug in the router to validate locale codes in the URL path.
  It implements PhoenixKit's simplified URL architecture:

  - URLs use base language codes (en, es, fr) for simplicity
  - Full dialect codes (en-US, es-MX) are redirected to base codes (302)
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
      # Redirects 302 to: /en/...

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

          # An ENABLED full dialect ("en-gb"/"en-GB" with en-GB enabled) is a
          # real localized URL — publishing's sibling-dialect URLs (two
          # enabled dialects of one base, the non-primary one addressed by
          # its lowercase full code) depend on this branch. Only exact
          # enabled membership qualifies, matched case-insensitively; every
          # other hyphenated segment keeps the historical redirect to base.
          dialect = enabled_full_dialect(locale) ->
            process_enabled_dialect_locale(conn, dialect)

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
        assign_default_locale(conn)
    end
  end

  # Process request as default locale (for reserved path segments like "admin", "api")
  # When a reserved segment is captured as locale, redirect to remove the locale segment
  # Example: /:locale/dashboard captures /admin with locale="admin"
  # We redirect to /dashboard so the correct route can match
  defp process_as_default_locale(conn) do
    locale = conn.path_params["locale"] || conn.path_params["language"]

    case strip_locale_segment(conn, locale) do
      {:ok, clean_path} ->
        # Set locale before redirecting. URL-driven dialect — no user (see
        # `process_valid_locale/2` for the rationale).
        default_dialect = resolve_active_dialect(Routes.get_default_admin_locale())
        put_gettext_locale(default_dialect)

        # Redirect to clean path so the router matches the correct route.
        #
        # A REAL 307, which the old code only claimed to send: it passed
        # `status: 307` to `Phoenix.Controller.redirect/2`, which sends
        # `conn.status || 302` and ignores an `:status` option entirely.
        # The status has to be set on the conn first.
        #
        # 307 rather than 302 because this pipeline carries the localized
        # non-live auth endpoints — `post "/:locale/users/log-in"` and
        # friends (see `generate_localized_routes/1`). A 302 is replayed
        # by the browser as a GET, so a login POST that happened to land
        # on a reserved segment would arrive at the corrected URL with its
        # body silently dropped. 307 preserves method and body, which is
        # what "you asked for the right resource under a wrong prefix"
        # should mean. Safe to cache-bust freely: unlike a 301 this is
        # explicitly temporary.
        conn
        |> put_status(:temporary_redirect)
        |> Phoenix.Controller.redirect(to: with_query_string(clean_path, conn))
        |> halt()

      :error ->
        # The locale segment could not be located in the path, so there is
        # no cleaner URL to send the user to. Historically this branch
        # redirected to `clean_path` anyway — and because the old strip
        # was prefix-blind (`String.replace_prefix(request_path,
        # "/#{locale}", "")` is a no-op on `/phoenix_kit/admin/shop`), it
        # emitted a redirect straight back to the same URL and the browser
        # spun until it gave up. Never redirect to a path we did not
        # actually change: fall through and let the matched route render
        # under the default locale instead.
        assign_default_locale(conn)
    end
  end

  # Rebuild the request path with the locale segment replaced by
  # `replacement_segments`, preserving both the mount prefix and any
  # enclosing `forward` mount. `replacement_segments` is a list of RAW
  # path segments spliced in where the locale segment was — `[]` strips
  # it entirely, `["en"]` swaps it for a base code.
  #
  # `conn.request_path` includes the PhoenixKit mount prefix
  # ("/phoenix_kit/admin/shop"), while `locale` is the segment that
  # follows it — so the prefix has to be skipped before touching the
  # segment, and re-attached afterwards. Returns `:error` when the path
  # does not have the expected `<prefix>/<locale>/...` shape, so callers
  # can decline to redirect rather than bounce the request at itself.
  #
  # The match is positional: the locale must sit at EXACTLY
  # `length(prefix_segments)` in `path_info`, i.e. the segment
  # immediately after the configured `PhoenixKit.Config.get_url_prefix()`
  # — not merely present somewhere later in the path. A locale scope
  # declared elsewhere in the router (bypassing the configured mount)
  # makes this return `:error`, so callers stop redirecting rather than
  # mismatch a coincidental substring further down the path.
  #
  # Two subtleties, both of which produced wrong URLs when this was first
  # written against `path_info` alone:
  #
  #   * **`script_name`.** `conn.path_info` is router-relative; a router
  #     reached through `Plug.forward` (a `/tenant` mount, say) carries
  #     the mount segments in `conn.script_name` instead. Rebuilding from
  #     `path_info` only would emit `/phoenix_kit/shop` for a request to
  #     `/tenant/phoenix_kit/api/shop` — a redirect straight out of the
  #     mount. The old `request_path`-based code got this right by
  #     accident, so it has to be restored explicitly.
  #
  #   * **percent-encoding.** Phoenix matches routes against a DECODED
  #     copy of the path (`Phoenix.Router.call/2` does
  #     `Enum.map(path_info, &URI.decode/1)` before `__match_route__`),
  #     but leaves `conn.path_info` encoded. So `/phoenix_kit/%61pi/shop`
  #     binds `path_params["locale"] == "api"` while `path_info` still
  #     holds `"%61pi"`, and a raw comparison silently misses. Compare
  #     decoded segments, but emit `rest` — everything after the locale
  #     — RAW, so the redirect target keeps whatever encoding the client
  #     sent there. The prefix portion of the output is the CONFIGURED
  #     `prefix_segments`, not a raw slice of the input — an encoded
  #     mount-prefix segment comes out normalized to its canonical form,
  #     which is what keeps the target canonical and unable to loop.
  #
  #   * **the fully-built path is checked before it's returned.** Neither
  #     `replacement_segments` (guarded by `safe_path_segment?/1`, but
  #     defense in depth is cheap) nor `rest` (raw CLIENT input, never
  #     validated anywhere else — it is deliberately spliced in
  #     unmodified, see above) is proof against reproducing a literal
  #     substring `Phoenix.Controller.redirect/2` itself refuses, e.g.
  #     the decoded text `"%09"` sitting next to a `/` in the joined
  #     path. `unsafe_redirect_target?/1` mirrors that downstream check
  #     exactly and runs here first, so a shape it would reject becomes
  #     an ordinary `:error` decline (callers already fall back to
  #     `assign_default_locale/1`) instead of an unhandled `ArgumentError`
  #     raised later, on an otherwise-anonymous GET.
  defp locale_segment_path(conn, locale, replacement_segments)
       when is_binary(locale) and is_list(replacement_segments) do
    prefix_segments =
      PhoenixKit.Config.get_url_prefix()
      |> to_string()
      |> String.split("/", trim: true)

    prefix_length = length(prefix_segments)
    decoded = Enum.map(conn.path_info, &URI.decode/1)

    with true <- Enum.all?(replacement_segments, &safe_path_segment?/1),
         {^prefix_segments, [^locale | _]} <- Enum.split(decoded, prefix_length),
         {_prefix, [_locale | rest]} <- Enum.split(conn.path_info, prefix_length),
         path = conn.script_name ++ prefix_segments ++ replacement_segments ++ rest,
         joined = "/" <> Enum.join(path, "/"),
         false <- unsafe_redirect_target?(joined) do
      {:ok, joined}
    else
      _ ->
        Logger.debug(
          "[PhoenixKit Locale] declined to build a locale redirect target for #{conn.request_path}"
        )

        :error
    end
  end

  defp locale_segment_path(_conn, _locale, _replacement_segments), do: :error

  # A replacement segment is always something THIS module computed — never
  # raw client `rest` (see the safety check on the fully-joined path in
  # `locale_segment_path/3`, which covers that case instead).
  # `redirect_to_base_locale/2`'s base_code is `DialectMapper.extract_base/1`
  # of the attacker-controlled, decoded locale segment `process_locale/1`
  # hands it, with no other validation between them (any decoded segment
  # containing a hyphen reaches it). A blocklist of specific dangerous
  # characters is how this guard previously missed a segment that is only
  # DANGEROUS-LOOKING TEXT rather than a dangerous byte — "%09" is three
  # harmless printable ASCII characters on its own, but spliced in next to a
  # path separator it reproduces the literal substring
  # `Phoenix.Controller.redirect/2` itself refuses to emit (see
  # `unsafe_redirect_target?/1` below). An allowlist sidesteps that class of
  # miss entirely: a real locale/base code only ever needs letters, digits,
  # underscore, hyphen — anything else (`%09`, `?`, `#`, a space, raw UTF-8
  # bytes, `.`/`..`, or empty) is rejected outright. An unrecognized locale
  # doesn't need a cleverly-encoded redirect target; declining and rendering
  # under the default locale (`assign_default_locale/1`) is already correct.
  defp safe_path_segment?(segment), do: segment =~ ~r/\A[a-zA-Z0-9_-]+\z/

  # Strip the mis-captured locale segment entirely — see
  # `locale_segment_path/3` for the mount-prefix and percent-encoding
  # subtleties this delegates to.
  defp strip_locale_segment(conn, locale), do: locale_segment_path(conn, locale, [])

  # Characters Phoenix.Controller.redirect/2 refuses in a local target
  # (deps/phoenix/lib/phoenix/url.ex — the list is private to Phoenix,
  # `@moduledoc false`, so it's mirrored here rather than called directly).
  # A leading "//" is rejected separately (classify_local_path/1's first
  # clause, see `unsafe_redirect_target?/1` below); this list is the second,
  # substring-anywhere clause.
  @unsafe_redirect_chars ["\\", "/%09", "/\t", "\n", "\r"]

  # Would Phoenix.Controller.redirect/2 accept `path` as a `:to` target, or
  # raise? Mirrors Phoenix.URL.classify_local_path/1's own two checks exactly,
  # so this always agrees with what the real call downstream would do — run
  # BEFORE that call, so a shape it would reject becomes an ordinary
  # decline-and-render (see `assign_default_locale/1`) instead of an unhandled
  # exception on an anonymous GET. Catches both a hostile `replacement_segments`
  # entry that slipped past `safe_path_segment?/1` (defense in depth — it
  # shouldn't, given the allowlist above) AND raw client-supplied `rest`
  # content, which is never otherwise validated: `/zz/%09evil/x` reaches here
  # with the literal text "%09evil" sitting in `rest`, untouched by
  # `safe_path_segment?/1` entirely since that only ever looks at
  # `replacement_segments`.
  #
  # A THIRD check, beyond what Phoenix itself validates: a dot-segment
  # (`.`/`..`) anywhere in `path` — never rejected by Phoenix (dot-segments
  # are syntactically ordinary path characters, not on its char list), but a
  # browser resolves them per RFC 3986 §5.2.4 before navigating, so
  # `/phoenix_kit/zz/../../shop` (an entirely ordinary invalid-locale
  # request — `rest` is client content, not something this module
  # constructs) silently escapes the mount prefix client-side. Also rejects
  # a segment that only SPELLS `.`/`..` as literal percent-encoded text
  # (`%2E`/`%2e`, for one dot or both — a browser's URL parser treats
  # those as dot-segments too) — the same "decoded text reproduces a
  # dangerous form one decode pass later" class as the `%09` bug this module
  # already guards against, just for dot-segments instead of control
  # characters: decode each segment one more time and check the result too,
  # not just its raw form. Exactly one extra pass: a double-encoded `%252E`
  # is not a dot-segment to a browser, so it is left alone.
  defp unsafe_redirect_target?(path) do
    String.starts_with?(path, "//") or
      String.contains?(path, @unsafe_redirect_chars) or
      path |> String.split("/") |> Enum.any?(&dot_segment?/1)
  end

  defp dot_segment?(segment) do
    segment in [".", ".."] or decode_or_self(segment) in [".", ".."]
  end

  defp decode_or_self(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  # Carry the query string across a locale redirect.
  #
  # Every locale redirect in this module rebuilds a PATH — `request_path`
  # and `path_info` both stop at the "?" — so the query was dropped on the
  # floor, and `redirect_to_base_locale/2` documented the opposite ("Query
  # parameters preserved", with a `?page=2` example that never worked).
  # On this surface that is not cosmetic: `Routes.return_to_query/1`
  # threads `return_to` through exactly these URLs, so a visitor arriving
  # at `/<prefix>/en-US/users/log-in?return_to=/admin/x` lost their
  # destination and landed on the post-login default instead.
  #
  # Drop the query rather than raise when it contains something
  # `redirect/2` rejects: a client can send a raw backslash in a query
  # value, and a 500 would be worse than the truncation we ship today.
  defp with_query_string(path, conn) do
    case conn.query_string do
      "" ->
        path

      query ->
        candidate = path <> "?" <> query
        if String.contains?(candidate, @unsafe_redirect_chars), do: path, else: candidate
    end
  end

  defp locale_allowed?(base_code) do
    language_enabled?(base_code)
  end

  # The stored-case enabled code for a hyphenated URL segment ("en-gb" →
  # "en-GB"), nil when the segment isn't an enabled dialect. An empty
  # enabled list means the Languages module is effectively off — fall
  # through to the historical hyphen→base redirect rather than accepting
  # arbitrary dialects.
  defp enabled_full_dialect(locale) do
    if String.contains?(locale, "-") do
      down = String.downcase(locale)

      Enum.find_value(Languages.get_enabled_languages(), fn lang ->
        if String.downcase(lang.code) == down, do: lang.code
      end)
    end
  end

  # Mirrors the else-branch of process_valid_locale/2 for an exact enabled
  # dialect: the URL already names the full dialect, so there is nothing to
  # resolve — set Gettext and expose base + full on the conn. The
  # prefixless-primary redirect never applies here: only non-primary
  # siblings are addressed by full-code URLs (the primary's URLs stay
  # base-coded), so a dialect segment is never the default locale.
  defp process_enabled_dialect_locale(conn, dialect) do
    put_gettext_locale(dialect)

    conn
    |> assign(:current_locale_base, DialectMapper.extract_base(dialect))
    |> assign(:current_locale, dialect)
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
      full_dialect = resolve_active_dialect(locale)

      put_gettext_locale(full_dialect)

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
  # Whether this request targets the admin area.
  #
  # Matches "admin" as a whole PATH SEGMENT, not as a substring. The old
  # `String.contains?(request_path, "/admin")` classified any URL with
  # those characters anywhere in it — a storefront product at
  # `/shop/product/admin-tools`, a blog post at `/news/admin-changes` — as
  # an admin request, which then skipped default-locale canonicalisation
  # for those pages.
  #
  # Segment-wise matching also means a genuine admin URL still matches
  # under any mount prefix and any locale segment, since we only care
  # whether "admin" appears as its own segment.
  #
  # Decoded, for the reason spelled out on `locale_segment_path/3`:
  # Phoenix binds routes against a decoded copy of the path but leaves
  # `conn.path_info` encoded, so `/<prefix>/en/%61dmin/users` reaches the
  # admin route while a raw comparison reports "not admin" and hands the
  # request to the default-locale canonicaliser.
  defp admin_request?(conn) do
    Enum.any?(conn.path_info, &(URI.decode(&1) == "admin"))
  end

  # Redirects default language URLs to clean URLs (no locale prefix)
  # Example: /phoenix_kit/en/dashboard → /phoenix_kit/dashboard
  #
  # This sends a 302, NOT the 301 the code used to ask for. Two reasons,
  # and they point the same way:
  #
  #   1. It never was a 301. `Phoenix.Controller.redirect/2` sends
  #      `conn.status || 302` and ignores an `:status` option entirely,
  #      so the `status: 301` that used to sit on this call was dead.
  #   2. A real 301 here would be a bug. Which language is "default" is a
  #      runtime setting an admin can change; browsers and crawlers cache
  #      301s ~forever, so flipping the default from en to et would leave
  #      clients permanently redirecting `/en/...` away from a locale that
  #      had become a legitimate URL. The accidental 302 was the correct
  #      behaviour all along.
  #
  # If canonicalisation for SEO is wanted, express it with a
  # `<link rel="canonical">` — not with a cached permanent redirect.
  defp redirect_default_locale_to_clean_url(conn, locale) do
    case locale_segment_path(conn, locale, []) do
      {:ok, clean_path} when clean_path != conn.request_path ->
        conn
        |> Phoenix.Controller.redirect(to: with_query_string(clean_path, conn))
        |> halt()

      _ ->
        # The locale segment could not be located in the path (or removing
        # it would not have changed anything, e.g. it only matched because
        # of stale percent-encoding). Never redirect to an unchanged path —
        # see `assign_default_locale/1`.
        assign_default_locale(conn)
    end
  end

  # Assign the default locale onto the conn without redirecting. Used by the
  # locale redirect functions when the "corrected" path would be identical
  # to (or no cleaner than) the one just requested — redirecting there would
  # bounce the browser back to itself and loop forever.
  defp assign_default_locale(conn) do
    default_base = Routes.get_default_admin_locale()
    default_dialect = resolve_active_dialect(default_base)

    put_gettext_locale(default_dialect)

    conn
    |> assign(:current_locale_base, default_base)
    |> assign(:current_locale, default_dialect)
  end

  # Assign a specific base locale onto the conn without redirecting.
  # Mirrors `assign_default_locale/1`, but for a caller that has a more
  # specific base than the site default to fall back to — currently only
  # `redirect_to_base_locale/2`'s decline branch, falling back to the
  # requested dialect's base rather than losing the requested language
  # entirely. Callers must have already checked that `base_code` is a
  # predefined, enabled base: this assigns it verbatim to
  # `current_locale_base`, which downstream code (Gettext, link-builders)
  # reads back.
  defp assign_resolved_base_locale(conn, base_code) do
    full_dialect = resolve_active_dialect(base_code)

    put_gettext_locale(full_dialect)

    conn
    |> assign(:current_locale_base, base_code)
    |> assign(:current_locale, full_dialect)
  end

  @doc """
  Redirects full dialect code URLs to base language URLs.

  This function handles backward compatibility by redirecting old URLs with
  full dialect codes (en-US, es-MX) to the new simplified base code URLs (en, es).

  Sends a **302**. The docs here used to promise a 301, and the call passed
  `status: 301` — but `Phoenix.Controller.redirect/2` sends
  `conn.status || 302` and ignores an `:status` option, so no 301 was ever
  emitted. The option has been removed rather than made real: a cached
  permanent redirect off a dialect code is hard to walk back if the
  dialect set changes, and nothing here needs permanence. Use
  `put_status(:moved_permanently)` before `redirect/2` if that ever changes.

  ## Examples

      iex> redirect_to_base_locale(conn, "en-US")
      # /phoenix_kit/en-US/admin → /phoenix_kit/en/admin

      iex> redirect_to_base_locale(conn, "es-MX")
      # /phoenix_kit/es-MX/users?page=2 → /phoenix_kit/es/users?page=2

  ## Preservation

  - Query parameters preserved (via `with_query_string/2` — they were not,
    before: this rebuilds a path, and `conn.request_path` stops at the "?")
  - Request method unchanged (GET → GET)
  - Full path structure maintained

  URL fragments are NOT preserved, and cannot be: a fragment never leaves
  the browser, so the server has nothing to copy. The client re-applies
  its own fragment to the `Location` it follows.

  ## When it does not redirect

  If the dialect segment can't be located in the path, replacing it would
  leave the path unchanged (e.g. stale percent-encoding), or the resulting
  target would be unsafe to hand to `Phoenix.Controller.redirect/2` (an
  unsafe character, a leading `//`, or a `.`/`..` path segment anywhere in
  it — see `unsafe_redirect_target?/1`), this does NOT redirect — that
  would just bounce the browser back to the URL it already requested, crash
  on an unsafe target, or hand a client-supplied dot-segment to the browser
  to resolve outside the mount. Instead it assigns `base_code` as the
  active locale onto the conn and lets the request continue un-halted,
  so `/fr-CA/page` still renders in French even when no redirect could
  be built — mirroring the non-redirecting else-branch of
  `process_valid_locale/2`. That only applies to a `base_code` that is a
  predefined, enabled language (the gate a bare `/fr/page` has to pass);
  any other base — unknown, disabled, or not even a safe path segment —
  falls back to the full site default via `assign_default_locale/1`.

  ## Notes

  - Halts conn pipeline when it redirects (no further processing);
    otherwise the conn continues un-halted — see "When it does not
    redirect" above
  - Logged for monitoring migration patterns, only when it redirects
  """
  def redirect_to_base_locale(conn, full_dialect) do
    base_code = DialectMapper.extract_base(full_dialect)

    case locale_segment_path(conn, full_dialect, [base_code]) do
      {:ok, corrected_path} when corrected_path != conn.request_path ->
        # Log redirect for monitoring (helps track migration patterns)
        Logger.info("""
        [PhoenixKit Locale] Redirecting full dialect URL to base code
        - Full dialect: #{full_dialect}
        - Base code: #{base_code}
        - Original path: #{conn.request_path}
        - Corrected path: #{corrected_path}
        """)

        conn
        |> Phoenix.Controller.redirect(to: with_query_string(corrected_path, conn))
        |> halt()

      _ ->
        # See `assign_default_locale/1` — never redirect to an unchanged path.
        # Prefer the requested base locale over the site default (see
        # moduledoc "When it does not redirect"), but only when `base_code`
        # would have been accepted had it arrived as a bare base segment:
        # a predefined AND enabled language — the same gate
        # `process_locale/1` puts in front of `process_valid_locale/2`.
        # Path-safety alone is not enough: `"zz-QQ"` (unknown) or `"fr-CA"`
        # with French disabled would otherwise render under a locale the
        # plain `/zz/...` / `/fr/...` URL is redirected away from.
        if DialectMapper.valid_base_code?(base_code) and locale_allowed?(base_code) do
          assign_resolved_base_locale(conn, base_code)
        else
          assign_default_locale(conn)
        end
    end
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

  ## When it does not redirect

  If the invalid locale segment can't be located in the path, the
  replacement above would leave the path unchanged (e.g. stale
  percent-encoding, or an "invalid" locale that already equals the
  replacement), or the resulting target would be unsafe to hand to
  `Phoenix.Controller.redirect/2` (an unsafe character, a leading `//`, or
  a `.`/`..` path segment anywhere in it — see `unsafe_redirect_target?/1`),
  this does NOT redirect — that would just bounce the browser back to the
  URL it already requested, crash on an unsafe target, or hand a
  client-supplied dot-segment to the browser to resolve outside the mount.
  Instead it assigns the default locale onto the conn and lets the request
  continue un-halted, the same fallback `process_as_default_locale/1` takes
  on its own `:error` branch.
  """
  def redirect_invalid_locale(conn, invalid_locale) do
    # Get the default language
    default_base = Routes.get_default_admin_locale()

    # Single read of the setting — the replacement always follows it
    # (prefixless ↔ prefixed), so evaluating the flag twice would just
    # risk a torn read if a concurrent setting flip landed in between.
    replacement = if prefixless_primary?(), do: [], else: [default_base]

    case locale_segment_path(conn, invalid_locale, replacement) do
      {:ok, corrected_path} when corrected_path != conn.request_path ->
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
        |> Phoenix.Controller.redirect(to: with_query_string(corrected_path, conn))
        |> halt()

      _ ->
        # See `assign_default_locale/1` — never redirect to an unchanged path.
        assign_default_locale(conn)
    end
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

  # One implementation, in the session context, so the endpoint a disconnect is
  # broadcast on is resolved the same way everywhere.
  defp broadcast_disconnect(live_socket_id), do: Sessions.disconnect(live_socket_id)
end
