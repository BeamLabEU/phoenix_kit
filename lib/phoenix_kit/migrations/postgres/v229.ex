defmodule PhoenixKit.Migrations.Postgres.V229 do
  @moduledoc """
  Relationship types, roles on an acting link, and translated role names.

  Plan: `dev_docs/plans/2026-11-07-account-relationships.md`.

    * **`phoenix_kit_relationship_types`** (new): the kinds of link an app defines,
      as data. Two built-in rows, so a staff level works with no setup: `manager`,
      with a fixed uuid so the column default below can name it, and `staff`, who may
      act but not manage.
    * **`phoenix_kit_organization_managers`** gains `relationship_type_uuid`,
      `all_roles` and `metadata`. Every existing grant becomes a `manager` link
      with `all_roles = true`, which is what it means today.
    * **`phoenix_kit_organization_manager_roles`** (new): the roles of a link whose
      `all_roles` is false. `role_uuid` is `ON DELETE RESTRICT`, so a role on a link
      counts as in use.
    * **`phoenix_kit_organization_invitations`** gains the same three facts for the
      link it will create. `role_uuids` is a snapshot, not a join: at acceptance
      only the roles that still exist apply, so a deleted role leaves the person
      with less, never more. `kind` stays `manager` for every acting type, so the
      pending unique index does not change.
    * **`phoenix_kit_user_roles`** gains `data`: name and description per language.

  ## Locks

  Additive columns with constant defaults are catalog-only. The foreign keys and
  the backfill scan two small tables. Everything runs under `lock_timeout`, and
  every statement can be run again.

  ## Down

  ⚠️ **Rolling back widens access.** It drops the role lists, so every narrowed link
  returns to the company's full authority. Roll the code back with the schema, and
  end acting sessions first. Translations and custom relationship types are lost.
  """
  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  # `PhoenixKit.Users.RelationshipType.manager_uuid/0` is the same value; a test
  # holds the two together. Literal here so the migration never depends on
  # application code that may change after it shipped.
  @manager_type_uuid "019a0000-0000-7000-8000-000000000229"
  @staff_type_uuid "019a0000-0000-7000-8000-00000000022a"

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
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_relationship_types (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        key character varying(64) NOT NULL,
        data jsonb NOT NULL DEFAULT '{}'::jsonb,
        from_kind character varying(20) NOT NULL,
        to_kind character varying(20) NOT NULL,
        can_act boolean NOT NULL DEFAULT false,
        can_manage boolean NOT NULL DEFAULT false,
        status character varying(20) NOT NULL DEFAULT 'active',
        position integer NOT NULL DEFAULT 0,
        builtin boolean NOT NULL DEFAULT false,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        CONSTRAINT phoenix_kit_relationship_types_status_check
          CHECK (status IN ('active', 'archived')),
        CONSTRAINT phoenix_kit_relationship_types_kinds_check
          CHECK (from_kind IN ('person', 'organization') AND to_kind IN ('person', 'organization')),
        CONSTRAINT phoenix_kit_relationship_types_manage_check
          CHECK (NOT can_manage OR can_act),
        CONSTRAINT phoenix_kit_relationship_types_act_check
          CHECK (NOT can_act OR (from_kind = 'person' AND to_kind = 'organization'))
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_relationship_types_key_index ON #{p}phoenix_kit_relationship_types (key)",
      """
      INSERT INTO #{p}phoenix_kit_relationship_types
        (uuid, key, from_kind, to_kind, can_act, can_manage, position, builtin)
      VALUES
        ('#{@manager_type_uuid}', 'manager', 'person', 'organization', true, true, 10, true),
        ('#{@staff_type_uuid}', 'staff', 'person', 'organization', true, false, 20, true)
      ON CONFLICT DO NOTHING
      """,
      "ALTER TABLE #{p}phoenix_kit_organization_managers ADD COLUMN IF NOT EXISTS relationship_type_uuid uuid NOT NULL DEFAULT '#{@manager_type_uuid}'",
      "ALTER TABLE #{p}phoenix_kit_organization_managers ADD COLUMN IF NOT EXISTS all_roles boolean NOT NULL DEFAULT true",
      "ALTER TABLE #{p}phoenix_kit_organization_managers ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb",
      constraint(
        prefix,
        "phoenix_kit_organization_managers",
        "pk_org_managers_relationship_type_fkey",
        "FOREIGN KEY (relationship_type_uuid) REFERENCES #{p}phoenix_kit_relationship_types(uuid) ON DELETE RESTRICT"
      ),
      "CREATE INDEX IF NOT EXISTS phoenix_kit_organization_managers_type_index ON #{p}phoenix_kit_organization_managers (relationship_type_uuid)",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_organization_manager_roles (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        organization_manager_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_organization_managers(uuid) ON DELETE CASCADE,
        role_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_user_roles(uuid) ON DELETE RESTRICT,
        assigned_by_uuid uuid REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_organization_manager_roles_link_role_index ON #{p}phoenix_kit_organization_manager_roles (organization_manager_uuid, role_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_organization_manager_roles_role_index ON #{p}phoenix_kit_organization_manager_roles (role_uuid)",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations ADD COLUMN IF NOT EXISTS relationship_type_uuid uuid",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations ADD COLUMN IF NOT EXISTS all_roles boolean NOT NULL DEFAULT true",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations ADD COLUMN IF NOT EXISTS role_uuids uuid[] NOT NULL DEFAULT '{}'",
      constraint(
        prefix,
        "phoenix_kit_organization_invitations",
        "pk_org_invitations_relationship_type_fkey",
        "FOREIGN KEY (relationship_type_uuid) REFERENCES #{p}phoenix_kit_relationship_types(uuid) ON DELETE RESTRICT"
      ),
      "UPDATE #{p}phoenix_kit_organization_invitations SET relationship_type_uuid = '#{@manager_type_uuid}' WHERE kind = 'manager' AND relationship_type_uuid IS NULL",
      constraint(
        prefix,
        "phoenix_kit_organization_invitations",
        "phoenix_kit_org_invitations_type_check",
        "CHECK ((kind = 'manager') = (relationship_type_uuid IS NOT NULL))"
      ),
      "ALTER TABLE #{p}phoenix_kit_user_roles ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb",
      "COMMENT ON TABLE #{p}phoenix_kit IS '229'",
      "RESET lock_timeout"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "ALTER TABLE #{p}phoenix_kit_user_roles DROP COLUMN IF EXISTS data",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations DROP CONSTRAINT IF EXISTS phoenix_kit_org_invitations_type_check",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations DROP COLUMN IF EXISTS role_uuids",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations DROP COLUMN IF EXISTS all_roles",
      "ALTER TABLE #{p}phoenix_kit_organization_invitations DROP COLUMN IF EXISTS relationship_type_uuid",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_organization_manager_roles",
      "ALTER TABLE #{p}phoenix_kit_organization_managers DROP COLUMN IF EXISTS metadata",
      "ALTER TABLE #{p}phoenix_kit_organization_managers DROP COLUMN IF EXISTS all_roles",
      "ALTER TABLE #{p}phoenix_kit_organization_managers DROP COLUMN IF EXISTS relationship_type_uuid",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_relationship_types",
      "COMMENT ON TABLE #{p}phoenix_kit IS '228'",
      "RESET lock_timeout"
    ]
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
