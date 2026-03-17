# PR #428 — Update Leaf dependency to v0.2.0

**Author:** alexdont (Sasha Don)
**Date:** 2026-03-17
**Status:** Merged

## Overview

This PR updates the Leaf content editor dependency from v0.1.0 to v0.2.0. Leaf is a JavaScript rich text editor used in PhoenixKit's publishing module.

## Changes Summary

- **2 files changed**: 2 additions, 2 deletions
- **Scope:** Dependency version bump only

## What Changed

### 1. Updated Mix Dependency

**File:** `mix.exs`

```diff
-      {:leaf, "~> 0.1.0"},
+      {:leaf, "~> 0.2.0"},
```

### 2. Updated CDN URL

**File:** `priv/static/assets/phoenix_kit.js`

```diff
-    var LEAF_CDN = "https://cdn.jsdelivr.net/gh/alexdont/leaf@v0.1.0/priv/static/assets/leaf.js";
+    var LEAF_CDN = "https://cdn.jsdelivr.net/gh/alexdont/leaf@v0.2.0/priv/static/assets/leaf.js";
```

## Impact

- **Breaking changes:** None (maintains compatibility)
- **New features:** Includes updates from Leaf v0.2.0
- **Deployment:** Requires `mix deps.get` to update

## Testing

- Verified Leaf editor loads from new CDN URL
- Publishing module editor continues to function correctly
