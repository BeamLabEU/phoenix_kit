defmodule PhoenixKit.Migrations.Postgres.V107 do
  @moduledoc """
  V107: Pin AI endpoints to a specific integration row via `integration_uuid`.

  Prior to this migration, `phoenix_kit_ai_endpoints.provider` stored a
  provider-type tag (`"openrouter"`) and the integrations system had to
  guess which connection row to use at request time via
  `find_first_connected/1` — necessary compensation for AI never having
  recorded the user's actual choice. This column closes that gap: each
  endpoint now references the integration row directly, so renaming or
  re-labelling integrations doesn't change which one an endpoint uses,
  and the resolver's `default`-based fallback chain becomes dead code.

  ## Up

  - Adds nullable `integration_uuid uuid` column to
    `phoenix_kit_ai_endpoints`.
  - Adds a btree index on the new column for FK-style lookups.
  - Backfills `integration_uuid` from the existing `provider` strings:
    - For `provider = "openrouter:my-key"` → match the exact storage
      row `integration:openrouter:my-key`.
    - For `provider = "openrouter"` (bare) → pick the
      most-recently-validated `integration:openrouter:*` row, breaking
      ties on `inserted_at ASC` (oldest first — stable on identical
      timestamps).
    - Endpoints with no matching integration row stay NULL; the user
      re-picks via the endpoint form.

  ## Down

  Drops the column. Lossy — endpoint→integration choices made via the
  new picker are discarded.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_ai_endpoints
    ADD COLUMN IF NOT EXISTS integration_uuid uuid
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_ai_endpoints_integration_uuid_index
    ON #{p}phoenix_kit_ai_endpoints (integration_uuid)
    """)

    # Backfill #1 — endpoints with explicit `provider:name` shape map
    # one-to-one to a storage key.
    execute("""
    UPDATE #{p}phoenix_kit_ai_endpoints e
    SET integration_uuid = s.uuid
    FROM #{p}phoenix_kit_settings s
    WHERE s.key = 'integration:' || e.provider
      AND e.integration_uuid IS NULL
      AND e.provider LIKE '%:%'
    """)

    # Backfill #2 — endpoints with bare provider strings get matched
    # against the most-recently-validated row for that provider.
    # NULLS LAST keeps un-validated rows at the bottom; the row uuid
    # is the deterministic tiebreaker (UUIDv7 encodes time, so smaller
    # uuid ≈ older row → ASC = oldest first when timestamps tie).
    execute("""
    UPDATE #{p}phoenix_kit_ai_endpoints e
    SET integration_uuid = winner.uuid
    FROM (
      SELECT
        split_part(key, ':', 2) AS provider_key,
        uuid,
        ROW_NUMBER() OVER (
          PARTITION BY split_part(key, ':', 2)
          ORDER BY
            (value_json ->> 'last_validated_at') DESC NULLS LAST,
            uuid ASC
        ) AS rn
      FROM #{p}phoenix_kit_settings
      WHERE key LIKE 'integration:%:%'
    ) winner
    WHERE winner.rn = 1
      AND winner.provider_key = e.provider
      AND e.integration_uuid IS NULL
      AND e.provider NOT LIKE '%:%'
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '107'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    DROP INDEX IF EXISTS #{p}phoenix_kit_ai_endpoints_integration_uuid_index
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_ai_endpoints
    DROP COLUMN IF EXISTS integration_uuid
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '106'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
