defmodule PhoenixKit.Migrations.Postgres.V103 do
  @moduledoc """
  V103: Per-user notifications driven by the activity feed.

  Creates `phoenix_kit_notifications` — one row per (activity, recipient_user)
  with independent `seen_at` / `dismissed_at` timestamps. Generated in fan-out
  fashion by `PhoenixKit.Notifications.maybe_create_from_activity/1` whenever an
  activity targets a user other than the actor.

  ## Schema

  - `uuid`            — UUIDv7 primary key
  - `activity_uuid`   — FK → `phoenix_kit_activities` (ON DELETE CASCADE)
  - `recipient_uuid`  — FK → `phoenix_kit_users`      (ON DELETE CASCADE)
  - `seen_at`         — `NULL` = unread; set when the user clicks the row or
                        uses "Mark all as seen"
  - `dismissed_at`    — `NULL` = still visible; set when the user dismisses
  - `inserted_at`     — creation timestamp (no `updated_at`)

  ## Indexes

  - Unique (`activity_uuid`, `recipient_uuid`) — one notification per activity
    per recipient
  - Partial (`recipient_uuid`, `inserted_at`) WHERE `dismissed_at IS NULL` —
    covers the main "my undismissed inbox, newest first" read path

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_notifications (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      activity_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_activities(uuid) ON DELETE CASCADE,
      recipient_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
      seen_at TIMESTAMPTZ,
      dismissed_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_notifications_activity_recipient_index
    ON #{p}phoenix_kit_notifications (activity_uuid, recipient_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_notifications_recipient_inbox_index
    ON #{p}phoenix_kit_notifications (recipient_uuid, inserted_at DESC)
    WHERE dismissed_at IS NULL
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '103'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_notifications_recipient_inbox_index")

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_notifications_activity_recipient_index")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_notifications")
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '102'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
