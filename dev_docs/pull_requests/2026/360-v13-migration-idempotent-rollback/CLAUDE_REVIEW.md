# PR #360 — Fix V13 migration down/0 to use remove_if_exists for idempotency

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/360
**Author:** @construct-d
**Merged:** 2026-02-24 into `dev`
**Additions:** +18 | **Deletions:** -13
**Reviewer:** Claude Sonnet 4.6

---

## Executive Summary

Small, targeted, correct fix. The V13 `down/0` was using bare `remove` instead of `remove_if_exists`, causing rollbacks to crash with a "column does not exist" error on databases that hadn't fully applied V13. The fix brings V13 in line with the idempotency standard every PhoenixKit migration `down/0` should meet.

**Verdict: Clean fix. No concerns. Correctly merged.**

---

## Code Review

### Column Removals: Correct

The nine `remove` → `remove_if_exists` changes are straightforward and correct. `remove_if_exists` requires an explicit column type as its second argument:

```elixir
remove_if_exists :aws_message_id, :string
remove_if_exists :bounced_at, :utc_datetime_usec
# etc.
```

The types match what `up/0` adds. This is the standard pattern everywhere else in PhoenixKit migrations.

### Index Drop: Correct and Slightly Improved

The original `down/0` index drop:

```elixir
drop_if_exists unique_index(:phoenix_kit_email_logs, [:aws_message_id],
                 prefix: prefix,
                 name: "phoenix_kit_email_logs_aws_message_id_index",
                 where: "aws_message_id IS NOT NULL"
               )
```

Was replaced with:

```elixir
drop_if_exists index(
                 :phoenix_kit_email_logs,
                 [:aws_message_id],
                 prefix: prefix,
                 name: :phoenix_kit_email_logs_aws_message_id_index
               )
```

**`unique_index` → `index`:** Correct. When dropping, you're identifying the object, not recreating it. `index/2` is the right function for referencing an existing index. Using `unique_index/3` with `where:` in a drop context makes Ecto build an index struct with those options — the `where:` predicate is irrelevant for Postgres `DROP INDEX` but can affect how Ecto's `drop_if_exists` constructs its existence query.

**String → atom for `name:`:** Minor improvement. Atom is the conventional form for named database objects in Ecto. Both work, but atom is idiomatic and avoids a subtle risk where string vs atom doesn't match in some Ecto version edge cases.

**`where:` removed:** Correct for a drop-by-name operation. The partial index condition was part of the index's creation — it's not part of its name or identity for the purposes of dropping.

---

## Migration Pattern Alignment

The fix brings V13 into alignment with the project's established idempotency standard:

| Migration | `down/0` approach |
|-----------|------------------|
| V12 and earlier | Uses `remove_if_exists` ✓ |
| V13 (before fix) | Used bare `remove` ✗ |
| V13 (after fix) | Uses `remove_if_exists` ✓ |
| V14+ | Uses `remove_if_exists` ✓ |

This was a one-off gap where V13 was written without following the pattern. No systemic issue.

---

## Testing Considerations

There are no automated tests for this fix (migration rollbacks aren't unit tested in PhoenixKit — integration testing happens in parent apps). The fix is correct by inspection:

- `remove_if_exists` is an Ecto migration primitive specifically designed for idempotent column removal
- `drop_if_exists index(...)` is already used elsewhere in down functions
- The column types in `remove_if_exists` match the `add` calls in `up/0`

Manual verification: rolling back V13 on a fresh database (where V13 was never applied) would previously crash; after this fix it succeeds silently.

---

## No Concerns

This is a pure correctness fix with no behavioral changes to the `up/0` path, no schema changes, and no application logic affected. The CHANGELOG entry and version bump (1.7.46 → 1.7.47) are appropriate.
