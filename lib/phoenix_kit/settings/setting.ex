defmodule PhoenixKit.Settings.Setting do
  @moduledoc """
  Setting schema for PhoenixKit system settings.

  This schema defines system-wide settings that can be configured through
  the admin panel. Settings are stored as key-value pairs with timestamps.

  ## Fields

  - `key`: Setting identifier (unique, required)
  - `value`: Setting value (string format)
  - `module`: Module/feature identifier for organization (optional)
  - `date_added`: When the setting was first created
  - `date_updated`: When the setting was last modified

  ## Default Settings

  PhoenixKit includes three default system settings:

  - **time_zone**: System timezone offset (default: "0" for UTC)
  - **date_format**: Date display format (default: "Y-m-d")
  - **time_format**: Time display format (default: "H:i" for 24-hour)

  ## Usage Examples

      # Create a new setting
      %Setting{}
      |> Setting.changeset(%{key: "theme", value: "dark"})
      |> Repo.insert()

      # Update existing setting
      setting
      |> Setting.changeset(%{value: "light"})
      |> Repo.update()
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_settings" do
    field :key, :string
    field :value, :string
    field :module, :string
    field :date_added, :utc_datetime_usec
    field :date_updated, :utc_datetime_usec
  end

  @doc """
  Creates a changeset for setting creation and updates.

  Validates that key and value are present and key is unique.
  Automatically sets date_updated to current time on updates.
  """
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :module, :date_added, :date_updated])
    |> validate_required([:key])
    |> validate_length(:key, min: 1, max: 255)
    |> validate_setting_value()
    |> validate_length(:module, max: 255)
    |> unique_constraint(:key, name: :phoenix_kit_settings_key_uidx)
    |> maybe_set_timestamps()
  end

  @doc """
  Creates a changeset for updating only the value field.

  This is used when updating existing settings through the admin panel.
  Automatically updates the date_updated timestamp.
  """
  def update_changeset(setting, attrs) do
    setting
    |> cast(attrs, [:value, :module])
    |> validate_setting_value()
    |> validate_length(:module, max: 255)
    |> put_change(:date_updated, DateTime.utc_now())
  end

  # Private helper to set timestamps on new records
  defp maybe_set_timestamps(changeset) do
    case get_field(changeset, :id) do
      nil ->
        now = DateTime.utc_now()

        changeset
        |> put_change(:date_added, now)
        |> put_change(:date_updated, now)

      _id ->
        put_change(changeset, :date_updated, DateTime.utc_now())
    end
  end

  # Validates setting values with special handling for optional fields
  defp validate_setting_value(changeset) do
    key = get_field(changeset, :key)
    value = get_field(changeset, :value)

    case key do
      "site_url" ->
        # site_url can be empty, but max 1000 characters
        # Ensure empty string is preserved, not converted to nil
        case value do
          nil -> put_change(changeset, :value, "")
          _ -> validate_length(changeset, :value, max: 1000)
        end

      _ ->
        # All other settings require non-empty values
        validate_length(changeset, :value, min: 1, max: 1000)
    end
  end

  defmodule SettingsForm do
    @moduledoc """
    Settings form schema for PhoenixKit system settings validation.

    This embedded schema provides validation for the settings form in the admin panel.
    It handles validation for core system settings like timezone, date format, and time format.

    ## Fields

    - `project_title`: Application/project title
    - `site_url`: Website URL for the application (optional)
    - `allow_registration`: Allow public user registration (true/false)
    - `time_zone`: System timezone offset (-12 to +12)
    - `date_format`: Date display format (Y-m-d, m/d/Y, etc.)
    - `time_format`: Time display format (H:i for 24-hour, h:i A for 12-hour)

    ## Usage Examples

        # Create a changeset for validation
        %PhoenixKit.Settings.Setting.SettingsForm{}
        |> PhoenixKit.Settings.Setting.SettingsForm.changeset(%{
          project_title: "My App",
          time_zone: "0", 
          date_format: "Y-m-d",
          time_format: "H:i"
        })

        # Validate existing settings
        form_data = struct(PhoenixKit.Settings.Setting.SettingsForm, %{project_title: "My App", ...})
        PhoenixKit.Settings.Setting.SettingsForm.changeset(form_data, %{time_zone: "+5"})
    """
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :project_title, :string
      field :site_url, :string
      field :allow_registration, :string
      field :new_user_default_role, :string
      field :week_start_day, :string
      field :time_zone, :string
      field :date_format, :string
      field :time_format, :string
    end

    @doc """
    Creates a changeset for settings form validation.

    Validates that all required fields are present and have valid values.

    ## Validations

    - All fields are required
    - `project_title`: 1-100 characters
    - `time_zone`: Must be a valid timezone offset (-12 to +12)
    - `date_format`: Must be one of the supported formats
    - `time_format`: Must be one of the supported formats

    ## Examples

        iex> PhoenixKit.Settings.Setting.SettingsForm.changeset(%PhoenixKit.Settings.Setting.SettingsForm{}, %{project_title: "My App"})
        %Ecto.Changeset{valid?: false} # Missing required fields

        iex> valid_attrs = %{
        ...>   project_title: "My App",
        ...>   time_zone: "0",
        ...>   date_format: "Y-m-d", 
        ...>   time_format: "H:i"
        ...> }
        iex> PhoenixKit.Settings.Setting.SettingsForm.changeset(%PhoenixKit.Settings.Setting.SettingsForm{}, valid_attrs)
        %Ecto.Changeset{valid?: true}
    """
    def changeset(form, attrs) do
      form
      |> cast(attrs, [
        :project_title,
        :site_url,
        :allow_registration,
        :new_user_default_role,
        :week_start_day,
        :time_zone,
        :date_format,
        :time_format
      ])
      |> validate_required([
        :project_title,
        :new_user_default_role,
        :week_start_day,
        :time_zone,
        :date_format,
        :time_format
      ])
      |> validate_length(:project_title, min: 1, max: 100)
      |> validate_url()
      |> validate_allow_registration()
      |> validate_new_user_default_role()
      |> validate_week_start_day()
      |> validate_timezone()
      |> validate_date_format()
      |> validate_time_format()
    end

    # Validates URL format (optional field - allows empty)
    defp validate_url(changeset) do
      site_url = get_field(changeset, :site_url)

      case site_url do
        nil ->
          changeset

        "" ->
          changeset

        url when is_binary(url) ->
          trimmed_url = String.trim(url)

          if trimmed_url == "" do
            changeset
          else
            case URI.parse(trimmed_url) do
              %URI{scheme: scheme, host: host}
              when scheme in ["http", "https"] and not is_nil(host) ->
                put_change(changeset, :site_url, trimmed_url)

              _ ->
                add_error(
                  changeset,
                  :site_url,
                  "must be a valid URL starting with http:// or https://"
                )
            end
          end

        _ ->
          add_error(changeset, :site_url, "must be a valid URL")
      end
    end

    # Validates allow_registration is a valid boolean string
    defp validate_allow_registration(changeset) do
      validate_inclusion(changeset, :allow_registration, ["true", "false"],
        message: "must be either 'true' or 'false'"
      )
    end

    # Validates new_user_default_role is a valid non-Owner role
    defp validate_new_user_default_role(changeset) do
      owner_role = PhoenixKit.Users.Role.system_roles().owner

      # Get all valid role names except Owner
      all_roles = PhoenixKit.Users.Roles.list_roles()

      valid_roles =
        all_roles
        |> Enum.reject(fn role -> role.name == owner_role end)
        |> Enum.map(fn role -> role.name end)

      validate_inclusion(changeset, :new_user_default_role, valid_roles,
        message: "must be a valid role (Owner is reserved for first user)"
      )
    end

    # Validates week_start_day is a valid weekday number (1-7)
    defp validate_week_start_day(changeset) do
      validate_inclusion(changeset, :week_start_day, ["1", "2", "3", "4", "5", "6", "7"],
        message: "must be a valid weekday (1-7)"
      )
    end

    # Validates timezone offset is within acceptable range
    defp validate_timezone(changeset) do
      validate_change(changeset, :time_zone, fn :time_zone, time_zone ->
        case Integer.parse(time_zone) do
          {offset, ""} when offset >= -12 and offset <= 12 ->
            []

          _ ->
            [time_zone: "must be a valid timezone offset between -12 and +12"]
        end
      end)
    end

    # Validates date format is one of the supported formats
    defp validate_date_format(changeset) do
      supported_formats = ["Y-m-d", "m/d/Y", "d/m/Y", "d.m.Y", "d-m-Y", "F j, Y"]

      validate_inclusion(changeset, :date_format, supported_formats,
        message: "must be one of the supported date formats"
      )
    end

    # Validates time format is one of the supported formats  
    defp validate_time_format(changeset) do
      supported_formats = ["H:i", "h:i A"]

      validate_inclusion(changeset, :time_format, supported_formats,
        message: "must be either 24-hour (H:i) or 12-hour (h:i A) format"
      )
    end
  end
end
