defmodule PhoenixKit.Migrations.Postgres.V67 do
  @moduledoc """
  V67: Make all remaining legacy NOT NULL integer FK columns nullable.

  After the UUID cleanup (V56+), schemas only write `_uuid` foreign keys.
  Many tables still have legacy integer FK columns with NOT NULL constraints,
  causing inserts to fail with `not_null_violation`.

  This migration makes all remaining affected columns nullable in one pass.
  All operations are idempotent (guarded by table/column existence checks).

  ## Tables & Columns (39 total)

  ### Posts (3)
  - posts.user_id
  - comment_likes.user_id
  - comment_dislikes.user_id

  ### Tickets (2)
  - ticket_comments.user_id
  - ticket_status_history.changed_by_id

  ### Storage (1)
  - files.user_id

  ### Admin/Auth/Audit (5)
  - admin_notes.user_id, admin_notes.author_id
  - user_oauth_providers.user_id
  - audit_logs.target_user_id, audit_logs.admin_user_id

  ### Connections (13)
  - user_follows: follower_id, followed_id
  - user_connections: requester_id, recipient_id
  - user_blocks: blocker_id, blocked_id
  - user_follows_history: follower_id, followed_id
  - user_connections_history: user_a_id, user_b_id, actor_id
  - user_blocks_history: blocker_id, blocked_id

  ### Billing (6)
  - invoices.user_id
  - transactions.user_id, transactions.invoice_id
  - subscriptions.user_id, subscriptions.subscription_type_id (was plan_id)
  - payment_methods.user_id

  ### Entities (3)
  - entities.created_by
  - entity_data.entity_id, entity_data.created_by

  ### Referrals (3)
  - referral_codes.created_by
  - referral_code_usage.code_id, referral_code_usage.used_by

  ### Standalone Comments (2)
  - comments_likes.user_id
  - comments_dislikes.user_id

  ### Shop (1)
  - shop_cart_items.cart_id
  """

  use Ecto.Migration

  # {table_name, column_name}
  @columns [
    # Posts
    {"phoenix_kit_posts", "user_id"},
    {"phoenix_kit_comment_likes", "user_id"},
    {"phoenix_kit_comment_dislikes", "user_id"},
    # Tickets
    {"phoenix_kit_ticket_comments", "user_id"},
    {"phoenix_kit_ticket_status_history", "changed_by_id"},
    # Storage
    {"phoenix_kit_files", "user_id"},
    # Admin / Auth / Audit
    {"phoenix_kit_admin_notes", "user_id"},
    {"phoenix_kit_admin_notes", "author_id"},
    {"phoenix_kit_user_oauth_providers", "user_id"},
    {"phoenix_kit_audit_logs", "target_user_id"},
    {"phoenix_kit_audit_logs", "admin_user_id"},
    # Connections
    {"phoenix_kit_user_follows", "follower_id"},
    {"phoenix_kit_user_follows", "followed_id"},
    {"phoenix_kit_user_connections", "requester_id"},
    {"phoenix_kit_user_connections", "recipient_id"},
    {"phoenix_kit_user_blocks", "blocker_id"},
    {"phoenix_kit_user_blocks", "blocked_id"},
    {"phoenix_kit_user_follows_history", "follower_id"},
    {"phoenix_kit_user_follows_history", "followed_id"},
    {"phoenix_kit_user_connections_history", "user_a_id"},
    {"phoenix_kit_user_connections_history", "user_b_id"},
    {"phoenix_kit_user_connections_history", "actor_id"},
    {"phoenix_kit_user_blocks_history", "blocker_id"},
    {"phoenix_kit_user_blocks_history", "blocked_id"},
    # Billing
    {"phoenix_kit_invoices", "user_id"},
    {"phoenix_kit_transactions", "user_id"},
    {"phoenix_kit_transactions", "invoice_id"},
    {"phoenix_kit_subscriptions", "user_id"},
    {"phoenix_kit_payment_methods", "user_id"},
    # Entities
    {"phoenix_kit_entities", "created_by"},
    {"phoenix_kit_entity_data", "entity_id"},
    {"phoenix_kit_entity_data", "created_by"},
    # Referrals
    {"phoenix_kit_referral_codes", "created_by"},
    {"phoenix_kit_referral_code_usage", "code_id"},
    {"phoenix_kit_referral_code_usage", "used_by"},
    # Standalone Comments
    {"phoenix_kit_comments_likes", "user_id"},
    {"phoenix_kit_comments_dislikes", "user_id"},
    # Shop
    {"phoenix_kit_shop_cart_items", "cart_id"}
  ]

  # V65 renamed plan_id → subscription_type_id, but older installs may still
  # have plan_id. Handle both names.
  @subscription_type_columns [
    {"phoenix_kit_subscriptions", "subscription_type_id"},
    {"phoenix_kit_subscriptions", "plan_id"}
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    for {table, column} <- @columns do
      drop_not_null_if_exists(table, column, prefix, escaped_prefix)
    end

    # Handle subscription type column (could be either name)
    for {table, column} <- @subscription_type_columns do
      drop_not_null_if_exists(table, column, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '67'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    for {table, column} <- @subscription_type_columns do
      set_not_null_if_exists(table, column, prefix, escaped_prefix)
    end

    for {table, column} <- Enum.reverse(@columns) do
      set_not_null_if_exists(table, column, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '66'")
  end

  defp drop_not_null_if_exists(table, column, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) and
         column_exists?(table, column, escaped_prefix) and
         column_not_null?(table, column, escaped_prefix) do
      execute("""
      ALTER TABLE #{prefix_table(table, prefix)}
      ALTER COLUMN #{column} DROP NOT NULL
      """)
    end
  end

  defp set_not_null_if_exists(table, column, prefix, escaped_prefix) do
    if table_exists?(table, escaped_prefix) and
         column_exists?(table, column, escaped_prefix) do
      execute("""
      ALTER TABLE #{prefix_table(table, prefix)}
      ALTER COLUMN #{column} SET NOT NULL
      """)
    end
  end

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

  defp column_not_null?(table, column, escaped_prefix) do
    case repo().query(
           """
           SELECT is_nullable = 'NO'
           FROM information_schema.columns
           WHERE table_name = '#{table}'
           AND column_name = '#{column}'
           AND table_schema = '#{escaped_prefix}'
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
