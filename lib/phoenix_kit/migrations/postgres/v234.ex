defmodule PhoenixKit.Migrations.Postgres.V234 do
  @moduledoc """
  V234: approval of an OAuth connection, and what the review of the OAuth server added before
  V233 and V234 were released.

  **`phoenix_kit_api_oauth_grants.approved_at`** (new, nullable): when an owner of the site
  approved the connection, or when it was made, if it did not need approval. **A connection
  waits for approval exactly while this is `NULL`** (and it is not revoked or expired): a grant
  written with no decision at all reads as waiting, never as working
  (`PhoenixKit.API.OAuth.Grants.awaiting?/1`).

  The rows that exist when the column is added are all counted as approved
  (`approved_at = COALESCE(activated_at, inserted_at)`): before this version a connection never
  waited, so none of them can be waiting. This is done in the one step that adds the column, so a
  re-run on a chain that already has it never turns a waiting connection into an approved one.

  Who approved is in the activity feed (`oauth.grant_approved`); there is no column for it.

  **`phoenix_kit_api_oauth_grants.redirect_uri`** (new, nullable `text`): where the answers of the
  connection go, taken from the authorization code when the code is exchanged (the grant is
  activated). The client's own row can change after the consent (a metadata document is fetched
  again), so the owner who approves a connection, and the `oauth.grant_approved` entry, are shown
  the host the connection really answers to. `NULL` for a consent nobody finished and for the
  grants made before this column (the client's row stands in for them).

  **`phoenix_kit_api_oauth_requests.network_hash`** (new, nullable `bytea`, indexed): the SHA-256
  of the client network (`PhoenixKit.Utils.IpAddress.network/1`: an IPv4 address, an IPv6 /64) an
  authorization request came from, never the address itself, so that one network cannot hold
  every waiting request of the install (`api_oauth_requests_per_network`). `NULL` for the rows made
  before it, which count for no network.

  **Indexes on `expires_at`** of `phoenix_kit_api_oauth_tokens` and `phoenix_kit_api_oauth_codes`:
  the daily prune deletes by it, in batches.

  ## Locks

  `ADD COLUMN`s with no default (catalog-only, under `lock_timeout`), one `UPDATE` of the grants
  table, which holds one row per connection, and three `CREATE INDEX` on tables that a release
  before V233 does not have. Re-runnable.

  ## Down

  First ends every connection that still waits (`approved_at IS NULL`, not revoked): its tokens,
  its hidden key and the grant get `revoked_at`, the tokens the reason `migration_rollback`;
  otherwise the rollback would make the waiting connections work. Then drops the indexes and the
  columns this version added.

  ## Rolling back the code only

  Older code on a database that has V234 ignores `approved_at`, so every connection that waits
  would start working with its person's rights. Before deploying code older than V234 on a
  database that has it, end the waiting connections first. The normal way is to roll V234 back
  (`down_statements/1`): that ends the waiting connections and drops the column. To keep the
  column, run only the `DO` block of that SQL, which ends the waiting connections.
  """
  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    Helpers.validate_prefix!(prefix)
    Enum.each(up_statements(prefix), &execute/1)
  end

  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      # Column and backfill in one guarded step: the backfill is only right for the run that
      # adds the column.
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{prefix}' AND table_name = 'phoenix_kit_api_oauth_grants'
            AND column_name = 'approved_at'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_api_oauth_grants
            ADD COLUMN approved_at timestamp(0) without time zone;
          UPDATE #{p}phoenix_kit_api_oauth_grants
            SET approved_at = COALESCE(activated_at, inserted_at);
        END IF;
      END $$
      """,
      "ALTER TABLE #{p}phoenix_kit_api_oauth_grants ADD COLUMN IF NOT EXISTS redirect_uri text",
      "ALTER TABLE #{p}phoenix_kit_api_oauth_requests ADD COLUMN IF NOT EXISTS network_hash bytea",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_requests_network_hash_index ON #{p}phoenix_kit_api_oauth_requests (network_hash)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_tokens_expires_at_index ON #{p}phoenix_kit_api_oauth_tokens (expires_at)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_codes_expires_at_index ON #{p}phoenix_kit_api_oauth_codes (expires_at)",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '234'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      # Guarded: a re-run after the column went must not fail on it. Tokens and key first, by
      # the grants that still wait, then the grants themselves.
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{prefix}' AND table_name = 'phoenix_kit_api_oauth_grants'
            AND column_name = 'approved_at'
        ) THEN
          UPDATE #{p}phoenix_kit_api_oauth_tokens
            SET revoked_at = (now() AT TIME ZONE 'UTC'), revoke_reason = 'migration_rollback'
            WHERE revoked_at IS NULL AND grant_uuid IN (
              SELECT uuid FROM #{p}phoenix_kit_api_oauth_grants
              WHERE approved_at IS NULL AND revoked_at IS NULL);
          UPDATE #{p}phoenix_kit_api_keys
            SET revoked_at = (now() AT TIME ZONE 'UTC')
            WHERE revoked_at IS NULL AND oauth_grant_uuid IN (
              SELECT uuid FROM #{p}phoenix_kit_api_oauth_grants
              WHERE approved_at IS NULL AND revoked_at IS NULL);
          UPDATE #{p}phoenix_kit_api_oauth_grants
            SET revoked_at = (now() AT TIME ZONE 'UTC')
            WHERE approved_at IS NULL AND revoked_at IS NULL;
        END IF;
      END $$
      """,
      "DROP INDEX IF EXISTS #{p}phoenix_kit_api_oauth_codes_expires_at_index",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_api_oauth_tokens_expires_at_index",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_api_oauth_requests_network_hash_index",
      "ALTER TABLE #{p}phoenix_kit_api_oauth_requests DROP COLUMN IF EXISTS network_hash",
      "ALTER TABLE #{p}phoenix_kit_api_oauth_grants DROP COLUMN IF EXISTS redirect_uri",
      "ALTER TABLE #{p}phoenix_kit_api_oauth_grants DROP COLUMN IF EXISTS approved_at",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '233'"
    ]
  end
end
