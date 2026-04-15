---
name: PR 491 review
description: Code review of Max's maintenance mode rewrite (layout override + scheduled windows + PubSub)
type: project
---

# PR #491 — Maintenance mode: layout override + scheduled windows + PubSub

**Author:** @mdon (Max Don) · **Branch:** `dev` → `dev` · **Files:** 20 (+2011 / −753) · 2 commits

## Summary

Refactors maintenance mode from a redirect-based approach to a **layout override**. When maintenance turns on, the underlying LiveView keeps running and form/scroll state is preserved, but `socket.private[:live_layout]` is swapped to `{PhoenixKitWeb.Layouts, :maintenance}` for non-admins. A PubSub hook listens for `{:maintenance_status_changed, _}` and swaps layouts live; admin tabs stay put. URL never changes.

Adds **scheduled maintenance windows** (UTC start/end with validation — empty/past/end-before-start/>1y), an **auto-shutoff `Process.send_after` timer** so users sitting on a blocked page get unblocked at scheduled end, a **non-LiveView plug** that renders inline 503 HTML with a `Retry-After` header for controller routes, and a **live admin settings UI** with real-time preview.

Extracts timezone helpers (`offset_to_seconds/1`, `shift_to_offset/2`, `parse_datetime_local/2`, `format_datetime_local/2`) to `PhoenixKit.Utils.Date` with doctests. Adds ~93 tests (validate_schedule unit, PubSub, plug integration including an XSS regression test, and doctested timezone helpers).

## Overall verdict

**Request changes.** Architecture is solid and the test coverage is impressive. But two real bugs need fixing before merge: the countdown hook is wired in the HEEx but the JS is never defined (feature silently broken), and the plug's inline 503 page references a CSS path that doesn't exist in the parent app. Plus a few medium-value polish items.

## Findings

### BUG — HIGH

- **`MaintenanceCountdown` phx-hook is referenced but never defined.** Both `maintenance.html.heex:31` and `maintenance_page_live.ex:139` render `phx-hook="MaintenanceCountdown"`, and `maintenance_page_live.ex` has a `check_status` handler wired to receive the "countdown finished" event. But `priv/static/assets/phoenix_kit.js` does not register a `window.PhoenixKitHooks.MaintenanceCountdown` — I checked `PhoenixKitHooks.*` registrations in that file and the hook is missing. Result: the `<span id="countdown-value">` stays empty, and "Expected back in …" renders as "Expected back in" with no timer, and the `check_status` path is dead code. This is a feature advertised in the PR body as "scheduled auto-shutoff timer" / "countdown". Either add the hook to `phoenix_kit.js` (and update the CSS compile step so parent apps pick it up) or remove the markup + dead server handler.

- **Plug's 503 HTML references a stylesheet path that doesn't exist.** `lib/modules/maintenance/web/plugs/maintenance_mode.ex:108` emits `<link rel="stylesheet" href="/assets/css/app.css" />`, but the real root layout (`lib/phoenix_kit_web/components/layouts/root.html.heex:49`) serves `~p"/assets/app.css"` (no `css/` segment, and Phoenix usually digests the filename). Non-LiveView routes hitting the plug will render an unstyled page. Either inline the critical CSS into the plug's HTML, or fetch the digested path from the parent endpoint's cache manifest, or serve a bare page without relying on daisyUI classes.

### BUG — MEDIUM

- **`disable_system` clears `scheduled_start` but not `scheduled_end`.** In `maintenance.ex:131`, disable clears only `maintenance_scheduled_start`. If an admin had "enable + end at 18:00", then manually disabled at 17:00, `maintenance_scheduled_end` remains. Combined with `active?/0` short-circuiting on `past_scheduled_end?`, the leftover end doesn't force-on, so it looks harmless — but now if the admin re-enables at 17:30 via `enable_system`, it works, and at 18:00 `past_scheduled_end?` goes true and maintenance is auto-disabled, which is surprising UX. `cleanup_expired_schedule` also doesn't run because the end hasn't been reached. Either clear both on `disable_system`, or explicitly document "end acts as a stop-signal for future manual enables too."

- **Plug's auth-route detection uses `String.contains?`, which is too loose.** `lib/modules/maintenance/web/plugs/maintenance_mode.ex:75-78` checks `String.contains?(path, "/users/log-in")` etc. Any path in the parent app containing `/users/log-in` as a substring (e.g., `/blog/users/log-in-to-our-app`) would bypass maintenance. Use `String.starts_with?(path, prefix_path.(route))` instead, matching the `static_asset?/1` style already in the same file.

- **Plug's `/favicon` skip uses `String.contains?` without anchoring.** Same file, line 53: `String.contains?(path, "/favicon")`. A URL like `/blog/favicon-policy` would bypass. Anchor with `String.starts_with?` or a tighter check.

- **Stale `Process.send_after` timer never gets canceled if the schedule changes.** `auth.ex:1259-1277` starts a one-shot timer for the scheduled end, but when an admin edits the schedule (or clears it), the old timer still fires a bogus `{:maintenance_status_changed, %{active: false}}`. Today that's saved because `handle_maintenance_change/2` re-checks `Maintenance.active?/0` rather than trusting the payload — so a stale timer just causes an extra no-op. Still worth either storing the timer ref in an assign and canceling on re-subscription, or adding a comment that the payload is intentionally distrusted.

- **`enable_system` returns `result` even when PubSub broadcast happens, but doesn't broadcast on `{:error, _}`.** That's fine, but `result` is `{:ok, setting}` / `{:error, changeset}` — callers in `settings.ex:116` match on `{:ok, _setting}`. OK. Note, however, that the atom `:ok` returned from `clear_schedule/0` and `update_schedule/2` isn't consistent with the `{:ok, _}` tuple from `enable_system/0` / `disable_system/0`. Minor API inconsistency.

### IMPROVEMENT — MEDIUM

- **`check_maintenance_mode` is called from six different on_mount clauses** (`auth.ex:438, 473, 514, 526, 565, 609`). That's enough copy-paste that it should be folded into a shared `on_mount` helper or added to the top of a single pipeline. Adding a new live_session variant in the future means remembering to sprinkle another call.

- **`put_in socket.private[:live_layout]` is undocumented Phoenix internals.** It works today because `Phoenix.LiveView.Utils.get_layout/2` reads `socket.private[:live_layout]`, but `socket.private` is explicitly marked private and has shifted in past LV releases. Consider at minimum an `# HACK:` comment explaining the coupling to a specific LV version, or track LV upgrade risk in a follow-up issue. (I see the pattern is "already used elsewhere in phoenix_kit" per the PR body — good, but the fragility is the same.)

- **`handle_maintenance_change` touches `:phoenix_kit_maintenance_active` assign "to trigger a re-render" (auth.ex:1287).** This is a legitimate workaround but the assign isn't read anywhere, so future cleanup may delete it as unused. Rename to `:phoenix_kit_maintenance_render_nonce` or similar, and add a comment that reads cannot be removed.

- **Settings page doesn't reload content (`header`/`subtext`) when another admin tab edits them.** The `{:maintenance_status_changed, _}` PubSub handler in `settings.ex:193` refreshes status assigns but not header/subtext. Not strictly a bug (content updates don't broadcast), but for real-time multi-admin UX it would be worth broadcasting content changes too.

- **`validate_not_too_far/1` hardcodes 365 days but doesn't account for leap years.** Use `DateTime.add(DateTime.utc_now(), 366, :day)` or similar. Edge-case only.

- **`schedule_error_message(_)` catches any atom**, which swallows future validation atoms without translation. Add a Logger warning in the catch-all.

### IMPROVEMENT — LOW / NITPICK

- **`parse_naive_datetime_local/1` concatenates `":00"` then retries without it.** If the input already includes seconds, the first parse fails (e.g. `"2026-04-14T12:00:30:00"`), and the fallback works. Cleaner: try without the suffix first, then retry with `":00"` appended. Same behavior, less surprise on reading.

- **`settings.ex:216` duplicates the literal `30_000` instead of using `@current_time_tick_ms`.** The module attribute is defined at line 20 — reuse it.

- **Duplicate doc comment in `utils/date.ex:717` ("Timezone offset helpers")** — nice section divider but the helpers' docstrings already explain the same scope. Fine, but could be trimmed.

- **`maintenance_page_live.ex:80-89` `check_status` handle_event** is unreachable without the missing JS hook. Once the hook is added (or removed), reconcile this.

- **`Maintenance.active?/0` has a `rescue` that "fails open"** (auth.ex-equivalent in maintenance.ex:351). Sensible, but in the same file `cleanup_expired_schedule` also rescues. A cascading settings outage could cause this to get called from the plug on every request, spamming logs. Consider rate-limiting the error log (once per minute).

- **README was shortened** — helpful, but the old doc explained setup clearly. Worth keeping a "Setup" section since the `mix phoenix_kit.install` automation is the only non-obvious step.

### GOOD

- **Layout override architecture** — preserving form state across maintenance toggles is a genuine UX win and the attach_hook/PubSub plumbing is sound. ✅
- **`validate_schedule/2`** — clean `with`-pipeline, well-tested, explicit error atoms, 60s tolerance for minute-precision inputs is thoughtful. ✅
- **Plug XSS test** — good defensive coverage; `Phoenix.HTML.html_escape` + `safe_to_string` is the right pattern for inline HTML. ✅
- **Timezone helpers extracted to `Utils.Date` with doctests** — exactly the right move; they're now unit-testable in isolation. ✅
- **`cleanup_expired_schedule/0`** — idempotent, safe to call on every page load, rescues DB errors. ✅
- **`active?/0` rescue fails open with logged error** — correct failure-mode choice for a maintenance gate. ✅
- **Timer clamp to Erlang's 32-bit max** (`@max_timer_ms`, auth.ex:1257) — defensive even though `validate_schedule` already caps at 1 year. ✅
- **Activity logging for all admin actions** — toggle, schedule, content all tracked. ✅
- **All user-facing strings in `gettext`.** ✅
- **Form-level `phx-change` on settings page** — correct fix for input-level change only firing on blur. Matches the 2nd commit message. ✅

## Recommendation

Fix the two HIGH bugs (missing JS hook + wrong CSS path in the plug) and tighten the plug path matching from `String.contains?` to `String.starts_with?`. After that this is merge-ready — the architecture, test coverage, and polish are all at the bar we want.

## Resolution

**Merged 2026-04-15** as commit `868a9b8d` (squash). Follow-up commits `89e5633d` and `48c1f6f8` addressed all HIGH and MEDIUM items:

- ✅ `MaintenanceCountdown` hook registered in `priv/static/assets/phoenix_kit.js:2116`
- ✅ Plug 503 page uses inline CSS (no broken `/assets/css/app.css` link)
- ✅ `auth_route?` / `static_asset?` switched to `String.starts_with?` + regression test for look-alike paths
- ✅ `disable_system/0` clears both `scheduled_start` and `scheduled_end`
- ✅ Timer ref tracked in `:phoenix_kit_maintenance_timer_ref`, cancelled via `reschedule_maintenance_end_timer/1`
- ✅ `check_maintenance_mode` folded into `mount_phoenix_kit_current_scope/3` — new live_sessions inherit it automatically
- ✅ HACK comment near `socket.private[:live_layout]`, schedule error catch-all logs unknown atoms, content PubSub sync added to settings

Post-merge `mix precommit` on `dev` is clean (format, credo, dialyzer baseline unchanged).
