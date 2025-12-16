defmodule PhoenixKit.Migrations.Postgres.V33 do
  @moduledoc """
  PhoenixKit V33 Migration: Payment Providers and Subscriptions

  This migration introduces payment provider integrations (Stripe, PayPal, Razorpay)
  and the subscription system with internal billing control.

  ## Design Philosophy

  PhoenixKit uses **Internal Subscription Control** - subscriptions are managed
  in our database as the source of truth, not by payment providers. This approach:
  - Allows using providers without subscription API support
  - Gives full control over subscription lifecycle
  - Enables pause, resume, proration calculations
  - Supports multiple providers for the same subscription

  ## Changes

  ### Payment Methods Table (phoenix_kit_payment_methods)
  - Saved payment methods (cards, wallets) for recurring billing
  - Tokenized data from providers (no raw card data stored)
  - Display info for user (last4, brand, expiration)

  ### Subscription Plans Table (phoenix_kit_subscription_plans)
  - Subscription pricing plans
  - Interval configuration (day/week/month/year)
  - Trial period support
  - Feature list (JSONB)

  ### Subscriptions Table (phoenix_kit_subscriptions)
  - User subscriptions (master record)
  - Status tracking with grace period and dunning
  - Billing cycle management
  - Payment method association

  ### Payment Provider Configs Table (phoenix_kit_payment_provider_configs)
  - Provider credentials (encrypted)
  - Webhook secrets
  - Test/Live mode configuration

  ### Webhook Events Table (phoenix_kit_webhook_events)
  - Webhook event logging for idempotency
  - Event processing status tracking
  - Retry count for failed events

  ### Modifications to Existing Tables
  - Orders: checkout session fields
  - Invoices: subscription reference

  ### Settings Seeds
  - Provider enable/disable settings
  - Subscription grace period configuration
  - Dunning retry configuration
  """
  use Ecto.Migration

  @doc """
  Run the V33 migration to add payment providers and subscriptions.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===========================================
    # 1. PAYMENT METHODS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_payment_methods, prefix: prefix) do
      add :user_id, :integer, null: false
      add :provider, :string, size: 20, null: false
      add :provider_payment_method_id, :string, null: false
      add :provider_customer_id, :string

      # Payment method type
      add :type, :string, size: 20, null: false, default: "card"
      add :brand, :string, size: 20
      add :last4, :string, size: 4
      add :exp_month, :integer
      add :exp_year, :integer

      # Display name for user
      add :display_name, :string

      # Status
      add :is_default, :boolean, null: false, default: false
      add :status, :string, size: 20, null: false, default: "active"

      # Additional data
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:phoenix_kit_payment_methods, [:user_id],
                           name: :phoenix_kit_payment_methods_user_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_payment_methods, [:user_id, :is_default],
                           name: :phoenix_kit_payment_methods_user_default_idx,
                           prefix: prefix
                         )

    create_if_not_exists unique_index(
                           :phoenix_kit_payment_methods,
                           [:provider, :provider_payment_method_id],
                           name: :phoenix_kit_payment_methods_provider_id_uidx,
                           prefix: prefix
                         )

    # ===========================================
    # 2. SUBSCRIPTION PLANS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_subscription_plans, prefix: prefix) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text

      # Pricing
      add :price, :decimal, precision: 15, scale: 2, null: false
      add :currency, :string, size: 3, null: false, default: "EUR"

      # Billing interval
      add :interval, :string, size: 10, null: false, default: "month"
      add :interval_count, :integer, null: false, default: 1

      # Trial
      add :trial_days, :integer, null: false, default: 0

      # Features (JSONB array)
      add :features, {:array, :map}, null: false, default: []

      # Status
      add :active, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0

      # Additional data
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:phoenix_kit_subscription_plans, [:slug],
                           name: :phoenix_kit_subscription_plans_slug_uidx,
                           prefix: prefix
                         )

    # ===========================================
    # 3. SUBSCRIPTIONS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_subscriptions, prefix: prefix) do
      add :user_id, :integer, null: false
      add :billing_profile_id, :integer
      add :payment_method_id, :integer
      add :plan_id, :integer, null: false
      add :plan_name, :string, null: false

      # Provider info (for tracking, not control)
      add :provider, :string, size: 20
      add :provider_subscription_id, :string

      # Status
      add :status, :string, size: 20, null: false, default: "active"

      # Billing period
      add :current_period_start, :utc_datetime_usec, null: false
      add :current_period_end, :utc_datetime_usec, null: false

      # Cancellation
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :cancelled_at, :utc_datetime_usec

      # Trial
      add :trial_start, :utc_datetime_usec
      add :trial_end, :utc_datetime_usec

      # Dunning (failed payment handling)
      add :grace_period_end, :utc_datetime_usec
      add :renewal_attempts, :integer, null: false, default: 0
      add :last_renewal_attempt_at, :utc_datetime_usec
      add :last_renewal_error, :string

      # Pricing at subscription time
      add :price, :decimal, precision: 15, scale: 2, null: false
      add :currency, :string, size: 3, null: false, default: "EUR"

      # Additional data
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:phoenix_kit_subscriptions, [:user_id],
                           name: :phoenix_kit_subscriptions_user_id_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_subscriptions, [:status],
                           name: :phoenix_kit_subscriptions_status_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_subscriptions, [:current_period_end],
                           name: :phoenix_kit_subscriptions_period_end_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_subscriptions, [:provider, :provider_subscription_id],
                           name: :phoenix_kit_subscriptions_provider_idx,
                           prefix: prefix
                         )

    # ===========================================
    # 4. PAYMENT PROVIDER CONFIGS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_payment_provider_configs, prefix: prefix) do
      add :provider, :string, size: 20, null: false

      # Status
      add :enabled, :boolean, null: false, default: false
      add :mode, :string, size: 10, null: false, default: "test"

      # Credentials (should be encrypted in app layer)
      add :api_key, :text
      add :api_secret, :text
      add :webhook_secret, :text

      # Auto-generated webhook URL (for display)
      add :webhook_url, :string

      # Verification
      add :last_verified_at, :utc_datetime_usec
      add :verification_status, :string, size: 20, default: "pending"
      add :verification_error, :text

      # Additional config (JSONB)
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:phoenix_kit_payment_provider_configs, [:provider],
                           name: :phoenix_kit_payment_provider_configs_provider_uidx,
                           prefix: prefix
                         )

    # ===========================================
    # 5. WEBHOOK EVENTS TABLE (for idempotency)
    # ===========================================
    create_if_not_exists table(:phoenix_kit_webhook_events, prefix: prefix) do
      add :provider, :string, size: 20, null: false
      add :event_id, :string, null: false
      add :event_type, :string, null: false

      # Payload
      add :payload, :map, null: false, default: %{}

      # Processing status
      add :processed, :boolean, null: false, default: false
      add :processed_at, :utc_datetime_usec
      add :error_message, :text
      add :retry_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:phoenix_kit_webhook_events, [:provider, :event_id],
                           name: :phoenix_kit_webhook_events_provider_event_uidx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_webhook_events, [:processed],
                           name: :phoenix_kit_webhook_events_processed_idx,
                           prefix: prefix
                         )

    # ===========================================
    # 6. MODIFY ORDERS TABLE - Add checkout fields
    # ===========================================
    alter table(:phoenix_kit_orders, prefix: prefix) do
      add_if_not_exists :checkout_session_id, :string
      add_if_not_exists :checkout_url, :text
      add_if_not_exists :checkout_expires_at, :utc_datetime_usec
    end

    # ===========================================
    # 7. MODIFY INVOICES TABLE - Add subscription reference
    # ===========================================
    alter table(:phoenix_kit_invoices, prefix: prefix) do
      add_if_not_exists :subscription_id, :integer
    end

    create_if_not_exists index(:phoenix_kit_invoices, [:subscription_id],
                           name: :phoenix_kit_invoices_subscription_id_idx,
                           prefix: prefix
                         )

    # ===========================================
    # 8. SEED SETTINGS
    # ===========================================
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    settings = [
      {"billing_stripe_enabled", "false"},
      {"billing_paypal_enabled", "false"},
      {"billing_razorpay_enabled", "false"},
      {"billing_subscription_grace_days", "3"},
      {"billing_dunning_max_attempts", "3"},
      {"billing_dunning_retry_days", "3"}
    ]

    for {key, value} <- settings do
      execute """
      INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)} (key, value, module, date_added, date_updated)
      VALUES ('#{key}', '#{value}', 'billing', '#{now}', '#{now}')
      ON CONFLICT (key) DO NOTHING
      """
    end

    # ===========================================
    # 9. UPDATE VERSION
    # ===========================================
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '33'"
  end

  @doc """
  Rollback the V33 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Remove settings
    settings_keys = [
      "billing_stripe_enabled",
      "billing_paypal_enabled",
      "billing_razorpay_enabled",
      "billing_subscription_grace_days",
      "billing_dunning_max_attempts",
      "billing_dunning_retry_days"
    ]

    for key <- settings_keys do
      execute """
      DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
      WHERE key = '#{key}'
      """
    end

    # Remove index from invoices
    drop_if_exists index(:phoenix_kit_invoices, [:subscription_id],
                     name: :phoenix_kit_invoices_subscription_id_idx,
                     prefix: prefix
                   )

    # Remove columns from invoices
    alter table(:phoenix_kit_invoices, prefix: prefix) do
      remove_if_exists :subscription_id, :integer
    end

    # Remove columns from orders
    alter table(:phoenix_kit_orders, prefix: prefix) do
      remove_if_exists :checkout_session_id, :string
      remove_if_exists :checkout_url, :text
      remove_if_exists :checkout_expires_at, :utc_datetime_usec
    end

    # Drop webhook events table
    drop_if_exists table(:phoenix_kit_webhook_events, prefix: prefix)

    # Drop provider configs table
    drop_if_exists table(:phoenix_kit_payment_provider_configs, prefix: prefix)

    # Drop subscriptions table
    drop_if_exists table(:phoenix_kit_subscriptions, prefix: prefix)

    # Drop subscription plans table
    drop_if_exists table(:phoenix_kit_subscription_plans, prefix: prefix)

    # Drop payment methods table
    drop_if_exists table(:phoenix_kit_payment_methods, prefix: prefix)

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '32'"
  end

  # Helper to build prefixed table name
  defp prefix_table_name(table, nil), do: table
  defp prefix_table_name(table, "public"), do: table
  defp prefix_table_name(table, prefix), do: "#{prefix}.#{table}"
end
