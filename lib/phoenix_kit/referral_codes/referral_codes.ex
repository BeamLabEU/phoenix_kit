defmodule PhoenixKit.ReferralCodes do
  @moduledoc """
  Referral code system for PhoenixKit - complete management in a single module.

  This module provides both the Ecto schema definition and business logic for 
  managing referral codes. It includes code creation, validation, usage tracking,
  and system configuration.

  ## Schema Fields

  - `code`: The referral code string (unique, required)
  - `description`: Human-readable description of the code
  - `status`: Boolean indicating if the code is active
  - `number_of_uses`: Current number of times the code has been used
  - `max_uses`: Maximum number of times the code can be used
  - `created_by`: User ID of the admin who created the code
  - `beneficiary`: User ID who benefits when this code is used (optional)
  - `date_created`: When the code was created
  - `expiration_date`: When the code expires

  ## Core Functions

  ### Code Management
  - `list_codes/0` - Get all referral codes
  - `get_code!/1` - Get a referral code by ID (raises if not found)
  - `get_code_by_string/1` - Get a referral code by its string value
  - `create_code/1` - Create a new referral code
  - `update_code/2` - Update an existing referral code
  - `delete_code/1` - Delete a referral code
  - `generate_random_code/0` - Generate a random code string

  ### Usage Tracking
  - `use_code/2` - Record usage of a referral code by a user
  - `get_usage_stats/1` - Get usage statistics for a code
  - `list_usage_for_code/1` - Get all usage records for a code
  - `user_used_code?/2` - Check if user has used a specific code

  ### System Settings
  - `enabled?/0` - Check if referral codes system is enabled
  - `required?/0` - Check if referral codes are required for registration
  - `enable_system/0` - Enable the referral codes system
  - `disable_system/0` - Disable the referral codes system
  - `set_required/1` - Set whether referral codes are required

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKit.ReferralCodes.enabled?() do
        # System is active
      end

      # Create a new referral code
      {:ok, code} = PhoenixKit.ReferralCodes.create_code(%{
        code: "WELCOME2024",
        description: "Welcome promotion",
        max_uses: 100,
        created_by: admin_user.id,
        expiration_date: ~U[2024-12-31 23:59:59.000000Z]
      })

      # Use a referral code during registration
      case PhoenixKit.ReferralCodes.use_code("WELCOME2024", user.id) do
        {:ok, usage} -> # Code used successfully
        {:error, reason} -> # Handle error
      end
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Settings

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_referral_codes" do
    field :code, :string
    field :description, :string
    field :status, :boolean, default: true
    field :number_of_uses, :integer, default: 0
    field :max_uses, :integer
    field :created_by, :integer
    field :beneficiary, :integer
    field :date_created, :utc_datetime_usec
    field :expiration_date, :utc_datetime_usec

    belongs_to :creator, PhoenixKit.Users.Auth.User, foreign_key: :created_by, define_field: false

    belongs_to :beneficiary_user, PhoenixKit.Users.Auth.User,
      foreign_key: :beneficiary,
      define_field: false

    has_many :usage_records, PhoenixKit.ReferralCodeUsage, foreign_key: :code_id
  end

  ## --- Schema Functions ---

  @doc """
  Creates a changeset for referral code creation and updates.

  Validates that code is unique and all required fields are present.
  Automatically sets date_created on new records.
  """
  def changeset(referral_code, attrs) do
    referral_code
    |> cast(attrs, [
      :code,
      :description,
      :status,
      :number_of_uses,
      :max_uses,
      :created_by,
      :beneficiary,
      :date_created,
      :expiration_date
    ])
    |> validate_required([:code, :description, :max_uses])
    |> validate_length(:code, min: 3, max: 50)
    |> validate_length(:description, min: 1, max: 255)
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_max_uses_limit()
    |> validate_number(:number_of_uses, greater_than_or_equal_to: 0)
    |> validate_code_uniqueness()
    |> unique_constraint(:code)
    |> validate_expiration_date()
    |> maybe_set_date_created()
    |> maybe_set_default_expiration()
  end

  @doc """
  Generates a random 5-character alphanumeric referral code.

  Returns a string with uppercase letters and numbers, excluding
  potentially confusing characters (0, O, I, 1).

  ## Examples

      iex> PhoenixKit.ReferralCodes.generate_random_code()
      "A7B2K"
  """
  def generate_random_code do
    # Exclude confusing characters: 0, O, I, 1
    chars = ~w(A B C D E F G H J K L M N P Q R S T U V W X Y Z 2 3 4 5 6 7 8 9)

    chars
    |> Enum.take_random(5)
    |> Enum.join()
  end

  @doc """
  Checks if a referral code is currently valid for use.

  A code is valid if:
  - It exists and is active (status: true)
  - It has not exceeded its maximum uses
  - It has not expired

  ## Examples

      iex> PhoenixKit.ReferralCodes.valid_for_use?(code)
      true
  """
  def valid_for_use?(%__MODULE__{} = code) do
    code.status &&
      code.number_of_uses < code.max_uses &&
      (is_nil(code.expiration_date) ||
         DateTime.compare(DateTime.utc_now(), code.expiration_date) == :lt)
  end

  @doc """
  Checks if a referral code has expired.

  ## Examples

      iex> PhoenixKit.ReferralCodes.expired?(code)
      false
  """
  def expired?(%__MODULE__{} = code) do
    !is_nil(code.expiration_date) &&
      DateTime.compare(DateTime.utc_now(), code.expiration_date) != :lt
  end

  @doc """
  Checks if a referral code has reached its usage limit.

  ## Examples

      iex> PhoenixKit.ReferralCodes.usage_limit_reached?(code)
      false
  """
  def usage_limit_reached?(%__MODULE__{} = code) do
    code.number_of_uses >= code.max_uses
  end

  ## --- Business Logic Functions ---

  @doc """
  Returns the list of referral codes ordered by creation date.

  ## Examples

      iex> PhoenixKit.ReferralCodes.list_codes()
      [%PhoenixKit.ReferralCodes{}, ...]
  """
  def list_codes do
    __MODULE__
    |> order_by([r], desc: r.date_created)
    |> preload([:creator, :beneficiary_user])
    |> repo().all()
  end

  @doc """
  Gets a single referral code by ID.

  Raises `Ecto.NoResultsError` if the code does not exist.

  ## Examples

      iex> PhoenixKit.ReferralCodes.get_code!(123)
      %PhoenixKit.ReferralCodes{}

      iex> PhoenixKit.ReferralCodes.get_code!(456)
      ** (Ecto.NoResultsError)
  """
  def get_code!(id), do: repo().get!(__MODULE__, id)

  @doc """
  Gets a single referral code by its string value.

  Returns the referral code if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.ReferralCodes.get_code_by_string("WELCOME2024")
      %PhoenixKit.ReferralCodes{}

      iex> PhoenixKit.ReferralCodes.get_code_by_string("INVALID")
      nil
  """
  def get_code_by_string(code_string) when is_binary(code_string) do
    repo().get_by(__MODULE__, code: code_string)
  end

  @doc """
  Creates a referral code.

  ## Examples

      iex> PhoenixKit.ReferralCodes.create_code(%{code: "TEST123", max_uses: 10})
      {:ok, %PhoenixKit.ReferralCodes{}}

      iex> PhoenixKit.ReferralCodes.create_code(%{code: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_code(attrs \\ %{}) do
    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a referral code.

  ## Examples

      iex> PhoenixKit.ReferralCodes.update_code(code, %{description: "Updated"})
      {:ok, %PhoenixKit.ReferralCodes{}}

      iex> PhoenixKit.ReferralCodes.update_code(code, %{code: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_code(%__MODULE__{} = referral_code, attrs) do
    referral_code
    |> changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a referral code.

  ## Examples

      iex> PhoenixKit.ReferralCodes.delete_code(code)
      {:ok, %PhoenixKit.ReferralCodes{}}

      iex> PhoenixKit.ReferralCodes.delete_code(code)
      {:error, %Ecto.Changeset{}}
  """
  def delete_code(%__MODULE__{} = referral_code) do
    repo().delete(referral_code)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking referral code changes.

  ## Examples

      iex> PhoenixKit.ReferralCodes.change_code(code)
      %Ecto.Changeset{data: %PhoenixKit.ReferralCodes{}}
  """
  def change_code(%__MODULE__{} = referral_code, attrs \\ %{}) do
    changeset(referral_code, attrs)
  end

  @doc """
  Records usage of a referral code by a user.

  Validates that the code is valid for use before recording the usage.
  Updates the code's number_of_uses counter.

  ## Examples

      iex> PhoenixKit.ReferralCodes.use_code("WELCOME2024", user_id)
      {:ok, %PhoenixKit.ReferralCodeUsage{}}

      iex> PhoenixKit.ReferralCodes.use_code("EXPIRED", user_id)
      {:error, :code_not_found}
  """
  def use_code(code_string, user_id) when is_binary(code_string) and is_integer(user_id) do
    case get_code_by_string(code_string) do
      nil -> {:error, :code_not_found}
      code -> process_code_usage(code, user_id)
    end
  end

  defp process_code_usage(code, user_id) do
    case valid_for_use?(code) do
      true -> record_code_usage(code, user_id)
      false -> get_code_error(code)
    end
  end

  defp record_code_usage(code, user_id) do
    repo().transaction(fn -> do_record_usage(code, user_id) end)
  end

  defp do_record_usage(code, user_id) do
    usage_result =
      %PhoenixKit.ReferralCodeUsage{}
      |> PhoenixKit.ReferralCodeUsage.changeset(%{code_id: code.id, used_by: user_id})
      |> repo().insert()

    case usage_result do
      {:ok, usage} ->
        {:ok, _updated_code} = update_code(code, %{number_of_uses: code.number_of_uses + 1})
        usage

      {:error, changeset} ->
        repo().rollback(changeset)
    end
  end

  defp get_code_error(code) do
    cond do
      expired?(code) -> {:error, :code_expired}
      usage_limit_reached?(code) -> {:error, :usage_limit_reached}
      !code.status -> {:error, :code_inactive}
      true -> {:error, :code_invalid}
    end
  end

  @doc """
  Gets usage statistics for a referral code.

  ## Examples

      iex> PhoenixKit.ReferralCodes.get_usage_stats(code_id)
      %{total_uses: 5, unique_users: 3, last_used: ~U[...], recent_users: [...]}
  """
  def get_usage_stats(code_id) when is_integer(code_id) do
    PhoenixKit.ReferralCodeUsage.get_usage_stats(code_id)
  end

  @doc """
  Lists all usage records for a referral code.

  ## Examples

      iex> PhoenixKit.ReferralCodes.list_usage_for_code(code_id)
      [%PhoenixKit.ReferralCodeUsage{}, ...]
  """
  def list_usage_for_code(code_id) when is_integer(code_id) do
    PhoenixKit.ReferralCodeUsage.for_code(code_id)
    |> repo().all()
  end

  @doc """
  Checks if a user has already used a specific referral code.

  ## Examples

      iex> PhoenixKit.ReferralCodes.user_used_code?(user_id, code_id)
      false
  """
  def user_used_code?(user_id, code_id) when is_integer(user_id) and is_integer(code_id) do
    PhoenixKit.ReferralCodeUsage.user_used_code?(user_id, code_id)
  end

  ## --- System Settings ---

  @doc """
  Checks if the referral codes system is enabled.

  Returns true if the "referral_codes_enabled" setting is true.

  ## Examples

      iex> PhoenixKit.ReferralCodes.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting("referral_codes_enabled", false)
  end

  @doc """
  Checks if referral codes are required for user registration.

  Returns true if the "referral_codes_required" setting is true.

  ## Examples

      iex> PhoenixKit.ReferralCodes.required?()
      false
  """
  def required? do
    Settings.get_boolean_setting("referral_codes_required", false)
  end

  @doc """
  Enables the referral codes system.

  Sets the "referral_codes_enabled" setting to true.

  ## Examples

      iex> PhoenixKit.ReferralCodes.enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("referral_codes_enabled", true, "referral_codes")
  end

  @doc """
  Disables the referral codes system.

  Sets the "referral_codes_enabled" setting to false.

  ## Examples

      iex> PhoenixKit.ReferralCodes.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module("referral_codes_enabled", false, "referral_codes")
  end

  @doc """
  Sets whether referral codes are required for registration.

  ## Examples

      iex> PhoenixKit.ReferralCodes.set_required(true)
      {:ok, %Setting{}}

      iex> PhoenixKit.ReferralCodes.set_required(false)
      {:ok, %Setting{}}
  """
  def set_required(required) when is_boolean(required) do
    Settings.update_boolean_setting_with_module(
      "referral_codes_required",
      required,
      "referral_codes"
    )
  end

  @doc """
  Gets the maximum number of uses allowed per referral code.

  Returns the system-wide limit for how many times a single referral code can be used.
  Defaults to 100 if not set.

  ## Examples

      iex> PhoenixKit.ReferralCodes.get_max_uses_per_code()
      100
  """
  def get_max_uses_per_code do
    Settings.get_integer_setting("max_number_of_uses_per_code", 100)
  end

  @doc """
  Gets the maximum number of referral codes a single user can create.

  Returns the system-wide limit for referral code creation per user.
  Defaults to 10 if not set.

  ## Examples

      iex> PhoenixKit.ReferralCodes.get_max_codes_per_user()
      10
  """
  def get_max_codes_per_user do
    Settings.get_integer_setting("max_number_of_codes_per_user", 10)
  end

  @doc """
  Sets the maximum number of uses allowed per referral code.

  Updates the system-wide limit for referral code usage.

  ## Examples

      iex> PhoenixKit.ReferralCodes.set_max_uses_per_code(50)
      {:ok, %Setting{}}
  """
  def set_max_uses_per_code(max_uses) when is_integer(max_uses) and max_uses > 0 do
    Settings.update_setting_with_module(
      "max_number_of_uses_per_code",
      to_string(max_uses),
      "referral_codes"
    )
  end

  @doc """
  Sets the maximum number of referral codes a single user can create.

  Updates the system-wide limit for referral code creation per user.

  ## Examples

      iex> PhoenixKit.ReferralCodes.set_max_codes_per_user(5)
      {:ok, %Setting{}}
  """
  def set_max_codes_per_user(max_codes) when is_integer(max_codes) and max_codes > 0 do
    Settings.update_setting_with_module(
      "max_number_of_codes_per_user",
      to_string(max_codes),
      "referral_codes"
    )
  end

  @doc """
  Gets the current referral codes system configuration.

  Returns a map with the current settings.

  ## Examples

      iex> PhoenixKit.ReferralCodes.get_config()
      %{enabled: false, required: false}
  """
  def get_config do
    %{
      enabled: enabled?(),
      required: required?(),
      max_uses_per_code: get_max_uses_per_code(),
      max_codes_per_user: get_max_codes_per_user()
    }
  end

  @doc """
  Gets codes that are currently valid for use.

  Returns codes that are active, not expired, and haven't reached usage limits.

  ## Examples

      iex> PhoenixKit.ReferralCodes.list_valid_codes()
      [%PhoenixKit.ReferralCodes{}, ...]
  """
  def list_valid_codes do
    now = DateTime.utc_now()

    from(r in __MODULE__,
      where: r.status == true,
      where: r.expiration_date > ^now,
      where: r.number_of_uses < r.max_uses,
      order_by: [desc: r.date_created]
    )
    |> repo().all()
  end

  @doc """
  Gets summary statistics for the referral codes system.

  Returns counts and metrics useful for admin dashboards.

  ## Examples

      iex> PhoenixKit.ReferralCodes.get_system_stats()
      %{total_codes: 10, active_codes: 8, total_usage: 150, codes_with_usage: 6}
  """
  def get_system_stats do
    codes_query = from(r in __MODULE__)
    usage_query = from(u in PhoenixKit.ReferralCodeUsage)

    total_codes = repo().aggregate(codes_query, :count)
    active_codes = repo().aggregate(from(r in codes_query, where: r.status == true), :count)
    total_usage = repo().aggregate(usage_query, :count)

    codes_with_usage =
      repo().aggregate(from(r in codes_query, where: r.number_of_uses > 0), :count)

    %{
      total_codes: total_codes,
      active_codes: active_codes,
      total_usage: total_usage,
      codes_with_usage: codes_with_usage
    }
  end

  ## --- Private Helpers ---

  defp validate_code_uniqueness(changeset) do
    case get_field(changeset, :code) do
      nil ->
        changeset

      # Let validate_required handle empty strings
      "" ->
        changeset

      code_string ->
        case get_code_by_string(code_string) do
          # No duplicate found, validation passes
          nil ->
            changeset

          existing_code ->
            # Check if this is the same record we're editing
            current_id = get_field(changeset, :id)

            if current_id && existing_code.id == current_id do
              # This is the same record, validation passes
              changeset
            else
              # Different record with same code, validation fails
              add_error(changeset, :code, "has already been taken")
            end
        end
    end
  end

  defp validate_expiration_date(changeset) do
    case get_field(changeset, :expiration_date) do
      nil ->
        changeset

      expiration_date ->
        if DateTime.compare(expiration_date, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, :expiration_date, "must be in the future")
        end
    end
  end

  defp maybe_set_date_created(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :date_created, DateTime.utc_now())
      _id -> changeset
    end
  end

  defp validate_max_uses_limit(changeset) do
    case get_field(changeset, :max_uses) do
      nil ->
        changeset

      max_uses ->
        system_limit = get_max_uses_per_code()

        if max_uses <= system_limit do
          changeset
        else
          add_error(changeset, :max_uses, "cannot exceed system limit of #{system_limit}")
        end
    end
  end

  @doc """
  Validates that a user hasn't exceeded their referral code creation limit.

  Checks the current number of codes created by the user against the system limit.
  Returns `{:ok, :valid}` if within limits, `{:error, reason}` if limit exceeded.

  ## Examples

      iex> PhoenixKit.ReferralCodes.validate_user_code_limit(1)
      {:ok, :valid}

      iex> PhoenixKit.ReferralCodes.validate_user_code_limit(1)
      {:error, "You have reached the maximum limit of 10 referral codes"}
  """
  def validate_user_code_limit(user_id) when is_integer(user_id) do
    max_codes = get_max_codes_per_user()
    current_count = count_user_codes(user_id)

    if current_count < max_codes do
      {:ok, :valid}
    else
      {:error, "You have reached the maximum limit of #{max_codes} referral codes"}
    end
  end

  @doc """
  Counts the total number of referral codes created by a user.

  ## Examples

      iex> PhoenixKit.ReferralCodes.count_user_codes(1)
      5
  """
  def count_user_codes(user_id) when is_integer(user_id) do
    from(r in __MODULE__, where: r.created_by == ^user_id, select: count(r.id))
    |> repo().one()
  end

  defp maybe_set_default_expiration(changeset) do
    # Respect user's intent to leave expiration empty (nil = no expiration)
    # Only set default expiration for programmatic creation without explicit intent
    changeset
  end

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
