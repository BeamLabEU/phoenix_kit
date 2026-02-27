defmodule PhoenixKit.Migrations.Postgres.V68 do
  @moduledoc """
  V68: Allow NULL slug for timestamp-mode publishing posts

  Timestamp-mode posts are identified by (post_date, post_time), not by slug.
  The NOT NULL constraint on slug was incorrectly applied to all modes.

  ## Changes

  1. Drop NOT NULL constraint on `slug` column in `phoenix_kit_publishing_posts`
  2. Replace unique index `idx_publishing_posts_group_slug` with a partial index
     that only enforces uniqueness for slug-mode posts (where slug IS NOT NULL)
  3. Add unique index on `(group_uuid, post_date, post_time)` for timestamp-mode posts

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    if table_exists?(:phoenix_kit_publishing_posts, escaped_prefix) do
      table = prefix_table("phoenix_kit_publishing_posts", prefix)

      # 1. Drop NOT NULL on slug
      execute("ALTER TABLE #{table} ALTER COLUMN slug DROP NOT NULL")

      # 2. Replace the unconditional unique index with a partial one (slug-mode only)
      execute("DROP INDEX IF EXISTS idx_publishing_posts_group_slug")

      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_slug
      ON #{table} (group_uuid, slug)
      WHERE slug IS NOT NULL
      """)

      # 3. Add unique constraint for timestamp-mode posts
      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_date_time_unique
      ON #{table} (group_uuid, post_date, post_time)
      WHERE post_date IS NOT NULL AND post_time IS NOT NULL
      """)
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '68'")
  end

  def down(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    if table_exists?(:phoenix_kit_publishing_posts, escaped_prefix) do
      table = prefix_table("phoenix_kit_publishing_posts", prefix)

      # Remove timestamp unique index
      execute("DROP INDEX IF EXISTS idx_publishing_posts_group_date_time_unique")

      # Restore unconditional unique index
      execute("DROP INDEX IF EXISTS idx_publishing_posts_group_slug")

      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_slug
      ON #{table} (group_uuid, slug)
      """)

      # Restore NOT NULL (generate unique placeholder slugs to avoid unique index collision)
      execute("UPDATE #{table} SET slug = 'migrated-' || uuid WHERE slug IS NULL")
      execute("ALTER TABLE #{table} ALTER COLUMN slug SET NOT NULL")
    end

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '67'")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp table_exists?(table, escaped_prefix) do
    table_name = Atom.to_string(table)

    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table_name}'
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
