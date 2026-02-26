defmodule PhoenixKit.Migrations.Postgres.V65 do
  @moduledoc """
  V65: Rename SubscriptionPlan → SubscriptionType

  Renames the subscription plans table and related FK columns in subscriptions
  to reflect the correct "subscription type" naming convention.

  ## Changes

  1. `phoenix_kit_subscription_plans` table → `phoenix_kit_subscription_types`
  2. `phoenix_kit_subscription_plans_slug_uidx` index →
     `phoenix_kit_subscription_types_slug_uidx`
  3. `phoenix_kit_subscriptions.plan_id` → `subscription_type_id`
  4. `phoenix_kit_subscriptions.plan_uuid` → `subscription_type_uuid`

  All operations are idempotent — safe to run on any installation.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Flush any pending migration commands from earlier versions
    flush()

    # 1. Rename phoenix_kit_subscription_plans → phoenix_kit_subscription_types
    rename_subscription_plans_table(prefix, escaped_prefix)

    # Flush so the renamed table is visible for subsequent operations
    flush()

    # 2. Rename plan_id / plan_uuid columns in phoenix_kit_subscriptions
    rename_plan_columns_in_subscriptions(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '65'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # Reverse column renames first
    reverse_plan_columns_in_subscriptions(prefix, escaped_prefix)

    # Then reverse table rename
    reverse_subscription_plans_table(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '64'")
  end

  # ---------------------------------------------------------------------------
  # Up helpers
  # ---------------------------------------------------------------------------

  defp rename_subscription_plans_table(prefix, escaped_prefix) do
    if table_exists?(:phoenix_kit_subscription_plans, escaped_prefix) do
      old_table = prefix_table("phoenix_kit_subscription_plans", prefix)
      execute("ALTER TABLE #{old_table} RENAME TO phoenix_kit_subscription_types")

      execute("""
      ALTER INDEX IF EXISTS phoenix_kit_subscription_plans_slug_uidx
      RENAME TO phoenix_kit_subscription_types_slug_uidx
      """)
    end
  end

  defp rename_plan_columns_in_subscriptions(prefix, escaped_prefix) do
    if table_exists?(:phoenix_kit_subscriptions, escaped_prefix) do
      table = prefix_table("phoenix_kit_subscriptions", prefix)

      if column_exists?(:phoenix_kit_subscriptions, :plan_id, escaped_prefix) do
        execute("ALTER TABLE #{table} RENAME COLUMN plan_id TO subscription_type_id")
      end

      if column_exists?(:phoenix_kit_subscriptions, :plan_uuid, escaped_prefix) do
        execute("ALTER TABLE #{table} RENAME COLUMN plan_uuid TO subscription_type_uuid")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Down helpers
  # ---------------------------------------------------------------------------

  defp reverse_subscription_plans_table(prefix, escaped_prefix) do
    if table_exists?(:phoenix_kit_subscription_types, escaped_prefix) do
      new_table = prefix_table("phoenix_kit_subscription_types", prefix)
      execute("ALTER TABLE #{new_table} RENAME TO phoenix_kit_subscription_plans")

      execute("""
      ALTER INDEX IF EXISTS phoenix_kit_subscription_types_slug_uidx
      RENAME TO phoenix_kit_subscription_plans_slug_uidx
      """)
    end
  end

  defp reverse_plan_columns_in_subscriptions(prefix, escaped_prefix) do
    if table_exists?(:phoenix_kit_subscriptions, escaped_prefix) do
      table = prefix_table("phoenix_kit_subscriptions", prefix)

      if column_exists?(:phoenix_kit_subscriptions, :subscription_type_id, escaped_prefix) do
        execute("ALTER TABLE #{table} RENAME COLUMN subscription_type_id TO plan_id")
      end

      if column_exists?(:phoenix_kit_subscriptions, :subscription_type_uuid, escaped_prefix) do
        execute("ALTER TABLE #{table} RENAME COLUMN subscription_type_uuid TO plan_uuid")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers (same pattern as V63)
  # ---------------------------------------------------------------------------

  defp table_exists?(table, escaped_prefix) do
    table_name = Atom.to_string(table)

    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table_name}'
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
    table_name = Atom.to_string(table)
    column_name = Atom.to_string(column)

    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table_name}'
             AND column_name = '#{column_name}'
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
