defmodule PhoenixKit.Migrations.Postgres.V97 do
  @moduledoc """
  V97: Reserved.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = if prefix == "public", do: "public.", else: "#{prefix}."

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '97'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = if prefix == "public", do: "public.", else: "#{prefix}."

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '96'")
  end
end
