defmodule PhoenixKit.Migrations.Postgres.V164 do
  @moduledoc """
  V164: Repair for the V56/V57 flush-order bug's fallout on already-migrated
  single-shot installs.

  ## Root cause (fixed at the source in V56/V57/V72; this version is the
  cleanup for installs that ran the buggy versions before those fixes)

  V56 called `UUIDFKColumns.up/1` (queues `ADD COLUMN` for ~80 `*_uuid` FK
  columns) immediately followed by `UUIDFKColumns.add_constraints/1` (whose
  `set_not_null/4` and `add_fk_constraint/7` guard themselves with immediate
  `column_exists?`/`table_exists?` `information_schema` queries) with no
  `flush()` between them, and V57 (which re-runs the same pair) had no
  `flush()` at all. V56 and V57 are not separate Ecto migration modules —
  they are sub-calls inside one parent `up/1` that share a single command
  buffer — so ANY chain run crossing V56/V57 within one migrator invocation
  hits this, whether it came from a fresh `mix phoenix_kit.install` (one
  unpinned wrapper for the whole chain) or from an update wrapper whose
  range happens to span those versions. The buffer is not flushed by an
  immediate `repo().query`, so
  `add_constraints/1`'s guards ran against `information_schema` state that
  had not seen the columns `UUIDFKColumns.up/1` had *just* queued moments
  earlier in the same call — every guard failed closed:

    * ~46 `*_uuid` columns across ~33 tables were silently left nullable
      instead of NOT NULL.
    * ALL ~70 declared FK constraints (`UUIDFKColumns.fk_constraints/0`)
      failed the same closed guard, not just the one this version used to
      single out. Live evidence from a production database that crossed
      V56/V57 in one migrator invocation: 155 foreign keys existed on
      `phoenix_kit_*` tables, but only a handful carried the `fk_` naming
      convention these declarations use — every sampled expected name
      (`fk_users_tokens_user_uuid`, `fk_role_permissions_role_uuid`,
      `fk_orders_user_uuid`, …) was absent. An earlier revision of this
      migration repaired only `phoenix_kit_comments.fk_comments_user_uuid`
      (item 3 below) on the mistaken premise that it was the sole
      casualty — understating the fallout by roughly 67 constraints.

  `phoenix_kit_comments.fk_comments_user_uuid` specifically was never
  created at all (the same guard gap). V72, running later and finding that
  FK genuinely missing, added it back with a guessed `ON DELETE CASCADE`
  instead of matching V56/V57's own already-declared `SET NULL` intent
  (`UUIDFKColumns.@fk_constraints`) — comments behave like tickets/
  ai_requests (orphaned-author rows survive, blanked), not like the
  `*_likes`/`*_dislikes` junction tables, which genuinely should vanish
  with their user.

  V56 and V57 now each have the missing `flush()`, and V72's entry is now
  `SET NULL` — so every chain run *from here on*, single-shot or
  incremental, produces the correct shape and this version is a no-op on
  it. This version exists only to repair installs whose single-shot run
  already happened before those fixes landed.

  ## What this does

  1. For every `{table, column}` pair `UUIDFKColumns.add_constraints/1`
     sets NOT NULL on (`UUIDFKColumns.not_null_uuid_fks/0` — the exact same
     list, not a second copy of it) **minus `@relaxed_after_v57`** (below):
     if the column currently has zero NULL rows, sets NOT NULL — matching
     the shape a correctly-flushed V56/V57 run would already have
     produced, a no-op if it's already NOT NULL. If NULL rows exist, this
     does **not** guess: those NULLs may be legitimate application data
     (e.g. an FK reference to a deleted row with no CASCADE, or a
     genuinely optional relation) rather than purely an artifact of the
     flush bug, so it raises a warning naming the table/column/row count
     and leaves the column nullable for an operator to investigate — never
     backfills a live column with a random value to force the constraint
     through (unlike `UUIDFKColumns`' own conversion-era backfill, which
     only ever ran against columns it had *just* created moments earlier
     in the same call, never live data). A column skipped via
     `@relaxed_after_v57` stays nullable permanently — that is the point of
     the list. A column skipped via the WARN path is different, and the text
     here used to say otherwise: the NULL count is re-read on every run, so
     once an operator resolves those rows a re-run DOES enforce NOT NULL.
     Re-running is free for everything already enforced (the nullability probe
     short-circuits before any ALTER), which is what makes it safe to re-run
     after a partial failure.

  ### `@relaxed_after_v57` — columns a LATER version deliberately made nullable again

  `not_null_uuid_fks/0` is V56/V57's own declared list — a snapshot of
  intent as of V57. Later versions can and do legitimately relax a column
  on that list for reasons that have nothing to do with the flush bug
  (V164 blindly re-enforcing NOT NULL on those would silently break
  whatever feature needed the relaxation — on a *fresh* install, the table
  starts empty, so the zero-NULL-rows check would not catch this at all).
  Found by grepping every `DROP NOT NULL` in `v58.ex`..`v162.ex` — after
  V57, where the flush fix landed — and intersecting the touched
  `{table, column}` pairs against `not_null_uuid_fks/0` (checked both raw
  SQL `ALTER COLUMN ... DROP NOT NULL` and the Ecto `modify ..., null:
  true` DSL form; only the former appears anywhere in this range):

    * `{:phoenix_kit_files, "user_uuid"}` — V113 (`v113.ex`): system-managed
      media rows (DZI tiles/manifests) have no human owner, only a
      `parent_file_uuid`; `phoenix_kit_files_user_or_parent_check` enforces
      "one of the two is set" at the CHECK-constraint level instead.
      Re-imposing NOT NULL here would break `Storage.store_system_file`'s
      tile generation on any install whose run hit the flush bug.

  A THIRD case exists that belongs in neither category: an entry that was
  simply WRONG in `not_null_uuid_fks/0` from the start.
  `{:phoenix_kit_users_tokens, "user_uuid"}` was removed from that list
  outright on 2026-08-08 rather than excluded here, because V64's
  `user_uuid_required_for_non_registration_tokens` CHECK deliberately permits
  NULL for magic-link REGISTRATION tokens (no user exists yet) — so enforcing
  NOT NULL breaks registration on a fresh install as surely as on a repaired
  one, and the fix has to reach the baseline and the manifest too, not just
  this repair. Removing it at the source makes every path agree; excluding it
  here would have left V56/V57 still imposing it. The relaxation was invisible
  to the `DROP NOT NULL` grep this list was built from because it was expressed
  as a CHECK — `v164_relaxed_columns_test.exs` now scans for that shape too.

  The list also carries one entry that is not a later relaxation but a
  contradiction inside V56/V57's own declarations —
  `phoenix_kit_ticket_status_history.changed_by_uuid` is claimed by
  `@not_null_uuid_fks` while `@fk_constraints` gives its FK
  `ON DELETE SET NULL`, which NOT NULL makes unsatisfiable. See its inline
  comment; `uuid_fk_columns_test.exs` asserts no other pair contradicts.

  `test/phoenix_kit/migrations/v164_relaxed_columns_test.exs` statically
  scans `v58.ex`..the current HEAD version for this exact pattern and fails
  if it finds a `not_null_uuid_fks/0` member relaxed by a later version
  that is not listed here — a future relaxation cannot silently make this
  list stale again.

  2. For every `{table, uuid_fk, ref_table, ref_col, on_delete}` tuple in
     `UUIDFKColumns.fk_constraints/0` (the exact same ~70-entry list, not a
     second copy): if the FK's own table/column or its referenced
     table/column is absent, the whole tuple is skipped (feature-module
     tables can legitimately be missing on an install that never enabled
     that module) and folded into one aggregate warning naming every
     skipped tuple. Otherwise, if the named constraint
     (`UUIDFKColumns.fk_constraint_name/2` — the identical name
     `add_fk_constraint/7` itself would have used) does not already exist,
     it is added the same way `PhoenixKit.Migrations.Repair.Executor` adds
     any FK (spec §6.2/§6.3, the repair engine's own rule, not a new one
     invented here): `NOT VALID` first — metadata-only, no table scan,
     brief lock — then a separate `VALIDATE CONSTRAINT` — `SHARE UPDATE
     EXCLUSIVE`, does not block reads or writes, but does scan the table.
     If validation fails because live rows violate it, the constraint is
     left `NOT VALID` (new writes are still checked going forward) and a
     warning names the table, column and the orphan row count — a real
     `COUNT(*)` diagnostic query, never a guess. Nothing here ever deletes
     a row or nulls out a reference to force a constraint through: V72's
     own historical fix for the one comments FK did that, and so does
     `UUIDFKColumns.add_fk_constraint/7` itself when it first lays down
     these constraints on a fresh install — both are safe there only
     because they act on data they just created moments earlier in the
     same call, never on live, already-deployed data, which is exactly
     what this repair runs against. Idempotent: a constraint that already
     exists, `NOT VALID` or fully validated, is left exactly as-is on every
     re-run — a second run finds everything this pass would have created
     already present and does nothing.

  3. `phoenix_kit_comments.fk_comments_user_uuid`: if it currently has `ON
     DELETE CASCADE` (V72's guess, made under the buggy single-shot
     shape), drops and re-adds it `ON DELETE SET NULL`. No orphan cleanup
     is needed for that transition — rows cannot be orphaned under an
     already-enforced CASCADE constraint (every row whose referenced user
     was deleted would already be gone). If the constraint is absent
     entirely — reachable now only if item 2 above also failed to create
     it (e.g. a validation failure left it `NOT VALID`, which this branch
     does not treat as "absent"; item 2 always runs first and already
     covers the ordinary "missing entirely" case with the correct `SET
     NULL` action) — adds it `SET NULL` with the same orphan cleanup V72's
     own `add_fk_constraint/7` does. If already `SET NULL`, no-op.

  ## down/1

  This is a repair, not a feature — rolling back does not undo the NOT
  NULL constraints or the FK correction (same precedent as V57: "don't
  undo V56's work on rollback"). `down/1` only restamps the version
  comment.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Migrations.UUIDFKColumns

  # ── Prefix-unsafety normalization (folded in from the V164 draft: this
  # release ships ONE migration, not two) ────────────────────────────────
  @publishing_table "phoenix_kit_publishing_posts"
  @publishing_index "idx_publishing_posts_group_slug"
  @publishing_partial_clause "WHERE (slug IS NOT NULL)"

  @subscription_table "phoenix_kit_subscription_types"
  @old_slug_index "phoenix_kit_subscription_plans_slug_uidx"
  @new_slug_index "phoenix_kit_subscription_types_slug_uidx"

  @comments_table "phoenix_kit_comments"
  @comments_fk_column "user_uuid"
  @comments_constraint "fk_comments_user_uuid"
  @comments_ref_table "phoenix_kit_users"
  @comments_ref_column "uuid"

  # See the moduledoc section of the same name — a `not_null_uuid_fks/0`
  # member a LATER version deliberately dropped NOT NULL from again, so
  # V164 must not re-impose it. Exposed publicly so
  # `V164RelaxedColumnsTest` can assert this list stays a superset of every
  # `DROP NOT NULL` the chain applies to a tracked column after V57.
  @relaxed_after_v57 [
    # V113 (v113.ex): system-managed media rows have no human owner, only
    # a parent_file_uuid; phoenix_kit_files_user_or_parent_check enforces
    # "one of the two" at the CHECK-constraint level instead.
    {:phoenix_kit_files, "user_uuid"},
    # Not a later relaxation but a contradiction inside V56/V57's own two
    # lists: `@not_null_uuid_fks` claims this column, while `@fk_constraints`
    # declares its FK `ON DELETE SET NULL`. NOT NULL makes that FK
    # unsatisfiable — deleting a user who ever changed a ticket status would
    # fail with a not-null violation instead of blanking the author. On the
    # broken installs this repair targets the column is nullable, so user
    # deletion works today; enforcing NOT NULL would newly break it. Left
    # nullable until the chain resolves which of the two declarations is
    # wrong (`uuid_fk_columns_test.exs` asserts no OTHER pair contradicts).
    {:phoenix_kit_ticket_status_history, "changed_by_uuid"}
  ]

  @doc false
  def relaxed_after_v57, do: @relaxed_after_v57

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    # The immediate queries below (NULL counts, the comments-FK's
    # confdeltype) must see every column/constraint queued by earlier
    # versions in this same chain run — same reasoning as the flush now
    # added to V56/V57.
    flush()

    # Serialization note: Ecto's default `:table_lock` migration_lock
    # strategy (Ecto.Adapters.Postgres.lock_for_migrations/3 — not
    # overridden anywhere in this codebase) serializes this run against any
    # CONCURRENT migrator invocation on the same repo, which is what closes
    # the window between a column's null_count/1 read below and its SET NOT
    # NULL write. Note it does NOT put the DDL itself in one transaction:
    # every wrapper generated for this chain sets
    # `@disable_ddl_transaction true`, so each statement auto-commits (an
    # earlier version of this note conflated the two — GLM review,
    # 2026-08-07). Neither mechanism closes the window against ordinary
    # application traffic concurrently INSERTing a NULL into the same live
    # column mid-migration — the same
    # deploy discipline (migrations run before the app starts serving
    # traffic) every other additive migration in this chain already
    # depends on for exactly this reason.
    for {table, column} <- UUIDFKColumns.not_null_uuid_fks() -- @relaxed_after_v57 do
      repair_not_null(table, column, prefix, escaped_prefix)
    end

    not_valid =
      repair_missing_fks(prefix, escaped_prefix) ++ repair_comments_fk(prefix, escaped_prefix)

    report_not_valid_fks(not_valid)

    repair_publishing_slug_index(prefix, escaped_prefix)
    repair_subscription_slug_index(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '164'")
  end

  def down(%{prefix: prefix} = _opts) do
    # Repair migration — never undoes the NOT NULL / FK correction on
    # rollback (V57's precedent: "don't undo V56's work"). Comment-restamp
    # only.
    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '163'")
  end

  # ── NOT NULL repair ──────────────────────────────────────────────────

  defp repair_not_null(table, column, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    if table_exists?(table_str, escaped_prefix) and
         column_exists?(table_str, column, escaped_prefix) and
         not column_not_null?(table_str, column, escaped_prefix) do
      # The nullability check above is what makes a re-run genuinely free.
      # Without it the ALTER was re-issued on every run, taking ACCESS EXCLUSIVE
      # on each of ~45 tables (some of them large) only to assert what was
      # already true — the "re-running is a no-op" claim was false in the way
      # that matters operationally (Kimi review, 2026-08-08).
      table_name = prefix_table_name(table_str, prefix)

      case null_count(table_name, column) do
        0 ->
          execute("""
          ALTER TABLE #{table_name}
          ALTER COLUMN #{column} SET NOT NULL
          """)

        :unknown ->
          IO.warn(
            "PhoenixKit V164: could not determine NULL count for #{table_str}.#{column} — " <>
              "leaving nullable. Re-running V164 WILL retry this column (the probe is a fresh " <>
              "read each time), so once the cause is understood a re-run enforces it; or apply " <>
              "ALTER TABLE ... ALTER COLUMN ... SET NOT NULL by hand."
          )

        count ->
          IO.warn(
            "PhoenixKit V164: #{table_str}.#{column} has #{count} NULL row(s) — leaving " <>
              "nullable (never backfilling live data). Investigate before enforcing NOT NULL. " <>
              "Re-running V164 WILL retry this column once those rows are resolved (the NULL " <>
              "count is re-read on every run); or apply ALTER TABLE ... ALTER COLUMN ... SET " <>
              "NOT NULL by hand."
          )
      end
    end
  end

  # information_schema, schema-anchored — same idiom as every other probe here.
  # `UUIDFKColumns.column_is_not_null?/3` is the same query; kept local so this
  # version does not depend on a helper that a future refactor of that module
  # could change out from under it.
  defp column_not_null?(table, column, escaped_prefix) do
    query = """
    SELECT is_nullable = 'NO'
    FROM information_schema.columns
    WHERE table_name = '#{table}'
      AND column_name = '#{column}'
      AND table_schema = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp null_count(table_name, column) do
    case repo().query(
           "SELECT count(*) FROM #{table_name} WHERE #{column} IS NULL",
           [],
           log: false
         ) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> :unknown
    end
  end

  # ── Missing FK repair ─────────────────────────────────────────────────
  #
  # Drives off UUIDFKColumns.fk_constraints/0 (the exact list, not a copy)
  # and adds every FK that list's own `add_fk_constraint/7` would have
  # created had the flush bug not made its existence guard fail closed.
  # Uses the same NOT VALID + VALIDATE two-step
  # `PhoenixKit.Migrations.Repair.Executor` uses for every FK it creates
  # (spec §6.2/§6.3) and the same orphan-count diagnostic
  # (`Repair.Probe.orphan_count/6`, reused rather than duplicated).

  # Returns the labels of every constraint left NOT VALID, for the single
  # end-of-run summary `up/1` emits. Per-constraint warnings are easy to lose
  # in a deploy log between hundreds of other migration lines, and a run that
  # left constraints unvalidated still exits successfully and stamps 164 — so
  # the operator needs one line at the end telling them there is follow-up
  # work, not only N interleaved warnings (GLM review, 2026-08-07).
  defp repair_missing_fks(prefix, escaped_prefix) do
    outcomes =
      Enum.map(UUIDFKColumns.fk_constraints(), fn {table, uuid_fk, ref_table, ref_col, on_delete} ->
        ensure_fk(table, uuid_fk, ref_table, ref_col, on_delete, prefix, escaped_prefix)
      end)

    outcomes
    |> Enum.filter(&match?({:skipped, _reason}, &1))
    |> Enum.map(fn {:skipped, reason} -> reason end)
    |> report_skipped_fks()

    report_mismatched_actions(for {:mismatched_action, label} <- outcomes, do: label)

    for {tag, label} <- outcomes, tag in [:not_valid, :failed], do: label
  end

  # Reported, never "fixed": dropping a constraint an application already
  # depends on to replace it with a differently-named twin is a decision for
  # the operator, not for a repair migration that cannot know which action the
  # application actually relies on.
  defp report_mismatched_actions([]), do: :ok

  defp report_mismatched_actions(labels) do
    IO.warn(
      "PhoenixKit V164: #{length(labels)} foreign key(s) are already enforced under a " <>
        "different constraint name with a DIFFERENT ON DELETE action than this chain " <>
        "declares. Left untouched — adding a second constraint would not change the " <>
        "behaviour anyway (the strictest action wins). Reconcile by hand if the declared " <>
        "action is the one you want: " <> Enum.join(labels, "; ")
    )
  end

  defp ensure_fk(table, uuid_fk, ref_table, ref_col, on_delete, prefix, escaped_prefix) do
    table_str = Atom.to_string(table)

    cond do
      not (table_exists?(table_str, escaped_prefix) and
               column_exists?(table_str, uuid_fk, escaped_prefix)) ->
        {:skipped, "#{table_str}.#{uuid_fk} (source table/column absent)"}

      not (table_exists?(ref_table, escaped_prefix) and
               column_exists?(ref_table, ref_col, escaped_prefix)) ->
        {:skipped,
         "#{table_str}.#{uuid_fk} -> #{ref_table}.#{ref_col} (referenced table/column absent)"}

      true ->
        create_fk_if_missing(
          table_str,
          uuid_fk,
          ref_table,
          ref_col,
          on_delete,
          prefix,
          escaped_prefix
        )
    end
  end

  defp create_fk_if_missing(
         table_str,
         uuid_fk,
         ref_table,
         ref_col,
         on_delete,
         prefix,
         escaped_prefix
       ) do
    constraint = UUIDFKColumns.fk_constraint_name(table_str, uuid_fk)

    # Shape, not name. Checking `conname` alone misses an equivalent FK that
    # already covers this exact (column -> ref_table.ref_col) pair under some
    # other name — Ecto's own `<table>_<col>_fkey`, most commonly — and adding
    # a second constraint beside it does NOT give this migration's declared
    # ON DELETE action any effect: PostgreSQL fires every matching FK action,
    # and the strictest one wins, so a pre-existing CASCADE silently defeats
    # the SET NULL declared here (measured both directions, Opus review
    # 2026-08-07). One such pair already exists in the wild:
    # phoenix_kit_ai_requests.prompt_uuid carries
    # `phoenix_kit_ai_requests_prompt_uuid_fkey`, benign only because its
    # action happens to match. Adopt what is there and report the mismatch
    # instead of creating a duplicate whose semantics silently lose.
    case fk_shape_present(table_str, uuid_fk, ref_table, ref_col, escaped_prefix) do
      {:present, ^constraint, confdeltype} ->
        # Compare the action even under the expected name. Adopting it blindly
        # was the one path where a wrong ON DELETE produced no signal at all,
        # while a differently-named twin earned a warning (Kimi review,
        # 2026-08-08).
        adopted_fk(table_str, uuid_fk, ref_table, ref_col, on_delete, constraint, confdeltype)

      {:present, other_name, confdeltype} ->
        adopted_fk(table_str, uuid_fk, ref_table, ref_col, on_delete, other_name, confdeltype)

      :absent ->
        create_fk(table_str, uuid_fk, ref_table, ref_col, on_delete, prefix, escaped_prefix)
    end
  end

  defp adopted_fk(table_str, uuid_fk, ref_table, ref_col, on_delete, other_name, confdeltype) do
    if confdeltype == on_delete_char(on_delete) do
      :already_present
    else
      {:mismatched_action,
       "#{table_str}.#{uuid_fk} -> #{ref_table}.#{ref_col} is already enforced by " <>
         "#{other_name} with ON DELETE #{on_delete_name(confdeltype)}, but this chain " <>
         "declares ON DELETE #{on_delete}"}
    end
  end

  defp create_fk(table_str, uuid_fk, ref_table, ref_col, on_delete, prefix, escaped_prefix) do
    constraint = UUIDFKColumns.fk_constraint_name(table_str, uuid_fk)
    table_name = prefix_table_name(table_str, prefix)
    ref_name = prefix_table_name(ref_table, prefix)

    # NOT VALID first: it skips the table scan a plain ADD would do. It is NOT
    # free — it takes SHARE ROW EXCLUSIVE on this table AND on the referenced
    # one, blocking writes on both while held (measured, Opus review
    # 2026-08-07; the upgrade guide states this so operators size the window
    # correctly). Same rule `PhoenixKit.Migrations.Repair.Executor` follows.
    #
    # Guarded like the VALIDATE below, and for the same reason: this migration
    # runs against unknown, historically-damaged schemas, where ADD can fail on
    # a missing unique constraint on the referenced column (42830) or on a name
    # already taken by an unrelated constraint (42710). An unguarded failure
    # would abort the whole chain run; guarded, this one constraint is reported
    # and the rest of the repair proceeds.
    execute("""
    DO $$
    BEGIN
      ALTER TABLE #{table_name}
      ADD CONSTRAINT #{constraint}
      FOREIGN KEY (#{uuid_fk})
      REFERENCES #{ref_name}(#{ref_col})
      ON DELETE #{on_delete}
      NOT VALID;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'PhoenixKit V164: ADD CONSTRAINT #{constraint} failed: % (SQLSTATE %)',
          SQLERRM, SQLSTATE;
    END $$;
    """)

    # Flushed before the immediate VALIDATE/read steps below — otherwise
    # they would run against pre-ADD state, exactly the ordering bug
    # this whole migration exists to repair.
    flush()

    if fk_exists?(table_str, constraint, escaped_prefix) do
      validate_fk(table_str, uuid_fk, ref_table, ref_col, constraint, prefix, escaped_prefix)
    else
      {:failed,
       "#{constraint} on #{table_str}.#{uuid_fk} could not be created — see the RAISE WARNING " <>
         "above for the PostgreSQL error and SQLSTATE"}
    end
  end

  # Any FK enforcing the same (column -> ref_table.ref_col) pair, under any
  # name. Decomposed through conkey/confkey the same way
  # `PhoenixKit.Migrations.Repair.Probe`'s constraint snapshot does, and
  # restricted to single-column keys, which is every entry in
  # `UUIDFKColumns.fk_constraints/0`.
  defp fk_shape_present(table_str, uuid_fk, ref_table, ref_col, escaped_prefix) do
    query = """
    SELECT c.conname, c.confdeltype::text
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_class ft ON ft.oid = c.confrelid
    JOIN pg_namespace fn ON fn.oid = ft.relnamespace
    WHERE c.contype = 'f'
      AND n.nspname = '#{escaped_prefix}'
      AND t.relname = '#{table_str}'
      AND ft.relname = '#{ref_table}'
      -- The REFERENCED relation needs the same schema anchor as the referencing
      -- one: without it a same-named table in another schema satisfies this
      -- probe through a cross-schema FK, and the intra-schema constraint this
      -- migration is supposed to create is silently skipped (Kimi review,
      -- 2026-08-08).
      AND fn.nspname = '#{escaped_prefix}'
      AND array_length(c.conkey, 1) = 1
      AND array_length(c.confkey, 1) = 1
      AND (SELECT a.attname FROM pg_attribute a
           WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]) = '#{uuid_fk}'
      AND (SELECT a.attname FROM pg_attribute a
           WHERE a.attrelid = c.confrelid AND a.attnum = c.confkey[1]) = '#{ref_col}'
    ORDER BY (c.conname = '#{UUIDFKColumns.fk_constraint_name(table_str, uuid_fk)}') DESC
    LIMIT 1
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[name, confdeltype]]}} -> {:present, name, confdeltype}
      {:ok, %{rows: []}} -> :absent
      # Never guess ":absent" on a failed probe — that is the mistake this
      # whole migration exists to repair, and here it would mean trying to
      # create a constraint that already exists.
      other -> raise "PhoenixKit V164: could not probe FKs on #{table_str}: #{inspect(other)}"
    end
  end

  defp on_delete_char("CASCADE"), do: "c"
  defp on_delete_char("SET NULL"), do: "n"
  defp on_delete_char("RESTRICT"), do: "r"
  defp on_delete_char("SET DEFAULT"), do: "d"
  defp on_delete_char("NO ACTION"), do: "a"

  defp on_delete_name("c"), do: "CASCADE"
  defp on_delete_name("n"), do: "SET NULL"
  defp on_delete_name("r"), do: "RESTRICT"
  defp on_delete_name("d"), do: "SET DEFAULT"
  defp on_delete_name("a"), do: "NO ACTION"
  defp on_delete_name(other), do: "confdeltype=#{inspect(other)}"

  defp validate_fk(table_str, uuid_fk, ref_table, ref_col, constraint, prefix, escaped_prefix) do
    table_name = prefix_table_name(table_str, prefix)

    # PL/pgSQL EXCEPTION handler, not an Elixir rescue — a failing immediate
    # VALIDATE CONSTRAINT would otherwise abort the surrounding transaction
    # (25P02), same reasoning as UUIDFKColumns' own backfill DO blocks.
    # The SQLSTATE is surfaced, not swallowed: orphaned rows are the EXPECTED
    # cause here, but lock_not_available, deadlock_detected and permission
    # errors land in this same branch, and the Elixir-side orphan count below
    # would then report "0 orphaned row(s)" as if that were the diagnosis
    # (Opus review 2026-08-07).
    execute("""
    DO $$
    BEGIN
      ALTER TABLE #{table_name} VALIDATE CONSTRAINT #{constraint};
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'PhoenixKit V164: VALIDATE CONSTRAINT #{constraint} failed: % (SQLSTATE %)',
          SQLERRM, SQLSTATE;
    END $$;
    """)

    flush()

    if fk_validated?(table_str, constraint, escaped_prefix) do
      :created
    else
      count = Probe.orphan_count(repo(), prefix, table_str, uuid_fk, ref_table, ref_col)

      IO.warn(
        "PhoenixKit V164: added #{constraint} NOT VALID but VALIDATE failed — " <>
          "#{orphan_message(count)} in #{table_str}.#{uuid_fk} referencing " <>
          "#{ref_table}.#{ref_col}. Leaving NOT VALID (new writes are still checked). " <>
          "Investigate and clean up the orphaned rows, then run ALTER TABLE " <>
          "#{table_name} VALIDATE CONSTRAINT #{constraint} by hand."
      )

      {:not_valid, "#{constraint} on #{table_str}.#{uuid_fk} (#{orphan_message(count)})"}
    end
  end

  defp report_not_valid_fks([]), do: :ok

  defp report_not_valid_fks(labels) do
    IO.warn(
      "PhoenixKit V164 SUMMARY: #{length(labels)} constraint(s) were added but could NOT be " <>
        "validated and remain NOT VALID — new writes are checked, pre-existing rows are not. " <>
        "This migration still succeeded and the version comment now reads 164; re-running it " <>
        "does not retry them. Resolve the reported rows, then VALIDATE each by hand: " <>
        Enum.join(labels, "; ")
    )
  end

  defp orphan_message(:unknown), do: "an unknown number of orphaned row(s)"
  defp orphan_message(count), do: "#{count} orphaned row(s)"

  defp report_skipped_fks([]), do: :ok

  defp report_skipped_fks(reasons) do
    IO.warn(
      "PhoenixKit V164: skipped #{length(reasons)} FK repair(s) — table or column absent " <>
        "(expected when the owning feature module was never installed): " <>
        Enum.join(reasons, "; ")
    )
  end

  defp fk_exists?(table_str, constraint, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT 1 FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE c.conname = '#{constraint}'
        AND t.relname = '#{table_str}'
        AND n.nspname = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp fk_validated?(table_str, constraint, escaped_prefix) do
    query = """
    SELECT convalidated FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE c.conname = '#{constraint}'
      AND t.relname = '#{table_str}'
      AND n.nspname = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  # ── Comments FK repair ────────────────────────────────────────────────

  defp repair_comments_fk(prefix, escaped_prefix) do
    if table_exists?(@comments_table, escaped_prefix) and
         column_exists?(@comments_table, @comments_fk_column, escaped_prefix) and
         table_exists?(@comments_ref_table, escaped_prefix) and
         column_exists?(@comments_ref_table, @comments_ref_column, escaped_prefix) do
      table_name = prefix_table_name(@comments_table, prefix)

      case comments_fk_on_delete(escaped_prefix) do
        "c" ->
          # DROP + ADD as two separate execute/1 calls, not one statement —
          # there is no established precedent anywhere in this chain for
          # combining multiple DDL statements into a single execute/1 (the
          # codebase's existing idiom for "must be atomic" is a single
          # statement guarded by a DO $$ IF NOT EXISTS $$ block, not
          # multiple statements in one call), so this keeps that
          # convention rather than introduce a new, unverified one.
          #
          # The window between the two IS real and is NOT closed by a
          # transaction: every wrapper this chain runs under is generated
          # with `@disable_ddl_transaction true`
          # (`mix phoenix_kit.update`/`phoenix_kit.gen.migration`), so each
          # statement auto-commits. An earlier version of this comment
          # claimed a migration-wide transaction covered it — it does not
          # (GLM review, 2026-08-07). What makes the window survivable is
          # that the re-add goes in `NOT VALID` like every other constraint
          # this migration creates: a user deleted mid-window orphans rows
          # that VALIDATE then reports, leaving the constraint NOT VALID
          # with a warning, instead of failing an inline-validated ADD and
          # aborting the whole migration on a table that may be large.
          execute("ALTER TABLE #{table_name} DROP CONSTRAINT #{@comments_constraint}")
          add_comments_fk(prefix, escaped_prefix)

        "n" ->
          []

        nil ->
          # Report and skip. This branch is only reachable when the generic FK
          # pass above ALREADY tried and failed to create this constraint, which
          # is the worst possible state to get aggressive in — and the old
          # fallback was strictly more dangerous than the primary path (Kimi
          # review, 2026-08-08): it issued an unguarded `UPDATE ... SET
          # user_uuid = NULL` against live rows, contradicting this migration's
          # own promise never to null out a reference, and then an unguarded
          # `ADD CONSTRAINT` that re-raised the same error the guarded attempt
          # had just swallowed — aborting the whole chain run AFTER that UPDATE
          # had auto-committed. Reachable for real: an install whose
          # `phoenix_kit_users.uuid` has no unique index (exactly what upstream's
          # V163 repairs, and which V163 DEFERS above two million rows) fails the
          # guarded add with 42830, lands here, and killed the deploy.
          IO.warn(
            "PhoenixKit V164: #{@comments_constraint} is absent and the guarded pass above " <>
              "could not create it — see its warning for the PostgreSQL error. Leaving the " <>
              "column as it is: this migration does not null out live references. Once the " <>
              "cause is resolved (commonly a missing unique index on " <>
              "#{@comments_ref_table}.#{@comments_ref_column} — upstream's V163 repairs that, " <>
              "and defers it above 2M rows), re-run the chain or add the constraint by hand."
          )

          []

        other ->
          IO.warn(
            "PhoenixKit V164: #{@comments_constraint} has unexpected ON DELETE action " <>
              "#{inspect(other)} — leaving as-is."
          )

          []
      end
    else
      []
    end
  end

  # NOT VALID + VALIDATE, the same shape `create_fk_if_missing/7` uses: the
  # bare ADD this used to issue takes ACCESS EXCLUSIVE and scans the whole
  # table, which on a large `phoenix_kit_comments` blocks all access — while
  # the generic pass ten lines above took no such lock for the other ~70
  # constraints. Returns the NOT-VALID label list `up/1` folds into its
  # end-of-run summary.
  defp add_comments_fk(prefix, escaped_prefix) do
    table_name = prefix_table_name(@comments_table, prefix)
    ref_name = prefix_table_name(@comments_ref_table, prefix)

    execute("""
    ALTER TABLE #{table_name}
    ADD CONSTRAINT #{@comments_constraint}
    FOREIGN KEY (#{@comments_fk_column})
    REFERENCES #{ref_name}(#{@comments_ref_column})
    ON DELETE SET NULL
    NOT VALID
    """)

    flush()

    case validate_fk(
           @comments_table,
           @comments_fk_column,
           @comments_ref_table,
           @comments_ref_column,
           @comments_constraint,
           prefix,
           escaped_prefix
         ) do
      {:not_valid, label} -> [label]
      :created -> []
    end
  end

  # Name-anchored pg_constraint + pg_class + pg_namespace JOIN — never a
  # `'<table>'::regclass` cast in an immediate check (CLAUDE.md's V146
  # 25P02 trap: it raises when the relation doesn't exist yet and aborts
  # the whole transaction).
  defp comments_fk_on_delete(escaped_prefix) do
    query = """
    SELECT c.confdeltype FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE c.conname = '#{@comments_constraint}'
      AND t.relname = '#{@comments_table}'
      AND n.nspname = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[deltype]]}} -> deltype
      _ -> nil
    end
  end

  # ── Existence checks (same pattern as every other version file) ──────

  defp table_exists?(table, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table, column, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_name = '#{table}'
      AND column_name = '#{column}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  # ── Publishing posts slug index ─────────────────────────────────────

  defp repair_publishing_slug_index(prefix, escaped_prefix) do
    if table_exists?(@publishing_table, escaped_prefix) and
         publishing_slug_index_needs_replacement?(escaped_prefix) do
      replace_publishing_slug_index(prefix)
    end
  end

  defp publishing_slug_index_needs_replacement?(escaped_prefix) do
    case index_definition(@publishing_index, @publishing_table, escaped_prefix) do
      {:present, definition} ->
        not String.contains?(definition, @publishing_partial_clause)

      # Absent means REPAIR, not "nothing to do". The two statements below
      # auto-commit separately (the wrapper disables the DDL transaction), so a
      # CREATE that fails after the DROP committed leaves the table with no
      # uniqueness on (group_uuid, slug) at all — and mapping absent to `false`
      # made every later run skip it, stamp success, and let duplicate slugs
      # accumulate silently (Kimi review, 2026-08-08). The caller's
      # `table_exists?` guard already excludes installs without the publishing
      # module, so reaching here means the index genuinely ought to exist.
      :absent ->
        true
    end
  end

  defp replace_publishing_slug_index(prefix) do
    table_name = prefix_table_name(@publishing_table, prefix)
    qualified_index = prefix_table_name(@publishing_index, prefix)

    # Qualified on DROP, bare on CREATE — this chain's prefix-safety rule,
    # and the exact spot V68's own version of this pair got wrong.
    execute("DROP INDEX IF EXISTS #{qualified_index}")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@publishing_index}
    ON #{table_name} (group_uuid, slug)
    WHERE slug IS NOT NULL
    """)
  end

  # ── Subscription slug index ──────────────────────────────────────────

  defp repair_subscription_slug_index(prefix, escaped_prefix) do
    if table_exists?(@subscription_table, escaped_prefix) do
      old_present? = index_exists?(@old_slug_index, @subscription_table, escaped_prefix)
      new_present? = index_exists?(@new_slug_index, @subscription_table, escaped_prefix)

      apply_subscription_slug_repair(old_present?, new_present?, prefix)
    end
  end

  # {old, new} presence -> action. `{false, _}` (already correct, or
  # neither exists) is intentionally not clauses-out below the `if
  # table_exists?` guard above — nothing to do either way.
  defp apply_subscription_slug_repair(true, false, prefix), do: rename_stale_slug_index(prefix)
  defp apply_subscription_slug_repair(true, true, prefix), do: drop_stale_slug_index(prefix)
  defp apply_subscription_slug_repair(false, _new_present?, _prefix), do: :ok

  defp rename_stale_slug_index(prefix) do
    qualified_old = prefix_table_name(@old_slug_index, prefix)

    # ALTER INDEX ... RENAME TO is metadata-only (no table rewrite, no
    # scan) — same operation V65 intended, just schema-qualified this
    # time. The target name is never schema-qualified: RENAME TO takes a
    # bare identifier and renames the object in place, in its own schema.
    execute("ALTER INDEX #{qualified_old} RENAME TO #{@new_slug_index}")
  end

  defp drop_stale_slug_index(prefix) do
    qualified_old = prefix_table_name(@old_slug_index, prefix)

    IO.warn(
      "PhoenixKit V164: both #{@old_slug_index} and #{@new_slug_index} exist on " <>
        "#{@subscription_table} — dropping the stale #{@old_slug_index} twin (both " <>
        "enforce the same UNIQUE(slug); keeping the correctly-named #{@new_slug_index})."
    )

    execute("DROP INDEX IF EXISTS #{qualified_old}")
  end

  # `pg_indexes` (schema-anchored via its own `schemaname` column, per
  # this chain's prefix-safety rule) rather than a `'schema.table'::regclass`
  # cast — this must survive being called against a name that may not
  # exist at all, and a cast raises in that case instead of returning no
  # rows (CLAUDE.md's 25P02 trap).
  defp index_exists?(index_name, table, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM pg_indexes
      WHERE indexname = '#{index_name}'
      AND tablename = '#{table}'
      AND schemaname = '#{escaped_prefix}'
    )
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  # Same schema anchor as `index_exists?/3`, but returns the indexdef text
  # instead of a bare boolean — `pg_indexes.indexdef` is the same
  # rendering `pg_get_indexdef/1` produces, so a partial index's `WHERE
  # (...)` clause is right there in the text and needs no separate
  # `pg_get_expr` probe.
  defp index_definition(index_name, table, escaped_prefix) do
    query = """
    SELECT indexdef FROM pg_indexes
    WHERE indexname = '#{index_name}'
    AND tablename = '#{table}'
    AND schemaname = '#{escaped_prefix}'
    """

    case repo().query(query, [], log: false) do
      {:ok, %{rows: [[definition]]}} -> {:present, definition}
      _ -> :absent
    end
  end
end
