defmodule PhoenixKit.Migrations.Postgres.V57 do
  @moduledoc """
  V57: UUID FK Column Repair

  Re-runs the idempotent UUID FK column operations from V56 to catch any
  columns that were missed when V56 was applied with an earlier version of
  the UUIDFKColumns module.

  Specifically fixes `phoenix_kit_role_permissions` which may be missing
  `role_uuid` and `granted_by_uuid` columns if V56 was applied before
  those entries were added to UUIDFKColumns.

  All operations are idempotent — this is a safe no-op on databases where
  V56 already created everything correctly.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.UUIDFKColumns

  def up(%{prefix: prefix} = opts) do
    # Re-run UUID FK column additions (all idempotent)
    UUIDFKColumns.up(opts)

    # Re-run constraints (NOT NULL + FK, all idempotent)
    UUIDFKColumns.add_constraints(opts)

    # Re-run unique indexes for ON CONFLICT support (all idempotent)
    add_uuid_unique_indexes(prefix, opts)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '57'")
  end

  def down(%{prefix: prefix} = _opts) do
    # No-op: don't undo V56's work on rollback
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '56'")
  end

  # Same unique indexes as V56 — idempotent
  defp add_uuid_unique_indexes(prefix, opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    indexes = [
      {:phoenix_kit_user_role_assignments, [:user_uuid, :role_uuid],
       "phoenix_kit_role_assignments_user_uuid_role_uuid_idx"},
      {:phoenix_kit_role_permissions, [:role_uuid, :module_key],
       "phoenix_kit_role_permissions_role_uuid_module_key_idx"},
      {:phoenix_kit_user_oauth_providers, [:user_uuid, :provider],
       "phoenix_kit_oauth_providers_user_uuid_provider_idx"}
    ]

    for {table, columns, index_name} <- indexes do
      if table_exists?(table, escaped_prefix) do
        table_name = prefix_table_name(Atom.to_string(table), prefix)
        cols = Enum.join(columns, ", ")
        idx = if prefix && prefix != "public", do: "#{prefix}.#{index_name}", else: index_name

        execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS #{idx}
        ON #{table_name}(#{cols})
        """)
      end
    end
  end

  defp table_exists?(table, escaped_prefix) do
    table_name = Atom.to_string(table)

    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{table_name}'
      AND table_schema = '#{escaped_prefix}'
    )
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
