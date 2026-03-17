defmodule PhoenixKit.Test.Repo.Migrations.AddPhoenixKit do
  use Ecto.Migration

  def up, do: PhoenixKit.Migrations.up()

  def down, do: PhoenixKit.Migrations.down()
end
