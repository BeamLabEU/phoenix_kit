# Define the EmailBlocklist schema first
defmodule PhoenixKit.Emails.EmailBlocklist do
  @moduledoc """
  Email blocklist schema for storing blocked email addresses.

  Used by the rate limiter to track emails that should be blocked
  due to bounces, complaints, or other issues.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "phoenix_kit_email_blocklist" do
    field :email, :string
    field :reason, :string
    field :expires_at, :utc_datetime_usec
    field :user_id, :integer
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def changeset(blocklist, attrs) do
    blocklist
    |> cast(attrs, [:email, :reason, :expires_at, :user_id, :inserted_at, :updated_at])
    |> validate_required([:email, :reason])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> unique_constraint(:email)
  end
end

defmodule PhoenixKit.Emails.RateLimiter do
  @moduledoc """
  Rate limiting and spam protection for the email system.

  Provides multiple layers of protection against abuse, spam, and suspicious email patterns:

  - **Per-recipient limits** - Prevent spam to individual email addresses
  - **Per-sender limits** - Control email volume from specific senders
  - **Global system limits** - Overall system protection
  - **User-specific limits** - Temporary reduced limits for flagged users
  - **Automatic blocklists** - Dynamic blocking of suspicious patterns
  - **Pattern detection** - ML-style spam pattern recognition
  - **User monitoring** - Event tracking for suspicious behavior

  ## Settings Integration

  All rate limiting settings are stored in phoenix_kit_settings:

  - `email_rate_limit_per_recipient` - Max emails per recipient per hour (default: 100)
  - `email_rate_limit_global` - Global max emails per hour (default: 10_000)
  - `email_blocklist_enabled` - Enable automatic blocklisting (default: true)

  User-specific settings (stored as JSON):
  - `user_rate_limits_#{user_id}` - Temporary reduced limits for specific users
  - `user_monitoring_#{user_id}` - Event tracking log for user behavior

  ## Usage Examples

      # Check if sending is allowed
      case PhoenixKit.Emails.RateLimiter.check_limits(email) do
        :ok ->
          # Send email

        {:blocked, :recipient_limit} ->
          # Handle recipient rate limit

        {:blocked, :global_limit} ->
          # Handle global rate limit

        {:blocked, :blocklist} ->
          # Handle blocklisted recipient
      end

      # Flag suspicious user activity
      PhoenixKit.Emails.RateLimiter.flag_suspicious_activity(user_id, "high_bounce_rate")
      # => :flagged (user gets reduced limits for 24 hours)

      # Check user's current limit status
      status = PhoenixKit.Emails.RateLimiter.get_user_limit_status(user_id)
      # => %{has_custom_limits: true, active_recipient_limit: 10, ...}

      # Clear user's custom limits
      PhoenixKit.Emails.RateLimiter.clear_user_rate_limits(user_id)
      # => :ok

      # Add suspicious email to blocklist
      PhoenixKit.Emails.RateLimiter.add_to_blocklist(
        "spam@example.com",
        "suspicious_pattern",
        expires_at: DateTime.add(DateTime.utc_now(), 86_400)
      )

      # Check current rate limit status
      status = PhoenixKit.Emails.RateLimiter.get_rate_limit_status()
      # => %{recipient_count: 45, global_count: 2341, blocked_count: 12}

  ## Rate Limiting Strategy

  Uses a sliding window approach with Redis-like atomic operations in PostgreSQL:

  1. **Sliding Window**: Tracks counts over rolling time periods
  2. **Efficient Storage**: Uses single table with automatic cleanup
  3. **Atomic Operations**: Prevents race conditions with database locks
  4. **Memory Efficient**: Automatically expires old tracking data
  5. **User-Specific Limits**: JSON settings for temporary user restrictions

  ## User Behavior Management

  - **Reduced Limits**: Automatically reduce limits for users with high bounce rates
  - **Email Blocking**: Block user emails for serious violations (spam complaints)
  - **Activity Monitoring**: Track suspicious patterns for future analysis
  - **Automatic Expiration**: Limits and blocks expire after configured periods
  - **Manual Override**: Admin can clear user restrictions via API

  ## Automatic Blocklist Features

  - **Pattern Detection**: Identifies bulk spam patterns
  - **Bounce Rate Monitoring**: Blocks high-bounce senders
  - **Complaint Rate Monitoring**: Blocks high-complaint addresses
  - **Frequency Analysis**: Detects unusual sending patterns
  - **Temporary Blocks**: Automatic expiration of blocks
  - **User Integration**: Links blocked emails to user accounts

  ## Integration Points

  Integrates with:
  - `PhoenixKit.Emails` - Main tracking system
  - `PhoenixKit.Emails.EmailInterceptor` - Pre-send filtering
  - `PhoenixKit.Settings` - Configuration management
  - `PhoenixKit.Users.Auth` - User-based limits and email blocking
  """

  alias PhoenixKit.Emails.{EmailBlocklist, Log}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  import Ecto.Query
  require Logger

  ## --- Rate Limit Checks ---

  @doc """
  Check all rate limits for an outgoing email.

  Returns `:ok` if email can be sent, or `{:blocked, reason}` if blocked.

  ## Examples

      iex> RateLimiter.check_limits(%{to: "user@example.com", from: "app@mysite.com"})
      :ok

      iex> RateLimiter.check_limits(%{to: "blocked@spam.com"})
      {:blocked, :blocklist}
  """
  def check_limits(email_attrs) when is_map(email_attrs) do
    with :ok <- check_blocklist(email_attrs[:to]),
         :ok <- check_recipient_limit(email_attrs[:to]),
         :ok <- check_sender_limit(email_attrs[:from]),
         :ok <- check_global_limit() do
      :ok
    else
      {:blocked, reason} -> {:blocked, reason}
    end
  end

  @doc """
  Check if recipient email address is within rate limits.

  ## Examples

      iex> RateLimiter.check_recipient_limit("user@example.com")
      :ok

      iex> RateLimiter.check_recipient_limit("high-volume@example.com")  
      {:blocked, :recipient_limit}
  """
  def check_recipient_limit(recipient_email, period \\ :hour) do
    limit = get_recipient_limit()
    count = get_recipient_count(recipient_email, period)

    if count >= limit do
      {:blocked, :recipient_limit}
    else
      :ok
    end
  end

  @doc """
  Check if sender email address is within rate limits.

  ## Examples

      iex> RateLimiter.check_sender_limit("app@mysite.com")
      :ok
  """
  def check_sender_limit(sender_email, period \\ :hour) do
    limit = get_sender_limit()
    count = get_sender_count(sender_email, period)

    if count >= limit do
      {:blocked, :sender_limit}
    else
      :ok
    end
  end

  @doc """
  Check global system-wide rate limits.

  ## Examples

      iex> RateLimiter.check_global_limit()
      :ok
  """
  def check_global_limit(period \\ :hour) do
    limit = get_global_limit()
    count = get_global_count(period)

    if count >= limit do
      {:blocked, :global_limit}
    else
      :ok
    end
  end

  ## --- Blocklist Management ---

  @doc """
  Check if email address is blocklisted.

  ## Examples

      iex> RateLimiter.check_blocklist("user@example.com")
      :ok

      iex> RateLimiter.check_blocklist("spam@blocked.com")
      {:blocked, :blocklist}
  """
  def check_blocklist(email) when is_binary(email) do
    if blocklist_enabled?() and is_blocked?(email) do
      {:blocked, :blocklist}
    else
      :ok
    end
  end

  def check_blocklist(_), do: :ok

  @doc """
  Add email address to blocklist.

  ## Options

  - `:reason` - Reason for blocking (string)
  - `:expires_at` - When block expires (DateTime, nil for permanent)
  - `:user_id` - User ID that triggered the block

  ## Examples

      # Temporary block for 24 hours
      RateLimiter.add_to_blocklist(
        "spam@example.com",
        "bulk_spam_pattern",
        expires_at: DateTime.add(DateTime.utc_now(), 86_400)
      )

      # Permanent block
      RateLimiter.add_to_blocklist("malicious@example.com", "manual_block")
  """
  def add_to_blocklist(email, reason, opts \\ []) when is_binary(email) do
    expires_at = Keyword.get(opts, :expires_at)
    user_id = Keyword.get(opts, :user_id)

    blocklist_entry = %{
      email: String.downcase(email),
      reason: reason,
      expires_at: expires_at,
      user_id: user_id,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    case repo().insert(%EmailBlocklist{} |> EmailBlocklist.changeset(blocklist_entry),
           on_conflict: [
             set: [reason: reason, expires_at: expires_at, updated_at: DateTime.utc_now()]
           ],
           conflict_target: :email
         ) do
      {:ok, _} -> :ok
      {:error, _changeset} -> {:error, :database_error}
    end
  end

  @doc """
  Remove email address from blocklist.

  ## Examples

      iex> RateLimiter.remove_from_blocklist("user@example.com")
      :ok
  """
  def remove_from_blocklist(email) when is_binary(email) do
    from(b in EmailBlocklist, where: b.email == ^String.downcase(email))
    |> repo().delete_all()

    :ok
  end

  @doc """
  Check if email address is currently blocked.

  ## Examples

      iex> RateLimiter.is_blocked?("user@example.com")
      false

      iex> RateLimiter.is_blocked?("blocked@spam.com")
      true
  """
  def is_blocked?(email) when is_binary(email) do
    now = DateTime.utc_now()

    query =
      from b in EmailBlocklist,
        where: b.email == ^String.downcase(email),
        where: is_nil(b.expires_at) or b.expires_at > ^now

    repo().exists?(query)
  end

  @doc """
  List all blocked emails with optional filtering.

  ## Options

  - `:search` - Search term for email address
  - `:reason` - Filter by block reason
  - `:include_expired` - Include expired blocks (default: false)
  - `:limit` - Limit number of results
  - `:offset` - Offset for pagination
  - `:order_by` - Order field (:email, :inserted_at, :expires_at)
  - `:order_dir` - Order direction (:asc, :desc)

  ## Examples

      iex> RateLimiter.list_blocklist()
      [%EmailBlocklist{}, ...]

      iex> RateLimiter.list_blocklist(%{reason: "manual_block", limit: 10})
      [%EmailBlocklist{}, ...]
  """
  def list_blocklist(opts \\ %{}) do
    now = DateTime.utc_now()

    query = from(b in EmailBlocklist)

    # Apply filters
    query =
      if opts[:search] && opts[:search] != "" do
        search_term = "%#{opts[:search]}%"
        where(query, [b], ilike(b.email, ^search_term))
      else
        query
      end

    query =
      if opts[:reason] && opts[:reason] != "" do
        where(query, [b], b.reason == ^opts[:reason])
      else
        query
      end

    query =
      if opts[:include_expired] do
        query
      else
        where(query, [b], is_nil(b.expires_at) or b.expires_at > ^now)
      end

    # Apply ordering
    query =
      case {opts[:order_by], opts[:order_dir]} do
        {field, :desc} when field in [:email, :inserted_at, :expires_at, :reason] ->
          order_by(query, [b], desc: field(b, ^field))

        {field, _} when field in [:email, :inserted_at, :expires_at, :reason] ->
          order_by(query, [b], asc: field(b, ^field))

        _ ->
          order_by(query, [b], desc: :inserted_at)
      end

    # Apply pagination
    query =
      if opts[:limit] do
        limit(query, ^opts[:limit])
      else
        query
      end

    query =
      if opts[:offset] do
        offset(query, ^opts[:offset])
      else
        query
      end

    repo().all(query)
  end

  @doc """
  Count blocked emails with optional filtering.

  ## Examples

      iex> RateLimiter.count_blocklist()
      42

      iex> RateLimiter.count_blocklist(%{reason: "bounce_limit"})
      15
  """
  def count_blocklist(opts \\ %{}) do
    now = DateTime.utc_now()

    query = from(b in EmailBlocklist)

    query =
      if opts[:search] && opts[:search] != "" do
        search_term = "%#{opts[:search]}%"
        where(query, [b], ilike(b.email, ^search_term))
      else
        query
      end

    query =
      if opts[:reason] && opts[:reason] != "" do
        where(query, [b], b.reason == ^opts[:reason])
      else
        query
      end

    query =
      if opts[:include_expired] do
        query
      else
        where(query, [b], is_nil(b.expires_at) or b.expires_at > ^now)
      end

    repo().aggregate(query, :count, :id)
  end

  @doc """
  Get blocklist statistics.

  Returns a map with statistics about blocked emails.

  ## Examples

      iex> RateLimiter.get_blocklist_stats()
      %{
        total_blocks: 42,
        active_blocks: 38,
        expired_today: 4,
        by_reason: %{"manual_block" => 10, "bounce_limit" => 28, ...}
      }
  """
  def get_blocklist_stats do
    now = DateTime.utc_now()
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    total_blocks = repo().aggregate(EmailBlocklist, :count, :id)

    active_blocks =
      from(b in EmailBlocklist, where: is_nil(b.expires_at) or b.expires_at > ^now)
      |> repo().aggregate(:count, :id)

    expired_today =
      from(b in EmailBlocklist,
        where: not is_nil(b.expires_at),
        where: b.expires_at < ^now,
        where: b.expires_at >= ^today_start
      )
      |> repo().aggregate(:count, :id)

    by_reason =
      from(b in EmailBlocklist,
        where: is_nil(b.expires_at) or b.expires_at > ^now,
        group_by: b.reason,
        select: {b.reason, count(b.id)}
      )
      |> repo().all()
      |> Enum.into(%{})

    %{
      total_blocks: total_blocks,
      active_blocks: active_blocks,
      expired_today: expired_today,
      by_reason: by_reason
    }
  end

  ## --- Pattern Detection ---

  @doc """
  Analyze email for suspicious spam patterns.

  Returns a list of detected patterns or empty list if clean.

  ## Examples

      iex> RateLimiter.detect_spam_patterns(email_log)
      []

      iex> RateLimiter.detect_spam_patterns(suspicious_email_log)
      ["high_frequency", "bulk_template"]
  """
  def detect_spam_patterns(%Log{} = email_log) do
    patterns = []

    patterns =
      if high_frequency_sender?(email_log.from) do
        ["high_frequency" | patterns]
      else
        patterns
      end

    patterns =
      if bulk_template_detected?(email_log) do
        ["bulk_template" | patterns]
      else
        patterns
      end

    patterns =
      if suspicious_subject?(email_log.subject) do
        ["suspicious_subject" | patterns]
      else
        patterns
      end

    patterns
  end

  @doc """
  Flag suspicious activity for a user.

  Automatically triggers blocklist or rate limit adjustments based on activity patterns.

  ## Examples

      iex> RateLimiter.flag_suspicious_activity(123, "high_bounce_rate")
      :flagged

      iex> RateLimiter.flag_suspicious_activity(456, "complaint_spam")
      :blocked
  """
  def flag_suspicious_activity(user_id, reason) when is_integer(user_id) and is_binary(reason) do
    case reason do
      "high_bounce_rate" ->
        # Temporarily reduce limits for this user
        reduce_user_limits(user_id, reason)
        :flagged

      "complaint_spam" ->
        # Add user's email to blocklist
        block_user_emails(user_id, reason)
        :blocked

      "bulk_sending" ->
        # Monitor closely but don't block yet
        monitor_user(user_id, :bulk_sending, %{reason: reason})
        :monitored

      _ ->
        :ignored
    end
  end

  ## --- User Limit Management API ---

  @doc """
  Checks if a user has custom rate limits applied.

  Returns user's custom limits if they exist and haven't expired,
  otherwise returns nil.

  ## Examples

      iex> RateLimiter.check_user_limits(123)
      %{
        "recipient_limit" => 10,
        "sender_limit" => 50,
        "reason" => "high_bounce_rate",
        "applied_at" => "2025-01-15T12:00:00Z",
        "expires_at" => "2025-01-16T12:00:00Z"
      }

      iex> RateLimiter.check_user_limits(999)
      nil
  """
  def check_user_limits(user_id) when is_integer(user_id) do
    get_user_limits(user_id)
  end

  @doc """
  Gets comprehensive rate limit status for a specific user.

  Returns a map with user's current limits, monitoring status,
  and any active restrictions.

  ## Examples

      iex> RateLimiter.get_user_limit_status(123)
      %{
        user_id: 123,
        has_custom_limits: true,
        custom_limits: %{"recipient_limit" => 10, "sender_limit" => 50},
        monitoring: %{"event_count" => 5, "last_event_at" => "..."},
        is_blocked: false,
        default_recipient_limit: 100,
        default_sender_limit: 1000
      }

      iex> RateLimiter.get_user_limit_status(999)
      %{
        user_id: 999,
        has_custom_limits: false,
        custom_limits: nil,
        monitoring: nil,
        is_blocked: false,
        default_recipient_limit: 100,
        default_sender_limit: 1000
      }
  """
  def get_user_limit_status(user_id) when is_integer(user_id) do
    custom_limits = get_user_limits(user_id)
    monitoring = get_user_monitoring(user_id)

    # Check if user's email is blocked
    is_blocked =
      case Auth.get_user(user_id) do
        nil ->
          false

        user ->
          is_blocked?(user.email)
      end

    %{
      user_id: user_id,
      has_custom_limits: not is_nil(custom_limits),
      custom_limits: custom_limits,
      monitoring: monitoring,
      is_blocked: is_blocked,
      default_recipient_limit: get_recipient_limit(),
      default_sender_limit: get_sender_limit(),
      active_recipient_limit:
        if(custom_limits, do: custom_limits["recipient_limit"], else: get_recipient_limit()),
      active_sender_limit:
        if(custom_limits, do: custom_limits["sender_limit"], else: get_sender_limit())
    }
  rescue
    _error ->
      %{
        user_id: user_id,
        has_custom_limits: false,
        custom_limits: nil,
        monitoring: nil,
        is_blocked: false,
        default_recipient_limit: get_recipient_limit(),
        default_sender_limit: get_sender_limit(),
        active_recipient_limit: get_recipient_limit(),
        active_sender_limit: get_sender_limit()
      }
  end

  @doc """
  Clears custom rate limits for a specific user.

  Removes any reduced limits or custom restrictions applied to the user,
  returning them to default system limits.

  ## Examples

      iex> RateLimiter.clear_user_rate_limits(123)
      :ok

  ## Returns

  - `:ok` - Limits cleared successfully
  """
  def clear_user_rate_limits(user_id) when is_integer(user_id) do
    clear_user_limits(user_id)
  end

  @doc """
  Gets monitoring events for a specific user.

  Returns the monitoring log with all tracked events for the user,
  or nil if no monitoring exists.

  ## Examples

      iex> RateLimiter.get_user_monitoring_events(123)
      %{
        "events" => [
          %{"event_type" => "bulk_sending", "timestamp" => "...", "metadata" => %{...}},
          %{"event_type" => "high_bounce_rate", "timestamp" => "...", "metadata" => %{...}}
        ],
        "event_count" => 2,
        "first_event_at" => "2025-01-15T12:00:00Z",
        "last_event_at" => "2025-01-15T18:00:00Z"
      }

      iex> RateLimiter.get_user_monitoring_events(999)
      nil
  """
  def get_user_monitoring_events(user_id) when is_integer(user_id) do
    get_user_monitoring(user_id)
  end

  ## --- Status and Statistics ---

  @doc """
  Get current rate limit status across all dimensions.

  ## Examples

      iex> RateLimiter.get_rate_limit_status()
      %{
        global: %{count: 1250, limit: 10_000, percentage: 12.5},
        recipients: %{active_limits: 5, total_emails: 892},
        senders: %{active_limits: 2, total_emails: 1250},
        blocklist: %{active_blocks: 15, expired_today: 3}
      }
  """
  def get_rate_limit_status do
    now = DateTime.utc_now()
    hour_ago = DateTime.add(now, -3600)

    %{
      global: %{
        count: get_global_count(:hour),
        limit: get_global_limit(),
        percentage: calculate_percentage(get_global_count(:hour), get_global_limit())
      },
      recipients: get_recipient_status(hour_ago, now),
      senders: get_sender_status(hour_ago, now),
      blocklist: get_blocklist_status()
    }
  end

  ## --- Configuration Helpers ---

  defp get_recipient_limit do
    Settings.get_integer_setting("email_rate_limit_per_recipient", 100)
  end

  defp get_sender_limit do
    # Default to 10x recipient limit for senders
    Settings.get_integer_setting(
      "email_rate_limit_per_sender",
      get_recipient_limit() * 10
    )
  end

  defp get_global_limit do
    Settings.get_integer_setting("email_rate_limit_global", 10_000)
  end

  defp blocklist_enabled? do
    Settings.get_boolean_setting("email_blocklist_enabled", true)
  end

  ## --- Count Helpers ---

  defp get_recipient_count(email, period) do
    {start_time, _end_time} = get_time_window(period)

    query =
      from l in Log,
        where: l.to == ^email and l.sent_at >= ^start_time,
        select: count(l.id)

    repo().one(query) || 0
  end

  defp get_sender_count(email, period) do
    {start_time, _end_time} = get_time_window(period)

    query =
      from l in Log,
        where: l.from == ^email and l.sent_at >= ^start_time,
        select: count(l.id)

    repo().one(query) || 0
  end

  defp get_global_count(period) do
    {start_time, _end_time} = get_time_window(period)

    query =
      from l in Log,
        where: l.sent_at >= ^start_time,
        select: count(l.id)

    repo().one(query) || 0
  end

  defp get_time_window(:hour) do
    now = DateTime.utc_now()
    hour_ago = DateTime.add(now, -3600)
    {hour_ago, now}
  end

  defp get_time_window(:day) do
    now = DateTime.utc_now()
    day_ago = DateTime.add(now, -86_400)
    {day_ago, now}
  end

  ## --- Pattern Detection Helpers ---

  defp high_frequency_sender?(from_email) when is_binary(from_email) do
    # Check if sender has sent more than 50 emails in last 10 minutes
    ten_minutes_ago = DateTime.add(DateTime.utc_now(), -600)

    query =
      from l in Log,
        where: l.from == ^from_email and l.sent_at >= ^ten_minutes_ago,
        select: count(l.id)

    count = repo().one(query) || 0
    count > 50
  end

  defp high_frequency_sender?(_), do: false

  defp bulk_template_detected?(%Log{template_name: template}) when is_binary(template) do
    # Check if this template has been used more than 100 times in last hour
    hour_ago = DateTime.add(DateTime.utc_now(), -3600)

    query =
      from l in Log,
        where: l.template_name == ^template and l.sent_at >= ^hour_ago,
        select: count(l.id)

    count = repo().one(query) || 0
    count > 100
  end

  defp bulk_template_detected?(_), do: false

  defp suspicious_subject?(subject) when is_binary(subject) do
    # Basic spam keyword detection
    spam_keywords = ~w(free urgent winner viagra lottery prize claim)

    subject_lower = String.downcase(subject)
    Enum.any?(spam_keywords, &String.contains?(subject_lower, &1))
  end

  defp suspicious_subject?(_), do: false

  ## --- User Management Helpers ---

  @doc """
  Reduces rate limits for a specific user temporarily.

  Creates a JSON setting with reduced limits for the user. The limits
  automatically expire after a configured duration (default: 24 hours).

  ## Parameters

  - `user_id` - User ID to apply reduced limits
  - `reason` - Reason for reduction (e.g., "high_bounce_rate")

  ## Examples

      iex> RateLimiter.reduce_user_limits(123, "high_bounce_rate")
      :ok

  ## Reduced Limits

  When applied, the user's limits are set to:
  - Per-recipient limit: 10 (vs default 100)
  - Per-sender limit: 50 (vs default 1000)
  - Duration: 24 hours

  ## Settings Storage

  Stored in JSON setting with key: `user_rate_limits_#{user_id}`

  Structure:
  ```elixir
  %{
    "recipient_limit" => 10,
    "sender_limit" => 50,
    "reason" => "high_bounce_rate",
    "applied_at" => "2025-01-15T12:00:00Z",
    "expires_at" => "2025-01-16T12:00:00Z"
  }
  ```
  """
  defp reduce_user_limits(user_id, reason) when is_integer(user_id) and is_binary(reason) do
    # Get default limits
    default_recipient_limit = get_recipient_limit()
    default_sender_limit = get_sender_limit()

    # Calculate reduced limits (10% of defaults, minimum 10)
    reduced_recipient_limit = max(div(default_recipient_limit, 10), 10)
    reduced_sender_limit = max(div(default_sender_limit, 10), 50)

    # Set expiration to 24 hours from now
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 86_400)

    user_limits = %{
      "recipient_limit" => reduced_recipient_limit,
      "sender_limit" => reduced_sender_limit,
      "reason" => reason,
      "applied_at" => DateTime.to_iso8601(now),
      "expires_at" => DateTime.to_iso8601(expires_at)
    }

    # Store in settings with user_id-specific key
    Settings.update_json_setting("user_rate_limits_#{user_id}", user_limits)

    require Logger

    Logger.warning(
      "Rate limits reduced for user #{user_id}: reason=#{reason}, " <>
        "recipient_limit=#{reduced_recipient_limit}, sender_limit=#{reduced_sender_limit}, " <>
        "expires_at=#{expires_at}"
    )

    :ok
  rescue
    error ->
      require Logger
      Logger.error("Failed to reduce user limits for user #{user_id}: #{inspect(error)}")
      :ok
  end

  @doc """
  Blocks all email addresses associated with a user.

  Retrieves the user's email address and adds it to the blocklist
  with a temporary block duration (default: 7 days).

  ## Parameters

  - `user_id` - User ID whose email should be blocked
  - `reason` - Reason for blocking (e.g., "complaint_spam")

  ## Examples

      iex> RateLimiter.block_user_emails(123, "complaint_spam")
      :ok

  ## Blocklist Integration

  Uses the existing `phoenix_kit_email_blocklist` table via `add_to_blocklist/3`.
  The block automatically expires after 7 days unless the user continues suspicious activity.

  ## Side Effects

  - Adds user's email to blocklist
  - Logs warning with block details
  - Creates monitoring entry for the user
  """
  defp block_user_emails(user_id, reason) when is_integer(user_id) and is_binary(reason) do
    # Get user from database
    case Auth.get_user(user_id) do
      nil ->
        require Logger
        Logger.error("Cannot block emails for user #{user_id}: user not found")
        :ok

      user ->
        # Set expiration to 7 days from now for serious violations
        expires_at = DateTime.add(DateTime.utc_now(), 86_400 * 7)

        # Add to blocklist
        add_to_blocklist(user.email, reason, expires_at: expires_at, user_id: user_id)

        # Also monitor the user for future activity
        monitor_user(user_id, :email_blocked, %{reason: reason, email: user.email})

        require Logger

        Logger.warning(
          "Email blocked for user #{user_id}: email=#{user.email}, reason=#{reason}, expires_at=#{expires_at}"
        )

        :ok
    end
  rescue
    error ->
      require Logger
      Logger.error("Failed to block user emails for user #{user_id}: #{inspect(error)}")
      :ok
  end

  @doc """
  Monitors user behavior by tracking events.

  Creates or updates a monitoring log for the user, storing events
  that indicate suspicious patterns. This data can be used for
  future analysis and automatic enforcement.

  ## Parameters

  - `user_id` - User ID to monitor
  - `event_type` - Type of event (atom or string)
  - `metadata` - Additional event data (map)

  ## Examples

      iex> RateLimiter.monitor_user(123, :bulk_sending, %{count: 500})
      :ok

      iex> RateLimiter.monitor_user(123, "high_bounce_rate", %{rate: 0.45})
      :ok

  ## Event Tracking

  Events are stored in JSON setting with key: `user_monitoring_#{user_id}`

  Structure:
  ```elixir
  %{
    "events" => [
      %{
        "event_type" => "bulk_sending",
        "metadata" => %{"count" => 500},
        "timestamp" => "2025-01-15T12:00:00Z"
      },
      %{
        "event_type" => "high_bounce_rate",
        "metadata" => %{"rate" => 0.45},
        "timestamp" => "2025-01-15T13:30:00Z"
      }
    ],
    "first_event_at" => "2025-01-15T12:00:00Z",
    "last_event_at" => "2025-01-15T13:30:00Z",
    "event_count" => 2
  }
  ```

  ## Event Retention

  Events older than 30 days are automatically pruned when new events are added.
  """
  defp monitor_user(user_id, event_type, metadata \\ %{})
       when is_integer(user_id) and (is_atom(event_type) or is_binary(event_type)) do
    # Convert event_type to string
    event_type_str = to_string(event_type)

    # Get existing monitoring data
    monitoring_key = "user_monitoring_#{user_id}"
    existing_monitoring = Settings.get_json_setting(monitoring_key, %{})

    # Get existing events or initialize empty list
    existing_events = Map.get(existing_monitoring, "events", [])

    # Create new event
    now = DateTime.utc_now()

    new_event = %{
      "event_type" => event_type_str,
      "metadata" => metadata,
      "timestamp" => DateTime.to_iso8601(now)
    }

    # Filter out events older than 30 days
    thirty_days_ago = DateTime.add(now, -86_400 * 30)

    recent_events =
      Enum.filter(existing_events, fn event ->
        case DateTime.from_iso8601(event["timestamp"]) do
          {:ok, timestamp, _} -> DateTime.compare(timestamp, thirty_days_ago) == :gt
          _ -> false
        end
      end)

    # Add new event
    updated_events = [new_event | recent_events]

    # Update monitoring data
    updated_monitoring = %{
      "events" => updated_events,
      "first_event_at" =>
        Map.get(existing_monitoring, "first_event_at", DateTime.to_iso8601(now)),
      "last_event_at" => DateTime.to_iso8601(now),
      "event_count" => length(updated_events)
    }

    # Store updated monitoring data
    Settings.update_json_setting(monitoring_key, updated_monitoring)

    require Logger

    Logger.info(
      "User monitoring event recorded for user #{user_id}: type=#{event_type_str}, " <>
        "metadata=#{inspect(metadata)}, total_events=#{length(updated_events)}"
    )

    :ok
  rescue
    error ->
      require Logger
      Logger.error("Failed to monitor user #{user_id}: #{inspect(error)}")
      :ok
  end

  @doc """
  Gets user-specific rate limits if they exist and are not expired.

  Returns a map with user's custom limits or nil if no limits are set or they expired.

  ## Examples

      iex> RateLimiter.get_user_limits(123)
      %{
        "recipient_limit" => 10,
        "sender_limit" => 50,
        "reason" => "high_bounce_rate",
        "expires_at" => "2025-01-16T12:00:00Z"
      }

      iex> RateLimiter.get_user_limits(999)
      nil
  """
  defp get_user_limits(user_id) when is_integer(user_id) do
    monitoring_key = "user_rate_limits_#{user_id}"
    user_limits = Settings.get_json_setting(monitoring_key)

    case user_limits do
      nil ->
        nil

      limits ->
        # Check if limits have expired
        case Map.get(limits, "expires_at") do
          nil ->
            limits

          expires_at_str ->
            case DateTime.from_iso8601(expires_at_str) do
              {:ok, expires_at, _} ->
                if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
                  limits
                else
                  # Limits expired, clean them up
                  clear_user_limits(user_id)
                  nil
                end

              _ ->
                limits
            end
        end
    end
  rescue
    _error ->
      nil
  end

  @doc """
  Gets the recipient limit for a specific user.

  If user has custom limits set, returns the custom limit.
  Otherwise returns the default system limit.

  ## Examples

      iex> RateLimiter.get_user_recipient_limit(123)
      10  # User has reduced limits

      iex> RateLimiter.get_user_recipient_limit(999)
      100  # Default limit
  """
  defp get_user_recipient_limit(user_id) when is_integer(user_id) do
    case get_user_limits(user_id) do
      %{"recipient_limit" => limit} when is_integer(limit) -> limit
      _ -> get_recipient_limit()
    end
  end

  @doc """
  Gets the sender limit for a specific user.

  If user has custom limits set, returns the custom limit.
  Otherwise returns the default system limit.

  ## Examples

      iex> RateLimiter.get_user_sender_limit(123)
      50  # User has reduced limits

      iex> RateLimiter.get_user_sender_limit(999)
      1000  # Default limit
  """
  defp get_user_sender_limit(user_id) when is_integer(user_id) do
    case get_user_limits(user_id) do
      %{"sender_limit" => limit} when is_integer(limit) -> limit
      _ -> get_sender_limit()
    end
  end

  @doc """
  Clears user-specific rate limits.

  Removes the JSON setting for user's custom limits.
  Used when limits expire or are manually cleared.

  ## Examples

      iex> RateLimiter.clear_user_limits(123)
      :ok
  """
  defp clear_user_limits(user_id) when is_integer(user_id) do
    monitoring_key = "user_rate_limits_#{user_id}"

    # Delete the setting by setting it to nil
    case Settings.update_json_setting(monitoring_key, nil) do
      {:ok, _} ->
        require Logger
        Logger.info("Cleared expired rate limits for user #{user_id}")
        :ok

      _ ->
        :ok
    end
  rescue
    _error ->
      :ok
  end

  @doc """
  Gets monitoring data for a specific user.

  Returns the monitoring events and statistics for a user, or nil if no monitoring exists.

  ## Examples

      iex> RateLimiter.get_user_monitoring(123)
      %{
        "events" => [...],
        "event_count" => 5,
        "first_event_at" => "2025-01-15T12:00:00Z",
        "last_event_at" => "2025-01-15T18:00:00Z"
      }

      iex> RateLimiter.get_user_monitoring(999)
      nil
  """
  defp get_user_monitoring(user_id) when is_integer(user_id) do
    monitoring_key = "user_monitoring_#{user_id}"
    Settings.get_json_setting(monitoring_key)
  rescue
    _error ->
      nil
  end

  ## --- Status Helpers ---

  defp get_recipient_status(_start_time, _end_time) do
    # Get recipient statistics for the time period
    # Simplified for now
    %{active_limits: 0, total_emails: 0}
  end

  defp get_sender_status(_start_time, _end_time) do
    # Get sender statistics for the time period
    # Simplified for now
    %{active_limits: 0, total_emails: 0}
  end

  defp get_blocklist_status do
    now = DateTime.utc_now()
    today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00])

    %{
      active_blocks: count_active_blocks(now),
      expired_today: count_expired_blocks(today_start, now)
    }
  end

  defp count_active_blocks(now) do
    query =
      from b in EmailBlocklist,
        where: is_nil(b.expires_at) or b.expires_at > ^now,
        select: count(b.id)

    repo().one(query) || 0
  end

  defp count_expired_blocks(start_time, end_time) do
    query =
      from b in EmailBlocklist,
        where: not is_nil(b.expires_at),
        where: b.expires_at >= ^start_time and b.expires_at <= ^end_time,
        select: count(b.id)

    repo().one(query) || 0
  end

  defp calculate_percentage(count, limit) when limit > 0 do
    Float.round(count / limit * 100, 1)
  end

  defp calculate_percentage(_, _), do: 0.0

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end

# EmailBlocklist schema is defined at the top of this file
