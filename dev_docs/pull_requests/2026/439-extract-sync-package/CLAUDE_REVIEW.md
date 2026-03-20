# Claude Review — PR #439: Extract Sync Module

**Verdict:** Approve — clean, thorough extraction

## Extraction Completeness

Verified the extraction across all integration points. Every Sync touchpoint was properly removed:

| Integration Point | Status | Notes |
|------------------|--------|-------|
| Source files (31 files, ~16.5K lines) | Removed | Entire `lib/modules/sync/` deleted |
| Route definitions (API + admin + WebSocket) | Removed | 90 lines from `integration.ex` |
| Endpoint socket mount | Removed | `/sync` socket from `endpoint.ex` |
| Oban queue + installer | Removed | `sync: 5` queue, `ensure_sync_queue/2` |
| Admin nav icon | Removed | Icon mapping in `admin_nav.ex` |
| Modules page card | Removed | 52-line card in `modules.html.heex` |
| Sitemap exclusion | Removed | `^/sync` pattern from `router_discovery.ex` |
| Config | Removed | `sync: 5` from `config.exs` |
| README docs | Updated | Feature list, counts, examples, routes |
| Module guide | Updated | Plugin reference name corrected |
| Permissions doc | Updated | 25→24 count |
| Tests | Updated | All count assertions adjusted |

## Leftover Reference Audit

Searched entire `lib/` (excluding `migrations/`) for sync references:

- `"sync"` — only in `module_registry.ex:443` as external package key. **Correct** — this is the key for the extracted package.
- `db-sync`, `phoenix_kit_socket` — only in `endpoint_integration.ex` which handles cleanup of the deprecated macro from parent apps. **Correct** — this is forward-compatible infrastructure.
- Migration files (V37, V40, V44, V56, V58, V74) — all sync table references. **Correct** — intentionally preserved as historical records.

**No stale references found.**

## What's Good

1. **External package registration is well-designed.** `known_external_packages/0` in `ModuleRegistry` provides the "not installed" card on admin Modules page with hex link, description, and icon. When the dep is added, beam scanning auto-discovers it — zero config.

2. **Deprecated macro handled gracefully.** `endpoint_integration.ex` removes `phoenix_kit_socket()` from parent apps during install/update, with clear comments explaining why. Users upgrading won't hit compile errors.

3. **Migration files preserved.** This is the right call — the versioned migration system needs these for multi-version upgrades. The sync tables remain in the DB and will be reused by the external package.

4. **Permission key preserved via V53 seed.** The `sync` permission key stays seeded in the database. When `phoenix_kit_sync` is installed, it reuses this key without needing a new migration.

5. **Test updates are precise.** Count assertions updated (21→20 modules, 25→24 permissions, 20→19 feature keys), Sync removed from `@all_internal_modules`. No over-corrections.

## Observations

### The module guide reference update

Commit 1 (`62fb85fd`) renames `phoenix_kit_doc_forge/` to `phoenix_kit_document_creator/` in the module system guide. This is unrelated to the Sync extraction — it's a rename of a different plugin reference. Harmless but should ideally be a separate commit for git-bisect clarity.

### Permission count in `permissions.ex`

The moduledoc string was updated from 25→24 keys. This is a documentation-only change (the actual count is derived at runtime from registered modules), so it's cosmetic but correct.

### `config.exs` queue removal

The `sync: 5` queue was removed from PhoenixKit's own dev config. Parent apps that have already installed PhoenixKit will still have `sync: 5` in their own config — this is harmless (Oban ignores queues with no workers), but could be noted in upgrade docs for the external package.

## Testing Notes

- Verify `mix compile` succeeds with no warnings about missing Sync modules
- Verify admin Modules page shows "Not Installed" card for Sync when `phoenix_kit_sync` dep is absent
- Verify existing parent apps with `sync: 5` queue in config don't error
- Verify `endpoint_integration.ex` correctly removes `phoenix_kit_socket()` during `mix phoenix_kit.update`
