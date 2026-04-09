# PR #480 Review — Fix installer to auto-inject PhoenixKitHooks into app.js

**Reviewer:** Pincer 🦀
**Date:** 2026-04-08
**Verdict:** Approve

---

## Summary

Broader than the title suggests. 5 files, ~311 lines:

1. **JS installer fix** — Auto-injects `PhoenixKitHooks` into `app.js` during install. Three strategies: hooks exist → spread, no hooks → add option, can't detect → manual notice.
2. **Activity logging** — `log_activity/4` calls for setup, connect, disconnect, token refresh, validation
3. **Decrypt fix after legacy migration** — `get_integration` now decrypts data after migrating legacy keys (was missing)
4. **Simplified status** — Removed `configured` status, now just `connected` or `disconnected`
5. **Validation improvements** — Checks provider exists before credentials check
6. **Cookie max_age** — Set to 60 days
7. **OAuth remember_me** — Passed by default
8. **Test fix** — Registers/unregisters custom permission key properly

---

## What Works Well

1. **Three-strategy JS injection** — Handles existing hooks, missing hooks, and undetectable cases. Robust.
2. **Decrypt fix is critical** — Legacy migrated data was being returned encrypted. Good catch.
3. **Activity logging** — Useful for debugging integration issues in production
4. **Status simplification** — `configured` was confusing. `connected`/`disconnected` is clearer.

---

## Issues and Observations

### 1. OBSERVATION: PR title understates scope
Title says "fix installer" but this also touches Integrations, auth, cookies, and tests. Not a blocker, just noting.

### 2. OBSERVATION: Activity logs in settings table
Same pattern as document creator — activity logs stored as settings entries. Will grow over time. Not a blocker for now.

---

## Post-Review Status

No blockers. Ready for precommit and release.
