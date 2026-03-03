defmodule PhoenixKit.Migrations.Postgres.V74 do
  @moduledoc """
  V74: Drop integer `id`/`_id` columns, promote `uuid` to PK on Category B tables.

  V72 renamed `id` → `uuid` on 30 Category A tables. V73 fixed prerequisites
  (NOT NULL, unique indexes, dynamic PK code). V74 completes the migration by:

  1. **Drop all FK constraints** referencing `id` on `phoenix_kit_%` tables
  2. **Drop integer FK columns** across all tables (both Category A and B)
  3. **Drop bigint `id` + make `uuid` PK** on Category B tables

  After V74, every PhoenixKit table has `uuid` as its PK column. No integer
  `id` or `_id` columns remain.

  All operations are idempotent (IF EXISTS / dynamic introspection guards).
  """

  use Ecto.Migration

  # ── Integer FK columns to drop ──────────────────────────────────────
  # Comprehensive list from uuid_fk_columns.ex groups A–D plus extras.
  # These exist on both Category A and Category B tables.
  # Format: {table, column}

  @integer_fk_columns [
    # ── Group A: User FK columns (→ phoenix_kit_users.id) ──
    {"phoenix_kit_users_tokens", "user_id"},
    {"phoenix_kit_user_role_assignments", "user_id"},
    {"phoenix_kit_user_role_assignments", "assigned_by"},
    {"phoenix_kit_admin_notes", "user_id"},
    {"phoenix_kit_admin_notes", "author_id"},
    {"phoenix_kit_user_oauth_providers", "user_id"},
    {"phoenix_kit_audit_logs", "target_user_id"},
    {"phoenix_kit_audit_logs", "admin_user_id"},
    {"phoenix_kit_role_permissions", "granted_by"},
    {"phoenix_kit_comments", "user_id"},
    {"phoenix_kit_comments_likes", "user_id"},
    {"phoenix_kit_comments_dislikes", "user_id"},
    {"phoenix_kit_posts", "user_id"},
    {"phoenix_kit_post_comments", "user_id"},
    {"phoenix_kit_post_likes", "user_id"},
    {"phoenix_kit_post_dislikes", "user_id"},
    {"phoenix_kit_post_views", "user_id"},
    {"phoenix_kit_post_mentions", "user_id"},
    {"phoenix_kit_post_groups", "user_id"},
    {"phoenix_kit_comment_likes", "user_id"},
    {"phoenix_kit_comment_dislikes", "user_id"},
    {"phoenix_kit_tickets", "user_id"},
    {"phoenix_kit_tickets", "assigned_to_id"},
    {"phoenix_kit_ticket_comments", "user_id"},
    {"phoenix_kit_ticket_status_history", "changed_by_id"},
    {"phoenix_kit_user_blocks", "blocker_id"},
    {"phoenix_kit_user_blocks", "blocked_id"},
    {"phoenix_kit_user_blocks_history", "blocker_id"},
    {"phoenix_kit_user_blocks_history", "blocked_id"},
    {"phoenix_kit_user_follows", "follower_id"},
    {"phoenix_kit_user_follows", "followed_id"},
    {"phoenix_kit_user_follows_history", "follower_id"},
    {"phoenix_kit_user_follows_history", "followed_id"},
    {"phoenix_kit_user_connections", "requester_id"},
    {"phoenix_kit_user_connections", "recipient_id"},
    {"phoenix_kit_user_connections_history", "user_a_id"},
    {"phoenix_kit_user_connections_history", "user_b_id"},
    {"phoenix_kit_user_connections_history", "actor_id"},
    {"phoenix_kit_files", "user_id"},
    {"phoenix_kit_shop_carts", "user_id"},
    {"phoenix_kit_shop_products", "created_by"},
    {"phoenix_kit_shop_import_logs", "user_id"},
    {"phoenix_kit_billing_profiles", "user_id"},
    {"phoenix_kit_orders", "user_id"},
    {"phoenix_kit_invoices", "user_id"},
    {"phoenix_kit_transactions", "user_id"},
    {"phoenix_kit_subscriptions", "user_id"},
    {"phoenix_kit_payment_methods", "user_id"},
    {"phoenix_kit_ai_requests", "user_id"},
    {"phoenix_kit_sync_connections", "approved_by"},
    {"phoenix_kit_sync_connections", "suspended_by"},
    {"phoenix_kit_sync_connections", "revoked_by"},
    {"phoenix_kit_sync_connections", "created_by"},
    {"phoenix_kit_sync_transfers", "approved_by"},
    {"phoenix_kit_sync_transfers", "denied_by"},
    {"phoenix_kit_sync_transfers", "initiated_by"},
    {"phoenix_kit_entities", "created_by"},
    {"phoenix_kit_entity_data", "created_by"},
    {"phoenix_kit_email_logs", "user_id"},
    {"phoenix_kit_email_blocklist", "user_id"},
    {"phoenix_kit_email_templates", "created_by_user_id"},
    {"phoenix_kit_email_templates", "updated_by_user_id"},
    {"phoenix_kit_referral_codes", "created_by"},
    {"phoenix_kit_referral_codes", "beneficiary"},
    {"phoenix_kit_referral_code_usage", "used_by"},
    {"phoenix_kit_consent_logs", "user_id"},
    # ── Group B: Role FK columns (→ phoenix_kit_user_roles.id) ──
    {"phoenix_kit_user_role_assignments", "role_id"},
    {"phoenix_kit_role_permissions", "role_id"},
    # ── Group C: Entity FK columns (→ phoenix_kit_entities.id) ──
    {"phoenix_kit_entity_data", "entity_id"},
    # ── Group D: Module-internal FK columns ──
    {"phoenix_kit_shop_cart_items", "cart_id"},
    {"phoenix_kit_shop_cart_items", "product_id"},
    {"phoenix_kit_shop_carts", "shipping_method_id"},
    {"phoenix_kit_shop_carts", "merged_into_cart_id"},
    {"phoenix_kit_shop_carts", "payment_option_id"},
    {"phoenix_kit_shop_products", "category_id"},
    {"phoenix_kit_shop_categories", "parent_id"},
    {"phoenix_kit_shop_categories", "featured_product_id"},
    {"phoenix_kit_orders", "billing_profile_id"},
    {"phoenix_kit_invoices", "order_id"},
    {"phoenix_kit_transactions", "invoice_id"},
    {"phoenix_kit_subscriptions", "subscription_type_id"},
    {"phoenix_kit_subscriptions", "billing_profile_id"},
    {"phoenix_kit_subscriptions", "payment_method_id"},
    {"phoenix_kit_email_events", "email_log_id"},
    {"phoenix_kit_ai_requests", "endpoint_id"},
    {"phoenix_kit_ai_requests", "prompt_id"},
    {"phoenix_kit_sync_transfers", "connection_id"},
    {"phoenix_kit_referral_code_usage", "code_id"},
    # ── Extras: columns not in uuid_fk_columns.ex ──
    {"phoenix_kit_invoices", "subscription_id"},
    {"phoenix_kit_email_orphaned_events", "matched_email_log_id"},
    {"phoenix_kit_publishing_posts", "created_by_id"},
    {"phoenix_kit_publishing_posts", "updated_by_id"},
    {"phoenix_kit_publishing_versions", "created_by_id"},
    {"phoenix_kit_shop_cart_items", "variant_id"},
    {"phoenix_kit_scheduled_jobs", "created_by_id"},
    {"phoenix_kit_ai_requests", "account_id"},
    # Additional columns found in schemas but not in uuid_fk_columns.ex
    {"phoenix_kit_posts", "author_id"},
    {"phoenix_kit_tickets", "created_by_user_id"},
    {"phoenix_kit_ticket_attachments", "user_id"},
    {"phoenix_kit_transactions", "order_id"},
    {"phoenix_kit_transactions", "payment_method_id"}
  ]

  # ── Category B tables: drop bigint `id`, make `uuid` PK ────────────
  # These tables still have bigint `id` PK + separate `uuid` column.
  # Category A (30 tables) were handled by V72 (id renamed to uuid).
  # Idempotent: checks for `uuid` column existence before proceeding.

  @category_b_tables ~w(
    phoenix_kit_users
    phoenix_kit_users_tokens
    phoenix_kit_user_roles
    phoenix_kit_user_role_assignments
    phoenix_kit_role_permissions
    phoenix_kit_settings
    phoenix_kit_admin_notes
    phoenix_kit_audit_logs
    phoenix_kit_email_logs
    phoenix_kit_email_events
    phoenix_kit_email_metrics
    phoenix_kit_email_templates
    phoenix_kit_email_blocklist
    phoenix_kit_email_orphaned_events
    phoenix_kit_ai_accounts
    phoenix_kit_ai_endpoints
    phoenix_kit_ai_prompts
    phoenix_kit_ai_requests
    phoenix_kit_entities
    phoenix_kit_entity_data
    phoenix_kit_user_oauth_providers
    phoenix_kit_consent_logs
    phoenix_kit_referral_codes
    phoenix_kit_referral_code_usage
    phoenix_kit_billing_profiles
    phoenix_kit_orders
    phoenix_kit_invoices
    phoenix_kit_transactions
    phoenix_kit_payment_methods
    phoenix_kit_payment_options
    phoenix_kit_payment_provider_configs
    phoenix_kit_subscriptions
    phoenix_kit_subscription_types
    phoenix_kit_currencies
    phoenix_kit_shop_carts
    phoenix_kit_shop_cart_items
    phoenix_kit_shop_products
    phoenix_kit_shop_categories
    phoenix_kit_shop_shipping_methods
    phoenix_kit_shop_config
    phoenix_kit_shop_import_configs
    phoenix_kit_shop_import_logs
    phoenix_kit_sync_connections
    phoenix_kit_sync_transfers
    phoenix_kit_webhook_events
    phoenix_kit_publishing_posts
    phoenix_kit_publishing_versions
  )

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    # Step 1: Drop all FK constraints referencing `id` on phoenix_kit_% tables
    drop_id_fk_constraints(prefix, escaped_prefix)

    # Step 2: Drop integer FK columns
    drop_integer_fk_columns(prefix, escaped_prefix)

    # Step 3: Drop bigint `id` PK + make `uuid` PK on Category B tables
    promote_uuid_to_pk(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '74'")
  end

  def down(%{prefix: prefix} = _opts) do
    # V74 is destructive — columns and data are dropped.
    # Down migration only restores the version comment.
    # To fully reverse, restore from backup.
    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '73'")
  end

  # ---------------------------------------------------------------------------
  # Step 1: Drop all FK constraints referencing `id`
  # ---------------------------------------------------------------------------

  defp drop_id_fk_constraints(_prefix, escaped_prefix) do
    # Dynamic query: find and drop all FK constraints where the referenced
    # column is `id` on phoenix_kit_% tables.
    execute("""
    DO $$ DECLARE r RECORD; BEGIN
      FOR r IN
        SELECT tc.constraint_name, tc.table_schema, tc.table_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.constraint_column_usage ccu
          USING (constraint_schema, constraint_name)
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = '#{escaped_prefix}'
          AND ccu.table_name LIKE 'phoenix_kit_%'
          AND ccu.column_name = 'id'
      LOOP
        EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I',
                       r.table_schema, r.table_name, r.constraint_name);
      END LOOP;
    END $$;
    """)
  end

  # ---------------------------------------------------------------------------
  # Step 2: Drop integer FK columns
  # ---------------------------------------------------------------------------

  defp drop_integer_fk_columns(prefix, escaped_prefix) do
    for {table, column} <- @integer_fk_columns do
      if table_exists?(table, escaped_prefix) do
        table_name = prefix_table(table, prefix)
        execute("ALTER TABLE #{table_name} DROP COLUMN IF EXISTS #{column}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Drop bigint `id` + make `uuid` PK
  # ---------------------------------------------------------------------------

  defp promote_uuid_to_pk(prefix, escaped_prefix) do
    for table <- @category_b_tables do
      if table_exists?(table, escaped_prefix) and
           column_exists?(table, "uuid", escaped_prefix) do
        table_name = prefix_table(table, prefix)

        # Drop existing PK constraint (named {table}_pkey by convention)
        execute("ALTER TABLE #{table_name} DROP CONSTRAINT IF EXISTS #{table}_pkey")

        # Drop the bigint id column (cascade drops associated sequence)
        execute("ALTER TABLE #{table_name} DROP COLUMN IF EXISTS id")

        # Promote uuid to PK (only if not already a PK)
        execute("""
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM information_schema.table_constraints
            WHERE table_name = '#{table}'
            AND table_schema = '#{escaped_prefix}'
            AND constraint_type = 'PRIMARY KEY'
          ) THEN
            ALTER TABLE #{table_name} ADD PRIMARY KEY (uuid);
          END IF;
        END $$;
        """)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Introspection Helpers
  # ---------------------------------------------------------------------------

  defp table_exists?(table, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table}'
             AND column_name = '#{column}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
