# KIMI_REVIEW.md — PR #349

**Reviewer:** Kimi Code CLI
**Date:** 2026-02-19
**Verdict:** Approve with minor observations

---

## Executive Summary

This PR delivers three well-scoped fixes that improve architectural consistency and address review feedback from PR #341. The implementation demonstrates solid engineering judgment with thoughtful backwards compatibility and comprehensive test coverage.

| Area | Assessment | Notes |
|------|------------|-------|
| Entities Multilang Title Unification | ✅ Strong | Consolidates fragmented storage, proper migration strategy |
| Rekey Logic Fix | ✅ Correct | Semantically accurate override recomputation |
| Permissions Follow-ups | ✅ Clean | Error atoms, boundary fixes, UI polish |
| Test Coverage | ✅ Excellent | 165 new lines + updates, good edge cases |
| Documentation | ✅ Updated | 88+ namespace fixes, technical accuracy |

---

## Detailed Review

### 1. Entities Multilang Title Unification

**The Problem:**
Titles lived in `metadata["translations"][lang]["title"]` while all other translatable fields used `data[lang][field]`. This fragmentation meant:
- Different code paths for title vs. field translations
- Inconsistent merge/override logic
- Technical debt in multilang implementation

**The Solution:**
Unified storage using `data[lang]["_title"]` with the same override-only pattern as custom fields.

**Key Implementation Strengths:**

1. **Priority chain in `get_title_translation/2`:**
   ```elixir
   # JSONB _title → metadata fallback → title column
   ```
   This ensures unmigrated records continue working while new records use the unified path.

2. **Lazy migration in `seed_title_in_data/2`:**
   - Migration happens on mount, not at deployment
   - Non-destructive — original data preserved until save
   - No downtime required for existing records

3. **Consistent `_` prefix convention:**
   - `_title` alongside `_primary_language`
   - Clear distinction between system keys and user field keys
   - Field validation already rejects keys starting with `_`

**Observation:** The migration is primary-language-gated. Once the primary language has `_title`, `seed_title_in_data/2` skips entirely. This means secondary languages may continue using the metadata fallback until explicitly edited. This is an acceptable trade-off for zero-downtime migration but means the fallback code path will live longer.

---

### 2. Rekey Logic Fix

**The Bug:**
When promoting a secondary language to primary via `rekey_primary/2`, secondary overrides were left untouched. Since overrides are computed *relative to primary*, this was semantically wrong — a Spanish override of `"color": "rojo"` means "differs from English primary," but after rekeying (German becomes primary), that same override is now incorrect.

**The Fix:**
`recompute_all_secondaries/4` correctly:
1. Reconstructs full data for each secondary: `Map.merge(old_primary_data, lang_data)`
2. Computes new overrides against the promoted primary: `compute_overrides(full, promoted)`
3. Removes languages with zero overrides (they match new primary exactly)

**Code Quality:**
```elixir
defp recompute_all_secondaries(data, new_primary, promoted, old_primary_data) do
  Enum.reduce(data, data, fn
    {lang, lang_data}, acc when is_map(lang_data) and lang != new_primary ->
      full_lang_data = Map.merge(old_primary_data, lang_data)
      overrides = compute_overrides(full_lang_data, promoted)
      put_or_remove_language(acc, lang, overrides)
    # ...
  end)
end
```
- Clean reduction pattern
- Proper filtering of the promoted language
- Idempotent (rekeying twice produces same result)

**Test Coverage:**
- Override recomputation verified
- Round-trip preservation confirmed
- Secondary removal when matching new primary
- Flat data and nil data edge cases handled

---

### 3. Permissions Review Follow-ups

#### Error Atoms (Excellent Pattern)

Changed from:
```elixir
{:error, "You cannot edit your own role's permissions"}
```

To:
```elixir
{:error, :self_role}
```

**Why this matters:**
- Error identity separated from display text
- Enables proper i18n via `permission_error_message/1`
- Callers can pattern match on atoms for logic decisions
- Easier to maintain and test

**Implementation:**
```elixir
defp permission_error_message(:not_authenticated), do: gettext("You must be logged in")
defp permission_error_message(:owner_immutable), do: gettext("Owner role permissions cannot be modified")
defp permission_error_message(:self_role), do: gettext("You cannot edit your own role's permissions")
defp permission_error_message(:admin_owner_only), do: gettext("Only Owner or Admin can modify permissions")
defp permission_error_message(_), do: gettext("Permission denied")
```
- Catch-all fallback prevents crashes on unknown atoms
- All messages properly wrapped in gettext

#### System Role Self-Edit Logic

```elixir
role.name in user_roles and not Scope.system_role?(scope) ->
  {:error, :self_role}
```

This is the right call. System role users (Owner, Admin) are trusted to edit roles they hold. An Admin+Editor can now edit Editor permissions. The hierarchy checks (`Scope.owner?/1`, `Scope.admin?/1`) still enforce the critical boundaries.

#### Catch-All Scope Fallbacks

Changed guarded clauses to catch-all patterns:
```elixir
# Before
def has_role?(%__MODULE__{user: nil}, _role_name), do: false

# After  
def has_role?(_, _role_name), do: false
```

**Trade-off:** Prevents FunctionClauseError for malformed scopes but could mask bugs. Given these functions are only called with session-derived scopes, this is a pragmatic choice for production robustness.

#### UUID Fix in `auto_grant_to_admin_roles`

Correctly changed from integer `id` to `%{uuid: admin_uuid}` to match `grant_permission/3` signature. Good catch.

#### CSS Columns Layout

Fixed a real UI bug where `grid-cols-2` with a single inner `div` put all items in the first column. The `columns-1 md:columns-2` with `break-inside-avoid` approach correctly distributes items.

---

### 4. Test Coverage Analysis

| Test File | Lines | Coverage |
|-----------|-------|----------|
| `title_translation_test.exs` | 165 (new) | JSONB, metadata fallback, column fallback, priority, inheritance |
| `entity_data_test.exs` | 7 updated | Rekey override recomputation, round-trip |
| `permissions_test.exs` | Updated | Error atoms, system role self-edit |

**Strengths:**
- Pure function testing (no DB required for translation logic)
- Edge cases covered: empty strings, nil values, missing languages
- Priority chain verified: JSONB > metadata > column
- Idempotency tested for rekey operations

**Minor Gap:** No test explicitly verifies the migration path where primary has `_title` but secondary doesn't (the gradual migration scenario). However, the fallback logic is tested individually.

---

### 5. Documentation Updates

**88+ namespace fixes:** `PhoenixKit.Entities` → `PhoenixKit.Modules.Entities`

**Technical corrections:**
- Field type count: 11 → 12 (file type registered)
- `utc_datetime_usec` → `utc_datetime` (aligns with PR #347)

These were much-needed updates. Documentation drift is real, and keeping it aligned with code structure is important for developer experience.

---

## Minor Observations

### 1. Double Injection Pattern

In both `handle_event("validate", ...)` and `handle_event("save", ...)`:

```elixir
form_data = inject_title_into_form_data(form_data, data_params, current_lang, socket.assigns)
# ... FormBuilder.validate_data strips unknown keys ...
validated_data = inject_title_into_form_data(validated_data, data_params, current_lang, socket.assigns)
```

**Impact:** Functionally correct but runs the same logic twice. The second injection is necessary because `FormBuilder.validate_data` only preserves known field keys.

**Future Improvement:** Consider having `FormBuilder.validate_data` accept a `preserve_keys` option or automatically preserve `_`-prefixed keys.

### 2. Gradual Migration Timeline

The lazy migration strategy means:
- Records edited frequently will migrate quickly
- Dormant records will retain metadata fallback indefinitely
- The fallback code path cannot be removed until all records are migrated

**Suggestion:** Consider a one-time Mix task for bulk migration:
```elixir
mix phoenix_kit.entities.migrate_titles
```

This would allow faster cleanup of the transitional code.

### 3. Slug Generation Disabled on Secondaries

The PR disables the slug generation button on secondary language tabs. This is correct behavior (slugs are derived from primary language), but worth noting as a UX change.

---

## Suggestions for Future Work

1. **Bulk Migration Task:** One-time task to migrate all titles from metadata to JSONB, enabling eventual removal of fallback code.

2. **FormBuilder Enhancement:** Add option to preserve specific keys during validation to eliminate double injection.

3. **Cleanup Timeline:** Set a deprecation milestone (e.g., V60) to remove metadata fallback after sufficient migration time.

4. **Test Addition:** Consider adding a test for the partial migration state (primary migrated, secondary not).

---

## Verdict

**Approve.**

This PR successfully addresses three distinct areas with clean, well-tested implementations:

1. **Architectural Improvement:** Title unification eliminates design inconsistency
2. **Correctness Fix:** Rekey logic now properly recomputes overrides
3. **Code Quality:** Error atoms enable i18n, permissions logic is cleaner

The backwards compatibility strategy is thoughtful, test coverage is comprehensive, and documentation is updated. The minor observations noted are not blocking issues and can be addressed in future iterations.

**Risk Assessment:** Low. Changes are well-scoped, thoroughly tested, and include proper fallback handling.

**Recommended Action:** Merge to `dev` and monitor for any edge cases in staging before release.
