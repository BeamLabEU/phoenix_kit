defmodule PhoenixKit.Migrations.Postgres.V55 do
  @moduledoc """
  V55: Standalone Comments Module

  Creates polymorphic comments tables decoupled from the Posts module.
  Comments can be attached to any resource type via `resource_type` + `resource_id`.

  ## Tables

  - `phoenix_kit_comments` — threaded comments with polymorphic resource association
  - `phoenix_kit_comments_likes` — comment like tracking
  - `phoenix_kit_comments_dislikes` — comment dislike tracking

  ## Design

  - Polymorphic: `resource_type` (varchar) + `resource_id` (uuid), no FK constraints
  - Self-referencing `parent_id` for unlimited threading depth
  - Counter caches for `like_count` and `dislike_count`
  - Status-based moderation (published/hidden/deleted/pending)
  - Old `phoenix_kit_post_comments` tables remain untouched
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""
    schema_name = if prefix && prefix != "public", do: prefix, else: "public"

    # Step 1: Create phoenix_kit_comments table
    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_comments (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      resource_type VARCHAR(50) NOT NULL,
      resource_id UUID NOT NULL,
      user_id BIGINT,
      parent_id UUID,
      content TEXT NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'published',
      depth INTEGER NOT NULL DEFAULT 0,
      like_count INTEGER NOT NULL DEFAULT 0,
      dislike_count INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_comments_user
        FOREIGN KEY (user_id) REFERENCES #{prefix_str}phoenix_kit_users(id) ON DELETE SET NULL,
      CONSTRAINT fk_comments_parent
        FOREIGN KEY (parent_id) REFERENCES #{prefix_str}phoenix_kit_comments(id) ON DELETE CASCADE
    )
    """

    # Step 2: Create indexes for comments
    execute """
    CREATE INDEX IF NOT EXISTS idx_comments_resource
    ON #{prefix_str}phoenix_kit_comments (resource_type, resource_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_comments_resource_status
    ON #{prefix_str}phoenix_kit_comments (resource_type, resource_id, status)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_comments_user_id
    ON #{prefix_str}phoenix_kit_comments (user_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_comments_parent_id
    ON #{prefix_str}phoenix_kit_comments (parent_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_comments_status
    ON #{prefix_str}phoenix_kit_comments (status)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_comments_inserted_at
    ON #{prefix_str}phoenix_kit_comments (inserted_at)
    """

    # Step 3: Create phoenix_kit_comments_likes table
    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_comments_likes (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      comment_id UUID NOT NULL,
      user_id BIGINT NOT NULL,
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_comments_likes_comment
        FOREIGN KEY (comment_id) REFERENCES #{prefix_str}phoenix_kit_comments(id) ON DELETE CASCADE,
      CONSTRAINT fk_comments_likes_user
        FOREIGN KEY (user_id) REFERENCES #{prefix_str}phoenix_kit_users(id) ON DELETE CASCADE,
      CONSTRAINT uq_comments_likes_comment_user
        UNIQUE (comment_id, user_id)
    )
    """

    # Step 4: Create phoenix_kit_comments_dislikes table
    execute """
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_comments_dislikes (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      comment_id UUID NOT NULL,
      user_id BIGINT NOT NULL,
      inserted_at TIMESTAMP NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_comments_dislikes_comment
        FOREIGN KEY (comment_id) REFERENCES #{prefix_str}phoenix_kit_comments(id) ON DELETE CASCADE,
      CONSTRAINT fk_comments_dislikes_user
        FOREIGN KEY (user_id) REFERENCES #{prefix_str}phoenix_kit_users(id) ON DELETE CASCADE,
      CONSTRAINT uq_comments_dislikes_comment_user
        UNIQUE (comment_id, user_id)
    )
    """

    # Step 5: Seed default settings
    execute """
    INSERT INTO #{prefix_str}phoenix_kit_settings (key, value, date_added, date_updated)
    VALUES
      ('comments_enabled', 'false', NOW(), NOW()),
      ('comments_moderation', 'false', NOW(), NOW()),
      ('comments_max_depth', '10', NOW(), NOW()),
      ('comments_max_length', '10000', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """

    # Step 6: Seed "comments" permission for Admin role
    seed_admin_comments_permission(prefix_str, schema_name)

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '55'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_comments_dislikes CASCADE"
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_comments_likes CASCADE"
    execute "DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_comments CASCADE"

    # Remove settings
    execute """
    DELETE FROM #{prefix_str}phoenix_kit_settings
    WHERE key IN ('comments_enabled', 'comments_moderation', 'comments_max_depth', 'comments_max_length')
    """

    # Remove permission
    execute """
    DELETE FROM #{prefix_str}phoenix_kit_role_permissions WHERE module_key = 'comments'
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '54'"
  end

  defp seed_admin_comments_permission(prefix_str, schema_name) do
    execute """
    DO $$
    DECLARE
      admin_role_id BIGINT;
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = '#{schema_name}' AND table_name = 'phoenix_kit_user_roles') THEN
        SELECT id INTO admin_role_id FROM #{prefix_str}phoenix_kit_user_roles WHERE name = 'Admin' LIMIT 1;

        IF admin_role_id IS NOT NULL THEN
          INSERT INTO #{prefix_str}phoenix_kit_role_permissions (role_id, module_key, inserted_at)
          VALUES (admin_role_id, 'comments', NOW())
          ON CONFLICT (role_id, module_key) DO NOTHING;
        END IF;
      END IF;
    END $$;
    """
  end
end
