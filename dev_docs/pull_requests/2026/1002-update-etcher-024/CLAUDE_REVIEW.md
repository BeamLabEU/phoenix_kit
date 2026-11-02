# PR #1002 — Update etcher to 0.24

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve, no code changes

`mix.exs` `{:etcher, "~> 0.23.0"}` → `"~> 0.24.0"` and the lockfile entry.

## Checked and sound

- **No bundle to rebuild.** Etcher's JS is vendored from the *consumer's* installed dependency at
  install/compile time (`PhoenixKit.Install.ViewerLibraries`, `source: {:etcher, "static/etcher.js"}`,
  `version: :app_vsn`), not from a copy inside core's `priv/static`, so the host picks up 0.24's file by
  resolving the new floor.
- **No API change.** Etcher 0.24.0's CHANGELOG has one "Changed" entry (inserted-image sizing);
  `insertImage(href, { maxSide })` and explicit sizes keep their meaning, and core's Elixir side calls
  nothing new.
- **Requirement shape.** `~> 0.24.0` keeps a closed ceiling (`< 0.25.0`), as the CDN-pinned siblings
  require; the fresco range etcher 0.24 declares is unchanged from 0.23, so core's fresco pin still
  resolves.

No findings.
