defmodule PhoenixKit.Migrations.Postgres.V135BaselineSchemaTest do
  @moduledoc """
  Final-shape schema pins carried forward from the deleted `V107Test`,
  `V112Test`, `V113Test`, and `V125Test` (squash floor 135 — spec
  `dev_docs/plans/2026-07-14-squash-migrations-spec.md` §5.3).

  V107/V112/V113/V125 are all below the floor and no longer exist as
  standalone migration modules — their DDL now lives, final-state only,
  inside `PhoenixKit.Migrations.Postgres.V135`. What those test files
  pinned was never the migration MECHANISM (none of them could invoke
  `up/1`/`down/1` outside an `Ecto.Migrator` runner in the first place —
  see their now-deleted moduledocs) but the resulting DB shape, verified
  at boot through `test_helper.exs`'s `ensure_current/2`. That shape is
  unchanged by the squash (verified separately by the generator's S1
  dump-diff against the pre-squash chain, `dev_docs/squash/verify.exs`),
  so these assertions are moved here verbatim rather than deleted —
  losing them would silently drop coverage for column types, index
  predicates, FK delete actions, and CHECK-constraint enforcement that
  the manifest's own structural `check:` SQL does not exercise at `mix
  test` time (that only runs live via `mix phoenix_kit.repair`/the
  squash verification harness).

  NOT carried forward (see `dev_docs/plans/2026-07-14-squash-inventory.md`,
  "What the squash changed" for the full accounting):

    * `V106Test` — pinned `V106.down/1`'s cross-mode-duplicate pre-check
      SQL, a migration-rollback mechanism that no longer exists as a
      distinct step once V106 is folded into the V135 baseline (the
      baseline's own `down/1` tears down the whole slice, it does not
      replay V106's granular pre-check). The FINAL fact it protected —
      `phoenix_kit_projects` has no unique-name index left — is already
      encoded by omission in the generated manifest (confirmed by
      `dev_docs/squash/output/generation_report.md`'s "Dropped along the
      chain" list, which names `phoenix_kit_projects_name_index` /
      `_name_template_index` / `_name_project_index` explicitly) and by
      this file's own "dropped unique-name indexes" tests below.
    * `V107Test`'s backfill-correctness describes (`integration_uuid`
      backfill from `phoenix_kit_settings`) — pure upgrade-only data
      rewrite (D7: zero historical backfills in the baseline); a fresh
      floor-135 install has no legacy rows to backfill and no lasting
      invariant to assert (unlike V114, below, `integration_uuid` may
      legitimately be NULL forever). Its schema-shape describes ARE kept.
    * `V114Test` — entirely upgrade-only data-rewrite logic (composite-key
      `integration:<provider>:<name>` → uuid-only storage), unreachable
      at floor 135. The END-STATE invariant it protected ("no composite
      `integration:*` keys remain") is already a generator-emitted
      `data_invariant` in `PhoenixKit.Migrations.ExpectedSchema` (`since:
      114`), checked by `mix phoenix_kit.repair`/verify, not by this file.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp insert_project!(name, is_template) do
    %{rows: [[uuid_bin]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_projects (name, is_template)
        VALUES ($1, $2)
        RETURNING uuid
        """,
        [name, is_template]
      )

    Ecto.UUID.cast!(uuid_bin)
  end

  defp insert_endpoint!(name, provider) do
    %{rows: [[uuid_bin]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_ai_endpoints (
          name, provider, model, api_key, enabled, inserted_at, updated_at
        )
        VALUES ($1, $2, 'anthropic/claude-3-haiku', '', true, NOW(), NOW())
        RETURNING uuid
        """,
        [name, provider]
      )

    Ecto.UUID.cast!(uuid_bin)
  end

  defp column(table, column) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    case rows do
      [[data_type, is_nullable, default]] ->
        %{type: data_type, nullable: is_nullable, default: default}

      [] ->
        nil
    end
  end

  defp column_data_type(table, column), do: column(table, column).type

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)", [name])

    exists
  end

  defp constraint_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = $1)", [name])

    exists
  end

  # Returns the ON DELETE action ('a' no action, 'r' restrict, 'c' cascade,
  # 'n' set null, 'd' set default) for a named FK constraint.
  defp fk_delete_rule(constraint_name) do
    %{rows: rows} =
      Repo.query!("SELECT confdeltype FROM pg_constraint WHERE conname = $1", [constraint_name])

    case rows do
      [[rule]] -> rule
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # From V107Test — phoenix_kit_ai_endpoints.integration_uuid + name uniqueness
  # ---------------------------------------------------------------------------

  describe "ai_endpoints integration_uuid (from V107)" do
    test "the integration_uuid column exists" do
      %{rows: [[exists]]} =
        Repo.query!("""
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'phoenix_kit_ai_endpoints'
            AND column_name = 'integration_uuid'
        )
        """)

      assert exists == true
    end

    test "the integration_uuid index exists" do
      assert index_exists?("phoenix_kit_ai_endpoints_integration_uuid_index")
    end

    test "the unique name index exists" do
      assert index_exists?("phoenix_kit_ai_endpoints_name_index")
    end

    test "duplicate endpoint names are rejected by the UNIQUE constraint" do
      _first = insert_endpoint!("Claude Haiku", "openrouter")

      assert_raise Postgrex.Error, ~r/duplicate key value violates/, fn ->
        insert_endpoint!("Claude Haiku", "openrouter")
      end
    end

    test "case-only differences in endpoint names collide (lower(name) index)" do
      _first = insert_endpoint!("Claude Haiku", "openrouter")

      assert_raise Postgrex.Error, ~r/duplicate key value violates/, fn ->
        insert_endpoint!("CLAUDE HAIKU", "openrouter")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # From V112Test — phoenix_kit_projects archived_at/translations/position/etc
  # ---------------------------------------------------------------------------

  describe "projects archived_at column (from V112)" do
    test "exists on phoenix_kit_projects, nullable, timestamp without time zone" do
      assert %{type: "timestamp without time zone", nullable: "YES"} =
               column("phoenix_kit_projects", "archived_at")
    end
  end

  describe "projects visible-set partial index (from V112)" do
    test "phoenix_kit_projects_visible_idx exists with predicate archived_at IS NULL only" do
      assert index_exists?("phoenix_kit_projects_visible_idx")

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_projects_visible_idx'
        """)

      assert indexdef =~ "WHERE (archived_at IS NULL)"
      refute indexdef =~ "is_template"
    end
  end

  describe "translations JSONB columns (from V112)" do
    for table <-
          ~w(phoenix_kit_projects phoenix_kit_project_tasks phoenix_kit_project_assignments) do
      test "exists on #{table} as JSONB NOT NULL DEFAULT '{}'" do
        assert %{type: "jsonb", nullable: "NO", default: default} =
                 column(unquote(table), "translations")

        assert default =~ ~r/'\{\}'::jsonb/
      end
    end
  end

  describe "scheduled_start_date retype (from V112)" do
    test "is timestamp(0), not date" do
      assert column_data_type("phoenix_kit_projects", "scheduled_start_date") ==
               "timestamp without time zone"
    end
  end

  describe "position columns (from V112)" do
    for table <- ~w(phoenix_kit_projects phoenix_kit_project_tasks) do
      test "exists on #{table} as INTEGER NOT NULL DEFAULT 0" do
        assert %{type: "integer", nullable: "NO", default: "0"} =
                 column(unquote(table), "position")
      end
    end
  end

  describe "dropped unique-name indexes (from V106/V112)" do
    test "V106's template partial index is gone" do
      refute index_exists?("phoenix_kit_projects_name_template_index")
    end

    test "V106's project partial index is gone" do
      refute index_exists?("phoenix_kit_projects_name_project_index")
    end

    test "V101's global unique-name index is gone (V106 already dropped it)" do
      refute index_exists?("phoenix_kit_projects_name_index")
    end

    test "V101's task-title unique index is gone" do
      refute index_exists?("phoenix_kit_project_tasks_title_index")
    end
  end

  describe "duplicate-name behavior (from V112)" do
    test "templates and real projects can share a name" do
      _template_uuid = insert_project!("Onboarding", true)
      _project_uuid = insert_project!("Onboarding", false)
    end

    test "two templates with the same name coexist" do
      first = insert_project!("Quarterly Review", true)
      second = insert_project!("Quarterly Review", true)

      assert first != second
    end

    test "two real projects with the same name coexist" do
      first = insert_project!("Q4 Planning", false)
      second = insert_project!("Q4 Planning", false)

      assert first != second
    end

    test "case-only differences are allowed (no lower(name) index left)" do
      first = insert_project!("Onboarding", true)
      second = insert_project!("ONBOARDING", true)

      assert first != second
    end
  end

  # ---------------------------------------------------------------------------
  # From V113Test — phoenix_kit_files system_managed/parent_file_uuid + comment_media
  # ---------------------------------------------------------------------------

  describe "files system_managed column (from V113)" do
    test "exists on phoenix_kit_files as BOOLEAN NOT NULL DEFAULT false" do
      assert %{type: "boolean", nullable: "NO", default: "false"} =
               column("phoenix_kit_files", "system_managed")
    end
  end

  describe "files parent_file_uuid column + self-FK (from V113)" do
    test "exists as nullable UUID" do
      assert %{type: "uuid", nullable: "YES"} = column("phoenix_kit_files", "parent_file_uuid")
    end

    test "FK constraint cascades on delete" do
      assert constraint_exists?("phoenix_kit_files_parent_file_uuid_fkey")
      assert fk_delete_rule("phoenix_kit_files_parent_file_uuid_fkey") == "c"
    end
  end

  describe "files user_uuid NOT NULL dropped (from V113)" do
    test "is now nullable on phoenix_kit_files" do
      assert %{nullable: "YES"} = column("phoenix_kit_files", "user_uuid")
    end
  end

  describe "files indexes (from V113)" do
    test "parent_uuid index exists (partial: WHERE parent_file_uuid IS NOT NULL)" do
      assert index_exists?("phoenix_kit_files_parent_uuid_index")

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_files_parent_uuid_index'
        """)

      assert indexdef =~ "WHERE (parent_file_uuid IS NOT NULL)"
    end

    test "system_managed index exists (partial: WHERE system_managed = false)" do
      assert index_exists?("phoenix_kit_files_system_managed_index")

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_files_system_managed_index'
        """)

      assert indexdef =~ "WHERE (system_managed = false)"
    end

    test "system_dedup partial unique index exists on (parent_file_uuid, file_name)" do
      assert index_exists?("phoenix_kit_files_system_dedup_index")

      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE indexname = 'phoenix_kit_files_system_dedup_index'
        """)

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "parent_file_uuid"
      assert indexdef =~ "file_name"
      assert indexdef =~ "WHERE (system_managed = true)"
    end
  end

  describe "files CHECK constraint: user_uuid OR parent_file_uuid (from V113)" do
    test "constraint exists" do
      assert constraint_exists?("phoenix_kit_files_user_or_parent_check")
    end

    test "row with both user_uuid and parent_file_uuid NULL is rejected" do
      # Bypass the changeset; this test exists specifically to verify the
      # DB enforces the invariant when raw SQL bypasses Elixir validation.
      assert_raise Postgrex.Error, ~r/phoenix_kit_files_user_or_parent_check/, fn ->
        Repo.query!("""
        INSERT INTO phoenix_kit_files (
          uuid, original_file_name, file_name, file_path, mime_type,
          file_type, ext, file_checksum, user_file_checksum, size,
          status, system_managed, inserted_at, updated_at
        ) VALUES (
          uuid_generate_v7(), 'orphan.bin', 'orphan.bin', '/', 'application/octet-stream',
          'other', '.bin', 'x', 'x', 1,
          'active', false, NOW(), NOW()
        )
        """)
      end
    end
  end

  describe "phoenix_kit_comment_media junction table (from V113)" do
    test "table exists" do
      %{rows: [[exists]]} =
        Repo.query!("""
        SELECT EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_name = 'phoenix_kit_comment_media'
        )
        """)

      assert exists == true
    end

    test "unique index on (comment_uuid, position) exists" do
      assert index_exists?("phoenix_kit_comment_media_comment_position_index")
    end

    test "secondary index on file_uuid exists" do
      %{rows: [[count]]} =
        Repo.query!("""
        SELECT count(*) FROM pg_indexes
        WHERE tablename = 'phoenix_kit_comment_media'
          AND indexdef ~ 'file_uuid'
          AND indexname != 'phoenix_kit_comment_media_pkey'
        """)

      assert count >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # From V125Test — phoenix_kit_project_statuses + projects catalog columns
  # ---------------------------------------------------------------------------

  describe "phoenix_kit_project_statuses table (from V125)" do
    test "exists with the expected columns" do
      assert %{type: "uuid", nullable: "NO"} = column("phoenix_kit_project_statuses", "uuid")

      assert %{type: "uuid", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "project_uuid")

      assert %{type: "character varying", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "label")

      assert %{type: "character varying", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "slug")

      assert %{type: "integer", nullable: "NO", default: "0"} =
               column("phoenix_kit_project_statuses", "position")

      assert %{type: "jsonb", nullable: "NO"} = column("phoenix_kit_project_statuses", "data")

      assert %{type: "jsonb", nullable: "NO"} =
               column("phoenix_kit_project_statuses", "translations")

      assert %{type: "uuid", nullable: "YES"} =
               column("phoenix_kit_project_statuses", "source_entity_data_uuid")
    end

    test "project_uuid FK cascades on delete" do
      assert fk_delete_rule("phoenix_kit_project_statuses_project_uuid_fkey") == "c"
    end

    test "has a per-project index and a unique (project_uuid, slug) index" do
      assert index_exists?("phoenix_kit_project_statuses_project_index")
      assert index_exists?("phoenix_kit_project_statuses_project_slug_index")
    end

    test "enforces slug uniqueness within a project" do
      %{rows: [[project_bin]]} =
        Repo.query!(
          "INSERT INTO phoenix_kit_projects (name) VALUES ($1) RETURNING uuid",
          ["Status Host"]
        )

      insert = fn ->
        Repo.query!(
          "INSERT INTO phoenix_kit_project_statuses (project_uuid, label, slug) VALUES ($1, $2, $3)",
          [project_bin, "Done", "done"]
        )
      end

      assert insert.()
      assert_raise Postgrex.Error, insert
    end
  end

  describe "phoenix_kit_projects catalog columns (from V125)" do
    test "status_entity_uuid is a nullable uuid" do
      assert %{type: "uuid", nullable: "YES"} =
               column("phoenix_kit_projects", "status_entity_uuid")
    end

    test "current_status_slug is a nullable varchar" do
      assert %{type: "character varying", nullable: "YES"} =
               column("phoenix_kit_projects", "current_status_slug")
    end

    test "settings is a JSONB NOT NULL default '{}'" do
      assert %{type: "jsonb", nullable: "NO", default: default} =
               column("phoenix_kit_projects", "settings")

      assert default =~ ~r/'\{\}'::jsonb/
    end

    test "status_entity_uuid FK sets null on delete" do
      assert fk_delete_rule("phoenix_kit_projects_status_entity_uuid_fkey") == "n"
    end

    test "partial index on status_entity_uuid exists and is predicated on NOT NULL" do
      assert index_exists?("phoenix_kit_projects_status_entity_idx")

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'phoenix_kit_projects_status_entity_idx'"
        )

      assert indexdef =~ "status_entity_uuid IS NOT NULL"
    end

    test "external_id is a nullable varchar" do
      assert %{type: "character varying", nullable: "YES"} =
               column("phoenix_kit_projects", "external_id")
    end

    test "partial index on external_id exists and is predicated on NOT NULL" do
      assert index_exists?("phoenix_kit_projects_external_id_idx")

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'phoenix_kit_projects_external_id_idx'"
        )

      assert indexdef =~ "external_id IS NOT NULL"
    end
  end
end
