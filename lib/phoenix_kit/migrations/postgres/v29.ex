defmodule PhoenixKit.Migrations.Postgres.V29 do
  @moduledoc """
  PhoenixKit V29 Migration: Billing System - Phase 1

  This migration introduces the core billing infrastructure including currencies,
  billing profiles, orders, and invoices. This is Phase 1 of the billing module,
  focused on manual bank transfer payments.

  ## Changes

  ### Currencies Table (phoenix_kit_currencies)
  - Multi-currency support with ISO 4217 codes
  - Exchange rates for currency conversion
  - Default currency configuration

  ### Billing Profiles Table (phoenix_kit_billing_profiles)
  - User billing information storage
  - Support for individuals and companies (EU Standard)
  - VAT number and company registration for B2B
  - Billing address management

  ### Orders Table (phoenix_kit_orders)
  - Order management with line items (JSONB)
  - Status tracking (draft, pending, confirmed, paid, cancelled, refunded)
  - Multi-currency support
  - Billing snapshot at order time

  ### Invoices Table (phoenix_kit_invoices)
  - Invoice generation from orders
  - Status tracking (draft, sent, paid, void, overdue)
  - Receipt functionality integrated
  - Bank details for payment

  ### Settings Seeds
  - Billing module enable/disable
  - Default currency and tax settings
  - Invoice/order number prefixes

  ## PostgreSQL Support
  - Leverages PostgreSQL's native JSONB for flexible data
  - Decimal precision for financial calculations
  - Supports prefix for schema isolation
  - Optimized indexes for common queries
  """
  use Ecto.Migration

  @doc """
  Run the V29 migration to add the billing system.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===========================================
    # 1. CURRENCIES TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_currencies, prefix: prefix) do
      add :code, :string, size: 3, null: false
      add :name, :string, null: false
      add :symbol, :string, size: 5, null: false
      add :decimal_places, :integer, null: false, default: 2
      add :is_default, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :exchange_rate, :decimal, precision: 15, scale: 6, null: false, default: 1
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:phoenix_kit_currencies, [:code],
                           name: :phoenix_kit_currencies_code_uidx,
                           prefix: prefix
                         )

    # Seed default currencies
    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_currencies", prefix)}
      (code, name, symbol, decimal_places, is_default, enabled, exchange_rate, sort_order, inserted_at, updated_at)
    VALUES
      ('EUR', 'Euro', '€', 2, true, true, 1.000000, 1, NOW(), NOW()),
      ('USD', 'US Dollar', '$', 2, false, true, 1.100000, 2, NOW(), NOW()),
      ('GBP', 'British Pound', '£', 2, false, true, 0.850000, 3, NOW(), NOW())
    ON CONFLICT (code) DO NOTHING
    """

    # ===========================================
    # 2. BILLING PROFILES TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_billing_profiles, prefix: prefix) do
      add :user_id, :integer, null: false
      add :type, :string, size: 20, null: false, default: "individual"
      add :is_default, :boolean, null: false, default: false
      add :name, :string

      # Individual fields
      add :first_name, :string
      add :last_name, :string
      add :middle_name, :string
      add :phone, :string
      add :email, :string

      # Company fields (EU Standard)
      add :company_name, :string
      add :company_vat_number, :string, size: 20
      add :company_registration_number, :string, size: 30
      add :company_legal_address, :text

      # Billing Address
      add :address_line1, :string
      add :address_line2, :string
      add :city, :string
      add :state, :string
      add :postal_code, :string, size: 20
      add :country, :string, size: 2, default: "EE"

      add :metadata, :map, null: true, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:phoenix_kit_billing_profiles, [:user_id],
                           name: :phoenix_kit_billing_profiles_user_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_billing_profiles, [:user_id, :is_default],
                           name: :phoenix_kit_billing_profiles_user_default_idx,
                           prefix: prefix
                         )

    # Add foreign key to users
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_billing_profiles_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_billing_profiles", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_billing_profiles", prefix)}
        ADD CONSTRAINT phoenix_kit_billing_profiles_user_id_fkey
        FOREIGN KEY (user_id)
        REFERENCES #{prefix_table_name("phoenix_kit_users", prefix)}(id)
        ON DELETE CASCADE;
      END IF;
    END $$;
    """

    # ===========================================
    # 3. ORDERS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_orders, prefix: prefix) do
      add :user_id, :integer, null: false
      add :billing_profile_id, :integer, null: true
      add :order_number, :string, size: 30, null: false
      add :status, :string, size: 20, null: false, default: "draft"

      # Payment method (Phase 1: only bank)
      add :payment_method, :string, size: 20, null: false, default: "bank"

      # Line items (JSONB array)
      add :line_items, :map, null: false, default: "[]"

      # Financial amounts
      add :subtotal, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :tax_amount, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :tax_rate, :decimal, precision: 5, scale: 4, null: false, default: 0
      add :discount_amount, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :discount_code, :string, size: 50
      add :total, :decimal, precision: 15, scale: 2, null: false
      add :currency, :string, size: 3, null: false, default: "EUR"

      # Billing snapshot at order time
      add :billing_snapshot, :map, null: true, default: %{}

      # Notes
      add :notes, :text
      add :internal_notes, :text

      add :metadata, :map, null: true, default: %{}

      # Timestamps
      add :confirmed_at, :utc_datetime_usec
      add :paid_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:phoenix_kit_orders, [:order_number],
                           name: :phoenix_kit_orders_order_number_uidx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_orders, [:user_id],
                           name: :phoenix_kit_orders_user_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_orders, [:status],
                           name: :phoenix_kit_orders_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_orders, [:inserted_at],
                           name: :phoenix_kit_orders_inserted_at_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_orders, [:billing_profile_id],
                           name: :phoenix_kit_orders_billing_profile_id_idx,
                           prefix: prefix
                         )

    # Add foreign keys for orders
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_orders_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_orders", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_orders", prefix)}
        ADD CONSTRAINT phoenix_kit_orders_user_id_fkey
        FOREIGN KEY (user_id)
        REFERENCES #{prefix_table_name("phoenix_kit_users", prefix)}(id)
        ON DELETE RESTRICT;
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_orders_billing_profile_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_orders", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_orders", prefix)}
        ADD CONSTRAINT phoenix_kit_orders_billing_profile_id_fkey
        FOREIGN KEY (billing_profile_id)
        REFERENCES #{prefix_table_name("phoenix_kit_billing_profiles", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """

    # ===========================================
    # 4. INVOICES TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_invoices, prefix: prefix) do
      add :user_id, :integer, null: false
      add :order_id, :integer, null: true
      add :invoice_number, :string, size: 30, null: false
      add :status, :string, size: 20, null: false, default: "draft"

      # Financial amounts
      add :subtotal, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :tax_amount, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :tax_rate, :decimal, precision: 5, scale: 4, null: false, default: 0
      add :total, :decimal, precision: 15, scale: 2, null: false
      add :currency, :string, size: 3, null: false, default: "EUR"
      add :due_date, :date

      # Full billing snapshot
      add :billing_details, :map, null: true, default: %{}
      add :line_items, :map, null: false, default: "[]"
      add :payment_terms, :string
      add :bank_details, :map, null: true, default: %{}
      add :notes, :text

      add :metadata, :map, null: true, default: %{}

      # Receipt (integrated into invoice)
      add :receipt_number, :string, size: 30
      add :receipt_generated_at, :utc_datetime_usec
      add :receipt_data, :map, null: true, default: %{}

      # Timestamps
      add :sent_at, :utc_datetime_usec
      add :paid_at, :utc_datetime_usec
      add :voided_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:phoenix_kit_invoices, [:invoice_number],
                           name: :phoenix_kit_invoices_invoice_number_uidx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_invoices, [:user_id],
                           name: :phoenix_kit_invoices_user_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_invoices, [:order_id],
                           name: :phoenix_kit_invoices_order_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_invoices, [:status],
                           name: :phoenix_kit_invoices_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_invoices, [:due_date],
                           name: :phoenix_kit_invoices_due_date_idx,
                           prefix: prefix
                         )

    # Add foreign keys for invoices
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_invoices_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_invoices", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_invoices", prefix)}
        ADD CONSTRAINT phoenix_kit_invoices_user_id_fkey
        FOREIGN KEY (user_id)
        REFERENCES #{prefix_table_name("phoenix_kit_users", prefix)}(id)
        ON DELETE RESTRICT;
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_invoices_order_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_invoices", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_invoices", prefix)}
        ADD CONSTRAINT phoenix_kit_invoices_order_id_fkey
        FOREIGN KEY (order_id)
        REFERENCES #{prefix_table_name("phoenix_kit_orders", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    END $$;
    """

    # ===========================================
    # 5. BILLING SETTINGS
    # ===========================================
    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)} (key, value, module, date_added, date_updated)
    VALUES
      ('billing_enabled', 'false', 'billing', NOW(), NOW()),
      ('billing_default_currency', 'EUR', 'billing', NOW(), NOW()),
      ('billing_tax_enabled', 'false', 'billing', NOW(), NOW()),
      ('billing_default_tax_rate', '0', 'billing', NOW(), NOW()),
      ('billing_invoice_prefix', 'INV', 'billing', NOW(), NOW()),
      ('billing_order_prefix', 'ORD', 'billing', NOW(), NOW()),
      ('billing_receipt_prefix', 'RCP', 'billing', NOW(), NOW()),
      ('billing_invoice_due_days', '14', 'billing', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    # ===========================================
    # 6. TABLE COMMENTS
    # ===========================================
    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_currencies", prefix)} IS
    'Supported currencies for billing with exchange rates'
    """

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_billing_profiles", prefix)} IS
    'User billing information for individuals and companies (EU Standard)'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_billing_profiles", prefix)}.type IS
    'Profile type: individual or company'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_billing_profiles", prefix)}.company_vat_number IS
    'EU VAT Number (e.g., EE123456789)'
    """

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_orders", prefix)} IS
    'Orders with line items, amounts, and billing information'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_orders", prefix)}.line_items IS
    'JSONB array of line items: [{name, description, quantity, unit_price, total}]'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_orders", prefix)}.billing_snapshot IS
    'Snapshot of billing profile at order creation time'
    """

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_invoices", prefix)} IS
    'Invoices generated from orders with receipt functionality'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_invoices", prefix)}.bank_details IS
    'Bank account details for payment (IBAN, SWIFT, bank name)'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_invoices", prefix)}.receipt_data IS
    'Receipt information after payment (PDF URL, download count, etc.)'
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '29'"

    # Seed billing_invoice email template
    flush()
    seed_billing_invoice_template()
  end

  @doc """
  Rollback the V29 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop foreign keys first
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_invoices_order_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_invoices", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_invoices", prefix)}
        DROP CONSTRAINT phoenix_kit_invoices_order_id_fkey;
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_invoices_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_invoices", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_invoices", prefix)}
        DROP CONSTRAINT phoenix_kit_invoices_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_orders_billing_profile_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_orders", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_orders", prefix)}
        DROP CONSTRAINT phoenix_kit_orders_billing_profile_id_fkey;
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_orders_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_orders", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_orders", prefix)}
        DROP CONSTRAINT phoenix_kit_orders_user_id_fkey;
      END IF;
    END $$;
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_billing_profiles_user_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_billing_profiles", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_billing_profiles", prefix)}
        DROP CONSTRAINT phoenix_kit_billing_profiles_user_id_fkey;
      END IF;
    END $$;
    """

    # Drop indexes and tables in reverse order
    drop_if_exists index(:phoenix_kit_invoices, [:due_date],
                     name: :phoenix_kit_invoices_due_date_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_invoices, [:status],
                     name: :phoenix_kit_invoices_status_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_invoices, [:order_id],
                     name: :phoenix_kit_invoices_order_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_invoices, [:user_id],
                     name: :phoenix_kit_invoices_user_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_invoices, [:invoice_number],
                     name: :phoenix_kit_invoices_invoice_number_uidx,
                     prefix: prefix
                   )

    drop_if_exists table(:phoenix_kit_invoices, prefix: prefix)

    drop_if_exists index(:phoenix_kit_orders, [:billing_profile_id],
                     name: :phoenix_kit_orders_billing_profile_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_orders, [:inserted_at],
                     name: :phoenix_kit_orders_inserted_at_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_orders, [:status],
                     name: :phoenix_kit_orders_status_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_orders, [:user_id],
                     name: :phoenix_kit_orders_user_id_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_orders, [:order_number],
                     name: :phoenix_kit_orders_order_number_uidx,
                     prefix: prefix
                   )

    drop_if_exists table(:phoenix_kit_orders, prefix: prefix)

    drop_if_exists index(:phoenix_kit_billing_profiles, [:user_id, :is_default],
                     name: :phoenix_kit_billing_profiles_user_default_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_billing_profiles, [:user_id],
                     name: :phoenix_kit_billing_profiles_user_id_idx,
                     prefix: prefix
                   )

    drop_if_exists table(:phoenix_kit_billing_profiles, prefix: prefix)

    drop_if_exists index(:phoenix_kit_currencies, [:code],
                     name: :phoenix_kit_currencies_code_uidx,
                     prefix: prefix
                   )

    drop_if_exists table(:phoenix_kit_currencies, prefix: prefix)

    # Remove billing settings
    execute """
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key IN (
      'billing_enabled',
      'billing_default_currency',
      'billing_tax_enabled',
      'billing_default_tax_rate',
      'billing_invoice_prefix',
      'billing_order_prefix',
      'billing_receipt_prefix',
      'billing_invoice_due_days'
    )
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '28'"
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  # Seed the billing_invoice email template if it doesn't exist
  defp seed_billing_invoice_template do
    alias PhoenixKit.Emails.Templates

    case Code.ensure_loaded(Templates) do
      {:module, _} ->
        try do
          # Check if billing_invoice template already exists
          case Templates.get_template_by_name("billing_invoice") do
            nil ->
              # Template doesn't exist, run seed to create all missing system templates
              Templates.seed_system_templates()
              :ok

            _template ->
              # Template already exists
              :ok
          end
        rescue
          _ -> :ok
        end

      _ ->
        :ok
    end
  end
end
