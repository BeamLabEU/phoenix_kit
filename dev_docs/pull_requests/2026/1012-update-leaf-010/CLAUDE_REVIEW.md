# PR #1012 — Admit Leaf 0.9 and 0.10

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; one nitpick fixed, one improvement open
outside this repo

Widens the enumerated `leaf` pin with `~> 0.9.0 or ~> 0.10.0`. `febdf7f9e` then moved `mix.lock` to
0.10.0.

## Checked and sound

The pin's own comment asks for a read of how core uses Leaf before each move, so that was redone against
Leaf 0.10.0 in `deps/`:

- **The browser half.** `phoenix_kit.js` only looks up `window.LeafHooks.Leaf`, and 0.10.0 still defines
  it (`leaf.js:1938`).
- **The vendored file.** `ViewerLibraries` copies `static/assets/leaf.js`, and the path has not moved.
- **The Elixir half.** Core has no call into Leaf. It forwards `{:leaf_changed, _}`, and the message is
  still that two-tuple (`%{editor_id, markdown, html}`).
- **A stale host copy is loud.** 0.10 warns in the console when the vendored `leaf.js` does not match the
  library, and names `mix phoenix_kit.update` as the fix.
- **The comment's summary of 0.9 and 0.10 matches Leaf's changelog**, `Leaf.Sanitizer` included.

## Findings

### IMPROVEMENT - MEDIUM — Leaf 0.10.0 is on Hex but not on GitHub, so the CDN fallback 404s (open)

`ViewerLibraries` builds the fallback URL from the host's Leaf version:
`cdn.jsdelivr.net/gh/alexdont/leaf@v{vsn}/priv/static/assets/leaf.js`. `alexdont/leaf` has no `v0.10.0` tag,
and its `main` is still at 0.9.0 (last pushed 2026-11-01), so the 0.10.0 published on 2026-11-04 was never
pushed.

Checked directly: the URL answers 200 for `v0.9.0` and 404 for `v0.10.0`.

Only a host with `library_cdn_fallback: true` is affected, and only after its local copy failed to load,
which is exactly when it needs the fallback: the editor then stays down. Nothing in core is wrong and no
test can see this.

Not fixed here because the fix belongs in the other repository: push the 0.10.0 commit and its tag to
`alexdont/leaf`.

### NITPICK — the pin's line left `main` failing the format check (fixed)

The widened requirement ran past the formatter's width, so `mix format --check-formatted`, and with it
`quality.ci` and `mix precommit`, failed on `main`. `ci.yml` is manual-only, so nothing caught it. `mix
format` split the tuple across two lines, with no change to the requirement.
