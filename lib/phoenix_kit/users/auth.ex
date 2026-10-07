defmodule PhoenixKit.Users.Auth do
  @compile {:no_warn_undefined, PhoenixKitEcommerce.Cart}

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

  use Gettext, backend: PhoenixKitWeb.Gettext

  # This module will be populated by mix phx.gen.auth

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.{User, UserNotifier, UserToken}
  alias PhoenixKit.Users.{CustomFields, RateLimiter, Role, Roles, Sessions, WelcomeEmail}
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Geolocation
  alias PhoenixKit.Utils.Pagination
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.SessionFingerprint
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

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
          # Successful login: hand back the slot the check took. The bucket
          # counts brute-force attempts, and this was not one.
          RateLimiter.record_successful_login(email, ip_address)
          {:ok, user}
        else
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
            # Treat as username - case-insensitive lookup. Plain equality is
            # enough since V161 made the column `citext`, and unlike the
            # `LOWER(username)` fragment this replaces it can use
            # `phoenix_kit_users_username_uidx`: that fragment matched no index,
            # so every username login sequentially scanned the whole users table
            # — on an endpoint anyone can hit without authenticating.
            get_user_by_username(email_or_username)
          end

        # Return user if password is valid, regardless of is_active status
        # The session controller will handle inactive status check separately
        if User.valid_password?(user, password) do
          RateLimiter.record_successful_login(email_or_username, ip_address)
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
  def get_user(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      Repo.get(User, uuid)
    else
      nil
    end
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(uuid) when is_binary(uuid) do
    Repo.get!(User, uuid)
  end

  @doc """
  Gets users by list of UUIDs.

  Returns list of users with all fields including custom_fields.
  Useful for batch loading users when you have a list of UUIDs.

  ## Examples

      iex> get_users_by_ids(["01924...", "01925..."])
      [%User{uuid: "01924...", ...}, %User{uuid: "01925...", ...}]

      iex> get_users_by_ids([])
      []
  """
  def get_users_by_ids([]), do: []

  def get_users_by_ids(ids) when is_list(ids) do
    from(u in User, where: u.uuid in ^ids)
    |> Repo.all()
  end

  @doc """
  Gets multiple users by their UUIDs.
  """
  def get_users_by_uuids([]), do: []

  def get_users_by_uuids(uuids) when is_list(uuids) do
    from(u in User, where: u.uuid in ^uuids)
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
        order_by: [asc: u.uuid],
        limit: 1

    case Repo.one(owner_query) do
      nil ->
        # No owner, try admin
        admin_query =
          from u in User,
            join: assignment in assoc(u, :role_assignments),
            join: role in assoc(assignment, :role),
            where: role.name == ^roles.admin,
            order_by: [asc: u.uuid],
            limit: 1

        Repo.one(admin_query)

      user ->
        user
    end
  end

  @doc """
  Gets the first user in the system (by insertion order).

  Returns the earliest registered user (by UUID, which is time-ordered via UUIDv7).
  Useful as a fallback when no specific admin is needed.

  ## Examples

      iex> get_first_user()
      %User{uuid: "some-uuid"}
  """
  def get_first_user do
    from(u in User, order_by: [asc: u.uuid], limit: 1)
    |> Repo.one()
  end

  @doc """
  Gets the UUID of the first user in the system.

  Convenience function for getting a user UUID for `created_by` fields.

  Deprecated name kept for backwards compatibility - returns UUID now.
  Prefer `get_first_user_uuid/0` for new code.

  ## Examples

      iex> get_first_user_uuid()
      "01924..."
  """
  def get_first_user_uuid do
    case get_first_user() do
      nil -> nil
      user -> user.uuid
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

      iex> register_user(%{email: "user@example.com", password: "pass", custom_fields: %{"source" => "landing_page"}})
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

  @doc """
  Creates a user on behalf of an admin, recording who added them.

  The admin-panel counterpart of `register_user/2`: the same changeset, the
  same role assignment and `user_created` broadcast, plus
  `created_by_uuid = actor.uuid`. `created_by_uuid` is put on the changeset
  here rather than cast, so no params map can set it.

  Not rate limited: the registration limits exist to stop anonymous sign-up
  spam, and this path is reachable only by an authenticated actor already
  admitted to the users admin. Counting it against the admin's IP would lock
  the admin out after ten additions an hour — and lock their office network
  out of public sign-up with it.

  ## Examples

      iex> admin_create_user(%{"email" => "new@example.com", "password" => "..."}, admin)
      {:ok, %User{created_by_uuid: ^admin_uuid}}

      iex> admin_create_user(%{"email" => "invalid"}, admin)
      {:error, %Ecto.Changeset{}}
  """
  def admin_create_user(attrs, %User{uuid: actor_uuid}) when is_map(attrs) do
    do_register_user(attrs, created_by_uuid: actor_uuid)
  end

  defp do_register_user(attrs, opts \\ []) do
    case %User{}
         |> User.registration_changeset(attrs)
         |> Ecto.Changeset.put_change(:created_by_uuid, Keyword.get(opts, :created_by_uuid))
         |> Repo.insert() do
      {:ok, user} ->
        # Safely assign Owner role to first user, User role to others
        case Roles.ensure_first_user_is_owner(user) do
          {:ok, role_type} ->
            # Log successful role assignment for security audit
            Logger.info(
              "PhoenixKit: User #{user.uuid} (#{user.email}) assigned #{role_type} role"
            )

            # Broadcast user creation event
            Events.broadcast_user_created(user)

            {:ok, user}

          {:error, reason} ->
            # Role assignment failed - this is critical
            Logger.error(
              "PhoenixKit: Failed to assign role to user #{user.uuid}: #{inspect(reason)}"
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
  def register_user_with_geolocation(attrs, ip_address)
      when is_binary(ip_address) and ip_address != "unknown" do
    # `attrs` may arrive atom-keyed (e.g. the OAuth registration path) or
    # string-keyed (e.g. form params). Normalize to string keys before
    # merging in any of our own string-keyed fields below — Ecto.Changeset.cast/3
    # raises Ecto.CastError on a map with mixed atom/string keys.
    attrs = stringify_keys(attrs)

    # Start with the IP address
    enhanced_attrs = Map.put(attrs, "registration_ip", ip_address)

    # Attempt geolocation lookup
    case Geolocation.lookup_location(ip_address) do
      {:ok, location} ->
        # Add geolocation data to registration. `registration_country` is a
        # 2-char column by design (ISO 3166-1 alpha-2) — the full country
        # name from `location["country"]` (e.g. "United States") does NOT
        # fit and crashes the insert with `string_data_right_truncation`,
        # killing the registration LiveView mid-signup. Only a genuine
        # 2-letter code goes in; anything else (a provider quirk, a nil)
        # leaves the column nil rather than risk a repeat of that crash.
        enhanced_attrs =
          enhanced_attrs
          |> Map.put("registration_country", registration_country_code(location["country_code"]))
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

  def register_user_with_geolocation(attrs, _invalid_or_unknown_ip) do
    # No usable IP (nil, "unknown", or anything else non-address-shaped) —
    # register without geolocation data and without a bogus `registration_ip`.
    # A literal "unknown" here previously got stored as if it were an IP
    # (the `is_binary` guard above didn't exclude it) and rendered verbatim
    # in the admin UI.
    register_user(attrs, nil)
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp registration_country_code(code) when is_binary(code) and byte_size(code) == 2, do: code
  defp registration_country_code(_), do: nil

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
            Logger.info(
              "PhoenixKit: Guest user #{user.uuid} (#{user.email}) created from checkout"
            )

            {:ok, user}

          {:error, reason} ->
            Logger.error(
              "PhoenixKit: Failed to assign role to guest user #{user.uuid}: #{inspect(reason)}"
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
  Emulates that the email will change without actually changing it in the
  database — same as `apply_user_email/3`, but without a password check.

  Restricted to a user who has never confirmed their account (enforced by
  the pattern match, not just a caller convention). The password re-entry in
  `apply_user_email/3` exists to stop a hijacked session from quietly
  redirecting a *live* account's mail; there is no live account to protect
  here yet, only a pending signup fixing a typo'd address before its first
  confirmation. This is the only email-change path core exposes without a
  password, so it must never be reachable once `confirmed_at` is set.

  ## Examples

      iex> apply_unconfirmed_user_email(unconfirmed_user, %{email: "new@example.com"})
      {:ok, %User{}}

  """
  def apply_unconfirmed_user_email(%User{confirmed_at: nil} = user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"
    was_unconfirmed? = is_nil(user.confirmed_at)

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, %{user: updated_user}} <-
           Repo.transaction(user_email_multi(user, email, context, was_unconfirmed?)) do
      # Only a genuine unconfirmed -> confirmed transition, not every email
      # change (an already-confirmed user changing their address re-runs
      # confirm_changeset too, but did not just newly confirm) — otherwise a
      # dashboard subscribed to `@topic_users` would see a false "just
      # confirmed" event on every routine email change.
      if was_unconfirmed?, do: Events.broadcast_user_confirmed(updated_user)

      PhoenixKit.Activity.log(%{
        action: "user.email_changed",
        module: "users",
        mode: "auto",
        actor_uuid: user.uuid,
        resource_type: "user",
        resource_uuid: user.uuid,
        metadata: %{"old_email" => user.email, "new_email" => email, "actor_role" => "user"}
      })

      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context, was_unconfirmed?) do
    changeset =
      user
      |> User.email_changeset(%{email: email})
      |> User.confirm_changeset()

    # "Wrong email?" on an unconfirmed account: the new address is the first
    # one the reader has proven, so this is their confirmation too — when the
    # row is still unconfirmed as the transaction sees it.
    multi =
      if was_unconfirmed?,
        do: WelcomeEmail.track_transition(Ecto.Multi.new(), user),
        else: Ecto.Multi.new()

    multi
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, [context]))
    |> WelcomeEmail.multi()
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &PhoenixKit.Utils.Routes.url("/profile/settings/confirm-email/#{&1}"))
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

  Every session token is deleted. Other devices are disconnected immediately.
  Pass `:except_token` for the browser that just submitted the form: LiveView
  broadcasts `"disconnect"` as a page reload, and the settings form still needs
  this socket alive so `phx-trigger-action` can POST the re-login. A reload
  here lands on a deleted remember-me token and looks like a sign-out.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, password, attrs, opts \\ []) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, changeset)

    multi
    |> Ecto.Multi.delete_all(:tokens, revoked_tokens_query(user))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, tokens: {_count, revoked}}} ->
        disconnect_revoked_sessions(revoked, except_token: opts[:except_token])

        PhoenixKit.Activity.log(%{
          action: "user.password_changed",
          module: "users",
          mode: "manual",
          actor_uuid: user.uuid,
          resource_type: "user",
          resource_uuid: user.uuid,
          metadata: %{"method" => "password_form", "actor_role" => "user"}
        })

        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates the user password as an admin (bypasses current password validation).

  ## Parameters
    * `user` - The user whose password is being updated
    * `attrs` - Password attributes (password, password_confirmation)
    * `context` - Optional context map containing:
      * `:admin_user` - The admin performing the action. **Authorizes as well as
        audits**: when present, the write is refused unless
        `can_manage_user_credentials?/2` allows this actor over this target.
      * `:ip_address` - IP address of the admin (for audit logging)
      * `:user_agent` - User agent of the admin (for audit logging)

  Omitting `:admin_user` is the system path — seeds, migrations and mix tasks
  act with no actor and are not rank-checked, matching `update_user_status/3`.
  A web caller must always pass it; without it there is nothing to check.

  ## Examples

      iex> admin_update_user_password(user, %{password: "new_password", password_confirmation: "new_password"})
      {:ok, %User{}}

      iex> admin_update_user_password(user, %{password: "new_password", password_confirmation: "new_password"}, %{admin_user: admin, ip_address: "192.168.1.1"})
      {:ok, %User{}}

      iex> admin_update_user_password(owner, %{password: "new_password"}, %{admin_user: admin})
      {:error, :insufficient_permissions}

      iex> admin_update_user_password(user, %{password: "short"})
      {:error, %Ecto.Changeset{}}

  """
  # The rank rule lives here rather than in the form that calls it. `:admin_user`
  # was already threaded in for the audit row, so the actor was in hand the whole
  # time and only the question was missing: the edit LiveView asked
  # `can_manage_user_credentials?/2` to hide the UI and to refuse the event, but
  # the context function wrote the hash for anyone who reached it. That is the
  # same shape the status path had — a rule living in one LiveView while two
  # other callers went around it — and it is why `update_user_status/3` was moved
  # into the context. Credentials are the more final of the two, since setting a
  # password also deletes every session token of the target.
  def admin_update_user_password(user, attrs, context \\ %{}) do
    case Map.get(context, :admin_user) do
      %User{} = actor ->
        if can_manage_user_credentials?(user, actor) do
          do_admin_update_user_password(user, attrs, context)
        else
          refuse_credential_write(user, actor)
        end

      # Only an ABSENT actor is the system path — seeds, migrations and mix
      # tasks pass no context at all. A value that is present but not a `%User{}`
      # (a map decoded from JSON by a host controller, a bare uuid string) is a
      # caller that meant to supply an actor and got the shape wrong; treating
      # that as "no actor" would hand it the unchecked path. This is a library,
      # so it cannot see its hosts' callers — it fails closed instead.
      nil ->
        do_admin_update_user_password(user, attrs, context)

      _malformed ->
        Logger.warning(
          "PhoenixKit: refused a password write for #{target_label(user)} — :admin_user was present but not a %User{}"
        )

        {:error, :insufficient_permissions}
    end
  end

  # A refusal that leaves no trace is a guard nobody can tell fired. The whole
  # point of moving this rule into the context is the caller that does not exist
  # yet; when it arrives and is blocked, the operator needs to be able to see
  # that rather than debug a silent no-op. `do_deactivate_user/2` already sets
  # this precedent for a milder refusal (see the last-Owner branch below).
  defp refuse_credential_write(user, %User{} = actor) do
    Logger.warning(
      "PhoenixKit: refused a password write for #{target_label(user)} by #{actor.uuid} — actor is out of rank"
    )

    {:error, :insufficient_permissions}
  end

  # The public head takes `user` unguarded, so both refusal branches can be
  # handed whatever a host passes — and `can_manage_user_credentials?/2` answers
  # `false` for a non-`%User{}` target rather than raising, which is how one
  # reaches the refusal in the first place. Interpolating `user.uuid` there
  # would raise `KeyError` on the JSON-decoded map the malformed-actor branch
  # was written to expect, turning the fail-closed path into a crash: exactly
  # the outcome the guard exists to prevent, and a louder one than the write.
  defp target_label(%User{uuid: uuid}), do: uuid
  defp target_label(_other), do: "an unrecognised target"

  defp do_admin_update_user_password(user, attrs, context) do
    changeset = User.password_changeset(user, attrs)

    multi = Ecto.Multi.new()
    multi = Ecto.Multi.update(multi, :user, changeset)

    multi =
      Ecto.Multi.delete_all(multi, :tokens, revoked_tokens_query(user))

    # Add audit logging if context is provided
    multi =
      if admin_user = Map.get(context, :admin_user) do
        Ecto.Multi.run(multi, :audit_log, fn _repo, %{user: updated_user} ->
          log_attrs = %{
            target_user_uuid: updated_user.uuid,
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
      {:ok, %{user: user, tokens: {_count, revoked}}} ->
        disconnect_revoked_sessions(revoked)
        admin_user = Map.get(context, :admin_user)

        PhoenixKit.Activity.log(%{
          action: "user.password_changed",
          module: "users",
          mode: "manual",
          actor_uuid: admin_user && admin_user.uuid,
          resource_type: "user",
          resource_uuid: user.uuid,
          target_uuid: user.uuid,
          metadata: %{"method" => "admin_reset", "actor_role" => "admin"}
        })

        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  ## Organization Accounts

  @doc """
  Whether organization accounts are enabled site-wide
  (`"enable_organization_accounts"`, default `false`).

  The master switch: off, this install has person accounts only and the
  organization columns, tabs and pickers are hidden throughout the admin area.
  """
  @spec organization_accounts_enabled?() :: boolean()
  def organization_accounts_enabled? do
    PhoenixKit.Settings.get_boolean_setting("enable_organization_accounts", false)
  end

  @doc """
  The account-type policy for the PUBLIC signup forms.

  Returns one of:

    * `"choice"` — the visitor picks Personal or Organization (the default, and
      what every install that has never touched the setting reads).
    * `"person"` — every self-serve signup is a person. Organizations still
      exist; only an admin creates them.
    * `"organization"` — every self-serve signup IS an organization, and the
      Organization Name field is required. The B2B shape: there are no personal
      accounts to open, and staff arrive through an organization invitation.

  Collapses to `"person"` whenever organization accounts are off, so a single
  call answers "what may this form create?" without every caller also having to
  ask `organization_accounts_enabled?/0`.

  An unrecognised stored value falls back to the default rather than raising —
  a bad row must not take the signup page down.
  """
  @spec registration_account_type() :: String.t()
  def registration_account_type do
    if organization_accounts_enabled?() do
      default = PhoenixKit.Settings.default_registration_account_type()
      stored = PhoenixKit.Settings.get_setting_cached("registration_account_type", default)

      if stored in PhoenixKit.Settings.registration_account_types(), do: stored, else: default
    else
      "person"
    end
  end

  @doc """
  Stamps the account-type policy onto public-signup params, server-side.

  ⚠️ This — not the hidden `<select>` — is the control. `registration_changeset/3`
  casts `account_type` and `organization_name` straight from the payload, and a
  `phx-submit` payload is whatever the client sends: without this, a forged
  `user[account_type]=organization` created an organization account on a site
  where the picker was never rendered (including one with organization accounts
  switched off entirely).

  Mirrors `maybe_write_remember_me_cookie/3`: the policy is enforced where the
  value is used, so no caller and no forged param can route around it.

  In `"choice"` mode the visitor's pick is honoured but normalised to the two
  known values — the registration changeset has no `validate_inclusion` of its
  own, so an unknown string would otherwise reach the insert and be rejected by
  a CHECK constraint as a 500 rather than a validation error.
  """
  @spec enforce_registration_account_type(map(), String.t()) :: map()
  def enforce_registration_account_type(params, "choice") when is_map(params) do
    if Map.get(params, "account_type") == "organization" do
      params
    else
      force_person_params(params)
    end
  end

  def enforce_registration_account_type(params, "organization") when is_map(params) do
    Map.put(params, "account_type", "organization")
  end

  def enforce_registration_account_type(params, _mode) when is_map(params) do
    force_person_params(params)
  end

  # `organization_name` goes with it: `validate_organization_fields/1` nils the
  # column for a person anyway, but dropping it here keeps the value out of the
  # changeset (and out of the re-rendered form) rather than relying on that.
  defp force_person_params(params) do
    params
    |> Map.put("account_type", "person")
    |> Map.delete("organization_name")
  end

  @doc """
  Lists all organization-type users.
  """
  def list_organizations do
    from(u in User, where: u.account_type == "organization", order_by: [asc: u.organization_name])
    |> Repo.all()
  end

  @doc """
  Lists all person users belonging to an organization.
  """
  def list_organization_members(organization_uuid) do
    from(u in User, where: u.organization_uuid == ^organization_uuid, order_by: [asc: u.email])
    |> Repo.all()
  end

  @doc """
  Lists person users available to join an organization (not already in one).
  Excludes the organization itself and users already belonging to any organization.
  """
  def list_available_members_for_organization(organization_uuid) do
    from(u in User,
      where:
        u.account_type == "person" and
          is_nil(u.organization_uuid) and
          u.uuid != ^organization_uuid,
      order_by: [asc: u.email]
    )
    |> Repo.all()
  end

  @doc """
  Sets a person user's organization. Validates target is an organization-type user.
  """
  def set_organization(%User{} = user, organization_uuid) do
    with {:ok, org} <- get_organization(organization_uuid),
         :ok <- validate_not_self(user, org),
         :ok <- validate_user_is_person(user) do
      user
      |> User.account_type_changeset(%{organization_uuid: organization_uuid})
      |> Repo.update()
    end
  end

  @doc """
  Removes a user from their organization.
  """
  def remove_from_organization(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{organization_uuid: nil})
    |> Repo.update()
  end

  @doc """
  Changes a user's account type. Validates no members exist when switching org→person.
  """
  def change_account_type(%User{} = user, attrs) do
    with :ok <- validate_can_change_type(user, attrs) do
      user
      |> User.account_type_changeset(attrs)
      |> Repo.update()
    end
  end

  defp get_organization(uuid) do
    case Repo.get(User, uuid) do
      %User{account_type: "organization"} = org -> {:ok, org}
      %User{} -> {:error, dgettext("phoenix_kit", "target user is not an organization")}
      nil -> {:error, dgettext("phoenix_kit", "organization not found")}
    end
  end

  defp validate_not_self(%User{uuid: uuid}, %User{uuid: org_uuid}) when uuid == org_uuid do
    {:error, dgettext("phoenix_kit", "cannot reference self")}
  end

  defp validate_not_self(_, _), do: :ok

  defp validate_user_is_person(%User{account_type: "person"}), do: :ok

  defp validate_user_is_person(_),
    do: {:error, dgettext("phoenix_kit", "only person accounts can join an organization")}

  defp validate_can_change_type(%User{account_type: "organization"} = user, attrs) do
    target_type = to_string(attrs[:account_type] || attrs["account_type"])

    if target_type == "person" do
      case list_organization_members(user.uuid) do
        [] ->
          :ok

        _ ->
          {:error,
           dgettext("phoenix_kit", "cannot change to person while organization has members")}
      end
    else
      :ok
    end
  end

  defp validate_can_change_type(_, _), do: :ok

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
      token_uuid: inserted_token.uuid,
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
            rebind_proxy_address(conn, token_record, token),
            token_record.user_agent_hash,
            session: session_label(token)
          )
      end
    else
      :ok
    end
  end

  # A session that stored a reverse proxy's address moves to the visitor's
  # once, without a warning — see `SessionFingerprint.proxy_rebind_address/3`.
  # Conditional on the stored value, so two requests racing here write once.
  defp rebind_proxy_address(conn, %UserToken{ip_address: stored_ip} = token_record, token) do
    case SessionFingerprint.proxy_rebind_address(conn, stored_ip, token_record.user_agent_hash) do
      nil ->
        stored_ip

      current_ip ->
        from(t in UserToken, where: t.uuid == ^token_record.uuid and t.ip_address == ^stored_ip)
        |> Repo.update_all(set: [ip_address: current_ip])

        Logger.info(
          "PhoenixKit: session #{session_label(token)} moved from proxy address " <>
            "#{stored_ip} to #{current_ip}"
        )

        current_ip
    end
  end

  # A short, stable label for one session, so fingerprint lines can be
  # correlated to each other and to a row in the sessions UI.
  #
  # THE SAME derivation the sessions UI displays as its token preview —
  # `encode(substring(token, 1, 4), 'hex')` in `PhoenixKit.Users.Sessions` —
  # because the label exists to be searched for on that page, and the
  # previous derivation (truncated sha256) could never match it: an operator
  # pasting the logged label into the sessions search got zero results every
  # time. Four of the token's ~32 random bytes in a log is not a usable
  # credential (the UI already shows admins these same bytes), and 8 hex
  # characters is plenty to group a handful of lines by.
  #
  # Public (@doc false) so the test suite can hold the two derivations
  # together — they drifted apart silently once already.
  @doc false
  def session_label(token) when is_binary(token) and byte_size(token) >= 4 do
    token |> binary_part(0, 4) |> Base.encode16(case: :lower)
  end

  def session_label(_), do: "unknown"

  @doc """
  Ensures the user is active by checking the is_active field.

  Returns nil for inactive users and logs a warning.
  Returns the user for active users or nil input.

  ## Examples

      iex> ensure_active_user(%User{is_active: true})
      %User{is_active: true}

      iex> ensure_active_user(%User{is_active: false, uuid: "some-uuid"})
      nil

      iex> ensure_active_user(nil)
      nil

  """
  def ensure_active_user(user) do
    case user do
      %User{is_active: false} = inactive_user ->
        Logger.warning("PhoenixKit: Inactive user #{inactive_user.uuid} attempted access")
        nil

      active_user ->
        active_user
    end
  end

  @doc """
  Deletes the signed token with the given context and disconnects the LiveView
  socket it was holding open.

  Every path that drops a session token disconnects it, so the invariant is
  "a revoked token has no live socket" rather than a list of callers that
  remember to say so. A logout already broadcasts for the session's own
  `live_socket_id`; the repeat is idempotent.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    Sessions.disconnect_tokens([token])
    :ok
  end

  # Every path that rotates a credential deletes ALL of the user's tokens, so
  # each one also has to close the sockets those sessions were holding open.
  # `delete_all` only reports what it deleted when the query selects it, and the
  # raw token is the only way to address the socket once the row is gone.
  defp revoked_tokens_query(user) do
    from(t in UserToken.by_user_and_contexts_query(user, :all),
      select: %{token: t.token, context: t.context}
    )
  end

  # Picks the session tokens out of a `:all` delete — the rest are one-shot
  # email tokens with no socket behind them. `:except_token` is the browser
  # that still has work to do on this request (see `update_user_password/4`).
  defp disconnect_revoked_sessions(revoked, opts \\ []) do
    except = opts[:except_token]

    revoked
    |> Enum.filter(&(&1.context == "session"))
    |> Enum.map(& &1.token)
    |> Enum.reject(&(&1 == except))
    |> Sessions.disconnect_tokens()
  end

  @doc """
  Deletes all session tokens for the given user and disconnects their open
  LiveView sockets.

  This function is useful when you need to force logout a user from all sessions,
  for example when their roles change and they need fresh authentication.

  The disconnect is part of the drain rather than each caller's job: deleting
  the row only ends the session at the next request, while an already-connected
  socket keeps its authenticated assigns until it re-mounts. "Force logout" that
  leaves the open tab working is the failure mode this exists to prevent.
  """
  def delete_all_user_session_tokens(user) do
    {_count, revoked} =
      Repo.delete_all(
        from(t in UserToken.by_user_and_contexts_query(user, ["session"]), select: t.token)
      )

    Sessions.disconnect_tokens(revoked)
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
  Returns the `inserted_at` of the most recently sent, still-live confirmation
  email for this user, or `nil` if none is on record (never sent, or all
  confirm tokens have since expired/been consumed).

  Backs the "sent X ago" wording on the parked confirmation-instructions page
  — without it that page's "we sent a link" claim has no evidence behind it.
  """
  def get_last_confirmation_sent_at(%User{} = user) do
    user
    |> UserToken.by_user_and_contexts_query(["confirm"])
    |> select([t], t.inserted_at)
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: updated_user}} <-
           Repo.transaction(confirm_user_multi(user)) do
      # Broadcast confirmation event
      Events.broadcast_user_confirmed(updated_user)

      PhoenixKit.Activity.log(%{
        action: "user.email_confirmed",
        module: "users",
        mode: "auto",
        actor_uuid: updated_user.uuid,
        resource_type: "user",
        resource_uuid: updated_user.uuid,
        metadata: %{"method" => "email_link", "actor_role" => "user"}
      })

      {:ok, updated_user}
    else
      _ -> :error
    end
  end

  # The welcome email is enqueued only on a real unconfirmed -> confirmed
  # transition: an old link clicked after an administrator confirmed the
  # account re-runs the confirmation, but confirms nothing new.
  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> WelcomeEmail.track_transition(user)
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, ["confirm"]))
    |> WelcomeEmail.multi()
  end

  @doc """
  Manually confirms a user account (admin function).

  Sends no welcome email (`PhoenixKit.Users.WelcomeEmail`): an administrator
  confirming an account is not the reader proving their address. A flow that
  confirms through here on the reader's behalf — magic-link registration —
  calls `WelcomeEmail.after_confirmation/1` itself.

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
  Confirms an account whose email ownership was just proven by an external
  channel (verified OAuth email, magic link) rather than by the confirmation
  email — and closes the account-pre-hijack window while doing so.

  An unconfirmed row may have been *pre-registered by someone else* with a
  password they know. Confirming it alone would hand that row to the rightful
  address holder while leaving the pre-registrant's password and sessions
  intact. So, atomically with the confirmation, every token (sessions, pending
  resets, confirmation links) is deleted and the stored password hash is
  rotated to an unguessable value. The rightful owner sets a password via
  "forgot password" if they want one; they never knew the old one.

  Already-confirmed users are returned unchanged.
  """
  @spec confirm_user_from_external_proof(User.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def confirm_user_from_external_proof(%User{confirmed_at: nil} = user) do
    rotated_hash = Bcrypt.hash_pwd_salt(:crypto.strong_rand_bytes(32) |> Base.encode64())

    changeset =
      user
      |> User.confirm_changeset()
      |> Ecto.Changeset.change(hashed_password: rotated_hash)

    Ecto.Multi.new()
    # A second tab holding the same stale, unconfirmed struct confirms again;
    # only the transition the database sees enqueues the welcome email.
    |> WelcomeEmail.track_transition(user)
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, revoked_tokens_query(user))
    # Enqueued in this transaction — and in the OAuth callback's around it —
    # so a rollback takes the welcome email with the confirmation.
    |> WelcomeEmail.multi()
    |> Repo.transaction()
    |> case do
      {:ok, %{user: confirmed_user, tokens: {_count, revoked}}} ->
        disconnect_revoked_sessions(revoked)
        Events.broadcast_user_confirmed(confirmed_user)
        {:ok, confirmed_user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  def confirm_user_from_external_proof(%User{} = user), do: {:ok, user}

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

  ## Authorization

  Pass `actor: %User{}` and the RANK rule is enforced here, in the context —
  the actor must outrank the target (`can_manage_user_status?/2`). Do that from
  every request-driven path.

  Omitting `:actor` is the system path and performs NO authorization, matching
  `update_user_status/3`. An `:actor` that is PRESENT but is not a `%User{}` is
  refused rather than read as absent.

  ## Examples

      iex> toggle_user_confirmation(confirmed_user)
      {:ok, %User{confirmed_at: nil}}

      iex> toggle_user_confirmation(unconfirmed_user)
      {:ok, %User{confirmed_at: ~N[2023-01-01 12:00:00]}}

      iex> toggle_user_confirmation(owner, actor: admin)
      {:error, :insufficient_permissions}
  """
  def toggle_user_confirmation(user, opts \\ [])

  def toggle_user_confirmation(%User{} = user, opts) do
    # Same rank rule as status and credentials, and for the same reason:
    # `require_email_confirmation` is honoured at eleven gates, so UNCONFIRMING
    # an account locks it out of every protected page. Offered from the same
    # pages, to the same holders of the `users` permission, it is the same
    # denial of service against accounts that outrank the actor.
    case Keyword.get(opts, :actor) do
      %User{} = actor ->
        if can_manage_user_status?(user, actor),
          do: do_toggle_user_confirmation(user),
          else: {:error, :insufficient_permissions}

      # Only an ABSENT actor is the system path — seeds, migrations and mix
      # tasks pass no opts at all. A value that is present but not a `%User{}`
      # (a map decoded from JSON by a host controller, a bare uuid string) is a
      # caller that meant to supply an actor and got the shape wrong; treating
      # that as "no actor" would hand it the unchecked path. Fails closed for
      # the same reason `admin_update_user_password/3` does, and it matters most
      # here: the unchecked path can clear `confirmed_at`.
      nil ->
        do_toggle_user_confirmation(user)

      _malformed ->
        Logger.warning(
          "PhoenixKit: refused a confirmation toggle for #{target_label(user)} — :actor was present but not a %User{}"
        )

        {:error, :insufficient_permissions}
    end
  end

  defp do_toggle_user_confirmation(%User{confirmed_at: nil} = user) do
    admin_confirm_user(user)
  end

  defp do_toggle_user_confirmation(%User{} = user) do
    admin_unconfirm_user(user)
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given user.

  This function includes rate limiting protection to prevent mass password reset attacks.
  After exceeding the rate limit (default: 3 requests per 5 minutes), subsequent
  requests will be rejected with `{:error, :rate_limit_exceeded}`.

  ## Options

    * `:rate_limit` — set to `false` when the caller has ALREADY charged
      `RateLimiter.check_password_reset_rate_limit/2` for this request. The
      public forgot-password form has to throttle before the user lookup (a
      limiter that only runs for addresses which resolve to a user is an
      account-existence oracle), and both checks hit the same per-email bucket
      — so leaving this on there spends two of the three allowed hits per
      submission and silently drops every second reset email. Defaults to
      `true` for callers with no limiter of their own (e.g. the admin
      "send reset link" action).

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &PhoenixKit.Utils.Routes.url("/users/reset-password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_reset_password_instructions(user, &PhoenixKit.Utils.Routes.url("/users/reset-password/#{&1}"))
      {:error, :rate_limit_exceeded}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun, opts \\ [])
      when is_function(reset_password_url_fun, 1) do
    if Keyword.get(opts, :rate_limit, true) do
      case RateLimiter.check_password_reset_rate_limit(user.email) do
        :ok -> send_reset_password_instructions(user, reset_password_url_fun)
        {:error, :rate_limit_exceeded} -> {:error, :rate_limit_exceeded}
      end
    else
      send_reset_password_instructions(user, reset_password_url_fun)
    end
  end

  defp send_reset_password_instructions(user, reset_password_url_fun) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)

    UserNotifier.deliver_reset_password_instructions(
      user,
      reset_password_url_fun.(encoded_token)
    )
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

    multi
    |> Ecto.Multi.delete_all(:tokens, revoked_tokens_query(user))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, tokens: {_count, revoked}}} ->
        disconnect_revoked_sessions(revoked)

        PhoenixKit.Activity.log(%{
          action: "user.password_reset",
          module: "users",
          mode: "auto",
          actor_uuid: user.uuid,
          resource_type: "user",
          resource_uuid: user.uuid,
          metadata: %{"method" => "reset_token", "actor_role" => "user"}
        })

        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
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
  The address to reach this user at on Google, or `nil`.

  Sharing something through Google (a Drive file, a calendar invite) needs the
  address the user's Google account answers to, which is not always the one
  they registered with. In order:

    1. `google_email`, set by the user, by an admin, or filled in from a
       linked Google sign-in.
    2. `email`, when it is itself a Google-hosted address — a user who signed
       up with their Gmail address has already told us where to share, and
       making them retype it into a second field is the kind of thing nobody
       does until it is too late.

  Nothing else is guessed: any other address may or may not have a Google
  account behind it, and a share sent to one that does not is a share the
  user never receives.

  ## Examples

      iex> google_email(%User{google_email: "work@example.com", email: "a@b.com"})
      "work@example.com"

      iex> google_email(%User{google_email: nil, email: "person@gmail.com"})
      "person@gmail.com"

      iex> google_email(%User{google_email: nil, email: "person@example.com"})
      nil
  """
  @spec google_email(User.t()) :: String.t() | nil
  def google_email(%User{} = user) do
    case presence(user.google_email) do
      nil -> user.email |> presence() |> google_hosted() |> then(&(&1 && String.downcase(&1)))
      address -> address
    end
  end

  @google_domains ~w(gmail.com googlemail.com)

  defp google_hosted(nil), do: nil

  defp google_hosted(email) do
    domain = email |> String.split("@") |> List.last() |> String.downcase()
    if domain in @google_domains, do: email
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  @doc """
  Updates a user's profile information.

  ## Examples

      iex> update_user_profile(user, %{first_name: "John", last_name: "Doe"})
      {:ok, %User{}}

      iex> update_user_profile(user, %{first_name: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_user_profile(%User{} = user, attrs) do
    changeset = User.profile_changeset(user, attrs)

    case Repo.update(changeset) do
      {:ok, updated_user} ->
        Events.broadcast_user_updated(updated_user)

        PhoenixKit.Activity.log_user_change("user.profile_updated", user, changeset,
          mode: "manual"
        )

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

  Writes through the atomic single-key primitives —
  `merge_user_custom_fields/3` to set, `delete_user_custom_field/3` to
  clear — so a concurrent writer of a different custom_fields key is
  never lost. Passes `ensure_definitions: false` deliberately: the
  locale is an internal preference, not an admin-managed custom field,
  so the first write no longer auto-registers a field definition
  (the old whole-map path did, as a side effect).

  ## Examples

      iex> update_user_locale_preference(user, "en-GB")
      {:ok, %User{custom_fields: %{"preferred_locale" => "en-GB", ...}}}

      iex> update_user_locale_preference(user, "invalid")
      {:error, "must be a valid locale format (e.g., en-US, es-MX)"}

      iex> update_user_locale_preference(user, nil)
      {:ok, %User{...}}  # Clears the preference

  Two distinct error shapes: a validation failure returns `{:error, message}`
  with a human-readable string, while a row deleted concurrently surfaces the
  primitives' `{:error, :not_found}`.
  """
  @spec update_user_locale_preference(User.t(), String.t() | nil) ::
          {:ok, User.t()} | {:error, String.t()} | {:error, :not_found}
  def update_user_locale_preference(%User{} = user, preferred_locale) do
    case User.validate_locale_value(preferred_locale) do
      :ok ->
        # Both branches operate on the single affected key at the
        # database level rather than replacing the whole map — this
        # function is fired from the language-switcher hook and used to
        # race (and lose against) any concurrent custom_fields writer,
        # e.g. a newsletters opt-out. Validation stays above, on the
        # explicit path, before anything touches the row.
        if preferred_locale && preferred_locale != "" do
          merge_user_custom_fields(user, %{"preferred_locale" => preferred_locale},
            ensure_definitions: false
          )
        else
          delete_user_custom_field(user, "preferred_locale")
        end

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  The page this user has chosen to land on after signing in, or `nil`.

  A RELATIVE path (`"/admin/projects"`), never a resolved URL: the PhoenixKit
  prefix and the active locale are applied at redirect time, so a preference
  saved in Estonian still works in English and survives a prefix change.

  Stored in `custom_fields` under a reserved key, exactly like
  `preferred_locale` — an internal preference, not an admin-managed custom
  field.
  """
  @spec user_start_page(User.t() | nil) :: String.t() | nil
  def user_start_page(%User{custom_fields: fields}) when is_map(fields) do
    case Map.get(fields, "start_page") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  def user_start_page(_user), do: nil

  @doc """
  Sets (or clears, with `nil`) where this user lands after signing in.

  Refuses anything that is not a local relative path — a stored `//evil.test`
  or a full URL would turn a saved preference into an open redirect fired on
  every login. Delegates the check to `PhoenixKit.Utils.Routes.local_path?/1`
  rather than re-testing the shape here: that function is the documented
  single source of truth for this guard (it also blocks the ASCII
  control-character smuggle, `"/\t/evil.com"`, that browsers strip down to
  `//evil.com`) and a second, drifting copy of it is exactly what let that
  gap open the first time. Writes through the atomic single-key primitives
  with `ensure_definitions: false`, the same discipline as
  `update_user_locale_preference/2`, so a concurrent writer of another
  `custom_fields` key is never lost.
  """
  @spec update_user_start_page(User.t(), String.t() | nil) ::
          {:ok, User.t()} | {:error, String.t()} | {:error, :not_found}
  def update_user_start_page(%User{} = user, path) do
    cond do
      is_nil(path) or path == "" ->
        delete_user_custom_field(user, "start_page")

      Routes.local_path?(path) ->
        merge_user_custom_fields(user, %{"start_page" => path}, ensure_definitions: false)

      true ->
        {:error, "must be a path within this site"}
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
  def update_user_custom_fields(%User{} = user, custom_fields, opts \\ [])
      when is_map(custom_fields) do
    # Internal UI preferences (e.g. a table view toggle) also write through this
    # function, but must not register themselves as user-facing custom-field
    # definitions nor fan out a profile-update broadcast. Both options default
    # to true, so every existing caller is unchanged.
    if Keyword.get(opts, :ensure_definitions, true) do
      CustomFields.ensure_definitions_exist(custom_fields)
    end

    case user
         |> User.custom_fields_changeset(%{custom_fields: custom_fields})
         |> Repo.update() do
      {:ok, updated_user} ->
        if Keyword.get(opts, :broadcast, true) do
          # Broadcast user profile update event
          Events.broadcast_user_updated(updated_user)
        end

        {:ok, updated_user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Atomically merges `additions` into a user's custom_fields JSONB column
  at the database level (`custom_fields || additions`), instead of
  `update_user_custom_fields/3`'s read-modify-write contract.

  Every existing caller that wants to add/update a couple of keys while
  preserving the rest follows the same pattern: fetch the user, compute
  `Map.merge(user.custom_fields, %{"key" => value})` in Elixir, then call
  `update_user_custom_fields/3` with the merged result. That has a real
  lost-update race: two callers merging DIFFERENT keys into the same
  user's custom_fields concurrently (say, a locale preference switch and
  a newsletters opt-out) can each read the same pre-update snapshot, and
  whichever write commits second silently overwrites the whole column
  with a map that never saw the other's key — no error, no conflict
  raised, just quietly missing data. Doing the merge inside the UPDATE
  statement itself closes that window: Postgres serializes concurrent
  writers on the same row, so the second UPDATE's `||` reads the FIRST
  writer's already-committed value, not a stale snapshot.

  Only ever ADDS or OVERWRITES the given keys — this can't clear/remove
  one (unlike `update_user_custom_fields/3`, which replaces the whole
  map and so CAN clear fields by omitting them from the replacement —
  see that function's own tests); to remove a single key atomically use
  `delete_user_custom_field/3`. Reach for this whenever the intent is
  "add/update these specific keys, leave everything else exactly as any
  concurrent writer left it"; reach for `update_user_custom_fields/3`
  when the caller genuinely needs to replace the whole map.

  Returns `{:error, :not_found}` rather than raising if the user row was
  deleted concurrently between the caller's read and this call.

  ## Examples

      iex> merge_user_custom_fields(user, %{"newsletters_opted_out_at" => "2026-01-01T00:00:00Z"})
      {:ok, %User{}}
  """
  @spec merge_user_custom_fields(User.t(), map(), keyword()) ::
          {:ok, User.t()} | {:error, :not_found}
  def merge_user_custom_fields(%User{} = user, additions, opts \\ [])
      when is_map(additions) do
    if Keyword.get(opts, :ensure_definitions, true) do
      CustomFields.ensure_definitions_exist(additions)
    end

    query =
      from(u in User,
        where: u.uuid == ^user.uuid,
        update: [
          set: [
            # COALESCE first: the column is nullable (V18) and
            # `NULL || jsonb` is NULL — without it a NULL row would
            # swallow the additions with no error. Same defensive idiom
            # the V30 migration uses for its own atomic merge.
            custom_fields:
              fragment("COALESCE(?, '{}'::jsonb) || ?", u.custom_fields, type(^additions, :map)),
            updated_at: ^UtilsDate.utc_now()
          ]
        ],
        select: u
      )

    case Repo.update_all(query, []) do
      {1, [updated_user]} ->
        if Keyword.get(opts, :broadcast, true) do
          Events.broadcast_user_updated(updated_user)
        end

        {:ok, updated_user}

      {0, _} ->
        {:error, :not_found}
    end
  end

  # Kept as a module attribute with a public reader rather than a literal inside
  # `update_user_fields/2`, because a second list of the same names lives in the
  # admin form — which drops them out of `custom_fields` precisely so they
  # cannot reach the branch below unfiltered. Two hand-maintained copies of a
  # security-relevant whitelist drift, and the drift is silent: adding a field
  # here and forgetting the other copy re-opens the bypass for that one field.
  # `test/integration/users/user_form_authority_test.exs` pins them together.
  @updatable_profile_fields [
    :first_name,
    :last_name,
    :email,
    :google_email,
    :username,
    :user_timezone
  ]

  @doc """
  The schema fields `update_user_fields/2` routes OUT of `custom_fields` and
  writes through `profile_changeset`.

  Public so that callers filtering untrusted params against this rule read the
  list rather than restating it.
  """
  def updatable_profile_fields, do: @updatable_profile_fields

  @doc """
  Updates both schema and custom fields in a single call.

  This is a unified update function that automatically splits the provided
  attributes into schema fields and custom fields, updating both appropriately.

  ## Schema Fields
  - first_name, last_name, email, google_email, username, user_timezone

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

  ## ⚠️ This function does not authorize, and `email` is a credential

  A key named in `updatable_profile_fields/0` leaves `custom_fields` and is
  written to the schema — including `:email`, with **no** confirmation-token
  flow, and `:username`, which is the second credential
  `get_user_by_email_or_username_and_password/3` accepts. Whoever may call this
  may re-point the address a password-reset link is delivered to. Callers that
  build `attrs` from request params must filter those names first (see
  `PhoenixKitWeb.Users.UserForm`) or gate the call on
  `can_manage_user_credentials?/2`.
  """
  def update_user_fields(%User{} = user, attrs) when is_map(attrs) do
    updatable_profile_fields = updatable_profile_fields()

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

    update_user_custom_fields(
      user,
      drop_stale_avatar_crop(merged_custom_fields, existing_custom_fields, attrs)
    )
  end

  # A stored crop describes the file it was made against — its aspect ratio
  # is baked into the map — so a crop must never outlive its file: applied
  # to a different image it renders stretched and mis-framed everywhere.
  # Enforced HERE, at the one merge every custom-fields write goes through,
  # because every other enforcement point proved forgettable: the settings
  # page cleared the crop on a new pick, while the admin form and
  # update_user_avatar/4 did not. A caller that sets the crop alongside the
  # file (the settings crop editor) is explicit and wins.
  defp drop_stale_avatar_crop(merged, existing, attrs) do
    changed_file? =
      Map.has_key?(attrs, "avatar_file_uuid") and
        Map.get(attrs, "avatar_file_uuid") != Map.get(existing, "avatar_file_uuid")

    if changed_file? and not Map.has_key?(attrs, "avatar_crop") do
      Map.put(merged, "avatar_crop", nil)
    else
      merged
    end
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
  - `user_uuid` - The user UUID owning this file (defaults to user.uuid)

  ## Returns
  - `{:ok, user}` - Avatar saved successfully
  - `{:error, reason}` - File storage or update failed

  ## Examples

      # Store avatar in default location with automatic variant generation
      {:ok, updated_user} = Auth.update_user_avatar(user, "/tmp/upload_xyz", "avatar.jpg")

      # Store with explicit user_uuid (for custom workflows)
      {:ok, updated_user} = Auth.update_user_avatar(user, "/tmp/upload_xyz", "avatar.jpg", custom_user_uuid)

  ## Automatically Generated Variants
  The storage layer automatically generates these image variants:
  - original - Full-size image
  - large - 800x800px
  - medium - 400x400px
  - small - 200x200px
  - thumbnail - 100x100px
  """
  def update_user_avatar(%User{} = user, file_path, filename, user_uuid \\ nil) do
    user_uuid = user_uuid || user.uuid

    # Calculate file hash
    file_hash = calculate_file_hash(file_path)

    # Get file extension
    ext = Path.extname(filename) |> String.replace_leading(".", "")

    # Store file in buckets (automatically queues ProcessFileJob for variants)
    case Storage.store_file_in_buckets(
           file_path,
           "image",
           user_uuid,
           file_hash,
           ext,
           filename
         ) do
      {:ok, file} ->
        PhoenixKit.UploadsParentFolder.place(file, :avatar, user_uuid, user)

        # Save the file UUID to user's custom fields
        update_user_fields(user, %{"avatar_file_uuid" => file.uuid})

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

  Returns `{:error, :not_found}` (not a changeset error) if the user
  row was deleted concurrently — same contract as
  `merge_user_custom_fields/3`, which this delegates to.
  """
  def set_user_custom_field(%User{} = user, key, value) when is_binary(key) do
    # Delegates to the atomic merge rather than the historical
    # Map.put + whole-map replace, so a concurrent writer touching a
    # DIFFERENT key can no longer be silently overwritten — see
    # merge_user_custom_fields/3.
    merge_user_custom_fields(user, %{key => value})
  end

  @doc """
  Deletes a specific custom field for a user.

  Removes the key at the database level (`custom_fields - key`) — the
  removal counterpart to `merge_user_custom_fields/3`, with the same
  lost-update rationale: the historical Map.delete + whole-map replace
  could silently drop a key a concurrent writer had just merged in.
  Removing an absent key is a no-op that still returns `{:ok, user}`;
  returns `{:error, :not_found}` if the user row was deleted
  concurrently.

  ## Examples

      iex> delete_user_custom_field(user, "phone")
      {:ok, %User{}}
  """
  @spec delete_user_custom_field(User.t(), String.t(), keyword()) ::
          {:ok, User.t()} | {:error, :not_found}
  def delete_user_custom_field(%User{} = user, key, opts \\ []) when is_binary(key) do
    query =
      from(u in User,
        where: u.uuid == ^user.uuid,
        update: [
          set: [
            # COALESCE for the same NULL gap as the merge (`NULL - key`
            # stays NULL); also preserves the old path's side effect of
            # normalizing a NULL column to '{}' on any delete.
            custom_fields: fragment("COALESCE(?, '{}'::jsonb) - ?::text", u.custom_fields, ^key),
            updated_at: ^UtilsDate.utc_now()
          ]
        ],
        select: u
      )

    case Repo.update_all(query, []) do
      {1, [updated_user]} ->
        if Keyword.get(opts, :broadcast, true) do
          Events.broadcast_user_updated(updated_user)
        end

        {:ok, updated_user}

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates user status with Owner protection.

  Prevents deactivation of the last Owner to maintain system security.

  ## Authorization

  Pass `actor: %User{}` and the RANK rule is enforced here, in the context —
  the actor must outrank the target (`can_manage_user_status?/2`). Do that from
  every request-driven path. The rank check lived only in the admin edit form
  once, and the user-list and user-detail pages reached this function without
  it, so a role holding merely the `users` permission could deactivate an Admin
  or a non-last Owner from two of the three pages. Enforcing it here is what
  makes a fourth caller safe by construction.

  Omitting `:actor` means "system-initiated" and performs NO authorization —
  correct for `PhoenixKit.Users.Referrals` expiring an account, wrong for
  anything a user asked for. An `:actor` that is PRESENT but is not a `%User{}`
  is refused rather than read as absent: it is a caller that meant to supply an
  actor and got the shape wrong.

  ## Parameters

  - `user`: User to update
  - `attrs`: Status attributes (typically %{"is_active" => true/false})
  - `opts`: `:actor` — the `%User{}` performing the change, when there is one

  ## Examples

      iex> update_user_status(user, %{"is_active" => false}, actor: admin)
      {:ok, %User{}}

      iex> update_user_status(owner, %{"is_active" => false}, actor: admin)
      {:error, :insufficient_permissions}

      iex> update_user_status(last_owner, %{"is_active" => false})
      {:error, :cannot_deactivate_last_owner}
  """
  def update_user_status(user, attrs, opts \\ [])

  def update_user_status(%User{} = user, attrs, opts) do
    case Keyword.get(opts, :actor) do
      %User{} = actor ->
        if can_manage_user_status?(user, actor) do
          do_update_user_status_with_owner_guard(user, attrs)
        else
          {:error, :insufficient_permissions}
        end

      # Only an ABSENT actor is the system path — `PhoenixKit.Users.Referrals`
      # expires an account with no `:actor` at all, as do seeds and mix tasks. A
      # value that is present but not a `%User{}` (a map decoded from JSON by a
      # host controller, a bare uuid string) is a caller that meant to supply an
      # actor and got the shape wrong; treating that as "no actor" would hand it
      # the unchecked path. Fails closed, matching
      # `admin_update_user_password/3`.
      nil ->
        do_update_user_status_with_owner_guard(user, attrs)

      _malformed ->
        Logger.warning(
          "PhoenixKit: refused a status write for #{target_label(user)} — :actor was present but not a %User{}"
        )

        {:error, :insufficient_permissions}
    end
  end

  defp do_update_user_status_with_owner_guard(user, attrs) do
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
        Logger.warning("PhoenixKit: Attempted to deactivate last Owner user #{user.uuid}")
        {:error, :cannot_deactivate_last_owner}
    end
  end

  defp do_update_user_status(user, attrs) do
    case user
         |> User.status_changeset(attrs)
         |> Repo.update() do
      {:ok, updated_user} ->
        # Deactivation must REVOKE, not merely deny. Every gate that reads a
        # session runs `ensure_active_user/1`, so a deactivated user is bounced
        # from ordinary pages — but the token row itself survives for its full
        # 60-day life, and any entry point that resolves a token without that
        # filter still sees a live user behind it. Deleting the tokens here
        # makes "deactivate" mean what an operator cutting off a departing or
        # compromised account believes it means, and removes the standing
        # dependency on every present and future caller remembering the filter.
        if updated_user.is_active == false do
          delete_all_user_session_tokens(updated_user)
        end

        # Broadcast user status update event
        Events.broadcast_user_updated(updated_user)
        {:ok, updated_user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets a user by UUID with preloaded roles, organization, and the admin who
  created them (`created_by`, `nil` for a self-registered user).

  ## Examples

      iex> get_user_with_roles("01924...")
      %User{roles: [%Role{}, %Role{}]}

      iex> get_user_with_roles("nonexistent")
      nil
  """
  def get_user_with_roles(uuid) when is_binary(uuid) do
    from(u in User,
      where: u.uuid == ^uuid,
      preload: [:roles, :role_assignments, :organization, :created_by]
    )
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
    account_type_filter = Keyword.get(opts, :account_type)
    status_filter = Keyword.get(opts, :status)
    confirmation_filter = Keyword.get(opts, :confirmation)

    base_query = from(u in User, order_by: [desc: u.inserted_at])

    query =
      base_query
      |> maybe_filter_by_role(role_filter)
      |> maybe_filter_by_search(search_query)
      |> maybe_filter_by_account_type(account_type_filter)
      |> maybe_filter_by_status(status_filter)
      |> maybe_filter_by_confirmation(confirmation_filter)

    total_count = PhoenixKit.RepoHelper.aggregate(query, :count, :uuid)
    total_pages = Pagination.total_pages(total_count, page_size)

    users =
      query
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> preload([:roles, :role_assignments, :organization])
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
      distinct: u.uuid
  end

  defp maybe_filter_by_account_type(query, nil), do: query
  defp maybe_filter_by_account_type(query, "all"), do: query

  defp maybe_filter_by_account_type(query, account_type) when is_binary(account_type) do
    from([u] in query, where: u.account_type == ^account_type)
  end

  # `:status` and `:confirmation` mirror, exactly, the four counts
  # `PhoenixKit.Users.Roles.get_extended_stats/0` reports on the admin
  # dashboard (`is_active = true/false`, `confirmed_at IS NULL / NOT NULL`).
  # They exist so those cards can link to the list behind their number — a
  # filter that returned a different set than the card counted would be worse
  # than no link at all, so the predicates are deliberately identical.
  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, "all"), do: query
  defp maybe_filter_by_status(query, "active"), do: from([u] in query, where: u.is_active == true)

  defp maybe_filter_by_status(query, "inactive"),
    do: from([u] in query, where: u.is_active == false)

  defp maybe_filter_by_status(query, _unknown), do: query

  defp maybe_filter_by_confirmation(query, nil), do: query
  defp maybe_filter_by_confirmation(query, "all"), do: query

  defp maybe_filter_by_confirmation(query, "confirmed"),
    do: from([u] in query, where: not is_nil(u.confirmed_at))

  defp maybe_filter_by_confirmation(query, "pending"),
    do: from([u] in query, where: is_nil(u.confirmed_at))

  defp maybe_filter_by_confirmation(query, _unknown), do: query

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
  Gets a user by UUID with minimal fields for selection interfaces.

  Returns a user map with uuid, email, first_name, and last_name fields.
  Returns nil if user is not found.

  ## Examples

      iex> PhoenixKit.Users.Auth.get_user_for_selection("01924...")
      %{uuid: "01924...", email: "user@example.com", first_name: "John", last_name: "Doe"}

      iex> PhoenixKit.Users.Auth.get_user_for_selection("nonexistent")
      nil
  """
  def get_user_for_selection(user_uuid) when is_binary(user_uuid) do
    from(u in User,
      where: u.uuid == ^user_uuid,
      select: %{
        uuid: u.uuid,
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
  Gets a single admin note by UUID.

  Preloads the author information.

  ## Examples

      iex> get_admin_note("01924...")
      %AdminNote{}

      iex> get_admin_note("nonexistent")
      nil

  """
  def get_admin_note(uuid) when is_binary(uuid) do
    from(n in AdminNote,
      where: n.uuid == ^uuid,
      preload: [:author]
    )
    |> Repo.one()
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
      |> Map.put("user_uuid", user.uuid)
      |> Map.put("author_uuid", author.uuid)

    %AdminNote{}
    |> AdminNote.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, note} ->
        PhoenixKit.Activity.log(%{
          action: "user.note_created",
          module: "users",
          mode: "manual",
          actor_uuid: author.uuid,
          resource_type: "user",
          resource_uuid: user.uuid,
          target_uuid: user.uuid,
          metadata: %{"actor_role" => "admin"}
        })

        {:ok, Repo.preload(note, :author)}

      error ->
        error
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
  def delete_admin_note(%AdminNote{} = note, admin \\ nil) do
    case Repo.delete(note) do
      {:ok, deleted} ->
        PhoenixKit.Activity.log(%{
          action: "user.note_deleted",
          module: "users",
          mode: "manual",
          actor_uuid: admin && admin.uuid,
          resource_type: "user",
          resource_uuid: note.user_uuid,
          target_uuid: note.user_uuid,
          metadata: %{"actor_role" => "admin"}
        })

        {:ok, deleted}

      error ->
        error
    end
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
  Read-only preview of what `delete_user/2` would do to `user` — the exact
  per-category record counts for a delete-confirmation screen, computed
  the same defensive, module-optional way the real deletion counts them
  (via `Code.ensure_loaded?/1`, never raising for a module that isn't
  installed), but without writing anything. Keep the category list in
  sync with `delete_cascade_data/1` and `anonymize_user_data/1` if either
  changes — this does not derive from them, to avoid adding a "preview
  mode" to code that runs on every real deletion.

  ## Returns

  `%{delete: [{label, count}, ...], anonymize: [{label, count}, ...]}` —
  every category is included even at `0`, so the admin sees a complete,
  accurate picture rather than a list that silently omits what doesn't
  apply to this particular user.

  ## Examples

      iex> preview_user_deletion(user)
      %{
        delete: [{"Session and other tokens", 2}, {"Role assignments", 1}, ...],
        anonymize: [{"Orders", 0}, {"Posts", 3}, ...]
      }
  """
  @spec preview_user_deletion(User.t()) :: %{
          delete: [{String.t(), non_neg_integer()}],
          anonymize: [{String.t(), non_neg_integer()}]
        }
  def preview_user_deletion(%User{uuid: user_uuid}) do
    %{
      delete: [
        {gettext("Session and other tokens"), count_schema(UserToken, user_uuid)},
        {gettext("Role assignments"), count_schema(PhoenixKit.Users.RoleAssignment, user_uuid)},
        {gettext("OAuth connections"), count_schema(PhoenixKit.Users.OAuthProvider, user_uuid)},
        {gettext("Billing profiles"),
         count_optional_schema(PhoenixKitBilling.BillingProfile, user_uuid)},
        {gettext("Shopping carts"), count_optional_schema(PhoenixKitEcommerce.Cart, user_uuid)},
        {gettext("Admin notes"), count_schema(AdminNote, user_uuid)}
      ],
      anonymize: [
        {gettext("Orders"),
         count_optional_schema(Module.concat([PhoenixKit, Modules, Shop, Order]), user_uuid)},
        {gettext("Posts"),
         count_optional_schema(Module.concat([PhoenixKit, Modules, Posts, Post]), user_uuid)},
        {gettext("Comments"),
         count_optional_schema(
           Module.concat([PhoenixKit, Modules, Posts, PostComment]),
           user_uuid
         ) +
           count_optional_schema(
             Module.concat([PhoenixKit, Modules, Comments, Comment]),
             user_uuid
           )},
        {gettext("Support tickets"),
         count_optional_schema(Module.concat([PhoenixKitCustomerSupport, Ticket]), user_uuid)},
        {gettext("Email logs"),
         count_optional_schema(Module.concat([PhoenixKit, Modules, Emails, Log]), user_uuid)},
        {gettext("Files"),
         count_optional_schema(Module.concat([PhoenixKit, Modules, Storage, File]), user_uuid)}
      ]
    }
  end

  # A core schema that always exists — no optional-module guard needed,
  # matching `delete_user_oauth_providers/1` and `delete_user_admin_notes/1`.
  defp count_schema(module, user_uuid) do
    from(r in module, where: r.user_uuid == ^user_uuid)
    |> Repo.repo().aggregate(:count)
  end

  # A module belonging to an optional dependency or feature module — absent
  # entirely on a host that hasn't installed it, exactly like every
  # `anonymize_user_*`/`delete_user_*` counterpart this mirrors.
  defp count_optional_schema(module, user_uuid) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      from(r in module, where: r.user_uuid == ^user_uuid)
      |> Repo.repo().aggregate(:count)
    else
      0
    end
  rescue
    _ -> 0
  end

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
  - Orders - SET NULL on user_uuid, preserve financial records
  - Posts - Keep content, set user_uuid to NULL, mark as deleted author
  - Comments - Keep content, set user_uuid to NULL, mark as deleted author
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

  - `{:ok, %{deleted_user_uuid: uuid, anonymized_records: count}}` - Success
  - `{:error, :cannot_delete_self}` - Cannot delete your own account
  - `{:error, :cannot_delete_last_owner}` - Cannot delete the last Owner
  - `{:error, :insufficient_permissions}` - Current user lacks permission
  - `{:error, reason}` - Other errors

  ## Examples

      iex> delete_user(user, %{current_user: admin_user})
      {:ok, %{deleted_user_uuid: "some-uuid", anonymized_records: 15}}

      iex> delete_user(user, %{current_user: user})
      {:error, :cannot_delete_self}

      iex> delete_user(last_owner, %{current_user: admin_user})
      {:error, :cannot_delete_last_owner}

      iex> delete_user(admin_user, %{current_user: non_owner_admin})
      {:error, :insufficient_permissions}
  """
  def delete_user(%User{} = user, opts \\ %{}) do
    current_user = Map.get(opts, :current_user)

    with :ok <- validate_can_delete_user(user, current_user) do
      # Module lifecycle hooks run BEFORE the row delete, while the
      # user's related rows (memberships, assignments) still exist —
      # remediation the DB cascades can't do (ownership succession,
      # orphan audit trails). Best-effort: a raising hook never aborts.
      # Hooks run OUTSIDE the delete transaction, deliberately: a hook's
      # own writes (succession promotions, audit rows) must survive even
      # if they use a different repo/pool. Accepted tradeoff: if the
      # delete itself then fails, hook side-effects have already
      # committed (e.g. an extra owner) — rare, admin-recoverable, and
      # preferable to hooks silently vanishing with a rollback.
      run_before_user_delete_hooks(user.uuid)

      do_delete_user(user, opts, current_user)
    end
  end

  defp do_delete_user(user, opts, current_user) do
    with {:ok, result} <- execute_user_deletion(user, opts) do
      PhoenixKit.Activity.log(%{
        action: "user.deleted",
        module: "users",
        mode: "manual",
        actor_uuid: current_user && current_user.uuid,
        resource_type: "user",
        resource_uuid: user.uuid,
        target_uuid: user.uuid,
        metadata: %{"deleted_email" => user.email, "actor_role" => "admin"}
      })

      {:ok, result}
    end
  end

  @doc """
  Runs every discovered module's optional `before_user_delete/1` hook.
  Public with an injectable module list so the dispatch is testable;
  production callers use the discovered default.
  """
  def run_before_user_delete_hooks(user_uuid, modules \\ nil) do
    (modules || PhoenixKit.ModuleRegistry.all_modules())
    |> Enum.each(fn module ->
      if Code.ensure_loaded?(module) and function_exported?(module, :before_user_delete, 1) do
        try do
          module.before_user_delete(user_uuid)
        rescue
          e ->
            require Logger

            Logger.error(
              "before_user_delete hook #{inspect(module)} failed: #{Exception.message(e)}"
            )
        catch
          # `kind, reason` (not just :exit) — a hook that THROWS must not
          # abort the deletion either.
          kind, reason ->
            require Logger

            Logger.error("before_user_delete hook #{inspect(module)} #{kind}: #{inspect(reason)}")
        end
      end
    end)

    :ok
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

  # Validates deletion permissions and constraints.
  #
  # Rule 3 used to be the whole authority check and it was two rules short: it
  # only refused an ADMIN target, so an Owner who was not the last Owner could
  # be deleted by an Admin, and it never asked whether the actor held a staff
  # role at all — the comment deferred that to "the controller/LiveView", where
  # the gate is `can_access_admin_area?/1`, true for any holder of a single
  # permission. Deleting an account is at least as final as taking it over, so
  # it now answers to the same rank rule as credentials and status.
  defp validate_can_delete_user(%User{} = user, %User{} = current_user) do
    cond do
      # Rule 1: Cannot delete self
      user.uuid == current_user.uuid ->
        {:error, :cannot_delete_self}

      # Rule 2: Cannot delete last Owner (a target-only rule, checked first so
      # the last-Owner message survives even for an actor who outranks them)
      has_system_role?(user, Role.system_roles().owner) and
          count_remaining_owners(user.uuid) < 1 ->
        {:error, :cannot_delete_last_owner}

      # Rule 3: the shared rank rule — staff only, and never upwards
      true ->
        validate_admin_authority_over(user, current_user)
    end
  end

  defp validate_can_delete_user(_user, _current_user) do
    {:error, :invalid_current_user}
  end

  @doc """
  True when `current_user` may manage `user`'s credentials — set a new password,
  send a password-reset mail, or change the address those mails are delivered to.

  Credential management is the one admin action that hands over an account, so it
  is decided by ROLE and by RANK, not by the `users` permission that admits a
  visitor to the user pages. Holding `users` answers "may this person administer
  users at all"; it must never answer "may this person take over that particular
  account". The rules mirror `can_delete_user?/2` (only an Owner acts on an
  Admin) and the impersonation authority in `PhoenixKitWeb.Users.MultiSession`
  (an Owner is never a target for anyone but themselves), so the three
  account-takeover surfaces agree.

  1. Your own account is always yours to manage.
  2. The actor must hold Owner or Admin **by role**.
  3. An Owner target may be managed only by an Owner.
  4. An Admin target may be managed only by an Owner.

  Everything else — an ordinary user changing their own password — belongs on
  their own settings page, not here.

  ## Examples

      iex> can_manage_user_credentials?(some_user, admin)
      true

      iex> can_manage_user_credentials?(owner, admin)
      false
  """
  def can_manage_user_credentials?(%User{} = user, %User{} = current_user) do
    case validate_admin_authority_over(user, current_user) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  def can_manage_user_credentials?(_user, _current_user), do: false

  @doc """
  True when `current_user` may activate or deactivate `user`.

  Same authority as `can_manage_user_credentials?/2`, for the same reason:
  deactivation is decided by rank, not by the `users` permission that admits a
  visitor to the user pages. Without it a role holding only `users` can switch
  off an Admin — or a non-last Owner — which is a denial of service against the
  accounts that are meant to outrank it.

  Unlike credential management, **your own status is not yours to change**. The
  admin UI has always said so ("You cannot deactivate your own account for
  security reasons") but two of the three pages enforced it only in the
  template, and the third not at all — so the rule lived in markup a client
  composes for itself. It lives here now.

  The last-Owner protection in `Roles.can_deactivate_user?/1` is a separate,
  target-only rule and still applies on top of this one.
  """
  def can_manage_user_status?(%User{uuid: uuid}, %User{uuid: uuid}), do: false

  def can_manage_user_status?(%User{} = user, %User{} = current_user) do
    case validate_admin_authority_over(user, current_user) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  def can_manage_user_status?(_user, _current_user), do: false

  # The shared rank rule behind every administrative action taken ON an account
  # rather than BY one. Kept private and expressed as `:ok | {:error, reason}`
  # so a caller that needs to explain the refusal can be given a public wrapper
  # without changing the decision itself.
  defp validate_admin_authority_over(%User{} = user, %User{} = current_user) do
    roles = Role.system_roles()
    actor_is_owner = has_system_role?(current_user, roles.owner)

    cond do
      user.uuid == current_user.uuid ->
        :ok

      not (actor_is_owner or has_system_role?(current_user, roles.admin)) ->
        {:error, :insufficient_permissions}

      has_system_role?(user, roles.owner) and not actor_is_owner ->
        {:error, :target_is_owner}

      has_system_role?(user, roles.admin) and not actor_is_owner ->
        {:error, :target_is_staff}

      true ->
        :ok
    end
  end

  # Reads the role set from a preloaded `:roles` association when the caller
  # already has one, and only queries when it does not.
  #
  # This rule runs once per rendered row on `/admin/users`, and each evaluation
  # asks up to four role questions — as four `EXISTS` queries that is 200 round
  # trips on a fifty-row page, repeated on every sort, filter and PubSub
  # re-render. `list_users_paginated/1` already preloads `:roles`, so the rows
  # carry the answer; the templates additionally hand in an actor loaded the
  # same way. Preloaded assignments are the live set — an inactive assignment
  # is deleted, not flagged — so the two paths agree.
  defp has_system_role?(%User{roles: roles}, role_name) when is_list(roles) do
    Enum.any?(roles, &(&1.name == role_name))
  end

  defp has_system_role?(%User{} = user, role_name) do
    Roles.user_has_role?(user, role_name)
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
      select: count(u.uuid)
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

          %{deleted_user_uuid: user.uuid, anonymized_records: anonymized_count}

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

    # Delete the user's PERSONAL integration connections. These live in
    # phoenix_kit_settings JSONB (owner_uuid) with no FK, so they must be
    # cleaned up explicitly or they'd orphan the user's encrypted credentials.
    delete_user_personal_integrations(user.uuid)

    # Trash the storage libraries the user owns (their files are purged by
    # a job). The database refuses to delete a user whose live library
    # still names them, so this step cannot be skipped (V203).
    {:ok, _count} = Libraries.trash_owned_libraries(user.uuid)

    :ok
  end

  # Delete a user's personal integration connections (owner_uuid in JSONB).
  defp delete_user_personal_integrations(user_uuid) do
    from(s in PhoenixKit.Settings.Setting,
      where: s.module == "integrations",
      where: fragment("?->>'owner_uuid' = ?", s.value_json, ^user_uuid)
    )
    |> Repo.repo().delete_all()
  end

  # Delete OAuth providers for a user (uses user_uuid for safety)
  defp delete_user_oauth_providers(user_uuid) do
    from(op in PhoenixKit.Users.OAuthProvider, where: op.user_uuid == ^user_uuid)
    |> Repo.repo().delete_all()
  end

  # Delete billing profiles for a user (uses user_uuid for safety)
  defp delete_user_billing_profiles(user_uuid) do
    if Code.ensure_loaded?(PhoenixKitBilling) do
      billing_profile_schema = PhoenixKitBilling.BillingProfile

      from(bp in billing_profile_schema, where: bp.user_uuid == ^user_uuid)
      |> Repo.repo().delete_all()
    end
  end

  # Delete shop carts for a user (uses user_uuid for safety)
  defp delete_user_shop_carts(user_uuid) do
    if Code.ensure_loaded?(PhoenixKitEcommerce.Cart) do
      from(c in PhoenixKitEcommerce.Cart, where: c.user_uuid == ^user_uuid)
      |> Repo.repo().delete_all()
    end
  end

  # Delete admin notes for a user (uses user_uuid for safety)
  defp delete_user_admin_notes(user_uuid) do
    from(an in AdminNote, where: an.user_uuid == ^user_uuid)
    |> Repo.repo().delete_all()
  end

  # Anonymize data that should be preserved but without PII
  defp anonymize_user_data(%User{} = user) do
    anonymized_count = 0

    # Anonymize orders - set user_uuid to NULL
    orders_count = anonymize_user_orders(user.uuid)

    # Anonymize posts - set user_uuid to NULL, mark as deleted author
    posts_count = anonymize_user_posts(user.uuid)

    # Anonymize comments - set user_uuid to NULL, mark as deleted author
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

  # Anonymize orders by setting user_uuid to NULL
  defp anonymize_user_orders(user_uuid) do
    # Check if Orders module exists and has the schema
    # Note: Order schema doesn't exist in Shop module yet - this is for future compatibility
    module = Module.concat([PhoenixKit, Modules, Shop, Order])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([o], o.user_uuid == ^user_uuid)

      from(o in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_uuid: nil,
          anonymized_at: UtilsDate.utc_now()
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize posts by setting user_uuid to NULL and marking deleted author
  defp anonymize_user_posts(user_uuid) do
    module = Module.concat([PhoenixKit, Modules, Posts, Post])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([p], p.user_uuid == ^user_uuid)

      from(p in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_uuid: nil,
          author_deleted: true,
          anonymized_at: UtilsDate.utc_now()
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize comments by setting user_uuid to NULL and marking deleted author
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
          user_uuid: nil,
          author_deleted: true,
          anonymized_at: UtilsDate.utc_now()
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
      |> Repo.repo().update_all(set: [user_uuid: nil])
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Anonymize tickets for support history
  defp anonymize_user_tickets(user_uuid) do
    module = Module.concat([PhoenixKitCustomerSupport, Ticket])

    if Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      dynamic_query = dynamic([t], t.user_uuid == ^user_uuid)

      from(t in module, where: ^dynamic_query)
      |> Repo.repo().update_all(
        set: [
          user_uuid: nil,
          anonymized_at: UtilsDate.utc_now(),
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
          user_uuid: nil,
          anonymized_at: UtilsDate.utc_now()
        ]
      )
      |> elem(0)
    else
      0
    end
  rescue
    _ -> 0
  end

  # The files the user uploaded stay where they are, with no uploader: in
  # the site's libraries and in other people's (the FK is `SET NULL` since
  # V203, which does the same on the row delete; this counts them). Their
  # own libraries were trashed in `delete_cascade_data/1`.
  defp anonymize_user_files(user_uuid) do
    from(f in PhoenixKit.Modules.Storage.File, where: f.user_uuid == ^user_uuid)
    |> Repo.repo().update_all(set: [user_uuid: nil])
    |> elem(0)
  end

  # Log user deletion for audit purposes
  defp log_user_deletion(%User{} = user, opts, anonymized_count) do
    current_user = Map.get(opts, :current_user)
    ip_address = Map.get(opts, :ip_address)
    user_agent = Map.get(opts, :user_agent)

    Logger.info(
      "PhoenixKit: User #{user.uuid} (#{user.email}) deleted by " <>
        "#{if current_user, do: "admin #{current_user.uuid} (#{current_user.email})", else: "system"}. " <>
        "Anonymized #{anonymized_count} records."
    )

    # If audit log module is available, log there too
    audit_module = Module.concat([PhoenixKit, AuditLog])

    if Code.ensure_loaded?(audit_module) and
         function_exported?(audit_module, :create_log_entry, 1) do
      log_attrs = %{
        target_user_uuid: user.uuid,
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
