defmodule PhoenixKit.Emails.Event do
  @moduledoc """
  Email event schema for managing delivery events in PhoenixKit.

  This schema records events that occur after email sending, such as delivery,
  bounce, complaint, open, and click events. These events are typically received
  from email providers like AWS SES through webhooks.

  ## Schema Fields

  - `email_log_id`: Foreign key to the associated email log
  - `event_type`: Type of event (send, delivery, bounce, complaint, open, click)
  - `event_data`: JSONB map containing event-specific data from the provider
  - `occurred_at`: Timestamp when the event occurred
  - `ip_address`: IP address of the recipient (for open/click events)
  - `user_agent`: User agent string (for open/click events)
  - `geo_location`: JSONB map with geographic data (country, region, city)
  - `link_url`: URL that was clicked (for click events)
  - `bounce_type`: Type of bounce (hard, soft, for bounce events)
  - `complaint_type`: Type of complaint (abuse, auth-failure, fraud, etc.)

  ## Event Types

  - **send**: Email was successfully sent to the provider
  - **delivery**: Email was successfully delivered to recipient's inbox
  - **bounce**: Email bounced (permanent or temporary failure)
  - **complaint**: Recipient marked email as spam
  - **open**: Recipient opened the email (AWS SES tracking)
  - **click**: Recipient clicked a link in the email

  ## Associations

  - `email_log`: Belongs to the EmailLog that this event is associated with

  ## Usage Examples

      # Create a delivery event
      {:ok, event} = PhoenixKit.Emails.Event.create_event(%{
        email_log_id: log.id,
        event_type: "delivery",
        event_data: %{
          timestamp: "2024-01-15T10:30:00.000Z",
          smtp_response: "250 OK"
        }
      })

      # Create an open event with managing data
      {:ok, event} = PhoenixKit.Emails.Event.create_event(%{
        email_log_id: log.id,
        event_type: "open",
        ip_address: "192.168.1.1",
        user_agent: "Mozilla/5.0...",
        geo_location: %{country: "US", region: "CA", city: "San Francisco"}
      })

      # Get all events for an email
      events = PhoenixKit.Emails.Event.for_email_log(log_id)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  @derive {Jason.Encoder, except: [:__meta__, :email_log]}

  alias PhoenixKit.Emails.Log

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_email_events" do
    field :uuid, Ecto.UUID
    field :event_type, :string
    field :event_data, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
    field :ip_address, :string
    field :user_agent, :string
    field :geo_location, :map, default: %{}
    field :link_url, :string
    field :bounce_type, :string
    field :complaint_type, :string
    field :reject_reason, :string
    field :delay_type, :string
    field :subscription_type, :string
    field :failure_reason, :string

    # Associations
    belongs_to :email_log, Log, foreign_key: :email_log_id

    timestamps(type: :utc_datetime_usec)
  end

  ## --- Schema Functions ---

  @doc """
  Creates a changeset for email event creation and updates.

  Validates required fields and ensures data consistency.
  Automatically sets occurred_at on new records if not provided.
  """
  def changeset(email_event, attrs) do
    email_event
    |> cast(attrs, [
      :email_log_id,
      :event_type,
      :event_data,
      :occurred_at,
      :ip_address,
      :user_agent,
      :geo_location,
      :link_url,
      :bounce_type,
      :complaint_type,
      :reject_reason,
      :delay_type,
      :subscription_type,
      :failure_reason
    ])
    |> validate_required([:email_log_id, :event_type])
    |> validate_inclusion(:event_type, [
      "queued",
      "send",
      "delivery",
      "bounce",
      "complaint",
      "open",
      "click",
      "reject",
      "delivery_delay",
      "subscription",
      "rendering_failure"
    ])
    |> validate_inclusion(:bounce_type, ["hard", "soft"], message: "must be hard or soft")
    |> validate_bounce_type_consistency()
    |> validate_complaint_type_consistency()
    |> validate_click_event_consistency()
    |> foreign_key_constraint(:email_log_id)
    |> maybe_set_occurred_at()
    |> validate_ip_address_format()
  end

  ## --- Business Logic Functions ---

  @doc """
  Creates an email event.

  ## Examples

      iex> PhoenixKit.Emails.Event.create_event(%{
        email_log_id: 1,
        event_type: "delivery"
      })
      {:ok, %PhoenixKit.Emails.Event{}}

      iex> PhoenixKit.Emails.Event.create_event(%{event_type: "invalid"})
      {:error, %Ecto.Changeset{}}
  """
  def create_event(attrs \\ %{}) do
    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates an email event.

  ## Examples

      iex> PhoenixKit.Emails.Event.update_event(event, %{event_data: %{updated: true}})
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def update_event(%__MODULE__{} = email_event, attrs) do
    email_event
    |> changeset(attrs)
    |> repo().update()
  end

  @doc """
  Gets a single email event by ID.

  Raises `Ecto.NoResultsError` if the event does not exist.

  ## Examples

      iex> PhoenixKit.Emails.Event.get_event!(123)
      %PhoenixKit.Emails.Event{}
  """
  def get_event!(id) do
    __MODULE__
    |> preload([:email_log])
    |> repo().get!(id)
  end

  @doc """
  Gets all events for a specific email log.

  Returns events ordered by occurred_at (most recent first).

  ## Examples

      iex> PhoenixKit.Emails.Event.for_email_log(log_id)
      [%PhoenixKit.Emails.Event{}, ...]
  """
  def for_email_log(email_log_id) when is_integer(email_log_id) do
    from(e in __MODULE__,
      where: e.email_log_id == ^email_log_id,
      order_by: [desc: e.occurred_at]
    )
    |> repo().all()
  end

  @doc """
  Gets events of a specific type for an email log.

  ## Examples

      iex> PhoenixKit.Emails.Event.for_email_log_by_type(log_id, "open")
      [%PhoenixKit.Emails.Event{}, ...]
  """
  def for_email_log_by_type(email_log_id, event_type)
      when is_integer(email_log_id) and is_binary(event_type) do
    from(e in __MODULE__,
      where: e.email_log_id == ^email_log_id and e.event_type == ^event_type,
      order_by: [desc: e.occurred_at]
    )
    |> repo().all()
  end

  @doc """
  Checks if an event already exists for a specific email log and type.

  Returns true if an event of the given type already exists for the email log,
  false otherwise. This is used to prevent duplicate event creation.

  ## Examples

      iex> PhoenixKit.Emails.Event.event_exists?(log_id, "delivery")
      true

      iex> PhoenixKit.Emails.Event.event_exists?(log_id, "open")
      false
  """
  def event_exists?(email_log_id, event_type)
      when is_integer(email_log_id) and is_binary(event_type) do
    from(e in __MODULE__,
      where: e.email_log_id == ^email_log_id and e.event_type == ^event_type,
      limit: 1
    )
    |> repo().exists?()
  end

  @doc """
  Gets events of a specific type within a time range.

  ## Examples

      iex> PhoenixKit.Emails.Event.for_period_by_type(start_date, end_date, "click")
      [%PhoenixKit.Emails.Event{}, ...]
  """
  def for_period_by_type(start_date, end_date, event_type) do
    from(e in __MODULE__,
      where:
        e.occurred_at >= ^start_date and e.occurred_at <= ^end_date and
          e.event_type == ^event_type,
      order_by: [desc: e.occurred_at],
      preload: [:email_log]
    )
    |> repo().all()
  end

  @doc """
  Checks if an event of a specific type exists for an email log.

  ## Examples

      iex> PhoenixKit.Emails.Event.has_event_type?(log_id, "open")
      true
  """
  def has_event_type?(email_log_id, event_type)
      when is_integer(email_log_id) and is_binary(event_type) do
    query =
      from(e in __MODULE__,
        where: e.email_log_id == ^email_log_id and e.event_type == ^event_type,
        limit: 1
      )

    repo().exists?(query)
  end

  @doc """
  Gets the most recent event of a specific type for an email log.

  ## Examples

      iex> PhoenixKit.Emails.Event.get_latest_event_by_type(log_id, "open")
      %PhoenixKit.Emails.Event{}
  """
  def get_latest_event_by_type(email_log_id, event_type)
      when is_integer(email_log_id) and is_binary(event_type) do
    from(e in __MODULE__,
      where: e.email_log_id == ^email_log_id and e.event_type == ^event_type,
      order_by: [desc: e.occurred_at],
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Creates a delivery event from AWS SES webhook data.

  ## Examples

      iex> data = %{
        "eventType" => "delivery",
        "mail" => %{"messageId" => "abc123"},
        "delivery" => %{"timestamp" => "2024-01-15T10:30:00.000Z"}
      }
      iex> PhoenixKit.Emails.Event.create_from_ses_webhook(log, data)
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def create_from_ses_webhook(%Log{} = email_log, webhook_data) when is_map(webhook_data) do
    event_attrs = parse_ses_webhook_data(webhook_data)

    create_event(Map.merge(event_attrs, %{email_log_id: email_log.id}))
  end

  @doc """
  Creates a bounce event with bounce details.

  ## Examples

      iex> PhoenixKit.Emails.Event.create_bounce_event(log_id, "hard", "No such user")
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def create_bounce_event(email_log_id, bounce_type, reason \\ nil)
      when is_integer(email_log_id) do
    create_event(%{
      email_log_id: email_log_id,
      event_type: "bounce",
      bounce_type: bounce_type,
      event_data: %{
        bounce_type: bounce_type,
        reason: reason,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  @doc """
  Creates a complaint event with complaint details.

  ## Examples

      iex> PhoenixKit.Emails.Event.create_complaint_event(log_id, "abuse")
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def create_complaint_event(email_log_id, complaint_type \\ "abuse", feedback_id \\ nil)
      when is_integer(email_log_id) do
    create_event(%{
      email_log_id: email_log_id,
      event_type: "complaint",
      complaint_type: complaint_type,
      event_data: %{
        complaint_type: complaint_type,
        feedback_id: feedback_id,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  @doc """
  Creates an open event with managing data.

  ## Examples

      iex> PhoenixKit.Emails.Event.create_open_event(log_id, "192.168.1.1", "Mozilla/5.0...")
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def create_open_event(email_log_id, ip_address \\ nil, user_agent \\ nil, geo_data \\ %{})
      when is_integer(email_log_id) do
    create_event(%{
      email_log_id: email_log_id,
      event_type: "open",
      ip_address: ip_address,
      user_agent: user_agent,
      geo_location: geo_data,
      event_data: %{
        ip_address: ip_address,
        user_agent: user_agent,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  @doc """
  Creates a click event with link and managing data.

  ## Examples

      iex> PhoenixKit.Emails.Event.create_click_event(log_id, "https://example.com/link", "192.168.1.1")
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def create_click_event(
        email_log_id,
        link_url,
        ip_address \\ nil,
        user_agent \\ nil,
        geo_data \\ %{}
      )
      when is_integer(email_log_id) do
    create_event(%{
      email_log_id: email_log_id,
      event_type: "click",
      link_url: link_url,
      ip_address: ip_address,
      user_agent: user_agent,
      geo_location: geo_data,
      event_data: %{
        link_url: link_url,
        ip_address: ip_address,
        user_agent: user_agent,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  @doc """
  Creates a queued event when email is queued for sending.

  ## Examples

      iex> PhoenixKit.Emails.Event.create_queued_event(log_id)
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def create_queued_event(email_log_id) when is_integer(email_log_id) do
    create_event(%{
      email_log_id: email_log_id,
      event_type: "queued",
      event_data: %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  @doc """
  Creates a send event when email is successfully sent to provider.

  ## Examples

      iex> PhoenixKit.Emails.Event.create_send_event(log_id)
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def create_send_event(email_log_id, provider \\ nil) when is_integer(email_log_id) do
    create_event(%{
      email_log_id: email_log_id,
      event_type: "send",
      event_data: %{
        provider: provider,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  @doc """
  Gets event statistics for a time period.

  ## Examples

      iex> PhoenixKit.Emails.Event.get_event_stats(start_date, end_date)
      %{delivery: 1450, bounce: 30, open: 800, click: 200, complaint: 5}
  """
  def get_event_stats(start_date, end_date) do
    from(e in __MODULE__,
      where: e.occurred_at >= ^start_date and e.occurred_at <= ^end_date,
      group_by: e.event_type,
      select: %{event_type: e.event_type, count: count(e.id)}
    )
    |> repo().all()
    |> Enum.into(%{}, fn %{event_type: type, count: count} -> {String.to_atom(type), count} end)
  end

  @doc """
  Gets geographic distribution of events.

  ## Examples

      iex> PhoenixKit.Emails.Event.get_geo_distribution("open", start_date, end_date)
      %{"US" => 500, "CA" => 200, "UK" => 150}
  """
  def get_geo_distribution(event_type, start_date, end_date) do
    from(e in __MODULE__,
      where:
        e.event_type == ^event_type and e.occurred_at >= ^start_date and
          e.occurred_at <= ^end_date,
      where: fragment("?->>'country' IS NOT NULL", e.geo_location),
      group_by: fragment("?->>'country'", e.geo_location),
      select: %{
        country: fragment("?->>'country'", e.geo_location),
        count: count(e.id)
      },
      order_by: [desc: count(e.id)]
    )
    |> repo().all()
    |> Enum.into(%{}, fn %{country: country, count: count} -> {country, count} end)
  end

  @doc """
  Gets the most clicked links for a time period.

  ## Examples

      iex> PhoenixKit.Emails.Event.get_top_clicked_links(start_date, end_date, 10)
      [%{url: "https://example.com/product", clicks: 150}, ...]
  """
  def get_top_clicked_links(start_date, end_date, limit \\ 10) do
    from(e in __MODULE__,
      where:
        e.event_type == "click" and e.occurred_at >= ^start_date and e.occurred_at <= ^end_date,
      where: not is_nil(e.link_url),
      group_by: e.link_url,
      select: %{url: e.link_url, clicks: count(e.id)},
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> repo().all()
  end

  @doc """
  Deletes an email event.

  ## Examples

      iex> PhoenixKit.Emails.Event.delete_event(event)
      {:ok, %PhoenixKit.Emails.Event{}}
  """
  def delete_event(%__MODULE__{} = email_event) do
    repo().delete(email_event)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for managing email event changes.

  ## Examples

      iex> PhoenixKit.Emails.Event.change_event(event)
      %Ecto.Changeset{data: %PhoenixKit.Emails.Event{}}
  """
  def change_event(%__MODULE__{} = email_event, attrs \\ %{}) do
    changeset(email_event, attrs)
  end

  ## --- Private Helper Functions ---

  # Set occurred_at if not provided
  defp maybe_set_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  # Validate that bounce_type is only set for bounce events
  defp validate_bounce_type_consistency(changeset) do
    event_type = get_field(changeset, :event_type)
    bounce_type = get_field(changeset, :bounce_type)

    case {event_type, bounce_type} do
      {"bounce", nil} ->
        add_error(changeset, :bounce_type, "is required for bounce events")

      {"bounce", _} ->
        changeset

      {_, nil} ->
        changeset

      {_, _} ->
        add_error(changeset, :bounce_type, "can only be set for bounce events")
    end
  end

  # Validate that complaint_type is only set for complaint events
  defp validate_complaint_type_consistency(changeset) do
    event_type = get_field(changeset, :event_type)
    complaint_type = get_field(changeset, :complaint_type)

    case {event_type, complaint_type} do
      {"complaint", _} ->
        changeset

      {_, nil} ->
        changeset

      {_, _} ->
        add_error(changeset, :complaint_type, "can only be set for complaint events")
    end
  end

  # Validate that link_url is set for click events
  defp validate_click_event_consistency(changeset) do
    event_type = get_field(changeset, :event_type)
    link_url = get_field(changeset, :link_url)

    case {event_type, link_url} do
      {"click", nil} ->
        add_error(changeset, :link_url, "is required for click events")

      {"click", url} when is_binary(url) ->
        validate_url_format(changeset, :link_url)

      {_, _} ->
        changeset
    end
  end

  # Validate URL format
  defp validate_url_format(changeset, field) do
    validate_format(changeset, field, ~r/^https?:\/\/[^\s]+$/,
      message: "must be a valid HTTP or HTTPS URL"
    )
  end

  # Validate IP address format (basic validation)
  defp validate_ip_address_format(changeset) do
    case get_field(changeset, :ip_address) do
      nil ->
        changeset

      ip when is_binary(ip) ->
        if String.match?(ip, ~r/^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$/) do
          changeset
        else
          add_error(changeset, :ip_address, "must be a valid IPv4 or IPv6 address")
        end

      _ ->
        changeset
    end
  end

  # Parse AWS SES webhook data into event attributes
  defp parse_ses_webhook_data(webhook_data) do
    event_type = webhook_data["eventType"] || "unknown"

    base_attrs = %{
      event_type: normalize_event_type(event_type),
      occurred_at: parse_timestamp(webhook_data),
      event_data: webhook_data
    }

    # Add event-specific attributes
    case event_type do
      "bounce" ->
        bounce_data = webhook_data["bounce"] || %{}

        Map.merge(base_attrs, %{
          bounce_type: determine_bounce_type(bounce_data),
          event_data:
            Map.put(
              base_attrs.event_data,
              :parsed_bounce_type,
              determine_bounce_type(bounce_data)
            )
        })

      "complaint" ->
        complaint_data = webhook_data["complaint"] || %{}

        Map.merge(base_attrs, %{
          complaint_type: determine_complaint_type(complaint_data)
        })

      "click" ->
        click_data = webhook_data["click"] || %{}

        Map.merge(base_attrs, %{
          link_url: click_data["link"],
          ip_address: click_data["ipAddress"],
          user_agent: click_data["userAgent"]
        })

      "open" ->
        open_data = webhook_data["open"] || %{}

        Map.merge(base_attrs, %{
          ip_address: open_data["ipAddress"],
          user_agent: open_data["userAgent"]
        })

      _ ->
        base_attrs
    end
  end

  # Normalize AWS SES event types to our internal types
  defp normalize_event_type("send"), do: "send"
  defp normalize_event_type("delivery"), do: "delivery"
  defp normalize_event_type("bounce"), do: "bounce"
  defp normalize_event_type("complaint"), do: "complaint"
  defp normalize_event_type("open"), do: "open"
  defp normalize_event_type("click"), do: "click"
  defp normalize_event_type(_), do: "unknown"

  # Parse timestamp from webhook data
  defp parse_timestamp(webhook_data) do
    timestamp_str =
      webhook_data["delivery"]["timestamp"] ||
        webhook_data["bounce"]["timestamp"] ||
        webhook_data["complaint"]["timestamp"] ||
        webhook_data["open"]["timestamp"] ||
        webhook_data["click"]["timestamp"] ||
        DateTime.utc_now() |> DateTime.to_iso8601()

    case DateTime.from_iso8601(timestamp_str) do
      {:ok, datetime, _} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  # Determine bounce type from AWS SES data
  defp determine_bounce_type(%{"bounceType" => "Permanent"}), do: "hard"
  defp determine_bounce_type(%{"bounceType" => "Transient"}), do: "soft"
  defp determine_bounce_type(_), do: "hard"

  # Determine complaint type from AWS SES data
  defp determine_complaint_type(%{"complaintFeedbackType" => type}) when is_binary(type), do: type
  defp determine_complaint_type(_), do: "abuse"

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
