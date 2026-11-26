defmodule PhoenixKit.Migrations.Postgres.V238 do
  @moduledoc """
  V238: a rate limit of its own on an API key (`PhoenixKit.API.RateLimit`).

  **`phoenix_kit_api_keys.rate_limit_per_minute`** (integer, nullable, `> 0` when set) —
  the cost units a minute this key may spend. NULL (every existing key) is the shared
  limit, `api_admin_rate_per_min`, exactly as before. A set value never raises a key above
  the shared limit: the key's bucket is limited to the smaller of the two, so issuing keys
  cannot multiply what the API serves.

  ## Locks

  One nullable column with no default and a CHECK that every existing row (NULL) passes, on a
  table of a few rows per person. Re-runnable.

  ## Down

  Drops the column (and its CHECK with it).
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
      """
      ALTER TABLE #{p}phoenix_kit_api_keys
        ADD COLUMN IF NOT EXISTS rate_limit_per_minute integer
        CONSTRAINT phoenix_kit_api_keys_rate_limit_per_minute_check
        CHECK (rate_limit_per_minute IS NULL OR rate_limit_per_minute > 0)
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '238'",
      "RESET lock_timeout"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_api_keys DROP COLUMN IF EXISTS rate_limit_per_minute",
      "COMMENT ON TABLE #{p}phoenix_kit IS '237'",
      "RESET lock_timeout"
    ]
  end
end
