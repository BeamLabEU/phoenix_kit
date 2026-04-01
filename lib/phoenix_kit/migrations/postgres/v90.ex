defmodule PhoenixKit.Migrations.Postgres.V90 do
  @moduledoc """
  V90: Create activity feed table.

  Stores business-level activity entries: post created, comment liked,
  user registered, password changed, etc.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_if_not_exists table(:phoenix_kit_activities,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:action, :string, null: false, size: 100)
      add(:module, :string, size: 50)
      add(:actor_uuid, :uuid)
      add(:resource_type, :string, size: 50)
      add(:resource_uuid, :uuid)
      add(:target_uuid, :uuid)
      add(:metadata, :map, default: %{})
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:phoenix_kit_activities, [:actor_uuid], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_activities, [:action], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_activities, [:module], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_activities, [:resource_type], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_activities, [:target_uuid], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_activities, [:inserted_at], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_activities, [:action, :inserted_at], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_activities, [:actor_uuid, :inserted_at], prefix: prefix)
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '90'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_activities, prefix: prefix))
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '89'")
  end

  defp prefix_str("public"), do: ""
  defp prefix_str(prefix), do: "#{prefix}."
end
