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
  - `track_registration_geolocation`: Enable IP geolocation tracking during registration (default: false).
    Needs the host endpoint's LiveView socket to declare `:peer_data` in
    `connect_info` (`websocket: [connect_info: [:peer_data, session: ...]]`)
    — without it every registration's IP is unknown and the setting silently
    does nothing. See `PhoenixKit.Utils.IpAddress.client_address_from_socket/1`.

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

  alias PhoenixKit.Config.AWS
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings.Events
  alias PhoenixKit.Settings.History
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Settings.Setting.SettingsForm
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.TimeZone

  @cache_name :settings

  # The cached value meaning "this key has no row". Distinct from a cached nil
  # (a row that exists and stores nil) and from a cache MISS. Defined once: it is
  # written on one path and matched on four, and six copies of the same literal
  # is how the halves of a read/write pair drift apart.
  @not_found_sentinel :__setting_does_not_exist__

  # ⚠️ Pre-existing, not introduced here: the string and JSON read paths
  # (`get_setting_cached/2`/`get_settings_cached/2` vs.
  # `get_json_setting_cached/2`/`get_json_settings_cached/2`) share ONE cache
  # entry per key, but cache different shapes for it (`setting.value` vs.
  # `setting.value_json`). A key read through both APIs after an
  # invalidation/expiry races whichever one fills the cache first, and the
  # other then reads that shape until the next invalidation. No core caller
  # mixes both APIs for the same key today, so this is a documented
  # limitation rather than a fix — widening the miss-fill to a live cache
  # process (this change) makes the batch paths reachable through the same
  # race the single-key paths already had.

  # S007: keys that hold live credential material, not just data an admin
  # would rather keep quiet. `oauth_*_client_id`/`oauth_*_app_id` are NOT
  # here on purpose — they are public by OAuth's own design (visible in the
  # authorization redirect URL) and carry no exposure to guard. Same
  # reasoning excludes the billing-provider public counterparts written by
  # the (separate) phoenix_kit_billing package through this same table:
  # `billing_stripe_publishable_key` (meant for client-side JS),
  # `billing_paypal_client_id` (loaded in PayPal's client-side SDK tag),
  # `billing_razorpay_key_id` (loaded in Razorpay's client-side Checkout.js)
  # and `billing_everypay_api_username`/`billing_everypay_account_name`
  # (identifiers, not secrets) stay public for the same reason their oauth
  # counterparts do.
  #
  # This list also extends beyond OAuth: any key — core's own or a module's,
  # written through this same `Setting.changeset/2` — that carries a live
  # secret an attacker could use directly (a private key, an API secret, a
  # webhook-signing secret) belongs here regardless of which package defines
  # it, because encryption-at-rest is enforced once, here, for the whole
  # `phoenix_kit_settings` table. The `billing_*` secrets belong to
  # phoenix_kit_billing (`lib/phoenix_kit_billing/providers/{stripe,paypal,
  # razorpay,everypay}.ex`), which calls `PhoenixKit.Settings.update_setting/2`
  # directly — core has no other notion of that module's keys, but this list
  # is what `Setting.changeset/2` actually consults, so it must know them to
  # protect them. `billing_stripe_api_key` is a legacy alias
  # `PhoenixKitBilling.Providers.Stripe.stripe_secret_key/0` still falls back
  # to — as sensitive as `billing_stripe_secret_key` itself.
  # `billing_<provider>_webhook_secret` is built by string interpolation at
  # its one call site (`WebhookController.get_webhook_secret/1`), not a
  # literal, so a future provider added to that family needs the same
  # treatment even though no static scan in this repo can see it.
  @restricted_setting_keys ~w(
    oauth_google_client_secret
    oauth_github_client_secret
    oauth_facebook_app_secret
    oauth_apple_private_key
    aws_access_key_id
    aws_secret_access_key
    website_access_password
    website_access_link_token
    billing_stripe_secret_key
    billing_stripe_webhook_secret
    billing_stripe_api_key
    billing_paypal_client_secret
    billing_paypal_webhook_secret
    billing_razorpay_key_secret
    billing_razorpay_webhook_secret
    billing_everypay_api_secret
  )

  # The explicit ALLOW list `list_public_settings/0` reads from. Deliberately
  # NOT "get_defaults() keys minus @restricted_setting_keys" — that would
  # make every future setting public by default until someone remembers to
  # blacklist it, which is exactly the failure mode this replaces (the core
  # only recognized a setting as sensitive by `module == "integrations"`,
  # which OAuth login credentials never belonged to). A key missing from
  # BOTH this list and @restricted_setting_keys fails the partition
  # invariant in settings_test.exs instead of silently defaulting to shown.
  @public_setting_keys ~w(
    project_title
    site_url
    main_page_path
    allow_registration
    require_email_confirmation
    remember_me_enabled
    remember_me_default
    dev_mailbox_enabled
    after_login_path
    after_registration_path
    user_settings_path
    oauth_enabled
    oauth_google_enabled
    oauth_github_enabled
    oauth_facebook_enabled
    oauth_require_verified_email
    magic_link_login_enabled
    magic_link_registration_enabled
    qr_login_enabled
    new_login_alert_enabled
    email_welcome_enabled
    login_attempt_logging_enabled
    login_attempt_retention_days
    failed_login_alert_enabled
    failed_login_alert_threshold
    mentions_enabled
    mentions_redact_titles
    new_user_default_role
    new_user_default_status
    week_start_day
    time_zone
    date_format
    time_format
    editor_default_mode
    track_registration_geolocation
    registration_show_username
    site_icon_file_uuid
    show_admin_panel_label
    show_page_descriptions
    default_tab_title
    auth_logo_file_uuid
    auth_background_image_file_uuid
    auth_background_image_mobile_file_uuid
    auth_background_color
    email_enabled
    email_save_body
    email_ses_events
    email_retention_days
    email_sampling_rate
    email_compress_body
    email_archive_to_s3
    aws_region
    aws_sns_topic_arn
    aws_sqs_queue_url
    aws_sqs_queue_arn
    aws_sqs_dlq_url
    aws_ses_configuration_set
    sqs_polling_enabled
    sqs_polling_interval_ms
    sqs_max_messages_per_poll
    sqs_visibility_timeout
    crawlers_module_enabled
    crawlers_no_index
    enable_organization_accounts
    registration_account_type
    webhook_verify_sns_signature
    webhook_check_aws_ip
    webhook_rate_limit_enabled
    oauth_google_client_id
    oauth_github_client_id
    oauth_facebook_app_id
    notifications_enabled
    multi_session_enabled
    role_switcher_enabled
    role_switcher_location
    role_switcher_always_on_roles
  )

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
      # The "Admin Panel" chip beside the project name in the admin header.
      # On by default — this is the shipped appearance, and the row is absent
      # on every existing install, so `get_boolean_setting/2`'s default is what
      # they keep until an operator says otherwise.
      "show_admin_panel_label" => "true",
      # The one-line description a page can put after its title in the admin
      # header (`page_subtitle`) and under the in-page title
      # (`admin_page_header`'s `subtitle`). Off by default: the trail and the
      # title are what the header is for, and the descriptions repeated what
      # the page already says.
      "show_page_descriptions" => "false",
      "site_url" => "",
      # Local path of the site's home page, used as the anonymous "home"
      # destination. Empty = unset; core then falls back to its own
      # locale-complete `/users/log-in` rather than `"/"`, which no core route
      # serves. Must NOT default to `"/"`: an empty submitted field is written
      # back as the default, so a `"/"` default would silently re-introduce the
      # unowned path as a positively-configured first-priority candidate.
      "main_page_path" => "",
      "allow_registration" => "true",
      # Enforce email confirmation before the app is usable ("true"/"false").
      # Confirmation emails send either way — this only gates enforcement.
      "require_email_confirmation" => "true",
      # Session persistence policy. `remember_me_enabled` is the site-wide
      # master switch: off = no flow may write the persistent cookie and the
      # checkbox disappears. `remember_me_default` decides whether that
      # checkbox starts checked (and is what the no-UI flows — magic-link
      # login, OAuth — follow, since there's nothing to tick there).
      "remember_me_enabled" => "true",
      "remember_me_default" => "true",
      # Local dev mailbox (Swoosh.Adapters.Local + /dev/mailbox) is OPT-IN: the
      # page is unauthenticated by design, and the auth mail it would collect
      # carries single-use tokens that exist nowhere else (issue #687). Off =
      # deliver_email/2 writes the message to the server log instead of handing
      # it to the mailbox.
      "dev_mailbox_enabled" => "false",
      # Local paths users land on after signing in / registering.
      # after_registration_path empty = fall back to after_login_path.
      "after_login_path" => "/",
      "after_registration_path" => "",
      # Where "Settings" in the user menu points. Empty = core's own
      # /profile/settings; set it to hand the account UI to a host page.
      "user_settings_path" => "",
      "oauth_enabled" => "false",
      "oauth_google_enabled" => "false",
      "oauth_github_enabled" => "false",
      "oauth_facebook_enabled" => "false",
      # Whether an OAuth callback may attach to an EXISTING local account
      # without the provider asserting it verified the address. Default on:
      # matching on the email string alone is an account-takeover primitive.
      "oauth_require_verified_email" => "true",
      "magic_link_login_enabled" => "true",
      "magic_link_registration_enabled" => "true",
      "qr_login_enabled" => "false",
      "new_login_alert_enabled" => "false",
      # Recording failed sign-ins. Defaults ON, unlike the alert above: it
      # writes one aggregated row and sends nothing, and the data is useless
      # retroactively — an install that switches it on after an incident has
      # already thrown the evidence away.
      "login_attempt_logging_enabled" => "true",
      "login_attempt_retention_days" => "90",
      # Warning the account holder that they are being hammered. Defaults OFF
      # because it sends mail, matching new_login_alert_enabled. The threshold
      # is failures within one hour; one alert silences the next for 24h.
      "failed_login_alert_enabled" => "false",
      "failed_login_alert_threshold" => "10",
      # The welcome email after a confirmed address (PhoenixKit.Users.WelcomeEmail).
      # OFF by default: it is new mail an existing install never sent.
      "email_welcome_enabled" => "false",
      # Cross-module @ mentions and # record links. On by default: the
      # feature is inert until someone actually types a trigger, and
      # everything it stores degrades to plain text when it is off.
      "mentions_enabled" => "true",
      # Extra-security mode: withhold the TITLE of a mention the reader
      # can't open. Off by default — a record's name is rarely the secret,
      # the access is — and worth turning on where the name itself is.
      "mentions_redact_titles" => "false",
      "new_user_default_role" => "User",
      "new_user_default_status" => "true",
      "week_start_day" => "1",
      "time_zone" => "0",
      "date_format" => "Y-m-d",
      "time_format" => "H:i",
      # Content editor (Leaf): default mode for every editor the kit renders
      "editor_default_mode" => "hybrid",
      "track_registration_geolocation" => "false",
      "registration_show_username" => "true",
      # General branding
      "site_icon_file_uuid" => "",
      "default_tab_title" => "",
      # Auth Page Branding
      "auth_logo_file_uuid" => "",
      "auth_background_image_file_uuid" => "",
      "auth_background_image_mobile_file_uuid" => "",
      "auth_background_color" => "",
      # Email Settings
      "email_enabled" => "false",
      "email_save_body" => "false",
      "email_ses_events" => "false",
      "email_retention_days" => "90",
      "email_sampling_rate" => "100",
      "email_compress_body" => "30",
      "email_archive_to_s3" => "false",
      # AWS Configuration for SQS Integration
      "aws_access_key_id" => AWS.access_key_id(),
      "aws_secret_access_key" => AWS.secret_access_key(),
      "aws_region" => AWS.region(),
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
      # Crawlers (renamed from SEO in V172)
      "crawlers_module_enabled" => "false",
      "crawlers_no_index" => "false",
      # Website access — the two secrets (restricted: encrypted at rest,
      # withheld from the settings history). The page's other keys are read
      # with explicit defaults by `PhoenixKit.WebsiteAccess`, like maintenance's.
      "website_access_password" => "",
      "website_access_link_token" => "",
      # Organization Accounts
      "enable_organization_accounts" => "false",
      # Which account types the PUBLIC signup form may create. Only consulted
      # when organization accounts are on — see `registration_account_types/0`.
      "registration_account_type" => "choice",
      # Webhook Security Settings
      "webhook_verify_sns_signature" => "true",
      "webhook_check_aws_ip" => "true",
      "webhook_rate_limit_enabled" => "true",
      # OAuth Provider Credentials
      "oauth_google_client_id" => "",
      "oauth_google_client_secret" => "",
      "oauth_github_client_id" => "",
      "oauth_github_client_secret" => "",
      "oauth_facebook_app_id" => "",
      "oauth_facebook_app_secret" => "",
      # Apple Sign-In has no UI yet — classified ahead of the feature so a
      # private key set before it ships is never stored in the clear (see
      # @restricted_setting_keys).
      "oauth_apple_private_key" => "",
      # Billing-provider secrets. Written by the separate phoenix_kit_billing
      # package through this same table — core carries no other knowledge of
      # these keys, only enough to classify them (see
      # @restricted_setting_keys for why core has to know them at all).
      "billing_stripe_secret_key" => "",
      "billing_stripe_webhook_secret" => "",
      "billing_stripe_api_key" => "",
      "billing_paypal_client_secret" => "",
      "billing_paypal_webhook_secret" => "",
      "billing_razorpay_key_secret" => "",
      "billing_razorpay_webhook_secret" => "",
      "billing_everypay_api_secret" => "",
      # Notifications
      "notifications_enabled" => "true",
      # Multi-session switcher (opt-in; disabled by default)
      "multi_session_enabled" => "false",
      # Role switcher / active role (opt-in) — see `PhoenixKit.Users.ActiveRole`.
      # `role_switcher_always_on_roles` is comma-separated role uuids.
      "role_switcher_enabled" => "false",
      "role_switcher_location" => "menu",
      "role_switcher_always_on_roles" => ""
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
    # In update_mode (mix phoenix_kit.update), skip DB queries entirely.
    # The update task only needs the Repo for migrations, not live settings.
    if Application.get_env(:phoenix_kit, :update_mode, false) do
      nil
    else
      setting_record = Queries.get_setting_by_key(key)

      case setting_record do
        %Setting{value: value} -> decrypt_if_restricted(key, value)
        nil -> nil
      end
    end
  rescue
    # An unreachable database surfaces BOTH ways — a checkout with no owner
    # raises, a dead pool/owner exits — and this function previously handled
    # neither, so a transient DB problem crashed every caller (including the
    # login redirect resolver). "No setting" is the honest answer; it lets
    # each caller apply its own documented default.
    error ->
      unless sandbox_ownership_error?(error) do
        Logger.warning("Settings read for #{inspect(key)} failed: #{inspect(error)}")
      end

      nil
  catch
    :exit, reason ->
      Logger.warning("Settings read for #{inspect(key)} exited: #{inspect(reason)}")
      nil
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
  Gets the project title with proper fallback chain.

  Checks in order:
  1. Settings database (runtime customizable via admin panel)
  2. Config `:phoenix_kit, :project_title` (compile-time setting)
  3. Default "PhoenixKit"

  This ensures users who set `config :phoenix_kit, project_title: "My App"`
  see their branding everywhere, while still allowing runtime customization.

  ## Examples

      # With config :phoenix_kit, project_title: "My App"
      iex> PhoenixKit.Settings.get_project_title()
      "My App"

      # With database setting overriding config
      iex> PhoenixKit.Settings.get_project_title()
      "Custom Title"
  """
  @spec get_project_title() :: String.t()
  def get_project_title do
    # Check Settings (database) first - allows runtime customization
    case get_setting("project_title") do
      nil ->
        # Fall back to Config (compile-time setting)
        PhoenixKit.Config.get(:project_title, "PhoenixKit")

      value ->
        value
    end
  end

  @doc """
  Resolved site-icon file uuid: the `site_icon_file_uuid` setting, falling
  back to the project logo (`auth_logo_file_uuid`) when unset — the two
  branding images default to each other, so setting either brands both the
  browser tab and the app chrome. Returns `""` when neither is set.

  Cache-backed reads — the favicon renders in `<head>` on every page.
  """
  def get_site_icon_uuid do
    first_present_setting(
      ["site_icon_file_uuid", "auth_logo_file_uuid"],
      &get_setting_cached(&1, "")
    )
  end

  @doc """
  Resolved project-logo file uuid: the `auth_logo_file_uuid` setting, falling
  back to the site icon (`site_icon_file_uuid`) when unset — the counterpart
  of `get_site_icon_uuid/0`. Returns `""` when neither is set (consumers then
  fall back to the project title text).

  Uncached reads, matching the layout wrappers' existing read strategy (so a
  logo change shows cluster-wide without a restart).
  """
  def get_logo_uuid do
    first_present_setting(
      ["auth_logo_file_uuid", "site_icon_file_uuid"],
      &get_setting(&1, "")
    )
  end

  defp first_present_setting(keys, getter) do
    Enum.find_value(keys, "", fn key ->
      case getter.(key) do
        uuid when is_binary(uuid) and uuid != "" -> uuid
        _ -> nil
      end
    end)
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

    # The generation travels with the miss so the fill cannot bring back a
    # value a concurrent write has just invalidated (`Cache.put/4`).
    {cached, generation} =
      PhoenixKit.Cache.get_with_generation(@cache_name, key, cache_miss_sentinel)

    case cached do
      ^cache_miss_sentinel ->
        # Cache miss - query database and cache result
        value = query_and_cache_setting(key, generation)
        value || default

      @not_found_sentinel ->
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
  catch
    # A connection-pool failure EXITS rather than raising (`DBConnection`
    # checkout against a stopped/unowned pool), so `rescue` alone never
    # covered a genuinely unreachable database — the caller crashed instead
    # of getting its default. Only reachable on a cache MISS, which is why it
    # showed up as rare flakiness rather than a hard failure: a warm cache
    # never touches the pool, and any write to any setting invalidates it.
    :exit, reason ->
      Logger.warning("Settings read for #{inspect(key)} exited: #{inspect(reason)}")
      default
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
    # ⚠️ Miss-fill, and it is load-bearing — but `Cache.get_multiple/3` does NOT
    # omit keys it does not hold. Its `handle_call` always writes every
    # requested key into the returned map, substituting `Map.get(defaults, key)`
    # on a miss (expired or never cached) instead of leaving the key out. Pass
    # `%{}` as those defaults, as this used to, and a miss reads back as plain
    # `nil` — indistinguishable from "cached, and the value happens to be nil" —
    # so `Map.has_key?/2` sees every key as present and a miss is never detected.
    #
    # Tag every requested key with a private sentinel as the cache-level
    # default instead (mirrors the single-key `cache_miss_sentinel` two
    # functions up), then detect misses by matching the sentinel rather than by
    # key presence. `defaults` — the caller's own fallback — never reaches
    # `Cache.get_multiple/3`: passing it there would make a caller-supplied
    # default indistinguishable from a genuinely cached value equal to it.
    #
    # A key that was never cached — or whose entry has expired — must still
    # cost one batch query against the database instead of silently reading as
    # `nil`. Nothing surfaced that while the cache had no TTL: entries were
    # written once and never expired. The moment one was added, every expiry
    # wave would have left OAuth credential helpers and the user-list date
    # formats reading `nil`, site-wide, until something happened to re-warm them.
    cache_miss_sentinel = :__cache_not_found__
    cache_defaults = Map.new(keys, &{&1, cache_miss_sentinel})
    # See `get_setting_cached/2` for the generation.
    {cached_results, generation} =
      PhoenixKit.Cache.get_multiple_with_generation(@cache_name, keys, cache_defaults)

    missing = Enum.filter(keys, &(Map.get(cached_results, &1) == cache_miss_sentinel))
    fetched = if missing == [], do: %{}, else: fill_missing_settings(missing, generation)

    Enum.reduce(keys, %{}, fn key, acc ->
      value =
        case Map.fetch(cached_results, key) do
          {:ok, @not_found_sentinel} ->
            Map.get(defaults, key)

          {:ok, ^cache_miss_sentinel} ->
            # `Map.fetch`, not `||`: a row that genuinely stores nil is a
            # different answer from a row that does not exist, and `||` collapses
            # them onto the caller's default.
            case Map.fetch(fetched, key) do
              {:ok, value} -> value
              :error -> Map.get(defaults, key)
            end

          {:ok, value} ->
            value

          # Defensive only: `cached_results` always has an entry for every
          # key in `keys` (`cache_defaults` guarantees it, and so does
          # `Cache.get_multiple/3`'s own `:noproc`/timeout fallback, which
          # returns `cache_defaults` verbatim), so `Map.fetch/2` here never
          # actually misses.
          :error ->
            Map.get(defaults, key)
        end

      Map.put(acc, key, value)
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

  # One batch query for the keys the cache did not hold, writing the results back
  # so the next reader is a hit. Keys with no row are cached as the
  # "does not exist" sentinel — negative caching, or a setting a host never sets
  # would query the database on every single read.
  #
  # ⚠️ Deliberately NOT `get_settings_direct/1`: that swallows query failures and
  # returns `%{}`, which is indistinguishable from "none of these keys exist".
  # Caching on that would write a "does not exist" entry for every requested key
  # and hold it for a full TTL — so one transient database blip during an expiry
  # wave would make configured OAuth credentials read as unconfigured, site-wide,
  # for five minutes. The single-key path already avoids caching on failure; this
  # one has to as well.
  defp fill_missing_settings(keys, generation) do
    case query_settings_or_error(keys) do
      {:ok, found} ->
        to_cache =
          keys
          |> Enum.reject(&restricted_decrypt_failure?(&1, found))
          |> Map.new(&{&1, Map.get(found, &1, @not_found_sentinel)})

        PhoenixKit.Cache.put_multiple(@cache_name, to_cache, if_generation: generation)
        found

      :error ->
        # Nothing cached. The caller falls back to its defaults for this one
        # read, and the next read tries the database again.
        %{}
    end
  end

  # A restricted key (`@restricted_setting_keys`) decrypts to `nil` in exactly
  # one case — `decrypt_if_restricted/2`'s `{:error, reason}` branch — never
  # as a genuinely stored value. `update_setting/2` coerces a `nil` write to
  # `""` before it ever reaches the database, so a restricted key's row is
  # always either ciphertext or `""`, never a literal `NULL`; `key` present
  # in `found` (a row exists) mapped to `nil` can only mean that branch ran.
  #
  # Per ee48b351 ("Do not cache a restricted setting the boot warmer cannot
  # decrypt"), a decrypt failure is answered but must NOT be cached — the
  # key may simply not be available yet, and the next read has to try again.
  # Caching `@not_found_sentinel` for it instead would be a DIFFERENT, wrong
  # rule: `get_setting_cached/2` treats that sentinel as "row does not
  # exist" and returns the caller's default without ever retrying the
  # decrypt, for as long as the entry stays cached (a full TTL, or forever
  # without one) — and since the single-key and batch paths share one cache
  # entry per key, that would poison `get_setting_cached/2` too. Leave the
  # key out of the cache write entirely instead, exactly like
  # `warm_cache_data/0`'s own `undecryptable_at_boot?/1` guard does for the
  # boot path.
  #
  # A key genuinely absent from `found` (no row at all) is a different case
  # — that one still gets `@not_found_sentinel`, which is the correct,
  # intentional negative-cache entry for "no such setting".
  defp restricted_decrypt_failure?(key, found) do
    key in @restricted_setting_keys and Map.get(found, key, :__absent__) == nil
  end

  defp fill_missing_json_settings(keys, generation) do
    if Application.get_env(:phoenix_kit, :update_mode, false) or not repo_available?() do
      %{}
    else
      found = query_json_settings_batch(keys)

      # `Map.fetch`, not `||`: a key `query_json_settings_batch/1` found (a
      # row exists, just with no JSON value — e.g. a plain string-only
      # setting) legitimately maps to `nil` here, a different answer from a
      # key with no row at all. `||` collapsed both onto the "not found"
      # sentinel, so the next read served the caller's default instead of
      # the correctly-absent `nil` for the rest of the cache entry's life.
      to_cache =
        Map.new(keys, fn key ->
          value =
            case Map.fetch(found, key) do
              {:ok, value} -> value
              :error -> @not_found_sentinel
            end

          {key, value}
        end)

      PhoenixKit.Cache.put_multiple(@cache_name, to_cache, if_generation: generation)
      found
    end
  rescue
    error ->
      unless sandbox_ownership_error?(error) do
        Logger.warning("Settings JSON miss-fill query failed: #{inspect(error)}")
      end

      %{}
  end

  defp query_settings_or_error(keys) do
    if Application.get_env(:phoenix_kit, :update_mode, false) or not repo_available?() do
      :error
    else
      {:ok, keys |> Queries.list_settings_key_values_by_keys() |> decrypt_and_map_settings()}
    end
  rescue
    error ->
      unless sandbox_ownership_error?(error) do
        Logger.warning("Settings miss-fill query failed: #{inspect(error)}")
      end

      :error
  catch
    # A dead connection pool exits rather than raising.
    :exit, _reason ->
      Logger.warning("Settings miss-fill query failed: database unavailable")
      :error
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
    # Same miss-fill defect `get_settings_cached/2` had. `Cache.get_multiple/3`
    # does NOT omit keys it does not hold — its
    # `handle_call` always writes every requested key into the returned map,
    # substituting `Map.get(defaults, key)` on a miss (expired or never
    # cached) instead of leaving the key out. Passing `%{}` as those defaults
    # made a miss read back as plain `nil`, indistinguishable from "cached,
    # and the value happens to be nil" — so `Map.has_key?/2` saw every key as
    # present and a miss was never detected. Same fix: tag every requested
    # key with a private sentinel as the cache-level default instead, and
    # detect a miss by matching that sentinel rather than by key presence.
    cache_miss_sentinel = :__cache_not_found__
    cache_defaults = Map.new(keys, &{&1, cache_miss_sentinel})

    {cached_results, generation} =
      PhoenixKit.Cache.get_multiple_with_generation(@cache_name, keys, cache_defaults)

    missing = Enum.filter(keys, &(Map.get(cached_results, &1) == cache_miss_sentinel))

    fetched =
      if missing == [], do: %{}, else: fill_missing_json_settings(missing, generation)

    Enum.reduce(keys, %{}, fn key, acc ->
      value =
        case Map.fetch(cached_results, key) do
          {:ok, @not_found_sentinel} ->
            Map.get(defaults, key)

          # `Map.fetch`, not `||`: a key `fill_missing_json_settings/1` found
          # with a JSON value of `nil` is a different answer from a key it
          # never found at all, and `||` collapsed both onto the caller's
          # default.
          {:ok, ^cache_miss_sentinel} ->
            case Map.fetch(fetched, key) do
              {:ok, value} -> value
              :error -> Map.get(defaults, key)
            end

          {:ok, cached} ->
            cached

          # Defensive only: see the equivalent clause in `get_settings_cached/2`
          # above — `cached_results` always has an entry for every key here too.
          :error ->
            Map.get(defaults, key)
        end

      Map.put(acc, key, value)
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
    setting_record = Queries.get_setting_by_key(key)

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

    # See `get_setting_cached/2` for the generation.
    {cached, generation} =
      PhoenixKit.Cache.get_with_generation(@cache_name, key, cache_miss_sentinel)

    case cached do
      ^cache_miss_sentinel ->
        # Cache miss - query database and cache result
        value = query_and_cache_json_setting(key, generation)
        value || default

      @not_found_sentinel ->
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
  def update_json_setting(key, json_value, opts \\ []) when is_binary(key) and is_list(opts) do
    result =
      case Queries.get_setting_by_key(key) do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value_json: json_value, value: nil})
          |> Queries.update_setting(opts)

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value_json: json_value, value: nil})
          |> Queries.insert_setting(opts)
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
  def update_json_setting_with_module(key, json_value, module, opts \\ [])
      when is_binary(key) and is_binary(module) do
    existing_setting = Queries.get_setting_by_key(key)

    result =
      case existing_setting do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value_json: json_value, value: nil, module: module})
          |> Queries.update_setting(opts)

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value_json: json_value, value: nil, module: module})
          |> Queries.insert_setting(opts)
      end

    # Invalidate cache on successful update
    case result do
      {:ok, _setting} -> PhoenixKit.Cache.invalidate(@cache_name, key)
      {:error, _changeset} -> :ok
    end

    result
  end

  @doc """
  Lists all JSON settings whose keys start with the given prefix.

  Returns a list of `{key, json_value}` tuples.
  """
  def get_json_settings_by_prefix(prefix) when is_binary(prefix) do
    prefix
    |> Queries.list_settings_by_key_prefix()
    |> Enum.flat_map(fn setting ->
      if setting.value_json, do: [{setting.key, setting.value_json}], else: []
    end)
  end

  @doc """
  Lists all JSON settings whose keys start with the given prefix,
  including the setting UUID. Returns a list of `{uuid, key, json_value}` tuples.
  """
  def get_json_settings_by_prefix_with_uuid(prefix) when is_binary(prefix) do
    prefix
    |> Queries.list_settings_by_key_prefix()
    |> Enum.flat_map(fn setting ->
      if setting.value_json,
        do: [{setting.uuid, setting.key, setting.value_json}],
        else: []
    end)
  end

  @doc """
  Gets JSON settings for multiple prefixes in a single database query.

  More efficient than calling `get_json_settings_by_prefix_with_uuid/1` in a loop.
  Returns `[{uuid, key, value_json}]` tuples.
  """
  def get_json_settings_by_prefixes_with_uuid(prefixes) when is_list(prefixes) do
    prefixes
    |> Queries.list_settings_by_key_prefixes()
    |> Enum.flat_map(fn setting ->
      if setting.value_json,
        do: [{setting.uuid, setting.key, setting.value_json}],
        else: []
    end)
  end

  @doc """
  Gets a JSON setting by its UUID. Returns the `value_json` map or the default.
  """
  def get_json_setting_by_uuid(uuid, default \\ nil) when is_binary(uuid) do
    case Queries.get_setting_by_uuid(uuid) do
      %Setting{value_json: value_json} when not is_nil(value_json) -> value_json
      _ -> default
    end
  end

  @doc """
  Deletes a setting by key. Returns `{:ok, setting}` or `{:error, :not_found}`.
  Also invalidates the cache for the key.
  """
  def delete_setting(key) when is_binary(key) do
    result = Queries.delete_setting_by_key(key)

    case result do
      {:ok, _} ->
        PhoenixKit.Cache.invalidate_now(@cache_name, [key])
        Queries.announce(fn -> Events.broadcast_setting_deleted(key) end)

      _ ->
        :ok
    end

    result
  end

  @doc """
  Subscribes the calling process to settings changes.

  After a committed write that changed a value, the process receives
  `{:setting_changed, key, value}` — `value` is the committed value, or
  `:redacted` for a key that holds credential material — and after a delete,
  `{:setting_deleted, key}`. The local cache has already dropped the old
  value when the message arrives. Details and limits:
  `PhoenixKit.Settings.Events`.

      def mount(_params, _session, socket) do
        if connected?(socket), do: PhoenixKit.Settings.subscribe()
        {:ok, assign(socket, :theme, PhoenixKit.Settings.get_setting("theme"))}
      end

      def handle_info({:setting_changed, "theme", value}, socket) do
        {:noreply, assign(socket, :theme, value)}
      end

      def handle_info({:setting_changed, _key, _value}, socket), do: {:noreply, socket}
      def handle_info({:setting_deleted, _key}, socket), do: {:noreply, socket}
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Events.subscribe_to_settings()

  @doc """
  Gets OAuth credentials for a specific provider.

  Returns a map with all credentials for the given provider.
  Uses cache for performance - suitable for non-critical reads.

  ## Examples

      iex> PhoenixKit.Settings.get_oauth_credentials(:google)
      %{client_id: "google-client-id", client_secret: "google-client-secret"}
  """
  def get_oauth_credentials(provider) when provider in [:google, :github, :facebook] do
    case provider do
      :google -> get_google_oauth_credentials()
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
      when provider in [:google, :github, :facebook] do
    case provider do
      :google -> get_google_oauth_credentials_direct()
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
    # In update_mode, skip DB — the update task doesn't need live settings.
    if Application.get_env(:phoenix_kit, :update_mode, false) do
      %{}
    else
      if repo_available?() do
        Queries.list_settings_key_values_by_keys(keys)
        |> decrypt_and_map_settings()
      else
        %{}
      end
    end
  rescue
    error ->
      # Silence transient migration errors (missing uuid column, cached plan invalidation)
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
  def has_oauth_credentials?(provider) when provider in [:google, :github, :facebook] do
    credentials = get_oauth_credentials(provider)

    case provider do
      :google -> validate_google_credentials(credentials)
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
      when provider in [:google, :github, :facebook] do
    credentials = get_oauth_credentials_direct(provider)

    case provider do
      :google -> validate_google_credentials(credentials)
      :github -> validate_github_credentials(credentials)
      :facebook -> validate_facebook_credentials(credentials)
    end
  end

  defp validate_google_credentials(credentials) do
    credentials.client_id != "" and credentials.client_secret != ""
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
    Queries.list_settings_key_values()
    |> decrypt_and_map_settings()
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
    Queries.list_settings()
  end

  @doc """
  Lists settings safe to load on admin pages that do not manage OAuth login
  credentials or AWS keys (General, Users) — same shape as
  `list_all_settings/0`, filtered down to `@public_setting_keys`.

  The Authorization page manages the OAuth credentials themselves and keeps
  calling `list_all_settings/0` directly; it has a legitimate reason to hold
  those values that General and Users do not.

  ## Examples

      iex> PhoenixKit.Settings.list_public_settings()
      %{"time_zone" => "0", "date_format" => "Y-m-d"}
  """
  def list_public_settings do
    list_all_settings()
    |> Map.take(@public_setting_keys)
  end

  @doc false
  def public_setting_keys, do: @public_setting_keys

  @doc false
  def restricted_setting_keys, do: @restricted_setting_keys

  @doc """
  Whether a settings row holds credential material whose value must never be
  copied anywhere else — into the settings history, or into a broadcast.

  True for the restricted keys above, and for every integration connection row.
  Integration rows are identified by their `module` (`"integrations"`): since
  V114 their keys are uuids, so no key-name rule can recognise them, and with
  integration encryption off their `value_json` holds live tokens in plain
  text.
  """
  @spec secret_setting?(String.t() | nil, String.t() | nil) :: boolean()
  def secret_setting?(key, module) do
    module == "integrations" or key in @restricted_setting_keys or
      (is_binary(key) and String.starts_with?(key, "integration:"))
  end

  @doc """
  The changes to `key`, newest first — permanent `setting.changed` activity
  entries; see `PhoenixKit.Settings.History.list/2`.
  """
  @spec history(String.t(), keyword()) :: [PhoenixKit.Activity.Entry.t()]
  def history(key, opts \\ []) when is_binary(key), do: History.list(key, opts)

  @doc """
  The value `key` had at `instant` — the answer to "which timezone was this
  site on when that row was written?". See
  `PhoenixKit.Settings.History.value_at/2`.
  """
  @spec value_at(String.t(), DateTime.t() | NaiveDateTime.t()) :: String.t() | nil
  def value_at(key, instant) when is_binary(key), do: History.value_at(key, instant)

  # Classifies one raw stored value against `PhoenixKit.Integrations.Encryption`'s
  # `enc:v1:` scheme (S015 pt.2). Exactly three outcomes, deliberately never
  # collapsed into two:
  #
  #   * `{:decrypted, plaintext}` — carried the prefix and decrypted under the
  #     currently active key. The value that would previously have been
  #     returned unencrypted.
  #   * `{:legacy, value}` — no prefix at all. A value written before this
  #     encryption existed, or a key that was never restricted. Returned
  #     as-is (`Encryption.decrypt_value/1`'s own backwards-compatibility
  #     rule) but tagged distinctly from `:decrypted` — this is the
  #     difference `decrypt_if_restricted/2` and any future migration/audit
  #     tooling can tell apart; an ordinary caller of `get_setting/1` cannot
  #     (both are equally usable plaintext to it), and is not meant to.
  #   * `{:error, reason}` — carried the prefix but did NOT decrypt (wrong or
  #     rotated key, corrupted ciphertext). Never resolves to a value here —
  #     see `decrypt_if_restricted/2` for what a caller-facing function does
  #     with this instead of ever returning the raw `enc:v1:...` string.
  #
  # Public (but undocumented) so it has its own direct unit test seam for
  # each of the three states — the same reason
  # `Mix.Tasks.PhoenixKit.Repair.exit_code/1` is public: the decision is pure
  # and worth testing in isolation from the DB-touching callers that use it.
  @doc false
  @spec decrypt_restricted_value(String.t() | nil) ::
          {:decrypted, String.t()} | {:legacy, String.t() | nil} | {:error, term()}
  def decrypt_restricted_value(nil), do: {:legacy, nil}

  def decrypt_restricted_value(value) when is_binary(value) do
    if Encryption.encrypted?(value) do
      case Encryption.decrypt_value(value) do
        {:ok, plaintext} -> {:decrypted, plaintext}
        {:error, reason} -> {:error, reason}
      end
    else
      {:legacy, value}
    end
  end

  # Read side of S015 pt.2: applies `decrypt_restricted_value/1` to a value
  # ALREADY KNOWN to have come from `key`, and collapses its three states to
  # the `String.t() | nil` every existing `get_setting*` caller already
  # expects — `:decrypted`/`:legacy` both resolve to the plaintext (equally
  # usable to a caller that just wants "the setting's value"; the
  # distinction is for `decrypt_restricted_value/1`'s own callers, not for
  # this one), `:error` NEVER resolves to the raw value. Matches
  # `PhoenixKit.Integrations.Encryption.decrypt_fields/1`'s own precedent
  # for the identical dilemma: "a caller must never mistake stale
  # ciphertext for a real value" — log loudly (this must never fail
  # silently) and report the value as absent, exactly like a row that
  # never existed. A caller reading `nil` back for a restricted key already
  # has a documented fallback path (config, `||` defaults) for "not
  # configured"; falling into that path is the safe outcome here, not a
  # regression — the alternative is handing a broken key to whatever reads
  # it next (an OAuth strategy, `AWS.access_key_id/0`).
  #
  # A key NOT in `restricted_setting_keys/0` never reaches
  # `decrypt_restricted_value/1` at all — every ordinary setting's value
  # passes through unchanged, at the cost of one list membership check.
  defp decrypt_if_restricted(key, value) do
    if key in @restricted_setting_keys do
      case decrypt_restricted_value(value) do
        {:decrypted, plaintext} ->
          plaintext

        {:legacy, legacy_value} ->
          legacy_value

        {:error, reason} ->
          Logger.error(
            "PhoenixKit.Settings: #{inspect(key)} carries enc:v1: but failed to decrypt " <>
              "(#{inspect(reason)}) — treating as missing rather than returning ciphertext"
          )

          nil
      end
    else
      value
    end
  end

  # Same as `decrypt_if_restricted/2`, applied across a whole `{key, value}`
  # list — the shape `Queries.list_settings_key_values_by_keys/1` and
  # `Queries.list_settings_key_values/0` both return, and the shape
  # `warm_cache_data/0` builds by hand from `Queries.list_settings/0`
  # (S015 review finding 1 — that hand-built list originally bypassed this
  # entirely and fed the boot-time cache warmer raw ciphertext for every
  # restricted key, on every app start, forever until the next write; a
  # cache HIT never even reaches the decrypting miss-fill path below it).
  # Shared by every multi-key read path (`get_settings_direct/1`, the cache
  # miss-fill behind `get_settings_cached/2`, `list_all_settings/0`,
  # `warm_cache_data/0`) so there is exactly one place that decides how a
  # batch of raw rows becomes the map a caller — or the cache itself —
  # reads, not one call site each, silently drifting apart.
  defp decrypt_and_map_settings(pairs) do
    Map.new(pairs, fn {key, value} -> {key, decrypt_if_restricted(key, value)} end)
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

      iex> options = PhoenixKit.Settings.get_setting_options()
      iex> {"UTC+0 (London, Dublin, Lisbon, Accra)", "0"} in options["time_zone"]
      true
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
      "time_zone" => timezone_options(),
      "date_format" => UtilsDate.get_date_format_options(),
      "time_format" => UtilsDate.get_time_format_options(),
      "editor_default_mode" => editor_mode_options()
    }
  end

  # THE canonical `"registration_account_type"` list: `{stored value, label
  # msgid}`. The label is only a msgid here — it is passed through `gettext/1`
  # at the call site (the settings LiveView), because this module has no
  # gettext backend and a label baked in at compile time would ship one
  # language to every visitor.
  #
  # The head entry is the default, and is what every existing install reads:
  # the row is absent until an operator saves the page.
  @registration_account_types [
    {"choice", "Visitor chooses"},
    {"person", "Personal accounts only"},
    {"organization", "Organization accounts only"}
  ]

  @default_registration_account_type @registration_account_types |> hd() |> elem(0)

  @doc """
  The valid `"registration_account_type"` values.

  Single source for the changeset allowlist in `PhoenixKit.Settings.Setting`
  and for the coercion in `PhoenixKit.Users.Auth.registration_account_type/0`,
  so a value the picker offers can never be one the changeset rejects.
  """
  @spec registration_account_types() :: [String.t()]
  def registration_account_types,
    do: Enum.map(@registration_account_types, fn {value, _label} -> value end)

  @doc """
  The `"registration_account_type"` options as `{label msgid, value}` tuples.

  The labels are **untranslated msgids** — the caller runs them through its own
  `gettext/1`. See `PhoenixKitWeb.Live.Settings.Users`.
  """
  @spec registration_account_type_options() :: [{String.t(), String.t()}]
  def registration_account_type_options,
    do: Enum.map(@registration_account_types, fn {value, label} -> {label, value} end)

  @doc """
  The default `"registration_account_type"`, `"choice"` — today's behaviour,
  which is what an install that has never touched the setting keeps.
  """
  @spec default_registration_account_type() :: String.t()
  def default_registration_account_type, do: @default_registration_account_type

  # THE canonical content-editor (Leaf) mode list: `{stored value, Leaf atom,
  # label}`. Everything else about editor modes derives from this — the picker
  # options, the changeset's `validate_inclusion` allowlist (via
  # `editor_modes/0`, called from `PhoenixKit.Settings.Setting`), and the
  # string→atom coercion in `get_editor_mode/0`. Adding a mode is a one-line
  # change here; three hand-kept copies would drift (a value accepted by the
  # changeset but unmapped in the coercion silently degrades to `:hybrid`).
  # The head entry is the default.
  @editor_modes [
    {"hybrid", :hybrid, "Hybrid (inline live preview)"},
    {"visual", :visual, "Visual (WYSIWYG)"},
    {"markdown", :markdown, "Markdown (plain source)"},
    {"html", :html, "HTML (raw markup)"}
  ]

  @default_editor_mode @editor_modes |> hd() |> elem(0)

  @doc """
  The content-editor (Leaf) mode options, as {label, value} tuples.

  Single source for the `"editor_default_mode"` entry in
  `get_setting_options/0`.
  """
  @spec editor_mode_options() :: [{String.t(), String.t()}]
  def editor_mode_options do
    Enum.map(@editor_modes, fn {value, _atom, label} -> {label, value} end)
  end

  @doc """
  The valid `"editor_default_mode"` values. Used by
  `PhoenixKit.Settings.Setting`'s changeset so the accepted set and the
  picker/coercion can never disagree.
  """
  @spec editor_modes() :: [String.t()]
  def editor_modes, do: Enum.map(@editor_modes, fn {value, _atom, _label} -> value end)

  @doc """
  Returns the site-wide default content-editor mode as an atom, for
  passing straight to Leaf's `mode` attr:

      <.leaf_editor id="editor" mode={PhoenixKit.Settings.get_editor_mode()} ... />

  Backed by the `"editor_default_mode"` setting (admin-editable under
  Settings → Content Editor). Unknown or missing values fall back to
  `:hybrid`, so the return is always one of `:hybrid | :visual |
  :markdown | :html`.
  """
  @spec get_editor_mode() :: :hybrid | :visual | :markdown | :html
  def get_editor_mode do
    stored = get_setting_cached("editor_default_mode", @default_editor_mode)

    case List.keyfind(@editor_modes, stored, 0) do
      {_value, atom, _label} -> atom
      nil -> :hybrid
    end
  end

  @doc """
  The static timezone offset options, as {label, value} tuples.

  This is the single source for the `"time_zone"` entry in
  `get_setting_options/0` and for `get_timezone_label/1` — callers that
  only need the timezone list (not the whole options map, which also
  queries roles via `get_role_options/0`) should use this directly
  instead of duplicating the list or paying for `get_setting_options/0`.

  ## Examples

      iex> Enum.any?(PhoenixKit.Settings.timezone_options(), fn {_label, id} ->
      ...>   id == "Europe/Warsaw"
      ...> end)
      true
  """
  @spec timezone_options() :: [{String.t(), String.t()}]
  def timezone_options, do: TimeZone.options()

  @doc """
  Gets the display label for a timezone value — the cheap path.

  Resolves against `timezone_options/0` only. Unlike `get_timezone_label/2`,
  this never builds the full `get_setting_options/0` map, so it never
  queries roles (`get_role_options/0` → `Roles.list_roles/0`). Prefer this
  whenever only the timezone label is needed — most callers.

  ## Examples

      iex> PhoenixKit.Settings.get_timezone_label("Europe/Warsaw") =~ "Europe/Warsaw"
      true
  """
  @spec get_timezone_label(String.t()) :: String.t()
  def get_timezone_label(value) do
    TimeZone.label(value)
  end

  @doc """
  Gets the display label for a timezone value from an already-built
  `get_setting_options/0` map. Kept for callers that already have the
  full options map on hand (e.g. rendering several dropdowns on the same
  page) — for everyone else, `get_timezone_label/1` is cheaper.

  ## Examples

      iex> PhoenixKit.Settings.get_timezone_label("Europe/Warsaw", %{}) =~ "Europe/Warsaw"
      true
  """
  @spec get_timezone_label(String.t(), map()) :: String.t()
  def get_timezone_label(value, setting_options) do
    case Enum.find(setting_options["time_zone"] || [], fn {_label, val} -> val == value end) do
      {label, _value} -> label
      nil -> TimeZone.label(value)
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

  ## History

  A write that changes the value records a permanent `setting.changed`
  activity entry in the same transaction (see `PhoenixKit.Settings.History`). Pass
  `actor_uuid:` when a person made the change and `source:` (the admin pages
  pass `"settings"`; the default is `"system"`). Every other writer in this
  module takes the same options.
  """
  def update_setting(key, value, opts \\ [])

  def update_setting(key, value, opts)
      when is_binary(key) and (is_binary(value) or is_nil(value)) and is_list(opts) do
    # Convert nil to empty string for storage
    stored_value = value || ""

    result =
      case Queries.get_setting_by_key(key) do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value: stored_value})
          |> Queries.update_setting(opts)

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value: stored_value})
          |> Queries.insert_setting(opts)
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
  def update_settings_batch(settings_map, opts \\ [])
      when is_map(settings_map) and is_list(opts) do
    keys = Map.keys(settings_map)

    # Load all existing settings in a single query
    existing_settings =
      Queries.list_settings_by_keys(keys)
      |> Map.new(fn setting -> {setting.key, setting} end)

    # Perform all updates/inserts in a transaction
    result =
      Ecto.Multi.new()
      |> add_batch_operations(settings_map, existing_settings, opts)
      |> Queries.transaction()

    case result do
      {:ok, changes} ->
        # Committed: drop the cached values, then announce each real change.
        # Keys whose value did not change are still dropped (cheap) but
        # announced to nobody.
        changes
        |> Enum.flat_map(fn
          {{:history, key}, recorded} -> [{batch_written(changes, key), recorded}]
          _ -> []
        end)
        |> Queries.announce_committed()

        # The result is the settings written, as before; the history's own
        # steps are bookkeeping.
        {:ok,
         Map.reject(changes, fn {name, _} ->
           match?({:before, _}, name) or match?({:history, _}, name)
         end)}

      {:error, _failed_operation, _failed_value, _changes} ->
        result
    end
  end

  defp batch_written(changes, key) do
    Map.get(changes, {:update, key}) || Map.fetch!(changes, {:insert, key})
  end

  # Helper function to add operations to Multi
  defp add_batch_operations(multi, settings_map, existing_settings, opts) do
    # Sorted, because each key is taken FOR UPDATE and the order they are
    # taken in is the lock order. Erlang map iteration is NOT a stable total
    # order across maps: a map of 32 keys or fewer is a flatmap iterated in
    # term order, a larger one is a hashmap iterated in hash order, and the
    # same two keys come out reversed between them. Two concurrent batches
    # sharing keys — one small, one large — would take them in opposite
    # orders and deadlock. Sorting gives every batch the same order.
    settings_map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(multi, fn {key, value}, acc ->
      # Convert nil to empty string
      stored_value = value || ""

      # The row as it is NOW, locked for the transaction — the "before" the
      # history records, read inside the transaction rather than from the
      # pre-read map so a concurrent writer cannot make it stale.
      acc =
        Ecto.Multi.run(acc, {:before, key}, fn _repo, _ -> {:ok, History.lock_current(key)} end)

      {write_name, acc} =
        case Map.get(existing_settings, key) do
          %Setting{} = setting ->
            # Update existing setting
            changeset = Setting.update_changeset(setting, %{value: stored_value})
            {{:update, key}, Ecto.Multi.update(acc, {:update, key}, changeset)}

          nil ->
            # Create new setting
            changeset = Setting.changeset(%Setting{}, %{key: key, value: stored_value})
            {{:insert, key}, Ecto.Multi.insert(acc, {:insert, key}, changeset)}
        end

      # The history row rides in the same transaction as the write.
      Ecto.Multi.run(acc, {:history, key}, fn _repo, changes ->
        History.record(Map.fetch!(changes, {:before, key}), Map.fetch!(changes, write_name), opts)
      end)
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
  def update_boolean_setting(key, boolean_value, opts \\ [])
      when is_binary(key) and is_boolean(boolean_value) and is_list(opts) do
    string_value = if boolean_value, do: "true", else: "false"
    update_setting(key, string_value, opts)
  end

  @doc """
  Updates or creates a setting with module association.

  Similar to update_setting/2 but allows specifying which module the setting belongs to.
  Useful for organizing feature-specific settings.

  ## Examples

      iex> PhoenixKit.Settings.update_setting_with_module("codes_enabled", "true", "referral_codes")
      {:ok, %Setting{key: "codes_enabled", value: "true", module: "referral_codes"}}
  """
  def update_setting_with_module(key, value, module, opts \\ [])
      when is_binary(key) and is_binary(value) and is_list(opts) do
    existing_setting = Queries.get_setting_by_key(key)

    result =
      case existing_setting do
        %Setting{} = setting ->
          setting
          |> Setting.update_changeset(%{value: value, module: module})
          |> Queries.update_setting(opts)

        nil ->
          %Setting{}
          |> Setting.changeset(%{key: key, value: value, module: module})
          |> Queries.insert_setting(opts)
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
  def update_boolean_setting_with_module(key, boolean_value, module, opts \\ [])
      when is_binary(key) and is_boolean(boolean_value) and is_binary(module) and is_list(opts) do
    string_value = if boolean_value, do: "true", else: "false"
    update_setting_with_module(key, string_value, module, opts)
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
    # Use the default language from Languages module if enabled
    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      case Languages.get_default_language() do
        %{code: code} -> code
        nil -> "en"
      end
    else
      # Languages module disabled - default to "en"
      "en"
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
    # Use the default language from Languages module directly
    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      case Languages.get_default_language() do
        %{code: code, name: name} = lang ->
          %{
            code: code,
            name: name,
            native: lang.native || name,
            from_languages_module: true
          }

        nil ->
          # No default language set - return English
          %{
            code: "en",
            name: "English",
            native: "English",
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
  def update_settings(settings_params, opts \\ []) do
    changeset = validate_settings(settings_params)

    if changeset.valid? do
      case update_all_settings_from_changeset(changeset, opts) do
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
  defp update_all_settings_from_changeset(changeset, opts) do
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
        case update_setting(key, value, opts) do
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

  defp oauth_credential_keys("github") do
    ["oauth_github_client_id", "oauth_github_client_secret"]
  end

  defp oauth_credential_keys("facebook") do
    ["oauth_facebook_app_id", "oauth_facebook_app_secret"]
  end

  defp oauth_credential_keys(_), do: []

  @doc """
  Warms the cache by loading all settings from database.

  Called by `PhoenixKit.Cache` (`supervisor.ex`'s `:settings` child,
  `sync_init: true`) to pre-populate cache with all existing settings —
  synchronously, on every app boot, before the rest of the supervision tree
  starts. Prioritizes JSON values over string values for cache storage.

  Runs every restricted key's value (S015) through `decrypt_and_map_settings/1`
  before returning — the cache itself is a bare ETS passthrough with no
  notion of encryption (`PhoenixKit.Cache`'s warmer just `:ets.insert`s
  whatever this returns, verbatim), so this is the only place that stands
  between a boot-time warm and `get_setting_cached/2`/`get_settings_cached/2`
  serving `enc:v1:...` as if it were the real secret on every cache HIT
  until the next write invalidates it.
  """
  def warm_cache_data do
    # In update_mode, skip DB warming — the update task only needs the Repo for migrations.
    if Application.get_env(:phoenix_kit, :update_mode, false) do
      %{}
    else
      # Check if repository is available before attempting to warm cache
      # This prevents errors during Mix tasks when repo might not be started yet
      if repo_available?() do
        settings = Queries.list_settings()

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
        |> Enum.reject(&undecryptable_at_boot?/1)
        |> decrypt_and_map_settings()
        # Defense in depth: `undecryptable_at_boot?/1` already excludes an
        # undecryptable restricted key above, but if one still slips through
        # (e.g. becomes undecryptable between that check and the decrypt
        # right above), drop it here too rather than warm the cache with a
        # bare `nil` for it — same ee48b351 rule as `restricted_decrypt_failure?/2`:
        # leave it out entirely so the first cached read retries the decrypt.
        |> Map.reject(fn {key, value} -> key in @restricted_setting_keys and is_nil(value) end)
      else
        # Repo not available (likely during Mix task execution)
        # Return empty map - cache will be warmed later when repo becomes available
        %{}
      end
    end
  rescue
    error ->
      # Silence transient migration errors (missing uuid column, cached plan invalidation)
      unless migration_column_error?(error) do
        Logger.error("Failed to warm settings cache: #{inspect(error)}")
      end

      %{}
  end

  # The warmer runs before the host's endpoint is up, and under the legacy
  # encryption tier the endpoint's `secret_key_base` IS the key — so a
  # restricted value cannot be decrypted at boot on such a host. Caching
  # the failure would serve nil for that secret (the website gate's
  # password, an OAuth secret) on every read until its next write, i.e. a
  # gate that is silently off after every restart. Such a key is left out
  # of the warm map instead: the first cached read fills it, by which time
  # the endpoint is running.
  # A restricted value that failed to decrypt is answered nil but NOT
  # cached — the key may simply not be available yet (see
  # `undecryptable_at_boot?/1`), and the next read must try again.
  defp cache_decrypted(key, raw, decrypted, generation) do
    unless decrypt_failed?(key, raw, decrypted) do
      PhoenixKit.Cache.put(@cache_name, key, decrypted, if_generation: generation)
    end

    decrypted
  end

  defp decrypt_failed?(key, raw, decrypted) do
    is_nil(decrypted) and key in @restricted_setting_keys and is_binary(raw) and
      Encryption.encrypted?(raw)
  end

  defp undecryptable_at_boot?({key, value}) do
    if key in @restricted_setting_keys and is_binary(value) and Encryption.encrypted?(value) do
      case Encryption.decrypt_value(value) do
        {:ok, _} ->
          false

        {:error, reason} ->
          Logger.debug(
            "PhoenixKit.Settings: #{inspect(key)} left for the first read — " <>
              "not decryptable at boot (#{inspect(reason)})"
          )

          true
      end
    else
      false
    end
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
      Queries.list_settings_with_json_priority_by_keys(critical_keys)
      |> Map.new()
    else
      # Repo not available - return empty map
      # This should rarely happen as critical cache is loaded at startup
      %{}
    end
  rescue
    error ->
      # Silence transient migration errors (missing uuid column, cached plan invalidation)
      unless migration_column_error?(error) do
        Logger.error("Failed to warm critical cache: #{inspect(error)}")
      end

      %{}
  end

  ## Private Batch Query Functions

  # Batch query multiple string settings from database in a single operation
  defp query_settings_batch(keys) do
    Queries.list_settings_key_values_by_keys(keys)
    |> decrypt_and_map_settings()
  rescue
    _error ->
      # If query fails, return empty map
      %{}
  end

  # Batch query multiple JSON settings from database in a single operation
  defp query_json_settings_batch(keys) do
    settings = Queries.list_settings_by_keys(keys)

    Enum.reduce(settings, %{}, fn setting, acc ->
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
  defp query_and_cache_setting(key, generation) do
    # In update_mode, skip DB — return nil immediately.
    if Application.get_env(:phoenix_kit, :update_mode, false) do
      nil
    else
      # Check if repository is available before attempting query
      if repo_available?() do
        case Queries.get_setting_by_key(key) do
          %Setting{value: value} ->
            cache_decrypted(key, value, decrypt_if_restricted(key, value), generation)

          nil ->
            # Cache a sentinel value to indicate this setting doesn't exist
            # This prevents repeated database queries for non-existent settings
            PhoenixKit.Cache.put(@cache_name, key, @not_found_sentinel, if_generation: generation)
            nil
        end
      else
        # Repository not started yet - return nil silently
        nil
      end
    end
  rescue
    error ->
      # Silence transient migration errors (missing uuid column, cached plan invalidation)
      # Also skip logging during compilation mode
      unless migration_column_error?(error) or sandbox_ownership_error?(error) or
               compilation_mode?() do
        Logger.error("Failed to query setting #{key}: #{inspect(error)}")
      end

      nil
  end

  # Queries database for a single JSON setting and caches the result
  defp query_and_cache_json_setting(key, generation) do
    # Check if repository is available before attempting query
    if repo_available?() do
      case Queries.get_setting_by_key(key) do
        %Setting{value_json: value_json} when not is_nil(value_json) ->
          PhoenixKit.Cache.put(@cache_name, key, value_json, if_generation: generation)
          value_json

        %Setting{value: value} when not is_nil(value) and value != "" ->
          # Has meaningful string value but no JSON - cache nil for JSON lookup
          PhoenixKit.Cache.put(@cache_name, key, nil, if_generation: generation)
          nil

        nil ->
          # Cache a sentinel value to indicate this setting doesn't exist
          # This prevents repeated database queries for non-existent settings
          PhoenixKit.Cache.put(@cache_name, key, @not_found_sentinel, if_generation: generation)
          nil
      end
    else
      # Repository not started yet - return nil silently
      nil
    end
  rescue
    error ->
      # Silence transient migration errors (missing uuid column, cached plan invalidation)
      # Also skip logging during compilation mode
      unless migration_column_error?(error) or sandbox_ownership_error?(error) or
               compilation_mode?() do
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

  # Check if error is a transient migration-related error that should be silenced.
  # These errors resolve on their own after connections are recycled.
  #
  # Matches:
  # 1. Missing uuid column (during V56 migration, before uuid column exists)
  # 2. Cached plan invalidation (during V58+ migrations that change column types,
  #    e.g. timestamp -> timestamptz). PostgreSQL raises "cached plan must not
  #    change result type" when a prepared statement's cached plan becomes stale
  #    after ALTER COLUMN TYPE.
  defp migration_column_error?(%Postgrex.Error{
         postgres: %{code: :undefined_column, message: msg}
       }) do
    String.contains?(msg, "uuid")
  end

  defp migration_column_error?(%Postgrex.Error{
         postgres: %{code: :feature_not_supported, message: msg}
       }) do
    String.contains?(msg, "cached plan")
  end

  defp migration_column_error?(_), do: false

  # An Ecto sandbox ownership error means the *calling process* has no
  # connection checked out — it is the test-suite spelling of
  # `repo_available?() == false`, which this module already answers with a
  # silent `nil`. It cannot occur outside a sandboxed repo, so nothing in
  # production is quieted.
  #
  # Worth a named clause because it is otherwise the single loudest thing in a
  # `mix test` run: with a reachable database `test_helper.exs` no longer sets
  # `:update_mode`, so every settings read on the unit half (no `DataCase`, no
  # checkout) reaches the pool, fails here, and logs at :error — hundreds of
  # multi-line stack-free walls that bury the actual failures.
  defp sandbox_ownership_error?(%DBConnection.OwnershipError{}), do: true
  defp sandbox_ownership_error?(_), do: false

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
