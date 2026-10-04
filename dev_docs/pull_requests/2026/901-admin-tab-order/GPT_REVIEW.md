# PR #901 — GPT release recheck

Reviewed the published 2.52.0 tag (`72c9b8127`) against 2.51.0.

No additional defect found. Core applies its known-module positions to top-level module tabs, then the registry applies host overrides on each entry path. Priority ties use tab ids, and dynamic-child parents retain their sorted positions. Subtabs are retrieved by parent id across groups, so moving a parent does not orphan its children.

Claude's documented limitations remain: boot-time tabs cannot target a custom group registered later, unlisted modules keep their own priority, and host order applies only to `level: :admin` tabs. These do not invalidate the implemented ordering behavior.

See the [complete release recheck](../../../reviews/2026-10-04-2.52.0-release/GPT_REVIEW.md) for validation and package provenance.
