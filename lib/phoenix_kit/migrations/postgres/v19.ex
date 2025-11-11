defmodule PhoenixKit.Migrations.Postgres.V19 do
  @moduledoc """
  PhoenixKit V19 Migration: Enhanced Email Status Tracking

  Adds additional timestamp fields to phoenix_kit_email_logs table for comprehensive
  email lifecycle tracking, enabling full visibility from queue to delivery.

  ## Changes

  ### Email Logs Table (phoenix_kit_email_logs)
  - Adds `queued_at` timestamp for when email enters send queue
  - Adds `rejected_at` timestamp for provider rejections
  - Adds `failed_at` timestamp for send failures
  - Adds `delayed_at` timestamp for delivery delays

  ## Features

  - **Complete Lifecycle Tracking**: Track emails from queued → sent → delivered
  - **Failure Timestamps**: Precise timing for rejections and failures
  - **Delay Tracking**: Monitor when emails experience delivery delays
  - **Status History**: Enhanced audit trail with granular timestamps

  ## Email Status Flow

  ```
  QUEUED (queued_at) → SENT (sent_at) → DELIVERED (delivered_at)
                    ↘ FAILED (failed_at)
                    ↘ REJECTED (rejected_at)

  DELIVERED → OPENED (opened_at) → CLICKED (clicked_at)
           ↘ HARD_BOUNCED/SOFT_BOUNCED (bounced_at)
           ↘ COMPLAINT (complained_at)
           ↘ DELAYED (delayed_at)
  ```

  ## Usage Examples

  ```elixir
  # Email queued for sending
  Log.create_log(%{..., status: "queued", queued_at: DateTime.utc_now()})

  # Email sent to provider
  Log.update_status(log, "sent", %{sent_at: DateTime.utc_now()})

  # Email delivery confirmed
  Log.mark_as_delivered(log, DateTime.utc_now())

  # Email rejected by provider
  Log.mark_as_rejected(log, "Invalid recipient", DateTime.utc_now())
  ```
  """
  use Ecto.Migration

  @doc """
  Run the V19 migration to add enhanced email status tracking fields.
  """
  def up(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      add :queued_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :delayed_at, :utc_datetime_usec
    end

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_email_logs", prefix)}.queued_at IS
    'Timestamp when email was queued for sending'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_email_logs", prefix)}.rejected_at IS
    'Timestamp when email was rejected by provider'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_email_logs", prefix)}.failed_at IS
    'Timestamp when email send failed'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_email_logs", prefix)}.delayed_at IS
    'Timestamp when email delivery was delayed'
    """

    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '19'"
  end

  @doc """
  Rollback the V19 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_email_logs, prefix: prefix) do
      remove :queued_at
      remove :rejected_at
      remove :failed_at
      remove :delayed_at
    end

    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '18'"
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
