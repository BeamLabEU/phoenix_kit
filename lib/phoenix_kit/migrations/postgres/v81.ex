defmodule PhoenixKit.Migrations.Postgres.V81 do
  @moduledoc """
  V81: Add position column to entity_data for manual reordering support.

  Adds an integer `position` column to `phoenix_kit_entity_data` that enables
  manual record ordering per entity. Auto-populated for existing records based
  on creation date (earliest = 1). New records auto-populate via application code.

  The entity's `settings` JSONB stores a `sort_mode` key ("auto" or "manual")
  that controls whether queries sort by `date_created` or `position`.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")

    if table_exists?(:phoenix_kit_entity_data, prefix) do
      alter table(:phoenix_kit_entity_data, prefix: prefix) do
        add_if_not_exists :position, :integer
      end

      # Backfill positions based on creation order (oldest = 1) per entity
      execute """
      WITH ranked AS (
        SELECT uuid,
               ROW_NUMBER() OVER (
                 PARTITION BY entity_uuid
                 ORDER BY date_created ASC
               ) AS rn
        FROM #{prefix_str(prefix)}phoenix_kit_entity_data
        WHERE position IS NULL
      )
      UPDATE #{prefix_str(prefix)}phoenix_kit_entity_data ed
      SET position = ranked.rn
      FROM ranked
      WHERE ed.uuid = ranked.uuid
      """

      create_if_not_exists index(:phoenix_kit_entity_data, [:entity_uuid, :position],
                             name: :phoenix_kit_entity_data_entity_position_idx,
                             prefix: prefix
                           )
    end

    execute "COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '81'"
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")

    if table_exists?(:phoenix_kit_entity_data, prefix) do
      drop_if_exists index(:phoenix_kit_entity_data, [:entity_uuid, :position],
                       name: :phoenix_kit_entity_data_entity_position_idx,
                       prefix: prefix
                     )

      alter table(:phoenix_kit_entity_data, prefix: prefix) do
        remove_if_exists :position, :integer
      end
    end

    execute "COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '80'"
  end

  defp table_exists?(table_name, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = '#{prefix}'
      AND table_name = '#{table_name}'
    )
    """

    %{rows: [[exists]]} = PhoenixKit.RepoHelper.repo().query!(query)
    exists
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
