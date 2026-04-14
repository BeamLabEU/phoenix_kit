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
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:x, :integer, null: false)
      add(:y, :integer, null: false)
      add(:w, :integer, null: false)
      add(:h, :integer, null: false)
      add(:enabled, :boolean, default: false)
      timestamps(type: :utc_datetime)

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

    create unique_index(
             :phoenix_kit_dashboard_layouts,
             [:user_uuid, :widget_uuid],
             name: :phoenix_kit_dashboard_layouts_unique_index
           )

    execute("COMMENT ON TABLE #{p}phoenix_kit_dashboard_layouts IS '97'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(index(:phoenix_kit_dashboard_layouts, [], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit_dashboard_layouts IS '97'")
  end

  defp prefix_str("public"), do: ""
  defp prefix_str(prefix), do: "#{prefix}."
end
