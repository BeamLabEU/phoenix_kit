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
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth.{User, UserNotifier, UserToken}
  alias PhoenixKit.Users.{CustomFields, RateLimiter, Role, Roles}
  alias PhoenixKit.Utils.Geolocation
  alias PhoenixKit.Utils.SessionFingerprint

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
  Gets a user by username.

  ## Examples

      iex> get_user_by_username("johndoe")
      %User{}

      iex> get_user_by_username("unknown")
      nil

  """
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Gets a user by email or username.

  Checks if the input contains "@" to determine whether to search
  by email or username.

  ## Examples

      iex> get_user_by_email_or_username("user@example.com")
      %User{}

      iex> get_user_by_email_or_username("johndoe")
      %User{}

      iex> get_user_by_email_or_username("unknown")
      nil

  """
  def get_user_by_email_or_username(email_or_username) when is_binary(email_or_username) do
    if String.contains?(email_or_username, "@") do
      get_user_by_email(email_or_username)
    else
      get_user_by_username(email_or_username)
    end
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
  Gets a user by email or username and password.

  Allows users to log in using either their email address or username.
  If the input contains "@", it's treated as an email; otherwise, as a username.
  Username lookup is case-insensitive for better UX.

  This function includes rate limiting protection to prevent brute-force attacks.

  ## Examples

      iex> get_user_by_email_or_username_and_password("foo@example.com", "correct_password")
      {:ok, %User{}}

      iex> get_user_by_email_or_username_and_password("johndoe", "correct_password")
      {:ok, %User{}}

      iex> get_user_by_email_or_username_and_password("JohnDoe", "correct_password")
      {:ok, %User{}}  # Case-insensitive username lookup

      iex> get_user_by_email_or_username_and_password("unknown", "password")
      {:error, :invalid_credentials}

  """
  def get_user_by_email_or_username_and_password(email_or_username, password, ip_address \\ nil)
      when is_binary(email_or_username) and is_binary(password) do
    # Check rate limit before attempting authentication
    case RateLimiter.check_login_rate_limit(email_or_username, ip_address) do
      :ok ->
        user =
          if String.contains?(email_or_username, "@") do
            # Treat as email
            Repo.get_by(User, email: email_or_username)
          else
            # Treat as username - case-insensitive lookup
            from(u in User,
              where: fragment("LOWER(?)", u.username) == ^String.downcase(email_or_username)
            )
            |> Repo.one()
          end

        # Return user if password is valid, regardless of is_active status
        # The session controller will handle inactive status check separately
        if User.valid_password?(user, password) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      {:error, :rate_limit_exceeded} ->
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
  def get_user(id) when is_integer(id), do: Repo.get_by(User, id: id)
  def get_user(uuid) when is_binary(uuid), do: PhoenixKit.UUID.get(User, uuid)

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id) when is_integer(id) do
    case Repo.get_by(User, id: id) do
      nil -> raise Ecto.NoResultsError, queryable: User
      user -> user
    end
  end

  def get_user!(uuid) when is_binary(uuid) do
    case Integer.parse(uuid) do
      {int_id, ""} -> get_user!(int_id)
      _ -> Repo.get!(User, uuid)
    end
  end

  @doc """
  Gets users by list of IDs.

  Returns list of users with all fields including custom_fields.
  Useful for batch loading users when you have a list of IDs.

  ## Examples

      iex> get_users_by_ids([1, 2, 3])
      [%User{id: 1, ...}, %User{id: 2, ...}]

      iex> get_users_by_ids([])
      []
  """
  def get_users_by_ids([]), do: []

  def get_users_by_ids(ids) when is_list(ids) do
    from(u in User, where: u.id in ^ids)
    |> Repo.all()
  end

  @doc """
  Gets the first admin user (Owner or Admin role).

  Useful for programmatic operations that require a user ID, such as
  creating entities via scripts or seeds.

  Returns the first Owner if one exists, otherwise the first Admin,
  otherwise nil.

  ## Examples

      iex> get_first_admin()
      %User{id: 1, email: "admin@example.com"}

      iex> get_first_admin()
      nil  # No admin users exist
  """
  def get_first_admin do
    roles = Role.system_roles()

    # Try to get Owner first, then Admin
    owner_query =
      from u in User,
        join: assignment in assoc(u, :role_assignments),
        join: role in assoc(assignment, :role),
        where: role.name == ^roles.owner,
        order_by: [asc: u.id],
        limit: 1

    case Repo.one(owner_query) do
      nil ->
        # No owner, try admin
        admin_query =
          from u in User,
            join: assignment in assoc(u, :role_assignments),
            join: role in assoc(assignment, :role),
            where: role.name == ^roles.admin,
            order_by: [asc: u.id],
            limit: 1

        Repo.one(admin_query)

      user ->
        user
    end
  end

  @doc """
  Gets the ID of the first admin user.

  Convenience function that returns just the user ID, useful for
  setting `created_by` fields programmatically.

  ## Examples

      iex> get_first_admin_id()
      1

      iex> get_first_admin_id()
      nil  # No admin users exist

      # Common usage for creating entities
      PhoenixKit.Modules.Entities.create_entity(%{
        name: "contact",
        display_name: "Contact",
        created_by: PhoenixKit.Users.Auth.get_first_admin_id()
      })
  """
  def get_first_admin_id do
    case get_first_admin() do
      nil -> nil
      user -> user.id
    end
  end

  @doc """
  Gets the first user in the system (by ID).

  Returns the user with the lowest ID, typically the first registered user.
  Useful as a fallback when no specific admin is needed.

  ## Examples

      iex> get_first_user()
      %User{id: 1}
  """
  def get_first_user do
    from(u in User, order_by: [asc: u.id], limit: 1)
    |> Repo.one()
  end

  @doc """
  Gets the ID of the first user in the system.

  Convenience function for getting a user ID for `created_by` fields.

  ## Examples

      iex> get_first_user_id()
      1
  """
  def get_first_user_id do
    case get_first_user() do
      nil -> nil
      user -> user.id
    end
  end

  @doc """
  Gets the UUID of the first admin user.

  Convenience function that returns just the user UUID, useful for
  setting `created_by_uuid` fields programmatically.

  ## Examples

      iex> get_first_admin_uuid()
      "019b5704-3680-7b95-9d82-ef16127f1fd2"

      iex> get_first_admin_uuid()
      nil  # No admin users exist
  """
  def get_first_admin_uuid do
    case get_first_admin() do
      nil -> nil
      user -> user.uuid
    end
  end

  @doc """
  Gets the UUID of the first user in the system.

  Convenience function for getting a user UUID for `created_by_uuid` fields.

  ## Examples

      iex> get_first_user_uuid()
      "019b5704-3680-7b95-9d82-ef16127f1fd2"
  """
  def get_first_user_uuid do
    case get_first_user() do
      nil -> nil
      user -> user.uuid
    end
  end

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
  Creates a guest user from checkout billing data.

  This function is used during guest checkout to create a temporary user
  account. The user will have `confirmed_at = nil` until they verify their
  email address.

  ## Parameters

  - `attrs` - Map with email (required), first_name, last_name

  ## Returns

  - `{:ok, user}` - New user created successfully
  - `{:error, :email_exists_confirmed}` - Email belongs to confirmed user (should login)
  - `{:error, :email_exists_unconfirmed, existing_user}` - Reuse existing unconfirmed user
  - `{:error, changeset}` - Validation errors

  ## Examples

      iex> create_guest_user(%{email: "guest@example.com", first_name: "John"})
      {:ok, %User{}}

      iex> create_guest_user(%{email: "existing@confirmed.com"})
      {:error, :email_exists_confirmed}

      iex> create_guest_user(%{email: "existing@unconfirmed.com"})
      {:error, :email_exists_unconfirmed, %User{}}

  """
  def create_guest_user(attrs) do
    email = attrs[:email] || attrs["email"]

    case get_user_by_email(email) do
      %User{confirmed_at: confirmed} = _user when not is_nil(confirmed) ->
        # User exists and is confirmed - they should login instead
        {:error, :email_exists_confirmed}

      %User{confirmed_at: nil} = existing_user ->
        # User exists but unconfirmed - update their name and return
        first_name = attrs[:first_name] || attrs["first_name"]
        last_name = attrs[:last_name] || attrs["last_name"]

        update_attrs =
          %{}
          |> maybe_put(:first_name, first_name)
          |> maybe_put(:last_name, last_name)

        if map_size(update_attrs) > 0 do
          case update_user_profile(existing_user, update_attrs) do
            {:ok, updated_user} -> {:error, :email_exists_unconfirmed, updated_user}
            {:error, _} -> {:error, :email_exists_unconfirmed, existing_user}
          end
        else
          {:error, :email_exists_unconfirmed, existing_user}
        end

      nil ->
        # No user with this email - create new guest user
        do_create_guest_user(attrs)
    end
  end

  defp do_create_guest_user(attrs) do
    case %User{}
         |> User.guest_user_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} ->
        # Assign default User role (not Owner, even if first guest)
        user_role = Role.system_roles().user

        case Roles.assign_role(user, user_role) do
          {:ok, _} ->
            Logger.info("PhoenixKit: Guest user #{user.id} (#{user.email}) created from checkout")
            {:ok, user}

          {:error, reason} ->
            Logger.error(
              "PhoenixKit: Failed to assign role to guest user #{user.id}: #{inspect(reason)}"
            )

            {:ok, user}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Helper to conditionally add key-value to map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

      iex> deliver_user_update_email_instructions(user, current_email, &PhoenixKit.Utils.Routes.url("/dashboard/settings/confirm_email/#{&1}"))
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

  ## Parameters
    * `user` - The user whose password is being updated
    * `attrs` - Password attributes (password, password_confirmation)
    * `context` - Optional context map containing:
      * `:admin_user` - The admin performing the action (for audit logging)
      * `:ip_address` - IP address of the admin (for audit logging)
      * `:user_agent` - User agent of the admin (for audit logging)

  ## Examples

      iex> admin_update_user_password(user, %{password: "new_password", password_confirmation: "new_password"})
      {:ok, %User{}}

      iex> admin_update_user_password(user, %{password: "new_password", password_confirmation: "new_password"}, %{admin_user: admin, ip_address: "192.168.1.1"})
      {:ok, %User{}}

      iex> admin_update_user_password(user, %{password: "short"})
      {:error, %Ecto.Changeset{}}

  """
  def admin_update_user_password(user, attrs, context \\ %{}) do
    changeset = User.password_changeset(user, attrs)

    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, changeset)

    multi =
      Ecto.Multi.delete_all(multi, :tokens, UserToken.by_user_and_contexts_query(user, :all))

    # Add audit logging if context is provided
    multi =
      if admin_user = Map.get(context, :admin_user) do
        Ecto.Multi.run(multi, :audit_log, fn _repo, %{user: updated_user} ->
          log_attrs = %{
            target_user_id: updated_user.id,
            target_user_uuid: updated_user.uuid,
            admin_user_id: admin_user.id,
            admin_user_uuid: admin_user.uuid,
            action: :admin_password_reset,
            ip_address: Map.get(context, :ip_address),
            user_agent: Map.get(context, :user_agent),
            metadata: %{
              target_email: updated_user.email,
              admin_email: admin_user.email
            }
          }

          case PhoenixKit.AuditLog.log_password_change(log_attrs) do
            {:ok, log_entry} -> {:ok, log_entry}
            # Don't fail password update if logging fails
            {:error, _} -> {:ok, nil}
          end
        end)
      else
        multi
      end

    multi
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

    * `:fingerprint` - Optional `%SessionFingerprint{}` struct with `:ip_address` and `:user_agent_hash`

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
        Logger.warning("PhoenixKit: Inactive user #{inactive_user.id} attempted access")
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
  Updates user's preferred locale (dialect preference).

  This allows users to select specific language dialects (e.g., en-GB, en-US)
  while URLs continue to use base codes (e.g., /en/).
  The locale is stored in the `custom_fields` JSONB column.

  Uses `update_user_custom_fields/2` internally for consistency.

  ## Examples

      iex> update_user_locale_preference(user, "en-GB")
      {:ok, %User{custom_fields: %{"preferred_locale" => "en-GB", ...}}}

      iex> update_user_locale_preference(user, "invalid")
      {:error, "must be a valid locale format (e.g., en-US, es-MX)"}

      iex> update_user_locale_preference(user, nil)
      {:ok, %User{...}}  # Clears the preference
  """
  def update_user_locale_preference(%User{} = user, preferred_locale) do
    case User.validate_locale_value(preferred_locale) do
      :ok ->
        # Merge locale into existing custom_fields
        current_fields = user.custom_fields || %{}

        updated_fields =
          if preferred_locale && preferred_locale != "" do
            Map.put(current_fields, "preferred_locale", preferred_locale)
          else
            Map.delete(current_fields, "preferred_locale")
          end

        update_user_custom_fields(user, updated_fields)

      {:error, message} ->
        {:error, message}
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
  Update a user's avatar by storing the file and saving the file ID.

  This function handles the complete avatar upload workflow:
  1. Stores the file in configured storage buckets
  2. Automatically queues background job for variant generation
  3. Saves the file ID to the user's custom_fields

  This is a convenience function that combines file storage with user update.
  Can be called from any context (LiveView, controllers, scripts, etc.) outside
  of the PhoenixKit project.

  ## Parameters
  - `user` - The User struct to update
  - `file_path` - Path to the uploaded file (temporary location)
  - `filename` - Original filename for the upload
  - `user_id` - The user ID owning this file (defaults to user.id)

  ## Returns
  - `{:ok, user}` - Avatar saved successfully
  - `{:error, reason}` - File storage or update failed

  ## Examples

      # Store avatar in default location with automatic variant generation
      {:ok, updated_user} = Auth.update_user_avatar(user, "/tmp/upload_xyz", "avatar.jpg")

      # Store with explicit user_id (for custom workflows)
      {:ok, updated_user} = Auth.update_user_avatar(user, "/tmp/upload_xyz", "avatar.jpg", custom_user_id)

  ## Automatically Generated Variants
  The storage layer automatically generates these image variants:
  - original - Full-size image
  - large - 800x800px
  - medium - 400x400px
  - small - 200x200px
  - thumbnail - 100x100px
  """
  def update_user_avatar(%User{} = user, file_path, filename, user_id \\ nil) do
    user_id = user_id || user.id

    # Calculate file hash
    file_hash = calculate_file_hash(file_path)

    # Get file extension
    ext = Path.extname(filename) |> String.replace_leading(".", "")

    # Store file in buckets (automatically queues ProcessFileJob for variants)
    case Storage.store_file_in_buckets(
           file_path,
           "image",
           user_id,
           file_hash,
           ext,
           filename
         ) do
      {:ok, file} ->
        # Save the file ID to user's custom fields
        update_user_fields(user, %{"avatar_file_id" => file.id})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calculate SHA256 hash of a file.

  Used internally for file integrity verification.

  ## Parameters
  - `file_path` - Path to the file

  ## Returns
  - String containing the lowercase hexadecimal SHA256 hash
  """
  def calculate_file_hash(file_path) do
    file_path
    |> File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
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
  Gets the display value for a custom field, resolving select field indexes to text.

  For select/radio/checkbox fields that store index values (0, 1, 2...),
  this function returns the actual option text. For other fields, returns
  the raw value.

  ## Examples

      iex> get_user_custom_field_display(user, "favorite_color")
      "Blue"  # even though stored value is "1"

      iex> get_user_custom_field_display(user, "phone")
      "555-1234"  # non-select field returns raw value
  """
  def get_user_custom_field_display(%User{} = user, field_key) when is_binary(field_key) do
    raw_value = get_user_field(user, field_key)
    CustomFields.get_option_text(field_key, raw_value) || raw_value
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

  def get_user_with_roles(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} ->
        get_user_with_roles(int_id)

      _ ->
        from(u in User, where: u.uuid == ^id, preload: [:roles, :role_assignments])
        |> Repo.one()
    end
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

    total_count = PhoenixKit.RepoHelper.aggregate(query, :count, :uuid)
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
            uuid: u.uuid,
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
        uuid: u.uuid,
        email: u.email,
        username: u.username,
        first_name: u.first_name,
        last_name: u.last_name
      }
    )
    |> Repo.one()
  end

  def get_user_for_selection(user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} ->
        get_user_for_selection(int_id)

      _ ->
        from(u in User,
          where: u.uuid == ^user_id,
          select: %{
            id: u.id,
            uuid: u.uuid,
            email: u.email,
            username: u.username,
            first_name: u.first_name,
            last_name: u.last_name
          }
        )
        |> Repo.one()
    end
  end

  # Safe atom conversion - only succeeds if atom already exists
  # This prevents atom exhaustion attacks by only converting strings
  # that correspond to already-existing atoms in the system
  defp safe_string_to_existing_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  ## Admin Notes

  alias PhoenixKit.Users.AdminNote

  @doc """
  Lists all admin notes for a user, ordered by most recent first.

  Preloads the author information for display.

  ## Examples

      iex> list_admin_notes(user)
      [%AdminNote{}, ...]

  """
  def list_admin_notes(%User{} = user) do
    from(n in AdminNote,
      where: n.user_uuid == ^user.uuid,
      order_by: [desc: n.inserted_at],
      preload: [:author]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single admin note by ID.

  Preloads the author information.

  ## Examples

      iex> get_admin_note(123)
      %AdminNote{}

      iex> get_admin_note(456)
      nil

  """
  def get_admin_note(id) when is_integer(id) do
    from(n in AdminNote,
      where: n.id == ^id,
      preload: [:author]
    )
    |> Repo.one()
  end

  def get_admin_note(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} ->
        get_admin_note(int_id)

      _ ->
        from(n in AdminNote,
          where: n.uuid == ^id,
          preload: [:author]
        )
        |> Repo.one()
    end
  end

  @doc """
  Creates an admin note about a user.

  ## Parameters

  - `user` - The user being noted about
  - `author` - The admin creating the note
  - `attrs` - Map containing `:content`

  ## Examples

      iex> create_admin_note(user, author, %{content: "Important note"})
      {:ok, %AdminNote{}}

      iex> create_admin_note(user, author, %{content: ""})
      {:error, %Ecto.Changeset{}}

  """
  def create_admin_note(%User{} = user, %User{} = author, attrs) do
    attrs =
      attrs
      |> Map.put("user_id", user.id)
      |> Map.put("user_uuid", user.uuid)
      |> Map.put("author_id", author.id)
      |> Map.put("author_uuid", author.uuid)

    %AdminNote{}
    |> AdminNote.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, note} -> {:ok, Repo.preload(note, :author)}
      error -> error
    end
  end

  @doc """
  Updates an admin note.

  Only the content can be updated.

  ## Examples

      iex> update_admin_note(note, %{content: "Updated note"})
      {:ok, %AdminNote{}}

      iex> update_admin_note(note, %{content: ""})
      {:error, %Ecto.Changeset{}}

  """
  def update_admin_note(%AdminNote{} = note, attrs) do
    note
    |> AdminNote.update_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, note} -> {:ok, Repo.preload(note, :author)}
      error -> error
    end
  end

  @doc """
  Deletes an admin note.

  ## Examples

      iex> delete_admin_note(note)
      {:ok, %AdminNote{}}

  """
  def delete_admin_note(%AdminNote{} = note) do
    Repo.delete(note)
  end

  @doc """
  Returns a changeset for tracking admin note changes.

  ## Examples

      iex> change_admin_note(note)
      %Ecto.Changeset{}

  """
  def change_admin_note(%AdminNote{} = note, attrs \\ %{}) do
    AdminNote.changeset(note, attrs)
  end

  ## User Deletion

  @doc """
  Deletes a user account with proper cascade handling and data anonymization.

  ## Protection Rules

  1. Cannot delete self - Prevents accidental self-deletion
  2. Cannot delete last Owner - System must always have at least one Owner
  3. Admin/Owner only - Only privileged users can delete accounts

  ## Data Handling Strategy

  ### Cascade Delete (automatic or manual)
  - User tokens (ON DELETE CASCADE in DB)
  - Role assignments (ON DELETE CASCADE in DB)
  - OAuth providers
  - Billing profiles
  - Shop carts
  - Admin notes

  ### Anonymize (preserve data, remove PII)
  - Orders - SET NULL on user_id, preserve financial records
  - Posts - Keep content, set user_id to NULL, mark as deleted author
  - Comments - Keep content, set user_id to NULL, mark as deleted author
  - Tickets - Preserve for support history, anonymize
  - Email logs - Retain for compliance, anonymize
  - Files - Anonymize ownership

  ## Parameters

  - `user` - The user to delete
  - `opts` - Options map containing:
    - `:current_user` - The user performing the deletion (required)
    - `:ip_address` - IP address for audit logging
    - `:user_agent` - User agent for audit logging

  ## Returns

  - `{:ok, %{deleted_user_id: id, anonymized_records: count}}` - Success
  - `{:error, :cannot_delete_self}` - Cannot delete your own account
  - `{:error, :cannot_delete_last_owner}` - Cannot delete the last Owner
  - `{:error, :insufficient_permissions}` - Current user lacks permission
  - `{:error, reason}` - Other errors

  ## Examples

      iex> delete_user(user, %{current_user: admin_user})
      {:ok, %{deleted_user_id: 123, anonymized_records: 15}}

      iex> delete_user(user, %{current_user: user})
      {:error, :cannot_delete_self}

      iex> delete_user(last_owner, %{current_user: admin_user})
      {:error, :cannot_delete_last_owner}

      iex> delete_user(admin_user, %{current_user: non_owner_admin})
      {:error, :insufficient_permissions}
  """
  def delete_user(%User{} = user, opts \\ %{}) do
    current_user = Map.get(opts, :current_user)

    with :ok <- validate_can_delete_user(user, current_user),
         {:ok, result} <- execute_user_deletion(user, opts) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a user can be deleted by the current user.

  Returns `:ok` if deletion is allowed, or `{:error, reason}` if not.

  ## Examples

      iex> can_delete_user?(user_to_delete, current_user)
      :ok

      iex> can_delete_user?(current_user, current_user)
      {:error, :cannot_delete_self}
  """
  def can_delete_user?(%User{} = user, %User{} = current_user) do
    case validate_can_delete_user(user, current_user) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  def can_delete_user?(_user, _current_user), do: false

  # Validates deletion permissions and constraints
  defp validate_can_delete_user(%User{} = user, %User{} = current_user) do
    cond do
      # Rule 1: Cannot delete self
      user.uuid == current_user.uuid ->
        {:error, :cannot_delete_self}

      # Rule 2: Cannot delete last Owner
      Roles.user_has_role_owner?(user) and count_remaining_owners(user.uuid) < 1 ->
        {:error, :cannot_delete_last_owner}

      # Rule 3: Only Owner can delete Admin users
      Roles.user_has_role_admin?(user) and not Roles.user_has_role_owner?(current_user) ->
        {:error, :insufficient_permissions}

      # Rule 4: Only Admin/Owner can delete (checked via scope in controller/LiveView)
      true ->
        :ok
    end
  end

  defp validate_can_delete_user(_user, _current_user) do
    {:error, :invalid_current_user}
  end

  # Count remaining active owners excluding the given user
  defp count_remaining_owners(excluding_user_uuid) do
    roles = Role.system_roles()

    from(u in User,
      join: assignment in assoc(u, :role_assignments),
      join: role in assoc(assignment, :role),
      where: role.name == ^roles.owner,
      where: u.is_active == true,
      where: u.uuid != ^excluding_user_uuid,
      select: count(u.id)
    )
    |> Repo.one() || 0
  end

  # Execute the deletion within a transaction
  defp execute_user_deletion(%User{} = user, opts) do
    Repo.transaction(fn ->
      # 1. Delete cascade data (related records that should be fully removed)
      delete_cascade_data(user)

      # 2. Anonymize preserved data (records that should remain but without PII)
      anonymized_count = anonymize_user_data(user)

      # 3. Delete the user
      case Repo.delete(user) do
        {:ok, _deleted_user} ->
          # 4. Log the deletion
          log_user_deletion(user, opts, anonymized_count)

          # 5. Broadcast the deletion event
          Events.broadcast_user_deleted(user)

          %{deleted_user_id: user.id, anonymized_records: anonymized_count}

        {:error, changeset} ->
          Repo.rollback({:error, changeset})
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # Delete related data that should be fully removed
  defp delete_cascade_data(%User{} = user) do
    # Delete OAuth providers
    delete_user_oauth_providers(user.uuid)

    # Delete billing profiles
    delete_user_billing_profiles(user.uuid)

    # Delete shop carts
    delete_user_shop_carts(user.uuid)

    # Delete admin notes about this user
    delete_user_admin_notes(user.uuid)

    :ok
  end

  # Delete OAuth providers for a user (uses user_uuid for safety)
  defp delete_user_oauth_providers(user_uuid) do
    from(op in PhoenixKit.Users.OAuthProvider, where: op.user_uuid == ^user_uuid)
    |> Repo.repo().delete_all()
  end

  # Delete billing profiles for a user (uses user_uuid for safety)
  defp delete_user_billing_profiles(user_uuid) do
    from(bp in PhoenixKit.Modules.Billing.BillingProfile, where: bp.user_uuid == ^user_uuid)
    |> Repo.repo().delete_all()
  end

  # Delete shop carts for a user (uses user_uuid for safety)
  defp delete_user_shop_carts(user_uuid) do
    from(c in PhoenixKit.Modules.Shop.Cart, where: c.user_uuid == ^user_uuid)
    |> Repo.repo().delete_all()
  end

  # Delete admin notes for a user (uses user_uuid for safety)
  defp delete_user_admin_notes(user_uuid) do
    from(an in AdminNote, where: an.user_uuid == ^user_uuid)
    |> Repo.repo().delete_all()
  end

  # Anonymize data that should be preserved but without PII
  defp anonymize_user_data(%User{} = user) do
    anonymized_count = 0

    # Anonymize orders - set user_id to NULL
    orders_count = anonymize_user_orders(user.uuid)

    # Anonymize posts - set user_id to NULL, mark as deleted author
    posts_count = anonymize_user_posts(user.uuid)

    # Anonymize comments - set user_id to NULL, mark as deleted author
    comments_count = anonymize_user_comments(user.uuid)

    # Anonymize tickets - preserve for support history
    tickets_count = anonymize_user_tickets(user.uuid)

    # Anonymize email logs - retain for compliance
    email_logs_count = anonymize_user_email_logs(user.uuid)

    # Anonymize files - remove ownership
    files_count = anonymize_user_files(user.uuid)

    anonymized_count +
      orders_count +
      posts_count +
      comments_count +
      tickets_count +
      email_logs_count +
      files_count
  end

  # Anonymize orders by setting user_id to NULL
  defp anonymize_user_orders(user_uuid) do
    # Check if Orders module exists and has the schema
    # Note: Order schema doesn't exist in Shop module yet - this is for future compatibility
    module = Module.concat([PhoenixKit, Modules, Shop, Order])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([o], o.user_uuid == ^user_uuid)

      from(o in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [user_id: nil, user_uuid: nil, anonymized_at: DateTime.utc_now()]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize posts by setting user_id to NULL and marking deleted author
  defp anonymize_user_posts(user_uuid) do
    module = Module.concat([PhoenixKit, Modules, Posts, Post])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([p], p.user_uuid == ^user_uuid)

      from(p in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_id: nil,
          user_uuid: nil,
          author_deleted: true,
          anonymized_at: DateTime.utc_now()
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize comments by setting user_id to NULL and marking deleted author
  defp anonymize_user_comments(user_uuid) do
    # Anonymize legacy PostComments (Posts module)
    legacy_count = anonymize_legacy_post_comments(user_uuid)

    # Anonymize standalone Comments module
    standalone_count = anonymize_standalone_comments(user_uuid)

    legacy_count + standalone_count
  end

  defp anonymize_legacy_post_comments(user_uuid) do
    module = Module.concat([PhoenixKit, Modules, Posts, PostComment])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([c], c.user_uuid == ^user_uuid)

      from(c in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_id: nil,
          user_uuid: nil,
          author_deleted: true,
          anonymized_at: DateTime.utc_now()
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  defp anonymize_standalone_comments(user_uuid) do
    module = Module.concat([PhoenixKit, Modules, Comments, Comment])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([c], c.user_uuid == ^user_uuid)

      from(c in module, where: ^dynamic_query)
      |> Repo.repo().update_all(set: [user_id: nil, user_uuid: nil])
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize tickets for support history
  defp anonymize_user_tickets(user_uuid) do
    module = Module.concat([PhoenixKit, Modules, Tickets, Ticket])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([t], t.user_uuid == ^user_uuid)

      from(t in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_id: nil,
          user_uuid: nil,
          anonymized_at: DateTime.utc_now(),
          original_user_email: nil
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize email logs - retain for compliance but remove PII
  defp anonymize_user_email_logs(user_uuid) do
    # Emails.Log is in PhoenixKit.Modules.Emails namespace
    module = Module.concat([PhoenixKit, Modules, Emails, Log])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([el], el.user_uuid == ^user_uuid)

      from(el in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_id: nil,
          user_uuid: nil,
          anonymized_at: DateTime.utc_now()
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize files - remove ownership
  defp anonymize_user_files(user_uuid) do
    module = Module.concat([PhoenixKit, Modules, Storage, File])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([f], f.user_uuid == ^user_uuid)

      from(f in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_id: nil,
          user_uuid: nil,
          anonymized_at: DateTime.utc_now()
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Log user deletion for audit purposes
  defp log_user_deletion(%User{} = user, opts, anonymized_count) do
    current_user = Map.get(opts, :current_user)
    ip_address = Map.get(opts, :ip_address)
    user_agent = Map.get(opts, :user_agent)

    Logger.info(
      "PhoenixKit: User #{user.id} (#{user.email}) deleted by " <>
        "#{if current_user, do: "admin #{current_user.id} (#{current_user.email})", else: "system"}. " <>
        "Anonymized #{anonymized_count} records."
    )

    # If audit log module is available, log there too
    audit_module = Module.concat([PhoenixKit, AuditLog])

    if Code.ensure_loaded?(audit_module) and
         function_exported?(audit_module, :create_log_entry, 1) do
      log_attrs = %{
        target_user_id: user.id,
        target_user_uuid: user.uuid,
        admin_user_id: current_user && current_user.id,
        admin_user_uuid: current_user && current_user.uuid,
        action: :user_deleted,
        ip_address: ip_address,
        user_agent: user_agent,
        metadata: %{
          target_email: user.email,
          admin_email: current_user && current_user.email,
          anonymized_records: anonymized_count
        }
      }

      # Don't fail if audit logging fails
      # Using apply/3 intentionally to avoid compile-time module resolution
      try do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(audit_module, :create_log_entry, [log_attrs])
      rescue
        _ -> :ok
      end
    end

    :ok
  end
end
