# PR #446: Fix/Update to leaf editor 0.2.5

**Author**: @alexdont (Sasha Don)
**Reviewer**: @claude
**Status**: ✅ Merged
**Commit**: `4073072..a36e300` (2 commits)
**Date**: 2026-03-23

## Goal

Two unrelated fixes bundled together: bump the Leaf editor dependency to v0.2.5 and fix the media selector modal being hidden behind other overlays.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_web/live/components/media_selector_modal.html.heex` | `z-50` → `z-[10001]` on backdrop |
| `mix.exs` | `{:leaf, "~> 0.2"}` → `{:leaf, "~> 0.2.5"}` |
| `priv/static/assets/phoenix_kit.js` | CDN URL `leaf@v0.2.4` → `leaf@v0.2.5` |

## Review Notes

### Looks Good

1. **CDN URL and mix.exs are in sync** — both point to v0.2.5.
2. **Commit separation** — z-index fix and dep bump are in separate commits with clear messages.

### Issues

1. **`z-[10001]` is a magic number with no z-index strategy** — The codebase uses `z-50` (Tailwind's highest named tier, = 50) across ~15 elements: headers, sidebars, dropdowns, cookie consent banners, and other modals. Flash toasts use `z-[1000]`. Now the media selector jumps to `z-[10001]`. This creates an ad-hoc layering hierarchy (`50` → `1000` → `10001`) with no documented convention. The next modal that needs to be "on top" will pick `z-[10002]` or `z-[20000]`, and the escalation continues. A better approach would be to define a z-index scale (e.g., in a Tailwind config or CSS custom properties) so all overlays use consistent, predictable layers. At minimum, a comment explaining *why* 10001 (what specific element was it behind?) would help future developers.

2. **`{:leaf, "~> 0.2.5"}` is more restrictive than intended** — Hex version matching: `~> 0.2` allows `>= 0.2.0 and < 1.0.0`, while `~> 0.2.5` allows `>= 0.2.5 and < 0.3.0`. This means future `0.3.x` releases of Leaf will not resolve. If Leaf follows semver, `~> 0.2` was the more appropriate constraint (accepting patches and minor bumps). If the intent was to set a minimum patch version, `~> 0.2.5` works but is tighter than before. Worth confirming this was intentional.

3. **Committed JS bundle** — `priv/static/assets/phoenix_kit.js` is a built artifact with a CDN URL change. The comment on line 1765 still says `{:leaf, "~> 0.1.0"}` which is stale (should be `~> 0.2.5` or just removed). Minor, but stale comments in committed bundles accumulate.

### Non-blocking Suggestions

- Consider whether the media selector modal should use a Phoenix-level modal component (like the core `modal` component) which would centralize z-index management rather than each modal picking its own.
- The two changes (z-index fix + dep bump) are unrelated — cleaner as separate PRs for easier revert if either causes issues.
