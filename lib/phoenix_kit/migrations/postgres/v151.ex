defmodule PhoenixKit.Migrations.Postgres.V151 do
  @moduledoc """
  V151: supplier-info source/primary columns + CRM email normalization.

  Completes the V149 `phoenix_kit_cat_item_supplier_info` junction with the
  two columns the merged `phoenix_kit_catalogue` sourcing layer (catalogue
  PR #44) reads and writes — without them every junction INSERT/UPDATE
  crashes on an undefined column:

    * `supplier_source` — `'crm_company' | 'crm_contact' | 'local'` (CHECK).
      Disambiguates the polymorphic soft `supplier_uuid` (a CRM company, a
      CRM contact, or a local `cat_suppliers` row) so the resolver and the
      `phoenix_kit_catalogue.audit_supplier_refs` consistency report route
      lookups without a trial cascade.
    * `is_primary` + partial-unique index (at most one primary row per
      item). The catalogue context auto-promotes the first linked supplier
      and offers "make primary"; `Suppliers.primary_for_item/1` backs the
      warehouse resolver.

  The V146 scalar `phoenix_kit_cat_items.primary_supplier_uuid` is left
  untouched (V149's design keeps it); the merged catalogue schema simply no
  longer maps it.

  Also normalises the CRM party email columns to `citext`
  (`phoenix_kit_crm_contacts.email`, `phoenix_kit_crm_companies.email`):
  case-insensitive matching is a prerequisite for the CRM v2 backfill
  (match-by-email) and the user↔contact bridge (`connect_user/2` finds or
  creates auth users by email). citext is a core dependency since V01
  (`phoenix_kit_users.email`), so `ensure_extension!/1` is a no-op on any
  existing install.

  **citext conversion cost:** `ALTER COLUMN … TYPE citext` takes an ACCESS
  EXCLUSIVE lock and rewrites the table — plan a maintenance window for
  large CRM tables. Neither email column carries an index or a unique
  constraint anywhere in the chain, so no index rebuild happens and no
  latent case-duplicate can surface as a violation; if a unique index on
  email is ever added later, case-variant duplicates must be resolved
  first (citext compares case-insensitively).

  All operations are idempotent.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)
    p = prefix_str(prefix)

    # ------------------------------------------------------------------
    # Block 1: supplier_source on the V149 junction
    # ------------------------------------------------------------------

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info
    ADD COLUMN IF NOT EXISTS supplier_source VARCHAR(20) NOT NULL DEFAULT 'local'
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_cat_item_supplier_info_supplier_source_check'
        AND conrelid = '#{p}phoenix_kit_cat_item_supplier_info'::regclass
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info
        ADD CONSTRAINT phoenix_kit_cat_item_supplier_info_supplier_source_check
        CHECK (supplier_source IN ('crm_company', 'crm_contact', 'local'));
      END IF;
    END $$;
    """)

    # ------------------------------------------------------------------
    # Block 2: is_primary + partial-unique (one primary per item)
    # ------------------------------------------------------------------

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info
    ADD COLUMN IF NOT EXISTS is_primary BOOLEAN NOT NULL DEFAULT FALSE
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_supplier_info_primary_uniq
    ON #{p}phoenix_kit_cat_item_supplier_info (item_uuid)
    WHERE is_primary
    """)

    # ------------------------------------------------------------------
    # Block 3: CRM email normalization to citext
    # ------------------------------------------------------------------

    # no-op when citext is already installed (avoids the privilege check on
    # bare CREATE EXTENSION IF NOT EXISTS for low-privilege roles)
    Helpers.ensure_extension!("citext")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{escaped_prefix}'
        AND table_name = 'phoenix_kit_crm_contacts'
        AND column_name = 'email'
        AND udt_name <> 'citext'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_crm_contacts
        ALTER COLUMN email TYPE citext;
      END IF;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{escaped_prefix}'
        AND table_name = 'phoenix_kit_crm_companies'
        AND column_name = 'email'
        AND udt_name <> 'citext'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_crm_companies
        ALTER COLUMN email TYPE citext;
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '151'")
  end

  @doc """
  Rolls V151 back.

  **Lossy for the two columns:** `supplier_source` values and `is_primary`
  flags are dropped (the junction rows themselves survive). CRM email
  columns revert from `citext` to `VARCHAR(255)` (their V138 shape).
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)
    p = prefix_str(prefix)

    execute("""
    DROP INDEX IF EXISTS #{p}phoenix_kit_cat_item_supplier_info_primary_uniq
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info
    DROP COLUMN IF EXISTS is_primary
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info
    DROP COLUMN IF EXISTS supplier_source
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{escaped_prefix}'
        AND table_name = 'phoenix_kit_crm_contacts'
        AND column_name = 'email'
        AND udt_name = 'citext'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_crm_contacts
        ALTER COLUMN email TYPE VARCHAR(255);
      END IF;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{escaped_prefix}'
        AND table_name = 'phoenix_kit_crm_companies'
        AND column_name = 'email'
        AND udt_name = 'citext'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_crm_companies
        ALTER COLUMN email TYPE VARCHAR(255);
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '150'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
