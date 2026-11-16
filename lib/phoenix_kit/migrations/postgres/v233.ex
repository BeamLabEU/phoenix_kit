defmodule PhoenixKit.Migrations.Postgres.V233 do
  @moduledoc """
  V233: OAuth for the MCP endpoint of the machine API.

  Five new tables, all read by `PhoenixKit.API.OAuth`:

    * **`phoenix_kit_api_oauth_clients`**: the applications that may ask for access.
      `client_id` is unique (a metadata-document URL, a registered id or a pre-registered
      one) and `kind` says which (`cimd | dcr | preregistered`). `redirect_uris` is what
      the client declared; `metadata_*` and `last_seen_at` serve the metadata cache and
      the clean-up of registered clients nobody uses.
    * **`phoenix_kit_api_oauth_requests`**: one validated authorization request waiting for
      the person's consent. It is found by `request_token_hash` (the SHA-256 of a random
      token that sits in the consent URL; unique), lives ten minutes and is used once
      (`consumed_at`). It pins the client's name and redirect URIs as they were when the
      request was made (`client_snapshot`).
    * **`phoenix_kit_api_oauth_grants`**: one consent. It belongs to a person
      (`user_uuid`), a client and to **one hidden API key** (`key_uuid`, unique): the key
      is what lets a grant reuse the actor, the rights, the rate limit, the confirmations
      and the activity of API keys. `activated_at` is set when the authorization code is
      exchanged, so a consent nobody finished can be told from a live one.
    * **`phoenix_kit_api_oauth_codes`**: authorization codes (SHA-256, 60 seconds, used
      once).
    * **`phoenix_kit_api_oauth_tokens`**: access and refresh tokens (SHA-256 only).
      `family` groups a rotation chain, `parent_uuid` names the token a retried refresh
      replaced (a plain column, no foreign key: rows of one grant are removed together by
      the grant's cascade) and `revoke_reason` says why a token was ended.

  **`phoenix_kit_api_keys.oauth_grant_uuid`** (new, nullable): marks the hidden key of a
  grant. No foreign key from this side (the grant references the key, so a cycle is
  avoided); a unique partial index keeps it one key per grant.

  Every user, client and key reference cascades: removing a person, a client or a key
  removes the grants and tokens under it.

  ## Locks

  New tables and their indexes; one `ADD COLUMN` with no default (catalog-only) and a
  partial index over an all-`NULL` column, both under `lock_timeout`. No backfill.
  Re-runnable.

  ## Down

  Drops the column, the index and the five tables: every grant and token is gone, and
  every connected application has to be authorized again.
  """
  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    Helpers.validate_prefix!(prefix)
    Helpers.ensure_uuid_v7_function(prefix)
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
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_api_oauth_clients (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        client_id character varying(2048) NOT NULL,
        kind character varying(16) NOT NULL,
        client_name character varying(160),
        client_uri character varying(2048),
        redirect_uris text[] NOT NULL DEFAULT '{}',
        metadata_fetched_at timestamp(0) without time zone,
        metadata_expires_at timestamp(0) without time zone,
        last_seen_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        CONSTRAINT phoenix_kit_api_oauth_clients_kind_check
          CHECK (kind IN ('cimd', 'dcr', 'preregistered'))
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_oauth_clients_client_id_index ON #{p}phoenix_kit_api_oauth_clients (client_id)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_api_oauth_requests (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        request_token_hash bytea NOT NULL,
        client_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_api_oauth_clients(uuid) ON DELETE CASCADE,
        redirect_uri text NOT NULL,
        code_challenge character varying(128) NOT NULL,
        resource character varying(2048) NOT NULL,
        state character varying(512),
        requested_scopes text[] NOT NULL DEFAULT '{}',
        client_snapshot jsonb NOT NULL DEFAULT '{}',
        expires_at timestamp(0) without time zone NOT NULL,
        consumed_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_oauth_requests_request_token_hash_index ON #{p}phoenix_kit_api_oauth_requests (request_token_hash)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_requests_client_uuid_index ON #{p}phoenix_kit_api_oauth_requests (client_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_requests_expires_at_index ON #{p}phoenix_kit_api_oauth_requests (expires_at)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_api_oauth_grants (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        user_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        client_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_api_oauth_clients(uuid) ON DELETE CASCADE,
        key_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_api_keys(uuid) ON DELETE CASCADE,
        resource character varying(2048) NOT NULL,
        scopes text[] NOT NULL DEFAULT '{}',
        expires_at timestamp(0) without time zone NOT NULL,
        activated_at timestamp(0) without time zone,
        revoked_at timestamp(0) without time zone,
        last_used_at timestamp(0) without time zone,
        created_ip character varying(45),
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_grants_user_uuid_index ON #{p}phoenix_kit_api_oauth_grants (user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_grants_client_uuid_index ON #{p}phoenix_kit_api_oauth_grants (client_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_oauth_grants_key_uuid_index ON #{p}phoenix_kit_api_oauth_grants (key_uuid)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_api_oauth_codes (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        code_hash bytea NOT NULL,
        grant_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_api_oauth_grants(uuid) ON DELETE CASCADE,
        redirect_uri text NOT NULL,
        code_challenge character varying(128) NOT NULL,
        expires_at timestamp(0) without time zone NOT NULL,
        used_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_oauth_codes_code_hash_index ON #{p}phoenix_kit_api_oauth_codes (code_hash)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_codes_grant_uuid_index ON #{p}phoenix_kit_api_oauth_codes (grant_uuid)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_api_oauth_tokens (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        token_hash bytea NOT NULL,
        kind character varying(8) NOT NULL,
        grant_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_api_oauth_grants(uuid) ON DELETE CASCADE,
        family uuid NOT NULL,
        parent_uuid uuid,
        expires_at timestamp(0) without time zone NOT NULL,
        used_at timestamp(0) without time zone,
        revoked_at timestamp(0) without time zone,
        revoke_reason character varying(32),
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        CONSTRAINT phoenix_kit_api_oauth_tokens_kind_check
          CHECK (kind IN ('access', 'refresh'))
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_oauth_tokens_token_hash_index ON #{p}phoenix_kit_api_oauth_tokens (token_hash)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_tokens_grant_uuid_index ON #{p}phoenix_kit_api_oauth_tokens (grant_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_oauth_tokens_parent_uuid_index ON #{p}phoenix_kit_api_oauth_tokens (parent_uuid) WHERE parent_uuid IS NOT NULL",
      "ALTER TABLE #{p}phoenix_kit_api_keys ADD COLUMN IF NOT EXISTS oauth_grant_uuid uuid",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_keys_oauth_grant_uuid_index ON #{p}phoenix_kit_api_keys (oauth_grant_uuid) WHERE oauth_grant_uuid IS NOT NULL",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '233'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_api_keys_oauth_grant_uuid_index",
      "ALTER TABLE #{p}phoenix_kit_api_keys DROP COLUMN IF EXISTS oauth_grant_uuid",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_oauth_tokens",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_oauth_codes",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_oauth_grants",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_oauth_requests",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_oauth_clients",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '232'"
    ]
  end
end
