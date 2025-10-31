defmodule PhoenixKit.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    Oban.Migration.init()
  end

  def down do
    drop_if_exists(table(:oban_jobs))
    drop_if_exists(table(:oban_producers))
    drop_if_exists(table(:oban_inserted_at_index_oban_jobs))
    drop_if_exists(table(:oban_state_index_oban_jobs))
    drop_if_exists(table(:oban_queue_index_oban_jobs))
  end
end
