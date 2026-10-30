defmodule PhoenixKitWeb.Users.Session do
  @moduledoc """
  Controller for handling user session management.

  This controller manages user login and logout operations, including:
  - Creating new sessions via email/password authentication
  - Handling post-registration and password update flows
  - Session termination (logout)
  - GET-based logout for direct URL access

  ## Security Features

  - Prevents user enumeration by not disclosing whether an email is registered
  - Supports remember me functionality via UserAuth module
  - Session renewal on login/logout to prevent fixation attacks
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.LoginAttempts
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth
  alias PhoenixKitWeb.Users.MultiSession

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, gettext("Account created successfully!"), :registered)
  end

  def create(conn, %{"_action" => "password_updated"} = params) do
    previous_token = get_session(conn, :user_token)

    conn
    |> create(
      carry_remember_me(conn, params),
      gettext("Password updated successfully!"),
      :password_updated
    )
    |> disconnect_previous_session(previous_token)
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"), :login)
  end

  # The destination is stashed only once the credentials check out. Doing it up
  # front leaked it into the failure branches, so a rejected registration
  # handoff left `after_registration_path` in the session and the user's NEXT
  # ordinary login landed on the registration page.
  # The password change deleted every token but spared THIS browser's from
  # the disconnect broadcast so the re-login above could go out. Now that a
  # new token is in the session, the old one is closed too — after a delay,
  # so the page load the POST triggers is never raced — which also drops any
  # other socket riding a stolen copy of that same cookie.
  defp disconnect_previous_session(conn, previous_token) when is_binary(previous_token) do
    case get_session(conn, :user_token) do
      new_token when is_binary(new_token) and new_token != previous_token ->
        Sessions.disconnect_tokens_later([previous_token])
        conn

      _ ->
        conn
    end
  end

  defp disconnect_previous_session(conn, _previous_token), do: conn

  defp stash_destination(conn, :registered), do: maybe_store_after_registration_path(conn)

  defp stash_destination(conn, :password_updated),
    do: put_session(conn, :user_return_to, Routes.user_settings_path())

  defp stash_destination(conn, _), do: conn

  defp create(conn, %{"user" => user_params}, info, action) do
    %{"password" => password} = user_params
    # Support both old "email" field and new "email_or_username" field for backwards compatibility
    email_or_username = user_params["email_or_username"] || user_params["email"]
    ip_address = IpAddress.extract_from_conn(conn)

    case Auth.get_user_by_email_or_username_and_password(email_or_username, password, ip_address) do
      {:ok, %Auth.User{is_active: false} = user} ->
        # Valid credentials but account is inactive. The most interesting of
        # the three outcomes to record: somebody has the password.
        LoginAttempts.record(conn, email_or_username, "inactive", user: user)

        conn
        |> put_flash(
          :error,
          gettext(
            "Your account is currently inactive. Please contact the team if you believe this is an error."
          )
        )
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:ok, user} ->
        # Valid credentials and active account
        conn
        |> stash_destination(action)
        |> maybe_store_return_to_from_params(user_params)
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      {:error, :rate_limit_exceeded} ->
        # Rate limit exceeded - show specific error message
        LoginAttempts.record(conn, email_or_username, "rate_limited")

        conn
        |> put_flash(:error, gettext("Too many login attempts. Please try again later."))
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:error, :invalid_credentials} ->
        # Invalid credentials (wrong email/username or password)
        # In order to prevent user enumeration attacks, don't disclose whether the email/username is registered.
        # `record/4` does the same work on both branches for the same reason.
        LoginAttempts.record(conn, email_or_username, "invalid_credentials")

        conn
        |> put_flash(:error, gettext("Invalid email/username or password"))
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))
    end
  end

  # Logout: "all" drains the whole stack; otherwise log out the active account only
  # (falling back to root) unless root is active, in which case full logout runs.
  def delete(conn, %{"all" => _} = _params) do
    # log_out_user/1 drains the whole multi-session stack, so this is now just a
    # relabelled full logout (kept distinct for the clearer flash message).
    conn
    |> put_flash(:info, gettext("Logged out of all accounts."))
    |> UserAuth.log_out_user()
  end

  def delete(conn, _params) do
    if MultiSession.acting?(get_session(conn)) do
      conn |> put_flash(:info, gettext("Logged out successfully.")) |> UserAuth.log_out_user()
    else
      delete_active_account(conn)
    end
  end

  defp delete_active_account(conn) do
    case MultiSession.log_out_active(conn) do
      {:switched, conn, user} ->
        conn
        # The subject here is the ROOT account that just became active — not
        # `conn.assigns[:phoenix_kit_current_user]`, which still describes the
        # account that was logged out.
        |> put_flash(:info, gettext("Logged out. Now signed in as %{email}.", email: user.email))
        |> redirect(to: Routes.safe_destination(conn, scope: Scope.for_user(user)))

      {:full, conn} ->
        # Root account is active → full logout. log_out_user/1 drains the whole
        # stack (after resolving the user for the disconnect broadcast).
        conn
        |> put_flash(:info, gettext("Logged out successfully."))
        |> UserAuth.log_out_user()
    end
  end

  # --- multi-session helpers ---

  def enter_organization(conn, %{"uuid" => uuid}) do
    case MultiSession.act_as_organization(conn, uuid) do
      {:ok, conn, user} ->
        conn
        |> put_flash(
          :info,
          gettext("You are now acting as %{organization}.",
            organization: Auth.User.display_name(user)
          )
        )
        |> redirect(to: Routes.post_auth_path())

      {:error, :rate_limit_exceeded} ->
        conn
        |> put_flash(:error, gettext("Too many organization switches. Please try again later."))
        |> redirect_back(%{})

      {:error, _} ->
        conn
        |> put_flash(:error, gettext("Could not enter that organization."))
        |> redirect_back(%{})
    end
  end

  def leave_organization(conn, params) do
    case MultiSession.leave_organization(conn) do
      {:ok, conn, user} ->
        conn
        |> put_flash(:info, gettext("You are back in your own account."))
        |> redirect(
          to:
            Routes.safe_destination(conn,
              scope: Scope.for_user(user),
              return_to: params["return_to"]
            )
        )

      {:error, _} ->
        UserAuth.log_out_user(conn)
    end
  end

  defp with_gate(conn, _params, fun) do
    if MultiSession.gate_allowed?(get_session(conn)) do
      fun.(conn)
    else
      # Feature is off (or no valid root) — send the user home with a flash. A bare
      # redirect (302) lets the flash render; a 403 would swallow it (the browser
      # never follows the Location header on a non-3xx response).
      conn
      |> put_flash(:error, gettext("Multi-account switching is not available."))
      |> redirect(to: Routes.safe_destination(conn, scope: conn_scope(conn)))
    end
  end

  defp redirect_back(conn, params) do
    redirect(conn,
      to: Routes.safe_destination(conn, scope: conn_scope(conn), return_to: params["return_to"])
    )
  end

  # Read from the SESSION, never from assigns. Every `redirect_back/2` caller
  # runs AFTER MultiSession has already swapped the active account —
  # `add_account/3`, `switch_to/2` and `impersonate/2` all activate the new
  # token, and `remove_account/2` falls back to root — while
  # `conn.assigns[:phoenix_kit_current_user]` still describes whoever the
  # pipeline saw on the way in. Building the scope from assigns would resolve
  # "sign in as this user" against the *administrator's* roles and send the
  # now-impersonated plain user to `/admin`, which then denies them.
  #
  # `with_gate/3` refuses before any mutation, so the same read is correct there.
  defp conn_scope(conn), do: conn |> session_user() |> Scope.for_user()

  defp session_user(conn) do
    conn
    |> get_session(:user_token)
    |> case do
      token when is_binary(token) -> Auth.get_user_by_session_token(token)
      _ -> nil
    end
    # A deactivated account must never produce a non-anonymous scope, wherever
    # the scope is read. `with_gate/3` already refuses before any mutation here,
    # so this is defence in depth rather than the control — but the filter
    # belongs on every token resolution, not only the ones currently load-bearing.
    |> Auth.ensure_active_user()
  end

  @doc """
  Switches the role the ACTIVE session acts as (`PhoenixKit.Users.ActiveRole`).

  A plain form PUT, like the account switcher: the switcher renders in the
  layout, where a `phx-click` would land in whichever LiveView the page
  mounted. See `redirect_after_role_switch/2` for where it lands.

  The role is stored on the session token, so this changes only the browser
  session making the request: another device, another multi-session account,
  and the borrowed account's own sessions while impersonating are untouched.
  """
  def set_active_role(conn, %{"role_uuid" => role_uuid} = params) when is_binary(role_uuid) do
    case session_user(conn) do
      nil ->
        conn
        |> put_flash(:error, gettext("You must log in to access this page."))
        |> redirect(to: Routes.path("/users/log-in"))

      user ->
        case ActiveRole.switch(user, get_session(conn, :user_token), role_uuid) do
          {:ok, role} ->
            conn
            |> put_flash(:info, gettext("You are now acting as %{role}.", role: role.name))
            |> redirect_after_role_switch(params)

          {:error, _reason} ->
            conn
            |> put_flash(:error, gettext("Could not switch to that role."))
            |> redirect_back(params)
        end
    end
  end

  def set_active_role(conn, params) do
    conn
    |> put_flash(:error, gettext("Could not switch to that role."))
    |> redirect_back(params)
  end

  # The scope is read from the session AFTER the switch, so it is the new
  # role's. `return_to` is followed only when that scope can actually mount
  # it — every role judged the same way, through the router and the same gate
  # the mount runs (`reachable_return_to?/3`) — otherwise the chain falls
  # through to the first page the new role can reach. Without this, switching
  # from an admin page to a role without that page's permission would follow
  # `return_to` straight into the mount gate and its "no longer have
  # permission" bounce.
  defp redirect_after_role_switch(conn, params) do
    scope = conn_scope(conn)
    return_to = params["return_to"]

    redirect(conn,
      to:
        Routes.safe_destination(conn,
          scope: scope,
          return_to: if(reachable_return_to?(conn, scope, return_to), do: return_to)
        )
    )
  end

  # Admin-area paths are resolved to their LiveView and asked the mount gate's
  # own question (`UserAuth.admin_gate_decision/2` + `can_access_admin_view?/2`);
  # an admin-area path that does not resolve to a LiveView is judged by
  # admin-area access alone. Everything else is left to `safe_destination/2`,
  # which already proves it local and routable — host pages gate themselves.
  defp reachable_return_to?(conn, scope, path) when is_binary(path) do
    if Routes.admin_area_path?(path) do
      case admin_view_for(conn, path) do
        {:ok, view, action} ->
          case UserAuth.admin_gate_decision(scope, view) do
            :landing -> true
            :enforce_view -> UserAuth.can_access_admin_view?(scope, view, action)
            :deny -> false
          end

        :error ->
          Scope.can_access_admin_area?(scope)
      end
    else
      true
    end
  end

  defp reachable_return_to?(_conn, _scope, _path), do: false

  defp admin_view_for(conn, path) do
    path_only = path |> String.split(["?", "#"], parts: 2) |> hd()

    # The action travels with the view: admin-tab permissions are keyed by
    # `{module, live_action}`, so a module-only lookup would miss every tab
    # registered with an action and fail closed for a partial role.
    case Phoenix.Router.route_info(conn.private.phoenix_router, "GET", path_only, conn.host) do
      %{phoenix_live_view: {view, action, _opts, _meta}} when is_atom(view) -> {:ok, view, action}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Changing a password deletes every token for the user, the one inside the
  # live remember-me cookie included, and the dashboard form that re-logs them
  # in carries no checkbox. Without this the user keeps a cookie pointing at a
  # deleted token: fine until the browser drops its session cookie, then a
  # silent sign-out — the exact failure this module's remember-me work exists
  # to prevent. Re-authenticating as themselves, so carrying their existing
  # choice forward is right; an absent cookie stays absent.
  defp carry_remember_me(conn, %{"user" => user_params} = params) do
    if UserAuth.remembered?(conn) do
      %{params | "user" => Map.put(user_params, "remember_me", "true")}
    else
      params
    end
  end

  defp carry_remember_me(_conn, params), do: params

  # Configured landing page for freshly registered accounts
  # (`after_registration_path` setting; empty = fall through to the
  # after-login default). An explicit destination always wins over the
  # setting: a return_to already stashed in the session (by an auth gate) is
  # left alone, and a return_to carried by the form overwrites the session
  # key afterwards (maybe_store_return_to_from_params/2 runs later in the
  # shared create/3).
  #
  # Re-guarded on read exactly like `Routes.post_auth_path/2` does for
  # `after_login_path`: trimmed (the changeset trims the CHANGE, but settings
  # are persisted from `changeset.params`, so a stored value can still carry
  # surrounding whitespace), rejected if not local, and rejected if it points
  # at a sign-in page — a hand-edited DB row must not become an open redirect
  # or a login loop.
  defp maybe_store_after_registration_path(conn) do
    path =
      "after_registration_path"
      |> PhoenixKit.Settings.get_setting("")
      |> to_string()
      |> String.trim()

    if path != "" and Routes.local_path?(path) and not Routes.auth_page?(path) and
         is_nil(get_session(conn, :user_return_to)) do
      put_session(conn, :user_return_to, path)
    else
      conn
    end
  end

  # Store return_to from form params (e.g., guest checkout → login → back to checkout)
  defp maybe_store_return_to_from_params(conn, %{"return_to" => return_to})
       when is_binary(return_to) and return_to != "" do
    if Routes.local_path?(return_to) do
      put_session(conn, :user_return_to, return_to)
    else
      conn
    end
  end

  defp maybe_store_return_to_from_params(conn, _params), do: conn

  # Support GET logout for direct URL access. log_out_user/1 drains the whole
  # multi-session stack, so secondary tokens are invalidated here too.
  def get_logout(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end

  def add_account(conn, %{"user" => %{"password" => password} = user_params} = params) do
    email_or_username = user_params["email_or_username"] || user_params["email"]

    with_gate(conn, params, fn conn ->
      case MultiSession.add_account(conn, email_or_username, password) do
        {:ok, conn} ->
          conn |> put_flash(:info, gettext("Account added.")) |> redirect_back(params)

        {:error, :stack_full} ->
          conn
          |> put_flash(:error, gettext("Maximum number of accounts reached."))
          |> redirect_back(params)

        {:error, :already_in_stack} ->
          conn
          |> put_flash(:error, gettext("That account is already in your session."))
          |> redirect_back(params)

        {:error, :acting_organization} ->
          conn
          |> put_flash(
            :error,
            gettext("Return to your own account before adding another account.")
          )
          |> redirect_back(params)

        {:error, reason} ->
          # Same three outcomes as the login form. `:stack_full` and
          # `:already_in_stack` above are not failed sign-ins — the
          # credentials checked out.
          record_failed_sign_in(conn, email_or_username, reason)

          conn
          |> put_flash(:error, gettext("Invalid email/username or password."))
          |> redirect_back(params)
      end
    end)
  end

  # A map rather than function clauses with a catch-all. Dialyzer can prove
  # `MultiSession.add_account/3` returns only these three reasons and so calls
  # a fallback CLAUSE unreachable — but deleting the fallback would mean a
  # fourth reason added later raises FunctionClauseError on the sign-in path,
  # which is the one thing this subsystem must never do. A map lookup keeps the
  # fallback reachable and the guarantee intact.
  @outcome_by_reason %{
    invalid_credentials: "invalid_credentials",
    rate_limit_exceeded: "rate_limited",
    inactive: "inactive"
  }

  defp record_failed_sign_in(conn, identifier, reason) do
    case Map.get(@outcome_by_reason, reason) do
      nil -> :ok
      outcome -> LoginAttempts.record(conn, identifier, outcome)
    end
  end

  def set_active_account(conn, %{"ref" => ref} = params) do
    with_gate(conn, params, fn conn ->
      case MultiSession.switch_to(conn, ref) do
        {:ok, conn, user} ->
          conn
          |> put_flash(:info, gettext("Switched to %{email}.", email: user.email))
          |> redirect_back(params)

        {:error, _reason} ->
          conn |> put_flash(:error, gettext("Could not switch account.")) |> redirect_back(params)
      end
    end)
  end

  @doc """
  Adds a user to the session stack on an administrator's authority — the
  "log in as this user" button in the admin area.

  The authority checks live in `MultiSession.impersonate/2`; this action only
  translates their outcome into a flash. Each refusal says which rule stopped it,
  because "could not do that" on a support tool is how an operator ends up
  guessing at permissions.

  The precise refusals are for operators, so the actor's authority is settled
  BEFORE the uuid is resolved. The other order hands every signed-in user — the
  gate admits all of them, it only asks that the root session be real — a
  distinct "User not found." for an unused uuid and a different message for a
  used one, which is an account-existence oracle wearing a support tool's copy.
  """
  def impersonate(conn, %{"user_uuid" => user_uuid} = params) do
    with_gate(conn, params, fn conn ->
      if MultiSession.may_impersonate?(get_session(conn)) do
        lookup_and_impersonate(conn, user_uuid, params)
      else
        MultiSession.log_impersonation_refusal(conn, user_uuid)

        conn
        |> put_flash(:error, impersonation_error(:not_allowed))
        |> redirect_back(params)
      end
    end)
  end

  defp lookup_and_impersonate(conn, user_uuid, params) do
    case Auth.get_user(user_uuid) do
      nil ->
        conn |> put_flash(:error, gettext("User not found.")) |> redirect_back(params)

      user ->
        do_impersonate(conn, user, params)
    end
  end

  defp do_impersonate(conn, user, params) do
    case MultiSession.impersonate(conn, user) do
      {:ok, conn} ->
        conn
        |> put_flash(:info, gettext("You are now signed in as %{email}.", email: user.email))
        |> redirect_back(params)

      {:error, reason} ->
        conn |> put_flash(:error, impersonation_error(reason)) |> redirect_back(params)
    end
  end

  defp impersonation_error(:not_allowed),
    do: gettext("You do not have permission to sign in as another user.")

  defp impersonation_error(:target_is_owner), do: gettext("An owner account cannot be used.")

  defp impersonation_error(:target_is_staff),
    do: gettext("Only an owner can sign in as another administrator.")

  defp impersonation_error(:self), do: gettext("That is already your account.")

  defp impersonation_error(:acting_organization),
    do: gettext("Return to your own account before signing in as another user.")

  defp impersonation_error(:inactive), do: gettext("That account is deactivated.")

  defp impersonation_error(:stack_full),
    do: gettext("Maximum number of accounts reached — remove one first.")

  defp impersonation_error(:already_in_stack),
    do: gettext("That account is already in your session — switch to it instead.")

  # No catch-all: `MultiSession.impersonate/2`'s spec enumerates the reasons, so
  # Dialyzer proves one unreachable (`pattern_match_cov`) and fails the gate. A
  # new reason has to be given copy here, which is the point — the refusals are
  # for operators, and a generic fallback is how one ends up guessing.

  def remove_account(conn, %{"ref" => ref} = params) do
    with_gate(conn, params, fn conn ->
      case MultiSession.remove_account(conn, ref) do
        {:ok, conn} ->
          conn |> put_flash(:info, gettext("Account removed.")) |> redirect_back(params)

        {:error, :cannot_remove_root} ->
          conn
          |> put_flash(:error, gettext("Cannot remove your primary account."))
          |> redirect_back(params)

        {:error, _reason} ->
          conn
          |> put_flash(:error, gettext("Could not remove account."))
          |> redirect_back(params)
      end
    end)
  end
end
