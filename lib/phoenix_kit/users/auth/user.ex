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
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Slug
  alias PhoenixKit.Utils.TimeZone

  # Fields excluded from get_user_field for security/internal reasons
  @excluded_fields ~w(password current_password hashed_password __meta__ __struct__)a

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          email: String.t(),
          google_email: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t(),
          current_password: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          is_active: boolean(),
          api_only: boolean(),
          managed_by_members: boolean(),
          contact_email: String.t() | nil,
          acting_user_uuid: UUIDv7.t() | nil,
          confirmed_at: DateTime.t() | nil,
          user_timezone: String.t() | nil,
          registration_ip: String.t() | nil,
          registration_country: String.t() | nil,
          country: String.t() | nil,
          registration_region: String.t() | nil,
          registration_city: String.t() | nil,
          custom_fields: map() | nil,
          account_type: String.t(),
          organization_name: String.t() | nil,
          organization_uuid: UUIDv7.t() | nil,
          created_by_uuid: UUIDv7.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_users" do
    field :email, :string
    field :google_email, :string
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :first_name, :string
    field :last_name, :string
    field :is_active, :boolean, default: true
    # A service user (`PhoenixKit.API.ServiceUsers`): owns API keys, never signs in on the
    # web. Every web authentication door refuses it. Written only by core code that
    # creates a service user - never add it to a `cast/3` list, or a form could mint one.
    field :api_only, :boolean, default: false
    # Internal account policy; never cast from public profile/registration input.
    field :managed_by_members, :boolean, default: false
    field :contact_email, :string
    field :confirmed_at, :utc_datetime
    field :user_timezone, :string
    field :registration_ip, :string
    field :registration_country, :string
    # Where the person lives / the company is based (ISO 3166-1 alpha-2); decides
    # how dates are written for the account. See `PhoenixKit.Users.FormatCountry`.
    field :country, :string
    field :registration_region, :string
    field :registration_city, :string
    field :custom_fields, :map, default: %{}
    field :account_type, :string, default: "person"
    field :organization_name, :string
    field :organization_uuid, UUIDv7
    # The role the CURRENT SESSION acts as (`PhoenixKit.Users.ActiveRole`).
    # Filled only by `UserToken.verify_session_token_query/1` (and its twin by token
    # row id, `verify_session_token_uuid_query/1`) from the session token's
    # `active_role_uuid`; `nil` for a session that never switched AND
    # for a user loaded any other way — both resolve to the DEFAULT role
    # (never to the union) in `Scope.for_user/1`.
    field :active_role_uuid, :string, virtual: true
    # Provenance is filled only by the session query, never by a uuid lookup.
    field :acting_user_uuid, UUIDv7, virtual: true
    field :acting_session_uuid, UUIDv7, virtual: true
    field :organization_manager_uuid, UUIDv7, virtual: true

    has_many :role_assignments, PhoenixKit.Users.RoleAssignment,
      foreign_key: :user_uuid,
      references: :uuid

    many_to_many :roles, PhoenixKit.Users.Role,
      join_through: PhoenixKit.Users.RoleAssignment,
      join_keys: [user_uuid: :uuid, role_uuid: :uuid]

    belongs_to :organization, __MODULE__,
      foreign_key: :organization_uuid,
      references: :uuid,
      type: UUIDv7,
      define_field: false

    has_many :members, __MODULE__,
      foreign_key: :organization_uuid,
      references: :uuid

    # The admin who added this user from the admin panel; `nil` for a user who
    # signed themselves up. Written only by `Auth.admin_create_user/2` — never
    # add it to a `cast/3` list, or a public form could claim to have been
    # added by anyone.
    belongs_to :created_by, __MODULE__,
      foreign_key: :created_by_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
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

  An optional `:custom_fields` map may be included in `attrs` to persist
  arbitrary key-value metadata alongside the user record in a single atomic
  insert. If omitted, `custom_fields` defaults to `%{}`.
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
      :registration_city,
      :country,
      :custom_fields,
      :account_type,
      :organization_name,
      :user_timezone,
      :google_email
    ])
    |> validate_email(opts)
    |> validate_google_email()
    |> validate_username(opts)
    |> validate_password(opts)
    |> validate_names()
    |> validate_registration_fields()
    |> validate_custom_fields()
    |> validate_user_timezone()
    |> validate_country()
    |> start_country_from_registration()
    |> maybe_skip_names_for_organization()
    |> maybe_generate_username_from_email()
    |> set_default_active_status()
  end

  @doc """
  A user changeset for guest checkout.

  Creates a temporary user with a random password for guests who
  complete checkout without registering. The user will have
  `confirmed_at = nil` until they verify their email.

  ## Features

  - Generates a random secure password (required by DB constraint)
  - Sets `custom_fields.source` to "guest_checkout" for tracking
  - Generates UUID and username automatically
  - Does NOT confirm the email (confirmed_at remains nil)

  ## Examples

      iex> guest_user_changeset(%User{}, %{email: "guest@example.com", first_name: "John"})
      %Ecto.Changeset{valid?: true}
  """
  def guest_user_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :first_name, :last_name])
    |> validate_required([:email])
    |> validate_email(validate_email: true)
    |> put_random_password()
    |> put_guest_checkout_source()
    |> maybe_generate_username_from_email()
    |> set_default_active_status()
  end

  # Generates a cryptographically secure random password and hashes it.
  # Used for guest users who don't set their own password at checkout.
  defp put_random_password(changeset) do
    random_password = :crypto.strong_rand_bytes(32) |> Base.encode64()
    put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(random_password))
  end

  # Sets custom_fields.source to "guest_checkout" for tracking guest users
  defp put_guest_checkout_source(changeset) do
    current_fields = get_field(changeset, :custom_fields) || %{}
    updated_fields = Map.put(current_fields, "source", "guest_checkout")
    put_change(changeset, :custom_fields, updated_fields)
  end

  defp validate_email(changeset, opts) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> validate_change(:email, &validate_deliverable_email/2)
    |> maybe_validate_unique_email(opts)
  end

  @doc "Whether an address uses the reserved .invalid domain (including subdomains)."
  def invalid_email?(email) when is_binary(email) do
    email |> String.downcase() |> String.trim() |> String.ends_with?(".invalid")
  end

  def invalid_email?(_), do: false

  defp validate_deliverable_email(field, email) do
    if invalid_email?(email), do: [{field, "must use a deliverable email domain"}], else: []
  end

  @doc "The address to display or deliver to; contact email never authenticates an account."
  def delivery_email(%{managed_by_members: true, contact_email: email}), do: email
  def delivery_email(%{managed_by_members: true}), do: nil
  def delivery_email(%{email: email}), do: email
  def delivery_email(_), do: nil

  @doc "Validates a managed organization's optional, non-unique delivery address."
  def contact_email_changeset(user, attrs) do
    user
    |> cast(attrs, [:contact_email])
    |> update_change(:contact_email, &normalize_google_email/1)
    |> validate_format(:contact_email, ~r/^[^\s]+@[^\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:contact_email, max: 160)
    |> validate_change(:contact_email, &validate_deliverable_email/2)
  end

  # The Google address is optional and is never an identity: nothing
  # authenticates against it, so it is neither required nor unique (a team
  # shares one inbox often enough). An empty string from a cleared form input
  # is stored as nil, so "unset" has one representation rather than two.
  defp validate_google_email(changeset) do
    changeset
    |> update_change(:google_email, &normalize_google_email/1)
    |> validate_format(:google_email, ~r/^[^\s]+@[^\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:google_email, max: 160)
  end

  defp normalize_google_email(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_google_email(value), do: value

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> apply_password_requirements()
    |> maybe_hash_password(opts)
  end

  # Apply configurable password requirements from application config.
  #
  # Password requirements can be configured via:
  #
  #     config :phoenix_kit, :password_requirements,
  #       min_length: 8,
  #       max_length: 72,
  #       require_uppercase: false,
  #       require_lowercase: false,
  #       require_digit: false,
  #       require_special: false
  #
  # Default Requirements:
  # - min_length: 8 characters (minimum recommended)
  # - max_length: 72 characters (bcrypt limit)
  # - require_uppercase: false
  # - require_lowercase: false
  # - require_digit: false
  # - require_special: false
  defp apply_password_requirements(changeset) do
    requirements = PhoenixKit.Config.get_list(:password_requirements, [])

    changeset
    |> validate_length(:password,
      min: Keyword.get(requirements, :min_length, 8),
      max: Keyword.get(requirements, :max_length, 72)
    )
    |> maybe_validate_uppercase(Keyword.get(requirements, :require_uppercase, false))
    |> maybe_validate_lowercase(Keyword.get(requirements, :require_lowercase, false))
    |> maybe_validate_digit(Keyword.get(requirements, :require_digit, false))
    |> maybe_validate_special(Keyword.get(requirements, :require_special, false))
  end

  # Conditionally validate uppercase requirement
  defp maybe_validate_uppercase(changeset, true) do
    validate_format(changeset, :password, ~r/[A-Z]/,
      message: "must contain at least one uppercase character"
    )
  end

  defp maybe_validate_uppercase(changeset, _), do: changeset

  # Conditionally validate lowercase requirement
  defp maybe_validate_lowercase(changeset, true) do
    validate_format(changeset, :password, ~r/[a-z]/,
      message: "must contain at least one lowercase character"
    )
  end

  defp maybe_validate_lowercase(changeset, _), do: changeset

  # Conditionally validate digit requirement
  defp maybe_validate_digit(changeset, true) do
    validate_format(changeset, :password, ~r/[0-9]/, message: "must contain at least one digit")
  end

  defp maybe_validate_digit(changeset, _), do: changeset

  # Conditionally validate special character requirement
  defp maybe_validate_special(changeset, true) do
    validate_format(changeset, :password, ~r/[!?@#$%^&*_]/,
      message: "must contain at least one special character (!?@#$%^&*_)"
    )
  end

  defp maybe_validate_special(changeset, _), do: changeset

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

  # `validate_email: false` skips only the pre-flight `unsafe_validate_unique`
  # round trip. The `unique_constraint` stays on: without it a duplicate
  # address surfaces as a raised `Ecto.ConstraintError` (crashing the admin
  # user form) instead of a changeset error.
  defp maybe_validate_unique_email(changeset, opts) do
    changeset =
      if Keyword.get(opts, :validate_email, true) do
        unsafe_validate_unique(changeset, :email, PhoenixKit.RepoHelper.repo())
      else
        changeset
      end

    unique_constraint(changeset, :email)
  end

  @doc """
  A user changeset for changing the email.

  It requires the email to change otherwise an error is added.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
    |> refuse_managed_credentials(:email)
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
    |> validate_password_different_from_current()
    |> validate_password(opts)
    |> refuse_managed_credentials(:password)
  end

  defp refuse_managed_credentials(%{data: %{managed_by_members: true}} = changeset, field),
    do: add_error(changeset, field, "cannot be changed for a managed organization")

  defp refuse_managed_credentials(changeset, _field), do: changeset

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = UtilsDate.utc_now()
    change(user, confirmed_at: now)
  end

  @doc """
  Unconfirms the account by setting `confirmed_at` to nil.
  """
  def unconfirm_changeset(user) do
    change(user, confirmed_at: nil)
  end

  @doc """
  Validates a locale value for format and existence.

  Returns `:ok` if valid, `{:error, message}` if invalid.

  ## Examples

      iex> validate_locale_value("en-US")
      :ok

      iex> validate_locale_value("invalid")
      {:error, "must be a valid locale format (e.g., en-US, es-MX)"}
  """
  def validate_locale_value(nil), do: :ok
  def validate_locale_value(""), do: :ok

  def validate_locale_value(locale) when is_binary(locale) do
    cond do
      !Regex.match?(~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/, locale) ->
        {:error, "must be a valid locale format (e.g., en-US, es-MX)"}

      !Languages.get_predefined_language(locale) ->
        {:error, "is not a recognized language code"}

      true ->
        :ok
    end
  end

  def validate_locale_value(_), do: {:error, "must be a string"}

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%PhoenixKit.Users.Auth.User{api_only: true}, _password) do
    # A service user signs in with an API key only. It has a random password hash, but a
    # password somebody sets on it later (an admin form, a reset) must not open the web.
    Bcrypt.no_user_verify()
    false
  end

  def valid_password?(%__MODULE__{managed_by_members: true}, _password) do
    Bcrypt.no_user_verify()
    false
  end

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

  # Validates that the new password is different from the current password
  defp validate_password_different_from_current(changeset) do
    new_password = get_change(changeset, :password)

    if new_password && changeset.data.hashed_password do
      if Bcrypt.verify_pass(new_password, changeset.data.hashed_password) do
        add_error(changeset, :password, "must be different from current password")
      else
        changeset
      end
    else
      changeset
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

  ## Custom fields

  `attrs` here is what a profile form posted, so a `custom_fields` entry is
  treated as the account holder's input and never cast as a whole map:
  `PhoenixKit.Users.CustomFields.cast_user_input/2` keeps the keys that are
  defined, user-accessible custom fields, validates their values, and the
  result is merged over the stored map. Every other stored key keeps its
  value, and no other key can be written this way. System code writes its own
  keys through `PhoenixKit.Users.Auth.merge_user_custom_fields/3` or
  `update_user_custom_fields/3`.
  """
  def profile_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [
      :first_name,
      :last_name,
      :email,
      :google_email,
      :username,
      :user_timezone,
      :country,
      :organization_name
    ])
    |> validate_names()
    |> validate_email(opts)
    |> validate_google_email()
    |> validate_username(opts)
    |> validate_user_timezone()
    |> validate_country()
    |> cast_user_custom_fields(attrs)
    |> protect_managed_profile_credentials()
  end

  defp protect_managed_profile_credentials(%{data: %{managed_by_members: true}} = changeset) do
    Enum.reduce([:email, :google_email], changeset, fn field, acc ->
      if changed?(acc, field),
        do: add_error(acc, field, "cannot be changed for a managed organization"),
        else: acc
    end)
  end

  defp protect_managed_profile_credentials(changeset), do: changeset

  defp cast_user_custom_fields(changeset, attrs) do
    case submitted_custom_fields(attrs) do
      nil ->
        changeset

      submitted when is_map(submitted) ->
        stored = changeset.data.custom_fields || %{}
        {accepted, errors} = CustomFields.cast_user_input(stored, submitted)

        changeset =
          Enum.reduce(errors, changeset, fn {key, {message, error_opts}}, acc ->
            add_error(acc, :custom_fields, message, [field: key] ++ error_opts)
          end)

        if map_size(accepted) == 0 do
          changeset
        else
          put_change(changeset, :custom_fields, Map.merge(stored, accepted))
        end

      _other ->
        add_error(changeset, :custom_fields, "must be a valid map")
    end
  end

  defp submitted_custom_fields(%{} = attrs) do
    case attrs do
      %{"custom_fields" => submitted} -> submitted
      %{custom_fields: submitted} -> submitted
      _ -> nil
    end
  end

  defp submitted_custom_fields(_attrs), do: nil

  @doc """
  A user changeset for updating active status.
  """
  def status_changeset(user, attrs) do
    # Owner protection lives in `Auth.update_user_status/2` (last-owner check
    # under the advisory lock). A blanket "no Owner can ever be deactivated"
    # rule here contradicted it: a compromised non-last Owner could pass the
    # context guard and then fail on this changeset.
    user
    |> cast(attrs, [:is_active])
    |> validate_inclusion(:is_active, [true, false])
  end

  @doc """
  A user changeset for updating account type and organization fields.
  """
  def account_type_changeset(user, attrs) do
    user
    |> cast(attrs, [:account_type, :organization_name, :organization_uuid])
    |> validate_required([:account_type])
    |> validate_inclusion(:account_type, ["person", "organization"])
    |> validate_organization_fields()
  end

  defp validate_organization_fields(changeset) do
    account_type = get_field(changeset, :account_type)

    case account_type do
      "organization" ->
        changeset
        |> validate_required([:organization_name])
        |> validate_length(:organization_name, max: 255)
        |> put_change(:organization_uuid, nil)

      "person" ->
        changeset
        |> put_change(:organization_name, nil)
        |> validate_no_self_reference()

      _ ->
        changeset
    end
  end

  defp validate_no_self_reference(changeset) do
    uuid = get_field(changeset, :uuid)
    org_uuid = get_field(changeset, :organization_uuid)

    if uuid && org_uuid && uuid == org_uuid do
      add_error(changeset, :organization_uuid, "cannot reference self")
    else
      changeset
    end
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
  What to call this person when showing them TO OTHER PEOPLE.

  The one canonical answer. Before this existed there were half a dozen
  private copies, several of which ended `|| user.email` — which is how a
  public issue board came to print commenters' full addresses next to their
  words, indexed and scrapeable.

  The chain, first non-blank wins:

      organization account's name    (an org has no first/last)
      first + last name
      username
      the local part of the email    (before the "@")
      "User"

  **Never the full email.** The local part is not anonymity —
  `john.smith@…` still reads as "john.smith" — but it carries no domain, is
  not directly mailable, and is not harvestable as an address.

  Every rung is trimmed and rejected when blank: `full_name/1` happily
  returns `""` for a first name of `"   "`, and an unguarded chain stops
  dead on it.

  Only fields the USER wrote about themselves. A name recorded by somebody
  else — `phoenix_kit_staff`'s HR record, a CRM contact label — must never
  reach this, whatever its quality: the people with no name set are exactly
  the ones who are pseudonymous by choice or inertia, and publishing an
  HR-entered legal name on their behalf is not ours to do.

  For "does this person have a real name at all", keep using `full_name/1`
  — it still answers `nil`, and that question is still worth asking.

  ## Examples

      iex> display_name(%User{first_name: "John", last_name: "Doe"})
      "John Doe"

      iex> display_name(%User{first_name: nil, username: "jdoe"})
      "jdoe"

      iex> display_name(%User{first_name: nil, username: nil, email: "j@x.com"})
      "j"
  """
  @spec display_name(t() | nil) :: String.t()
  def display_name(%__MODULE__{} = user) do
    first_present([
      full_name(user),
      user.username,
      email_local_part(user.email)
    ]) || "User"
  end

  # A deleted or unloaded association. Callers that can say something better
  # ("Former user") should; this keeps a nil from reaching a template raw.
  def display_name(_), do: "User"

  defp first_present(candidates) do
    Enum.find_value(candidates, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end)
  end

  defp email_local_part(email) when is_binary(email) do
    case String.split(email, "@") do
      [local | _] -> local
      _ -> nil
    end
  end

  defp email_local_part(_), do: nil

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
  def full_name(%__MODULE__{account_type: "organization", organization_name: name})
      when is_binary(name) and name != "",
      do: name

  def full_name(%__MODULE__{first_name: first_name, last_name: last_name}) do
    case {first_name, last_name} do
      {nil, nil} -> nil
      {first, nil} -> String.trim(first)
      {nil, last} -> String.trim(last)
      {first, last} -> String.trim("#{first} #{last}")
    end
  end

  defp maybe_skip_names_for_organization(changeset) do
    case get_field(changeset, :account_type) do
      "organization" ->
        changeset
        |> validate_required([:organization_name])
        |> validate_length(:organization_name, max: 255)

      _ ->
        changeset
    end
  end

  defp validate_names(changeset) do
    changeset
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
  end

  defp validate_registration_fields(changeset) do
    # `registration_country` is a 2-char column (ISO 3166-1 alpha-2) — this
    # validation used to say `max: 100`, matching region/city instead of the
    # column it actually guards, so an oversized value (e.g. a full country
    # name) sailed through the changeset as "valid" and only failed at the
    # SQL layer with an unhandled `string_data_right_truncation`, crashing
    # the caller instead of returning a normal `{:error, changeset}`.
    changeset
    |> validate_length(:registration_ip, max: 45)
    |> validate_length(:registration_country, max: 2)
    |> validate_length(:registration_region, max: 100)
    |> validate_length(:registration_city, max: 100)
  end

  defp validate_username(changeset, opts) do
    changeset
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z][a-zA-Z0-9_]*$/,
      message: "must start with a letter and contain only letters, numbers, and underscores"
    )
    |> validate_change(:username, fn :username, username ->
      if reserved_username?(username), do: [username: "is reserved"], else: []
    end)
    |> maybe_validate_unique_username(opts)
  end

  @doc """
  Whether `username` is one the host keeps for its own pages: `config :phoenix_kit,
  :reserved_usernames, ["admin", "profile"]`. A host that gives each person an address of
  their own (`/<username>/…`) shares the first segment of every URL with its routes, so a
  person who took `admin` would be given a page no one can reach. A registration or an edit
  that asks for one is refused, and a name generated from an email address that is one gets
  a number (`admin_1`). Case does not matter. Names already taken are not changed.
  """
  @spec reserved_username?(term()) :: boolean()
  def reserved_username?(username) when is_binary(username) do
    username = String.downcase(username)

    Enum.any?(
      Application.get_env(:phoenix_kit, :reserved_usernames, []),
      &(String.downcase(to_string(&1)) == username)
    )
  end

  def reserved_username?(_username), do: false

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
    case get_change(changeset, :username) do
      username when username in [nil, ""] ->
        maybe_put_generated_username(changeset)

      _ ->
        # User has manually entered a username, don't override it
        changeset
    end
  end

  # Generating is for a user who does not have a username yet. An existing one
  # must never be rewritten here: this step runs on every registration changeset,
  # including the ones the admin user form rebuilds while editing (toggling the
  # password field, for one), and those carry no `username` param — so without
  # this guard, opening an existing user and saving renamed them.
  defp maybe_put_generated_username(changeset) do
    email = get_change(changeset, :email) || get_field(changeset, :email)

    cond do
      present?(changeset.data.username) ->
        changeset

      # Only generate once the email looks finished, so a half-typed address
      # does not mint a username from it.
      is_binary(email) and String.contains?(email, "@") ->
        changeset
        |> put_change(:username, generate_unique_username_from_email(email, changeset.data))
        # This step runs at the END of `registration_changeset/3`, after
        # `validate_username/2` has already decided there was no username change
        # to guard — so a GENERATED name reaches the database with no constraint
        # on it. And the walk below reads committed rows only: two registrations
        # from `maria@a.com` and `maria@b.com` racing each see `maria` free and
        # both take it, leaving the loser with an `Ecto.ConstraintError` raised
        # out of `Repo.insert/1` rather than an `{:error, changeset}`.
        |> unique_constraint(:username, name: :phoenix_kit_users_username_uidx)

      true ->
        changeset
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  # Generate a unique username from email by checking for collisions
  defp generate_unique_username_from_email(email, data) do
    base_username = generate_username_from_email(email)
    ensure_unique_username(base_username, 0, data.uuid)
  end

  # Recursively ensure username is unique by adding numeric suffix if needed
  # `own_uuid` is the user the name is being generated for, when there is one:
  # the row that already holds `maria` must not make `maria` look taken to
  # maria herself, or every regeneration would walk her one suffix further
  # (`maria` → `maria_1` → `maria_2`).
  defp ensure_unique_username(base_username, attempt, own_uuid) do
    username = if attempt == 0, do: base_username, else: "#{base_username}_#{attempt}"

    case reserved_username?(username) ||
           PhoenixKit.RepoHelper.repo().get_by(__MODULE__, username: username) do
      true -> ensure_unique_username(base_username, attempt + 1, own_uuid)
      nil -> username
      %__MODULE__{uuid: ^own_uuid} when not is_nil(own_uuid) -> username
      %__MODULE__{} -> ensure_unique_username(base_username, attempt + 1, own_uuid)
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
    # Fold accents and Cyrillic to ASCII before `clean_username/1` runs, or it
    # simply deletes them: `ülo.kask@` yielded `lo_kask`, losing the first letter
    # of the name, and a wholly non-Latin local part collapsed to nothing.
    # Downcasing first is required — `transliterate/1` maps lowercase Cyrillic.
    |> Slug.transliterate()
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

  # `country` is an ISO 3166-1 alpha-2 code known to BeamLabCountries, stored
  # upper-case; blank means "not chosen" and is stored as nil.
  defp validate_country(changeset) do
    case get_change(changeset, :country) do
      nil ->
        changeset

      code when is_binary(code) ->
        case String.upcase(String.trim(code)) do
          "" ->
            put_change(changeset, :country, nil)

          upcased ->
            if BeamLabCountries.get(upcased) do
              put_change(changeset, :country, upcased)
            else
              add_error(changeset, :country, "must be a valid country code")
            end
        end
    end
  end

  # A new account starts with the country its registration came from, so the
  # profile form opens on something sensible. Only a code the data set knows:
  # `registration_country` is a GeoIP guess and may be junk.
  defp start_country_from_registration(changeset) do
    registration_country = get_change(changeset, :registration_country)

    if is_nil(get_field(changeset, :country)) and is_binary(registration_country) do
      upcased = registration_country |> String.trim() |> String.upcase()

      if BeamLabCountries.get(upcased),
        do: put_change(changeset, :country, upcased),
        else: changeset
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
        add_error(changeset, :user_timezone, "must be a timezone identifier")
    end
  end

  # Accepts what the picker now offers — an IANA identifier like
  # "Europe/Warsaw" — and, still, the numeric offsets rows were written with
  # before the move to identifiers, so an existing account does not fail
  # validation on a field it never touched. `PhoenixKit.Utils.TimeZone.valid?/1`
  # owns both shapes; see its moduledoc for why an old offset is kept rather
  # than upgraded in place.
  defp validate_timezone_offset(changeset, timezone) do
    if TimeZone.valid?(timezone) do
      changeset
    else
      add_error(
        changeset,
        :user_timezone,
        "must be a timezone identifier like Europe/Warsaw"
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
