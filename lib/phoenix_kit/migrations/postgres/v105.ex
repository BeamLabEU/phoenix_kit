defmodule PhoenixKit.Migrations.Postgres.V105 do
  @moduledoc """
  V105: CRM tables.

  Two tables supporting the upcoming `phoenix_kit_crm` plugin:

  ## phoenix_kit_crm_role_settings

  Tracks which user roles have opted into the CRM module. One row per
  role; the FK cascades on role deletion so no orphan cleanup is needed.

  - `role_uuid UUID PRIMARY KEY` — FK → `phoenix_kit_user_roles(uuid)` ON DELETE CASCADE
  - `enabled BOOLEAN NOT NULL DEFAULT false` — opt-in flag; false by default
    so existing roles are unaffected until an admin explicitly enables CRM.
  - `inserted_at`, `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`

  ## phoenix_kit_crm_user_role_view

  Per-user, per-scope view preferences for CRM tables (column selection,
  ordering, active filters). One row per (user, scope) pair; scope values
  are strings like `"role:<uuid>"` or `"companies"`.

  - `uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7()`
  - `user_uuid UUID NOT NULL` — FK → `phoenix_kit_users(uuid)` ON DELETE CASCADE
  - `scope VARCHAR(100) NOT NULL` — e.g. `"role:<uuid>"`, `"companies"`
  - `view_config JSONB NOT NULL DEFAULT '{}'` — arbitrary UI preferences blob
  - `inserted_at`, `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - `UNIQUE (user_uuid, scope)` — one preference row per user/scope pair
  - Index on `(user_uuid)` for per-user lookups

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_role_settings (
      role_uuid UUID PRIMARY KEY REFERENCES #{p}phoenix_kit_user_roles(uuid) ON DELETE CASCADE,
      enabled BOOLEAN NOT NULL DEFAULT false,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_user_role_view (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      user_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
      scope VARCHAR(100) NOT NULL,
      view_config JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_crm_user_role_view_user_scope_uniq UNIQUE (user_uuid, scope)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_crm_user_role_view_user
    ON #{p}phoenix_kit_crm_user_role_view (user_uuid)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '105'")
  end

  @doc """
  Rolls V105 back by dropping both CRM tables in reverse creation order.

  **Lossy rollback:** all role CRM opt-in settings and user view preferences
  are lost. Back up before rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_user_role_view CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_crm_role_settings CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '104'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
