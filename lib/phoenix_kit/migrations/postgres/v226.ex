defmodule PhoenixKit.Migrations.Postgres.V226 do
  @moduledoc """
  V226: personal API keys.

  One additive column:

    * **`phoenix_kit_api_keys.personal`** (`boolean`, `NOT NULL`, default `false`). `true`
      marks a person's own key, made on the "My API keys" page through
      `PhoenixKit.API.Keys.create_personal_key/3` by a holder of the
      `api_personal_keys` or `api` permission. Such a key works only while its owner holds
      `api_personal_keys` or `api`, must expire, cannot need approval, and nobody but its
      owner may rotate it. Every existing key, and every key made on Settings -> API,
      reads `false` and behaves as before.

  ## Locks

  `ADD COLUMN ... DEFAULT false` is a catalog-only change on PostgreSQL 11 and later (no
  table rewrite); it waits for the table's ACCESS EXCLUSIVE lock for at most
  `lock_timeout`. Re-runnable.

  ## Down

  Drops the column: every personal key becomes an ordinary key of its owner (its
  expiry stays; the permission check and the rotation rule of personal keys no longer
  apply), so revoke personal keys before rolling back if that matters.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V226 back: the `personal` column goes."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_api_keys ADD COLUMN IF NOT EXISTS personal boolean DEFAULT false NOT NULL",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '226'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_api_keys DROP COLUMN IF EXISTS personal",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '225'"
    ]
  end
end
