defmodule PhoenixKit.Migrations.Postgres.V51 do
  @moduledoc """
  V51: Cart items unique constraint fix + User deletion FK constraints

  ## Part 1: Cart Items Unique Constraint
  The original constraint only checked (cart_id, product_id), preventing
  users from adding the same product with different options to their cart.

  New constraint uses MD5 hash of selected_specs JSONB for efficient
  unique checking across all option combinations.

  ## Part 2: User Deletion Foreign Key Constraints
  Changes ON DELETE behavior for user-related tables to support GDPR
  compliance - preserve financial/support records while allowing user deletion.

  ## Changes

  - Drops existing idx_shop_cart_items_unique index
  - Creates new unique index including MD5 hash of selected_specs
  - orders.user_id: RESTRICT → SET NULL (preserve orders, anonymize user)
  - billing_profiles.user_id: CASCADE → SET NULL (preserve for history)
  - tickets.user_id: DELETE_ALL → SET NULL (preserve support history)
  - orders.user_id: DROP NOT NULL constraint
  - billing_profiles.user_id: DROP NOT NULL constraint
  - tickets.user_id: DROP NOT NULL constraint
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Drop old index that doesn't include selected_specs
    execute """
    DROP INDEX IF EXISTS #{prefix_str}idx_shop_cart_items_unique
    """

    # Create new index that includes selected_specs via MD5 hash
    # MD5 provides consistent hashing of JSONB for unique comparison
    execute """
    CREATE UNIQUE INDEX idx_shop_cart_items_unique
    ON #{prefix_str}phoenix_kit_shop_cart_items(
      cart_id,
      product_id,
      MD5(COALESCE(selected_specs::text, '{}'))
    )
    WHERE variant_id IS NULL
    """

    # ===========================================
    # Part 2: Fix User Deletion Foreign Key Constraints
    # ===========================================

    # 2.1 ORDERS: RESTRICT → SET NULL
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_orders_user_id_fkey'
        AND conrelid = '#{prefix_str}phoenix_kit_orders'::regclass
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_orders
        DROP CONSTRAINT phoenix_kit_orders_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_orders
    ADD CONSTRAINT phoenix_kit_orders_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES #{prefix_str}phoenix_kit_users(id)
    ON DELETE SET NULL;
    """

    # 2.2 BILLING PROFILES: CASCADE → SET NULL
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_billing_profiles_user_id_fkey'
        AND conrelid = '#{prefix_str}phoenix_kit_billing_profiles'::regclass
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_billing_profiles
        DROP CONSTRAINT phoenix_kit_billing_profiles_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_billing_profiles
    ADD CONSTRAINT phoenix_kit_billing_profiles_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES #{prefix_str}phoenix_kit_users(id)
    ON DELETE SET NULL;
    """

    # 2.3 TICKETS: DELETE_ALL → SET NULL
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_tickets_user_id_fkey'
        AND conrelid = '#{prefix_str}phoenix_kit_tickets'::regclass
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_tickets
        DROP CONSTRAINT phoenix_kit_tickets_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_tickets
    ADD CONSTRAINT phoenix_kit_tickets_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES #{prefix_str}phoenix_kit_users(id)
    ON DELETE SET NULL;
    """

    # 2.4 Allow NULL values for user_id columns (required for SET NULL to work)
    execute "ALTER TABLE #{prefix_str}phoenix_kit_orders ALTER COLUMN user_id DROP NOT NULL"

    execute "ALTER TABLE #{prefix_str}phoenix_kit_billing_profiles ALTER COLUMN user_id DROP NOT NULL"

    execute "ALTER TABLE #{prefix_str}phoenix_kit_tickets ALTER COLUMN user_id DROP NOT NULL"

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '51'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # ===========================================
    # Revert FK Constraints
    # ===========================================

    # Revert ORDERS: SET NULL → RESTRICT
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_orders_user_id_fkey'
        AND conrelid = '#{prefix_str}phoenix_kit_orders'::regclass
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_orders
        DROP CONSTRAINT phoenix_kit_orders_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_orders
    ADD CONSTRAINT phoenix_kit_orders_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES #{prefix_str}phoenix_kit_users(id)
    ON DELETE RESTRICT;
    """

    # Revert BILLING PROFILES: SET NULL → CASCADE
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_billing_profiles_user_id_fkey'
        AND conrelid = '#{prefix_str}phoenix_kit_billing_profiles'::regclass
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_billing_profiles
        DROP CONSTRAINT phoenix_kit_billing_profiles_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_billing_profiles
    ADD CONSTRAINT phoenix_kit_billing_profiles_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES #{prefix_str}phoenix_kit_users(id)
    ON DELETE CASCADE;
    """

    # Revert TICKETS: SET NULL → CASCADE
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_tickets_user_id_fkey'
        AND conrelid = '#{prefix_str}phoenix_kit_tickets'::regclass
      ) THEN
        ALTER TABLE #{prefix_str}phoenix_kit_tickets
        DROP CONSTRAINT phoenix_kit_tickets_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_tickets
    ADD CONSTRAINT phoenix_kit_tickets_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES #{prefix_str}phoenix_kit_users(id)
    ON DELETE CASCADE;
    """

    # Restore NOT NULL constraints ( Note: will fail if NULL values exist )
    execute "ALTER TABLE #{prefix_str}phoenix_kit_orders ALTER COLUMN user_id SET NOT NULL"

    execute "ALTER TABLE #{prefix_str}phoenix_kit_billing_profiles ALTER COLUMN user_id SET NOT NULL"

    execute "ALTER TABLE #{prefix_str}phoenix_kit_tickets ALTER COLUMN user_id SET NOT NULL"

    # ===========================================
    # Revert Cart Items Index
    # ===========================================

    # Restore original index (will fail if duplicate cart_id+product_id exist)
    execute """
    DROP INDEX IF EXISTS #{prefix_str}idx_shop_cart_items_unique
    """

    execute """
    CREATE UNIQUE INDEX idx_shop_cart_items_unique
    ON #{prefix_str}phoenix_kit_shop_cart_items(cart_id, product_id)
    WHERE variant_id IS NULL
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '50'"
  end
end
