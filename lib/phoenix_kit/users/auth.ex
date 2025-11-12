defmodule PhoenixKit.Users.Auth do
  @moduledoc """
  The Auth context for user authentication and management.

  This module provides functions for user registration, authentication, password management,
  and email confirmation. It serves as the main interface for all user-related operations
  in PhoenixKit.

  ## Core Functions

  ### User Registration and Authentication

  - `register_user/1` - Register a new user with email and password
  - `get_user_by_email_and_password/2` - Authenticate user credentials
  - `get_user_by_email/1` - Find user by email address

  ### Password Management

  - `change_user_password/2` - Update user password
  - `reset_user_password/2` - Reset password with token
  - `deliver_user_reset_password_instructions/1` - Send password reset email

  ### Email Confirmation

  - `deliver_user_confirmation_instructions/1` - Send confirmation email
  - `confirm_user/1` - Confirm user account with token
  - `update_user_email/2` - Change user email with confirmation

  ### Session Management

  - `generate_user_session_token/1` - Create session token for login
  - `get_user_by_session_token/1` - Get user from session token
  - `delete_user_session_token/1` - Logout user session

  ## Usage Examples

      # Register a new user
      {:ok, user} = PhoenixKit.Users.Auth.register_user(%{
        email: "user@example.com",
        password: "secure_password123"
      })

      # Authenticate user
      case PhoenixKit.Users.Auth.get_user_by_email_and_password(email, password) do
        {:ok, user} -> {:ok, user}
        {:error, :invalid_credentials} -> {:error, :invalid_credentials}
        {:error, :rate_limit_exceeded} -> {:error, :rate_limit_exceeded}
      end

      # Send confirmation email
      PhoenixKit.Users.Auth.deliver_user_confirmation_instructions(user)

  ## Security Features

  - Passwords are hashed using bcrypt
  - Email confirmation prevents unauthorized account creation
  - Session tokens provide secure authentication
  - Password reset tokens expire for security
  - All sensitive operations are logged
  """

  import Ecto.Query, warn: false
  alias PhoenixKit.RepoHelper, as: Repo

  require Logger

  # This module will be populated by mix phx.gen.auth

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Users.Auth.{User, UserNotifier, UserToken}
  alias PhoenixKit.Users.{RateLimiter, Roles}
  alias PhoenixKit.Utils.Geolocation

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  This function includes rate limiting protection to prevent brute-force attacks.
  After exceeding the rate limit (default: 5 attempts per minute), subsequent
  attempts will be rejected with `{:error, :rate_limit_exceeded}`.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      {:ok, %User{}}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      {:error, :invalid_credentials}

      iex> get_user_by_email_and_password("foo@example.com", "password", "192.168.1.1")
      {:ok, %User{}}

  """
  def get_user_by_email_and_password(email, password, ip_address \\ nil)
      when is_binary(email) and is_binary(password) do
    # Check rate limit before attempting authentication
    case RateLimiter.check_login_rate_limit(email, ip_address) do
      :ok ->
        user = Repo.get_by(User, email: email)
        # Return user if password is valid, regardless of is_active status
        # The session controller will handle inactive status check separately
        if User.valid_password?(user, password) do
          # Successful login
          {:ok, user}
        else
          # Invalid credentials - rate limit counter incremented
          {:error, :invalid_credentials}
        end

      {:error, :rate_limit_exceeded} ->
        # Return error immediately without checking credentials
        # This prevents timing attacks and reduces load
        {:error, :rate_limit_exceeded}
    end
  end

  @doc """
  Gets a single user.

  Returns `nil` if the user does not exist.

  ## Examples

      iex> get_user(123)
      %User{}

      iex> get_user(456)
      nil

  """
  def get_user(id) when is_integer(id), do: Repo.get(User, id)

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user with automatic role assignment.

  Role assignment is handled by Elixir application logic:
  - First user receives Owner role
  - Subsequent users receive User role
  - Uses database transactions to prevent race conditions

  This function includes rate limiting protection to prevent spam account creation.
  Rate limits apply per email address and optionally per IP address.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

      iex> register_user(%{email: "user@example.com"}, "192.168.1.1")
      {:ok, %User{}}

  """
  def register_user(attrs, ip_address \\ nil) do
    # Check rate limit before attempting registration
    email = attrs["email"] || attrs[:email] || ""

    case RateLimiter.check_registration_rate_limit(email, ip_address) do
      :ok ->
        do_register_user(attrs)

      {:error, :rate_limit_exceeded} ->
        # Return changeset error for rate limit
        changeset =
          %User{}
          |> User.registration_changeset(attrs)
          |> Ecto.Changeset.add_error(
            :email,
            "Too many registration attempts. Please try again later."
          )

        {:error, changeset}
    end
  end

  defp do_register_user(attrs) do
    case %User{}
         |> User.registration_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        # Safely assign Owner role to first user, User role to others
        case Roles.ensure_first_user_is_owner(user) do
          {:ok, role_type} ->
            # Log successful role assignment for security audit
            Logger.info("PhoenixKit: User #{user.id} (#{user.email}) assigned #{role_type} role")

            # Broadcast user creation event
            Events.broadcast_user_created(user)

            {:ok, user}

          {:error, reason} ->
            # Role assignment failed - this is critical
            Logger.error(
              "PhoenixKit: Failed to assign role to user #{user.id}: #{inspect(reason)}"
            )

            # User was created but role assignment failed
            # In production, you might want to delete the user or mark as needs_role_assignment
            {:ok, user}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Registers a user with IP geolocation data.

  This function attempts to look up geographical location information
  based on the provided IP address and includes it in the user registration.
  If geolocation lookup fails, the user is still registered with just the IP address.

  This function automatically applies rate limiting based on the IP address.

  ## Examples

      iex> register_user_with_geolocation(%{email: "user@example.com", password: "password"}, "192.168.1.1")
      {:ok, %User{registration_ip: "192.168.1.1", registration_country: "United States"}}

      iex> register_user_with_geolocation(%{email: "invalid"}, "192.168.1.1")
      {:error, %Ecto.Changeset{}}
  """
  def register_user_with_geolocation(attrs, ip_address) when is_binary(ip_address) do
    # Start with the IP address
    enhanced_attrs = Map.put(attrs, "registration_ip", ip_address)

    # Attempt geolocation lookup
    case Geolocation.lookup_location(ip_address) do
      {:ok, location} ->
        # Add geolocation data to registration
        enhanced_attrs =
          enhanced_attrs
          |> Map.put("registration_country", location["country"])
          |> Map.put("registration_region", location["region"])
          |> Map.put("registration_city", location["city"])

        Logger.info("PhoenixKit: Successful geolocation lookup for IP #{ip_address}")

        # Pass IP address for rate limiting
        register_user(enhanced_attrs, ip_address)

      {:error, reason} ->
        # Log the error but continue with registration
        Logger.warning("PhoenixKit: Geolocation lookup failed for IP #{ip_address}: #{reason}")

        # Register user with just IP address
        register_user(enhanced_attrs, ip_address)
    end
  end

  def register_user_with_geolocation(attrs, _invalid_ip) do
    # Invalid IP provided, register without geolocation data
    register_user(attrs, nil)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_email: false)
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs, validate_email: false)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context) do
    changeset =
      user
      |> User.email_changeset(%{email: email})
      |> User.confirm_changeset()

    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, changeset)
    Ecto.Multi.delete_all(multi, :tokens, UserToken.by_user_and_contexts_query(user, [context]))
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &PhoenixKit.Utils.Routes.url("/users/settings/confirm_email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user profile.

  ## Examples

      iex> change_user_profile(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_profile(user, attrs \\ %{}) do
    User.profile_changeset(user, attrs, validate_email: false)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, changeset)

    Ecto.Multi.delete_all(multi, :tokens, UserToken.by_user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Updates the user password as an admin (bypasses current password validation).

  ## Examples

      iex> admin_update_user_password(user, %{password: "new_password", password_confirmation: "new_password"})
      {:ok, %User{}}

      iex> admin_update_user_password(user, %{password: "short"})
      {:error, %Ecto.Changeset{}}

  """
  def admin_update_user_password(user, attrs) do
    changeset = User.password_changeset(user, attrs)

    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, changeset)

    Ecto.Multi.delete_all(multi, :tokens, UserToken.by_user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Session

  @doc """
  Generates a session token.

  ## Options

    * `:fingerprint` - Optional session fingerprint map with `:ip_address` and `:user_agent_hash`

  ## Examples

      # Without fingerprinting (backward compatible)
      token = generate_user_session_token(user)

      # With fingerprinting
      fingerprint = PhoenixKit.Utils.SessionFingerprint.create_fingerprint(conn)
      token = generate_user_session_token(user, fingerprint: fingerprint)

  """
  def generate_user_session_token(user, opts \\ []) do
    {token, user_token} = UserToken.build_session_token(user, opts)
    inserted_token = Repo.insert!(user_token)

    # Broadcast session creation event
    token_info = %{
      token_id: inserted_token.id,
      created_at: inserted_token.inserted_at,
      context: inserted_token.context
    }

    Events.broadcast_session_created(user, token_info)

    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  # Define session validity for query
  @session_validity_in_days 60

  @doc """
  Gets the user token record for the given session token.

  This is useful for accessing fingerprint data stored with the token.

  ## Examples

      iex> get_session_token_record("valid_token")
      %UserToken{ip_address: "192.168.1.1", user_agent_hash: "abc123"}

      iex> get_session_token_record("invalid_token")
      nil

  """
  def get_session_token_record(token) do
    import Ecto.Query

    from(t in UserToken,
      where: t.token == ^token and t.context == "session",
      where: t.inserted_at > ago(@session_validity_in_days, "day")
    )
    |> Repo.one()
  end

  @doc """
  Verifies a session fingerprint against the stored token data.

  Returns:
  - `:ok` if fingerprint matches or fingerprinting is disabled
  - `{:warning, reason}` if there's a partial mismatch (IP or UA changed)
  - `{:error, :fingerprint_mismatch}` if both IP and UA changed

  ## Examples

      iex> verify_session_fingerprint(conn, token)
      :ok

      iex> verify_session_fingerprint(conn, token)
      {:warning, :ip_mismatch}

  """
  def verify_session_fingerprint(conn, token) do
    alias PhoenixKit.Utils.SessionFingerprint

    # Skip verification if fingerprinting is disabled
    if SessionFingerprint.fingerprinting_enabled?() do
      case get_session_token_record(token) do
        nil ->
          # Token not found or expired
          {:error, :token_not_found}

        token_record ->
          SessionFingerprint.verify_fingerprint(
            conn,
            token_record.ip_address,
            token_record.user_agent_hash
          )
      end
    else
      :ok
    end
  end

  @doc """
  Ensures the user is active by checking the is_active field.

  Returns nil for inactive users and logs a warning.
  Returns the user for active users or nil input.

  ## Examples

      iex> ensure_active_user(%User{is_active: true})
      %User{is_active: true}

      iex> ensure_active_user(%User{is_active: false, id: 123})
      nil

      iex> ensure_active_user(nil)
      nil

  """
  def ensure_active_user(user) do
    case user do
      %User{is_active: false} = inactive_user ->
        require Logger

        Logger.warning(
          "PhoenixKit: Inactive user #{inactive_user.id} attempted access"
        )

        nil

      active_user ->
        active_user
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Deletes all session tokens for the given user.

  This function is useful when you need to force logout a user from all sessions,
  for example when their roles change and they need fresh authentication.
  """
  def delete_all_user_session_tokens(user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
    :ok
  end

  @doc """
  Gets all active session tokens for the given user.

  This is useful for finding all active sessions to broadcast logout messages.
  """
  def get_all_user_session_tokens(user) do
    Repo.all(UserToken.by_user_and_contexts_query(user, ["session"]))
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &PhoenixKit.Utils.Routes.url("/users/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &PhoenixKit.Utils.Routes.url("/users/confirm/#{&1}"))
      {:error, :already_confirmed}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: updated_user}} <- Repo.transaction(confirm_user_multi(user)) do
      # Broadcast confirmation event
      alias PhoenixKit.Admin.Events
      Events.broadcast_user_confirmed(updated_user)
      {:ok, updated_user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user) do
    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, User.confirm_changeset(user))
    Ecto.Multi.delete_all(multi, :tokens, UserToken.by_user_and_contexts_query(user, ["confirm"]))
  end

  @doc """
  Manually confirms a user account (admin function).

  ## Examples

      iex> admin_confirm_user(user)
      {:ok, %User{}}

      iex> admin_confirm_user(invalid_user)
      {:error, %Ecto.Changeset{}}
  """
  def admin_confirm_user(%User{} = user) do
    changeset = User.confirm_changeset(user)

    case Repo.update(changeset) do
      {:ok, updated_user} = result ->
        alias PhoenixKit.Admin.Events
        Events.broadcast_user_confirmed(updated_user)
        result

      error ->
        error
    end
  end

  @doc """
  Manually unconfirms a user account (admin function).

  ## Examples

      iex> admin_unconfirm_user(user)
      {:ok, %User{}}

      iex> admin_unconfirm_user(invalid_user)
      {:error, %Ecto.Changeset{}}
  """
  def admin_unconfirm_user(%User{} = user) do
    changeset = User.unconfirm_changeset(user)

    case Repo.update(changeset) do
      {:ok, updated_user} = result ->
        alias PhoenixKit.Admin.Events
        Events.broadcast_user_unconfirmed(updated_user)
        result

      error ->
        error
    end
  end

  @doc """
  Toggles user confirmation status (admin function).

  ## Examples

      iex> toggle_user_confirmation(confirmed_user)
      {:ok, %User{confirmed_at: nil}}

      iex> toggle_user_confirmation(unconfirmed_user)
      {:ok, %User{confirmed_at: ~N[2023-01-01 12:00:00]}}
  """
  def toggle_user_confirmation(%User{confirmed_at: nil} = user) do
    admin_confirm_user(user)
  end

  def toggle_user_confirmation(%User{} = user) do
    admin_unconfirm_user(user)
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given user.

  This function includes rate limiting protection to prevent mass password reset attacks.
  After exceeding the rate limit (default: 3 requests per 5 minutes), subsequent
  requests will be rejected with `{:error, :rate_limit_exceeded}`.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &PhoenixKit.Utils.Routes.url("/users/reset-password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_reset_password_instructions(user, &PhoenixKit.Utils.Routes.url("/users/reset-password/#{&1}"))
      {:error, :rate_limit_exceeded}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    # Check rate limit before sending reset email
    case RateLimiter.check_password_reset_rate_limit(user.email) do
      :ok ->
        {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
        Repo.insert!(user_token)

        UserNotifier.deliver_reset_password_instructions(
          user,
          reset_password_url_fun.(encoded_token)
        )

      {:error, :rate_limit_exceeded} ->
        {:error, :rate_limit_exceeded}
    end
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  def reset_user_password(user, attrs) do
    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, User.password_changeset(user, attrs))

    Ecto.Multi.delete_all(multi, :tokens, UserToken.by_user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Role Management Functions

  @doc """
  Assigns a role to a user.

  ## Examples

      iex> assign_role(user, "Admin")
      {:ok, %RoleAssignment{}}

      iex> assign_role(user, "Admin", assigned_by_user)
      {:ok, %RoleAssignment{}}

      iex> assign_role(user, "NonexistentRole")
      {:error, :role_not_found}
  """
  defdelegate assign_role(user, role_name, assigned_by \\ nil, opts \\ []),
    to: PhoenixKit.Users.Roles

  @doc """
  Removes a role from a user.

  ## Examples

      iex> remove_role(user, "Admin")
      {:ok, %RoleAssignment{}}

      iex> remove_role(user, "NonexistentRole")
      {:error, :assignment_not_found}
  """
  defdelegate remove_role(user, role_name, opts \\ []), to: PhoenixKit.Users.Roles

  @doc """
  Checks if a user has a specific role.

  ## Examples

      iex> user_has_role?(user, "Admin")
      true

      iex> user_has_role?(user, "Owner")
      false
  """
  defdelegate user_has_role?(user, role_name), to: PhoenixKit.Users.Roles

  @doc """
  Gets all active roles for a user.

  ## Examples

      iex> get_user_roles(user)
      ["Admin", "User"]

      iex> get_user_roles(user_with_no_roles)
      []
  """
  defdelegate get_user_roles(user), to: PhoenixKit.Users.Roles

  @doc """
  Gets all users who have a specific role.

  ## Examples

      iex> users_with_role("Admin")
      [%User{}, %User{}]

      iex> users_with_role("NonexistentRole")
      []
  """
  defdelegate users_with_role(role_name), to: PhoenixKit.Users.Roles

  @doc """
  Promotes a user to admin role.

  ## Examples

      iex> promote_to_admin(user)
      {:ok, %RoleAssignment{}}

      iex> promote_to_admin(user, assigned_by_user)
      {:ok, %RoleAssignment{}}
  """
  defdelegate promote_to_admin(user, assigned_by \\ nil), to: PhoenixKit.Users.Roles

  @doc """
  Demotes an admin user to regular user role.

  ## Examples

      iex> demote_to_user(user)
      {:ok, %RoleAssignment{}}
  """
  defdelegate demote_to_user(user), to: PhoenixKit.Users.Roles

  @doc """
  Gets role statistics for dashboard display.

  ## Examples

      iex> get_role_stats()
      %{
        total_users: 10,
        owner_count: 1,
        admin_count: 2,
        user_count: 7
      }
  """
  defdelegate get_role_stats(), to: PhoenixKit.Users.Roles

  @doc """
  Assigns roles to existing users who don't have any PhoenixKit roles.

  This is useful for migration scenarios where PhoenixKit is installed
  into an existing application with users.

  ## Examples

      iex> assign_roles_to_existing_users()
      {:ok, %{assigned_owner: 1, assigned_users: 5, total_processed: 6}}
  """
  defdelegate assign_roles_to_existing_users(opts \\ []), to: PhoenixKit.Users.Roles

  @doc """
  Lists all roles.

  ## Examples

      iex> list_roles()
      [%Role{}, %Role{}, %Role{}]
  """
  defdelegate list_roles(), to: PhoenixKit.Users.Roles

  @doc """
  Updates a user's profile information.

  ## Examples

      iex> update_user_profile(user, %{first_name: "John", last_name: "Doe"})
      {:ok, %User{}}

      iex> update_user_profile(user, %{first_name: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_user_profile(%User{} = user, attrs) do
    case user
         |> User.profile_changeset(attrs)
         |> Repo.update() do
      {:ok, updated_user} ->
        # Broadcast user profile update event
        Events.broadcast_user_updated(updated_user)
        {:ok, updated_user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates user custom fields.

  Custom fields are stored as JSONB and can contain arbitrary key-value pairs
  for extending user data without schema changes.

  ## Examples

      iex> update_user_custom_fields(user, %{"phone" => "555-1234", "department" => "Engineering"})
      {:ok, %User{}}

      iex> update_user_custom_fields(user, "invalid")
      {:error, %Ecto.Changeset{}}
  """
  def update_user_custom_fields(%User{} = user, custom_fields) when is_map(custom_fields) do
    case user
         |> User.custom_fields_changeset(%{custom_fields: custom_fields})
         |> Repo.update() do
      {:ok, updated_user} ->
        # Broadcast user profile update event
        Events.broadcast_user_updated(updated_user)
        {:ok, updated_user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates both schema and custom fields in a single call.

  This is a unified update function that automatically splits the provided
  attributes into schema fields and custom fields, updating both appropriately.

  ## Schema Fields
  - first_name, last_name, email, username, user_timezone

  ## Custom Fields
  - Any other keys are treated as custom fields

  ## Examples

      iex> update_user_fields(user, %{
      ...>   "first_name" => "John",
      ...>   "email" => "john@example.com",
      ...>   "phone" => "555-1234",
      ...>   "department" => "Engineering"
      ...> })
      {:ok, %User{}}

      iex> update_user_fields(user, %{email: "invalid"})
      {:error, %Ecto.Changeset{}}
  """
  def update_user_fields(%User{} = user, attrs) when is_map(attrs) do
    # Fields that can be updated via profile_changeset
    updatable_profile_fields = [:first_name, :last_name, :email, :username, :user_timezone]

    # Split attrs into schema fields and custom fields using Map.has_key? pattern
    {schema_attrs, custom_attrs} =
      Enum.reduce(attrs, {%{}, %{}}, fn {key, value}, {schema_acc, custom_acc} ->
        # Convert key to atom if needed to check Map.has_key?
        case safe_string_to_existing_atom(to_string(key)) do
          {:ok, field_atom} ->
            # Check if this is an updatable schema field
            if field_atom in updatable_profile_fields and Map.has_key?(user, field_atom) do
              {Map.put(schema_acc, field_atom, value), custom_acc}
            else
              # Not updatable or not in schema - treat as custom field
              {schema_acc, Map.put(custom_acc, to_string(key), value)}
            end

          :error ->
            # Not a known atom - must be custom field
            {schema_acc, Map.put(custom_acc, to_string(key), value)}
        end
      end)

    # Update in sequence: profile first, then custom fields
    with {:ok, updated_user} <- maybe_update_profile(user, schema_attrs) do
      maybe_update_custom_fields(updated_user, custom_attrs)
    end
  end

  # Helper to update profile fields only if there are any
  defp maybe_update_profile(user, attrs) when map_size(attrs) == 0, do: {:ok, user}

  defp maybe_update_profile(user, attrs) do
    update_user_profile(user, attrs)
  end

  # Helper to update custom fields only if there are any
  defp maybe_update_custom_fields(user, attrs) when map_size(attrs) == 0, do: {:ok, user}

  defp maybe_update_custom_fields(user, attrs) do
    # Merge new custom fields with existing ones (don't replace entirely)
    existing_custom_fields = user.custom_fields || %{}
    merged_custom_fields = Map.merge(existing_custom_fields, attrs)

    update_user_custom_fields(user, merged_custom_fields)
  end

  @doc """
  Bulk update multiple users with the same field values.

  This function updates multiple users at once with the same set of fields.
  Each user is updated independently, and the function returns a list of results
  showing which updates succeeded and which failed.

  Both schema fields and custom fields can be updated in the same call.

  ## Parameters
  - `users` - List of User structs to update
  - `attrs` - Map of field names to values (can include both schema and custom fields)

  ## Returns
  Returns `{:ok, results}` where results is a list of tuples:
  - `{:ok, user}` - Successfully updated user
  - `{:error, changeset}` - Failed update with error details

  ## Examples

      # Update multiple users with the same fields
      iex> users = [user1, user2, user3]
      iex> bulk_update_user_fields(users, %{status: "active", department: "Engineering"})
      {:ok, [
        {:ok, %User{status: "active", custom_fields: %{"department" => "Engineering"}}},
        {:ok, %User{status: "active", custom_fields: %{"department" => "Engineering"}}},
        {:error, %Ecto.Changeset{}}
      ]}

      # Update both schema and custom fields
      iex> bulk_update_user_fields(users, %{
      ...>   first_name: "John",           # Schema field
      ...>   last_name: "Doe",             # Schema field
      ...>   custom_field_1: "value1",     # Custom field
      ...>   custom_field_2: "value2"      # Custom field
      ...> })
      {:ok, [results...]}
  """
  def bulk_update_user_fields(users, attrs) when is_list(users) and is_map(attrs) do
    results =
      Enum.map(users, fn user ->
        case update_user_fields(user, attrs) do
          {:ok, updated_user} -> {:ok, updated_user}
          {:error, changeset} -> {:error, changeset}
        end
      end)

    {:ok, results}
  end

  @doc """
  Gets a user field value from either schema fields or custom fields.

  This unified accessor provides O(1) performance by checking struct fields
  first using Map.has_key?/2, then falling back to custom_fields JSONB.

  Certain sensitive fields are excluded for security:
  - password, current_password (virtual fields)
  - hashed_password (use authentication functions instead)

  ## Examples

      # Standard schema fields (O(1) struct access)
      iex> get_user_field(user, "email")
      "user@example.com"

      iex> get_user_field(user, :first_name)
      "John"

      # Custom fields (O(1) JSONB lookup)
      iex> get_user_field(user, "phone")
      "555-1234"

      # Nonexistent returns nil
      iex> get_user_field(user, "nonexistent")
      nil

      # Excluded sensitive fields return nil
      iex> get_user_field(user, "hashed_password")
      nil

  ## Performance

  - Standard fields: ~0.5μs (direct struct access)
  - Custom fields: ~1-2μs (JSONB lookup)
  - No performance penalty from checking both locations
  """
  def get_user_field(%User{} = user, field) when is_binary(field) do
    case safe_string_to_existing_atom(field) do
      {:ok, field_atom} ->
        if Map.has_key?(user, field_atom) and field_atom not in User.excluded_fields() do
          Map.get(user, field_atom)
        else
          Map.get(user.custom_fields || %{}, field)
        end

      :error ->
        # Not a known atom - must be custom field
        Map.get(user.custom_fields || %{}, field)
    end
  end

  def get_user_field(%User{} = user, field) when is_atom(field) do
    if Map.has_key?(user, field) and field not in User.excluded_fields() do
      Map.get(user, field)
    else
      # Try custom fields with string key
      Map.get(user.custom_fields || %{}, Atom.to_string(field))
    end
  end

  @doc """
  Gets a specific custom field value for a user.

  Returns the value if the key exists, or nil otherwise.

  ## Examples

      iex> get_user_custom_field(user, "phone")
      "555-1234"

      iex> get_user_custom_field(user, "nonexistent")
      nil
  """
  def get_user_custom_field(%User{custom_fields: custom_fields}, key) when is_binary(key) do
    Map.get(custom_fields || %{}, key)
  end

  @doc """
  Sets a specific custom field value for a user.

  Updates a single key in the custom_fields map while preserving other fields.

  ## Examples

      iex> set_user_custom_field(user, "phone", "555-1234")
      {:ok, %User{}}

      iex> set_user_custom_field(user, "department", "Product")
      {:ok, %User{}}
  """
  def set_user_custom_field(%User{} = user, key, value) when is_binary(key) do
    current_fields = user.custom_fields || %{}
    updated_fields = Map.put(current_fields, key, value)
    update_user_custom_fields(user, updated_fields)
  end

  @doc """
  Deletes a specific custom field for a user.

  Removes the key from the custom_fields map.

  ## Examples

      iex> delete_user_custom_field(user, "phone")
      {:ok, %User{}}
  """
  def delete_user_custom_field(%User{} = user, key) when is_binary(key) do
    current_fields = user.custom_fields || %{}
    updated_fields = Map.delete(current_fields, key)
    update_user_custom_fields(user, updated_fields)
  end

  @doc """
  Updates user status with Owner protection.

  Prevents deactivation of the last Owner to maintain system security.

  ## Parameters

  - `user`: User to update
  - `attrs`: Status attributes (typically %{"is_active" => true/false})

  ## Examples

      iex> update_user_status(user, %{"is_active" => false})
      {:ok, %User{}}

      iex> update_user_status(last_owner, %{"is_active" => false})
      {:error, :cannot_deactivate_last_owner}
  """
  def update_user_status(%User{} = user, attrs) do
    # Check if this would deactivate the last owner
    if attrs["is_active"] == false or attrs[:is_active] == false do
      do_deactivate_user(user, attrs)
    else
      # Activation is always safe
      do_update_user_status(user, attrs)
    end
  end

  defp do_deactivate_user(user, attrs) do
    case Roles.can_deactivate_user?(user) do
      :ok ->
        do_update_user_status(user, attrs)

      {:error, :cannot_deactivate_last_owner} ->
        Logger.warning("PhoenixKit: Attempted to deactivate last Owner user #{user.id}")
        {:error, :cannot_deactivate_last_owner}
    end
  end

  defp do_update_user_status(user, attrs) do
    case user
         |> User.status_changeset(attrs)
         |> Repo.update() do
      {:ok, updated_user} ->
        # Broadcast user status update event
        Events.broadcast_user_updated(updated_user)
        {:ok, updated_user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets a user by ID with preloaded roles.

  ## Examples

      iex> get_user_with_roles(123)
      %User{roles: [%Role{}, %Role{}]}

      iex> get_user_with_roles(999)
      nil
  """
  def get_user_with_roles(id) when is_integer(id) do
    from(u in User, where: u.id == ^id, preload: [:roles, :role_assignments])
    |> Repo.one()
  end

  @doc """
  Lists users with pagination and optional role filtering.

  ## Examples

      iex> list_users_paginated(page: 1, page_size: 10)
      %{users: [%User{}], total_count: 50, total_pages: 5}

      iex> list_users_paginated(page: 1, page_size: 10, role: "Admin")
      %{users: [%User{}], total_count: 3, total_pages: 1}
  """
  def list_users_paginated(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 10)
    role_filter = Keyword.get(opts, :role)
    search_query = Keyword.get(opts, :search, "")

    base_query = from(u in User, order_by: [desc: u.inserted_at])

    query =
      base_query
      |> maybe_filter_by_role(role_filter)
      |> maybe_filter_by_search(search_query)

    total_count = PhoenixKit.RepoHelper.aggregate(query, :count, :id)
    total_pages = div(total_count + page_size - 1, page_size)

    users =
      query
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> preload([:roles, :role_assignments])
      |> Repo.all()

    %{
      users: users,
      total_count: total_count,
      total_pages: total_pages,
      current_page: page
    }
  end

  defp maybe_filter_by_role(query, nil), do: query
  defp maybe_filter_by_role(query, "all"), do: query

  defp maybe_filter_by_role(query, role_name) when is_binary(role_name) do
    from [u] in query,
      join: assignment in assoc(u, :role_assignments),
      join: role in assoc(assignment, :role),
      where: role.name == ^role_name,
      distinct: u.id
  end

  defp maybe_filter_by_search(query, ""), do: query

  defp maybe_filter_by_search(query, search_term) when is_binary(search_term) do
    search_pattern = "%#{search_term}%"

    from [u] in query,
      where:
        ilike(u.email, ^search_pattern) or
          ilike(u.username, ^search_pattern) or
          ilike(u.first_name, ^search_pattern) or
          ilike(u.last_name, ^search_pattern)
  end

  @doc """
  Searches users by email or name for selection interfaces.

  Returns a list of users matching the search term, limited to 10 results
  for performance. Useful for autocomplete/typeahead interfaces.

  ## Examples

      iex> PhoenixKit.Users.Auth.search_users("john")
      [%User{email: "john@example.com", first_name: "John"}, ...]

      iex> PhoenixKit.Users.Auth.search_users("")
      []
  """
  def search_users(search_term) when is_binary(search_term) do
    case String.trim(search_term) do
      "" ->
        []

      trimmed_term when byte_size(trimmed_term) >= 2 ->
        search_pattern = "%#{trimmed_term}%"

        from(u in User,
          where:
            ilike(u.email, ^search_pattern) or
              ilike(u.username, ^search_pattern) or
              ilike(u.first_name, ^search_pattern) or
              ilike(u.last_name, ^search_pattern),
          order_by: [asc: u.email],
          limit: 10,
          select: %{
            id: u.id,
            email: u.email,
            username: u.username,
            first_name: u.first_name,
            last_name: u.last_name
          }
        )
        |> Repo.all()

      _ ->
        []
    end
  end

  @doc """
  Gets a user by ID with minimal fields for selection interfaces.

  Returns a user map with id, email, first_name, and last_name fields.
  Returns nil if user is not found.

  ## Examples

      iex> PhoenixKit.Users.Auth.get_user_for_selection(123)
      %{id: 123, email: "user@example.com", first_name: "John", last_name: "Doe"}

      iex> PhoenixKit.Users.Auth.get_user_for_selection(999)
      nil
  """
  def get_user_for_selection(user_id) when is_integer(user_id) do
    from(u in User,
      where: u.id == ^user_id,
      select: %{
        id: u.id,
        email: u.email,
        username: u.username,
        first_name: u.first_name,
        last_name: u.last_name
      }
    )
    |> Repo.one()
  end

  # Safe atom conversion - only succeeds if atom already exists
  # This prevents atom exhaustion attacks by only converting strings
  # that correspond to already-existing atoms in the system
  defp safe_string_to_existing_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end
end
