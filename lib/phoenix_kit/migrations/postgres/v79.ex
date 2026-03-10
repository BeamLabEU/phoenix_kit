defmodule PhoenixKit.Migrations.Postgres.V79 do
  @moduledoc """
  V79: Newsletters Module — Database Tables

  Creates 4 tables for the newsletter broadcast system:
  - `phoenix_kit_newsletters_lists` — Named newsletter lists for segmentation
  - `phoenix_kit_newsletters_list_members` — User membership in lists
  - `phoenix_kit_newsletters_broadcasts` — Email broadcasts (draft/sent/scheduled)
  - `phoenix_kit_newsletters_deliveries` — Per-recipient delivery tracking

  All UUIDs use `uuid_generate_v7()`. All operations are idempotent.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # =========================================================================
    # Table 1: phoenix_kit_newsletters_lists
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_lists (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      is_default BOOLEAN NOT NULL DEFAULT false,
      subscriber_count INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_lists_slug
    ON #{p}phoenix_kit_newsletters_lists (slug)
    """)

    # =========================================================================
    # Table 2: phoenix_kit_newsletters_list_members
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_list_members (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      user_uuid UUID NOT NULL,
      list_uuid UUID NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      subscribed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      unsubscribed_at TIMESTAMPTZ,
      CONSTRAINT fk_newsletters_list_members_user
        FOREIGN KEY (user_uuid)
        REFERENCES #{p}phoenix_kit_users(uuid)
        ON DELETE CASCADE,
      CONSTRAINT fk_newsletters_list_members_list
        FOREIGN KEY (list_uuid)
        REFERENCES #{p}phoenix_kit_newsletters_lists(uuid)
        ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_list_members_user_list
    ON #{p}phoenix_kit_newsletters_list_members (user_uuid, list_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_list_members_list
    ON #{p}phoenix_kit_newsletters_list_members (list_uuid)
    """)

    # =========================================================================
    # Table 3: phoenix_kit_newsletters_broadcasts
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_broadcasts (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      subject VARCHAR(998) NOT NULL,
      markdown_body TEXT,
      html_body TEXT,
      text_body TEXT,
      template_uuid UUID,
      list_uuid UUID NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      scheduled_at TIMESTAMPTZ,
      sent_at TIMESTAMPTZ,
      total_recipients INTEGER NOT NULL DEFAULT 0,
      sent_count INTEGER NOT NULL DEFAULT 0,
      delivered_count INTEGER NOT NULL DEFAULT 0,
      opened_count INTEGER NOT NULL DEFAULT 0,
      bounced_count INTEGER NOT NULL DEFAULT 0,
      created_by_user_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_newsletters_broadcasts_template
        FOREIGN KEY (template_uuid)
        REFERENCES #{p}phoenix_kit_email_templates(uuid)
        ON DELETE SET NULL,
      CONSTRAINT fk_newsletters_broadcasts_list
        FOREIGN KEY (list_uuid)
        REFERENCES #{p}phoenix_kit_newsletters_lists(uuid)
        ON DELETE RESTRICT,
      CONSTRAINT fk_newsletters_broadcasts_created_by
        FOREIGN KEY (created_by_user_uuid)
        REFERENCES #{p}phoenix_kit_users(uuid)
        ON DELETE SET NULL
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_list
    ON #{p}phoenix_kit_newsletters_broadcasts (list_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_status
    ON #{p}phoenix_kit_newsletters_broadcasts (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_scheduled_at
    ON #{p}phoenix_kit_newsletters_broadcasts (scheduled_at)
    WHERE scheduled_at IS NOT NULL
    """)

    # =========================================================================
    # Table 4: phoenix_kit_newsletters_deliveries
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_deliveries (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      broadcast_uuid UUID NOT NULL,
      user_uuid UUID NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'pending',
      sent_at TIMESTAMPTZ,
      delivered_at TIMESTAMPTZ,
      opened_at TIMESTAMPTZ,
      error TEXT,
      message_id VARCHAR(255),
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_newsletters_deliveries_broadcast
        FOREIGN KEY (broadcast_uuid)
        REFERENCES #{p}phoenix_kit_newsletters_broadcasts(uuid)
        ON DELETE CASCADE,
      CONSTRAINT fk_newsletters_deliveries_user
        FOREIGN KEY (user_uuid)
        REFERENCES #{p}phoenix_kit_users(uuid)
        ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_broadcast
    ON #{p}phoenix_kit_newsletters_deliveries (broadcast_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_user
    ON #{p}phoenix_kit_newsletters_deliveries (user_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_deliveries_message_id
    ON #{p}phoenix_kit_newsletters_deliveries (message_id)
    WHERE message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_status
    ON #{p}phoenix_kit_newsletters_deliveries (status)
    """)

    # Version marker
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '79'")
  end

  def down(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_deliveries CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_broadcasts CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_list_members CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_lists CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '78'")
  end

  defp prefix_str(nil), do: ""
  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
