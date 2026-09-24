defmodule PhoenixKit.Migrations.Postgres.V202 do
  @moduledoc """
  V202: storage libraries, the partition (phase 1 of
  `dev_docs/plans/2026-09-22-storage-libraries.md`).

  Every stored file belongs to exactly one **library**: a partition of the
  file store with its own members, settings and, later, its own storage. This
  version adds the partition and puts everything that exists into one system
  library, **Media**, so nothing changes for anyone:

    * `phoenix_kit_storage_libraries` — `kind` (`system` | `user`),
      `owner_uuid` (NULL for a system library), `visibility` (`site` |
      `private`), `key_prefix` (object-key prefix for NEW files; NULL keeps
      today's layout), `settings`, `is_default`, `trashed_at`. One row is
      seeded: Media, the default system library, under the fixed uuid
      `00000000-0000-7000-8000-000000000001` (`Storage.Libraries.media_uuid/0`).
    * `library_uuid` on `phoenix_kit_files`, `phoenix_kit_media_folders` and
      `phoenix_kit_media_folder_links`: NOT NULL, `ON DELETE RESTRICT`, and a
      column DEFAULT of Media's uuid. The default is what makes this
      invisible: existing rows read it without a table rewrite (a constant
      default is metadata-only), and every writer that does not name a
      library — core's and every module's — keeps landing in Media.
    * `UNIQUE (uuid, library_uuid)` on files, the target of the folder-link
      FK `(file_uuid, library_uuid)`: a link cannot cross libraries.
    * Folder names are unique per `(library_uuid, parent)` instead of per
      parent: `phoenix_kit_media_folders_name_parent_idx` gains a leading
      `library_uuid`. With every folder in Media this is the same rule.
    * `phoenix_kit_files_library_capture_date_index`, the capture-date index
      keyed by library. V200's user-keyed index stays for now.

  Deliberately NOT here (the plan's later phases): user libraries and
  members, any change to dedup, and the uploader FK moving to `SET NULL` —
  that one changes what deleting a user does, so it ships with the phase
  that needs it.

  ## Locks

  `NOT NULL` goes through `CHECK … NOT VALID` → `VALIDATE` → `SET NOT NULL`
  → drop the check (the V164 pattern): the validation scan holds only a
  `SHARE UPDATE EXCLUSIVE` lock, and `SET NOT NULL` then skips its own scan.
  FKs are added `NOT VALID` and validated separately for the same reason.
  Indexes are plain builds, not `CONCURRENTLY` (see V193 for why), so writes
  to `phoenix_kit_files` wait while they build.

  Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @media_uuid "00000000-0000-7000-8000-000000000001"
  @nil_uuid "00000000-0000-0000-0000-000000000000"

  @doc false
  def media_uuid, do: @media_uuid

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc """
  Rolls V202 back: drops the three `library_uuid` columns, their keys and
  indexes, restores the per-parent folder-name index and drops the libraries
  table. Which library a file was in is lost (everything is Media until a
  second library exists).
  """
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. `prefix` is the
  # bare schema name. Index names stay bare on CREATE and are qualified only
  # on DROP; every existence check is anchored to the schema.
  def up_statements(prefix) do
    p = prefix_str(prefix)

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_storage_libraries (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        name character varying(255) NOT NULL,
        kind character varying(20) DEFAULT 'system' NOT NULL,
        owner_uuid uuid,
        visibility character varying(20) DEFAULT 'site' NOT NULL,
        key_prefix character varying(64),
        settings jsonb DEFAULT '{}'::jsonb NOT NULL,
        is_default boolean DEFAULT false NOT NULL,
        trashed_at timestamp with time zone,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_storage_libraries_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_storage_libraries_owner_uuid_fkey FOREIGN KEY (owner_uuid)
          REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE RESTRICT,
        CONSTRAINT phoenix_kit_storage_libraries_kind_check
          CHECK (kind IN ('system', 'user')),
        CONSTRAINT phoenix_kit_storage_libraries_visibility_check
          CHECK (visibility IN ('site', 'private')),
        CONSTRAINT phoenix_kit_storage_libraries_owner_check
          CHECK ((kind = 'system' AND owner_uuid IS NULL) OR (kind = 'user' AND owner_uuid IS NOT NULL))
      )
      """,
      # A live name is unique per owner (system libraries share the nil owner).
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_libraries_owner_name_index
      ON #{p}phoenix_kit_storage_libraries
        (COALESCE(owner_uuid, '#{@nil_uuid}'::uuid), lower(name))
      WHERE trashed_at IS NULL
      """,
      # One default per owner: one default system library, one per user.
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_libraries_default_index
      ON #{p}phoenix_kit_storage_libraries (COALESCE(owner_uuid, '#{@nil_uuid}'::uuid))
      WHERE is_default
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_libraries_key_prefix_index
      ON #{p}phoenix_kit_storage_libraries (key_prefix)
      WHERE key_prefix IS NOT NULL
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_storage_libraries_owner_uuid_index
      ON #{p}phoenix_kit_storage_libraries (owner_uuid)
      """,
      """
      INSERT INTO #{p}phoenix_kit_storage_libraries
        (uuid, name, kind, visibility, is_default, inserted_at, updated_at)
      VALUES ('#{@media_uuid}', 'Media', 'system', 'site', true, NOW(), NOW())
      ON CONFLICT (uuid) DO NOTHING
      """
    ] ++
      library_column(p, prefix, "phoenix_kit_files", "phoenix_kit_files_library_uuid_fkey") ++
      library_column(
        p,
        prefix,
        "phoenix_kit_media_folders",
        "phoenix_kit_media_folders_library_uuid_fkey"
      ) ++
      library_column(
        p,
        prefix,
        "phoenix_kit_media_folder_links",
        "phoenix_kit_media_folder_links_library_uuid_fkey"
      ) ++
      [
        """
        CREATE INDEX IF NOT EXISTS phoenix_kit_files_library_uuid_index
        ON #{p}phoenix_kit_files (library_uuid)
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_files_uuid_library_uuid_index
        ON #{p}phoenix_kit_files (uuid, library_uuid)
        """,
        # A link names its file's library: moving a file to another library
        # carries its links along (ON UPDATE CASCADE) or fails the move.
        add_constraint(
          p,
          prefix,
          "phoenix_kit_media_folder_links",
          "phoenix_kit_media_folder_links_file_library_fkey",
          "FOREIGN KEY (file_uuid, library_uuid) REFERENCES #{p}phoenix_kit_files(uuid, library_uuid) ON UPDATE CASCADE ON DELETE CASCADE"
        ),
        "ALTER TABLE #{p}phoenix_kit_media_folder_links VALIDATE CONSTRAINT phoenix_kit_media_folder_links_file_library_fkey",
        # Folder names: unique per (library, parent) instead of per parent.
        # Rebuilt only while it still has the old shape, so a re-run does not
        # rebuild it again.
        """
        DO $$
        BEGIN
          IF EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname = '#{prefix}'
              AND indexname = 'phoenix_kit_media_folders_name_parent_idx'
              AND indexdef NOT LIKE '%library_uuid%'
          ) THEN
            DROP INDEX #{p}phoenix_kit_media_folders_name_parent_idx;
          END IF;
        END
        $$
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_media_folders_name_parent_idx
        ON #{p}phoenix_kit_media_folders
          (library_uuid, name, COALESCE(parent_uuid, '#{@nil_uuid}'::uuid))
        WHERE trashed_at IS NULL
        """,
        """
        CREATE INDEX IF NOT EXISTS phoenix_kit_files_library_capture_date_index
        ON #{p}phoenix_kit_files (library_uuid, taken_on DESC, taken_at DESC)
        WHERE system_managed = false
          AND trashed_at IS NULL
          AND parent_file_uuid IS NULL
          AND status = 'active'
          AND file_type IN ('image', 'video')
        """,
        "COMMENT ON TABLE #{p}phoenix_kit IS '202'"
      ]
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    [
      "DROP INDEX IF EXISTS #{p}phoenix_kit_files_library_capture_date_index",
      "ALTER TABLE #{p}phoenix_kit_media_folder_links DROP CONSTRAINT IF EXISTS phoenix_kit_media_folder_links_file_library_fkey",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_files_uuid_library_uuid_index",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_files_library_uuid_index",
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE schemaname = '#{prefix}'
            AND indexname = 'phoenix_kit_media_folders_name_parent_idx'
            AND indexdef LIKE '%library_uuid%'
        ) THEN
          DROP INDEX #{p}phoenix_kit_media_folders_name_parent_idx;
        END IF;
      END
      $$
      """,
      "ALTER TABLE #{p}phoenix_kit_media_folder_links DROP COLUMN IF EXISTS library_uuid",
      "ALTER TABLE #{p}phoenix_kit_media_folders DROP COLUMN IF EXISTS library_uuid",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS library_uuid",
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_media_folders_name_parent_idx
      ON #{p}phoenix_kit_media_folders (name, COALESCE(parent_uuid, '#{@nil_uuid}'::uuid))
      WHERE trashed_at IS NULL
      """,
      "DROP TABLE IF EXISTS #{p}phoenix_kit_storage_libraries",
      "COMMENT ON TABLE #{p}phoenix_kit IS '201'"
    ]
  end

  # `library_uuid` on `table`: a constant default (metadata-only for existing
  # rows), NOT NULL through a validated check, and the FK to libraries.
  defp library_column(p, prefix, table, fk_name) do
    check = "#{table}_library_uuid_not_null"

    [
      "ALTER TABLE #{p}#{table} ADD COLUMN IF NOT EXISTS library_uuid uuid DEFAULT '#{@media_uuid}'::uuid",
      add_constraint(p, prefix, table, check, "CHECK (library_uuid IS NOT NULL)"),
      "ALTER TABLE #{p}#{table} VALIDATE CONSTRAINT #{check}",
      "ALTER TABLE #{p}#{table} ALTER COLUMN library_uuid SET NOT NULL",
      "ALTER TABLE #{p}#{table} DROP CONSTRAINT IF EXISTS #{check}",
      add_constraint(
        p,
        prefix,
        table,
        fk_name,
        "FOREIGN KEY (library_uuid) REFERENCES #{p}phoenix_kit_storage_libraries(uuid) ON DELETE RESTRICT"
      ),
      "ALTER TABLE #{p}#{table} VALIDATE CONSTRAINT #{fk_name}"
    ]
  end

  # Adds a constraint `NOT VALID` unless the table already has one of that
  # name — checked by name through pg_class + pg_namespace, never
  # `'…'::regclass`, which raises when the relation is missing.
  defp add_constraint(p, prefix, table, name, definition) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}#{table} ADD CONSTRAINT #{name} #{definition} NOT VALID;
      END IF;
    END
    $$
    """
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
