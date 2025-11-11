defmodule PhoenixKit.EmailSystem.EmailLog do
  @moduledoc """
  Email logging system for PhoenixKit - comprehensive logging in a single module.

  This module provides both the Ecto schema definition and business logic for
  managing emails. It includes email creation tracking, status updates,
  event relationships, and analytics functions.

  ## Schema Fields

  - `message_id`: Unique identifier from email provider (required, unique)
  - `to`: Recipient email address (required)
  - `from`: Sender email address (required)
  - `subject`: Email subject line
  - `headers`: JSONB map of email headers (without duplication)
  - `body_preview`: Preview of email content (first 500+ characters)
  - `body_full`: Complete email body content (optional, settings-controlled)
  - `template_name`: Name/identifier of email template used
  - `campaign_id`: Campaign or group identifier for analytics
  - `attachments_count`: Number of email attachments
  - `size_bytes`: Total email size in bytes
  - `retry_count`: Number of send retry attempts
  - `error_message`: Error message if sending failed
  - `status`: Current status (sent, delivered, bounced, opened, clicked, failed)
  - `sent_at`: Timestamp when email was sent
  - `delivered_at`: Timestamp when email was delivered (from provider)
  - `configuration_set`: AWS SES configuration set used
  - `message_tags`: JSONB tags for grouping and analytics
  - `provider`: Email provider used (aws_ses, smtp, local, etc.)
  - `user_id`: Associated user ID for authentication emails

  ## Core Functions

  ### Email Log Management
  - `list_logs/1` - Get emails with optional filters
  - `get_log!/1` - Get an email log by ID (raises if not found)
  - `get_log_by_message_id/1` - Get log by message ID from provider
  - `create_log/1` - Create a new email log
  - `update_log/2` - Update an existing email log
  - `update_status/2` - Update log status with timestamp
  - `delete_log/1` - Delete an email log

  ### Status Management
  - `mark_as_delivered/2` - Mark email as delivered with timestamp
  - `mark_as_bounced/3` - Mark as bounced with bounce type and reason
  - `mark_as_opened/2` - Mark as opened with timestamp
  - `mark_as_clicked/3` - Mark as clicked with link and timestamp

  ### Analytics Functions
  - `get_stats_for_period/2` - Get statistics for date range
  - `get_campaign_stats/1` - Get statistics for specific campaign
  - `get_engagement_metrics/1` - Calculate open/click rates
  - `get_provider_performance/1` - Provider-specific metrics
  - `get_bounce_analysis/1` - Detailed bounce analysis

  ### System Functions
  - `cleanup_old_logs/1` - Remove logs older than specified days
  - `compress_old_bodies/1` - Compress body_full for old emails
  - `get_logs_for_archival/1` - Get logs ready for archival

  ## Usage Examples

      # Create a new email log
      {:ok, log} = PhoenixKit.EmailSystem.EmailLog.create_log(%{
        message_id: "msg-abc123",
        to: "user@example.com",
        from: "noreply@myapp.com",
        subject: "Welcome to MyApp",
        template_name: "welcome_email",
        campaign_id: "welcome_series",
        provider: "aws_ses"
      })

      # Update status when delivered
      {:ok, updated_log} = PhoenixKit.EmailSystem.EmailLog.mark_as_delivered(
        log, DateTime.utc_now()
      )

      # Get campaign statistics
      stats = PhoenixKit.EmailSystem.EmailLog.get_campaign_stats("newsletter_2024")
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @derive {Jason.Encoder, except: [:__meta__, :user, :events]}

  alias PhoenixKit.EmailSystem.EmailEvent

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_email_logs" do
    field :message_id, :string
    field :aws_message_id, :string
    field :to, :string
    field :from, :string
    field :subject, :string
    field :headers, :map, default: %{}
    field :body_preview, :string
    field :body_full, :string
    field :template_name, :string
    field :campaign_id, :string
    field :attachments_count, :integer, default: 0
    field :size_bytes, :integer
    field :retry_count, :integer, default: 0
    field :error_message, :string
    field :status, :string, default: "sent"
    field :sent_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :bounced_at, :utc_datetime_usec
    field :complained_at, :utc_datetime_usec
    field :opened_at, :utc_datetime_usec
    field :clicked_at, :utc_datetime_usec
    field :configuration_set, :string
    field :message_tags, :map, default: %{}
    field :provider, :string, default: "unknown"
    field :user_id, :integer

    # Associations
    belongs_to :user, PhoenixKit.Users.Auth.User, foreign_key: :user_id, define_field: false
    has_many :events, EmailEvent, foreign_key: :email_log_id, on_delete: :delete_all

    timestamps(type: :utc_datetime_usec)
  end

  ## --- Schema Functions ---

  @doc """
  Creates a changeset for email log creation and updates.

  Validates required fields and ensures data consistency.
  Automatically sets sent_at on new records if not provided.
  """
  def changeset(email_log, attrs) do
    email_log
    |> cast(attrs, [
      :message_id,
      :aws_message_id,
      :to,
      :from,
      :subject,
      :headers,
      :body_preview,
      :body_full,
      :template_name,
      :campaign_id,
      :attachments_count,
      :size_bytes,
      :retry_count,
      :error_message,
      :status,
      :sent_at,
      :delivered_at,
      :bounced_at,
      :complained_at,
      :opened_at,
      :clicked_at,
      :configuration_set,
      :message_tags,
      :provider,
      :user_id
    ])
    |> validate_required([:message_id, :to, :from, :provider])
    |> validate_email_format(:to)
    |> validate_email_format(:from)
    # RFC 2822 limit
    |> validate_length(:subject, max: 998)
    |> validate_number(:attachments_count, greater_than_or_equal_to: 0)
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, [
      "sent",
      "delivered",
      "bounced",
      "hard_bounced",
      "soft_bounced",
      "opened",
      "clicked",
      "failed",
      "rejected",
      "delayed",
      "complaint"
    ])
    |> validate_message_id_uniqueness()
    |> unique_constraint(:message_id)
    |> unique_constraint(:aws_message_id)
    |> maybe_set_sent_at()
    |> validate_body_size()
  end

  @doc """
  Creates an email log from a Swoosh.Email struct.

  Extracts relevant data and creates an appropriately formatted log entry.

  ## Examples

      iex> email = new() |> to("user@example.com") |> from("app@example.com")
      iex> PhoenixKit.EmailSystem.EmailLog.create_from_swoosh_email(email, provider: "aws_ses")
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}
  """
  def create_from_swoosh_email(%Swoosh.Email{} = email, opts \\ []) do
    attrs = extract_swoosh_data(email, opts)
    create_log(attrs)
  end

  @doc """
  Validates email format using basic regex pattern.
  """
  def validate_email_format(changeset, field) do
    validate_format(changeset, field, ~r/^[^\s]+@[^\s]+\.[^\s]+$/,
      message: "must be a valid email address"
    )
  end

  ## --- Business Logic Functions ---

  @doc """
  Returns a list of emails with optional filters.

  ## Filters

  - `:status` - Filter by status (sent, delivered, bounced, etc.)
  - `:campaign_id` - Filter by campaign
  - `:template_name` - Filter by template
  - `:provider` - Filter by email provider
  - `:from_date` - Emails sent after this date
  - `:to_date` - Emails sent before this date
  - `:recipient` - Filter by recipient email (supports partial match)
  - `:limit` - Limit number of results (default: 50)
  - `:offset` - Offset for pagination

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.list_logs(%{status: "bounced", limit: 10})
      [%PhoenixKit.EmailSystem.EmailLog{}, ...]
  """
  def list_logs(filters \\ %{}) do
    base_query()
    |> apply_filters(filters)
    |> apply_pagination(filters)
    |> apply_ordering(filters)
    |> preload([:user, :events])
    |> repo().all()
  end

  @doc """
  Counts emails with optional filtering (without loading all records).

  ## Parameters

  - `filters` - Map of filters to apply (optional)

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.count_logs(%{status: "bounced"})
      42
  """
  def count_logs(filters \\ %{}) do
    base_query()
    |> apply_filters(filters)
    |> repo().aggregate(:count, :id)
  end

  @doc """
  Gets a single email log by ID.

  Raises `Ecto.NoResultsError` if the log does not exist.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_log!(123)
      %PhoenixKit.EmailSystem.EmailLog{}

      iex> PhoenixKit.EmailSystem.EmailLog.get_log!(999)
      ** (Ecto.NoResultsError)
  """
  def get_log!(id) do
    __MODULE__
    |> preload([:user, :events])
    |> repo().get!(id)
  end

  @doc """
  Gets a single email log by message ID.

  This function searches for logs using PhoenixKit's internal message_id
  (pk_ prefix). For AWS SES message IDs, use find_by_aws_message_id/1 instead.

  Returns nil if not found.

  ## Search Strategy

  Primary: Search internal message_id field (pk_ prefix)
  Fallback: If ID doesn't have pk_ prefix, also check aws_message_id field

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_log_by_message_id("pk_abc123")
      %PhoenixKit.EmailSystem.EmailLog{}

      iex> PhoenixKit.EmailSystem.EmailLog.get_log_by_message_id("nonexistent")
      nil

  ## See Also

  - `find_by_aws_message_id/1` - For searching by AWS SES message IDs
  """
  def get_log_by_message_id(message_id) when is_binary(message_id) do
    # Primary: Search internal message_id field (pk_ prefix)
    log =
      __MODULE__
      |> where([l], l.message_id == ^message_id)
      |> preload([:user, :events])
      |> repo().one()

    # Fallback: If not found and ID doesn't look like internal format,
    # try aws_message_id field for backward compatibility
    if is_nil(log) and not String.starts_with?(message_id, "pk_") do
      __MODULE__
      |> where([l], l.aws_message_id == ^message_id)
      |> preload([:user, :events])
      |> repo().one()
    else
      log
    end
  end

  @doc """
  Finds an email log by AWS SES message ID.

  This function searches the dedicated aws_message_id field where AWS SES
  message IDs are stored after email delivery. AWS events correlate using
  this field.

  ## Search Strategy

  Primary: Search aws_message_id field (AWS SES ID stored after send)
  Fallback: Search message_id field (for backward compatibility)

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.find_by_aws_message_id("abc123-aws-ses")
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}

      iex> PhoenixKit.EmailSystem.EmailLog.find_by_aws_message_id("nonexistent")
      {:error, :not_found}
  """
  def find_by_aws_message_id(aws_message_id) when is_binary(aws_message_id) do
    # Search dedicated aws_message_id field (primary)
    # Also check message_id field for backward compatibility
    case __MODULE__
         |> where([l], l.aws_message_id == ^aws_message_id)
         |> or_where([l], l.message_id == ^aws_message_id)
         |> preload([:user, :events])
         |> repo().one() do
      nil -> {:error, :not_found}
      log -> {:ok, log}
    end
  end

  @doc """
  Creates an email log.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.create_log(%{message_id: "abc", to: "user@test.com"})
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}

      iex> PhoenixKit.EmailSystem.EmailLog.create_log(%{message_id: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_log(attrs \\ %{}) do
    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates an email log.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.update_log(log, %{status: "delivered"})
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}

      iex> PhoenixKit.EmailSystem.EmailLog.update_log(log, %{to: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_log(%__MODULE__{} = email_log, attrs) do
    email_log
    |> changeset(attrs)
    |> repo().update()
  end

  @doc """
  Updates the status of an email log.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.update_status(log, "delivered")
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}
  """
  def update_status(%__MODULE__{} = email_log, status) when is_binary(status) do
    update_log(email_log, %{status: status})
  end

  @doc """
  Marks an email as delivered with timestamp.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.mark_as_delivered(log, DateTime.utc_now())
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}
  """
  def mark_as_delivered(%__MODULE__{} = email_log, delivered_at \\ nil) do
    delivered_at = delivered_at || DateTime.utc_now()

    update_log(email_log, %{
      status: "delivered",
      delivered_at: delivered_at
    })
  end

  @doc """
  Marks an email as bounced with type and reason.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.mark_as_bounced(log, "hard", "No such user")
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}
  """
  def mark_as_bounced(%__MODULE__{} = email_log, bounce_type, reason \\ nil) do
    repo().transaction(fn ->
      # Update log status
      {:ok, updated_log} = update_log(email_log, %{status: "bounced"})

      # Create bounce event
      EmailEvent.create_event(%{
        email_log_id: updated_log.id,
        event_type: "bounce",
        event_data: %{
          bounce_type: bounce_type,
          reason: reason
        },
        bounce_type: bounce_type
      })

      updated_log
    end)
  end

  @doc """
  Marks an email as opened with timestamp.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.mark_as_opened(log, DateTime.utc_now())
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}
  """
  def mark_as_opened(%__MODULE__{} = email_log, opened_at \\ nil) do
    repo().transaction(fn ->
      # Only update status if not already at a higher engagement level
      new_status =
        if email_log.status in ["sent", "delivered"], do: "opened", else: email_log.status

      {:ok, updated_log} = update_log(email_log, %{status: new_status})

      # Create open event
      EmailEvent.create_event(%{
        email_log_id: updated_log.id,
        event_type: "open",
        occurred_at: opened_at || DateTime.utc_now()
      })

      updated_log
    end)
  end

  @doc """
  Marks an email as clicked with link URL and timestamp.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.mark_as_clicked(log, "https://example.com", DateTime.utc_now())
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}
  """
  def mark_as_clicked(%__MODULE__{} = email_log, link_url, clicked_at \\ nil) do
    repo().transaction(fn ->
      # Clicked is the highest engagement level
      {:ok, updated_log} = update_log(email_log, %{status: "clicked"})

      # Create click event
      EmailEvent.create_event(%{
        email_log_id: updated_log.id,
        event_type: "click",
        occurred_at: clicked_at || DateTime.utc_now(),
        link_url: link_url
      })

      updated_log
    end)
  end

  @doc """
  Deletes an email log.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.delete_log(log)
      {:ok, %PhoenixKit.EmailSystem.EmailLog{}}

      iex> PhoenixKit.EmailSystem.EmailLog.delete_log(log)
      {:error, %Ecto.Changeset{}}
  """
  def delete_log(%__MODULE__{} = email_log) do
    repo().delete(email_log)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking email log changes.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.change_log(log)
      %Ecto.Changeset{data: %PhoenixKit.EmailSystem.EmailLog{}}
  """
  def change_log(%__MODULE__{} = email_log, attrs \\ %{}) do
    changeset(email_log, attrs)
  end

  ## --- Analytics Functions ---

  @doc """
  Gets statistics for a specific time period.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_stats_for_period(~U[2024-01-01 00:00:00Z], ~U[2024-01-31 23:59:59Z])
      %{total_sent: 1500, delivered: 1450, bounced: 30, opened: 800, clicked: 200}
  """
  def get_stats_for_period(start_date, end_date) do
    base_period_query =
      from(l in __MODULE__, where: l.sent_at >= ^start_date and l.sent_at <= ^end_date)

    %{
      total_sent: repo().aggregate(base_period_query, :count),
      delivered:
        repo().aggregate(
          from(l in base_period_query, where: l.status in ["delivered", "opened", "clicked"]),
          :count
        ),
      bounced:
        repo().aggregate(from(l in base_period_query, where: l.status == "bounced"), :count),
      complained:
        repo().aggregate(from(l in base_period_query, where: l.status == "complained"), :count),
      opened:
        repo().aggregate(
          from(l in base_period_query, where: l.status in ["opened", "clicked"]),
          :count
        ),
      clicked:
        repo().aggregate(from(l in base_period_query, where: l.status == "clicked"), :count),
      failed: repo().aggregate(from(l in base_period_query, where: l.status == "failed"), :count)
    }
  end

  @doc """
  Gets statistics for a specific campaign.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_campaign_stats("newsletter_2024")
      %{total_sent: 500, delivery_rate: 96.0, open_rate: 25.0, click_rate: 5.0}
  """
  def get_campaign_stats(campaign_id) when is_binary(campaign_id) do
    base_query = from(l in __MODULE__, where: l.campaign_id == ^campaign_id)

    total = repo().aggregate(base_query, :count)

    delivered =
      repo().aggregate(
        from(l in base_query, where: l.status in ["delivered", "opened", "clicked"]),
        :count
      )

    opened =
      repo().aggregate(from(l in base_query, where: l.status in ["opened", "clicked"]), :count)

    clicked = repo().aggregate(from(l in base_query, where: l.status == "clicked"), :count)
    bounced = repo().aggregate(from(l in base_query, where: l.status == "bounced"), :count)

    %{
      total_sent: total,
      delivered: delivered,
      opened: opened,
      clicked: clicked,
      bounced: bounced,
      delivery_rate: safe_percentage(delivered, total),
      bounce_rate: safe_percentage(bounced, total),
      open_rate: safe_percentage(opened, delivered),
      click_rate: safe_percentage(clicked, opened)
    }
  end

  @doc """
  Gets engagement metrics for analysis.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_engagement_metrics(:last_30_days)
      %{avg_open_rate: 24.5, avg_click_rate: 4.2, engagement_trend: :increasing}
  """
  def get_engagement_metrics(period \\ :last_30_days) do
    {start_date, end_date} = get_period_dates(period)

    # Get daily stats for trend analysis
    daily_stats = get_daily_engagement_stats(start_date, end_date)

    total_stats = get_stats_for_period(start_date, end_date)

    %{
      avg_open_rate: safe_percentage(total_stats.opened, total_stats.delivered),
      avg_click_rate: safe_percentage(total_stats.clicked, total_stats.opened),
      bounce_rate: safe_percentage(total_stats.bounced, total_stats.total_sent),
      daily_stats: daily_stats,
      engagement_trend: calculate_engagement_trend(daily_stats)
    }
  end

  @doc """
  Gets daily delivery trend data for charts.

  Returns daily statistics optimized for chart visualization including
  delivery trends and bounce patterns over the specified period.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_daily_delivery_trends(:last_7_days)
      %{
        labels: ["2024-09-01", "2024-09-02", ...],
        delivered: [120, 190, 300, ...],
        bounced: [5, 10, 15, ...]
      }
  """
  def get_daily_delivery_trends(period \\ :last_7_days) do
    {start_date, end_date} = get_period_dates(period)

    daily_stats = get_daily_engagement_stats(start_date, end_date)

    %{
      labels:
        Enum.map(daily_stats, fn stat ->
          Date.to_iso8601(stat.date)
        end),
      delivered:
        Enum.map(daily_stats, fn stat ->
          stat.delivered
        end),
      bounced:
        Enum.map(daily_stats, fn stat ->
          stat.total_sent - stat.delivered
        end),
      total_sent:
        Enum.map(daily_stats, fn stat ->
          stat.total_sent
        end)
    }
  end

  @doc """
  Gets provider-specific performance metrics.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_provider_performance(:last_7_days)
      %{"aws_ses" => %{delivered: 98.5, bounced: 1.5}, "smtp" => %{delivered: 95.0, bounced: 5.0}}
  """
  def get_provider_performance(period \\ :last_7_days) do
    {start_date, end_date} = get_period_dates(period)

    from(l in __MODULE__,
      where: l.sent_at >= ^start_date and l.sent_at <= ^end_date,
      group_by: l.provider,
      select: %{
        provider: l.provider,
        total: count(l.id),
        delivered:
          count(
            fragment("CASE WHEN ? IN ('delivered', 'opened', 'clicked') THEN 1 END", l.status)
          ),
        bounced: count(fragment("CASE WHEN ? = 'bounced' THEN 1 END", l.status)),
        failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", l.status))
      }
    )
    |> repo().all()
    |> Enum.into(%{}, fn stats ->
      {stats.provider,
       %{
         total_sent: stats.total,
         delivery_rate: safe_percentage(stats.delivered, stats.total),
         bounce_rate: safe_percentage(stats.bounced, stats.total),
         failure_rate: safe_percentage(stats.failed, stats.total)
       }}
    end)
  end

  ## --- System Maintenance Functions ---

  @doc """
  Removes emails older than specified number of days.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.cleanup_old_logs(90)
      {5, nil}  # Deleted 5 records
  """
  def cleanup_old_logs(days_old \\ 90) when is_integer(days_old) and days_old > 0 do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_old, :day)

    from(l in __MODULE__, where: l.sent_at < ^cutoff_date)
    |> repo().delete_all()
  end

  @doc """
  Compresses body_full field for logs older than specified days.
  Sets body_full to nil to save storage space while keeping body_preview.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.compress_old_bodies(30)
      {12, nil}  # Compressed 12 records
  """
  def compress_old_bodies(days_old \\ 30) when is_integer(days_old) and days_old > 0 do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_old, :day)

    from(l in __MODULE__,
      where: l.sent_at < ^cutoff_date and not is_nil(l.body_full),
      update: [set: [body_full: nil]]
    )
    |> repo().update_all([])
  end

  @doc """
  Gets logs ready for archival to external storage.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailLog.get_logs_for_archival(90)
      [%PhoenixKit.EmailSystem.EmailLog{}, ...]
  """
  def get_logs_for_archival(days_old \\ 90) when is_integer(days_old) and days_old > 0 do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_old, :day)

    from(l in __MODULE__,
      where: l.sent_at < ^cutoff_date,
      preload: [:events],
      order_by: [asc: l.sent_at]
    )
    |> repo().all()
  end

  ## --- Private Helper Functions ---

  # Base query with common preloads
  defp base_query do
    from(l in __MODULE__, as: :log)
  end

  # Apply various filters to the query
  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, query when is_binary(status) ->
        where(query, [log: l], l.status == ^status)

      {:campaign_id, campaign}, query when is_binary(campaign) ->
        where(query, [log: l], l.campaign_id == ^campaign)

      {:template_name, template}, query when is_binary(template) ->
        where(query, [log: l], l.template_name == ^template)

      {:provider, provider}, query when is_binary(provider) ->
        where(query, [log: l], l.provider == ^provider)

      {:message_tag, message_tag}, query when is_binary(message_tag) ->
        # Filter by message_tags using JSONB operator to check email_type
        where(
          query,
          [log: l],
          fragment("? ->> ? = ?", l.message_tags, "email_type", ^message_tag)
        )

      {:from_date, from_date}, query ->
        where(query, [log: l], l.sent_at >= ^from_date)

      {:to_date, to_date}, query ->
        where(query, [log: l], l.sent_at <= ^to_date)

      {:recipient, email}, query when is_binary(email) ->
        where(query, [log: l], ilike(l.to, ^"%#{email}%"))

      {:search, search_term}, query when is_binary(search_term) ->
        search_pattern = "%#{search_term}%"

        where(
          query,
          [log: l],
          ilike(l.to, ^search_pattern) or
            ilike(l.subject, ^search_pattern) or
            ilike(l.campaign_id, ^search_pattern)
        )

      {:user_id, user_id}, query when is_integer(user_id) ->
        where(query, [log: l], l.user_id == ^user_id)

      _other, query ->
        query
    end)
  end

  # Apply pagination
  defp apply_pagination(query, filters) do
    limit = Map.get(filters, :limit, 50)
    offset = Map.get(filters, :offset, 0)

    query
    |> limit(^limit)
    |> offset(^offset)
  end

  # Apply ordering
  defp apply_ordering(query, filters) do
    order_by = Map.get(filters, :order_by, :sent_at)
    order_dir = Map.get(filters, :order_dir, :desc)

    order_by(query, [log: l], [{^order_dir, field(l, ^order_by)}])
  end

  # Extract data from Swoosh.Email struct
  defp extract_swoosh_data(%Swoosh.Email{} = email, opts) do
    %{
      message_id: generate_message_id(),
      to: extract_primary_recipient(email.to),
      from: extract_sender(email.from),
      subject: email.subject,
      headers: Map.new(email.headers),
      body_preview: extract_body_preview(email),
      body_full: extract_body_full(email, opts),
      attachments_count: length(email.attachments),
      provider: Keyword.get(opts, :provider, "unknown"),
      template_name: Keyword.get(opts, :template_name),
      campaign_id: Keyword.get(opts, :campaign_id),
      user_id: Keyword.get(opts, :user_id),
      configuration_set: Keyword.get(opts, :configuration_set),
      message_tags: Keyword.get(opts, :message_tags, %{}),
      sent_at: DateTime.utc_now()
    }
  end

  # Generate a unique message ID if not provided by the email service
  defp generate_message_id do
    "pk_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  # Extract primary recipient from to field
  defp extract_primary_recipient([{_name, email} | _]), do: email
  defp extract_primary_recipient([email | _]) when is_binary(email), do: email
  defp extract_primary_recipient({_name, email}), do: email
  defp extract_primary_recipient(email) when is_binary(email), do: email
  defp extract_primary_recipient(_), do: "unknown@example.com"

  # Extract sender from from field
  defp extract_sender({_name, email}), do: email
  defp extract_sender(email) when is_binary(email), do: email
  defp extract_sender(_), do: "unknown@example.com"

  # Extract body preview (first 500 characters)
  defp extract_body_preview(email) do
    body = email.text_body || email.html_body || ""

    body
    |> String.slice(0, 500)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Extract full body if settings allow
  defp extract_body_full(email, opts) do
    if Keyword.get(opts, :save_body, false) do
      email.text_body || email.html_body
    else
      nil
    end
  end

  # Validate message_id uniqueness
  defp validate_message_id_uniqueness(changeset) do
    case get_field(changeset, :message_id) do
      nil ->
        changeset

      "" ->
        changeset

      message_id ->
        existing_log = get_log_by_message_id(message_id)
        current_id = get_field(changeset, :id)

        case {existing_log, current_id} do
          # No existing log, valid
          {nil, _} ->
            changeset

          # Existing log is the same as current record, valid
          {%__MODULE__{id: id}, id} ->
            changeset

          # Different existing log, invalid
          {%__MODULE__{}, _} ->
            add_error(changeset, :message_id, "has already been taken")
        end
    end
  end

  # Set sent_at if not provided
  defp maybe_set_sent_at(changeset) do
    case get_field(changeset, :sent_at) do
      nil -> put_change(changeset, :sent_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  # Validate body size for storage efficiency
  defp validate_body_size(changeset) do
    case get_field(changeset, :body_full) do
      nil ->
        changeset

      # 1MB limit
      body when byte_size(body) > 1_000_000 ->
        add_error(changeset, :body_full, "is too large (max 1MB)")

      _ ->
        changeset
    end
  end

  # Calculate safe percentage
  defp safe_percentage(numerator, denominator) when denominator > 0 do
    (numerator / denominator * 100) |> Float.round(1)
  end

  defp safe_percentage(_, _), do: 0.0

  # Get period start/end dates
  defp get_period_dates(:last_7_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -7, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_30_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -30, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_90_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -90, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_24_hours) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -1, :day)
    {start_date, end_date}
  end

  defp get_period_dates({:date_range, start_date, end_date})
       when is_struct(start_date, Date) and is_struct(end_date, Date) do
    start_datetime = DateTime.new!(start_date, ~T[00:00:00])
    end_datetime = DateTime.new!(end_date, ~T[23:59:59])
    {start_datetime, end_datetime}
  end

  # Get daily engagement statistics for trend analysis
  defp get_daily_engagement_stats(start_date, end_date) do
    from(l in __MODULE__,
      where: l.sent_at >= ^start_date and l.sent_at <= ^end_date,
      group_by: fragment("DATE(?)", l.sent_at),
      order_by: fragment("DATE(?)", l.sent_at),
      select: %{
        date: fragment("DATE(?)", l.sent_at),
        total_sent: count(l.id),
        delivered:
          count(
            fragment("CASE WHEN ? IN ('delivered', 'opened', 'clicked') THEN 1 END", l.status)
          ),
        opened: count(fragment("CASE WHEN ? IN ('opened', 'clicked') THEN 1 END", l.status)),
        clicked: count(fragment("CASE WHEN ? = 'clicked' THEN 1 END", l.status))
      }
    )
    |> repo().all()
  end

  # Calculate engagement trend
  defp calculate_engagement_trend([]), do: :stable
  defp calculate_engagement_trend(daily_stats) when length(daily_stats) < 3, do: :stable

  defp calculate_engagement_trend(daily_stats) do
    # Simple trend calculation based on first half vs second half
    mid_point = div(length(daily_stats), 2)
    {first_half, second_half} = Enum.split(daily_stats, mid_point)

    first_avg = calculate_average_engagement(first_half)
    second_avg = calculate_average_engagement(second_half)

    diff = second_avg - first_avg

    cond do
      diff > 2.0 -> :increasing
      diff < -2.0 -> :decreasing
      true -> :stable
    end
  end

  # Calculate average engagement rate
  defp calculate_average_engagement(daily_stats) do
    if length(daily_stats) > 0 do
      total_delivered = Enum.sum(Enum.map(daily_stats, & &1.delivered))
      total_opened = Enum.sum(Enum.map(daily_stats, & &1.opened))
      safe_percentage(total_opened, total_delivered)
    else
      0.0
    end
  end

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
