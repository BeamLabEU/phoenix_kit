defmodule PhoenixKit.Migrations.Postgres.V62 do
  @moduledoc """
  V62: Rename UUID-type columns from `_id` suffix to `_uuid` suffix.

  Enforces the naming convention established in the UUID migration plan:
  - `_id` suffix = integer (legacy, deprecated)
  - `_uuid` suffix = UUID type

  Renames 35 columns across 25 tables in 7 module groups:
  - Posts (15 columns), Comments (4), Tickets (6), Storage (3),
    Publishing (3), Shop (3), Scheduled Jobs (1)

  Also renames 9 indexes whose names embedded the old column names,
  so they accurately reflect the columns they cover.

  All operations are idempotent — guarded by IF EXISTS checks.
  Tables that don't exist (e.g., Comments module not enabled) are
  safely skipped.
  """

  use Ecto.Migration

  @indexes_to_rename [
    # {old_name, new_name}
    # Posts
    {"phoenix_kit_post_likes_post_id_user_id_index",
     "phoenix_kit_post_likes_post_uuid_user_id_index"},
    {"phoenix_kit_post_dislikes_post_id_user_id_index",
     "phoenix_kit_post_dislikes_post_uuid_user_id_index"},
    {"phoenix_kit_post_mentions_post_id_user_id_index",
     "phoenix_kit_post_mentions_post_uuid_user_id_index"},
    {"phoenix_kit_post_media_post_id_position_index",
     "phoenix_kit_post_media_post_uuid_position_index"},
    {"phoenix_kit_post_tag_assignments_post_id_tag_id_index",
     "phoenix_kit_post_tag_assignments_post_uuid_tag_uuid_index"},
    {"phoenix_kit_post_group_assignments_post_id_group_id_index",
     "phoenix_kit_post_group_assignments_post_uuid_group_uuid_index"},
    {"phoenix_kit_comment_likes_comment_id_user_id_index",
     "phoenix_kit_comment_likes_comment_uuid_user_id_index"},
    {"phoenix_kit_comment_dislikes_comment_id_user_id_index",
     "phoenix_kit_comment_dislikes_comment_uuid_user_id_index"},
    # Storage
    {"phoenix_kit_file_instances_file_id_variant_name_index",
     "phoenix_kit_file_instances_file_uuid_variant_name_index"}
  ]

  @tables_and_columns [
    # {table, old_column, new_column}
    # Group A: Posts
    {"phoenix_kit_post_comments", "post_id", "post_uuid"},
    {"phoenix_kit_post_comments", "parent_id", "parent_uuid"},
    {"phoenix_kit_post_likes", "post_id", "post_uuid"},
    {"phoenix_kit_post_dislikes", "post_id", "post_uuid"},
    {"phoenix_kit_post_mentions", "post_id", "post_uuid"},
    {"phoenix_kit_post_media", "post_id", "post_uuid"},
    {"phoenix_kit_post_media", "file_id", "file_uuid"},
    {"phoenix_kit_post_views", "post_id", "post_uuid"},
    {"phoenix_kit_post_tag_assignments", "post_id", "post_uuid"},
    {"phoenix_kit_post_tag_assignments", "tag_id", "tag_uuid"},
    {"phoenix_kit_post_group_assignments", "post_id", "post_uuid"},
    {"phoenix_kit_post_group_assignments", "group_id", "group_uuid"},
    {"phoenix_kit_post_groups", "cover_image_id", "cover_image_uuid"},
    {"phoenix_kit_comment_likes", "comment_id", "comment_uuid"},
    {"phoenix_kit_comment_dislikes", "comment_id", "comment_uuid"},
    # Group B: Comments
    {"phoenix_kit_comments", "resource_id", "resource_uuid"},
    {"phoenix_kit_comments", "parent_id", "parent_uuid"},
    {"phoenix_kit_comments_likes", "comment_id", "comment_uuid"},
    {"phoenix_kit_comments_dislikes", "comment_id", "comment_uuid"},
    # Group C: Tickets
    {"phoenix_kit_ticket_comments", "ticket_id", "ticket_uuid"},
    {"phoenix_kit_ticket_comments", "parent_id", "parent_uuid"},
    {"phoenix_kit_ticket_attachments", "ticket_id", "ticket_uuid"},
    {"phoenix_kit_ticket_attachments", "comment_id", "comment_uuid"},
    {"phoenix_kit_ticket_attachments", "file_id", "file_uuid"},
    {"phoenix_kit_ticket_status_history", "ticket_id", "ticket_uuid"},
    # Group D: Storage
    {"phoenix_kit_file_instances", "file_id", "file_uuid"},
    {"phoenix_kit_file_locations", "bucket_id", "bucket_uuid"},
    {"phoenix_kit_file_locations", "file_instance_id", "file_instance_uuid"},
    # Group E: Publishing
    {"phoenix_kit_publishing_posts", "group_id", "group_uuid"},
    {"phoenix_kit_publishing_versions", "post_id", "post_uuid"},
    {"phoenix_kit_publishing_contents", "version_id", "version_uuid"},
    # Group F: Shop
    {"phoenix_kit_shop_categories", "image_id", "image_uuid"},
    {"phoenix_kit_shop_products", "featured_image_id", "featured_image_uuid"},
    {"phoenix_kit_shop_products", "file_id", "file_uuid"},
    # Group G: Scheduled Jobs
    {"phoenix_kit_scheduled_jobs", "resource_id", "resource_uuid"}
  ]

  def up(%{prefix: prefix} = _opts) do
    escaped_prefix = if prefix && prefix != "public", do: prefix, else: "public"
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # CRITICAL: flush pending migration commands from earlier versions
    flush()

    for {table, old_col, new_col} <- @tables_and_columns do
      execute("""
      DO $$ BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{escaped_prefix}'
          AND table_name = '#{table}'
          AND column_name = '#{old_col}'
        ) THEN
          ALTER TABLE #{prefix_str}#{table} RENAME COLUMN #{old_col} TO #{new_col};
        END IF;
      END $$;
      """)
    end

    # Rename indexes to reflect new column names
    schema_prefix = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    for {old_name, new_name} <- @indexes_to_rename do
      execute("""
      DO $$ BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE schemaname = '#{escaped_prefix}'
          AND indexname = '#{old_name}'
        ) THEN
          ALTER INDEX #{schema_prefix}#{old_name} RENAME TO #{new_name};
        END IF;
      END $$;
      """)
    end

    # Update version tracking
    pk_table = if prefix_str != "", do: "#{prefix_str}phoenix_kit", else: "phoenix_kit"
    execute("COMMENT ON TABLE #{pk_table} IS '62'")
  end

  def down(%{prefix: prefix} = _opts) do
    escaped_prefix = if prefix && prefix != "public", do: prefix, else: "public"
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    flush()

    for {table, old_col, new_col} <- @tables_and_columns do
      execute("""
      DO $$ BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{escaped_prefix}'
          AND table_name = '#{table}'
          AND column_name = '#{new_col}'
        ) THEN
          ALTER TABLE #{prefix_str}#{table} RENAME COLUMN #{new_col} TO #{old_col};
        END IF;
      END $$;
      """)
    end

    # Reverse index renames
    schema_prefix = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    for {old_name, new_name} <- @indexes_to_rename do
      execute("""
      DO $$ BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE schemaname = '#{escaped_prefix}'
          AND indexname = '#{new_name}'
        ) THEN
          ALTER INDEX #{schema_prefix}#{new_name} RENAME TO #{old_name};
        END IF;
      END $$;
      """)
    end

    # Restore version tracking
    pk_table = if prefix_str != "", do: "#{prefix_str}phoenix_kit", else: "phoenix_kit"
    execute("COMMENT ON TABLE #{pk_table} IS '61'")
  end
end
