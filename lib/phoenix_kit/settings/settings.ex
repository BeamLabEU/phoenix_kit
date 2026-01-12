defmodule PhoenixKit.Settings do
  @moduledoc """
  The Settings context for system configuration management.

  This module provides functions for managing system-wide settings in PhoenixKit.
  Settings are stored in the database and can be updated through the admin panel.

  ## Core Functions

  ### Settings Management

  - `get_setting/1` - Get a setting value by key
  - `get_setting/2` - Get a setting value with default fallback
  - `update_setting/2` - Update or create a setting
  - `list_all_settings/0` - Get all settings as a map

  ### JSON Settings Management

  - `get_json_setting/1` - Get a JSON setting value by key
  - `get_json_setting/2` - Get a JSON setting value with default fallback
  - `update_json_setting/2` - Update or create a JSON setting
  - `get_json_setting_cached/2` - Get cached JSON setting with fallback

  ### Default Settings

  The system includes core settings:
  - `project_title`: Application/project title
  - `site_url`: Website URL for the application (optional)
  - `allow_registration`: Allow public user registration (default: true)
  - `oauth_enabled`: Enable OAuth authentication (default: false)
  - `time_zone`: System timezone offset
  - `date_format`: Date display format
  - `time_format`: Time display format
  - `track_registration_geolocation`: Enable IP geolocation tracking during registration (default: false)

  ## Usage Examples

      # Get a simple string setting with default
      timezone = PhoenixKit.Settings.get_setting("time_zone", "0")

      # Update a simple string setting
      {:ok, setting} = PhoenixKit.Settings.update_setting("time_zone", "+1")

      # Get a JSON setting with default
      config = PhoenixKit.Settings.get_json_setting("app_config", %{})

      # Update a JSON setting
      app_config = %{
        "theme" => %{"primary" => "#3b82f6", "secondary" => "#64748b"},
        "features" => ["notifications", "dark_mode"],
        "limits" => %{"max_users" => 1000}
      }
      {:ok, setting} = PhoenixKit.Settings.update_json_setting("app_config", app_config)

      # Get all settings as a map
      settings = PhoenixKit.Settings.list_all_settings()
      # => %{"time_zone" => "0", "date_format" => "Y-m-d", "time_format" => "H:i"}

  ## Configuration

  The context uses PhoenixKit's configured repository and respects table prefixes
  set during installation.
  """
  require Logger

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [add_error: 3]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings.Events, as: SettingsEvents
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Settings.Setting.SettingsForm
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @default_locale PhoenixKit.Config.default_locale()
  @cache_name :settings

  # Gets the configured repository for database operations.
  # Uses PhoenixKit.RepoHelper to get the configured repo with proper prefix support.
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end

  @doc """
  Gets default values for all settings.

  Returns a map with setting keys and their default values.
  These defaults match the ones defined in the V03 migration.

  ## Examples

      iex> PhoenixKit.Settings.get_defaults()
      %{
        "time_zone" => "0",
        "date_format" => "Y-m-d",
        "time_format" => "H:i"
      }
  """
  def get_defaults do
    %{
      "project_title" => "PhoenixKit",
      "site_url" => "",
      "allow_registration" => "true",
      "oauth_enabled" => "false",
      "oauth_google_enabled" => "false",
      "oauth_apple_enabled" => "false",
      "oauth_github_enabled" => "false",
      "oauth_facebook_enabled" => "false",
      "magic_link_login_enabled" => "true",
      "magic_link_registration_enabled" => "true",
      "new_user_default_role" => "User",
      "new_user_default_status" => "true",
      "week_start_day" => "1",
      "time_zone" => "0",
      "date_format" => "Y-m-d",
      "time_format" => "H:i",
      "track_registration_geolocation" => "false",
      "registration_show_username" => "true",
      # Email Settings
      "email_enabled" => "false",
      "email_save_body" => "false",
      "email_ses_events" => "false",
      "email_retention_days" => "90",
      "email_sampling_rate" => "100",
      "email_compress_body" => "30",
      "email_archive_to_s3" => "false",
      # AWS Configuration for SQS Integration
      "aws_access_key_id" => PhoenixKit.Config.AWS.access_key_id(),
      "aws_secret_access_key" => PhoenixKit.Config.AWS.secret_access_key(),
      "aws_region" => PhoenixKit.Config.AWS.region(),
      "aws_sns_topic_arn" => "",
      "aws_sqs_queue_url" => "",
      "aws_sqs_queue_arn" => "",
      "aws_sqs_dlq_url" => "",
      "aws_ses_configuration_set" => "phoenixkit-tracking",
      # SQS Worker Configuration
      "sqs_polling_enabled" => "false",
      "sqs_polling_interval_ms" => "5000",
      "sqs_max_messages_per_poll" => "10",
      "sqs_visibility_timeout" => "300",
      # SEO
      "seo_module_enabled" => "false",
      "seo_no_index" => "false",
      # Webhook Security Settings
      "webhook_verify_sns_signature" => "true",
      "webhook_check_aws_ip" => "true",
      "webhook_rate_limit_enabled" => "true",
      # OAuth Provider Credentials
      "oauth_google_client_id" => "",
      "oauth_google_client_secret" => "",
      "oauth_apple_client_id" => "",
      "oauth_apple_team_id" => "",
      "oauth_apple_key_id" => "",
      "oauth_apple_private_key" => "",
      "oauth_github_client_id" => "",
      "oauth_github_client_secret" => "",
      "oauth_facebook_app_id" => "",
      "oauth_facebook_app_secret" => "",
      # Admin Panel Languages - default is just the default locale for fresh installs
      "admin_languages" => Jason.encode!([@default_locale])
    }
  end

  @doc """
  Gets a setting value by key.

  Returns the setting value as a string, or nil if not found.

  ## Examples

      iex> PhoenixKit.Settings.get_setting("time_zone")
      "0"

      iex> PhoenixKit.Settings.get_setting("non_existent")
      nil
  """
  def get_setting(key) when is_binary(key) do
    setting_record = repo().get_by(Setting, key: key)

    case setting_record do
      %Setting{value: value} -> value
      nil -> nil
    end
  end

  @doc """
  Gets a setting value by key with a default fallback.

  Returns the setting value as a string, or the default if not found.

  ## Examples

      iex> PhoenixKit.Settings.get_setting("time_zone", "0")
      "0"

      iex> PhoenixKit.Settings.get_setting("non_existent", "default")
      "default"
  """
  def get_setting(key, default) when is_binary(key) do
    get_setting(key) || default
  end

  @doc """
  Gets a setting value from cache with fallback to database.

  This is the preferred method for getting settings as it provides
  significant performance improvements over direct database queries.

  ## Examples

      iex> PhoenixKit.Settings.get_setting_cached("date_format", "Y-m-d")
      "F j, Y"

      iex> PhoenixKit.Settings.get_setting_cached("non_existent", "default")
      "default"
  """
  def get_setting_cached(key, default \\ nil) when is_binary(key) do
    # Use a special sentinel to distinguish "not in cache" from "cached nil" or "cached non-existent"
    cache_miss_sentinel = :__cache_not_found__
    setting_not_exists_sentinel = :__setting_does_not_exist__

    case PhoenixKit.Cache.get(@cache_name, key, cache_miss_sentinel) do
      ^cache_miss_sentinel ->
        # Cache miss - query database and cache result
        value = query_and_cache_setting(key)
        value || default

      ^setting_not_exists_sentinel ->
        # Setting doesn't exist in database (cached result)
        default

      value ->
        # Cache hit with actual value (including nil if setting exists with nil value)
        value
    end
  rescue
    error ->
      # Cache system unavailable, fallback to regular database query
      Logger.warning("Settings cache error: #{inspect(error)}, falling back to database")
      get_setting(key, default)
  end

  @doc """
  Gets multiple settings from cache in a single operation.

  More efficient than multiple individual get_setting_cached/2 calls
  when you need several settings at once.

  ## Examples

      iex> PhoenixKit.Settings.get_settings_cached(["date_format", "time_format"])
      %{"date_format" => "F j, Y", "time_format" => "h:i A"}

      iex> defaults = %{"date_format" => "Y-m-d", "time_format" => "H:i"}
      iex> PhoenixKit.Settings.get_settings_cached(["date_format", "time_format"], defaults)
      %{"date_format" => "F j, Y", "time_format" => "h:i A"}
  """
  def get_settings_cached(keys, defaults \\ %{}) when is_list(keys) do
    setting_not_exists_sentinel = :__setting_does_not_exist__

    cached_results = PhoenixKit.Cache.get_multiple(@cache_name, keys, %{})

    # Process cached results, replacing sentinel values with defaults
    Enum.reduce(cached_results, %{}, fn {key, value}, acc ->
      if value == setting_not_exists_sentinel do
        Map.put(acc, key, Map.get(defaults, key))
      else
        Map.put(acc, key, value)
      end
    end)
  rescue
    error ->
      Logger.warning(
        "Settings cache error: #{inspect(error)}, falling back to batch database query"
      )

      # Batch query all keys in a single database operation
      batch_results = query_settings_batch(keys)

      # Merge with defaults for any missing keys
      Enum.reduce(keys, %{}, fn key, acc ->
        value = Map.get(batch_results, key) || Map.get(defaults, key)
        Map.put(acc, key, value)
      end)
  end

  @doc """
  Gets multiple JSON settings from cache in a single operation.

  More efficient than multiple individual get_json_setting_cached/2 calls
  when you need several JSON settings at once.

  ## Examples

      iex> PhoenixKit.Settings.get_json_settings_cached(["app_config", "feature_flags"])
      %{"app_config" => %{"theme" => "dark"}, "feature_flags" => %{"auth" => true}}

      iex> defaults = %{"app_config" => %{}, "feature_flags" => %{}}
      iex> PhoenixKit.Settings.get_json_settings_cached(["app_config", "feature_flags"], defaults)
      %{"app_config" => %{"theme" => "dark"}, "feature_flags" => %{"auth" => true}}
  """
  def get_json_settings_cached(keys, defaults \\ %{}) when is_list(keys) do
    setting_not_exists_sentinel = :__setting_does_not_exist__

    cached_results = PhoenixKit.Cache.get_multiple(@cache_name, keys, %{})

    # Process cached results, replacing sentinel values with defaults
    Enum.reduce(cached_results, %{}, fn {key, value}, acc ->
      if value == setting_not_exists_sentinel do
        Map.put(acc, key, Map.get(defaults, key))
      else
        Map.put(acc, key, value)
      end
    end)
  rescue
    error ->
      Logger.warning(
        "Settings cache error: #{inspect(error)}, falling back to batch database query"
      )

      # Batch query all keys in a single database operation
      batch_results = query_json_settings_batch(keys)

      # Merge with defaults for any missing keys
      Enum.reduce(keys, %{}, fn key, acc ->
        value = Map.get(batch_results, key) || Map.get(defaults, key)
        Map.put(acc, key, value)
      end)
  end

  @doc """
  Gets the display label for a setting option value.

  ## Examples

      iex> options = [{"YYYY-MM-DD", "Y-m-d"}, {"MM/DD/YYYY", "m/d/Y"}]
      iex> PhoenixKit.Settings.get_option_label("Y-m-d", options)
      "YYYY-MM-DD"
  """
  def get_option_label(value, options) do
    case Enum.find(options, fn {_label, val} -> val == value end) do
      {label, _value} -> label
      nil -> value
    end
  end

  ## JSON Settings Functions

  @doc """
  Gets a JSON setting value by key.

  Returns the JSON value as a map/list/primitive, or nil if not found.

  ## Examples

      iex> PhoenixKit.Settings.get_json_setting("app_config")
      %{"theme" => "dark", "features" => ["auth", "admin"]}

      iex> PhoenixKit.Settings.get_json_setting("non_existent")
      nil
  """
  def get_json_setting(key) when is_binary(key) do
    setting_record = repo().get_by(Setting, key: key)

    case setting_record do
      %Setting{value_json: value_json} when not is_nil(value_json) -> value_json
      _ -> nil
    end
  end

  @doc """
  Gets a JSON setting value by key with a default fallback.

  Returns the JSON value as a map/list/primitive, or the default if not found.

  ## Examples

      iex> PhoenixKit.Settings.get_json_setting("app_config", %{})
      %{"theme" => "dark", "features" => ["auth", "admin"]}

      iex> PhoenixKit.Settings.get_json_setting("non_existent", %{"default" => true})
      %{"default" => true}
  """
  def get_json_setting(key, default) when is_binary(key) do
    get_json_setting(key) || default
  end

  @doc """
  Gets a JSON setting value from cache with fallback to database.

  This is the preferred method for getting JSON settings as it provides
  significant performance improvements over direct database queries.

  ## Examples

      iex> PhoenixKit.Settings.get_json_setting_cached("app_config", %{})
      %{"theme" => "dark", "features" => ["auth", "admin"]}

      iex> PhoenixKit.Settings.get_json_setting_cached("non_existent", %{"default" => true})
      %{"default" => true}
  """
  def get_json_setting_cached(key, default \\ nil) when is_binary(key) do
    # Use a special sentinel to distinguish "not in cache" from "cached nil" or "cached non-existent"
    cache_miss_sentinel = :__cache_not_found__
    setting_not_exists_sentinel = :__setting_does_not_exist__

    case PhoenixKit.Cache.get(@cache_name, key, cache_miss_sentinel) do
      ^cache_miss_sentinel ->
        # Cache miss - query database and cache result
        value = query_and_cache_json_setting(key)
        value || default

      ^setting_not_exists_sentinel ->
        # Setting doesn't exist in database (cached result)
        default

      value ->
        # Cache hit with actual value (including nil if setting exists with nil value)
        value
    end
  rescue
    error ->
      # Cache system unavailable, fallback to regular database query
      Logger.warning("Settings cache error: #{inspect(error)}, falling back to database")
      get_json_setting(key, default)
  end

  @doc """
  Updates or creates a JSON setting with the given key and value.

  If the setting exists, updates its value_json and timestamp.
  If the setting doesn't exist, creates a new one.
  Clears any existing string value when setting JSON value.

  Returns `{:ok, setting}` on success, `{:error, changeset}` on failure.

  ## Examples

      iex> config = %{"theme" => "dark", "features" => ["auth"]}
      iex> PhoenixKit.Settings.update_json_setting("app_config", config)
      {:ok, %Setting{key: "app_config", value_json: %{"theme" => "dark", "features" => ["auth"]}}}

      iex> PhoenixKit.Settings.update_json_setting("", %{})
      {:error, %Ecto.Changeset{}}
  """
  def update_json_setting(key, json_value) when is_binary(key) do
    result =
      case repo().get_by(Setting, key: key) do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value_json: json_value, value: nil})
          |> repo().update()

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value_json: json_value, value: nil})
          |> repo().insert()
      end

    # Invalidate cache on successful update
    case result do
      {:ok, _setting} -> PhoenixKit.Cache.invalidate(@cache_name, key)
      {:error, _changeset} -> :ok
    end

    result
  end

  @doc """
  Updates or creates a JSON setting with module association.

  Similar to update_json_setting/2 but allows specifying which module the setting belongs to.
  Useful for organizing feature-specific JSON settings.

  ## Examples

      iex> config = %{"enabled" => true, "options" => ["email", "sms"]}
      iex> PhoenixKit.Settings.update_json_setting_with_module("notifications", config, "messaging")
      {:ok, %Setting{key: "notifications", value_json: config, module: "messaging"}}
  """
  def update_json_setting_with_module(key, json_value, module)
      when is_binary(key) and is_binary(module) do
    existing_setting = repo().get_by(Setting, key: key)

    result =
      case existing_setting do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value_json: json_value, value: nil, module: module})
          |> repo().update()

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value_json: json_value, value: nil, module: module})
          |> repo().insert()
      end

    # Invalidate cache on successful update
    case result do
      {:ok, _setting} -> PhoenixKit.Cache.invalidate(@cache_name, key)
      {:error, _changeset} -> :ok
    end

    result
  end

  @doc """
  Gets OAuth credentials for a specific provider.

  Returns a map with all credentials for the given provider.
  Uses cache for performance - suitable for non-critical reads.

  ## Examples

      iex> PhoenixKit.Settings.get_oauth_credentials(:google)
      %{client_id: "google-client-id", client_secret: "google-client-secret"}

      iex> PhoenixKit.Settings.get_oauth_credentials(:apple)
      %{
        client_id: "apple-client-id",
        team_id: "apple-team-id",
        key_id: "apple-key-id",
        private_key: "-----BEGIN PRIVATE KEY-----..."
      }
  """
  def get_oauth_credentials(provider) when provider in [:google, :apple, :github, :facebook] do
    case provider do
      :google -> get_google_oauth_credentials()
      :apple -> get_apple_oauth_credentials()
      :github -> get_github_oauth_credentials()
      :facebook -> get_facebook_oauth_credentials()
    end
  end

  @doc """
  Gets OAuth credentials directly from database, bypassing cache.

  Use this for security-critical operations where fresh data is required,
  such as configuring OAuth providers after settings update.

  This prevents race conditions where cache invalidation hasn't completed
  before the credentials are read.

  ## Examples

      iex> PhoenixKit.Settings.get_oauth_credentials_direct(:google)
      %{client_id: "google-client-id", client_secret: "google-client-secret"}
  """
  def get_oauth_credentials_direct(provider)
      when provider in [:google, :apple, :github, :facebook] do
    case provider do
      :google -> get_google_oauth_credentials_direct()
      :apple -> get_apple_oauth_credentials_direct()
      :github -> get_github_oauth_credentials_direct()
      :facebook -> get_facebook_oauth_credentials_direct()
    end
  end

  defp get_google_oauth_credentials do
    keys = ["oauth_google_client_id", "oauth_google_client_secret"]
    defaults = %{"oauth_google_client_id" => "", "oauth_google_client_secret" => ""}
    settings = get_settings_cached(keys, defaults)

    %{
      client_id: settings["oauth_google_client_id"] || "",
      client_secret: settings["oauth_google_client_secret"] || ""
    }
  end

  defp get_apple_oauth_credentials do
    keys = [
      "oauth_apple_client_id",
      "oauth_apple_team_id",
      "oauth_apple_key_id",
      "oauth_apple_private_key"
    ]

    defaults = %{
      "oauth_apple_client_id" => "",
      "oauth_apple_team_id" => "",
      "oauth_apple_key_id" => "",
      "oauth_apple_private_key" => ""
    }

    settings = get_settings_cached(keys, defaults)

    %{
      client_id: settings["oauth_apple_client_id"] || "",
      team_id: settings["oauth_apple_team_id"] || "",
      key_id: settings["oauth_apple_key_id"] || "",
      private_key: settings["oauth_apple_private_key"] || ""
    }
  end

  defp get_github_oauth_credentials do
    keys = ["oauth_github_client_id", "oauth_github_client_secret"]
    defaults = %{"oauth_github_client_id" => "", "oauth_github_client_secret" => ""}
    settings = get_settings_cached(keys, defaults)

    %{
      client_id: settings["oauth_github_client_id"] || "",
      client_secret: settings["oauth_github_client_secret"] || ""
    }
  end

  defp get_facebook_oauth_credentials do
    keys = ["oauth_facebook_app_id", "oauth_facebook_app_secret"]
    defaults = %{"oauth_facebook_app_id" => "", "oauth_facebook_app_secret" => ""}
    settings = get_settings_cached(keys, defaults)

    %{
      app_id: settings["oauth_facebook_app_id"] || "",
      app_secret: settings["oauth_facebook_app_secret"] || ""
    }
  end

  # Direct database reads for OAuth credentials (bypassing cache)
  # Used by OAuthConfig.configure_providers() to avoid race conditions

  defp get_google_oauth_credentials_direct do
    keys = ["oauth_google_client_id", "oauth_google_client_secret"]
    settings = get_settings_direct(keys)

    %{
      client_id: Map.get(settings, "oauth_google_client_id", ""),
      client_secret: Map.get(settings, "oauth_google_client_secret", "")
    }
  end

  defp get_apple_oauth_credentials_direct do
    keys = [
      "oauth_apple_client_id",
      "oauth_apple_team_id",
      "oauth_apple_key_id",
      "oauth_apple_private_key"
    ]

    settings = get_settings_direct(keys)

    %{
      client_id: Map.get(settings, "oauth_apple_client_id", ""),
      team_id: Map.get(settings, "oauth_apple_team_id", ""),
      key_id: Map.get(settings, "oauth_apple_key_id", ""),
      private_key: Map.get(settings, "oauth_apple_private_key", "")
    }
  end

  defp get_github_oauth_credentials_direct do
    keys = ["oauth_github_client_id", "oauth_github_client_secret"]
    settings = get_settings_direct(keys)

    %{
      client_id: Map.get(settings, "oauth_github_client_id", ""),
      client_secret: Map.get(settings, "oauth_github_client_secret", "")
    }
  end

  defp get_facebook_oauth_credentials_direct do
    keys = ["oauth_facebook_app_id", "oauth_facebook_app_secret"]
    settings = get_settings_direct(keys)

    %{
      app_id: Map.get(settings, "oauth_facebook_app_id", ""),
      app_secret: Map.get(settings, "oauth_facebook_app_secret", "")
    }
  end

  @doc """
  Gets multiple settings directly from database, bypassing cache.

  Use this for security-critical operations where fresh data is required.
  Returns a map with setting keys and their values.

  ## Examples

      iex> PhoenixKit.Settings.get_settings_direct(["oauth_google_client_id", "oauth_google_client_secret"])
      %{"oauth_google_client_id" => "client-id", "oauth_google_client_secret" => "secret"}
  """
  def get_settings_direct(keys) when is_list(keys) do
    if repo_available?() do
      Setting
      |> where([s], s.key in ^keys)
      |> select([s], {s.key, s.value})
      |> repo().all()
      |> Map.new()
    else
      %{}
    end
  rescue
    error ->
      # Handle missing uuid column during V40 migration gracefully (silent)
      unless migration_column_error?(error) do
        Logger.warning("Failed to get settings directly from DB: #{inspect(error)}")
      end

      %{}
  end

  @doc """
  Checks if OAuth credentials are configured for a provider.

  Uses cache for performance - suitable for non-critical checks.

  ## Examples

      iex> PhoenixKit.Settings.has_oauth_credentials?(:google)
      true
  """
  def has_oauth_credentials?(provider) when provider in [:google, :apple, :github, :facebook] do
    credentials = get_oauth_credentials(provider)

    case provider do
      :google -> validate_google_credentials(credentials)
      :apple -> validate_apple_credentials(credentials)
      :github -> validate_github_credentials(credentials)
      :facebook -> validate_facebook_credentials(credentials)
    end
  end

  @doc """
  Checks if OAuth credentials are configured for a provider, reading directly from database.

  Bypasses cache to ensure fresh data. Use this when configuring OAuth providers
  after settings update to avoid race conditions.

  ## Examples

      iex> PhoenixKit.Settings.has_oauth_credentials_direct?(:google)
      true
  """
  def has_oauth_credentials_direct?(provider)
      when provider in [:google, :apple, :github, :facebook] do
    credentials = get_oauth_credentials_direct(provider)

    case provider do
      :google -> validate_google_credentials(credentials)
      :apple -> validate_apple_credentials(credentials)
      :github -> validate_github_credentials(credentials)
      :facebook -> validate_facebook_credentials(credentials)
    end
  end

  defp validate_google_credentials(credentials) do
    credentials.client_id != "" and credentials.client_secret != ""
  end

  defp validate_apple_credentials(credentials) do
    credentials.client_id != "" and
      credentials.team_id != "" and
      credentials.key_id != "" and
      credentials.private_key != ""
  end

  defp validate_github_credentials(credentials) do
    credentials.client_id != "" and credentials.client_secret != ""
  end

  defp validate_facebook_credentials(credentials) do
    credentials.app_id != "" and credentials.app_secret != ""
  end

  @doc """
  Gets a boolean setting value by key with a default fallback.

  Converts string values "true"/"false" to actual boolean values.
  Returns the default if the setting is not found or has an invalid value.

  ## Examples

      iex> PhoenixKit.Settings.get_boolean_setting("feature_enabled", false)
      false

      iex> PhoenixKit.Settings.get_boolean_setting("feature_enabled", true)
      true
  """
  def get_boolean_setting(key, default \\ false) when is_binary(key) and is_boolean(default) do
    raw_value = get_setting_cached(key, nil)

    case raw_value do
      "true" -> true
      "false" -> false
      nil -> default
      _ -> default
    end
  rescue
    # During compilation or when infrastructure isn't ready, return default silently
    _error -> default
  end

  @doc """
  Gets an integer setting value by key, with fallback to default.

  Converts the stored string value to an integer. If the setting doesn't exist
  or cannot be converted to an integer, returns the default value.

  ## Examples

      iex> PhoenixKit.Settings.get_integer_setting("max_items", 10)
      10

      iex> PhoenixKit.Settings.get_integer_setting("existing_number", 5)
      25  # if "25" is stored in database
  """
  def get_integer_setting(key, default \\ 0) when is_binary(key) and is_integer(default) do
    raw_value = get_setting_cached(key, nil)

    case raw_value do
      nil ->
        default

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer_value, _} -> integer_value
          :error -> default
        end

      _ ->
        default
    end
  end

  @doc """
  Lists all settings as a map with keys as setting names and values as setting values.

  Returns a map where keys are setting names and values are setting values.
  Useful for loading all settings at once for forms or configuration.

  ## Examples

      iex> PhoenixKit.Settings.list_all_settings()
      %{
        "time_zone" => "0",
        "date_format" => "Y-m-d",
        "time_format" => "H:i"
      }
  """
  def list_all_settings do
    Setting
    |> select([s], {s.key, s.value})
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Gets all settings with their full details (including timestamps).

  Returns a list of Setting structs. Useful for admin interfaces
  that need to show when settings were created/updated.

  ## Examples

      iex> PhoenixKit.Settings.list_settings()
      [
        %Setting{key: "time_zone", value: "0", date_added: ~U[2024-01-01 00:00:00.000000Z]},
        %Setting{key: "date_format", value: "Y-m-d", date_added: ~U[2024-01-01 00:00:00.000000Z]}
      ]
  """
  def list_settings do
    Setting
    |> order_by([s], s.key)
    |> repo().all()
  end

  @doc """
  Gets the available role options for the new user default role setting.

  Returns all roles from database except Owner, ordered by system roles first, then custom roles.

  ## Examples

      iex> PhoenixKit.Settings.get_role_options()
      [{"User", "User"}, {"Admin", "Admin"}, {"Manager", "Manager"}]
  """
  def get_role_options do
    owner_role = Role.system_roles().owner

    # Get all roles from database except Owner role
    all_roles = Roles.list_roles()

    # Filter out Owner role and convert to {label, value} format
    all_roles
    |> Enum.reject(fn role -> role.name == owner_role end)
    |> Enum.map(fn role -> {role.name, role.name} end)
  end

  @doc """
  Gets the available options for each setting type.

  Returns a map with setting keys and their available options as {label, value} tuples.
  Used to populate dropdown menus in the admin interface.

  ## Examples

      iex> PhoenixKit.Settings.get_setting_options()
      %{
        "time_zone" => [{"UTC-12", "-12"}, {"UTC+0 (GMT)", "0"}, {"UTC+8", "8"}],
        "date_format" => [{"YYYY-MM-DD", "Y-m-d"}, {"MM/DD/YYYY", "m/d/Y"}],
        "time_format" => [{"24 Hour (15:30)", "H:i"}, {"12 Hour (3:30 PM)", "h:i A"}]
      }
  """
  def get_setting_options do
    %{
      "new_user_default_role" => get_role_options(),
      "new_user_default_status" => [
        {"Active", "true"},
        {"Inactive", "false"}
      ],
      "week_start_day" => [
        {"Monday", "1"},
        {"Tuesday", "2"},
        {"Wednesday", "3"},
        {"Thursday", "4"},
        {"Friday", "5"},
        {"Saturday", "6"},
        {"Sunday", "7"}
      ],
      "time_zone" => [
        {"UTC-12 (Baker Island)", "-12"},
        {"UTC-11 (Pago Pago, Niue)", "-11"},
        {"UTC-10 (Honolulu, Tahiti)", "-10"},
        {"UTC-9 (Anchorage, Juneau)", "-9"},
        {"UTC-8 (Los Angeles, Vancouver, Seattle)", "-8"},
        {"UTC-7 (Denver, Phoenix, Calgary)", "-7"},
        {"UTC-6 (Chicago, Mexico City, Guatemala)", "-6"},
        {"UTC-5 (New York, Toronto, Bogotá, Lima)", "-5"},
        {"UTC-4 (Halifax, Caracas, Santiago)", "-4"},
        {"UTC-3 (Buenos Aires, São Paulo, Montevideo)", "-3"},
        {"UTC-2 (South Georgia)", "-2"},
        {"UTC-1 (Azores, Cape Verde)", "-1"},
        {"UTC+0 (London, Dublin, Lisbon, Accra)", "0"},
        {"UTC+1 (Paris, Berlin, Rome, Madrid, Lagos)", "1"},
        {"UTC+2 (Kyiv, Athens, Helsinki, Cairo, Johannesburg)", "2"},
        {"UTC+3 (Istanbul, Riyadh, Nairobi, Baghdad, Moscow)", "3"},
        {"UTC+4 (Dubai, Baku, Tbilisi)", "4"},
        {"UTC+5 (Karachi, Tashkent, Yekaterinburg)", "5"},
        {"UTC+5:30 (Mumbai, Delhi, Kolkata, Colombo)", "5.5"},
        {"UTC+6 (Dhaka, Almaty, Bishkek)", "6"},
        {"UTC+7 (Bangkok, Jakarta, Ho Chi Minh City)", "7"},
        {"UTC+8 (Beijing, Singapore, Hong Kong, Perth)", "8"},
        {"UTC+9 (Tokyo, Seoul, Pyongyang)", "9"},
        {"UTC+9:30 (Adelaide, Darwin)", "9.5"},
        {"UTC+10 (Sydney, Melbourne, Brisbane)", "10"},
        {"UTC+11 (Honiara, Noumea)", "11"},
        {"UTC+12 (Auckland, Fiji, Wellington)", "12"},
        {"UTC+13 (Nuku'alofa, Apia)", "13"},
        {"UTC+14 (Kiritimati)", "14"}
      ],
      "date_format" => UtilsDate.get_date_format_options(),
      "time_format" => UtilsDate.get_time_format_options()
    }
  end

  @doc """
  Gets the display label for a timezone value.

  ## Examples

      iex> PhoenixKit.Settings.get_timezone_label("0", get_setting_options())
      "UTC+0 (GMT/London)"
  """
  def get_timezone_label(value, setting_options) do
    case Enum.find(setting_options["time_zone"], fn {_label, val} -> val == value end) do
      {label, _value} -> label
      nil -> "UTC#{if value != "0", do: value, else: ""}"
    end
  end

  @doc """
  Updates or creates a setting with the given key and value.

  If the setting exists, updates its value and timestamp.
  If the setting doesn't exist, creates a new one.

  Returns `{:ok, setting}` on success, `{:error, changeset}` on failure.

  ## Examples

      iex> PhoenixKit.Settings.update_setting("time_zone", "+1")
      {:ok, %Setting{key: "time_zone", value: "+1"}}

      iex> PhoenixKit.Settings.update_setting("", "invalid")
      {:error, %Ecto.Changeset{}}
  """
  def update_setting(key, value) when is_binary(key) and (is_binary(value) or is_nil(value)) do
    # Convert nil to empty string for storage
    stored_value = value || ""

    result =
      case repo().get_by(Setting, key: key) do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value: stored_value})
          |> repo().update()

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value: stored_value})
          |> repo().insert()
      end

    # Invalidate cache on successful update
    case result do
      {:ok, _setting} -> PhoenixKit.Cache.invalidate(@cache_name, key)
      {:error, _changeset} -> :ok
    end

    result
  end

  @doc """
  Updates or creates multiple settings in a single transaction.

  More efficient version for batch updating settings.
  Loads all settings in a single query and updates them in a transaction.

  Accepts a map of key-value settings to update.
  Returns `{:ok, results}` on success, where results is a list of results.
  Returns `{:error, reason}` on transaction error.

  ## Examples

      iex> settings = %{"aws_region" => "eu-north-1", "aws_access_key_id" => "AKIAIOSFODNN7EXAMPLE"}
      iex> PhoenixKit.Settings.update_settings_batch(settings)
      {:ok, [ok: %Setting{}, ok: %Setting{}]}

      iex> PhoenixKit.Settings.update_settings_batch(%{})
      {:ok, []}
  """
  def update_settings_batch(settings_map) when is_map(settings_map) do
    keys = Map.keys(settings_map)

    # Load all existing settings in a single query
    existing_settings =
      Setting
      |> where([s], s.key in ^keys)
      |> repo().all()
      |> Map.new(fn setting -> {setting.key, setting} end)

    # Perform all updates/inserts in a transaction
    result =
      Ecto.Multi.new()
      |> add_batch_operations(settings_map, existing_settings)
      |> repo().transaction()

    case result do
      {:ok, _changes} ->
        # Invalidate cache for all updated keys in a single call
        PhoenixKit.Cache.invalidate_multiple(@cache_name, keys)
        result

      {:error, _failed_operation, _failed_value, _changes} ->
        result
    end
  end

  # Helper function to add operations to Multi
  defp add_batch_operations(multi, settings_map, existing_settings) do
    Enum.reduce(settings_map, multi, fn {key, value}, acc ->
      # Convert nil to empty string
      stored_value = value || ""

      case Map.get(existing_settings, key) do
        %Setting{} = setting ->
          # Update existing setting
          changeset = Setting.update_changeset(setting, %{value: stored_value})
          Ecto.Multi.update(acc, {:update, key}, changeset)

        nil ->
          # Create new setting
          changeset = Setting.changeset(%Setting{}, %{key: key, value: stored_value})
          Ecto.Multi.insert(acc, {:insert, key}, changeset)
      end
    end)
  end

  @doc """
  Updates or creates a boolean setting with the given key and boolean value.

  Converts boolean values to "true"/"false" strings for storage.
  If the setting exists, updates its value and timestamp.
  If the setting doesn't exist, creates a new one.

  Returns `{:ok, setting}` on success, `{:error, changeset}` on failure.

  ## Examples

      iex> PhoenixKit.Settings.update_boolean_setting("feature_enabled", true)
      {:ok, %Setting{key: "feature_enabled", value: "true"}}

      iex> PhoenixKit.Settings.update_boolean_setting("feature_enabled", false)
      {:ok, %Setting{key: "feature_enabled", value: "false"}}
  """
  def update_boolean_setting(key, boolean_value)
      when is_binary(key) and is_boolean(boolean_value) do
    string_value = if boolean_value, do: "true", else: "false"
    update_setting(key, string_value)
  end

  @doc """
  Updates or creates a setting with module association.

  Similar to update_setting/2 but allows specifying which module the setting belongs to.
  Useful for organizing feature-specific settings.

  ## Examples

      iex> PhoenixKit.Settings.update_setting_with_module("codes_enabled", "true", "referral_codes")
      {:ok, %Setting{key: "codes_enabled", value: "true", module: "referral_codes"}}
  """
  def update_setting_with_module(key, value, module) when is_binary(key) and is_binary(value) do
    existing_setting = repo().get_by(Setting, key: key)

    result =
      case existing_setting do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value: value, module: module})
          |> repo().update()

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value: value, module: module})
          |> repo().insert()
      end

    # Invalidate cache on successful update
    case result do
      {:ok, _setting} -> PhoenixKit.Cache.invalidate(@cache_name, key)
      {:error, _changeset} -> :ok
    end

    result
  end

  @doc """
  Updates or creates a boolean setting with module association.

  Combines boolean handling with module organization.

  ## Examples

      iex> PhoenixKit.Settings.update_boolean_setting_with_module("feature_enabled", true, "referral_codes")
      {:ok, %Setting{key: "feature_enabled", value: "true", module: "referral_codes"}}
  """
  def update_boolean_setting_with_module(key, boolean_value, module)
      when is_binary(key) and is_boolean(boolean_value) and is_binary(module) do
    string_value = if boolean_value, do: "true", else: "false"
    update_setting_with_module(key, string_value, module)
  end

  ## Content Language Functions

  @doc """
  Gets the site content language.

  This represents the primary language of website content (not UI language).
  Falls back to "en" if not configured or Languages module is disabled.

  This function uses batch caching for optimal performance when called
  alongside other settings queries.

  ## Examples

      iex> PhoenixKit.Settings.get_content_language()
      "en"

      iex> PhoenixKit.Settings.get_content_language()
      "es"  # if configured as Spanish
  """
  def get_content_language do
    # If Languages module is enabled, use the configured setting
    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      # Use batch cached settings for better performance
      settings =
        get_settings_cached(["site_content_language"], %{"site_content_language" => "en"})

      settings["site_content_language"] || "en"
    else
      # Languages module disabled - force "en"
      "en"
    end
  end

  @doc """
  Sets the site content language.

  Validates against enabled languages if Languages module is active.
  Broadcasts change event for live updates to connected admin sessions.

  ## Examples

      iex> PhoenixKit.Settings.set_content_language("es")
      {:ok, %Setting{}}

      iex> PhoenixKit.Settings.set_content_language("invalid")
      {:error, "Language not enabled"}
  """
  def set_content_language(language_code) when is_binary(language_code) do
    # Validate if Languages module is enabled
    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      enabled_codes = Languages.enabled_locale_codes()

      if language_code in enabled_codes do
        case update_setting("site_content_language", language_code) do
          {:ok, setting} ->
            # Broadcast change for live updates
            SettingsEvents.broadcast_content_language_changed(language_code)
            {:ok, setting}

          error ->
            error
        end
      else
        {:error, "Language '#{language_code}' is not enabled in Languages module"}
      end
    else
      # Languages module disabled - only allow "en"
      if language_code == "en" do
        case update_setting("site_content_language", "en") do
          {:ok, setting} ->
            # Broadcast change for live updates
            SettingsEvents.broadcast_content_language_changed("en")
            {:ok, setting}

          error ->
            error
        end
      else
        {:error, "Enable Languages module to use non-English content languages"}
      end
    end
  end

  @doc """
  Gets content language with full details.

  Returns a map with code, name, and native name if Languages module is enabled.

  ## Examples

      iex> PhoenixKit.Settings.get_content_language_details()
      %{
        code: "en",
        name: "English",
        native: "English",
        from_languages_module: false
      }
  """
  def get_content_language_details do
    code = get_content_language()

    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      case Languages.get_language(code) do
        %{"code" => lang_code, "name" => name} = lang ->
          %{
            code: lang_code,
            name: name,
            native: get_in(lang, ["native"]) || name,
            from_languages_module: true
          }

        nil ->
          # Fallback if language not found
          %{
            code: code,
            name: String.capitalize(code),
            native: String.capitalize(code),
            from_languages_module: false
          }
      end
    else
      # Languages module disabled - return English
      %{
        code: "en",
        name: "English",
        native: "English",
        from_languages_module: false
      }
    end
  end

  ## Settings Form Functions

  @doc """
  Creates a changeset for settings form validation.

  Takes a map of settings and returns a changeset that can be used in Phoenix forms.
  This function handles the conversion from string keys to atoms and creates the proper
  embedded schema structure for form validation.

  ## Examples

      iex> settings = %{"project_title" => "My App", "time_zone" => "0"}
      iex> PhoenixKit.Settings.change_settings(settings)
      %Ecto.Changeset{data: %SettingsForm{}, valid?: true}

      iex> PhoenixKit.Settings.change_settings(%{})
      %Ecto.Changeset{data: %SettingsForm{}, valid?: false}
  """
  def change_settings(settings \\ %{}) do
    SettingsForm.changeset(%SettingsForm{}, settings)
  end

  @doc """
  Validates settings parameters and returns a changeset.

  Similar to change_settings/1 but sets the action to :validate to trigger
  error display in forms.

  ## Examples

      iex> settings = %{"project_title" => "", "time_zone" => "invalid"}
      iex> changeset = PhoenixKit.Settings.validate_settings(settings)
      iex> changeset.action
      :validate
      iex> changeset.valid?
      false
  """
  def validate_settings(settings) do
    settings
    |> change_settings()
    |> Map.put(:action, :validate)
  end

  @doc """
  Updates multiple settings at once using form parameters.

  Takes a map of settings parameters, validates them, and if valid, updates
  all settings in the database. This is typically used from the settings form
  in the admin panel.

  Returns `{:ok, updated_settings_map}` on success or `{:error, changeset}` on failure.

  ## Examples

      iex> params = %{"project_title" => "My App", "time_zone" => "+1"}
      iex> PhoenixKit.Settings.update_settings(params)
      {:ok, %{"project_title" => "My App", "time_zone" => "+1"}}

      iex> PhoenixKit.Settings.update_settings(%{"time_zone" => "invalid"})
      {:error, %Ecto.Changeset{}}
  """
  def update_settings(settings_params) do
    changeset = validate_settings(settings_params)

    if changeset.valid? do
      case update_all_settings_from_changeset(changeset) do
        {:ok, updated_settings} ->
          # Invalidate cache for all updated settings
          updated_keys = Map.keys(updated_settings)
          PhoenixKit.Cache.invalidate_multiple(@cache_name, updated_keys)
          {:ok, updated_settings}

        {:error, errors} ->
          {:error, add_error(changeset, :base, errors)}
      end
    else
      {:error, changeset}
    end
  end

  # Private helper to update all settings from a valid changeset
  defp update_all_settings_from_changeset(changeset) do
    defaults = get_defaults()

    # Only update settings that were actually submitted in the form
    # Use changeset.params (original form params) not the full struct
    # This prevents one settings page from overwriting settings managed by another page
    settings_to_update =
      (changeset.params || %{})
      |> Enum.map(fn {k, v} ->
        key = to_string(k)
        # Use default value if nil or empty string
        value = if is_nil(v) or v == "", do: Map.get(defaults, key, ""), else: v
        {key, value}
      end)
      |> Map.new()
      # Auto-enable OAuth providers when credentials are saved
      |> auto_enable_oauth_providers()

    # Update each setting in the database and collect errors
    {updated_settings, failed_settings} =
      Enum.reduce(settings_to_update, {%{}, []}, fn {key, value}, {acc_success, acc_failed} ->
        case update_setting(key, value) do
          {:ok, _setting} ->
            {Map.put(acc_success, key, value), acc_failed}

          {:error, changeset} ->
            error_msg = extract_setting_error_message(changeset)
            Logger.warning("Failed to save setting #{key}: #{error_msg}")
            {acc_success, [{key, error_msg} | acc_failed]}
        end
      end)

    # Check if all settings were updated successfully
    if failed_settings == [] do
      {:ok, updated_settings}
    else
      # Format detailed error message with specific fields that failed
      failed_keys =
        Enum.map_join(failed_settings, ", ", fn {key, error} -> "#{key} (#{error})" end)

      error_msg = "Failed to save settings: #{failed_keys}"
      Logger.error("Settings batch update error: #{error_msg}")
      {:error, error_msg}
    end
  end

  # Helper function to extract error messages from Setting changeset
  defp extract_setting_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join(", ")
  end

  # Auto-enable OAuth providers when credentials are saved
  defp auto_enable_oauth_providers(settings_map) do
    settings_map
    # Auto-enable Google if credentials are being saved
    |> auto_enable_if_has_credentials("google")
    # Auto-enable Apple if credentials are being saved
    |> auto_enable_if_has_credentials("apple")
    # Auto-enable GitHub if credentials are being saved
    |> auto_enable_if_has_credentials("github")
    # Auto-enable Facebook if credentials are being saved
    |> auto_enable_if_has_credentials("facebook")
  end

  # Helper to auto-enable a provider if it has credentials
  defp auto_enable_if_has_credentials(settings_map, provider) do
    enable_key = "oauth_#{provider}_enabled"
    cred_keys = oauth_credential_keys(provider)

    # Check if any credential field for this provider is non-empty
    has_credentials? =
      Enum.any?(cred_keys, fn key ->
        value = Map.get(settings_map, key, "")
        value && value != ""
      end)

    # Auto-enable if it has credentials and isn't already set to something else
    if has_credentials? && Map.get(settings_map, enable_key, "false") != "false" do
      settings_map
    else
      if has_credentials? do
        Map.put(settings_map, enable_key, "true")
      else
        settings_map
      end
    end
  end

  # Get credential keys for a given OAuth provider
  defp oauth_credential_keys("google") do
    ["oauth_google_client_id", "oauth_google_client_secret"]
  end

  defp oauth_credential_keys("apple") do
    [
      "oauth_apple_client_id",
      "oauth_apple_team_id",
      "oauth_apple_key_id",
      "oauth_apple_private_key"
    ]
  end

  defp oauth_credential_keys("github") do
    ["oauth_github_client_id", "oauth_github_client_secret"]
  end

  defp oauth_credential_keys("facebook") do
    ["oauth_facebook_app_id", "oauth_facebook_app_secret"]
  end

  defp oauth_credential_keys(_), do: []

  @doc """
  Warms the cache by loading all settings from database.

  Called by PhoenixKit.Cache to pre-populate cache with all existing settings.
  Prioritizes JSON values over string values for cache storage.
  """
  def warm_cache_data do
    # Check if repository is available before attempting to warm cache
    # This prevents errors during Mix tasks when repo might not be started yet
    if repo_available?() do
      settings = repo().all(Setting)

      settings
      |> Enum.map(fn setting ->
        # Prioritize JSON value over string value for cache storage
        value =
          if setting.value_json do
            setting.value_json
          else
            setting.value
          end

        {setting.key, value}
      end)
      |> Map.new()
    else
      # Repo not available (likely during Mix task execution)
      # Return empty map - cache will be warmed later when repo becomes available
      %{}
    end
  rescue
    error ->
      # Handle missing uuid column during V40 migration gracefully
      unless migration_column_error?(error) do
        Logger.error("Failed to warm settings cache: #{inspect(error)}")
      end

      %{}
  end

  @doc """
  Warm cache with critical settings only.

  Returns map of critical settings for synchronous cache warming.
  This is used during startup to ensure essential configuration is available
  immediately.

  Note: OAuth credentials are NOT cached here because they are read directly
  from the database via get_oauth_credentials_direct/1 to avoid race conditions
  when credentials are updated through the admin UI.
  """
  def warm_critical_cache do
    # Critical keys that must be loaded synchronously at startup
    # OAuth credentials are intentionally NOT included - they use direct DB reads
    critical_keys = [
      # OAuth enabled flag only (not credentials)
      "oauth_enabled"
    ]

    # Check if repository is available
    if repo_available?() do
      settings =
        Setting
        |> where([s], s.key in ^critical_keys)
        |> repo().all()

      settings
      |> Enum.map(fn setting ->
        # Prioritize JSON value over string value for cache storage
        value =
          if setting.value_json do
            setting.value_json
          else
            setting.value
          end

        {setting.key, value}
      end)
      |> Map.new()
    else
      # Repo not available - return empty map
      # This should rarely happen as critical cache is loaded at startup
      %{}
    end
  rescue
    error ->
      # Handle missing uuid column during V40 migration gracefully
      unless migration_column_error?(error) do
        Logger.error("Failed to warm critical cache: #{inspect(error)}")
      end

      %{}
  end

  ## Private Batch Query Functions

  # Batch query multiple string settings from database in a single operation
  defp query_settings_batch(keys) do
    Setting
    |> where([s], s.key in ^keys)
    |> select([s], {s.key, s.value})
    |> repo().all()
    |> Map.new()
  rescue
    _error ->
      # If query fails, return empty map
      %{}
  end

  # Batch query multiple JSON settings from database in a single operation
  defp query_json_settings_batch(keys) do
    Setting
    |> where([s], s.key in ^keys)
    |> repo().all()
    |> Enum.reduce(%{}, fn setting, acc ->
      # Prioritize JSON value over string value (same logic as warm_cache_data)
      value = if setting.value_json, do: setting.value_json, else: nil
      Map.put(acc, setting.key, value)
    end)
  rescue
    _error ->
      # If query fails, return empty map
      %{}
  end

  ## Private Cache Management Functions

  # Queries database for a single setting and caches the result
  defp query_and_cache_setting(key) do
    # Check if repository is available before attempting query
    if repo_available?() do
      case repo().get_by(Setting, key: key) do
        %Setting{value: value} ->
          PhoenixKit.Cache.put(@cache_name, key, value)
          value

        nil ->
          # Cache a sentinel value to indicate this setting doesn't exist
          # This prevents repeated database queries for non-existent settings
          PhoenixKit.Cache.put(@cache_name, key, :__setting_does_not_exist__)
          nil
      end
    else
      # Repository not started yet - return nil silently
      nil
    end
  rescue
    error ->
      # Handle missing uuid column during V40 migration gracefully (silent)
      # Also skip logging during compilation mode
      unless migration_column_error?(error) or compilation_mode?() do
        Logger.error("Failed to query setting #{key}: #{inspect(error)}")
      end

      nil
  end

  # Queries database for a single JSON setting and caches the result
  defp query_and_cache_json_setting(key) do
    # Check if repository is available before attempting query
    if repo_available?() do
      case repo().get_by(Setting, key: key) do
        %Setting{value_json: value_json} when not is_nil(value_json) ->
          PhoenixKit.Cache.put(@cache_name, key, value_json)
          value_json

        %Setting{value: value} when not is_nil(value) and value != "" ->
          # Has meaningful string value but no JSON - cache nil for JSON lookup
          PhoenixKit.Cache.put(@cache_name, key, nil)
          nil

        nil ->
          # Cache a sentinel value to indicate this setting doesn't exist
          # This prevents repeated database queries for non-existent settings
          PhoenixKit.Cache.put(@cache_name, key, :__setting_does_not_exist__)
          nil
      end
    else
      # Repository not started yet - return nil silently
      nil
    end
  rescue
    error ->
      # Handle missing uuid column during V40 migration gracefully (silent)
      # Also skip logging during compilation mode
      unless migration_column_error?(error) or compilation_mode?() do
        Logger.error("Failed to query JSON setting #{key}: #{inspect(error)}")
      end

      nil
  end

  # Check if we're in compilation mode where database/cache infrastructure isn't available
  defp compilation_mode? do
    # During compilation, Config module may not be fully loaded
    # Check if repo is configured AND available - if not, we're in compilation mode
    case PhoenixKit.Config.get(:repo, nil) do
      nil ->
        true

      _repo_module ->
        # Even if repo is configured, it might not be started yet
        # In that case, we're effectively in "compilation mode" for queries
        not repo_available?()
    end
  rescue
    # If we can't even check the config, we're definitely in compilation mode
    _ -> true
  end

  # Check if error is specifically about missing uuid column (happens during V40 migration)
  # Only silences uuid column errors - other missing columns will still be logged
  # This is safe: after V40 migration, uuid exists and this never matches
  defp migration_column_error?(%Postgrex.Error{
         postgres: %{code: :undefined_column, message: msg}
       }) do
    String.contains?(msg, "uuid")
  end

  defp migration_column_error?(_), do: false

  @doc """
  Check if the repository is available and ready to accept queries.

  Returns true if the repo is configured and running, false otherwise.
  Used to prevent errors during Mix tasks when repo might not be started.
  """
  def repo_available? do
    # First check if repo is configured
    case PhoenixKit.Config.get(:repo, nil) do
      nil ->
        false

      repo_module ->
        # Check if the repo process is started and available
        try do
          # Try to get the repo's PID to verify it's running
          # This will raise if the repo isn't started
          pid = GenServer.whereis(repo_module)
          pid != nil
        rescue
          # Repo not started or not accessible
          _ -> false
        end
    end
  rescue
    # Config not available
    _ -> false
  end
end
