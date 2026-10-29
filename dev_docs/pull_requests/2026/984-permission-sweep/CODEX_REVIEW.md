# PR #984 — Role, settings and session permission boundaries

**Reviewer:** Codex · **Date:** 2026-10-29 · **Baseline:** `38a116bc4`

### BUG - HIGH — revocation could use stale preloaded roles (fixed)

`Sessions.revoke_session/2` and `revoke_user_sessions/2` passed user structs to the rank predicate. `Auth.can_manage_user_status?/2` deliberately uses an already loaded `roles` association for rendering efficiency. A caller retaining a preloaded Admin after the role was revoked could therefore end another person's sessions. Likewise, a preloaded ordinary target promoted to Admin after a dialog opened could still have their sessions revoked by another Admin.

The mutation paths now force a fresh, batched preload of both people's roles before evaluating the existing rank rule. The public display predicate keeps its rendering behavior. System callers and self-revocation retain their existing contracts; explicit invalid actors fail closed.

Added two integration regressions: a preloaded target promoted after loading, and a preloaded actor stripped of Admin. Both failed before the fix (sessions were actually deleted), then passed with it. Existing tests still cover Owner protection, ordinary users, self-revocation, system callers and confirmation-time target promotion on the Sessions page.

Also checked role permission subset decisions and error-aware readers, `actor:` propagation, the form key allowlist and locked security keys, required default-role fields, privilege backfills and page gates. No further change made to those paths.

## Validation

See the [batch validation record](../2026-10-29-recent-merges/CODEX_REVIEW.md).
