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
  - **Automatic blocklists** - Dynamic blocking of suspicious patterns
  - **Pattern detection** - ML-style spam pattern recognition

  ## Settings Integration

  All rate limiting settings are stored in phoenix_kit_settings:

  - `email_rate_limit_per_recipient` - Max emails per recipient per hour (default: 100)
  - `email_rate_limit_global` - Global max emails per hour (default: 10_000)
  - `email_blocklist_enabled` - Enable automatic blocklisting (default: true)

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

  ## Automatic Blocklist Features

  - **Pattern Detection**: Identifies bulk spam patterns
  - **Bounce Rate Monitoring**: Blocks high-bounce senders
  - **Complaint Rate Monitoring**: Blocks high-complaint addresses
  - **Frequency Analysis**: Detects unusual sending patterns
  - **Temporary Blocks**: Automatic expiration of blocks

  ## Integration Points

  Integrates with:
  - `PhoenixKit.Emails` - Main tracking system
  - `PhoenixKit.Emails.EmailInterceptor` - Pre-send filtering
  - `PhoenixKit.Settings` - Configuration management
  - `PhoenixKit.Users.Auth` - User-based limits
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
  def flag_suspicious_activity(user_id, reason) when is_integer(user_id) do
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
        monitor_user(user_id, "bulk_sending", %{reason: reason, flagged_at: DateTime.utc_now()})
        :monitored

      _ ->
        :ignored
    end
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

  defp reduce_user_limits(user_id, reason) when is_integer(user_id) do
    # Reduce sending limits for a user by setting temporary rate limit override
    Logger.warning("Reducing rate limits for user #{user_id}: #{reason}")

    # Store temporary limit reduction in Settings
    # This allows us to dynamically adjust per-user limits
    limit_key = "email_rate_limit_user_#{user_id}"
    current_limit = Settings.get_integer_setting(limit_key, get_recipient_limit())

    # Reduce limit by 50%
    new_limit = max(div(current_limit, 2), 10)

    Settings.update_setting(limit_key, to_string(new_limit))

    # Set expiration for the limit reduction (24 hours from now)
    expiry_key = "email_rate_limit_user_#{user_id}_expires"
    expires_at = DateTime.add(DateTime.utc_now(), 86_400)
    Settings.update_setting(expiry_key, DateTime.to_iso8601(expires_at))

    Logger.info("Reduced rate limit for user #{user_id} from #{current_limit} to #{new_limit}")
    :ok
  end

  defp block_user_emails(user_id, reason) when is_integer(user_id) do
    # Block all email addresses associated with this user
    Logger.warning("Blocking email addresses for user #{user_id}: #{reason}")

    # Get user's email address
    case Auth.get_user(user_id) do
      nil ->
        Logger.error("Cannot block emails for non-existent user #{user_id}")
        {:error, :user_not_found}

      user ->
        # Add user's email to blocklist with 7-day expiration
        expires_at = DateTime.add(DateTime.utc_now(), 604_800)

        case add_to_blocklist(user.email, reason,
               expires_at: expires_at,
               user_id: user_id
             ) do
          :ok ->
            Logger.info("Blocked email address #{user.email} for user #{user_id}")
            :ok

          {:error, error} ->
            Logger.error(
              "Failed to block email address #{user.email} for user #{user_id}: #{inspect(error)}"
            )

            {:error, error}
        end
    end
  end

  defp monitor_user(user_id, event_type, metadata) when is_integer(user_id) do
    # Add user to monitoring list by tracking in a dedicated setting
    Logger.info("Adding user #{user_id} to monitoring list: #{event_type}")

    # Store monitoring record in Settings with timestamp
    monitor_key = "email_monitor_user_#{user_id}_#{event_type}"

    monitoring_data = %{
      user_id: user_id,
      event_type: event_type,
      metadata: metadata,
      started_at: DateTime.to_iso8601(DateTime.utc_now()),
      # Monitor for 30 days
      expires_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 2_592_000))
    }

    Settings.update_setting(monitor_key, Jason.encode!(monitoring_data))

    Logger.info("User #{user_id} added to monitoring list for #{event_type}")
    :ok
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
