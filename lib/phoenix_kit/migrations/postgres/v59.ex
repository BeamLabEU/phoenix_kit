defmodule PhoenixKit.Migrations.Postgres.V59 do
  @moduledoc """
  V59: Publishing Module — Database Tables

  Creates core publishing tables (4 tables) to support the filesystem-to-database
  migration of the Publishing module. Social features (likes, views) are deferred
  to later migrations.

  ## Tables

  - `phoenix_kit_publishing_groups` — Content groups (blog, faq, legal, etc.)
  - `phoenix_kit_publishing_posts` — Posts within groups
  - `phoenix_kit_publishing_versions` — Version history per post
  - `phoenix_kit_publishing_contents` — Per-language content per version

  ## Design

  - JSONB `data` column on every table for extensibility without future migrations
  - Real columns for indexed/queried/FK fields (status, slug, language, dates)
  - UUID v7 primary keys with `uuid_generate_v7()` default
  - Dual-write user FKs: `created_by_uuid` (UUID, FK) + `created_by_id` (bigint, no FK)
  - All timestamps use `timestamptz` (per V58 standardization)
  - One content row per language (mirrors filesystem one-file-per-language model)
  - Per-group feature toggles stored in `data` JSONB (comments_enabled, likes_enabled, etc.)

  ## Idempotency

  All CREATE TABLE and CREATE INDEX use IF NOT EXISTS. Safe to re-run.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # =========================================================================
    # Table 1: phoenix_kit_publishing_groups
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_groups (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      mode VARCHAR(20) NOT NULL DEFAULT 'timestamp',
      position INTEGER NOT NULL DEFAULT 0,
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_groups_slug
    ON #{prefix_str}phoenix_kit_publishing_groups (slug)
    """)

    # =========================================================================
    # Table 2: phoenix_kit_publishing_posts
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_posts (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      group_id UUID NOT NULL,
      slug VARCHAR(500) NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      mode VARCHAR(20) NOT NULL DEFAULT 'timestamp',
      primary_language VARCHAR(10) NOT NULL DEFAULT 'en',
      published_at TIMESTAMPTZ,
      scheduled_at TIMESTAMPTZ,
      post_date DATE,
      post_time TIME,
      created_by_uuid UUID,
      created_by_id BIGINT,
      updated_by_uuid UUID,
      updated_by_id BIGINT,
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_publishing_posts_group
        FOREIGN KEY (group_id)
        REFERENCES #{prefix_str}phoenix_kit_publishing_groups(uuid)
        ON DELETE CASCADE,
      CONSTRAINT fk_publishing_posts_created_by
        FOREIGN KEY (created_by_uuid)
        REFERENCES #{prefix_str}phoenix_kit_users(uuid)
        ON DELETE SET NULL,
      CONSTRAINT fk_publishing_posts_updated_by
        FOREIGN KEY (updated_by_uuid)
        REFERENCES #{prefix_str}phoenix_kit_users(uuid)
        ON DELETE SET NULL
    )
    """)

    # Unique constraint: (group_id, slug)
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_slug
    ON #{prefix_str}phoenix_kit_publishing_posts (group_id, slug)
    """)

    # FK index for group_id
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_id
    ON #{prefix_str}phoenix_kit_publishing_posts (group_id)
    """)

    # Filter by status within a group
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_status
    ON #{prefix_str}phoenix_kit_publishing_posts (group_id, status)
    """)

    # Sort by published_at descending within a group
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_published_at
    ON #{prefix_str}phoenix_kit_publishing_posts (group_id, published_at DESC)
    """)

    # Timestamp-mode ordering (partial index — only for posts with post_date)
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_date_time
    ON #{prefix_str}phoenix_kit_publishing_posts (group_id, post_date DESC, post_time DESC)
    WHERE post_date IS NOT NULL
    """)

    # Scheduled publishing lookup (partial index — only scheduled posts)
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_scheduled
    ON #{prefix_str}phoenix_kit_publishing_posts (scheduled_at)
    WHERE status = 'scheduled'
    """)

    # FK indexes for user references
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_created_by
    ON #{prefix_str}phoenix_kit_publishing_posts (created_by_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_updated_by
    ON #{prefix_str}phoenix_kit_publishing_posts (updated_by_uuid)
    """)

    # =========================================================================
    # Table 3: phoenix_kit_publishing_versions
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_versions (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      post_id UUID NOT NULL,
      version_number INTEGER NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      created_by_uuid UUID,
      created_by_id BIGINT,
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_publishing_versions_post
        FOREIGN KEY (post_id)
        REFERENCES #{prefix_str}phoenix_kit_publishing_posts(uuid)
        ON DELETE CASCADE,
      CONSTRAINT fk_publishing_versions_created_by
        FOREIGN KEY (created_by_uuid)
        REFERENCES #{prefix_str}phoenix_kit_users(uuid)
        ON DELETE SET NULL
    )
    """)

    # Unique constraint: (post_id, version_number)
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_versions_post_number
    ON #{prefix_str}phoenix_kit_publishing_versions (post_id, version_number)
    """)

    # FK index for post_id
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_versions_post_id
    ON #{prefix_str}phoenix_kit_publishing_versions (post_id)
    """)

    # Filter by status within a post
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_versions_post_status
    ON #{prefix_str}phoenix_kit_publishing_versions (post_id, status)
    """)

    # FK index for created_by
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_versions_created_by
    ON #{prefix_str}phoenix_kit_publishing_versions (created_by_uuid)
    """)

    # =========================================================================
    # Table 4: phoenix_kit_publishing_contents
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_contents (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      version_id UUID NOT NULL,
      language VARCHAR(10) NOT NULL,
      title VARCHAR(500) NOT NULL,
      content TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      url_slug VARCHAR(500),
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_publishing_contents_version
        FOREIGN KEY (version_id)
        REFERENCES #{prefix_str}phoenix_kit_publishing_versions(uuid)
        ON DELETE CASCADE
    )
    """)

    # Unique constraint: (version_id, language)
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_contents_version_language
    ON #{prefix_str}phoenix_kit_publishing_contents (version_id, language)
    """)

    # FK index for version_id
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_contents_version_id
    ON #{prefix_str}phoenix_kit_publishing_contents (version_id)
    """)

    # Per-language URL slug lookup (partial index — only rows with custom url_slug)
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_contents_url_slug
    ON #{prefix_str}phoenix_kit_publishing_contents (url_slug)
    WHERE url_slug IS NOT NULL
    """)

    # GIN index for JSONB @> queries (e.g. previous_url_slugs redirect lookup)
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_contents_data_gin
    ON #{prefix_str}phoenix_kit_publishing_contents USING GIN (data)
    """)

    # =========================================================================
    # Seed default settings
    # =========================================================================

    execute("""
    INSERT INTO #{prefix_str}phoenix_kit_settings (key, value, date_added, date_updated)
    VALUES ('publishing_storage', 'filesystem', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """)

    # Record migration version
    execute("COMMENT ON TABLE #{prefix_str}phoenix_kit IS '59'")
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Drop in reverse order (contents → versions → posts → groups)
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_contents CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_versions CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_posts CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_groups CASCADE")

    # Remove setting
    execute("""
    DELETE FROM #{prefix_str}phoenix_kit_settings
    WHERE key = 'publishing_storage'
    """)

    execute("COMMENT ON TABLE #{prefix_str}phoenix_kit IS '58'")
  end
end
