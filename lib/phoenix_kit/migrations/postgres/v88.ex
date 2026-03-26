defmodule PhoenixKit.Migrations.Postgres.V88 do
  @moduledoc """
  V88: Publishing schema V2 — restructure posts/versions/contents.

  Posts become a minimal routing shell. Versions become the source of truth
  for published state and metadata. Contents hold per-language title + body.

  Changes:
  - Add `active_version_uuid` to posts (FK → versions, nullable)
  - Add `trashed_at` to posts (replaces status-based soft delete)
  - Add `published_at` to versions (moved from posts)
  - Add `title_i18n` and `description_i18n` JSONB to groups (for future i18n)
  - Data migration: populate new columns from existing data
  - Drop legacy post columns: `scheduled_at`, `status`, `published_at`, `primary_language`, `data`
  - Drop obsolete indexes (scheduled, group_status, group_published_at)
  - Add new indexes for active_version_uuid, trashed_at, and version published_at
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # Guard: only run if publishing tables exist
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_publishing_posts'
      ) THEN
        RAISE NOTICE 'Publishing tables not found, skipping V88';
        RETURN;
      END IF;

      -- 1. Add active_version_uuid to posts
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'active_version_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD COLUMN active_version_uuid UUID;

        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD CONSTRAINT fk_publishing_posts_active_version
          FOREIGN KEY (active_version_uuid)
          REFERENCES #{p}phoenix_kit_publishing_versions(uuid)
          ON DELETE SET NULL;
      END IF;

      -- 2. Add trashed_at to posts
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'trashed_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD COLUMN trashed_at TIMESTAMPTZ;
      END IF;

      -- 3. Add published_at to versions
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_versions'
          AND column_name = 'published_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_versions
          ADD COLUMN published_at TIMESTAMPTZ;
      END IF;

      -- 4. Add translatable title/description to groups (for future i18n)
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_groups'
          AND column_name = 'title_i18n'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_groups
          ADD COLUMN title_i18n JSONB NOT NULL DEFAULT '{}';
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_groups'
          AND column_name = 'description_i18n'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_groups
          ADD COLUMN description_i18n JSONB NOT NULL DEFAULT '{}';
      END IF;

    END $$;
    """)

    # ── New indexes ────────────────────────────────────────────────

    execute("""
    CREATE INDEX IF NOT EXISTS #{p}idx_publishing_posts_active_version
    ON #{p}phoenix_kit_publishing_posts (active_version_uuid)
    WHERE active_version_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{p}idx_publishing_posts_trashed_at
    ON #{p}phoenix_kit_publishing_posts (trashed_at)
    WHERE trashed_at IS NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{p}idx_publishing_versions_published_at
    ON #{p}phoenix_kit_publishing_versions (published_at DESC)
    WHERE published_at IS NOT NULL
    """)

    # ── Data migration (BEFORE dropping legacy columns) ─────────────

    # Populate trashed_at for trashed posts
    migrate_trashed_posts(p, schema)

    # Copy published_at from post to its published version
    migrate_published_at(p, schema)

    # Set active_version_uuid for published posts
    migrate_active_version(p, schema)

    # Copy metadata from content.data and post.data → version.data
    migrate_version_data(p, schema)

    # ── Drop legacy columns (AFTER data migration) ────────────────

    drop_legacy_post_columns(p, schema)

    # ── Drop obsolete indexes ──────────────────────────────────────

    execute("DROP INDEX IF EXISTS #{p}idx_publishing_posts_scheduled")
    execute("DROP INDEX IF EXISTS #{p}idx_publishing_posts_group_status")
    execute("DROP INDEX IF EXISTS #{p}idx_publishing_posts_group_published_at")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '88'")
  end

  # WARNING: Rollback restores schema structure but data migrations are irreversible.
  # - Legacy post columns are re-added as empty (original values lost)
  # - published_at copied to versions is lost when the version column is dropped
  # - active_version_uuid linkages are lost
  # - Merged JSONB data (tags, seo, featured_image_uuid) cannot be un-merged
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_publishing_posts'
      ) THEN
        RETURN;
      END IF;

      -- Restore legacy post columns (empty — original values lost)
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'scheduled_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD COLUMN scheduled_at TIMESTAMPTZ;
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'status'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'draft';
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'published_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD COLUMN published_at TIMESTAMPTZ;
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'primary_language'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD COLUMN primary_language VARCHAR(10) NOT NULL DEFAULT 'en';
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'data'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          ADD COLUMN data JSONB NOT NULL DEFAULT '{}';
      END IF;

      -- Drop new columns
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'active_version_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          DROP COLUMN active_version_uuid;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'trashed_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts
          DROP COLUMN trashed_at;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_versions'
          AND column_name = 'published_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_versions
          DROP COLUMN published_at;
      END IF;

      -- Drop new group columns
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_groups'
          AND column_name = 'title_i18n'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_groups
          DROP COLUMN title_i18n;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_groups'
          AND column_name = 'description_i18n'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_groups
          DROP COLUMN description_i18n;
      END IF;

    END $$;
    """)

    # Drop new indexes
    execute("DROP INDEX IF EXISTS #{p}idx_publishing_posts_active_version")
    execute("DROP INDEX IF EXISTS #{p}idx_publishing_posts_trashed_at")
    execute("DROP INDEX IF EXISTS #{p}idx_publishing_versions_published_at")

    # Restore old indexes
    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_scheduled
    ON #{p}phoenix_kit_publishing_posts (scheduled_at)
    WHERE status = 'scheduled'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_status
    ON #{p}phoenix_kit_publishing_posts (group_uuid, status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_published_at
    ON #{p}phoenix_kit_publishing_posts (group_uuid, published_at DESC)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '87'")
  end

  # ── Column cleanup (runs AFTER data migration) ──────────────────

  defp drop_legacy_post_columns(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_publishing_posts'
      ) THEN
        RETURN;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'scheduled_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts DROP COLUMN scheduled_at;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'status'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts DROP COLUMN status;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'published_at'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts DROP COLUMN published_at;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'primary_language'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts DROP COLUMN primary_language;
      END IF;

      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'data'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_publishing_posts DROP COLUMN data;
      END IF;
    END $$;
    """)
  end

  # ── Data migration helpers ───────────────────────────────────────

  defp migrate_trashed_posts(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'status'
      ) THEN
        UPDATE #{p}phoenix_kit_publishing_posts
        SET trashed_at = updated_at
        WHERE status = 'trashed' AND trashed_at IS NULL;
      END IF;
    END $$;
    """)
  end

  defp migrate_published_at(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'published_at'
      ) THEN
        UPDATE #{p}phoenix_kit_publishing_versions v
        SET published_at = p.published_at
        FROM #{p}phoenix_kit_publishing_posts p
        WHERE v.post_uuid = p.uuid
          AND v.status = 'published'
          AND p.published_at IS NOT NULL
          AND v.published_at IS NULL;
      END IF;
    END $$;
    """)
  end

  defp migrate_active_version(p, schema) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'status'
      ) THEN
        UPDATE #{p}phoenix_kit_publishing_posts p
        SET active_version_uuid = v.uuid
        FROM (
          SELECT DISTINCT ON (post_uuid) post_uuid, uuid
          FROM #{p}phoenix_kit_publishing_versions
          WHERE status = 'published'
          ORDER BY post_uuid, version_number DESC
        ) v
        WHERE p.uuid = v.post_uuid
          AND p.status = 'published'
          AND p.active_version_uuid IS NULL;
      END IF;
    END $$;
    """)
  end

  defp migrate_version_data(p, schema) do
    # For each version, find the site-default language content (falling back to
    # first by language ASC), and merge its data fields into version.data.
    # Also merge post.data fields (allow_version_access, tags, seo).
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_publishing_posts'
          AND column_name = 'data'
      ) THEN
        -- Merge post.data fields into version.data
        UPDATE #{p}phoenix_kit_publishing_versions v
        SET data = v.data || jsonb_build_object(
          'allow_version_access', COALESCE(p.data->'allow_version_access', 'false'::jsonb),
          'tags', COALESCE(p.data->'tags', '[]'::jsonb),
          'seo', COALESCE(p.data->'seo', '{}'::jsonb)
        )
        FROM #{p}phoenix_kit_publishing_posts p
        WHERE v.post_uuid = p.uuid
          AND p.data != '{}'::jsonb
          AND NOT v.data ? 'tags';

        -- Merge content.data fields into version.data (from best content row)
        WITH best_content AS (
          SELECT DISTINCT ON (c.version_uuid)
            c.version_uuid,
            c.data
          FROM #{p}phoenix_kit_publishing_contents c
          JOIN #{p}phoenix_kit_publishing_versions v ON v.uuid = c.version_uuid
          JOIN #{p}phoenix_kit_publishing_posts p ON p.uuid = v.post_uuid
          WHERE c.data != '{}'::jsonb
          ORDER BY c.version_uuid,
            CASE WHEN c.language = COALESCE(p.primary_language, 'en') THEN 0 ELSE 1 END,
            c.language ASC
        )
        UPDATE #{p}phoenix_kit_publishing_versions v
        SET data = v.data || jsonb_build_object(
          'featured_image_uuid', bc.data->'featured_image_uuid',
          'description', bc.data->'description',
          'seo_title', bc.data->'seo_title',
          'excerpt', bc.data->'excerpt'
        )
        FROM best_content bc
        WHERE v.uuid = bc.version_uuid
          AND NOT v.data ? 'featured_image_uuid';

      END IF;
    END $$;
    """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
