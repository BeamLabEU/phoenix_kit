# PR #434 Review — Fix PHOENIX_KIT_PREFIX interpolation + Oban Pruner + Cleanup

**PR:** https://github.com/BeamLabEU/phoenix_kit/pull/434
**Author:** construct-d (Sasha)
**Branch:** dev → dev (merge commit)
**Date:** 2026-03-19

## Summary

This PR bundles three independent fixes:

1. **Fix `PHOENIX_KIT_PREFIX` interpolation** in the `phoenix_kit_globals` component
2. **Fix Oban Pruner configuration** (was broken with per-queue pruner setup)
3. **Remove stale `runtime.exs`** file that belonged to a parent app ("alive"), not PhoenixKit

## Changes Reviewed

### 1. `phoenix_kit_globals.ex` — PHOENIX_KIT_PREFIX fix ✅

**Before:** `window.PHOENIX_KIT_PREFIX = "{PhoenixKit.Utils.Routes.url_prefix()}";`
**After:** Uses `@prefix` assign with proper HEEx interpolation `<%= @prefix %>`

**Verdict:** Correct fix. The old code was outputting the literal string `{PhoenixKit.Utils.Routes.url_prefix()}` instead of the actual prefix value. The Elixir `"#{...}"` string interpolation doesn't work inside HEEx templates — you need `<%= ... %>`. The fix properly:
- Aliases `PhoenixKit.Utils.Routes`
- Computes the prefix in the function body
- Assigns it and interpolates with `<%= @prefix %>`

### 2. `config/config.exs` — Oban Pruner configuration fix ✅

**Before:** Two `Oban.Plugins.Pruner` entries with `queue:` option + queue definitions misplaced inside the `crontab` list.

**Issues fixed:**
- **Queue definitions in wrong place:** `sitemap: 5`, `sqs_polling: 1`, `sync: 5`, `shop_imports: 2` were inside the `crontab` list instead of the `queues` list. This was clearly a copy-paste error.
- **Duplicate Pruner plugins:** Oban's `Pruner` plugin doesn't support a `queue` option in the open-source version — that's an Oban Pro feature (`Oban.Pro.Plugins.DynamicPruner`). The dual-pruner setup would have either been silently ignored or caused errors.
- **Fix:** Single pruner with 30-day `max_age`, all queues properly listed in the `queues` config.

**Note:** The `scheduled_jobs` queue previously had a 1-day retention comment — now it gets the same 30-day retention as everything else. This is fine; the pruner only removes `completed`/`discarded` jobs, and the cron runs every minute so old completed jobs don't matter.

### 3. `oban_config.ex` — Matching changes in install template ✅

The install/update template mirrors the same Pruner fix. Both the default config and the expected config for validation were updated consistently.

### 4. `runtime.exs` deletion ✅

Removed a 193-line `runtime.exs` that was clearly from a parent app called "alive" — it contained `config :alive`, `Alive.Repo`, `AliveWeb.Endpoint`, etc. This file had no business being in the PhoenixKit library repo.

## Issues Found

### Minor: No issues blocking merge

The changes are clean and correct. A few observations:

1. **Shop-imports queue added but no worker exists yet** — `shop_imports: 2` was added to the default queues config. This is fine (Oban ignores queues with no jobs), but it means parent apps will get this queue defined even if they don't use shop imports.

2. **No test coverage for the prefix interpolation fix** — The `phoenix_kit_globals` component doesn't appear to have tests. Since this was a bug where the literal string was output instead of the value, a simple render test would catch regressions. Not blocking.

## Verdict

**✅ Approve** — All four changes are correct and necessary fixes. The PHOENIX_KIT_PREFIX bug was breaking client-side routing for any app using a non-empty prefix. The Oban config was invalid (using OSS Pruner with Pro-only `queue:` option). The stale `runtime.exs` was clearly accidental.
