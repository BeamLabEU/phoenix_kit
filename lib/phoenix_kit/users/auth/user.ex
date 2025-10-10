defmodule PhoenixKit.Users.Auth.User do
  @moduledoc """
  User schema for PhoenixKit authentication system.

  This schema defines the core user entity with email-based authentication and account management features.

  ## Fields

  - `email`: User's email address (unique, required for authentication)
  - `password`: Virtual field for password input (redacted in logs)
  - `hashed_password`: Bcrypt-hashed password stored in database (redacted)
  - `current_password`: Virtual field for password confirmation (redacted)
  - `confirmed_at`: Timestamp when email was confirmed (nil for unconfirmed accounts)

  ## Security Features

  - Password hashing with bcrypt
  - Email uniqueness enforcement
  - Password strength validation
  - Sensitive field redaction in logs
  - Email confirmation workflow support
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Users.Roles

  # Fields excluded from get_user_field for security/internal reasons
  @excluded_fields ~w(password current_password hashed_password __meta__ __struct__)a

  @type t :: %__MODULE__{
          id: integer() | nil,
          email: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t(),
          current_password: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          is_active: boolean(),
          confirmed_at: NaiveDateTime.t() | nil,
          user_timezone: String.t() | nil,
          registration_ip: String.t() | nil,
          registration_country: String.t() | nil,
          registration_region: String.t() | nil,
          registration_city: String.t() | nil,
          custom_fields: map() | nil,
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  schema "phoenix_kit_users" do
    field :email, :string
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :first_name, :string
    field :last_name, :string
    field :is_active, :boolean, default: true
    field :confirmed_at, :naive_datetime
    field :user_timezone, :string
    field :registration_ip, :string
    field :registration_country, :string
    field :registration_region, :string
    field :registration_city, :string
    field :custom_fields, :map, default: %{}

    has_many :role_assignments, PhoenixKit.Users.RoleAssignment
    many_to_many :roles, PhoenixKit.Users.Role, join_through: PhoenixKit.Users.RoleAssignment

    timestamps()
  end

  @doc """
  A user changeset for registration.

  It is important to validate the length of both email and password.
  Otherwise databases may truncate the email without warnings, which
  could lead to unpredictable or insecure behaviour. Long passwords may
  also be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.

    * `:validate_email` - Validates the uniqueness of the email, in case
      you don't want to validate the uniqueness of the email (like when
      using this changeset for validations on a LiveView form before
      submitting the form), this option can be set to `false`.
      Defaults to `true`.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [
      :email,
      :username,
      :password,
      :first_name,
      :last_name,
      :registration_ip,
      :registration_country,
      :registration_region,
      :registration_city
    ])
    |> validate_email(opts)
    |> validate_username(opts)
    |> validate_password(opts)
    |> validate_names()
    |> validate_registration_fields()
    |> maybe_generate_username_from_email()
    |> set_default_active_status()
  end

  defp validate_email(changeset, opts) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> maybe_validate_unique_email(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp maybe_validate_unique_email(changeset, opts) do
    if Keyword.get(opts, :validate_email, true) do
      changeset
      |> unsafe_validate_unique(:email, PhoenixKit.RepoHelper.repo())
      |> unique_constraint(:email)
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the email.

  It requires the email to change otherwise an error is added.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
    |> case do
      %{changes: %{email: _}} = changeset -> changeset
      %{} = changeset -> add_error(changeset, :email, "did not change")
    end
  end

  @doc """
  A user changeset for changing the password.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Unconfirms the account by setting `confirmed_at` to nil.
  """
  def unconfirm_changeset(user) do
    change(user, confirmed_at: nil)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%PhoenixKit.Users.Auth.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Validates the current password otherwise adds an error to the changeset.
  """
  def validate_current_password(changeset, password) do
    changeset = cast(changeset, %{current_password: password}, [:current_password])

    if valid_password?(changeset.data, password) do
      changeset
    else
      add_error(changeset, :current_password, "is not valid")
    end
  end

  @doc """
  A user changeset for updating profile information.

  ## Options

    * `:validate_email` - Validates the uniqueness of the email, in case
      you don't want to validate the uniqueness of the email (like when
      using this changeset for validations on a LiveView form before
      submitting the form), this option can be set to `false`.
      Defaults to `true`.
  """
  def profile_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:first_name, :last_name, :email, :username, :user_timezone])
    |> validate_names()
    |> validate_email(opts)
    |> validate_username(opts)
    |> validate_user_timezone()
  end

  @doc """
  A user changeset for updating active status.
  """
  def status_changeset(user, attrs) do
    user
    |> cast(attrs, [:is_active])
    |> validate_inclusion(:is_active, [true, false])
    |> validate_owner_cannot_be_deactivated()
  end

  @doc """
  A user changeset for updating timezone preference.

  ## Examples

      iex> timezone_changeset(user, %{"user_timezone" => "+5"})
      %Ecto.Changeset{valid?: true}

      iex> timezone_changeset(user, %{"user_timezone" => "invalid"})
      %Ecto.Changeset{valid?: false}
  """
  def timezone_changeset(user, attrs) do
    user
    |> cast(attrs, [:user_timezone])
    |> validate_user_timezone()
  end

  @doc """
  A user changeset for updating custom fields.

  Custom fields are stored as JSONB and can contain arbitrary key-value pairs.

  ## Examples

      iex> custom_fields_changeset(user, %{custom_fields: %{"phone" => "555-1234"}})
      %Ecto.Changeset{valid?: true}

      iex> custom_fields_changeset(user, %{custom_fields: "invalid"})
      %Ecto.Changeset{valid?: false}
  """
  def custom_fields_changeset(user, attrs) do
    user
    |> cast(attrs, [:custom_fields])
    |> validate_custom_fields()
  end

  @doc """
  Checks if a user has a specific role.

  ## Examples

      iex> has_role?(user, "Admin")
      true

      iex> has_role?(user, "Owner")
      false
  """
  def has_role?(%__MODULE__{} = user, role_name) when is_binary(role_name) do
    Roles.user_has_role?(user, role_name)
  end

  @doc """
  Checks if a user is an owner.

  ## Examples

      iex> owner?(user)
      true
  """
  def owner?(%__MODULE__{} = user) do
    Roles.user_has_role_owner?(user)
  end

  @doc """
  Checks if a user is an admin or owner.

  ## Examples

      iex> admin?(user)
      true
  """
  def admin?(%__MODULE__{} = user) do
    Roles.user_has_role_admin?(user)
  end

  @doc """
  Gets all roles for a user.

  ## Examples

      iex> get_roles(user)
      ["Admin", "User"]
  """
  def get_roles(%__MODULE__{} = user) do
    Roles.get_user_roles(user)
  end

  @doc """
  Returns list of fields excluded from get_user_field for security.

  These fields contain sensitive or internal data and should not be
  accessed via the generic field accessor.

  ## Examples

      iex> excluded_fields()
      [:password, :current_password, :hashed_password, :__meta__, :__struct__]
  """
  def excluded_fields, do: @excluded_fields

  @doc """
  Gets the user's full name by combining first and last name.

  ## Examples

      iex> full_name(%User{first_name: "John", last_name: "Doe"})
      "John Doe"

      iex> full_name(%User{first_name: "John", last_name: nil})
      "John"

      iex> full_name(%User{first_name: nil, last_name: nil})
      nil
  """
  def full_name(%__MODULE__{first_name: first_name, last_name: last_name}) do
    case {first_name, last_name} do
      {nil, nil} -> nil
      {first, nil} -> String.trim(first)
      {nil, last} -> String.trim(last)
      {first, last} -> String.trim("#{first} #{last}")
    end
  end

  defp validate_names(changeset) do
    changeset
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
  end

  defp validate_registration_fields(changeset) do
    changeset
    |> validate_length(:registration_ip, max: 45)
    |> validate_length(:registration_country, max: 100)
    |> validate_length(:registration_region, max: 100)
    |> validate_length(:registration_city, max: 100)
  end

  defp validate_username(changeset, opts) do
    changeset
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z][a-zA-Z0-9_]*$/,
      message: "must start with a letter and contain only letters, numbers, and underscores"
    )
    |> maybe_validate_unique_username(opts)
  end

  defp maybe_validate_unique_username(changeset, opts) do
    if Keyword.get(opts, :validate_email, true) do
      # Only validate uniqueness if username is provided
      case get_change(changeset, :username) do
        nil ->
          changeset

        _username ->
          changeset
          |> unsafe_validate_unique(:username, PhoenixKit.RepoHelper.repo())
          |> unique_constraint(:username, name: :phoenix_kit_users_username_uidx)
      end
    else
      changeset
    end
  end

  defp maybe_generate_username_from_email(changeset) do
    username = get_change(changeset, :username)
    email = get_change(changeset, :email) || get_field(changeset, :email)

    # Only generate username if not provided and email is present
    case {username, email} do
      {nil, email} when is_binary(email) ->
        generated_username = generate_username_from_email(email)
        put_change(changeset, :username, generated_username)

      _ ->
        changeset
    end
  end

  @doc """
  Generate a username from an email address.

  Takes the part before @ symbol, converts to lowercase, replaces dots with underscores,
  and ensures it meets validation requirements.

  ## Examples

      iex> generate_username_from_email("john.doe@example.com")
      "john_doe"

      iex> generate_username_from_email("user@example.com")
      "user"
  """
  def generate_username_from_email(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.downcase()
    |> String.replace(".", "_")
    |> clean_username()
  end

  def generate_username_from_email(_), do: nil

  # Clean username to ensure it meets validation rules
  defp clean_username(username) do
    # Remove any invalid characters and ensure it starts with a letter
    cleaned =
      username
      |> String.replace(~r/[^a-zA-Z0-9_]/, "")
      # Max length
      |> String.slice(0, 30)

    # Ensure it starts with a letter
    case String.match?(cleaned, ~r/^[a-zA-Z]/) do
      true -> cleaned
      # Leave room for "user_" prefix
      false -> "user_" <> String.slice(cleaned, 0, 25)
    end
    |> ensure_minimum_username_length()
  end

  # Ensure username meets minimum length requirement
  defp ensure_minimum_username_length(username) when byte_size(username) >= 3, do: username
  defp ensure_minimum_username_length(username), do: username <> "_1"

  # Prevent deactivating Owner users
  defp validate_owner_cannot_be_deactivated(changeset) do
    user = changeset.data
    is_active = get_field(changeset, :is_active)

    if is_active == false && owner?(user) do
      add_error(changeset, :is_active, "owner cannot be deactivated")
    else
      changeset
    end
  end

  # Validates user timezone offset is within acceptable range or nil
  defp validate_user_timezone(changeset) do
    case get_change(changeset, :user_timezone) do
      nil ->
        # Allow nil (fallback to system timezone)
        changeset

      "" ->
        # Convert empty string to nil for consistent storage
        put_change(changeset, :user_timezone, nil)

      timezone when is_binary(timezone) ->
        trimmed_timezone = String.trim(timezone)

        if trimmed_timezone == "" do
          put_change(changeset, :user_timezone, nil)
        else
          validate_timezone_offset(changeset, trimmed_timezone)
        end

      _ ->
        add_error(changeset, :user_timezone, "must be a valid timezone offset")
    end
  end

  # Helper function to validate timezone offset format and range
  defp validate_timezone_offset(changeset, timezone) do
    case Integer.parse(timezone) do
      {offset, ""} when offset >= -12 and offset <= 12 ->
        changeset

      _ ->
        add_error(
          changeset,
          :user_timezone,
          "must be a valid timezone offset between -12 and +12"
        )
    end
  end

  # Sets the default active status for new user registrations based on system settings
  # Reads from "new_user_default_status" setting, defaults to true if not set
  defp set_default_active_status(changeset) do
    # Get the default status from settings (string "true" or "false")
    default_status_str = PhoenixKit.Settings.get_setting("new_user_default_status", "true")
    default_status = default_status_str == "true"

    # Set is_active field if not already set
    case get_change(changeset, :is_active) do
      nil -> put_change(changeset, :is_active, default_status)
      _ -> changeset
    end
  end

  # Validates custom_fields is a map
  defp validate_custom_fields(changeset) do
    case get_change(changeset, :custom_fields) do
      nil -> changeset
      value when is_map(value) -> changeset
      _ -> add_error(changeset, :custom_fields, "must be a valid map")
    end
  end
end
