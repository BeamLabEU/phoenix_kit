defmodule PhoenixKit.Migrations.Postgres.V227 do
  @moduledoc """
  Managed organizations, their manager grants and session provenance.

  A managed organization has no independent login. Its session references both
  the person's session and their manager grant; deleting either cascades to
  the organization session. Both referencing columns are indexed.

  Invitation uniqueness includes the relationship kind, so member and manager
  invitations may coexist. Rolling back requires pending invitations to be
  unique without the kind; conflicting rows must be resolved before rollback.
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

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_users ADD COLUMN IF NOT EXISTS managed_by_members boolean NOT NULL DEFAULT false",
      "ALTER TABLE #{p}phoenix_kit_users ADD COLUMN IF NOT EXISTS contact_email public.citext",
      constraint(
        prefix,
        "phoenix_kit_users",
        "phoenix_kit_users_managed_organization_check",
        "CHECK (NOT managed_by_members OR (account_type = 'organization' AND NOT api_only))"
      ),
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_organization_managers (
        uuid uuid PRIMARY KEY DEFAULT #{Helpers.uuid_v7_call(prefix)},
        organization_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        user_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        granted_by_uuid uuid REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        CONSTRAINT phoenix_kit_organization_managers_not_self_check CHECK (organization_uuid <> user_uuid)
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_organization_managers_org_user_index ON #{p}phoenix_kit_organization_managers (organization_uuid, user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_organization_managers_user_uuid_index ON #{p}phoenix_kit_organization_managers (user_uuid)",
      "ALTER TABLE #{p}phoenix_kit_users_tokens ADD COLUMN IF NOT EXISTS acting_session_uuid uuid",
      "ALTER TABLE #{p}phoenix_kit_users_tokens ADD COLUMN IF NOT EXISTS organization_manager_uuid uuid",
      constraint(
        prefix,
        "phoenix_kit_users_tokens",
        "pk_tokens_acting_session_fkey",
        "FOREIGN KEY (acting_session_uuid) REFERENCES #{p}phoenix_kit_users_tokens(uuid) ON DELETE CASCADE"
      ),
      constraint(
        prefix,
        "phoenix_kit_users_tokens",
        "pk_tokens_organization_manager_fkey",
        "FOREIGN KEY (organization_manager_uuid) REFERENCES #{p}phoenix_kit_organization_managers(uuid) ON DELETE CASCADE"
      ),
      constraint(
        prefix,
        "phoenix_kit_users_tokens",
        "phoenix_kit_users_tokens_acting_pair_check",
        "CHECK ((acting_session_uuid IS NULL AND organization_manager_uuid IS NULL) OR " <>
          "(acting_session_uuid IS NOT NULL AND organization_manager_uuid IS NOT NULL AND context = 'session'))"
      ),
      "CREATE INDEX IF NOT EXISTS phoenix_kit_users_tokens_acting_session_uuid_index ON #{p}phoenix_kit_users_tokens (acting_session_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_users_tokens_organization_manager_index ON #{p}phoenix_kit_users_tokens (organization_manager_uuid)",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations ADD COLUMN IF NOT EXISTS kind character varying(20) NOT NULL DEFAULT 'member'",
      constraint(
        prefix,
        "phoenix_kit_organization_invitations",
        "phoenix_kit_org_invitations_kind_check",
        "CHECK (kind IN ('member', 'manager'))"
      ),
      invitation_index(p, "organization_uuid, email, kind"),
      "COMMENT ON TABLE #{p}phoenix_kit IS '227'",
      "RESET lock_timeout"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      invitation_index(p, "organization_uuid, email"),
      "ALTER TABLE #{p}phoenix_kit_organization_invitations DROP COLUMN IF EXISTS kind",
      "ALTER TABLE #{p}phoenix_kit_users_tokens DROP COLUMN IF EXISTS organization_manager_uuid",
      "ALTER TABLE #{p}phoenix_kit_users_tokens DROP COLUMN IF EXISTS acting_session_uuid",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_organization_managers",
      "ALTER TABLE #{p}phoenix_kit_users DROP CONSTRAINT IF EXISTS phoenix_kit_users_managed_organization_check",
      "ALTER TABLE #{p}phoenix_kit_users DROP COLUMN IF EXISTS contact_email",
      "ALTER TABLE #{p}phoenix_kit_users DROP COLUMN IF EXISTS managed_by_members",
      "COMMENT ON TABLE #{p}phoenix_kit IS '226'",
      "RESET lock_timeout"
    ]
  end

  # One statement even under the host migrator's autocommit policy: if the
  # replacement fails (e.g. conflicting pending kinds during rollback), the
  # old unique index remains in place.
  defp invitation_index(p, columns) do
    """
    DO $$ BEGIN
      DROP INDEX IF EXISTS #{p}phoenix_kit_org_invitations_pending_unique_idx;
      CREATE UNIQUE INDEX phoenix_kit_org_invitations_pending_unique_idx
        ON #{p}phoenix_kit_organization_invitations (#{columns}) WHERE status = 'pending';
    END $$
    """
  end

  defp constraint(prefix, table, name, definition) do
    """
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}' AND t.relname = '#{table}' AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{prefix}.#{table} ADD CONSTRAINT #{name} #{definition};
      END IF;
    END $$
    """
  end
end
