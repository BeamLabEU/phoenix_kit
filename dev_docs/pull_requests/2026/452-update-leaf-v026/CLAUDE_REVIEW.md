# PR #452 Review: Update Leaf Dependency to v0.2.6

**Reviewer:** Claude (Anthropic)
**PR:** [#452](https://github.com/BeamLabEU/phoenix_kit/pull/452)
**Author:** Sasha Don (@alexdont)
**Base:** dev ← dev (1 commit)
**Scale:** 2 files changed, +2 / -2

## Overview

Bumps the Leaf content editor dependency from `~> 0.2.5` to `~> 0.2.6` and updates the corresponding CDN URL for the JS bundle.

**Verdict: Approve.** Routine dependency bump, correctly updates both the Hex version constraint and the CDN asset URL in lockstep.

---

## Changes

| File | Change |
|------|--------|
| `mix.exs:113` | `{:leaf, "~> 0.2.5"}` → `{:leaf, "~> 0.2.6"}` |
| `priv/static/assets/phoenix_kit.js:1769` | CDN URL `leaf@v0.2.5` → `leaf@v0.2.6` |

No issues found. Both references updated consistently.
