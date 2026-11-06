# PR #1022 — Update leaf requirement to admit 0.11

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; nothing to fix

Adds `~> 0.11.0` to the enumerated `leaf` requirement. `mix.lock` went to 0.11.0, and `651a02394` ("libs") then
moved it to 0.11.1.

## Checked and sound

The requirement's own comment asks for a read of how core uses Leaf before each move, so that was redone
against 0.11.1 in `deps/`:

- **The browser half.** `phoenix_kit.js` only looks up `window.LeafHooks.Leaf` (`phoenix_kit.js:8501`), and
  0.11.1's `leaf.js` still defines it.
- **The vendored file.** `ViewerLibraries` copies `static/assets/leaf.js`, and the path has not moved.
- **The Elixir half.** Core has no call into Leaf. It forwards `{:leaf_changed, _}`, and `Leaf`'s docs still
  give that message as `{:leaf_changed, %{editor_id, markdown, html}}`. `notify` and `autofocus` are off unless
  an editor asks for them.
- **0.11.1** only moves the counters under the editor into the catalogue, and sits inside `~> 0.11.0`.
- **The comment's summary of 0.11** matches Leaf's changelog.
- **The CDN fallback resolves.** `cdn.jsdelivr.net/gh/alexdont/leaf@v{vsn}/…/leaf.js` answers 200 for 0.11.0 and
  0.11.1. It also answers 200 for 0.10.0 now, which closes the open item in the #1012 review.

The enumeration comment says nothing holds the ceiling, and that stays true: the next Leaf minor needs this same
read by hand.
