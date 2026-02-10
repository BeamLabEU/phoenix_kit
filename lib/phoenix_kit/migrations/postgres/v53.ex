defmodule PhoenixKit.Migrations.Postgres.V53 do
  @moduledoc """
  V53: Module-Level Permission System

  Creates the `phoenix_kit_role_permissions` table for granular access control
  over which roles can access which admin sections and modules.

  ## Design

  - Allowlist model: row present = granted, absent = denied
  - Owner role bypasses permissions entirely (hardcoded in code)
  - Admin role gets ALL permissions seeded by default
  - New/custom roles start with NO permissions

  ## Table Structure

  - `role_id` FK to phoenix_kit_user_roles (CASCADE on delete)
  - `module_key` identifies the admin section or feature module
  - `granted_by` FK to phoenix_kit_users (SET NULL on delete) for audit trail
  - Unique constraint on (role_id, module_key) prevents duplicates

  ## Permission Keys

  Core sections (5): dashboard, users, media, settings, modules
  Feature modules (19): billing, shop, emails, entities, tickets, posts, ai,
    sync, publishing, referrals, sitemap, seo, maintenance, storage, languages,
    connections, legal, db, jobs
  """

  use Ecto.Migration

  @permission_keys ~w(
    dashboard users media settings modules
    billing shop emails entities tickets posts ai
    sync publishing referrals sitemap seo maintenance
    storage languages connections legal db jobs
  )

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""
    schema_name = if prefix && prefix != "public", do: prefix, else: "public"

    # Step 1: Create phoenix_kit_role_permissions table
    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_role_permissions (
      id BIGSERIAL PRIMARY KEY,
      uuid UUID DEFAULT gen_random_uuid(),
      role_id BIGINT NOT NULL,
      module_key VARCHAR(50) NOT NULL,
      granted_by BIGINT,
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_role_permissions_role
        FOREIGN KEY (role_id) REFERENCES #{prefix_str}phoenix_kit_user_roles(id) ON DELETE CASCADE,
      CONSTRAINT fk_role_permissions_granted_by
        FOREIGN KEY (granted_by) REFERENCES #{prefix_str}phoenix_kit_users(id) ON DELETE SET NULL,
      CONSTRAINT uq_role_permissions_role_module
        UNIQUE (role_id, module_key)
    )
    """

    # Step 2: Create indexes
    execute """
    CREATE INDEX IF NOT EXISTS idx_role_permissions_module_key
    ON #{prefix_str}phoenix_kit_role_permissions (module_key)
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_role_permissions_uuid
    ON #{prefix_str}phoenix_kit_role_permissions (uuid)
    """

    # Step 3: Seed Admin role with all permission keys
    # Owner bypasses in code, User has no admin access, so only Admin needs rows
    keys_sql = seed_admin_permissions_sql(prefix_str, schema_name)
    execute(keys_sql)

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '53'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_role_permissions CASCADE"

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '52'"
  end

  defp seed_admin_permissions_sql(prefix_str, schema_name) do
    values = Enum.map_join(@permission_keys, ", ", fn key -> "'#{key}'" end)

    """
    DO $$
    DECLARE
      admin_role_id BIGINT;
    BEGIN
      -- Only seed if the roles table exists
      IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = '#{schema_name}' AND table_name = 'phoenix_kit_user_roles') THEN
        -- Find the Admin role
        SELECT id INTO admin_role_id FROM #{prefix_str}phoenix_kit_user_roles WHERE name = 'Admin' LIMIT 1;

        IF admin_role_id IS NOT NULL THEN
          -- Insert all permission keys for Admin role (skip duplicates)
          INSERT INTO #{prefix_str}phoenix_kit_role_permissions (role_id, module_key, inserted_at)
          SELECT admin_role_id, key, NOW()
          FROM unnest(ARRAY[#{values}]) AS key
          ON CONFLICT (role_id, module_key) DO NOTHING;
        END IF;
      END IF;
    END $$;
    """
  end
end
