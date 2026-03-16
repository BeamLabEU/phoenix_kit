# PR #418 — Fix review follow-ups, refactor architecture, and fix regression bugs

**Author:** Max Don
**Date:** 2026-03-16
**Base:** dev
**Files changed:** 21 (+369, -370)

## What

Follow-up to PR #412's code review. Addresses the remaining items: translation status contradictions, dialyzer warnings, dead code, throw/catch control flow, DBStorage leaking into the web layer, missing PubSub broadcasts, and 4 regression bugs from the facade migration.

## Why

PR #412 introduced the Publishing facade but left several review items open:
- Translation status could be set to "published" even when the primary language wasn't published (stale fixer would silently revert it)
- 22 direct DBStorage calls remained in the web layer, bypassing the facade architecture
- throw/catch was used for control flow instead of idiomatic `with` chains
- Missing broadcasts/cache regen on restore, version creation, and translation status changes
- 4 regression bugs: string vs atom key access, nil guards, slug validation bypass, trashed groups served publicly

## How (10 commits)

1. **Translation status contradiction** — Prevent publishing translations when primary language isn't published
2. **Dialyzer cleanup** — Remove 6 redundant nil guards, use Constants for mode check
3. **throw/catch → with chains** — Refactor posts.ex, versions.ex, translation_manager.ex
4. **Extract business logic** — Move `change_post_status` and `build_post_languages` out of web layer
5. **Remove all 22 DBStorage calls from web** — Route through Publishing facade
6. **Fix trashed groups served publicly** — Add missing `status` field to `db_group_to_map`
7. **Add missing PubSub broadcasts** — restore_post, create_version, set_translation_status
8. **Remove dead PubSub code** — 5 never-called broadcast functions, bulk operation stubs
9. **Fix string/atom key access** — KeyError from atom access on string-keyed group maps
10. **Fix nil crashes & slug collisions** — nil guard for empty post lists, unique slug generation
