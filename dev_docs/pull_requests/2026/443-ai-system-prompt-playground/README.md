# PR #443 — Add system_prompt field to AI prompts and AI Playground page

**Author:** Max (mdon)
**Base:** dev
**Date:** 2026-03-23
**Impact:** +1,099 lines / -7 lines

## Summary

Adds a `system_prompt` field to AI prompts (enabling separate system-level instructions) and introduces a new AI Playground LiveView for interactively testing endpoints and prompts from the admin dashboard.

## Key Changes

### 1. System Prompt Field

| File | Change |
|------|--------|
| `migrations/postgres/v85.ex` | New migration: adds `system_prompt` TEXT column to `phoenix_kit_ai_prompts` |
| `prompt.ex` | Schema field, changeset cast, `render_system_prompt/2` function |
| `ai.ex` | `ask_with_prompt/4` auto-includes system prompt via `:system` opt |
| `prompt_form.html.heex` | System prompt textarea in prompt create/edit form |

- Variables are now extracted from **both** `system_prompt` and `content` fields (combined then deduplicated)
- `render_system_prompt/2` returns `{:ok, nil}` for nil/empty, `{:ok, rendered}` otherwise
- `ask_with_prompt` uses `Keyword.put_new` so callers can still override `:system`

### 2. AI Playground LiveView

| File | Change |
|------|--------|
| `web/playground.ex` | New LiveView (300 lines) — endpoint/prompt selection, variable inputs, freeform mode |
| `web/playground.html.heex` | Template (336 lines) — configuration card, input card, response area with usage stats |
| `integration.ex` | Route: `/admin/ai/playground` |
| `ai.ex` | Playground tab registered in navigation (priority 553) |

**Two modes:**
- **Prompt mode** — Select a prompt, fill in variables, edit the template inline, send
- **Freeform mode** — Type a message + optional system prompt directly

**Features:**
- Loading skeleton with auto-scroll to response
- Usage stats display (tokens in/out, total, cost)
- Async request via `handle_info(:do_send, ...)` to avoid blocking the LiveView

### 3. Navigation Updates

Playground tab added to all AI admin page tab bars:
- `endpoints.html.heex`
- `prompts.html.heex`
- `playground.html.heex` (active state)

### 4. Tests

- 44 unit tests in `test/modules/ai/prompt_test.exs` covering `extract_variables`, `render`, `render_system_prompt`, changeset variable extraction, `validate_variables`, `has_variables?`, `valid_content?`, `content_preview`, `generate_slug`, and `format_variables_for_display`

## Migration

**V85** — Idempotent `ALTER TABLE` adding `system_prompt` TEXT column. Checks for both table and column existence before executing. Bumps version comment to 85.
