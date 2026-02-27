# UUIDv4 Documentation Cleanup Audit

**Date**: 2026-02-27
**Scope**: Documentation and code referencing UUIDv4 patterns instead of UUIDv7
**Status**: Fixed

## Summary

Audit of all UUIDv4/`Ecto.UUID` references across documentation and code to ensure consistency with the completed UUIDv7 migration. Found 4 documentation issues and 1 code issue; all fixed.

---

## Issues Found & Fixed

### 1. `AGENTS.md` — Outdated UUID section

**Before:**
```markdown
## IN-PROGRESS: UUID Migration (V40)
> DELETE THIS SECTION after the UUID migration is fully complete and merged to main.
- All schemas have `field :uuid, Ecto.UUID`
- User schema generates UUID in Elixir; others use DB DEFAULT
```

**Problem:** Section was marked "IN-PROGRESS" and referenced `Ecto.UUID` (UUIDv4 type), but the migration is complete — all 69 schemas now use `@primary_key {:uuid, UUIDv7, autogenerate: true}`.

**Fix:** Rewrote the section to reflect the completed migration with both Pattern 1 and Pattern 2 descriptions, and replaced `Ecto.UUID` with `UUIDv7`.

---

### 2. `dev_docs/status/2026-02-05-uuid-module-status.md` — Old "New Standard Pattern" example

**Before:**
```elixir
schema "phoenix_kit_*" do
  field :uuid, Ecto.UUID, read_after_writes: true
  # ... other fields
end
```

**Problem:** Showed the intermediate pattern (`field :uuid, Ecto.UUID`) that was used before the primary key migration. The actual current pattern uses `@primary_key {:uuid, UUIDv7, autogenerate: true}`.

**Fix:** Updated to show the current pattern:
```elixir
@primary_key {:uuid, UUIDv7, autogenerate: true}

schema "phoenix_kit_*" do
  field :id, :integer, read_after_writes: true  # legacy, DB generates via SERIAL
  # ... other fields
end
```

---

### 3. `dev_docs/status/2026-02-05-uuid-module-status.md` — Outdated "ID Usage Rules"

**Before:**
| Use Case | Field | Example |
|----------|-------|---------|
| Foreign keys | `.id` | `parent_id: item.id` |
| Database queries | `.id` | `repo.get(Item, id)` |
| Event handlers (phx-value) | `.id` | `phx-value-id={item.id}` |

**Problem:** Contradicted the `_uuid` naming convention established during the migration. All code now uses `.uuid` and `phx-value-uuid`.

**Fix:** Renamed to "UUID Usage Rules" and updated all examples to use `.uuid`, `phx-value-uuid`, and `user_uuid: user.uuid`.

---

### 4. `dev_docs/pull_requests/TEMPLATE.md` — Example schema change

**Before:**
```elixir
field :uuid, Ecto.UUID
```

**Problem:** PR template example showed the old `Ecto.UUID` type, which would be copy-pasted into future PR descriptions.

**Fix:** Changed to `field :uuid, UUIDv7`.

---

### 5. `lib/phoenix_kit_web/router.ex:41` — `Ecto.UUID.generate()` in code

**Before:**
```elixir
Plug.Conn.put_session(conn, :phoenix_kit_session_uuid, Ecto.UUID.generate())
```

**Problem:** `Ecto.UUID.generate()` produces UUIDv4 (random). While session UUIDs don't go to indexed DB columns, this was the last remaining UUIDv4 generation call in the codebase.

**Fix:** Changed to `UUIDv7.generate()` for consistency.

---

## Not Changed (Legitimate References)

These references to UUIDv4 were reviewed and intentionally left unchanged:

### Comparison tables in migration guides

| File | Lines | Reason |
|------|-------|--------|
| `dev_docs/guides/2025-12-25-uuid-migration-guide.md` | 9, 278-286 | FAQ explaining why UUIDv7 > UUIDv4 |
| `dev_docs/guides/2026-02-17-uuid-migration-instructions-v3-guide.md` | 38-51 | "Correct vs Wrong" comparison table |

These are educational references that explain *why* UUIDv7 was chosen over UUIDv4. Removing them would lose valuable context.

### V56 migration moduledoc

| File | Line | Reason |
|------|------|--------|
| `lib/phoenix_kit/migrations/postgres/v56.ex` | 24 | Historical: documents that V45/V46/V53 used `gen_random_uuid()` (UUIDv4) |

This is an accurate historical record of what V56 fixed. The migration itself correctly uses `uuid_generate_v7()`.

### `Ecto.UUID.cast/1` and `Ecto.UUID.dump/1` in code

| File | Usage | Reason |
|------|-------|--------|
| `lib/phoenix_kit/utils/uuid.ex` | `Ecto.UUID.cast/1` | Validation — works with any UUID format |
| `lib/modules/shop/shop.ex` | `Ecto.UUID.dump/1`, `Ecto.UUID.cast/1` | Binary encoding for raw SQL, validation |
| `lib/modules/shop/options/options.ex` | `Ecto.UUID.cast/1` | Validation |
| `lib/modules/shop/web/imports.ex` | `Ecto.UUID.cast/1` | Validation |
| `lib/modules/shop/slug_resolver.ex` | `Ecto.UUID.cast/1` | Validation |
| `lib/modules/db/db.ex` | `Ecto.UUID.cast/1` | Validation |
| `lib/modules/billing/billing.ex` | `Ecto.UUID.cast/1` | Validation |

`Ecto.UUID` is Ecto's built-in UUID type for casting and validation. It accepts both UUIDv4 and UUIDv7 strings — it's format-agnostic. These are **not** UUIDv4 generation calls; they're standard Ecto type operations.

### Schema field types using `Ecto.UUID`

| File | Field | Reason |
|------|-------|--------|
| `lib/modules/shop/schemas/category.ex` | `field :image_uuid, Ecto.UUID` | References external resource UUID (no FK) |
| `lib/modules/shop/schemas/product.ex` | `field :featured_image_uuid, Ecto.UUID` | References external resource UUID (no FK) |
| `lib/modules/shop/schemas/product.ex` | `field :file_uuid, Ecto.UUID` | References external resource UUID (no FK) |
| `lib/modules/shop/schemas/product.ex` | `field :image_ids, {:array, Ecto.UUID}` | Array of external UUIDs |
| `lib/modules/comments/schemas/comment.ex` | `field :resource_uuid, Ecto.UUID` | Polymorphic resource reference |

These fields store UUID values but are not primary keys or autogenerated fields. `Ecto.UUID` is the correct Ecto type for storing/casting any UUID value. `UUIDv7` type is only needed for fields that autogenerate UUIDs.

### Historical PR review files

PR review files in `dev_docs/pull_requests/2026/` document what the code looked like at review time. Updating them would falsify the historical record.

---

## Verification

```bash
# No Ecto.UUID.generate() calls remain in lib/
rg 'Ecto\.UUID\.generate' lib/  # 0 matches

# No field :uuid, Ecto.UUID declarations remain in lib/
ast-grep --lang elixir --pattern 'field :uuid, Ecto.UUID' lib/  # 0 matches

# All schemas use UUIDv7 primary key
ast-grep --lang elixir --pattern '@primary_key {:uuid, UUIDv7, $$$}' lib/  # 69 matches

# Compiles cleanly
mix compile  # success (pre-existing warnings in variant_generator.ex unrelated)
```

---

## Key Distinction: `Ecto.UUID` vs `UUIDv7`

| Module | Purpose | Generates UUIDs? | UUID Version |
|--------|---------|-----------------|--------------|
| `Ecto.UUID` | Ecto's built-in UUID type — cast, dump, load, validate | `generate/0` produces **UUIDv4** | Format-agnostic for cast/dump |
| `UUIDv7` | Custom Ecto type for PhoenixKit — cast, dump, load, autogenerate | `generate/0` produces **UUIDv7** | Time-ordered |

**Rule of thumb:**
- **Generating UUIDs**: Always use `UUIDv7.generate()` or DB `uuid_generate_v7()`
- **Primary keys**: Always use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- **Validating/casting UUIDs**: `Ecto.UUID.cast/1` is fine (format-agnostic)
- **Non-PK UUID fields**: `Ecto.UUID` type is fine (no autogeneration needed)
