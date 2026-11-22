defmodule PhoenixKit.Migrations.Postgres.V236 do
  @moduledoc """
  V236: cross-domain handoff (`PhoenixKit.Handoff`).

  **`phoenix_kit_handoff_tokens`** — one row per handoff a visitor's browser carries from one of the
  site's domains to another. The raw token is never stored: `token_hash` is its SHA-256 (unique, the
  lookup key). The row is bound to the domain it may be redeemed on (`target_host`), to the browser
  that asked for it (`browser_nonce_hash`, the SHA-256 of a nonce held in a cookie of the target
  domain) and, softly, to that browser's `User-Agent` (`user_agent_hash`, nullable). It carries the
  path to land on (`redirect_path`), the account to sign in (`user_uuid`, nullable: a guest has none;
  the foreign key cascades) and what the modules asked to carry (`payload`, a map of module key to
  that module's snapshot). `used_at` is set by the one statement that redeems the row; a row is
  redeemable while `used_at` is null and `expires_at` is in the future.

  ## Locks

  A new table and its indexes. Re-runnable.

  ## Down

  Drops the table.
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
    id = Helpers.uuid_v7_call(prefix)

    [
      "SET lock_timeout = '5000ms'",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_handoff_tokens (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        token_hash bytea NOT NULL,
        target_host text NOT NULL,
        redirect_path text NOT NULL,
        user_uuid uuid REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        payload jsonb NOT NULL DEFAULT '{}'::jsonb,
        browser_nonce_hash bytea NOT NULL,
        user_agent_hash bytea,
        expires_at timestamp(0) without time zone NOT NULL,
        used_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_handoff_tokens_token_hash_index ON #{p}phoenix_kit_handoff_tokens (token_hash)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_handoff_tokens_user_uuid_index ON #{p}phoenix_kit_handoff_tokens (user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_handoff_tokens_expires_at_index ON #{p}phoenix_kit_handoff_tokens (expires_at)",
      "COMMENT ON TABLE #{p}phoenix_kit IS '236'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_handoff_tokens",
      "COMMENT ON TABLE #{p}phoenix_kit IS '235'"
    ]
  end
end
