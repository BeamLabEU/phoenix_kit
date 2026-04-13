defmodule PhoenixKit.Migrations.Postgres.V97 do
  @moduledoc """
  V97: Add dashboard_widgets
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Folders table
    create_if_not_exists table(:phoenix_kit_dashboard_layouts,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:widget_uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:x, :integer, null: false)
      add(:y, :integer, null: false)
      add(:w, :integer, null: false)
      add(:h, :integer, null: false)
      add(:enabled, :boolean, default: false)

      add(
        :user_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :nothing,
          prefix: prefix
        )
      )
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '97'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(index(:phoenix_kit_files, [:folder_uuid], prefix: prefix))

    alter table(:phoenix_kit_files, prefix: prefix) do
      remove_if_exists(:folder_uuid, :uuid)
    end

    drop_if_exists(table(:phoenix_kit_media_folder_links, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_media_folders, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '94'")
  end

  defp prefix_str("public"), do: ""
  defp prefix_str(prefix), do: "#{prefix}."
end
