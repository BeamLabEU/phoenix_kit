# PR #365 — Refactor shop public pages: DRY helpers, unified live_sessions, auth form fixes

**Author:** timujinne
**Merged:** 2026-02-25
**Files changed:** ~40 files (+1227 / -1368)
**Reviewed:** 2026-02-25

---

## Summary

Four concerns addressed in one PR:

1. **Shop DRY refactor** — Extracted duplicated logic across shop LiveView files into new shared modules: `Helpers`, `ShopLayouts`, `ShopCards`, `CatalogSidebar`.
2. **Unified live_sessions** — Merged separate public/auth/authenticated session declarations into unified `phoenix_kit_public_routes/1` and `phoenix_kit_authenticated_routes/1` macros, enabling seamless LiveView navigation across shop, auth, and dashboard without full page reloads.
3. **Auth form consistency fixes** — Login, registration, magic link, and password reset pages now use consistent layout and redirect logic.
4. **UUID field name completions** — Finished V62 code migration: `post_id` → `post_uuid`, `file_id` → `file_uuid`, `file_instance_id` → `file_instance_uuid`, etc. in context modules.

---

## Review Methodology

5 independent agents + 7 skeptical scoring agents. Issues scored 0–100; only issues scoring ≥80 reported.

---

## Issue Found: `defp` Proxy Wrappers Still Called from HEEX Templates

**Status: OPEN** — not fixed before merge.

**Score: 85/100**

**Files affected:**
- `lib/modules/shop/web/cart_page.ex`
- `lib/modules/shop/web/catalog_product.ex`
- `lib/modules/shop/web/checkout_complete.ex`
- `lib/modules/shop/web/checkout_page.ex`

### Problem

The PR correctly moves business logic into the new `Helpers` module, but leaves thin `defp` proxy wrappers in each LiveView that delegate to `Helpers`:

```elixir
defp format_price(amount, currency), do: Helpers.format_price(amount, currency)
defp humanize_key(key), do: Helpers.humanize_key(key)
defp profile_display_name(profile), do: Helpers.profile_display_name(profile)
defp profile_address(profile), do: Helpers.profile_address(profile)
```

These proxy functions are then called directly from HEEX templates:
```heex
{format_price(@product.price, @currency)}
{humanize_key(key)}
```

CLAUDE.md rule: "Never use `defp` helpers called from HEEX templates — compiler can't see usage."

### Correct Fix

Either call `Helpers.format_price(...)` directly in templates, or import `Helpers` functions so they're available without the module prefix. The proxy layer adds indirection with no benefit.

---

## False Positives Investigated and Rejected

| Issue | Score | Reason |
|-------|-------|--------|
| Route alias rename `_localized` → `_locale` for Tickets | 5 | Internal Phoenix router constructs, never documented as public API. Tickets is optional and disabled by default. Parent apps use `Routes.path()`, not generated route helpers. |
| `PostLike`/`PostDislike` unique constraint on `[:post_uuid, :user_id]` | 0 | Pre-existing issue; schema files not modified by this PR. |
| `ResetPassword` redirect for authenticated users | 25 | Pre-existing behavior — old `on_mount` hook also redirected authenticated users. Net behavior unchanged. |
| `first_image/1` using `featured_image_uuid` but schema has `featured_image_id` | 0 | False — base branch Product schema already has `field :featured_image_uuid`. Agent hallucinated the mismatch. |
| `# @deprecated` comment instead of `@deprecated` attribute on `phoenix_kit_dashboard_routes` | 65 | Real inconsistency (same file has correct `@deprecated` on other macros), but low impact — macro is already removed from all internal call sites. |
| `@moduledoc` field descriptions still showing old `post_id`/`tag_id` names | 0 | Schema files not modified by this PR; pre-existing doc drift. |

---

## What Works Well

### Unified live_sessions
The consolidation of session declarations is architecturally sound. Separating `phoenix_kit_public_routes/1` and `phoenix_kit_authenticated_routes/1` with distinct `on_mount` hooks eliminates the navigation flash/reload that occurred when crossing session boundaries.

### `ShopCards` and `ShopLayouts` components
Moving `defp shop_layout` from per-file private functions into proper public `def` Phoenix components is the correct pattern. The `sidebar_after_shop` attr is now properly declared.

### `DevNotice` component
Replaces 5 identical `defp show_dev_notice?` private functions with a single reusable Phoenix component — a clean CLAUDE.md compliance fix.

### V62 UUID field name completions
`post_id` → `post_uuid`, `file_id` → `file_uuid` etc. in `posts.ex`, `publishing/*.ex`, `storage.ex` correctly completes the migration that the base branch had only partially applied at the query level.

### Duplicate route alias warnings eliminated
`phoenix_kit_authenticated_routes/1` now splits route declarations into `authenticated_live_routes/0` and `authenticated_live_locale_routes/0` — prevents compilation warnings from duplicate `as:` aliases.

---

## Follow-Up Items

- [ ] Remove `defp` proxy wrappers in shop LiveViews; call `Helpers.*` directly from templates or import the module
- [ ] Consider changing `# @deprecated` comment on `phoenix_kit_dashboard_routes` to proper `@deprecated` module attribute
- [ ] `@moduledoc` in `post_like.ex`, `post_tag_assignment.ex` etc. still reference old `post_id`/`tag_id` field names — cleanup pass in a future PR
