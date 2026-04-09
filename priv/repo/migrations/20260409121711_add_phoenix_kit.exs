defmodule PhoenixKit.Repo.Migrations.AddPhoenixKit do
  use Ecto.Migration

  def up do
    PhoenixKit.Migrations.up()
  end

  def down do
    PhoenixKit.Migrations.down()
  end
end
