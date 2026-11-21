defmodule PhoenixKit.Migrations.Postgres.V235 do
  @moduledoc """
  V235: browser push notifications (`PhoenixKit.Notifications.Push`).

  **`phoenix_kit_push_installations`** — one row per browser or device that turned push on: its push
  service endpoint (a capability URL: whoever holds it can push to that device) with its SHA-256
  (`endpoint_hash`, unique, the lookup key), the subscription's public keys (`p256dh`, `auth`), a label
  ("Chrome on Mac"), the browser's own id (`browser_id`, from a cookie, so a logout in that browser can
  find it), the VAPID key it was made with (`vapid_key_id`), and when it last worked. One browser has ONE
  subscription, shared by every account signed in there.

  **`phoenix_kit_push_bindings`** — one row per account opted in on an installation, made by that account
  itself. Unique per `(installation, user)`; both foreign keys cascade.

  **`phoenix_kit_push_pending`** — the notifications waiting for the next push of a user (the 30-second
  grouping): a row per notification, read and deleted by the worker that sends one push for all of them.

  ## Locks

  Three new tables and their indexes. Re-runnable.

  ## Down

  Drops the three tables.
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
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_push_installations (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        endpoint text NOT NULL,
        endpoint_hash bytea NOT NULL,
        p256dh character varying(255) NOT NULL,
        auth character varying(255) NOT NULL,
        label character varying(160),
        browser_id character varying(64),
        vapid_key_id character varying(64) NOT NULL,
        last_success_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_push_installations_endpoint_hash_index ON #{p}phoenix_kit_push_installations (endpoint_hash)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_push_installations_browser_id_index ON #{p}phoenix_kit_push_installations (browser_id)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_push_bindings (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        installation_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_push_installations(uuid) ON DELETE CASCADE,
        user_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_push_bindings_installation_user_index ON #{p}phoenix_kit_push_bindings (installation_uuid, user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_push_bindings_user_uuid_index ON #{p}phoenix_kit_push_bindings (user_uuid)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_push_pending (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        user_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        notification_uuid uuid,
        type_key character varying(160),
        title text,
        line text,
        link text,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_push_pending_user_uuid_index ON #{p}phoenix_kit_push_pending (user_uuid, inserted_at)",
      "COMMENT ON TABLE #{p}phoenix_kit IS '235'",
      "RESET lock_timeout"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_push_pending",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_push_bindings",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_push_installations",
      "COMMENT ON TABLE #{p}phoenix_kit IS '234'",
      "RESET lock_timeout"
    ]
  end
end
