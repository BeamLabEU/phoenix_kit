defmodule PhoenixKit.Migrations.Postgres.V66 do
  @moduledoc """
  V66: Make legacy user_id columns nullable on posts module tables.

  After the UUID cleanup, posts schemas only set `user_uuid` — they never
  set the legacy `user_id` bigint column. Five tables still have
  `user_id bigint NOT NULL`, causing inserts to fail with not_null_violation.

  This migration makes `user_id` nullable on all affected tables.

  ## Tables Fixed

  - `phoenix_kit_post_groups` (V29)
  - `phoenix_kit_post_comments` (V29)
  - `phoenix_kit_post_likes` (V29)
  - `phoenix_kit_post_dislikes` (V48)
  - `phoenix_kit_post_mentions` (V29)
  """

  use Ecto.Migration

  @tables [
    "phoenix_kit_post_groups",
    "phoenix_kit_post_comments",
    "phoenix_kit_post_likes",
    "phoenix_kit_post_dislikes",
    "phoenix_kit_post_mentions"
  ]

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    for table <- @tables do
      if table_exists?(table, escaped_prefix) and
           column_exists?(table, "user_id", escaped_prefix) do
        execute("""
        ALTER TABLE #{prefix_table(table, prefix)}
        ALTER COLUMN user_id DROP NOT NULL
        """)
      end
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '66'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    for table <- Enum.reverse(@tables) do
      if table_exists?(table, escaped_prefix) and
           column_exists?(table, "user_id", escaped_prefix) do
        execute("""
        ALTER TABLE #{prefix_table(table, prefix)}
        ALTER COLUMN user_id SET NOT NULL
        """)
      end
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '65'")
  end

  defp table_exists?(table, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table}'
             AND column_name = '#{column}'
             AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
