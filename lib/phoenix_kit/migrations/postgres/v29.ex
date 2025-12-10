defmodule PhoenixKit.Migrations.Postgres.V29 do
  @moduledoc """
  PhoenixKit V29 Migration: Posts System

  Adds complete social posts system with media attachments, comments, likes,
  tags, user groups, and scheduled publishing.

  ## Changes

  ### Posts Table (phoenix_kit_posts)
  - Main posts storage with type-specific layouts (post/snippet/repost)
  - Privacy controls (draft/public/unlisted/scheduled)
  - Denormalized counters for performance (likes, comments, views)
  - SEO-friendly slugs
  - Scheduled publishing support

  ### Post Media Junction (phoenix_kit_post_media)
  - Many-to-many between posts and files (Storage system)
  - Ordered image galleries with captions
  - Position-based ordering

  ### Post Likes (phoenix_kit_post_likes)
  - User likes on posts
  - Unique constraint per user/post

  ### Post Comments (phoenix_kit_post_comments)
  - Nested threaded comments (unlimited depth)
  - Self-referencing for comment threads
  - Depth tracking for efficient queries

  ### Post Mentions (phoenix_kit_post_mentions)
  - Tag users as contributors/mentions
  - Unique per user/post

  ### Post Tags (phoenix_kit_post_tags)
  - Hashtag system for categorization
  - Auto-slugification
  - Usage counter tracking

  ### Post Tag Assignments (phoenix_kit_post_tag_assignments)
  - Many-to-many between posts and tags

  ### Post Groups (phoenix_kit_post_groups)
  - User-created collections (Pinterest-style)
  - Public/private visibility
  - Cover images
  - Manual ordering

  ### Post Group Assignments (phoenix_kit_post_group_assignments)
  - Many-to-many between posts and groups
  - Position-based ordering within groups

  ### Post Views (phoenix_kit_post_views)
  - Analytics tracking (future feature)
  - Session-based deduplication

  ## Settings

  - Content limits: max media, title length, subtitle length, content length, mentions, tags
  - Module config: enabled, per-page, default status
  - Feature toggles: comments, likes, scheduling, groups, reposts, SEO, view counts
  - Moderation: require approval, comment moderation

  ## Features

  - UUIDv7 primary keys for time-sortable IDs
  - Comprehensive indexes for efficient queries
  - Foreign key constraints for data integrity
  - Denormalized counters to avoid expensive COUNT queries
  - Support for scheduled publishing via Oban
  - Type-specific post layouts
  """
  use Ecto.Migration

  @doc """
  Run the V29 migration to add posts system.
  """
  def up(%{prefix: prefix} = _opts) do
    # Create tables in dependency order
    create_posts_table(prefix)
    create_post_media_table(prefix)
    create_post_likes_table(prefix)
    create_post_comments_table(prefix)
    create_post_mentions_table(prefix)
    create_post_tags_table(prefix)
    create_post_tag_assignments_table(prefix)
    create_post_groups_table(prefix)
    create_post_group_assignments_table(prefix)
    create_post_views_table(prefix)

    # Seed default settings
    seed_settings(prefix)

    # Update version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '29'"
  end

  @doc """
  Rollback the V29 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop tables in reverse order (respecting foreign keys)
    drop_if_exists table(:phoenix_kit_post_views, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_group_assignments, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_groups, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_tag_assignments, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_tags, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_mentions, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_comments, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_likes, prefix: prefix)
    drop_if_exists table(:phoenix_kit_post_media, prefix: prefix)
    drop_if_exists table(:phoenix_kit_posts, prefix: prefix)

    # Remove settings
    delete_setting(prefix, "posts_max_media")
    delete_setting(prefix, "posts_max_title_length")
    delete_setting(prefix, "posts_max_subtitle_length")
    delete_setting(prefix, "posts_max_content_length")
    delete_setting(prefix, "posts_max_mentions")
    delete_setting(prefix, "posts_max_tags")
    delete_setting(prefix, "posts_enabled")
    delete_setting(prefix, "posts_per_page")
    delete_setting(prefix, "posts_default_status")
    delete_setting(prefix, "posts_comments_enabled")
    delete_setting(prefix, "posts_likes_enabled")
    delete_setting(prefix, "posts_allow_scheduling")
    delete_setting(prefix, "posts_allow_groups")
    delete_setting(prefix, "posts_allow_reposts")
    delete_setting(prefix, "posts_seo_auto_slug")
    delete_setting(prefix, "posts_show_view_count")
    delete_setting(prefix, "posts_require_approval")
    delete_setting(prefix, "posts_comment_moderation")

    # Update version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '28'"
  end

  # Private helper functions

  defp create_posts_table(prefix) do
    create_if_not_exists table(:phoenix_kit_posts, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      add :title, :string, null: false
      add :sub_title, :string
      add :content, :text, null: false
      add :type, :string, null: false, default: "post"
      add :status, :string, null: false, default: "draft"
      add :scheduled_at, :utc_datetime_usec
      add :published_at, :utc_datetime_usec
      add :repost_url, :string
      add :slug, :string, null: false
      add :like_count, :integer, default: 0, null: false
      add :comment_count, :integer, default: 0, null: false
      add :view_count, :integer, default: 0, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :naive_datetime)
    end

    # Indexes for efficient queries
    create_if_not_exists index(:phoenix_kit_posts, [:user_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_posts, [:status], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_posts, [:type], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_posts, [:slug], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_posts, [:scheduled_at], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_posts, [:published_at], prefix: prefix)

    # Composite indexes for common queries
    create_if_not_exists index(:phoenix_kit_posts, [:user_id, :status], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_posts, [:type, :status], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_posts, [:status, :published_at], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_posts", prefix)} IS
    'Social posts with media, type-specific layouts, and scheduled publishing'
    """
  end

  defp create_post_media_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_media, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :file_id,
          references(:phoenix_kit_files, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :position, :integer, null: false
      add :caption, :text

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_media, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_media, [:file_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_media, [:position], prefix: prefix)

    # Unique constraint: one position per post
    create_if_not_exists unique_index(:phoenix_kit_post_media, [:post_id, :position],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_media", prefix)} IS
    'Post media attachments junction (ordered image galleries with captions)'
    """
  end

  defp create_post_likes_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_likes, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_likes, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_likes, [:user_id], prefix: prefix)

    # Unique constraint: one like per user per post
    create_if_not_exists unique_index(:phoenix_kit_post_likes, [:post_id, :user_id],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_likes", prefix)} IS
    'User likes on posts (unique per user/post pair)'
    """
  end

  defp create_post_comments_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_comments, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      add :parent_id,
          references(:phoenix_kit_post_comments,
            on_delete: :delete_all,
            prefix: prefix,
            type: :uuid
          )

      add :content, :text, null: false
      add :status, :string, null: false, default: "published"
      add :depth, :integer, default: 0, null: false
      add :like_count, :integer, default: 0, null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_comments, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_comments, [:user_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_comments, [:parent_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_comments, [:status], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_comments, [:depth], prefix: prefix)

    # Composite index for threaded queries
    create_if_not_exists index(:phoenix_kit_post_comments, [:post_id, :parent_id, :depth],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_comments", prefix)} IS
    'Nested threaded comments with unlimited depth (self-referencing)'
    """
  end

  defp create_post_mentions_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_mentions, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      add :mention_type, :string, null: false, default: "mention"

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_mentions, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_mentions, [:user_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_mentions, [:mention_type], prefix: prefix)

    # Unique constraint: one mention per user per post
    create_if_not_exists unique_index(:phoenix_kit_post_mentions, [:post_id, :user_id],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_mentions", prefix)} IS
    'User mentions/contributors (tagged users related to post)'
    """
  end

  defp create_post_tags_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_tags, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :usage_count, :integer, default: 0, null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_tags, [:usage_count], prefix: prefix)

    # Unique constraint: case-insensitive slug
    create_if_not_exists unique_index(:phoenix_kit_post_tags, [:slug], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_tags", prefix)} IS
    'Hashtag system for post categorization (auto-slugified)'
    """
  end

  defp create_post_tag_assignments_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_tag_assignments,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :tag_id,
          references(:phoenix_kit_post_tags, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_tag_assignments, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_tag_assignments, [:tag_id], prefix: prefix)

    # Unique constraint: no duplicate tags on same post
    create_if_not_exists unique_index(:phoenix_kit_post_tag_assignments, [:post_id, :tag_id],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_tag_assignments", prefix)} IS
    'Post-Tag many-to-many junction'
    """
  end

  defp create_post_groups_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_groups, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text

      add :cover_image_id,
          references(:phoenix_kit_files, on_delete: :nilify_all, prefix: prefix, type: :uuid)

      add :post_count, :integer, default: 0, null: false
      add :is_public, :boolean, default: false, null: false
      add :position, :integer, default: 0, null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_groups, [:user_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_groups, [:is_public], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_groups, [:position], prefix: prefix)

    # Composite index for user's groups
    create_if_not_exists index(:phoenix_kit_post_groups, [:user_id, :position], prefix: prefix)

    # Unique constraint: unique slug per user
    create_if_not_exists unique_index(:phoenix_kit_post_groups, [:user_id, :slug], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_groups", prefix)} IS
    'User-created collections to organize posts (Pinterest-style boards)'
    """
  end

  defp create_post_group_assignments_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_group_assignments,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :group_id,
          references(:phoenix_kit_post_groups,
            on_delete: :delete_all,
            prefix: prefix,
            type: :uuid
          ),
          null: false

      add :position, :integer, default: 0, null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_group_assignments, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_group_assignments, [:group_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_group_assignments, [:position], prefix: prefix)

    # Composite index for group's posts ordering
    create_if_not_exists index(:phoenix_kit_post_group_assignments, [:group_id, :position],
                           prefix: prefix
                         )

    # Unique constraint: post can't be in same group twice
    create_if_not_exists unique_index(:phoenix_kit_post_group_assignments, [:post_id, :group_id],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_group_assignments", prefix)} IS
    'Post-Group many-to-many junction with position ordering'
    """
  end

  defp create_post_views_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_views, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint)

      add :ip_address, :string
      add :user_agent_hash, :string
      add :session_id, :string
      add :viewed_at, :utc_datetime_usec, null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_views, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_views, [:user_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_views, [:session_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_views, [:viewed_at], prefix: prefix)

    # Composite index for analytics queries
    create_if_not_exists index(:phoenix_kit_post_views, [:post_id, :viewed_at], prefix: prefix)

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_views", prefix)} IS
    'Analytics tracking for post views (session-based deduplication)'
    """
  end

  defp seed_settings(prefix) do
    settings = [
      # Content Limits
      %{key: "posts_max_media", value: "10"},
      %{key: "posts_max_title_length", value: "255"},
      %{key: "posts_max_subtitle_length", value: "500"},
      %{key: "posts_max_content_length", value: "50000"},
      %{key: "posts_max_mentions", value: "10"},
      %{key: "posts_max_tags", value: "20"},

      # Module Configuration
      %{key: "posts_enabled", value: "true"},
      %{key: "posts_per_page", value: "20"},
      %{key: "posts_default_status", value: "draft"},

      # Feature Toggles
      %{key: "posts_comments_enabled", value: "true"},
      %{key: "posts_likes_enabled", value: "true"},
      %{key: "posts_allow_scheduling", value: "true"},
      %{key: "posts_allow_groups", value: "true"},
      %{key: "posts_allow_reposts", value: "true"},
      %{key: "posts_seo_auto_slug", value: "true"},
      %{key: "posts_show_view_count", value: "true"},

      # Moderation
      %{key: "posts_require_approval", value: "false"},
      %{key: "posts_comment_moderation", value: "false"}
    ]

    Enum.each(settings, fn setting ->
      insert_setting(prefix, setting.key, setting.value)
    end)
  end

  defp insert_setting(prefix, key, value) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    execute """
    INSERT INTO #{prefix_table_name("phoenix_kit_settings", prefix)}
    (key, value, date_added, date_updated)
    VALUES ('#{key}', '#{value}', '#{now}', '#{now}')
    ON CONFLICT (key) DO NOTHING
    """
  end

  defp delete_setting(prefix, key) do
    execute """
    DELETE FROM #{prefix_table_name("phoenix_kit_settings", prefix)}
    WHERE key = '#{key}'
    """
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
