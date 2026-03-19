# PR #431 Review — Tailwind Markdown, Translation Retry, Sync UX

**Reviewer:** Claude
**Date:** 2026-03-18
**PR:** Add Tailwind markdown rendering, translation retry resilience, and Sync UX improvements

## Summary

Three independent changes bundled into one PR:

1. **Markdown renderer** — Replace inline `<style>` block with Tailwind/daisyUI classes injected via Earmark post-processing. Blank line preservation added. Cache version bumped to v2.
2. **Translation worker** — Dynamic timeout scaling (~1.5 min/language, min 15 min). On retry, skip already-translated languages by comparing content `updated_at` against job `inserted_at`.
3. **Sync module** — Rename Sender/Receiver → Outgoing/Incoming, fix sender URL resolving to localhost, allow editing incoming connections, add structured logging.

## Verdict: Approve with minor issues

The code is well-structured, well-tested, and solves real problems. The issues below are minor.

---

## Issues

### 1. Security: `auth_token_hash` logged in plaintext (Medium)

**Files:** `connections_live.ex:964`, `api_controller.ex:883`

Both files log the full `auth_token_hash` value. While this is a hash (not the raw token), logging it openly gives attackers a lookup value if logs are compromised — they could match connections to hashes and attempt API calls using the hash directly (since several API endpoints accept `auth_token_hash` as an auth parameter).

**Recommendation:** Truncate to first 8 characters in logs: `String.slice(connection.auth_token_hash, 0, 8) <> "…"`

### 2. `get_our_site_url()` called twice per notification (Low)

**File:** `connection_notifier.ex:101` and `connection_notifier.ex:851`

`do_notify_remote_site` computes `our_url = get_our_site_url()` at line 101 for logging, then `build_request_body` calls `get_our_site_url()` again internally at line 851. This hits `Settings.get_setting` twice per notification.

**Recommendation:** Pass `our_url` into `build_request_body` instead of recomputing it. Change signature to `build_request_body(conn_name, our_url, raw_token, password)` and use the already-fetched value.

### 3. Regex-based HTML class injection is fragile (Low)

**File:** `renderer.ex:245-297`

The tag-matching approach using regex on HTML strings works but has edge cases:
- Self-closing tags like `<img />` vs `<img>` — the regex `(?=[\s>/])` handles this, which is good.
- Tags inside code blocks or attributes — the `<!--pkcode-->` marker technique protects `<pre><code>`, but if someone writes `<p class="...">` in inline code, it would get re-styled.
- The `merge_class` function puts new classes *before* existing ones, which is correct for Tailwind specificity.

This is acceptable for a markdown rendering context where content is authored, not arbitrary HTML. Just noting for awareness.

### 4. `Task.start` without supervisor (Low)

**File:** `connections_live.ex:975`

```elixir
Task.start(fn -> log_remote_notification(connection, token) end)
```

`Task.start` creates an unsupervised, fire-and-forget task. If the BEAM node is under memory pressure, this could be silently dropped. In production, `Task.Supervisor.start_child` is preferred — but this is a logging-only task where loss is acceptable, so it's fine here.

### 5. Process dictionary cache for regex patterns (Info)

**File:** `renderer.ex:272-286`

Using `Process.get/put` for caching compiled regex patterns is pragmatic — it avoids recompilation per render while keeping patterns process-local. The downside is that every new process (e.g., new LiveView mount) pays the compilation cost once. Given the small number of patterns (18), this is negligible.

An alternative would be `:persistent_term`, but Process dictionary is simpler and correctly scoped here.

---

## Test Coverage

Good test coverage across all three areas:

- **`renderer_test.exs`** (203 lines) — Tests class injection for all tag types, code block vs inline code distinction, blank line preservation, edge cases (nil, empty, class merging). Thorough.
- **`translate_post_worker_test.exs`** (43 lines) — Tests dynamic timeout scaling with various language counts. Clean.
- **`translate_retry_test.exs`** (121 lines) — Integration test for skip logic with real DB content rows. Tests skip-when-newer, keep-when-older, and no-prior-translations cases. Well done.

---

## What's Good

- **Cache version bump to v2** — correctly invalidates old cached HTML that used the `<style>` block approach.
- **Template change** `prose prose-lg` → `markdown-content` — clean break from prose plugin dependency.
- **Retry skip logic** — comparing `updated_at > job.inserted_at` is a sound heuristic for detecting work done by a previous attempt.
- **Dynamic timeout** — `max(15, ceil(count * 1.5))` is reasonable headroom over the 20-60s per language observed.
- **Structured logging** — consistent `[Sync.Notifier]`, `[Sync.API]`, `[Sync.Connections]` prefixes with pipe-separated key-value pairs. Much better for log parsing than the previous mixed formats.
- **URL fallback chain** — Settings DB → `:public_url` config → dynamic base URL is a sensible priority order that fixes the localhost bug.
- **Credo compliance** — the `log_remote_notification` extraction specifically addresses nesting depth.
