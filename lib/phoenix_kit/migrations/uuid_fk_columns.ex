defmodule PhoenixKit.Migrations.UUIDFKColumns do
  @moduledoc """
  Adds UUID FK columns alongside integer FKs across PhoenixKit tables.

  Called from V56 migration. This helper module keeps V56 manageable by
  extracting the UUID FK column creation logic (~80 columns across ~40 tables).

  ## How It Works

  For each FK column, three operations:
  1. `ALTER TABLE ... ADD COLUMN IF NOT EXISTS {uuid_fk} UUID`
  2. Backfill via JOIN: `UPDATE t SET {uuid_fk} = s.uuid FROM source s WHERE s.id = t.{int_fk}`
  3. `CREATE INDEX IF NOT EXISTS ... ON table({uuid_fk})`

  Large tables use batched backfills (PL/pgSQL DO block, 10k rows/batch)
  to avoid long-running transactions.

  After columns are created and backfilled, `add_constraints/1` adds:
  - NOT NULL constraints where the integer FK is NOT NULL
  - FK constraints where the integer FK has an explicit DB-level FK constraint

  ## Safety

  - All operations wrapped in `table_exists?` + `column_exists?` checks
  - FK constraint creation uses `pg_constraint` existence check (idempotent)
  - NOT NULL uses `ALTER COLUMN SET NOT NULL` (idempotent in PostgreSQL)
  - Idempotent — safe to run multiple times
  """

  use Ecto.Migration

  @batch_size 10_000

  # ── Group A: FK columns → phoenix_kit_users.uuid ──────────────────────

  @user_fk_columns [
    # Core
    {:phoenix_kit_users_tokens, "user_id", "user_uuid"},
    {:phoenix_kit_user_role_assignments, "user_id", "user_uuid"},
    {:phoenix_kit_user_role_assignments, "assigned_by", "assigned_by_uuid"},
    {:phoenix_kit_admin_notes, "user_id", "user_uuid"},
    {:phoenix_kit_admin_notes, "author_id", "author_uuid"},
    {:phoenix_kit_user_oauth_providers, "user_id", "user_uuid"},
    {:phoenix_kit_audit_logs, "target_user_id", "target_user_uuid"},
    {:phoenix_kit_audit_logs, "admin_user_id", "admin_user_uuid"},
    {:phoenix_kit_role_permissions, "granted_by", "granted_by_uuid"},
    # Comments module (standalone)
    {:phoenix_kit_comments, "user_id", "user_uuid"},
    {:phoenix_kit_comments_likes, "user_id", "user_uuid"},
    {:phoenix_kit_comments_dislikes, "user_id", "user_uuid"},
    # Posts module
    {:phoenix_kit_posts, "user_id", "user_uuid"},
    {:phoenix_kit_post_comments, "user_id", "user_uuid"},
    {:phoenix_kit_post_likes, "user_id", "user_uuid"},
    {:phoenix_kit_post_dislikes, "user_id", "user_uuid"},
    {:phoenix_kit_post_views, "user_id", "user_uuid"},
    {:phoenix_kit_post_mentions, "user_id", "user_uuid"},
    {:phoenix_kit_post_groups, "user_id", "user_uuid"},
    {:phoenix_kit_comment_likes, "user_id", "user_uuid"},
    {:phoenix_kit_comment_dislikes, "user_id", "user_uuid"},
    # Tickets module
    {:phoenix_kit_tickets, "user_id", "user_uuid"},
    {:phoenix_kit_tickets, "assigned_to_id", "assigned_to_uuid"},
    {:phoenix_kit_ticket_comments, "user_id", "user_uuid"},
    {:phoenix_kit_ticket_status_history, "changed_by_id", "changed_by_uuid"},
    # Connections module
    {:phoenix_kit_user_blocks, "blocker_id", "blocker_uuid"},
    {:phoenix_kit_user_blocks, "blocked_id", "blocked_uuid"},
    {:phoenix_kit_user_blocks_history, "blocker_id", "blocker_uuid"},
    {:phoenix_kit_user_blocks_history, "blocked_id", "blocked_uuid"},
    {:phoenix_kit_user_follows, "follower_id", "follower_uuid"},
    {:phoenix_kit_user_follows, "followed_id", "followed_uuid"},
    {:phoenix_kit_user_follows_history, "follower_id", "follower_uuid"},
    {:phoenix_kit_user_follows_history, "followed_id", "followed_uuid"},
    {:phoenix_kit_user_connections, "requester_id", "requester_uuid"},
    {:phoenix_kit_user_connections, "recipient_id", "recipient_uuid"},
    {:phoenix_kit_user_connections_history, "user_a_id", "user_a_uuid"},
    {:phoenix_kit_user_connections_history, "user_b_id", "user_b_uuid"},
    {:phoenix_kit_user_connections_history, "actor_id", "actor_uuid"},
    # Storage module
    {:phoenix_kit_files, "user_id", "user_uuid"},
    # Shop module
    {:phoenix_kit_shop_carts, "user_id", "user_uuid"},
    {:phoenix_kit_shop_products, "created_by", "created_by_uuid"},
    {:phoenix_kit_shop_import_logs, "user_id", "user_uuid"},
    # Billing module
    {:phoenix_kit_billing_profiles, "user_id", "user_uuid"},
    {:phoenix_kit_orders, "user_id", "user_uuid"},
    {:phoenix_kit_invoices, "user_id", "user_uuid"},
    {:phoenix_kit_transactions, "user_id", "user_uuid"},
    {:phoenix_kit_subscriptions, "user_id", "user_uuid"},
    {:phoenix_kit_payment_methods, "user_id", "user_uuid"},
    # AI module
    {:phoenix_kit_ai_requests, "user_id", "user_uuid"},
    # Sync module
    {:phoenix_kit_sync_connections, "approved_by", "approved_by_uuid"},
    {:phoenix_kit_sync_connections, "suspended_by", "suspended_by_uuid"},
    {:phoenix_kit_sync_connections, "revoked_by", "revoked_by_uuid"},
    {:phoenix_kit_sync_connections, "created_by", "created_by_uuid"},
    {:phoenix_kit_sync_transfers, "approved_by", "approved_by_uuid"},
    {:phoenix_kit_sync_transfers, "denied_by", "denied_by_uuid"},
    {:phoenix_kit_sync_transfers, "initiated_by", "initiated_by_uuid"},
    # Entities module
    {:phoenix_kit_entities, "created_by", "created_by_uuid"},
    {:phoenix_kit_entity_data, "created_by", "created_by_uuid"},
    # Emails module
    {:phoenix_kit_email_logs, "user_id", "user_uuid"},
    {:phoenix_kit_email_blocklist, "user_id", "user_uuid"},
    {:phoenix_kit_email_templates, "created_by_user_id", "created_by_user_uuid"},
    {:phoenix_kit_email_templates, "updated_by_user_id", "updated_by_user_uuid"},
    # Referrals module
    {:phoenix_kit_referral_codes, "created_by", "created_by_uuid"},
    {:phoenix_kit_referral_codes, "beneficiary", "beneficiary_uuid"},
    {:phoenix_kit_referral_code_usage, "used_by", "used_by_uuid"},
    # Legal module
    {:phoenix_kit_consent_logs, "user_id", "user_uuid"}
  ]

  # ── Group B: FK columns → phoenix_kit_user_roles.uuid ─────────────────

  @role_fk_columns [
    {:phoenix_kit_user_role_assignments, "role_id", "role_uuid"},
    {:phoenix_kit_role_permissions, "role_id", "role_uuid"}
  ]

  # ── Group C: FK columns → phoenix_kit_entities.uuid ───────────────────

  @entity_fk_columns [
    {:phoenix_kit_entity_data, "entity_id", "entity_uuid"}
  ]

  # ── Group D: Internal module FK columns ───────────────────────────────
  # Each tuple: {target_table, int_fk, uuid_fk, source_table}

  @module_fk_columns [
    # Shop module internal FKs
    {:phoenix_kit_shop_cart_items, "cart_id", "cart_uuid", "phoenix_kit_shop_carts"},
    {:phoenix_kit_shop_cart_items, "product_id", "product_uuid", "phoenix_kit_shop_products"},
    {:phoenix_kit_shop_carts, "shipping_method_id", "shipping_method_uuid",
     "phoenix_kit_shop_shipping_methods"},
    {:phoenix_kit_shop_carts, "merged_into_cart_id", "merged_into_cart_uuid",
     "phoenix_kit_shop_carts"},
    {:phoenix_kit_shop_carts, "payment_option_id", "payment_option_uuid",
     "phoenix_kit_payment_options"},
    {:phoenix_kit_shop_products, "category_id", "category_uuid", "phoenix_kit_shop_categories"},
    {:phoenix_kit_shop_categories, "parent_id", "parent_uuid", "phoenix_kit_shop_categories"},
    {:phoenix_kit_shop_categories, "featured_product_id", "featured_product_uuid",
     "phoenix_kit_shop_products"},
    # Billing module internal FKs
    {:phoenix_kit_orders, "billing_profile_id", "billing_profile_uuid",
     "phoenix_kit_billing_profiles"},
    {:phoenix_kit_invoices, "order_id", "order_uuid", "phoenix_kit_orders"},
    {:phoenix_kit_transactions, "invoice_id", "invoice_uuid", "phoenix_kit_invoices"},
    {:phoenix_kit_subscriptions, "plan_id", "plan_uuid", "phoenix_kit_subscription_plans"},
    {:phoenix_kit_subscriptions, "billing_profile_id", "billing_profile_uuid",
     "phoenix_kit_billing_profiles"},
    {:phoenix_kit_subscriptions, "payment_method_id", "payment_method_uuid",
     "phoenix_kit_payment_methods"},
    # Email module internal FKs
    {:phoenix_kit_email_events, "email_log_id", "email_log_uuid", "phoenix_kit_email_logs"},
    # AI module internal FKs
    {:phoenix_kit_ai_requests, "endpoint_id", "endpoint_uuid", "phoenix_kit_ai_endpoints"},
    {:phoenix_kit_ai_requests, "prompt_id", "prompt_uuid", "phoenix_kit_ai_prompts"},
    # Sync module internal FKs
    {:phoenix_kit_sync_transfers, "connection_id", "connection_uuid",
     "phoenix_kit_sync_connections"},
    # Referrals module internal FKs
    {:phoenix_kit_referral_code_usage, "code_id", "code_uuid", "phoenix_kit_referral_codes"}
  ]

  # Tables likely to have many rows — use batched backfill
  @batch_tables [
    "phoenix_kit_users_tokens",
    "phoenix_kit_audit_logs",
    "phoenix_kit_email_logs",
    "phoenix_kit_email_events",
    "phoenix_kit_ai_requests",
    "phoenix_kit_entity_data",
    "phoenix_kit_posts",
    "phoenix_kit_post_comments",
    "phoenix_kit_post_likes",
    "phoenix_kit_post_views",
    "phoenix_kit_consent_logs"
  ]

  # ── NOT NULL UUID FK columns ────────────────────────────────────────────
  # UUID FK columns where the integer FK counterpart is NOT NULL.
  # Applied AFTER backfill to ensure no NULL values remain.

  @not_null_uuid_fks [
    # Group A — User FKs
    {:phoenix_kit_users_tokens, "user_uuid"},
    {:phoenix_kit_user_role_assignments, "user_uuid"},
    {:phoenix_kit_admin_notes, "user_uuid"},
    {:phoenix_kit_admin_notes, "author_uuid"},
    {:phoenix_kit_user_oauth_providers, "user_uuid"},
    {:phoenix_kit_audit_logs, "target_user_uuid"},
    {:phoenix_kit_audit_logs, "admin_user_uuid"},
    {:phoenix_kit_posts, "user_uuid"},
    {:phoenix_kit_post_comments, "user_uuid"},
    {:phoenix_kit_post_likes, "user_uuid"},
    {:phoenix_kit_post_dislikes, "user_uuid"},
    {:phoenix_kit_post_mentions, "user_uuid"},
    {:phoenix_kit_post_groups, "user_uuid"},
    {:phoenix_kit_comment_likes, "user_uuid"},
    {:phoenix_kit_comment_dislikes, "user_uuid"},
    {:phoenix_kit_ticket_comments, "user_uuid"},
    {:phoenix_kit_ticket_status_history, "changed_by_uuid"},
    {:phoenix_kit_user_blocks, "blocker_uuid"},
    {:phoenix_kit_user_blocks, "blocked_uuid"},
    {:phoenix_kit_user_blocks_history, "blocker_uuid"},
    {:phoenix_kit_user_blocks_history, "blocked_uuid"},
    {:phoenix_kit_user_follows, "follower_uuid"},
    {:phoenix_kit_user_follows, "followed_uuid"},
    {:phoenix_kit_user_follows_history, "follower_uuid"},
    {:phoenix_kit_user_follows_history, "followed_uuid"},
    {:phoenix_kit_user_connections, "requester_uuid"},
    {:phoenix_kit_user_connections, "recipient_uuid"},
    {:phoenix_kit_user_connections_history, "user_a_uuid"},
    {:phoenix_kit_user_connections_history, "user_b_uuid"},
    {:phoenix_kit_user_connections_history, "actor_uuid"},
    {:phoenix_kit_files, "user_uuid"},
    {:phoenix_kit_comments_likes, "user_uuid"},
    {:phoenix_kit_comments_dislikes, "user_uuid"},
    {:phoenix_kit_entities, "created_by_uuid"},
    {:phoenix_kit_entity_data, "created_by_uuid"},
    {:phoenix_kit_invoices, "user_uuid"},
    {:phoenix_kit_transactions, "user_uuid"},
    {:phoenix_kit_payment_methods, "user_uuid"},
    {:phoenix_kit_subscriptions, "user_uuid"},
    {:phoenix_kit_referral_codes, "created_by_uuid"},
    {:phoenix_kit_referral_code_usage, "used_by_uuid"},
    # Group B — Role FKs
    {:phoenix_kit_user_role_assignments, "role_uuid"},
    {:phoenix_kit_role_permissions, "role_uuid"},
    # Group C — Entity FKs
    {:phoenix_kit_entity_data, "entity_uuid"},
    # Group D — Module Internal FKs
    {:phoenix_kit_shop_cart_items, "cart_uuid"},
    {:phoenix_kit_subscriptions, "plan_uuid"},
    {:phoenix_kit_email_events, "email_log_uuid"},
    {:phoenix_kit_referral_code_usage, "code_uuid"}
  ]

  # ── Legacy Integer FK Columns to Relax (DROP NOT NULL) ──────────────────
  # Integer FK columns where the Ecto schema now exclusively uses UUID FKs.
  # Keeping NOT NULL on these causes insert failures when code only writes UUIDs.
  # Applied AFTER UUID NOT NULL constraints are set (UUID is the new primary path).

  @relax_integer_fks [
    {:phoenix_kit_user_role_assignments, "user_id"},
    {:phoenix_kit_user_role_assignments, "role_id"},
    {:phoenix_kit_user_role_assignments, "assigned_by"},
    {:phoenix_kit_role_permissions, "role_id"}
  ]

  # ── FK Constraints for UUID FK columns ──────────────────────────────────
  # Only where the integer FK has an explicit DB-level FK constraint.
  # ON DELETE behavior matches the integer FK's behavior.
  # Format: {table, uuid_fk, ref_table, ref_column, on_delete}

  @fk_constraints [
    # User FKs → phoenix_kit_users(uuid)
    {:phoenix_kit_users_tokens, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_role_assignments, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_role_assignments, "assigned_by_uuid", "phoenix_kit_users", "uuid",
     "SET NULL"},
    {:phoenix_kit_admin_notes, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_admin_notes, "author_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_oauth_providers, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    # Posts module
    {:phoenix_kit_posts, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_post_comments, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_post_likes, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_post_dislikes, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_post_views, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_post_mentions, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_post_groups, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_comment_likes, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_comment_dislikes, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    # Tickets module
    {:phoenix_kit_tickets, "user_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_tickets, "assigned_to_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_ticket_comments, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_ticket_status_history, "changed_by_uuid", "phoenix_kit_users", "uuid",
     "SET NULL"},
    # Connections module
    {:phoenix_kit_user_blocks, "blocker_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_blocks, "blocked_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_blocks_history, "blocker_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_blocks_history, "blocked_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_follows, "follower_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_follows, "followed_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_follows_history, "follower_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_follows_history, "followed_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_connections, "requester_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_connections, "recipient_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_user_connections_history, "user_a_uuid", "phoenix_kit_users", "uuid",
     "CASCADE"},
    {:phoenix_kit_user_connections_history, "user_b_uuid", "phoenix_kit_users", "uuid",
     "CASCADE"},
    {:phoenix_kit_user_connections_history, "actor_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    # Storage module
    {:phoenix_kit_files, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    # Comments module (standalone)
    {:phoenix_kit_comments, "user_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_comments_likes, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    {:phoenix_kit_comments_dislikes, "user_uuid", "phoenix_kit_users", "uuid", "CASCADE"},
    # Billing module
    {:phoenix_kit_billing_profiles, "user_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_orders, "user_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_invoices, "user_uuid", "phoenix_kit_users", "uuid", "RESTRICT"},
    {:phoenix_kit_transactions, "user_uuid", "phoenix_kit_users", "uuid", "RESTRICT"},
    # AI module
    {:phoenix_kit_ai_requests, "user_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    # Shop module
    {:phoenix_kit_shop_carts, "user_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_shop_products, "created_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_shop_import_logs, "user_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    # Sync module
    {:phoenix_kit_sync_connections, "approved_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_sync_connections, "suspended_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_sync_connections, "revoked_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_sync_connections, "created_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_sync_transfers, "approved_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_sync_transfers, "denied_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    {:phoenix_kit_sync_transfers, "initiated_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    # Role permissions
    {:phoenix_kit_role_permissions, "granted_by_uuid", "phoenix_kit_users", "uuid", "SET NULL"},
    # Role FKs → phoenix_kit_user_roles(uuid)
    {:phoenix_kit_user_role_assignments, "role_uuid", "phoenix_kit_user_roles", "uuid",
     "CASCADE"},
    {:phoenix_kit_role_permissions, "role_uuid", "phoenix_kit_user_roles", "uuid", "CASCADE"},
    # Entity FKs → phoenix_kit_entities(uuid)
    {:phoenix_kit_entity_data, "entity_uuid", "phoenix_kit_entities", "uuid", "CASCADE"},
    # Shop module internal FKs
    {:phoenix_kit_shop_cart_items, "cart_uuid", "phoenix_kit_shop_carts", "uuid", "CASCADE"},
    {:phoenix_kit_shop_cart_items, "product_uuid", "phoenix_kit_shop_products", "uuid",
     "SET NULL"},
    {:phoenix_kit_shop_carts, "shipping_method_uuid", "phoenix_kit_shop_shipping_methods", "uuid",
     "SET NULL"},
    {:phoenix_kit_shop_carts, "payment_option_uuid", "phoenix_kit_payment_options", "uuid",
     "SET NULL"},
    {:phoenix_kit_shop_products, "category_uuid", "phoenix_kit_shop_categories", "uuid",
     "SET NULL"},
    {:phoenix_kit_shop_categories, "parent_uuid", "phoenix_kit_shop_categories", "uuid",
     "SET NULL"},
    {:phoenix_kit_shop_categories, "featured_product_uuid", "phoenix_kit_shop_products", "uuid",
     "SET NULL"},
    # Billing module internal FKs
    {:phoenix_kit_orders, "billing_profile_uuid", "phoenix_kit_billing_profiles", "uuid",
     "SET NULL"},
    {:phoenix_kit_invoices, "order_uuid", "phoenix_kit_orders", "uuid", "SET NULL"},
    {:phoenix_kit_transactions, "invoice_uuid", "phoenix_kit_invoices", "uuid", "RESTRICT"},
    # Email module internal FKs
    {:phoenix_kit_email_events, "email_log_uuid", "phoenix_kit_email_logs", "uuid", "CASCADE"},
    # AI module internal FKs
    {:phoenix_kit_ai_requests, "endpoint_uuid", "phoenix_kit_ai_endpoints", "uuid", "SET NULL"},
    {:phoenix_kit_ai_requests, "prompt_uuid", "phoenix_kit_ai_prompts", "uuid", "SET NULL"},
    # Sync module internal FKs
    {:phoenix_kit_sync_transfers, "connection_uuid", "phoenix_kit_sync_connections", "uuid",
     "SET NULL"},
    # Referrals module internal FKs
    {:phoenix_kit_referral_code_usage, "code_uuid", "phoenix_kit_referral_codes", "uuid",
     "CASCADE"}
  ]

  # ── Public API ────────────────────────────────────────────────────────

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Group A: FK columns → phoenix_kit_users.uuid
    process_fk_group(@user_fk_columns, "phoenix_kit_users", prefix, escaped_prefix)

    # Group B: FK columns → phoenix_kit_user_roles.uuid
    process_fk_group(@role_fk_columns, "phoenix_kit_user_roles", prefix, escaped_prefix)

    # Group C: FK columns → phoenix_kit_entities.uuid
    process_fk_group(@entity_fk_columns, "phoenix_kit_entities", prefix, escaped_prefix)

    # Group D: Internal module FKs (each has its own source table)
    process_module_fk_group(@module_fk_columns, prefix, escaped_prefix)
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    all_columns =
      Enum.map(@user_fk_columns, fn {t, _i, u} -> {t, u} end) ++
        Enum.map(@role_fk_columns, fn {t, _i, u} -> {t, u} end) ++
        Enum.map(@entity_fk_columns, fn {t, _i, u} -> {t, u} end) ++
        Enum.map(@module_fk_columns, fn {t, _i, u, _s} -> {t, u} end)

    for {table, uuid_fk} <- all_columns do
      table_str = Atom.to_string(table)

      if table_exists?(table_str, escaped_prefix) do
        drop_uuid_fk_index(table_str, uuid_fk, prefix, escaped_prefix)
        drop_uuid_fk_column(table_str, uuid_fk, prefix, escaped_prefix)
      end
    end
  end

  @doc """
  Adds NOT NULL constraints and FK constraints to UUID FK columns.

  Must be called AFTER `up/1` so that columns exist and are backfilled.

  Order: NOT NULL first (data already backfilled), then ensure unique indexes
  on all FK-target tables, then FK constraints.
  """
  def add_constraints(%{prefix: prefix} = _opts) do
    escaped_prefix = String.replace(prefix, "'", "\\'")

    for {table, uuid_fk} <- @not_null_uuid_fks do
      set_not_null(table, uuid_fk, prefix, escaped_prefix)
    end

    # Ensure unique indexes exist on all FK-target uuid columns.
    # FK constraints require a unique constraint/index on the referenced column.
    # V56 should have created these, but if it ran with an older version of this
    # module, some tables may be missing them.
    ensure_fk_target_unique_indexes(prefix, escaped_prefix)

    for {table, uuid_fk, ref_table, ref_col, on_delete} <- @fk_constraints do
      add_fk_constraint(table, uuid_fk, ref_table, ref_col, on_delete, prefix, escaped_prefix)
    end

    # Relax NOT NULL on legacy integer FK columns where Ecto schemas
    # now exclusively write UUID FKs. Without this, inserts that only
    # populate UUID columns fail with NOT NULL violations.
    for {table, int_fk} <- @relax_integer_fks do
      relax_integer_not_null(table, int_fk, prefix, escaped_prefix)
    end
  end

  @doc """
  Drops FK constraints and NOT NULL from UUID FK columns.

  Must be called BEFORE `down/1` so constraints are removed before columns are dropped.

  Order: FK constraints first (unblocks column removal), then NOT NULL.
  """
  def drop_constraints(%{prefix: prefix} = _opts) do
    escaped_prefix = String.replace(prefix, "'", "\\'")

    for {table, uuid_fk, _ref_table, _ref_col, _on_delete} <- @fk_constraints do
      drop_fk_constraint(table, uuid_fk, prefix, escaped_prefix)
    end

    for {table, uuid_fk} <- @not_null_uuid_fks do
      drop_not_null(table, uuid_fk, prefix, escaped_prefix)
    end
  end

  # ── FK Target Unique Index Enforcement ────────────────────────────────
  # PostgreSQL requires a UNIQUE constraint/index on the referenced column
  # for any FK constraint. This ensures all FK-target tables have one.

  defp ensure_fk_target_unique_indexes(prefix, escaped_prefix) do
    # Collect distinct {ref_table, ref_col} pairs from @fk_constraints
    fk_targets =
      @fk_constraints
      |> Enum.map(fn {_table, _uuid_fk, ref_table, ref_col, _on_delete} ->
        {ref_table, ref_col}
      end)
      |> Enum.uniq()

    for {ref_table, ref_col} <- fk_targets do
      if table_exists?(ref_table, escaped_prefix) and
           column_exists?(ref_table, ref_col, escaped_prefix) and
           not unique_index_exists?(ref_table, ref_col, escaped_prefix) do
        table_name = prefix_table_name(ref_table, prefix)
        index_name = "#{ref_table}_#{ref_col}_idx"

        index_name =
          case prefix do
            nil -> index_name
            "public" -> index_name
            p -> "#{p}.#{index_name}"
          end

        execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS #{index_name}
        ON #{table_name}(#{ref_col})
        """)
      end
    end
  end

  defp unique_index_exists?(table_str, column_str, escaped_prefix) do
    # Check pg_indexes for a unique index that covers this exact column
    query = """
    SELECT EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE tablename = '#{table_str}'
      AND schemaname = '#{escaped_prefix}'
      AND indexdef LIKE '%UNIQUE%'
      AND indexdef LIKE '%(#{column_str})%'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  # ── Group Processing ──────────────────────────────────────────────────

  defp process_fk_group(columns, source_table, prefix, escaped_prefix) do
    for {table, int_fk, uuid_fk} <- columns do
      table_str = Atom.to_string(table)

      if table_exists?(table_str, escaped_prefix) and
           table_exists?(source_table, escaped_prefix) and
           column_exists?(table_str, int_fk, escaped_prefix) do
        add_uuid_fk_column(table_str, uuid_fk, prefix, escaped_prefix)
        backfill_uuid_fk(table_str, int_fk, uuid_fk, source_table, prefix, escaped_prefix)
        create_uuid_fk_index(table_str, uuid_fk, prefix, escaped_prefix)
      end
    end
  end

  defp process_module_fk_group(columns, prefix, escaped_prefix) do
    for {table, int_fk, uuid_fk, source_table} <- columns do
      table_str = Atom.to_string(table)

      if table_exists?(table_str, escaped_prefix) and
           table_exists?(source_table, escaped_prefix) and
           column_exists?(table_str, int_fk, escaped_prefix) do
        add_uuid_fk_column(table_str, uuid_fk, prefix, escaped_prefix)
        backfill_uuid_fk(table_str, int_fk, uuid_fk, source_table, prefix, escaped_prefix)
        create_uuid_fk_index(table_str, uuid_fk, prefix, escaped_prefix)
      end
    end
  end

  # ── Column Operations ─────────────────────────────────────────────────

  defp add_uuid_fk_column(table_str, uuid_fk, prefix, escaped_prefix) do
    unless column_exists?(table_str, uuid_fk, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)

      execute("""
      ALTER TABLE #{table_name}
      ADD COLUMN IF NOT EXISTS #{uuid_fk} UUID
      """)
    end
  end

  defp backfill_uuid_fk(table_str, int_fk, uuid_fk, source_table, prefix, _escaped_prefix) do
    table_name = prefix_table_name(table_str, prefix)
    source_name = prefix_table_name(source_table, prefix)

    # Always attempt backfill — the SQL is idempotent (WHERE uuid_fk IS NULL).
    # Skipping via column_exists? can fail when columns were just added in the
    # same transaction (information_schema visibility lag).
    if table_str in @batch_tables do
      batched_backfill(table_name, int_fk, uuid_fk, source_name)
    else
      simple_backfill(table_name, int_fk, uuid_fk, source_name)
    end
  rescue
    # If column doesn't exist yet (shouldn't happen), silently skip
    _ -> :ok
  end

  defp simple_backfill(table_name, int_fk, uuid_fk, source_name) do
    execute("""
    UPDATE #{table_name} t
    SET #{uuid_fk} = s.uuid
    FROM #{source_name} s
    WHERE s.id = t.#{int_fk}
      AND t.#{uuid_fk} IS NULL
      AND t.#{int_fk} IS NOT NULL
    """)
  end

  defp batched_backfill(table_name, int_fk, uuid_fk, source_name) do
    execute("""
    DO $$
    DECLARE
      batch_count INTEGER;
    BEGIN
      LOOP
        UPDATE #{table_name} t
        SET #{uuid_fk} = s.uuid
        FROM #{source_name} s
        WHERE s.id = t.#{int_fk}
          AND t.#{uuid_fk} IS NULL
          AND t.#{int_fk} IS NOT NULL
          AND t.ctid IN (
            SELECT t2.ctid FROM #{table_name} t2
            WHERE t2.#{uuid_fk} IS NULL
              AND t2.#{int_fk} IS NOT NULL
            LIMIT #{@batch_size}
          );

        GET DIAGNOSTICS batch_count = ROW_COUNT;
        EXIT WHEN batch_count = 0;
        PERFORM pg_sleep(0.01);
      END LOOP;
    END $$;
    """)
  end

  defp create_uuid_fk_index(table_str, uuid_fk, prefix, escaped_prefix) do
    table_name = prefix_table_name(table_str, prefix)
    index_name = "#{table_str}_#{uuid_fk}_idx"

    index_name =
      case prefix do
        nil -> index_name
        "public" -> index_name
        p -> "#{p}.#{index_name}"
      end

    unless index_exists?(table_str, "#{table_str}_#{uuid_fk}_idx", escaped_prefix) do
      execute("""
      CREATE INDEX IF NOT EXISTS #{index_name}
      ON #{table_name}(#{uuid_fk})
      """)
    end
  end

  # ── NOT NULL Operations ───────────────────────────────────────────────

  defp set_not_null(table, uuid_fk, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    if table_exists?(table_str, escaped_prefix) and
         column_exists?(table_str, uuid_fk, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)

      # SET NOT NULL is idempotent in PostgreSQL (no-op if already NOT NULL)
      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN #{uuid_fk} SET NOT NULL
      """)
    end
  end

  defp drop_not_null(table, uuid_fk, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    if table_exists?(table_str, escaped_prefix) and
         column_exists?(table_str, uuid_fk, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)

      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN #{uuid_fk} DROP NOT NULL
      """)
    end
  end

  # ── Legacy Integer FK Relaxation ─────────────────────────────────────

  defp relax_integer_not_null(table, int_fk, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    if table_exists?(table_str, escaped_prefix) and
         column_exists?(table_str, int_fk, escaped_prefix) and
         column_is_not_null?(table_str, int_fk, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)

      execute("""
      ALTER TABLE #{table_name}
      ALTER COLUMN #{int_fk} DROP NOT NULL
      """)
    end
  end

  defp column_is_not_null?(table_str, column_str, escaped_prefix) do
    query = """
    SELECT is_nullable FROM information_schema.columns
    WHERE table_name = '#{table_str}'
    AND column_name = '#{column_str}'
    AND table_schema = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [["NO"]]}} -> true
      _ -> false
    end
  end

  # ── FK Constraint Operations ──────────────────────────────────────────

  defp add_fk_constraint(table, uuid_fk, ref_table, ref_col, on_delete, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    if table_exists?(table_str, escaped_prefix) and
         column_exists?(table_str, uuid_fk, escaped_prefix) and
         table_exists?(ref_table, escaped_prefix) and
         column_exists?(ref_table, ref_col, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)
      ref_name = prefix_table_name(ref_table, prefix)
      constraint = fk_constraint_name(table_str, uuid_fk)

      # Use DO block with pg_constraint check for idempotency (matches V51 pattern)
      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = '#{constraint}'
          AND conrelid = '#{table_name}'::regclass
        ) THEN
          ALTER TABLE #{table_name}
          ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{uuid_fk})
          REFERENCES #{ref_name}(#{ref_col})
          ON DELETE #{on_delete};
        END IF;
      END $$;
      """)
    end
  end

  defp drop_fk_constraint(table, uuid_fk, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    if table_exists?(table_str, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)
      constraint = fk_constraint_name(table_str, uuid_fk)

      execute("""
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = '#{constraint}'
          AND conrelid = '#{table_name}'::regclass
        ) THEN
          ALTER TABLE #{table_name}
          DROP CONSTRAINT #{constraint};
        END IF;
      END $$;
      """)
    end
  end

  # ── Rollback Operations ───────────────────────────────────────────────

  defp drop_uuid_fk_column(table_str, uuid_fk, prefix, escaped_prefix) do
    if column_exists?(table_str, uuid_fk, escaped_prefix) do
      table_name = prefix_table_name(table_str, prefix)

      execute("""
      ALTER TABLE #{table_name}
      DROP COLUMN #{uuid_fk}
      """)
    end
  end

  defp drop_uuid_fk_index(table_str, uuid_fk, prefix, _escaped_prefix) do
    index_name = "#{table_str}_#{uuid_fk}_idx"

    index_name =
      case prefix do
        nil -> index_name
        "public" -> index_name
        p -> "#{p}.#{index_name}"
      end

    execute("DROP INDEX IF EXISTS #{index_name}")
  end

  # ── Existence Checks ──────────────────────────────────────────────────

  defp table_exists?(table_str, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{table_str}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table_str, column_str, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_name = '#{table_str}'
      AND column_name = '#{column_str}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp index_exists?(table_str, index_name, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM pg_indexes
      WHERE tablename = '#{table_str}'
      AND indexname = '#{index_name}'
      AND schemaname = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  # ── Naming Helpers ────────────────────────────────────────────────────

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  defp fk_constraint_name(table_str, uuid_fk) do
    short = String.replace_prefix(table_str, "phoenix_kit_", "")
    "fk_#{short}_#{uuid_fk}"
  end
end
