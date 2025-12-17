defmodule PhoenixKit.Billing.WebhookEvent do
  @moduledoc """
  Schema for webhook event logging and idempotency.

  Every webhook received from payment providers is logged here to:
  - Ensure idempotency (same event_id is never processed twice)
  - Track processing status and errors
  - Enable debugging and auditing
  - Support retry logic for failed events

  ## Idempotency

  Before processing a webhook, we check if an event with the same
  `provider` + `event_id` combination exists. If it does, we skip
  processing and return success to prevent retries from provider.

  ## Retry Logic

  Failed events can be retried:
  1. Provider sends retry (we check idempotency, process if not done)
  2. Manual retry via admin interface
  3. Background worker for events stuck in processing
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "phoenix_kit_webhook_events" do
    field :provider, :string
    field :event_id, :string
    field :event_type, :string
    field :payload, :map, default: %{}
    field :processed, :boolean, default: false
    field :processed_at, :utc_datetime
    field :error_message, :string
    field :retry_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a webhook event.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :provider,
      :event_id,
      :event_type,
      :payload,
      :processed,
      :processed_at,
      :error_message,
      :retry_count
    ])
    |> validate_required([:provider, :event_id, :event_type])
    |> unique_constraint([:provider, :event_id],
      name: :phoenix_kit_webhook_events_provider_event_id_index
    )
  end

  @doc """
  Changeset for marking an event as processed.
  """
  def processed_changeset(event) do
    event
    |> change(%{
      processed: true,
      processed_at: DateTime.utc_now(),
      error_message: nil
    })
  end

  @doc """
  Changeset for marking an event as failed.
  """
  def failed_changeset(event, error_message) do
    event
    |> change(%{
      processed: false,
      error_message: error_message,
      retry_count: event.retry_count + 1
    })
  end

  # ============================================
  # Status Helpers
  # ============================================

  @doc """
  Returns true if the event was successfully processed.
  """
  def processed?(%__MODULE__{processed: true}), do: true
  def processed?(_), do: false

  @doc """
  Returns true if the event has failed and can be retried.
  """
  def retriable?(%__MODULE__{processed: false, retry_count: count}) when count < 5 do
    true
  end

  def retriable?(_), do: false

  @doc """
  Returns true if the event has exceeded max retries.
  """
  def max_retries_exceeded?(%__MODULE__{retry_count: count}) when count >= 5 do
    true
  end

  def max_retries_exceeded?(_), do: false
end
