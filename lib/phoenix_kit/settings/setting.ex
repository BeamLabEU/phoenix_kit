defmodule PhoenixKit.Settings.Setting do
  @moduledoc """
  Setting schema for PhoenixKit system settings.

  This schema defines system-wide settings that can be configured through
  the admin panel. Settings are stored as key-value pairs with timestamps.

  ## Fields

  - `key`: Setting identifier (unique, required)
  - `value`: Setting value (string format, for simple settings)
  - `value_json`: Setting value (JSONB format, for complex data structures)
  - `module`: Module/feature identifier for organization (optional)
  - `date_added`: When the setting was first created
  - `date_updated`: When the setting was last modified

  ## Value Storage Strategy

  Settings can use either `value` (string) OR `value_json` (JSONB), but not both:
  - Use `value` for simple string settings (themes, toggles, simple config)
  - Use `value_json` for complex data (objects, arrays, nested structures)
  - When both are present, `value_json` takes precedence

  ## Default Settings

  PhoenixKit includes three default system settings:

  - **time_zone**: System timezone offset (default: "0" for UTC)
  - **date_format**: Date display format (default: "Y-m-d")
  - **time_format**: Time display format (default: "H:i" for 24-hour)

  ## Usage Examples

      # Create a simple string setting
      %Setting{}
      |> Setting.changeset(%{key: "theme", value: "dark"})
      |> Repo.insert()

      # Create a complex JSON setting
      %Setting{}
      |> Setting.changeset(%{key: "app_config", value_json: %{"theme" => "dark", "features" => ["auth", "admin"]}})
      |> Repo.insert()

      # Update existing setting
      setting
      |> Setting.changeset(%{value: "light"})
      |> Repo.update()
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Settings that are allowed to have empty/nil values
  @optional_settings [
    # AWS Credentials
    "aws_access_key_id",
    "aws_secret_access_key",
    "aws_region",
    # AWS Infrastructure
    "aws_sqs_queue_url",
    "aws_sqs_dlq_url",
    "aws_sqs_queue_arn",
    "aws_sns_topic_arn",
    "aws_ses_configuration_set",
    "sqs_polling_interval_ms",
    # General
    "site_url",
    "site_icon_file_uuid",
    "default_tab_title",
    # Empty = no site default country; dates then follow `date_format`
    "format_country",
    # Empty = core falls back to its own `/users/log-in`, which exists in every
    # install and every locale (see `Routes.main_page_path/0`).
    "main_page_path",
    # Post-login redirects (empty = default behavior)
    "after_registration_path",
    # Empty = core's own /profile/settings (see `Routes.user_settings_path/1`).
    "user_settings_path",
    # OAuth Provider Credentials
    "oauth_google_client_id",
    "oauth_google_client_secret",
    "oauth_github_client_id",
    "oauth_github_client_secret",
    "oauth_facebook_app_id",
    "oauth_facebook_app_secret",
    # Unset until the Apple Sign-In feature and its admin UI exist
    "oauth_apple_private_key",
    # Cloudflare Turnstile keys — unset until an admin switches it on
    "turnstile_site_key",
    "turnstile_secret_key",
    # Billing-provider secrets (phoenix_kit_billing) — unset until an admin
    # configures that provider
    "billing_stripe_secret_key",
    "billing_stripe_webhook_secret",
    "billing_stripe_api_key",
    "billing_paypal_client_secret",
    "billing_paypal_webhook_secret",
    "billing_razorpay_key_secret",
    "billing_razorpay_webhook_secret",
    "billing_everypay_api_secret",
    # Auth Page Branding
    "auth_logo_file_uuid",
    "auth_background_image_file_uuid",
    "auth_background_image_mobile_file_uuid",
    "auth_background_color",
    # Maintenance Schedule (can be empty when no schedule is set)
    "maintenance_scheduled_start",
    "maintenance_scheduled_end",
    # Emails Transactional (blank falls back to app config, then a built-in default —
    # see PhoenixKit.Mailer.get_from_name/0, get_from_email/0)
    "from_name",
    "from_email",
    # Blank means "no default send integration" — deliver_email/2 falls back
    # to the static app-config/built-in mailer (see PhoenixKit.Mailer)
    "default_email_integration_uuid",
    # Blank means the neutral default accent (PhoenixKit.Email.Branding); the
    # field starts blank, so its first save is often an empty one.
    "email_accent_color",
    # Crawlers — verification tags and the llms.txt extra are legitimately
    # empty. Without these entries the FIRST write of an empty value (no row
    # yet) fails validation, so a form saving both slots partially applies:
    # the non-empty slot lands, the empty one errors, and the flash reports
    # failure for a half-applied save.
    "crawlers_google_verification",
    "crawlers_bing_verification",
    "crawlers_llms_extra",
    # Website access — a password not yet set, a link not yet made, a
    # redirect URL or allowed list left blank: all legitimately empty
    # (same first-write class as the crawlers keys).
    "website_access_password",
    "website_access_link_token",
    "website_access_gate_epoch",
    "website_access_redirect_url",
    "website_access_allowed_addresses",
    "maintenance_header",
    "maintenance_subtext",
    # Role switcher — no always-on custom roles is the default.
    "role_switcher_always_on_roles"
  ]

  @doc false
  def optional_settings, do: @optional_settings

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          key: String.t() | nil,
          value: String.t() | nil,
          value_json: map() | nil,
          module: String.t() | nil,
          date_added: DateTime.t() | nil,
          date_updated: DateTime.t() | nil
        }

  schema "phoenix_kit_settings" do
    field :key, :string
    # `redact: true` keeps both values out of `inspect/1` of a Setting or of a
    # changeset over it (error logs, IEx): they carry the `enc:v1:` ciphertext
    # of secret rows, or the plaintext when encryption is off.
    field :value, :string, redact: true
    field :value_json, :map, redact: true
    field :module, :string
    field :date_added, :utc_datetime
    field :date_updated, :utc_datetime
  end

  @doc """
  Creates a changeset for setting creation and updates.

  Validates that key and value are present and key is unique.
  Automatically sets date_updated to current time on updates.
  """
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :value_json, :module, :date_added, :date_updated])
    |> validate_required([:key])
    |> validate_length(:key, min: 1, max: 255)
    |> validate_setting_value()
    |> validate_value_exclusivity()
    |> validate_length(:module, max: 255)
    |> unique_constraint(:key, name: :phoenix_kit_settings_key_uidx)
    |> maybe_encrypt_restricted_value()
    |> maybe_set_timestamps()
  end

  @doc """
  Creates a changeset for updating only the value field.

  This is used when updating existing settings through the admin panel.
  Automatically updates the date_updated timestamp.
  """
  def update_changeset(setting, attrs) do
    setting
    |> cast(attrs, [:value, :value_json, :module])
    |> validate_setting_value()
    |> validate_value_exclusivity()
    |> validate_length(:module, max: 255)
    |> maybe_encrypt_restricted_value()
    |> put_change(:date_updated, UtilsDate.utc_now())
  end

  # S015 pt.3 (write side): a NEW value for a key in
  # `PhoenixKit.Settings.restricted_setting_keys/0` (`oauth_*_secret`,
  # `aws_access_key_id`/`aws_secret_access_key` — live credential material,
  # not just data an admin would rather keep quiet) is stored encrypted.
  # `get_change/2`, not `get_field/2`: `get_change/2` is `nil` both when
  # `attrs` never carried `:value` at all AND when it did but the submitted
  # value equals what `changeset.data` already holds (Ecto's own cast
  # diffing, not something this function decides) — either way, nothing
  # here re-touches whatever is already stored, encrypted or not. (Every
  # current caller happens to always pass `:value` — e.g.
  # `update_setting_with_module/3` always includes it alongside `module` —
  # so it is this second case, an unchanged resubmission, not an absent
  # key, that `get_change/2` actually needs to catch today; a future caller
  # that omits `:value` entirely is covered by the same check for free.)
  # Existing plaintext rows are deliberately left alone by this change —
  # migrating them is a separate, live-database step, not implied by this
  # changeset.
  #
  # `Encryption.encrypt_value/1` already does the right thing for every edge
  # case this needs: nil/empty pass through unchanged (no ciphertext for
  # nothing to protect — matches `@optional_settings` allowing these keys to
  # be blank), and an already-`enc:v1:`-prefixed value passes through
  # unchanged too (idempotent, so re-saving an already-encrypted value never
  # double-wraps it).
  defp maybe_encrypt_restricted_value(changeset) do
    key = get_field(changeset, :key)

    case get_change(changeset, :value) do
      nil ->
        changeset

      value when is_binary(value) ->
        if key in PhoenixKit.Settings.restricted_setting_keys() do
          put_change(changeset, :value, Encryption.encrypt_value(value))
        else
          changeset
        end
    end
  end

  # Private helper to set timestamps on new records
  defp maybe_set_timestamps(changeset) do
    case changeset.data.uuid do
      nil ->
        now = UtilsDate.utc_now()

        changeset
        |> put_change(:date_added, now)
        |> put_change(:date_updated, now)

      _uuid ->
        put_change(changeset, :date_updated, UtilsDate.utc_now())
    end
  end

  # Validates setting values with special handling for optional fields
  defp validate_setting_value(changeset) do
    key = get_field(changeset, :key)
    value = get_field(changeset, :value)
    value_json = get_field(changeset, :value_json)

    # Skip validation if using JSON value
    if value_json do
      changeset
    else
      cond do
        # Optional settings (AWS credentials, site_url, etc.) can be empty
        key in @optional_settings ->
          case value do
            nil -> put_change(changeset, :value, "")
            _ -> validate_length(changeset, :value, max: 1000)
          end

        # For settings with JSON data being set, allow nil/empty value
        Map.get(changeset.changes, :value_json) ->
          changeset

        # All other settings require non-empty values when using string storage
        true ->
          validate_length(changeset, :value, min: 1, max: 1000)
      end
    end
  end

  # Validates that a setting uses either value OR value_json, but not both
  defp validate_value_exclusivity(changeset) do
    value = get_field(changeset, :value)
    value_json = get_field(changeset, :value_json)
    key = get_field(changeset, :key)

    cond do
      # Both have meaningful values - only allow one
      not is_nil(value) and value != "" and not is_nil(value_json) ->
        add_error(changeset, :value_json, "cannot set both value and value_json, choose one")

      # At least one meaningful value exists - valid
      (not is_nil(value) and value != "") or not is_nil(value_json) ->
        changeset

      # Optional settings can be empty
      key in @optional_settings ->
        changeset

      # Both are nil/empty - require at least one for new records
      true ->
        if is_nil(changeset.data.uuid) do
          add_error(changeset, :value, "must provide either value or value_json")
        else
          changeset
        end
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
    - `track_registration_geolocation`: Enable IP geolocation tracking during registration (true/false)

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

    alias PhoenixKit.Users.FormatCountry
    alias PhoenixKit.Utils.Routes, as: RouteUtils
    alias PhoenixKit.Utils.TimeZone

    @primary_key false
    embedded_schema do
      field :project_title, :string
      field :site_url, :string
      field :main_page_path, :string
      field :allow_registration, :string
      field :oauth_enabled, :string
      field :oauth_google_enabled, :string
      field :oauth_github_enabled, :string
      field :oauth_facebook_enabled, :string
      field :oauth_require_verified_email, :string
      field :magic_link_login_enabled, :string
      field :magic_link_registration_enabled, :string
      field :new_user_default_role, :string
      field :new_user_default_status, :string
      field :week_start_day, :string
      field :time_zone, :string
      field :date_format, :string
      field :format_country, :string
      field :time_format, :string
      field :editor_default_mode, :string
      field :track_registration_geolocation, :string
      field :registration_show_username, :string
      field :require_email_confirmation, :string
      field :remember_me_enabled, :string
      field :remember_me_default, :string
      field :after_login_path, :string
      field :after_registration_path, :string
      field :user_settings_path, :string
      # Organization Accounts
      field :enable_organization_accounts, :string
      field :registration_account_type, :string
      # Admin Panel Languages
      field :admin_languages, :string
      # OAuth Provider Credentials
      field :oauth_google_client_id, :string
      field :oauth_google_client_secret, :string
      field :oauth_github_client_id, :string
      field :oauth_github_client_secret, :string
      field :oauth_facebook_app_id, :string
      field :oauth_facebook_app_secret, :string
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
        :main_page_path,
        :allow_registration,
        :oauth_enabled,
        :oauth_google_enabled,
        :oauth_github_enabled,
        :oauth_facebook_enabled,
        :oauth_require_verified_email,
        :magic_link_login_enabled,
        :magic_link_registration_enabled,
        :new_user_default_role,
        :new_user_default_status,
        :week_start_day,
        :time_zone,
        :date_format,
        :format_country,
        :time_format,
        :editor_default_mode,
        :track_registration_geolocation,
        :registration_show_username,
        :require_email_confirmation,
        :remember_me_enabled,
        :remember_me_default,
        :after_login_path,
        :after_registration_path,
        :user_settings_path,
        :enable_organization_accounts,
        :registration_account_type,
        :admin_languages,
        :oauth_google_client_id,
        :oauth_google_client_secret,
        :oauth_github_client_id,
        :oauth_github_client_secret,
        :oauth_facebook_app_id,
        :oauth_facebook_app_secret
      ])
      |> validate_required([
        :project_title,
        :new_user_default_role,
        :new_user_default_status,
        :week_start_day,
        :time_zone,
        :date_format,
        :time_format,
        :track_registration_geolocation
      ])
      |> validate_length(:project_title, min: 1, max: 100)
      |> validate_url()
      |> validate_allow_registration()
      |> validate_oauth_enabled()
      |> validate_oauth_provider_enabled(:oauth_google_enabled)
      |> validate_oauth_provider_enabled(:oauth_github_enabled)
      |> validate_oauth_provider_enabled(:oauth_facebook_enabled)
      |> validate_magic_link_enabled(:magic_link_login_enabled)
      |> validate_magic_link_enabled(:magic_link_registration_enabled)
      |> validate_new_user_default_role()
      |> validate_new_user_default_status()
      |> validate_week_start_day()
      |> validate_timezone()
      |> validate_date_format()
      |> validate_format_country()
      |> validate_time_format()
      |> validate_track_registration_geolocation()
      # Allowlist comes from the context's canonical mode list, so a new editor
      # mode can't be accepted here while `get_editor_mode/0` still coerces it
      # away (or offered in the picker while the changeset rejects it).
      |> validate_inclusion(:editor_default_mode, PhoenixKit.Settings.editor_modes())
      |> validate_inclusion(:enable_organization_accounts, ["true", "false"])
      # Allowlist comes from the context's canonical list, so the picker and
      # the accepted set cannot disagree.
      |> validate_inclusion(
        :registration_account_type,
        PhoenixKit.Settings.registration_account_types()
      )
      |> validate_inclusion(:require_email_confirmation, ["true", "false"],
        message: "must be either 'true' or 'false'"
      )
      |> validate_inclusion(:remember_me_enabled, ["true", "false"],
        message: "must be either 'true' or 'false'"
      )
      |> validate_inclusion(:remember_me_default, ["true", "false"],
        message: "must be either 'true' or 'false'"
      )
      |> validate_local_path(:after_login_path)
      |> validate_local_path(:after_registration_path)
      |> validate_local_path(:main_page_path)
      |> validate_local_path(:user_settings_path)
    end

    # Validates a redirect-target setting is a local path (optional field —
    # allows empty). Both rules come from `PhoenixKit.Utils.Routes`, which is
    # also what resolves the setting on read: `local_path?/1` so a saved value
    # can never become an open redirect, and `auth_page?/1` so it can't point
    # at a page that bounces an authenticated visitor (a permanent loop — and
    # `/users/log-out`, a real GET route, would sign every user straight back
    # out with nobody left signed in to undo it). Deliberately NOT a second
    # copy of the path list: guarded on read but forgotten on write is exactly
    # how the two would drift.
    defp validate_local_path(changeset, field) do
      changeset
      |> update_change(field, &String.trim/1)
      |> validate_change(field, fn ^field, value ->
        cond do
          value == "" ->
            []

          not RouteUtils.local_path?(value) ->
            [{field, "must be a local path starting with \"/\""}]

          RouteUtils.auth_page?(value) ->
            [{field, "cannot point at a sign-in page (it would loop)"}]

          true ->
            []
        end
      end)
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

    # Validates new_user_default_role is a valid role other than Owner and
    # Admin: Owner is reserved for the first user, and Admin would give every
    # self-registered account the admin panel. `Roles` applies the same rule
    # when it reads the setting, so a row written around this changeset is
    # still never used.
    defp validate_new_user_default_role(changeset) do
      system = Role.system_roles()

      valid_roles =
        Roles.list_roles()
        |> Enum.reject(fn role -> role.name in [system.owner, system.admin] end)
        |> Enum.map(fn role -> role.name end)

      validate_inclusion(changeset, :new_user_default_role, valid_roles,
        message: "must be a valid role other than Owner or Admin"
      )
    end

    # Validates new_user_default_status is a valid boolean string
    defp validate_new_user_default_status(changeset) do
      validate_inclusion(changeset, :new_user_default_status, ["true", "false"],
        message: "must be either 'true' or 'false'"
      )
    end

    # Validates week_start_day is a valid weekday number (1-7)
    defp validate_week_start_day(changeset) do
      validate_inclusion(changeset, :week_start_day, ["1", "2", "3", "4", "5", "6", "7"],
        message: "must be a valid weekday (1-7)"
      )
    end

    # Accepts an IANA identifier ("Europe/Warsaw") and, still, the numeric
    # offsets every installation predating named timezones has stored, so
    # saving an unrelated setting on the same form does not fail on a value
    # the admin never touched.
    defp validate_timezone(changeset) do
      validate_change(changeset, :time_zone, fn :time_zone, time_zone ->
        if TimeZone.valid?(time_zone) do
          []
        else
          [time_zone: "must be a timezone identifier like Europe/Warsaw"]
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

    # Store the same canonical alpha-2 code as the user profile; blank clears it.
    defp validate_format_country(changeset) do
      case get_change(changeset, :format_country) do
        code when is_binary(code) ->
          cond do
            String.trim(code) == "" ->
              put_change(changeset, :format_country, nil)

            normalized = FormatCountry.normalize(code) ->
              put_change(changeset, :format_country, normalized)

            true ->
              add_error(changeset, :format_country, "must be a valid country code")
          end

        _ ->
          changeset
      end
    end

    # Validates time format is one of the supported formats
    defp validate_time_format(changeset) do
      supported_formats = ["H:i", "h:i A"]

      validate_inclusion(changeset, :time_format, supported_formats,
        message: "must be either 24-hour (H:i) or 12-hour (h:i A) format"
      )
    end

    # Validates track_registration_geolocation is a valid boolean string
    defp validate_track_registration_geolocation(changeset) do
      validate_inclusion(changeset, :track_registration_geolocation, ["true", "false"],
        message: "must be either 'true' or 'false'"
      )
    end

    # Validates oauth_enabled is a valid boolean string
    defp validate_oauth_enabled(changeset) do
      if get_field(changeset, :oauth_enabled) do
        validate_inclusion(changeset, :oauth_enabled, ["true", "false"],
          message: "must be either 'true' or 'false'"
        )
      else
        changeset
      end
    end

    # Validates OAuth provider enabled fields
    defp validate_oauth_provider_enabled(changeset, field) do
      if get_field(changeset, field) do
        validate_inclusion(changeset, field, ["true", "false"],
          message: "must be either 'true' or 'false'"
        )
      else
        changeset
      end
    end

    # Validates magic link enabled fields
    defp validate_magic_link_enabled(changeset, field) do
      if get_field(changeset, field) do
        validate_inclusion(changeset, field, ["true", "false"],
          message: "must be either 'true' or 'false'"
        )
      else
        changeset
      end
    end
  end
end
