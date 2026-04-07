defmodule PhoenixKit.Migrations.Postgres.V94 do
  @moduledoc """
  V94: Add google_doc_id and status columns to Document Creator tables.

  Adds columns needed for local DB mirroring of Google Drive file metadata:
  - `google_doc_id` (VARCHAR(255)) on templates, documents, and headers_footers
  - `status` (VARCHAR(20), DEFAULT 'published') on documents (templates already have it)
  - Partial unique indexes on `google_doc_id WHERE google_doc_id IS NOT NULL`

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    # 1. Add google_doc_id to phoenix_kit_doc_templates
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_templates'
          AND column_name = 'google_doc_id'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_doc_templates
          ADD COLUMN google_doc_id VARCHAR(255);
      END IF;
    END $$;
    """)

    # 2. Add google_doc_id to phoenix_kit_doc_documents
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_documents'
          AND column_name = 'google_doc_id'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_doc_documents
          ADD COLUMN google_doc_id VARCHAR(255);
      END IF;
    END $$;
    """)

    # 3. Add status to phoenix_kit_doc_documents
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_documents'
          AND column_name = 'status'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_doc_documents
          ADD COLUMN status VARCHAR(20) DEFAULT 'published';
      END IF;
    END $$;
    """)

    # 4. Add google_doc_id to phoenix_kit_doc_headers_footers
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_headers_footers'
          AND column_name = 'google_doc_id'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_doc_headers_footers
          ADD COLUMN google_doc_id VARCHAR(255);
      END IF;
    END $$;
    """)

    # 5. Partial unique indexes on google_doc_id (only for non-null values)
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_doc_templates'
          AND indexname = 'phoenix_kit_doc_templates_google_doc_id_unique_idx'
      ) THEN
        CREATE UNIQUE INDEX phoenix_kit_doc_templates_google_doc_id_unique_idx
          ON #{p}phoenix_kit_doc_templates (google_doc_id)
          WHERE google_doc_id IS NOT NULL;
      END IF;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_doc_documents'
          AND indexname = 'phoenix_kit_doc_documents_google_doc_id_unique_idx'
      ) THEN
        CREATE UNIQUE INDEX phoenix_kit_doc_documents_google_doc_id_unique_idx
          ON #{p}phoenix_kit_doc_documents (google_doc_id)
          WHERE google_doc_id IS NOT NULL;
      END IF;
    END $$;
    """)

    # 6. Status index on documents
    create_if_not_exists(index(:phoenix_kit_doc_documents, [:status], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '94'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(index(:phoenix_kit_doc_documents, [:status], prefix: prefix))

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_doc_documents_google_doc_id_unique_idx")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_doc_templates_google_doc_id_unique_idx")

    execute("ALTER TABLE #{p}phoenix_kit_doc_headers_footers DROP COLUMN IF EXISTS google_doc_id")
    execute("ALTER TABLE #{p}phoenix_kit_doc_documents DROP COLUMN IF EXISTS status")
    execute("ALTER TABLE #{p}phoenix_kit_doc_documents DROP COLUMN IF EXISTS google_doc_id")
    execute("ALTER TABLE #{p}phoenix_kit_doc_templates DROP COLUMN IF EXISTS google_doc_id")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '93'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
