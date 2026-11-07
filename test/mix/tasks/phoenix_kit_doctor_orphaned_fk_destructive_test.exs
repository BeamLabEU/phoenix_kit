defmodule Mix.Tasks.PhoenixKit.DoctorOrphanedFkDestructiveTest do
  @moduledoc """
  Every test here runs real DDL (`ALTER TABLE ... ADD CONSTRAINT`,
  `ALTER TABLE ... ALTER CONSTRAINT`) against `phoenix_kit_activities`,
  `phoenix_kit_user_oauth_providers`, and `phoenix_kit_users` — split out of
  `DoctorOrphanedFkTest` for exactly that reason.

  `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ... REFERENCES` takes a
  `ShareRowExclusiveLock` on BOTH the altered table and the referenced one.
  These tests used to live in `DoctorOrphanedFkTest`, declared
  `async: true` — fine in isolation, but a live full-suite run deadlocked
  (Postgres `40P01`) between two of these DDL statements and one of the
  dozen-plus other async test files that write to `phoenix_kit_users`
  concurrently: this session's ALTER waits on a `ShareRowExclusiveLock`
  held by another async test's row lock, while that test's own next
  write waits on a lock this ALTER already holds — a real deadlock, not
  bad luck, and one the full suite could hit on any run, at random,
  depending on which async tests happened to interleave.

  ExUnit's own scheduling guarantee is the fix: every `async: true` test
  module runs first and concurrently, and every `async: false` module
  runs only after ALL of them have finished, one at a time. Moving the
  actual DDL out of the async module into this one, `async: false`,
  makes the deadlock structurally impossible rather than merely less
  likely — by the time any test here runs, nothing else in the suite is
  still touching `phoenix_kit_users` at all.
  """
  use PhoenixKit.DataCase, async: false

  alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask
  alias PhoenixKit.Test.Repo

  # Adding a foreign key validates every row, and the concurrency suites commit activity
  # rows outside the sandbox, so a row naming a user they have since deleted would fail
  # these tests depending on the order they run in. This runs in the test's own
  # transaction, so it rolls back with it.
  setup do
    Repo.query!("DELETE FROM phoenix_kit_activities")
    :ok
  end

  describe "check_orphaned_fk_refs/1 — destructive: a genuinely orphaned row outside the old 4 pairs is caught" do
    # The widened check reads every single-column FK straight from
    # `pg_constraint` (`discover_fk_constraints/2`), not just the four pairs
    # the old check knew by name. This proves that widened coverage actually
    # catches something the old four-pair list could never have seen:
    # `phoenix_kit_user_oauth_providers.user_uuid -> phoenix_kit_users.uuid`
    # (constraint `fk_user_oauth_providers_user_uuid`) was never one of the
    # old four (`phoenix_kit_users_tokens`, `phoenix_kit_user_role_assignments`,
    # `phoenix_kit_admin_notes`, `phoenix_kit_email_events`).
    #
    # A plain `INSERT` can't produce this row — the constraint rejects a
    # nonexistent `user_uuid` immediately, and it isn't `DEFERRABLE`, so
    # `SET CONSTRAINTS ALL DEFERRED` doesn't buy anything either.
    #
    # Planting the row via `DISABLE TRIGGER ALL` (the original approach)
    # needs superuser: Postgres reserves the internal `RI_ConstraintTrigger`
    # a FK creates for superusers regardless of who owns the table, so it
    # fails outright under the unprivileged-role model `config/test.exs`
    # documents (a role with no `CREATEDB`, pointed at a pre-provisioned
    # database via `PGDATABASE`/`PGPOOL`, owning the tables it migrated).
    #
    # `DROP CONSTRAINT` / re-`ADD ... NOT VALID` (PR #774) also clears that
    # bar, but it plants the orphan behind a constraint that is no longer
    # validated — and `classify_fk_check/6` branches on exactly that. A
    # `{:not_valid, _}` constraint with orphans routes to `:validate`, the
    # clause that predates the widening fix and was never the one at risk.
    # The assertion below could not tell the two apart, so the guard went
    # vacuous for the branch it exists to hold.
    #
    # `ALTER CONSTRAINT ... DEFERRABLE INITIALLY DEFERRED` is the
    # ordinary-DDL route that keeps the constraint VALID: altering an
    # existing FK's deferrability is a plain table-owner operation,
    # `pg_constraint.convalidated` stays `true`, and the deferred RI check
    # fires only at COMMIT — which never comes, because `DataCase` rolls
    # this test's sandbox transaction back. So the orphan is real, and
    # unmatched, for the entire life of the check, sitting behind a
    # constraint Postgres still reports as fully validated: the
    # `:existing_orphan` shape real corruption actually takes.
    test "an orphaned phoenix_kit_user_oauth_providers.user_uuid row is reported, not read as clean" do
      Repo.query!("""
      ALTER TABLE phoenix_kit_user_oauth_providers
        ALTER CONSTRAINT fk_user_oauth_providers_user_uuid DEFERRABLE INITIALLY DEFERRED
      """)

      Repo.query!("""
      INSERT INTO phoenix_kit_user_oauth_providers
        (user_uuid, provider, provider_uid, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'google', 'destructive-orphan-test', now(), now())
      """)

      # The constraint has to still read as validated, or the assertion
      # below is proving the wrong clause.
      assert %{rows: [[true]]} =
               Repo.query!("""
               SELECT convalidated FROM pg_constraint
               WHERE conname = 'fk_user_oauth_providers_user_uuid'
               """)

      assert {:fail, message} = DoctorTask.check_orphaned_fk_refs("public")
      assert message =~ "phoenix_kit_user_oauth_providers.user_uuid"

      # Pin the branch, not just the table.column. `:validate` (constraint
      # NOT VALID) and `:create` (no constraint at all) would both put this
      # same table.column in the message, and both were reachable before the
      # widening fix. Only `:existing_orphan` exercises the `:validated` +
      # `count > 0` clause — the one that used to discard real orphans.
      assert message =~ "constraint IS validated but orphans exist anyway"
    end
  end

  describe "discover_schema_declared_relations_without_fk/2 — I082, second step (destructive)" do
    # Proof by destruction: adding the FK a `belongs_to` already declares
    # must remove it from this list. Runs inside the test's own sandbox
    # transaction — Postgres DDL is transactional, so nothing outside this
    # test ever sees the added constraint; no manual cleanup needed. The
    # transaction itself is real, though, and still takes a real
    # `ShareRowExclusiveLock` for its duration — hence `async: false` here.
    test "adding the matching FK constraint drops that relation out of the count" do
      assert {:ok, {total_before, before_fix}} =
               DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      assert {"phoenix_kit_activities", "actor_uuid"} in before_fix

      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      ADD CONSTRAINT phoenix_kit_activities_actor_uuid_fkey
      FOREIGN KEY (actor_uuid) REFERENCES phoenix_kit_users(uuid)
      """)

      assert {:ok, {total_after, after_fix}} =
               DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      refute {"phoenix_kit_activities", "actor_uuid"} in after_fix
      assert {"phoenix_kit_activities", "target_uuid"} in after_fix
      assert length(after_fix) == length(before_fix) - 1
      # Adding a constraint changes which relations are MISSING, never how
      # many candidates exist to check in the first place.
      assert total_after == total_before
    end

    # Review finding (PR #755, HIGH-adjacent MEDIUM): the original SQL
    # matched a column against pg_constraint by (table, column) alone, with
    # no join back to the referenced table at all — a FK from
    # actor_uuid to ANY table, not specifically phoenix_kit_users, was
    # enough to silence the finding. Proven live before this fix: adding
    # exactly this (a real, single-column FK, just pointed at the wrong
    # target) left actor_uuid missing from the report. RED without the
    # (table, column, ref_table) triple match in the query.
    test "a FK on the right column pointing at the WRONG table does not silence the missing relation" do
      assert {:ok, {total_before, before_fix}} =
               DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      assert {"phoenix_kit_activities", "actor_uuid"} in before_fix

      # phoenix_kit_user_roles is a real table with a real `uuid` PK — a
      # perfectly valid single-column FK target, just not the one
      # PhoenixKit.Activity.Entry's `belongs_to :actor` declares
      # (`phoenix_kit_users`).
      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      ADD CONSTRAINT phoenix_kit_activities_actor_uuid_wrong_target_fkey
      FOREIGN KEY (actor_uuid) REFERENCES phoenix_kit_user_roles(uuid)
      """)

      assert {:ok, {total_after, after_wrong_target}} =
               DoctorTask.discover_schema_declared_relations_without_fk(Repo, "public")

      assert {"phoenix_kit_activities", "actor_uuid"} in after_wrong_target,
             "a FK to the wrong table must not count as satisfying the declared relation"

      assert after_wrong_target == before_fix
      assert total_after == total_before

      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      DROP CONSTRAINT phoenix_kit_activities_actor_uuid_wrong_target_fkey
      """)
    end
  end

  describe "check_schema_declared_relations_without_fk/1 — I082, second step: PASS is not vacuous (destructive)" do
    # Symmetric to the destruction check above: close BOTH real gaps and
    # confirm the check actually reads clean, not just "never fails".
    test "closing every real gap makes it :pass, not just non-:fail" do
      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      ADD CONSTRAINT phoenix_kit_activities_actor_uuid_fkey
      FOREIGN KEY (actor_uuid) REFERENCES phoenix_kit_users(uuid)
      """)

      Repo.query!("""
      ALTER TABLE phoenix_kit_activities
      ADD CONSTRAINT phoenix_kit_activities_target_uuid_fkey
      FOREIGN KEY (target_uuid) REFERENCES phoenix_kit_users(uuid)
      """)

      assert {:pass, message} = DoctorTask.check_schema_declared_relations_without_fk("public")
      assert message =~ "Every belongs_to"
    end
  end
end
