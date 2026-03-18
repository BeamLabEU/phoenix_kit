# PR #432 Review — Update Leaf to v0.2.2 with new function component API

**Reviewer:** Claude
**Date:** 2026-03-18
**PR:** Update Leaf to v0.2.2 with new function component API
**Author:** Sasha Don (alexdont)

## Summary

Four commits:

1. **Leaf v0.2.2 upgrade** — Replace `<.live_component module={Leaf}>` with `<.leaf_editor>` function component. Dep bumped `~> 0.2.1` → `~> 0.2.2`. CDN URL updated. Posts editor also gets the import.
2. **Editor refactor** — Extract `update_meta` handler into 3 helper functions (`prepare_meta_params`, `process_slug_updates`, `assign_meta_updates`) to reduce cyclomatic complexity from 13 to under 12 for credo strict.
3. **Dialyzer fixes** — Prefix unused `group_slug` param with underscore in `skip_already_translated`. Remove unreachable `{:error, reason}` pattern in `log_remote_notification`.

## Verdict: Approve — no action needed

Clean PR with no issues.

---

## Analysis

### Leaf component migration (Correct)

The `live_component` → function component migration is straightforward:
- `edit.ex` adds `import Leaf, only: [leaf_editor: 1]`
- Template changes `<.live_component module={Leaf}` → `<.leaf_editor`
- All other attributes remain unchanged

### Editor refactor (Correct)

The refactor is a pure extraction — logic is identical to before. One subtle point worth verifying:

`assign_meta_updates` reads `socket.assigns.slug_manually_set` and `socket.assigns.url_slug_manually_set` (lines 1066-1067). This is correct because the incoming socket (`socket_with_slug`) already has these values assigned by `maybe_generate_slug_from_title` (lines 1550-1551 in the same file). The refactor preserves the original behavior.

### Dialyzer fixes (Correct)

- **`_group_slug`**: The parameter was indeed unused in `skip_already_translated` — it resolves versions by `post_uuid`, not group slug.
- **Removed `{:error, reason}` clause**: `notify_remote_site` always returns `{:ok, result}` — even HTTP errors are wrapped as `{:ok, %{success: false, ...}}` (line 153 in `connection_notifier.ex`). The removed clause was genuinely unreachable.

### CDN URL update (Correct)

`phoenix_kit.js` CDN pointer updated from `@v0.2.1` to `@v0.2.2`. Consistent with the Hex dependency bump.

---

## No action items

This PR is clean. No bugs, no security concerns, no style issues. The changes have already been pulled into our `dev` branch via the `git pull` we did.
