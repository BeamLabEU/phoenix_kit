# PR #505 — Notifications module initial commit
**Author:** Sasha Don (alexdont)
**Reviewer:** Claude
**Date:** 2026-04-24
**Verdict:** ✅ APPROVE with follow-ups

---

## Summary

Adds `PhoenixKit.Notifications`: a per-user inbox that fans out from `Activity.log/1` whenever an activity targets a user other than the actor. Ships with a V104 migration, the `phoenix_kit_notifications` schema, a public context API (create / list / mark-seen / dismiss / prune), a Render module mapping actions to human text, a Types registry extensible via an optional `notification_types/0` Module callback, per-user preferences stored in `custom_fields.notification_preferences`, an Oban PruneWorker, a sticky nested `NotificationsBell` LiveView, and the per-user prefs toggle row in `UserSettings`. Admins still audit via `/admin/activity` and don't receive notifications — avoids drowning high-traffic systems.

Read Pincer's Phase 1 review for the high-level green/yellow flags; this review is the deeper pass they left open.

## Findings

### BUG - HIGH — `Render.render/1` first clause matches `Ecto.Association.NotLoaded` and crashes

File: `lib/phoenix_kit/notifications/render.ex:28-50`

```elixir
def render(%Notification{activity: %_{} = activity}) do
  meta = activity.metadata || %{}
  ...
end

def render(%Notification{} = _notification) do
  # "Activity wasn't preloaded — render a safe fallback."
  %{icon: "hero-bell", text: "You have a new notification.", ...}
end
```

`%_{}` matches **any** struct, including `%Ecto.Association.NotLoaded{}`, which is the exact value `notification.activity` holds when the association isn't preloaded. The first clause matches, then `activity.metadata` raises `KeyError` because `NotLoaded` has no `:metadata` field. The explicit fallback clause below it is unreachable via pattern matching.

In practice, every internal caller (`recent_for_user/2`, `list_for_user/2`, `broadcast_state/3`, `get_notification/2`) preloads `activity: [:actor]`, so production callers don't hit this today. But `Notification.@type t` declares `activity: Entry.t() | NotLoaded.t() | nil` as a valid state and the fallback clause documents itself as the safe path for un-preloaded — so the first external caller that skips preload gets a KeyError instead of the promised fallback.

**Fix:** match on the actual schema:

```elixir
def render(%Notification{activity: %PhoenixKit.Activity.Entry{} = activity}) do
  ...
end
```

Now `NotLoaded` falls through to the safe fallback as designed.

### IMPROVEMENT - MEDIUM — Bell's `mount/3` violates the "no DB in mount" rule

File: `lib/phoenix_kit_web/live/notifications_bell.ex:24-31`

```elixir
def mount(_params, %{"user_uuid" => user_uuid}, socket) when is_binary(user_uuid) do
  if connected?(socket), do: Events.subscribe(user_uuid)
  {:ok,
   socket
   |> assign(:user_uuid, user_uuid)
   |> refresh()}                                  # 2 DB queries, runs HTTP + WS
end
```

`refresh/1` runs `count_unread/1` + `recent_for_user/2` — two database hits — unconditionally, which means every mount (HTTP dead render + WebSocket connect) executes 2 queries, for a total of 4 per session boot. The sticky-nested embedding bounds the cost to "once per session" rather than "once per navigation," so it's not catastrophic, but the pattern contradicts Phoenix LiveView conventions and scales poorly if a non-sticky consumer ever appears.

**Fix options** (pick one):
- Cheapest: gate on `connected?(socket)` — `refresh` on WebSocket only; dead render shows an empty bell:
  ```elixir
  socket =
    if connected?(socket),
      do: refresh(socket),
      else: assign(socket, unread_count: 0, recent: [])
  ```
- Most idiomatic: `assign_async/3` for `:unread_count` and `:recent`.

### IMPROVEMENT - MEDIUM — `Activity.log/1` adds a synchronous user lookup per notifiable event

Files: `lib/phoenix_kit/activity/activity.ex:71-77`, `lib/phoenix_kit/notifications/prefs.ex:42-47`

Every `Activity.log/1` with a `target_uuid != actor_uuid` now does:

1. `Settings.get_setting("notifications_enabled", "true")` — usually cache hit.
2. `Prefs.user_wants?/2` → `Prefs.get(uuid)` → `Auth.get_user(uuid)` — **uncached DB lookup** of the target user, just to read `custom_fields["notification_preferences"]`.
3. `do_create/1` — insert.

The Activity log is on the hot path for user-facing mutations (post liked, comment replied, email changed, role updated). This essentially doubles DB round-trips for any activity that targets another user, just to read a JSONB field that's almost always empty for a user who hasn't opened the prefs UI.

**Cheapest fix:** let callers pass the already-loaded target user through `Activity.log/1` (e.g., `target_user: %User{}`), and have `Prefs.user_wants?/2` accept `%User{}` — which `Prefs.get/1` already supports (the zero-DB-work branch). Nearly every caller that sets `target_uuid` already has the user struct in scope.

**More thorough fix:** punt the fan-out to Oban. `maybe_create_from_activity/1` enqueues a `Notifications.CreateFromActivity` job; the worker does the pref lookup and insert. Removes the blocking cost on `Activity.log/1` entirely and isolates notification failures from activity writes.

### BUG - MEDIUM — Inconsistent rescue coverage in the bell's read path

Files: `lib/phoenix_kit/notifications/notifications.ex:113-132`

`count_unread/1` has `rescue _ -> 0` but `recent_for_user/2` does not. Any transient DB error (prepared-plan invalidation during a migration, momentary pool exhaustion, etc.) makes `recent_for_user` raise, which crashes the bell LiveView. The bell restarts from the supervisor, but during the restart window the user sees a dead bell in a sticky-mounted layout, and the restart blips propagate to the layout.

The prudent fix is to make both consistent. `count_unread/1`'s `-> 0` pattern is right for a UI widget. Mirroring `recent_for_user/2` → `[]` on rescue keeps the bell rendering even when the DB blips.

### IMPROVEMENT - LOW — `prune/1` filters on activity age, not notification age

File: `lib/phoenix_kit/notifications/notifications.ex:219-232`

The docstring on `retention_days/0` says "Retention period in days. Falls back to activity retention if unset" — which reads as "keep notifications for N days." But `prune/1` joins to `Entry` and filters on `e.inserted_at < cutoff`, so what's actually retained is "notifications whose activity is younger than N days." For a system where `notifications_retention_days < activity_retention_days` is unusual, the two are equivalent. The moduledoc's intent (stay aligned with activities) is reasonable, but the `retention_days/0` docstring oversells it as a per-notification window.

Either:
- Clarify the docstring: "notifications are retained until their underlying activity is pruned; `notifications_retention_days` lets you prune notifications earlier than the activity itself."
- Or filter on `n.inserted_at` and let the FK cascade cover the "activity older than retention" case.

### NITPICK — `Prefs.update/2` doesn't whitelist against known type keys

File: `lib/phoenix_kit/notifications/prefs.ex:59-69`

```elixir
sanitized =
  prefs
  |> Enum.reduce(%{}, fn
    {k, v}, acc when is_binary(k) -> Map.put(acc, k, !!v)
    _, acc -> acc
  end)
```

Drops atom keys (good) but stores *any* binary key, including `"not_a_real_type"`. `UserSettings.handle_event("update_notification_prefs", …)` already filters to `valid_keys` at the call site (`user_settings.ex:443-456`), so no junk reaches `Prefs.update/2` today. Defense-in-depth suggests filtering unknown keys against `Types.list/0` inside `Prefs.update/2` as well, so a future caller can't pollute `custom_fields` with stale toggle names.

### NITPICK — `PruneWorker.perform/1` discards the prune result

File: `lib/phoenix_kit/notifications/prune_worker.ex:20-24`

```elixir
def perform(_job) do
  days = Notifications.retention_days()
  Notifications.prune(days)
  :ok
end
```

Any shape `prune/1` returns — `{:ok, count}`, `{:error, reason}` — is swallowed and the job reports success. Matches the broader pruner convention in the codebase, but if `prune/1` ever grows explicit error returns, the worker should pass them through so Oban can retry.

### NITPICK — `Render.render/1` meta override treats `""` as missing

File: `lib/phoenix_kit/notifications/render.ex:138-143`

`meta_string/2` maps `""` → `nil`, so a caller setting `"notification_text" => ""` intentionally (e.g., an icon-only notification) won't get their choice honored. A short comment at the helper explaining the contract is enough; or document at the module level that empty strings fall through to the default.

### NITPICK — Missing tests for core module surface

Confirming Pincer's Phase 1 note: no tests ship with this PR despite ~1000 lines of new production code. At minimum:

- `Notifications.maybe_create_from_activity/1` — fires on target_uuid, skips self-action, skips when disabled, idempotent on unique collision.
- `Prefs.user_wants?/2` — known type / unknown type / raise path.
- `Types.type_for_action/1` and `default_for/1` — core + external contribution merge.
- `Render.render/1` — at least one action per clause + the metadata-override path.
- Activity → notification round-trip with `Repo.insert` to confirm the hook actually produces a row.

## Verdict

**Ship-blockers:** none. The `Render.render/1` bug is latent because every internal caller preloads `activity`, but it silently negates the safe-fallback promise of the second clause — worth fixing in the next patch.

**Top-of-queue follow-ups:**
1. `Render.render/1` struct match (HIGH) — 1-line fix.
2. Bell mount DB queries (MEDIUM) — prevents future regressions on a non-sticky consumer.
3. `Activity.log/1` sync cost (MEDIUM) — worth benchmarking before high-traffic use.
4. `recent_for_user/2` rescue (MEDIUM) — parity with `count_unread/1`.
5. Test coverage (MEDIUM) — the whole notifications namespace.
