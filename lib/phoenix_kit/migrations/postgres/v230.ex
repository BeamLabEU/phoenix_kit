defmodule PhoenixKit.Migrations.Postgres.V230 do
  @moduledoc """
  V230: the country and the device cookie of a known device.

  Two additive columns on `phoenix_kit_user_known_devices`:

    * **`country_code`** (`varchar(2)`, `NULL`): the ISO 3166-1 alpha-2 code of
      the place the device first signed in from, resolved once by
      `PhoenixKit.Users.LoginAlerts` together with the `location` text V147
      added. `location` is display text ("Tallinn, Estonia") and cannot be
      compared; this can. It backs the "sign-in from a new country" alert
      (`new_country_login_alert_enabled`).
    * **`device_token_hash`** (`varchar(64)`, `NULL`): a SHA-256 (hex) of the
      account's uuid and the browser's `_phoenix_kit_device` cookie. It
      recognizes a browser across updates and IP changes, which the
      user-agent hash cannot (it covers the version number). The raw cookie
      value is never stored.

  Existing rows keep `NULL` in both. Their country was never stored and the
  lookup service is not asked again for history: an account whose rows all
  read `NULL` has no known country yet, so its next new device records one
  and alerts on nothing. A row learns its device hash the next time its
  browser signs in from the same address; until then the user-agent hash
  still recognizes it, as before V230.

  ## Locks

  Two `ADD COLUMN`s with no default: catalog-only, bounded by `lock_timeout`.
  No backfill. Re-runnable.

  ## Down

  Drops both columns. Country alerts then have nothing to compare against,
  and browsers are recognized by user agent alone; roll the code back with
  the schema.
  """
  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V230 back: both columns go."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_user_known_devices ADD COLUMN IF NOT EXISTS country_code character varying(2)",
      "ALTER TABLE #{p}phoenix_kit_user_known_devices ADD COLUMN IF NOT EXISTS device_token_hash character varying(64)",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '230'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_user_known_devices DROP COLUMN IF EXISTS device_token_hash",
      "ALTER TABLE #{p}phoenix_kit_user_known_devices DROP COLUMN IF EXISTS country_code",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '229'"
    ]
  end
end
