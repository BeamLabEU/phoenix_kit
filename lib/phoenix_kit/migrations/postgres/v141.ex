defmodule PhoenixKit.Migrations.Postgres.V141 do
  @moduledoc """
  V141: Personal calendar events for the `phoenix_kit_calendar` module.

  One implicit personal calendar per user — events are keyed by
  `owner_uuid` (no calendars table in v1; recurrence is deliberately
  deferred).

  Time model (mirrors `phoenix_live_calendar`'s Event semantics):

  - Timed events use the `starts_at`/`ends_at` UTC pair; `ends_at` is
    EXCLUSIVE (`[start, end)`, iCal/RFC 5545 style).
  - All-day events use the `starts_on`/`ends_on` DATE pair (also
    end-exclusive) — proper date semantics instead of UTC-midnight
    instants, so a "day" never shifts across timezones/DST.
  - A CHECK constraint enforces exactly one pair per row, matching the
    `all_day` flag, with end > start on both pairs.

  `owner_uuid` cascades on user delete — a personal calendar follows its
  account's lifecycle.

  All statements are idempotent, safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_calendar_events (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      owner_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
      title VARCHAR(255) NOT NULL,
      description TEXT,
      location VARCHAR(255),
      all_day BOOLEAN NOT NULL DEFAULT FALSE,
      starts_at TIMESTAMP(0),
      ends_at TIMESTAMP(0),
      starts_on DATE,
      ends_on DATE,
      color VARCHAR(50),
      status VARCHAR(20) NOT NULL DEFAULT 'confirmed',
      inserted_at TIMESTAMP(0) NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP(0) NOT NULL DEFAULT NOW(),
      CONSTRAINT calendar_event_time_shape CHECK (
        (
          all_day = FALSE
          AND starts_at IS NOT NULL AND ends_at IS NOT NULL
          AND starts_on IS NULL AND ends_on IS NULL
          AND ends_at > starts_at
        )
        OR
        (
          all_day = TRUE
          AND starts_on IS NOT NULL AND ends_on IS NOT NULL
          AND starts_at IS NULL AND ends_at IS NULL
          AND ends_on > starts_on
        )
      ),
      CONSTRAINT calendar_event_status CHECK (status IN ('confirmed', 'cancelled'))
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_calendar_events_owner_starts_at
    ON #{p}phoenix_kit_calendar_events (owner_uuid, starts_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_calendar_events_owner_starts_on
    ON #{p}phoenix_kit_calendar_events (owner_uuid, starts_on)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '141'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_calendar_events")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '140'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
