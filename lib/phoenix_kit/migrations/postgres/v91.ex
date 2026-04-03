defmodule PhoenixKit.Migrations.Postgres.V91 do
  @moduledoc """
  V91: Add organization accounts support and organization invitations.

  ## User schema changes

  Adds three new columns to `phoenix_kit_users`:
  - `account_type` (VARCHAR(20), NOT NULL, DEFAULT 'person') with CHECK constraint
  - `organization_name` (VARCHAR(255)) for organization display names
  - `organization_uuid` (UUID) self-referencing FK to link persons to organizations

  ## Organization invitations table

  Creates `phoenix_kit_organization_invitations`:
  - BYTEA token (SHA-256 hash of raw 32-byte token, unique)
  - Status CHECK constraint: pending | accepted | declined | cancelled
  - FK to phoenix_kit_users: organization_uuid (CASCADE), invited_by_uuid (SET NULL)
  - Partial unique index on (organization_uuid, email) WHERE status = 'pending'

  All operations are idempotent.
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
    # 4. Create organization invitations table
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_organization_invitations'
      ) THEN
        CREATE TABLE #{p}phoenix_kit_organization_invitations (
          uuid UUID NOT NULL DEFAULT uuid_generate_v7() PRIMARY KEY,
          organization_uuid UUID NOT NULL
            REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
          email VARCHAR(160) NOT NULL,
          invited_by_uuid UUID
            REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
          token BYTEA NOT NULL,
          status VARCHAR(20) NOT NULL DEFAULT 'pending'
            CONSTRAINT phoenix_kit_org_invitations_status_check
            CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
          expires_at TIMESTAMPTZ NOT NULL,
          accepted_at TIMESTAMPTZ,
          inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
      END IF;
    END $$;
    """)

    create_if_not_exists(
      unique_index(:phoenix_kit_organization_invitations, [:token], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_organization_invitations, [:organization_uuid], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_organization_invitations, [:email], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_organization_invitations, [:status], prefix: prefix))

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_organization_invitations'
          AND indexname = 'phoenix_kit_org_invitations_pending_unique_idx'
      ) THEN
        CREATE UNIQUE INDEX phoenix_kit_org_invitations_pending_unique_idx
          ON #{p}phoenix_kit_organization_invitations (organization_uuid, email)
          WHERE status = 'pending';
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '91'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Drop invitations table first (FK depends on phoenix_kit_users)
    drop_if_exists(index(:phoenix_kit_organization_invitations, [:status], prefix: prefix))
    drop_if_exists(index(:phoenix_kit_organization_invitations, [:email], prefix: prefix))

    drop_if_exists(
      index(:phoenix_kit_organization_invitations, [:organization_uuid], prefix: prefix)
    )

    drop_if_exists(unique_index(:phoenix_kit_organization_invitations, [:token], prefix: prefix))

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_organization_invitations")

    drop_if_exists index(:phoenix_kit_users, [:organization_uuid], prefix: prefix)
    drop_if_exists index(:phoenix_kit_users, [:account_type], prefix: prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_users
      DROP COLUMN IF EXISTS organization_uuid,
      DROP COLUMN IF EXISTS organization_name,
      DROP COLUMN IF EXISTS account_type;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '90'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
