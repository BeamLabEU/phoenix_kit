defmodule PhoenixKit.Migrations.Postgres.V231 do
  @moduledoc """
  V231: passkeys.

  Plan: `dev_docs/plans/2026-11-10-passkeys.md`.

  **`phoenix_kit_user_passkeys`** (new): a person's passkeys, one row per WebAuthn
  credential, read by `PhoenixKit.Users.Passkeys`. The site keeps the public key only;
  the private key never leaves the person's device.

    * `credential_id` (`bytea`, unique): the handle the device names the passkey by.
    * `public_key` (`bytea`): the COSE key, CBOR-encoded.
    * `sign_count` (`bigint`): the device's signature counter. Synced passkeys always
      report 0; a non-zero count going backwards is logged, never refused.
    * `rp_id` (`varchar(255)`): the domain it was made for. A passkey works on that
      domain only, so a site that moved shows it as no longer usable.
    * `transports` (`varchar(32)[]`), `backup_eligible` (`boolean`): what the device
      reported (how it can be reached; synced or this device only).
    * `name`, `last_used_at`, `inserted_at`, `updated_at`.

  `user_uuid` cascades: a deleted account takes its passkeys with it.

  ## Locks

  A new table and its indexes; nothing existing is touched. Re-runnable.

  ## Down

  Drops the table: every passkey is gone, and their owners sign in another way.
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
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_user_passkeys (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        user_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        credential_id bytea NOT NULL,
        public_key bytea NOT NULL,
        sign_count bigint NOT NULL DEFAULT 0,
        rp_id character varying(255) NOT NULL,
        transports character varying(32)[] NOT NULL DEFAULT '{}',
        backup_eligible boolean NOT NULL DEFAULT false,
        name character varying(100) NOT NULL,
        last_used_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_user_passkeys_credential_id_index ON #{p}phoenix_kit_user_passkeys (credential_id)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_user_passkeys_user_uuid_index ON #{p}phoenix_kit_user_passkeys (user_uuid)",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '231'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_user_passkeys",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '230'"
    ]
  end
end
