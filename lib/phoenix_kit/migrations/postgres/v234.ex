defmodule PhoenixKit.Migrations.Postgres.V234 do
  @moduledoc """
  V234: approval of an OAuth connection.

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

  ## Locks

  One `ADD COLUMN` with no default (catalog-only, under `lock_timeout`) and one `UPDATE` of the
  grants table, which holds one row per connection. Re-runnable.

  ## Down

  First ends every connection that still waits (`approved_at IS NULL`, not revoked): its tokens,
  its hidden key and the grant get `revoked_at`, the tokens the reason `migration_rollback`;
  otherwise the rollback would make the waiting connections work. Then drops the column.

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
      "ALTER TABLE #{p}phoenix_kit_api_oauth_grants DROP COLUMN IF EXISTS approved_at",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '233'"
    ]
  end
end
