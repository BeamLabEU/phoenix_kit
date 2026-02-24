defmodule PhoenixKit.Migrations.Postgres.V62 do
  @moduledoc """
  V62 — Rename UUID-type columns from `_id` suffix to `_uuid` suffix.

  Enforces the naming convention: `_id` = integer (legacy), `_uuid` = UUID.
  All 35 operations are idempotent (guarded by column existence checks).

  ## Groups

  - A: Posts module (11 tables, 15 renames)
  - B: Comments module (3 tables, 4 renames)
  - C: Tickets module (3 tables, 6 renames)
  - D: Storage module (2 tables, 3 renames)
  - E: Publishing module (3 tables, 3 renames)
  - F: Shop module (2 tables, 3 renames)
  - G: Scheduled Jobs (1 table, 1 rename)
  """

  use Ecto.Migration

  @tables_and_columns [
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
    # Group B: Comments (may not exist if module not enabled)
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
    # Group E: Publishing (may not exist if module not enabled)
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

    # CRITICAL: flush pending migration commands before using repo().query()
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

    execute("COMMENT ON TABLE #{prefix_str}phoenix_kit IS '62'")
  end

  def down(%{prefix: prefix} = _opts) do
    escaped_prefix = if prefix && prefix != "public", do: prefix, else: "public"
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    flush()

    for {table, old_col, new_col} <- Enum.reverse(@tables_and_columns) do
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

    execute("COMMENT ON TABLE #{prefix_str}phoenix_kit IS '61'")
  end
end
