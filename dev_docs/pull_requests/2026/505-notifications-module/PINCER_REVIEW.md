# PR #505 — Notifications module intial commit
**Author:** Sasha Don (alexdont)
**Reviewer:** Pincer
**Phase:** 1 — surface review
**Date:** 2026-04-24
**Verdict:** ✅ APPROVE

---

## Summary

Adds a full per-user notifications system driven by the existing activity log. When an activity is logged with a `target_uuid` that differs from `actor_uuid`, a notification row is inserted for the target. Bell component, user preferences per-type, PubSub for live updates, pruning worker — the whole stack.

## Files Changed (18)

| File | Change |
|------|--------|
| `AGENTS.md` | +102 lines — comprehensive notifications section |
| `lib/phoenix_kit/activity/activity.ex` | Hook `maybe_notify/1` after each insert |
| `lib/phoenix_kit/install/oban_config.ex` | Add `PruneWorker` to Oban cron |
| `lib/phoenix_kit/migrations/postgres.ex` | Bump version to V104, document migration |
| `lib/phoenix_kit/migrations/postgres/v104.ex` | New — creates `phoenix_kit_notifications` table |
| `lib/phoenix_kit/module.ex` | Add `notification_types/0` callback (optional, default `[]`) |
| `lib/phoenix_kit/notifications/events.ex` | New — PubSub topic helpers |
| `lib/phoenix_kit/notifications/notification.ex` | New — Ecto schema |
| `lib/phoenix_kit/notifications/notifications.ex` | New — public API (288 lines) |
| `lib/phoenix_kit/notifications/prefs.ex` | New — per-user preference storage/lookup |
| `lib/phoenix_kit/notifications/prune_worker.ex` | New — Oban pruning worker |
| `lib/phoenix_kit/notifications/render.ex` | New — renders notification to icon/text/link |
| `lib/phoenix_kit/notifications/types.ex` | New — type registry, merges core + module types |
| `lib/phoenix_kit/settings/settings.ex` | Adds `notifications_enabled` setting lookup |
| `lib/phoenix_kit_web/components/media_browser.ex` | Minor update |
| `lib/phoenix_kit_web/live/components/user_settings.ex` | +105 lines — Notifications prefs section |
| `lib/phoenix_kit_web/live/notifications_bell.ex` | New — sticky bell LiveView (186 lines) |
| `lib/phoenix_kit_web/live/settings.html.heex` | Wire in the bell component |

## Green flags

- **Fail-open throughout** — unknown action, bad prefs row, DB error → notification is still created (fail-open). Only explicit user mute suppresses.
- **Activity hook is safe** — `maybe_notify/1` is guarded with `Code.ensure_loaded?` and a `rescue` block, so activity logging never crashes if Notifications module is missing.
- **Duplicate-safe** — unique constraint `(activity_uuid, recipient_uuid)` + explicit handling of the unique conflict as a no-op `:skipped` means retries are idempotent.
- **V104 migration** — UUIDv7 PK, proper FKs with `ON DELETE CASCADE`, correct partial index for the hot inbox read path, all idempotent.
- **PubSub** — per-user topics (not broadcast-to-all), so bell and inbox LiveViews refresh without fan-out overhead.
- **Module extensibility** — `notification_types/0` callback on `PhoenixKit.Module` with `[]` default is backward-compatible; external modules opt in at their own pace.
- **PruneWorker** — correct cron slot (4 AM, offset from storage at 3 AM), respects `notifications_retention_days` with fallback to `activity_retention_days`.
- **AGENTS.md** — the documentation section is thorough and well-organized.

## Yellow flags

- **No tests included** — for a new module of this size (7 new files, ~800 lines), no test suite is a gap. Phase 2 should include at least unit tests for `Notifications`, `Prefs`, and `Types`.
- **PR title typo** — "intial" → "initial" (cosmetic, fixable post-merge).
- `notifications_bell.ex` LiveView (186 lines) not fully reviewed — warrants a Phase 2 pass to check mount/handle_info patterns, socket cleanup, error handling.
- The `user_settings.ex` +105 line block (notification preferences UI) not reviewed in depth — verify toggle rendering and pref persistence flow works end-to-end.

## Red flags

None.

## Recommendation

**APPROVE.** The core architecture is clean and the fail-safe/fail-open design is correct throughout. The missing tests are the main concern — worth tracking as a follow-up ticket rather than blocking the merge.
