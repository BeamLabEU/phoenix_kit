## PR #509 — Legal i18n (de/fr/it/pl) + string entries in `css_sources/0`
**Author:** Tymofii Shapovalov (timujinne)
**Reviewer:** Claude
**Date:** 2026-04-29
**Verdict:** ✅ APPROVE — already merged. Changes are sound; flagging one maintenance hazard and a few small cleanups.

---

## Summary

Two unrelated improvements bundled:

1. **Legal module i18n** — translations for `phoenix_kit_legal`'s end-user-facing strings across ru/de/fr/it/es/pl, plus a build-time manifest module that re-emits Legal's `gettext` calls into core's POT (because `mix gettext.extract` doesn't walk into deps).
2. **`css_sources/0` accepts strings** — modules can return `[atom() | String.t()]` from their `css_sources/0` callback. Atoms still resolve via parent `mix.exs` deps; strings emit verbatim (absolute) or get `../../` prefixed (relative).

## Files Changed (code only — translation `.po`/`.pot` reviewed separately below)

| File | Change |
|------|--------|
| `lib/mix/tasks/compile.phoenix_kit_css_sources.ex` | Refactor: extract `format_source/2` with atom/string clauses |
| `lib/phoenix_kit/module.ex` | `@callback css_sources()` spec widened to `[atom() \| String.t()]`; moduledoc updated with both styles |
| `lib/phoenix_kit_web/legal_gettext_manifest.ex` | New: 50 `gettext(...)` calls so `mix gettext.extract` records Legal strings into core POT |
| `priv/gettext/default.pot` | ~900 phantom msgids removed (modules previously extracted) |
| `priv/gettext/{de,fr,it,pl}/LC_MESSAGES/*.po` | New locales with correct `Plural-Forms` headers |
| `priv/gettext/phoenix_kit.pot` + `*/LC_MESSAGES/phoenix_kit.po` | New domain (47 msgids) |
| `priv/static/assets/phoenix_kit.js` | 1-line — unrelated rebuild artifact |

## Green flags

- **`Plural-Forms` headers are correct.** Verified: German `n != 1` (2-form), French `n>1` (2-form, French/Brazilian convention), Italian `n != 1` (2-form), Polish `(n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10||n%100>=20) ? 1 : 2)` (canonical 3-form). Russian and Spanish kept their existing values.
- **Pre-existing translations preserved.** Spot-check: ru/es "Close" → "Закрыть"/"Cerrar" still present after the POT regen. The merge commit ordering (extract → merge → translate) avoided clobbering hand-edits.
- **Legal manifest scope is right.** Module re-emits only end-user strings (cookie banner, flash, page titles); admin-settings strings deliberately excluded with a comment explaining why ("admin panel runs in English"). That keeps the manifest stable instead of growing every time the Legal admin UI is touched.
- **`css_sources/0` refactor is the right shape.** The atom branch is unchanged in behaviour; the string branch is a clean addition behind a function-head guard. The `source_for_path/1` helper already handled the abs/rel split, so the new clause just slots in. Spec widening is non-breaking — atom-only consumers still satisfy the new spec.
- **Backwards-compat verified by inspection.** `def css_sources, do: [:phoenix_kit_my_module]` still routes through `format_source(atom, deps)` exactly as before.

## Findings

### IMPROVEMENT - MEDIUM — Manifest sync hazard between core and `phoenix_kit_legal`

File: `lib/phoenix_kit_web/legal_gettext_manifest.ex`

The moduledoc tells maintainers to refresh the list manually with a grep one-liner whenever `phoenix_kit_legal` adds or renames a string. There's no compile-time or CI check that catches drift. If a Legal contributor adds `gettext("Withdraw consent")` and forgets to update this manifest:

- `mix gettext.extract` in core won't see the new msgid.
- The string falls back to its English msgid at runtime in non-EN locales (silent failure — no log, no test fail).
- The bug is invisible until someone notices the missing translation in the locale they happen to read.

The manifest pattern is the right workaround for `gettext.extract` not walking deps, but the sync needs a forcing function. Options, easiest first:

1. **CI guard.** A small Mix task that runs the documented grep against `phoenix_kit_legal/lib/**/*.ex`, diffs against `LegalGettextManifest.__extract__/0`'s msgid list, and fails if drift is found. Cheap, catches 95% of cases.
2. **Generate the manifest.** Convert `LegalGettextManifest` to a generated file (e.g., `mix phoenix_kit.legal.refresh_manifest`) so the source-of-truth is the `phoenix_kit_legal` source itself, and the generator is the only thing that writes the list. Higher upfront cost but eliminates the manual step.
3. **Run extraction inside `phoenix_kit_legal`.** Have Legal own its own gettext backend + POT, then merge into core at install time. Re-architects the gettext story — out of scope for this PR.

The current state is fine for one consumer that changes rarely. If a second module adopts the manifest pattern, option (1) becomes worthwhile.

### IMPROVEMENT - LOW — String entries in `css_sources/0` aren't path-validated

File: `lib/mix/tasks/compile.phoenix_kit_css_sources.ex:81`

```elixir
defp format_source(entry, _deps) when is_binary(entry), do: source_for_path(entry)
```

A typo'd path (`"/Users/me/projects/foo"` when the dir doesn't exist, or a stale absolute path from a different machine) still emits a `@source` line. Tailwind silently scans nothing and the project loses styles in production with no error.

A `Logger.warning("[PhoenixKit] css_sources path not found: #{path}")` when `not File.dir?(path) and not File.regular?(path)` catches typos at compile time without making the compiler fail (paths can legitimately be glob-shaped or live outside the build env).

### NITPICK — Two adjacent comments overlap

File: `lib/mix/tasks/compile.phoenix_kit_css_sources.ex:76-80`

```elixir
# Absolute paths are emitted verbatim — prepending `../../` would
# produce `@source "../..//abs/path";` which Tailwind can't resolve
# reliably. Relative paths stay relative to the generated file at
# `assets/css/_phoenix_kit_sources.css` (two levels up to project root).
# String entries from css_sources/0 — treated as literal paths (abs or rel).
defp format_source(entry, _deps) when is_binary(entry), do: source_for_path(entry)
```

The first block (lines 76-79) was the comment for `source_for_path/1` before the refactor; now it's stranded above `format_source/2` and reads as if it documents the binary clause. Either move it back down to `source_for_path/1`'s own definition (lines 94-95) or fold the two blocks into one.

### NITPICK — `:hex` and `:not_found` collapse to the same branch

File: `lib/mix/tasks/compile.phoenix_kit_css_sources.ex:89-90`

```elixir
:hex -> "@source \"../../deps/#{app_name}\";"
:not_found -> "@source \"../../deps/#{app_name}\";"
```

Pre-existing in the codebase, just relocated by this PR — but worth folding to `:hex_or_not_found ->` or matching with `_ ->` since the output is identical. Leaving them split implies they should differ; if there's a reason to keep them split (e.g., future logging on `:not_found`), a comment would help.

### NITPICK — Module name placement

`PhoenixKitWeb.LegalGettextManifest` lives at the top level of the Web namespace alongside actual web components. It's a build-time extraction artifact, not runtime code. Suggested home: `PhoenixKitWeb.GettextManifests.Legal` (or even outside `Web.*` since the manifest only uses the gettext backend, not any web API). Cosmetic; doesn't change behaviour.

### Risk note — POT cleanup may have removed runtime/dynamic gettext keys

The PR drops ~900 phantom msgids from `default.pot` via `mix gettext.extract`. Static-callsite removal is safe by definition — no source uses them. **But** Elixir code can use `Gettext.gettext/2` with a runtime variable (e.g., `Gettext.gettext(MyApp.Gettext, dynamic_key)`), which the extractor can't see. Audit:

```bash
$ rg "Gettext\.(gettext|dgettext)\(" lib/
lib/phoenix_kit_web/components/core/input.ex:120: Gettext.dgettext(PhoenixKitWeb.Gettext, "errors", msg, opts)
lib/phoenix_kit_web/components/layouts/maintenance.html.heex:33: Gettext.gettext(PhoenixKitWeb.Gettext, "any moment now...")
lib/phoenix_kit_web/components/layouts/maintenance.html.heex:37: Gettext.gettext(PhoenixKitWeb.Gettext, "Expected back in")
```

All three pass literal strings, so the extractor handles them like macros. No dynamic-key usage in core. ✓ Risk is null in practice — but worth recording the check for future prunes.

## No tests added

`format_source/2` is a pure function on a small input set — image of the smallest unit test the codebase will tolerate:

```elixir
test "string entries pass through to source_for_path" do
  assert format_source("/abs/path", []) == "@source \"/abs/path\";"
  assert format_source("rel/path", []) == "@source \"../../rel/path\";"
end

test "atom entries resolve via deps" do
  deps = [{:my_dep, "~> 0.1"}]
  assert format_source(:my_dep, deps) == "@source \"../../deps/my_dep\";"
  assert format_source(:my_dep, [{:my_dep, path: "/local"}]) == "@source \"/local\";"
end
```

Cheap to add, locks in the dispatch. Not blocking.

## Suggested follow-ups

1. **CI drift check** for `LegalGettextManifest` vs `phoenix_kit_legal` source (Finding 1).
2. **Path validation warning** in `format_source/2` string clause (Finding 2).
3. **Comment cleanup** on the two stranded blocks (Finding 3).
4. **Move the manifest** under a `GettextManifests.*` sub-namespace if more modules adopt the pattern (Finding 5).
5. **Smallest-possible test** for `format_source/2` (no-tests note above).
