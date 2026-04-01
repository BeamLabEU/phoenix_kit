defmodule PhoenixKit.Migrations.Postgres.V89 do
  @moduledoc """
  V89: Add organization accounts support to users.

  Adds three new columns to `phoenix_kit_users`:
  - `account_type` (VARCHAR(20), NOT NULL, DEFAULT 'person') with CHECK constraint
  - `organization_name` (VARCHAR(255)) for organization display names
  - `organization_uuid` (UUID) self-referencing FK to link persons to organizations

  All operations are idempotent (guarded by information_schema.columns checks).
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # 1. Add account_type column
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_users'
          AND column_name = 'account_type'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_users
          ADD COLUMN account_type VARCHAR(20) NOT NULL DEFAULT 'person'
          CONSTRAINT phoenix_kit_users_account_type_check CHECK (account_type IN ('person', 'organization'));
      END IF;
    END $$;
    """)

    # 2. Add organization_name column
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_users'
          AND column_name = 'organization_name'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_users
          ADD COLUMN organization_name VARCHAR(255);
      END IF;
    END $$;
    """)

    # 3. Add organization_uuid column with FK
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_users'
          AND column_name = 'organization_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_users
          ADD COLUMN organization_uuid UUID
          REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    create_if_not_exists index(:phoenix_kit_users, [:account_type], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_users, [:organization_uuid], prefix: prefix)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '89'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists index(:phoenix_kit_users, [:organization_uuid], prefix: prefix)
    drop_if_exists index(:phoenix_kit_users, [:account_type], prefix: prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_users
      DROP COLUMN IF EXISTS organization_uuid,
      DROP COLUMN IF EXISTS organization_name,
      DROP COLUMN IF EXISTS account_type;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '88'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
