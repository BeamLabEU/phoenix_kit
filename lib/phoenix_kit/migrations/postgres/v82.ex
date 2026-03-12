defmodule PhoenixKit.Migrations.Postgres.V82 do
  @moduledoc """
  V82: Add metadata JSONB column to comments.

  Adds a `metadata` column (jsonb, default '{}') to `phoenix_kit_comments`
  so parent projects can store arbitrary extra data (giphy reactions, custom
  flags, rich embeds, etc.) without schema changes.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")

    if table_exists?(:phoenix_kit_comments, prefix) do
      alter table(:phoenix_kit_comments, prefix: prefix) do
        add_if_not_exists :metadata, :map, default: %{}
      end
    end

    execute "COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '82'"
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")

    if table_exists?(:phoenix_kit_comments, prefix) do
      alter table(:phoenix_kit_comments, prefix: prefix) do
        remove_if_exists :metadata, :map
      end
    end

    execute "COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '81'"
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
