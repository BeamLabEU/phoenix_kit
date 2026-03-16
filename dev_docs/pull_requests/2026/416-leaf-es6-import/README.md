# PR #416 — Replace inlined leaf.js with ES6 import for automatic updates

**Author:** Sasha Don (alexdont)
**Base:** dev
**Stats:** +12 / -2,033 across 2 files, 1 commit

## What

Replace the 2,000-line inlined leaf.js copy with a single ES6 `import` statement. Also bumps several dependencies (Phoenix 1.8.3→1.8.5, LiveView 1.1.22→1.1.27, telemetry 1.3.0→1.4.1, etc).

## Why

Inlining the full JS source meant manual updates on every Leaf version bump. Using an ES6 import from `deps/leaf/` lets the parent app's esbuild resolve it automatically — `mix deps.update leaf` is all that's needed.

## Key Changes

- **`phoenix_kit.js`**: Replace ~2,000 lines of inlined leaf.js with `import "../../../../leaf/priv/static/assets/leaf.js"`
- **`mix.lock`**: Bump leaf (hash change), phoenix, phoenix_live_view, igniter, rewrite, sourceror, spitfire, telemetry
