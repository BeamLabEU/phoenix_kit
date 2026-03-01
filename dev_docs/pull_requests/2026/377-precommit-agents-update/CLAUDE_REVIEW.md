# PR #377 — Update AGENTS.md with pre-commit instructions

**Date:** 2026-02-28
**Author:** construct-d
**Status:** Merged
**CI Result:** Failed (Code Quality Checks — Credo)

---

## Summary

A small housekeeping PR with two changes:

1. **`AGENTS.md`** — Adds a "Pre-commit commands" section with the `mix precommit` workflow; removes the old minimal "Pre-commit Checklist" (which only said to run `mix format`).
2. **`mix.exs`** — Adds a `precommit` alias: `["compile", "quality"]`, where `quality` = `["format", "credo --strict", "dialyzer"]`.

---

## CI Failure Analysis

The `Code Quality Checks` job failed with **18 Credo readability issues** — all of them `[R] AliasOrder` violations (aliases not alphabetically ordered). Exit code 4.

**Crucially: none of these issues were introduced by this PR.** This PR touches only `AGENTS.md` and `mix.exs`; the Credo findings are all in Elixir source files (e.g., `lib/phoenix_kit/mailer.ex`, `lib/modules/sync/web/sender.ex`, `lib/phoenix_kit_web/users/login.ex`, etc.) that were already broken before this branch. The PR simply exposed the already-failing baseline.

Files flagged by Credo:
- `lib/phoenix_kit_web/users/registration.ex:16`
- `lib/phoenix_kit_web/users/magic_link.ex:18`
- `lib/phoenix_kit_web/live/users/live_sessions.ex:22`
- `lib/phoenix_kit_web/live/settings/organization.ex:14`
- `lib/phoenix_kit_web/live/dashboard.ex:15`
- `lib/phoenix_kit/mailer.ex:33`
- `lib/modules/sync/web/sender.ex:20`
- `lib/modules/sync/web/connections_live.ex:20`
- `lib/modules/sync/transfers.ex:58`
- `lib/modules/sitemap/generator.ex:42`
- `lib/modules/shop/web/catalog_product.ex:24`
- `lib/modules/publishing/web/editor/forms.ex:12`
- `lib/modules/pages/web/index.ex:13`
- `lib/modules/pages/web/editor.ex:13`
- `lib/modules/emails/web/template_editor.ex:32`
- `lib/modules/db/web/activity.ex:14`
- `lib/modules/ai/web/endpoints.ex:25`
- `lib/phoenix_kit_web/users/login.ex:14`

All violations are the same pattern: `PhoenixKit.Utils.*` aliases (`Routes`, `IpAddress`, `UUID`, `Slug`) that appear out of alphabetical order in their `alias` groups.

---

## Review

### What's good

- The intent is correct: agents and AI tools have been running with an incomplete pre-commit step (`mix format` only), missing `credo` and `dialyzer`. A single `mix precommit` is a good DX improvement.
- The documentation restructuring is clean — pre-commit instructions are now a first-class section rather than buried under "CI/CD".

### Issues

**1. `mix precommit` includes Dialyzer — it's too slow for pre-commit use**

The alias expands to `compile → format → credo --strict → dialyzer`. Dialyzer takes 5–6 minutes even with PLT cache. Pre-commit hooks that block that long get disabled/skipped. A more practical pre-commit alias would be:

```elixir
precommit: ["compile", "format", "credo --strict"]
```

Dialyzer should stay in `quality` and be reserved for CI or manual runs before pushing.

**2. The PR exposed (but didn't fix) 18 pre-existing Credo violations**

This is the actual cause of the CI failure. The violations exist on `dev` independently of this PR, so the merge was correct. But those 18 alias ordering issues need to be resolved in a follow-up — they will block every PR that touches Credo going forward.

**3. AGENTS.md "Development Workflow" section now overlaps with "Pre-commit commands"**

The top-level workflow still lists `mix compile` and `mix credo --strict` as separate manual steps, while the new pre-commit section says "run `mix precommit`" which does both (plus more). A future reader may not know which to follow. Consider trimming the Development Workflow block to just reference `mix precommit`.

**4. Minor: double blank line left in AGENTS.md after the new section (line 37–38)**

---

## Verdict

The PR logic is sound and the merge was correct. The CI failure is a pre-existing problem, not a regression from this change.

### Follow-up needed

- [ ] Fix the 18 `AliasOrder` Credo violations across those 18 files (mechanical fix — just sort the alias groups alphabetically)
- [ ] Consider removing Dialyzer from `precommit` alias to keep pre-commit runtime under 30s
- [ ] Optionally simplify the "Development Workflow" section to avoid duplication with "Pre-commit commands"
