defmodule PhoenixKit.Migrations.Postgres.V83 do
  @moduledoc """
  V83: Add status column to publishing_groups.

  Adds a `status` column (varchar(20), default 'active') to
  `phoenix_kit_publishing_groups` to support soft-delete via "trashed" status.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    prefix_str = if prefix != "public", do: "#{prefix}.", else: ""

    if table_exists?(:phoenix_kit_publishing_groups, prefix) do
      execute("""
      ALTER TABLE #{prefix_str}phoenix_kit_publishing_groups
      ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'active'
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS idx_publishing_groups_status
      ON #{prefix_str}phoenix_kit_publishing_groups (status)
      """)
    end
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    prefix_str = if prefix != "public", do: "#{prefix}.", else: ""

    if table_exists?(:phoenix_kit_publishing_groups, prefix) do
      execute("DROP INDEX IF EXISTS #{prefix_str}idx_publishing_groups_status")

      execute("""
      ALTER TABLE #{prefix_str}phoenix_kit_publishing_groups
      DROP COLUMN IF EXISTS status
      """)
    end
  end

  defp table_exists?(table, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = '#{prefix}'
      AND table_name = '#{table}'
    )
    """

    case PhoenixKit.RepoHelper.repo().query(query) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end
end
