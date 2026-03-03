defmodule PhoenixKit.Migrations.Postgres.V75 do
  @moduledoc """
  V75: Fix missing/wrong DEFAULT on `uuid` PK columns, drop orphaned sequence.

  V72 renamed `id` → `uuid` on 30 Category A tables, but the old `id` column's
  DEFAULT was a `nextval()` sequence — that got dropped during the rename.
  This left 27 tables with no DEFAULT on `uuid`. Additionally, 4 tables
  (comments module + role_permissions) had `gen_random_uuid()` (UUIDv4) instead
  of `uuid_generate_v7()` (UUIDv7).

  While Ecto generates UUIDs in the app layer (`autogenerate: true`), a DB-level
  DEFAULT is important for:
  - Raw SQL inserts (e.g. migration scripts, manual fixes)
  - Defensive safety if Ecto doesn't provide a value

  ## Changes

  1. **Set DEFAULT uuid_generate_v7()** on 27 tables missing it (Category A)
  2. **Fix DEFAULT** on 4 tables using gen_random_uuid() → uuid_generate_v7()
  3. **Drop orphaned sequence** `phoenix_kit_id_seq` (leftover from dropped id columns)
  """

  use Ecto.Migration

  # Tables where uuid column has NO DEFAULT (Category A — V72 renamed id→uuid)
  @missing_default_tables ~w(
    phoenix_kit_buckets
    phoenix_kit_comment_dislikes
    phoenix_kit_comment_likes
    phoenix_kit_file_instances
    phoenix_kit_file_locations
    phoenix_kit_files
    phoenix_kit_post_comments
    phoenix_kit_post_dislikes
    phoenix_kit_post_groups
    phoenix_kit_post_likes
    phoenix_kit_post_media
    phoenix_kit_post_mentions
    phoenix_kit_post_tags
    phoenix_kit_post_views
    phoenix_kit_posts
    phoenix_kit_scheduled_jobs
    phoenix_kit_storage_dimensions
    phoenix_kit_ticket_attachments
    phoenix_kit_ticket_comments
    phoenix_kit_ticket_status_history
    phoenix_kit_tickets
    phoenix_kit_user_blocks
    phoenix_kit_user_blocks_history
    phoenix_kit_user_connections
    phoenix_kit_user_connections_history
    phoenix_kit_user_follows
    phoenix_kit_user_follows_history
  )

  # Tables where uuid DEFAULT is gen_random_uuid() (wrong — should be uuid_generate_v7())
  @wrong_default_tables ~w(
    phoenix_kit_comments
    phoenix_kit_comments_dislikes
    phoenix_kit_comments_likes
    phoenix_kit_role_permissions
  )

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    # Step 1: Set DEFAULT on tables missing it
    for table <- @missing_default_tables do
      if table_exists?(table, escaped_prefix) do
        execute(
          "ALTER TABLE #{prefix_table(table, prefix)} ALTER COLUMN uuid SET DEFAULT uuid_generate_v7()"
        )
      end
    end

    # Step 2: Fix wrong DEFAULT (gen_random_uuid → uuid_generate_v7)
    for table <- @wrong_default_tables do
      if table_exists?(table, escaped_prefix) do
        execute(
          "ALTER TABLE #{prefix_table(table, prefix)} ALTER COLUMN uuid SET DEFAULT uuid_generate_v7()"
        )
      end
    end

    # Step 3: Drop orphaned sequence
    execute("DROP SEQUENCE IF EXISTS #{prefix_table("phoenix_kit_id_seq", prefix)}")

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '75'")
  end

  def down(%{prefix: prefix} = _opts) do
    # Reversing defaults is not meaningful — just restore version comment
    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '74'")
  end

  # ---------------------------------------------------------------------------
  # Introspection Helpers
  # ---------------------------------------------------------------------------

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

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
