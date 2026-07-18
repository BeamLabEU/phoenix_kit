# PR #641: Fix sanitizer XSS + sidebar flip; harden phoenix_kit.doctor

**Author**: @mdon
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed — one finding flagged (policy conflict), not fixed per
maintainer's explicit choice; everything else verified correct
**Date**: 2026-07-16

## Goal

Six independent fixes: (1) close a stored-XSS bypass in `HtmlSanitizer`'s
URL scheme check, (2) fix an admin sidebar width flip around modal scroll
locks, (3) add a `phoenix_kit.doctor` check for supervision child start
order, (4) fix `phoenix_kit.doctor` prefix-blindness + an Oban `0/0` report,
(5) add a `phoenix_kit.doctor` schema-drift check, (6) silence a dialyzer
false positive in `QrLogin.location_for/1`.

## Verified correct (no action needed)

### 1. HTML sanitizer XSS bypass fix

Replaced the `javascript:`/`vbscript:`/`data:` literal-scheme blacklist with
an allowlist (`http`/`https`/`mailto`/`tel`, plus schemeless relative/
fragment/query URLs) evaluated over a **normalized** value: HTML entities
decoded (numeric hex/decimal + a small named-entity table covering `tab`,
`newline`, `colon`, `sol`, `lpar`, `rpar`, `num`), then ASCII control/
whitespace chars stripped, matching how a browser actually parses a scheme
before dispatch. Traced through the logic by hand against each bypass
vector in the new test suite:

- `jav&#x61;script:` / `jav&#97;script:` — hex/decimal entity decode → `a`.
- `java&Tab;script:` / `java&NewLine;script:` — named-entity decode → raw
  tab/newline → stripped by the control-char regex.
- `javascript&colon;alert1` — named-entity decode → literal `:`.
- Raw literal `\t`/control chars in the scheme — stripped directly, same
  code path as the decoded case.

Confirmed the **transform only ever removes an attribute, never rewrites
the visible URL** (`if safe_url?(value), do: full, else: ""` — the *original*
matched text is kept verbatim, not a re-encoded version), so a decoding gap
degrades to over-blocking, never to a bypass. Confirmed `Regex.replace/3`
with a 3-capture-group pattern and a function callback substitutes `""` (not
`nil`) for non-participating alternation branches — the `dquoted <> squoted
<> unquoted` concatenation in `scrub_url_attr/2` is safe. Also confirmed the
new allowlist is strictly stronger than the prior blacklist: any scheme not
in `http`/`https`/`mailto`/`tel` is now rejected by default (`cond` falls
through to `true -> false`), closing schemes the old blacklist never
covered (`livescript:`, `about:`, `chrome:`, etc.) as a side effect.
Well-covered by the new `html_sanitizer_test.exs`.

### 3–6. `phoenix_kit.doctor` hardening

- **`ChildOrder`** (new `lib/phoenix_kit/install/child_order.ex`) is a pure
  AST-reading analyzer over the host's `application.ex` text — correctly
  scoped as plain functions per the "no process without a runtime reason"
  rule (this is source analysis, not runtime state). Traced the pattern
  matching for both supported children-list shapes (`children = [...]`
  assignment and inline `Supervisor.start_link([...], opts)`) and all three
  child-spec shapes (bare alias, `{Mod, opts}` 2-tuple, `{Mod, a, b}` 3+-tuple)
  against the 8 test cases — all correct. One narrow gap: a host that
  `alias`es its Repo and references it by short name (`Repo`, not
  `MyApp.Repo`) in the children list won't be matched against the
  fully-qualified `repo_module` passed in, but this **fails safe** —
  it falls through to `:no_repo_in_children` → doctor reports `:warn`
  ("verify manually"), never a false `:pass` on an actually-misordered
  install. Not worth hardening for an edge case Phoenix's own generator
  never produces.
- **Prefix resolution fix**: doctor now resolves via the same
  `PrefixConfig.resolve_prefix/1` the updater/status commands use, called
  *after* `Mix.Task.run("app.config")` so a configured prefix is honored —
  confirmed this is the identical function already relied on elsewhere (not
  new/untested logic).
- **Oban config snapshot-before-cap fix**: correctly reads
  `Application.get_env(app, Oban)` before `cap_repo_pool_size/1` zeroes it,
  fixing a real self-inflicted `0 queues, 0 plugins` misreport.
- **Schema-drift check**: hardcoded to the two V150 columns
  (`phoenix_kit_users_tokens.browser`/`.os`) rather than a general
  all-migrations mechanism — a deliberately narrow MVP scope per the PR body,
  not a defect. Reuses the pre-existing `get_comment_version/2` helper
  (already exercised by the Migration State check), not new untested SQL.
- **Dialyzer ignore for `qr_login.ex`**: scoped regex mirroring the existing
  `auth.ex` entry for the identical `Task.t()` opaque-widening false
  positive class — narrowly targeted, not a blanket suppression.

`mix precommit` (format, credo --strict, dialyzer) passes clean on `main`
with this PR included.

## Flagged, not fixed (explicit maintainer decision)

### POLICY CONFLICT: sidebar `scrollbar-gutter` override re-added to a layout

`lib/phoenix_kit_web/components/layout_wrapper.ex` adds
`lg:[scrollbar-gutter:stable]` to `.drawer-side` to fix a ~15px sidebar
width flip when a daisyUI modal's page-scroll-lock changes the root's
ambient scrollbar state. This directly matches wording in `AGENTS.md`'s
daisyUI section: manual `scrollbar-gutter` compensations were deliberately
*removed* project-wide on 2026-07-12 (commit `39e93eb6`) after they caused
their own whack-a-mole layout jank, in favor of trusting daisyUI ≥5.1's own
conditional gutter handling (`rootscrollgutter.css`) — and the rule
explicitly says **"do NOT re-add `scrollbar-gutter` overrides in layouts,
PkDialog, or modules."** This PR does exactly that, in a layout file.

The PR author's own description argues this targets a *different* scroll
container (the sidebar's own auto-sized grid column, not the page root that
daisyUI 5.1+ already handles) — a plausible, narrower claim than what the
2026-07-12 removal was about. I did not verify this claim against a live
browser (no UI test performed), and did not revert the change — per the
maintainer's explicit instruction to flag this as a review finding rather
than unilaterally reverting or editing `AGENTS.md`. Recorded here so it's
on record as a deliberate exception to double-check if sidebar/content-pane
jank resurfaces around modals.

## Validation

- `mix compile` — clean, no warnings.
- `mix precommit` — format, credo --strict, dialyzer all pass (dialyzer
  confirmed clean specifically *because of* the new qr_login.ex ignore
  entry — verified it's the only diff to the ignore set).
