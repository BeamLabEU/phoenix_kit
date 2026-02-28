defmodule PhoenixKit.Migrations.Postgres.V69 do
  @moduledoc """
  V69: Make legacy integer FK columns nullable on role tables.

  After the UUID cleanup, role schemas only write `user_uuid` / `role_uuid` —
  they never set the legacy integer FK columns. Two tables still have these
  columns as NOT NULL, causing inserts to fail with not_null_violation.

  This was missed in V67 (the broader NOT NULL cleanup migration).

  ## Columns Fixed

  - `phoenix_kit_user_role_assignments.user_id` (NOT NULL → nullable)
  - `phoenix_kit_user_role_assignments.role_id` (NOT NULL → nullable)
  - `phoenix_kit_role_permissions.role_id` (NOT NULL → nullable)

  All operations are idempotent (guarded by table/column existence + NOT NULL checks).
  """

  use Ecto.Migration

  @columns [
    {"phoenix_kit_user_role_assignments", "user_id"},
    {"phoenix_kit_user_role_assignments", "role_id"},
    {"phoenix_kit_role_permissions", "role_id"}
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    for {table, column} <- @columns do
      drop_not_null_if_exists(table, column, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '69'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    for {table, column} <- Enum.reverse(@columns) do
      set_not_null_if_exists(table, column, prefix, escaped_prefix)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '68'")
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
