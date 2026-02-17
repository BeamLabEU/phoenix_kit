defmodule PhoenixKit.Migrations.Postgres.V58 do
  @moduledoc """
  V58: Timestamp Column Type Standardization (timestamptz)

  Converts ALL timestamp columns across all 68 PhoenixKit tables from
  `timestamp without time zone` (aka `timestamp(0)`) to
  `timestamp with time zone` (aka `timestamptz`).

  This completes the DateTime standardization:
  - Steps 1-4 (prior): Elixir schemas → `:utc_datetime` / `DateTime.utc_now()`
  - V58: PostgreSQL columns → `timestamptz`

  ## Why timestamptz?

  PostgreSQL `timestamp` stores values without timezone context. While PhoenixKit
  always stores UTC, `timestamptz` makes this explicit at the database level and
  is the PostgreSQL-recommended type for timestamps. Ecto's `:utc_datetime` type
  maps to `timestamptz` natively.

  ## Conversion Safety

  The `up` direction needs no `USING` clause — PostgreSQL implicitly treats
  existing `timestamp` values as UTC when casting to `timestamptz`.

  The `down` direction requires `USING col AT TIME ZONE 'UTC'` to explicitly
  convert `timestamptz` back to `timestamp(0)`.

  ## Idempotency

  All operations check:
  - `table_exists?/2` — skip if table doesn't exist (optional modules)
  - `column_exists?/3` — skip if column doesn't exist
  - `column_is_timestamptz?/3` — skip if already converted (up) or already reverted (down)
  """

  use Ecto.Migration

  # All PhoenixKit tables and their timestamp columns (68 tables, ~193 columns)
  @timestamp_columns [
    # V01 — Core Auth
    {"phoenix_kit", ["migrated_at"]},
    {"phoenix_kit_users", ["confirmed_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_users_tokens", ["inserted_at"]},
    {"phoenix_kit_user_roles", ["inserted_at", "updated_at"]},
    {"phoenix_kit_user_role_assignments", ["assigned_at", "inserted_at"]},

    # V03 — Settings
    {"phoenix_kit_settings", ["date_added", "date_updated"]},

    # V04 — Referrals
    {"phoenix_kit_referral_codes", ["date_created", "expiration_date"]},
    {"phoenix_kit_referral_code_usage", ["date_used"]},

    # V07+V13+V19 — Email Logs (merged)
    {"phoenix_kit_email_logs",
     [
       "sent_at",
       "delivered_at",
       "bounced_at",
       "complained_at",
       "opened_at",
       "clicked_at",
       "queued_at",
       "rejected_at",
       "failed_at",
       "delayed_at",
       "inserted_at",
       "updated_at"
     ]},
    {"phoenix_kit_email_events", ["occurred_at", "inserted_at", "updated_at"]},

    # V09 — Email Blocklist
    {"phoenix_kit_email_blocklist", ["expires_at", "inserted_at", "updated_at"]},

    # V15 — Email Templates
    {"phoenix_kit_email_templates", ["last_used_at", "inserted_at", "updated_at"]},

    # V16 — OAuth
    {"phoenix_kit_user_oauth_providers", ["token_expires_at", "inserted_at", "updated_at"]},

    # V17 — Entities
    {"phoenix_kit_entities", ["date_created", "date_updated"]},
    {"phoenix_kit_entity_data", ["date_created", "date_updated"]},

    # V20 — Storage
    {"phoenix_kit_buckets", ["inserted_at", "updated_at"]},
    {"phoenix_kit_files", ["inserted_at", "updated_at"]},
    {"phoenix_kit_file_instances", ["inserted_at", "updated_at"]},
    {"phoenix_kit_file_locations", ["last_verified_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_storage_dimensions", ["inserted_at", "updated_at"]},

    # V22 — Email Extensions
    {"phoenix_kit_email_orphaned_events",
     ["received_at", "matched_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_email_metrics", ["inserted_at", "updated_at"]},
    {"phoenix_kit_audit_logs", ["inserted_at"]},

    # V29 — Posts
    {"phoenix_kit_posts", ["scheduled_at", "published_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_post_media", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_likes", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_comments", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_mentions", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_tags", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_tag_assignments", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_groups", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_group_assignments", ["inserted_at", "updated_at"]},
    {"phoenix_kit_post_views", ["viewed_at", "inserted_at", "updated_at"]},

    # V31 — Billing Core
    {"phoenix_kit_currencies", ["inserted_at", "updated_at"]},
    {"phoenix_kit_billing_profiles", ["inserted_at", "updated_at"]},
    {"phoenix_kit_orders",
     [
       "confirmed_at",
       "paid_at",
       "cancelled_at",
       "checkout_expires_at",
       "inserted_at",
       "updated_at"
     ]},
    {"phoenix_kit_invoices",
     [
       "receipt_generated_at",
       "sent_at",
       "paid_at",
       "voided_at",
       "inserted_at",
       "updated_at"
     ]},
    {"phoenix_kit_transactions", ["inserted_at", "updated_at"]},

    # V32 — AI Core
    {"phoenix_kit_ai_accounts", ["last_validated_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_ai_requests", ["inserted_at", "updated_at"]},

    # V33 — Billing Extended
    {"phoenix_kit_payment_methods", ["inserted_at", "updated_at"]},
    {"phoenix_kit_subscription_plans", ["inserted_at", "updated_at"]},
    {"phoenix_kit_subscriptions",
     [
       "current_period_start",
       "current_period_end",
       "cancelled_at",
       "trial_start",
       "trial_end",
       "grace_period_end",
       "last_renewal_attempt_at",
       "inserted_at",
       "updated_at"
     ]},
    {"phoenix_kit_payment_provider_configs", ["last_verified_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_webhook_events", ["processed_at", "inserted_at", "updated_at"]},

    # V34 — AI Endpoints
    {"phoenix_kit_ai_endpoints", ["last_validated_at", "inserted_at", "updated_at"]},

    # V35 — Tickets
    {"phoenix_kit_tickets", ["resolved_at", "closed_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_ticket_comments", ["inserted_at", "updated_at"]},
    {"phoenix_kit_ticket_attachments", ["inserted_at", "updated_at"]},
    {"phoenix_kit_ticket_status_history", ["inserted_at"]},

    # V36 — Social/Connections
    {"phoenix_kit_user_follows", ["inserted_at"]},
    {"phoenix_kit_user_connections",
     ["requested_at", "responded_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_user_blocks", ["inserted_at"]},
    {"phoenix_kit_user_follows_history", ["inserted_at"]},
    {"phoenix_kit_user_connections_history", ["inserted_at"]},
    {"phoenix_kit_user_blocks_history", ["inserted_at"]},

    # V37 — Sync (renamed in V44)
    {"phoenix_kit_sync_connections",
     [
       "expires_at",
       "approved_at",
       "suspended_at",
       "revoked_at",
       "last_connected_at",
       "last_transfer_at",
       "inserted_at",
       "updated_at"
     ]},
    {"phoenix_kit_sync_transfers",
     [
       "approved_at",
       "denied_at",
       "approval_expires_at",
       "started_at",
       "completed_at",
       "inserted_at"
     ]},

    # V38 — AI Prompts
    {"phoenix_kit_ai_prompts", ["last_used_at", "inserted_at", "updated_at"]},

    # V39 — Admin Notes
    {"phoenix_kit_admin_notes", ["inserted_at", "updated_at"]},

    # V42 — Scheduled Jobs
    {"phoenix_kit_scheduled_jobs", ["scheduled_at", "executed_at", "inserted_at", "updated_at"]},

    # V43 — Legal/Consent
    {"phoenix_kit_consent_logs", ["inserted_at", "updated_at"]},

    # V45 — Shop
    {"phoenix_kit_shop_categories", ["inserted_at", "updated_at"]},
    {"phoenix_kit_shop_products", ["inserted_at", "updated_at"]},
    {"phoenix_kit_shop_shipping_methods", ["inserted_at", "updated_at"]},
    {"phoenix_kit_shop_carts", ["expires_at", "converted_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_shop_cart_items", ["inserted_at", "updated_at"]},
    {"phoenix_kit_payment_options", ["inserted_at", "updated_at"]},

    # V46 — Shop Config/Import
    {"phoenix_kit_shop_config", ["inserted_at", "updated_at"]},
    {"phoenix_kit_shop_import_logs", ["started_at", "completed_at", "inserted_at", "updated_at"]},
    {"phoenix_kit_shop_import_configs", ["inserted_at", "updated_at"]},

    # V48 — Post Reactions
    {"phoenix_kit_post_dislikes", ["inserted_at", "updated_at"]},
    {"phoenix_kit_comment_likes", ["inserted_at", "updated_at"]},
    {"phoenix_kit_comment_dislikes", ["inserted_at", "updated_at"]},

    # V53 — Role Permissions
    {"phoenix_kit_role_permissions", ["inserted_at"]},

    # V55 — Standalone Comments
    {"phoenix_kit_comments", ["inserted_at", "updated_at"]},
    {"phoenix_kit_comments_likes", ["inserted_at", "updated_at"]},
    {"phoenix_kit_comments_dislikes", ["inserted_at", "updated_at"]}
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    Enum.each(@timestamp_columns, fn {table, columns} ->
      if table_exists?(table, escaped_prefix) do
        convert_columns_to_timestamptz(table, columns, prefix, escaped_prefix)
      end
    end)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '58'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    Enum.each(@timestamp_columns, fn {table, columns} ->
      if table_exists?(table, escaped_prefix) do
        revert_columns_from_timestamptz(table, columns, prefix, escaped_prefix)
      end
    end)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '57'")
  end

  defp convert_columns_to_timestamptz(table, columns, prefix, escaped_prefix) do
    full_table = prefix_table_name(table, prefix)

    Enum.each(columns, fn col ->
      if column_exists?(table, col, escaped_prefix) and
           not column_is_timestamptz?(table, col, escaped_prefix) do
        execute("ALTER TABLE #{full_table} ALTER COLUMN #{col} TYPE timestamptz")
      end
    end)
  end

  defp revert_columns_from_timestamptz(table, columns, prefix, escaped_prefix) do
    full_table = prefix_table_name(table, prefix)

    Enum.each(columns, fn col ->
      if column_exists?(table, col, escaped_prefix) and
           column_is_timestamptz?(table, col, escaped_prefix) do
        execute(
          "ALTER TABLE #{full_table} ALTER COLUMN #{col} " <>
            "TYPE timestamp(0) USING #{col} AT TIME ZONE 'UTC'"
        )
      end
    end)
  end

  # Helpers

  defp table_exists?(table, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_name = '#{table}'
      AND column_name = '#{column}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_is_timestamptz?(table, column, escaped_prefix) do
    query = """
    SELECT data_type = 'timestamp with time zone'
    FROM information_schema.columns
    WHERE table_name = '#{table}'
    AND column_name = '#{column}'
    AND table_schema = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
