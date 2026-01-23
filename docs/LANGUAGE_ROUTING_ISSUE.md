# Language Routing Issue: Publishing Module Catch-All

## Problem Summary

The Publishing module's blog routes act as a **catch-all** for any URL with a language prefix, causing routes like `/es/shop`, `/fr/cart`, `/de/admin/ai` to be incorrectly routed to the Publishing controller instead of their intended modules.

## Technical Analysis

### Current Blog Routes (integration.ex:1191-1231)

```elixir
scope "#{prefix}/:language" do
  pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

  get "/:blog", PhoenixKit.Modules.Publishing.Web.Controller, :show,
    constraints: %{"blog" => ~r/^(?!admin$)/, "language" => ~r/^[a-z]{2}$/}

  get "/:blog/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show,
    constraints: %{"blog" => ~r/^(?!admin$)/, "language" => ~r/^[a-z]{2}$/}
end
```

### The Problem

1. **Pattern `/:language/:blog`** matches ANY two-segment path where language is 2 letters
2. **Constraint `~r/^(?!admin$)/`** only excludes the literal word "admin"
3. Everything else falls through: `shop`, `cart`, `checkout`, `ai`, `billing`, `db`, `sync`, `entities`, `sitemap`, etc.

### Route Order in `phoenix_kit_routes` Macro

```
1. generate_basic_scope         ← Shop, AI, Billing, DB, Sync, Entities (NO locale!)
2. generate_emails_routes       ← Has locale versions
3. generate_referral_codes_routes ← Has locale versions
4. generate_publishing_routes   ← Has locale versions (admin only)
5. generate_tickets_routes      ← Has locale versions
6. generate_localized_routes    ← Main routes (admin, dashboard, auth)
7. generate_non_localized_routes
8. generate_blog_routes         ← CATCH-ALL /:language/:blog ⚠️
```

### Affected Routes

These modules define routes **WITHOUT** locale versions:

| Module | Routes | When visiting `/es/...` |
|--------|--------|------------------------|
| Shop Admin | `/admin/shop/*` | `/es/admin/shop` → Publishing |
| Shop Public | `/shop`, `/cart`, `/checkout` | `/es/shop` → Publishing |
| Shop User | `/dashboard/orders`, `/dashboard/billing-profiles` | `/es/dashboard/orders` → Publishing |
| AI | `/admin/ai/*` | `/es/admin/ai` → Publishing |
| Billing | `/admin/billing/*`, webhooks | `/es/admin/billing` → Publishing |
| DB Explorer | `/admin/db/*` | `/es/admin/db` → Publishing |
| Sync | `/admin/sync/*` | `/es/admin/sync` → Publishing |
| Entities | `/admin/entities/*` | `/es/admin/entities` → Publishing |
| Sitemap | `/sitemap.xml` | `/es/sitemap.xml` → Publishing |

### Example: What Happens When User Visits `/es/shop`

```
Request: GET /phoenix_kit/es/shop

1. Router checks Shop routes:
   - Only `/shop` exists (no /:locale/shop) → NO MATCH

2. Router checks other module routes:
   - Same issue, no locale versions → NO MATCH

3. Router reaches blog catch-all:
   - Pattern: /:language/:blog
   - language = "es" ✓ (matches ^[a-z]{2}$)
   - blog = "shop" ✓ (matches ^(?!admin$) - not "admin")
   → MATCH!

4. Publishing.Web.Controller.show receives:
   - params: %{"language" => "es", "blog" => "shop"}
   - Tries to find blog named "shop" → 404 or error
```

## Proposed Solution

### Option A: Expanded Exclusion Pattern (Quick Fix)

Update the blog constraint to exclude all known path segments:

```elixir
@excluded_paths ~w(admin shop cart checkout ai billing db sync entities sitemap
                   users dashboard webhooks api assets static files images)

# Build regex pattern
excluded_pattern = Enum.join(@excluded_paths, "|")
blog_constraint = ~r/^(?!(?:#{excluded_pattern})$)/

get "/:blog", Publishing.Web.Controller, :show,
  constraints: %{"blog" => blog_constraint, "language" => ~r/^[a-z]{2}$/}
```

**Pros:** Minimal change, fixes immediate issue
**Cons:** Requires updating list when new modules added, fragile

### Option B: Centralized Locale Plug (Recommended)

Create a plug that handles locale detection at the **beginning** of the pipeline, before routing:

```elixir
defmodule PhoenixKitWeb.Plugs.LocaleExtractor do
  @moduledoc """
  Extracts locale from URL path and normalizes the request path.

  Transforms: /es/shop → /shop (with locale in assigns)
  This allows ALL routes to work without needing locale-specific versions.
  """

  def call(conn, _opts) do
    case extract_locale_from_path(conn.path_info) do
      {locale, remaining_path} when is_valid_locale(locale) ->
        conn
        |> assign(:current_locale_base, locale)
        |> assign(:current_locale, resolve_dialect(locale))
        |> Map.put(:path_info, remaining_path)
        |> Map.put(:request_path, "/" <> Enum.join(remaining_path, "/"))

      _ ->
        # No locale in path, use default
        assign_default_locale(conn)
    end
  end
end
```

**Usage in router:**
```elixir
pipeline :browser do
  # ... other plugs
  plug PhoenixKitWeb.Plugs.LocaleExtractor  # BEFORE routing
end

# Now ALL routes work with or without locale prefix:
# /shop AND /es/shop both route to Shop module
# Locale available in @current_locale_base
```

**Pros:**
- Universal solution - all modules automatically support locales
- No need to duplicate routes
- Clean separation of concerns
- Blog routes only match actual blog content

**Cons:**
- Requires careful implementation to not break existing routes
- Need to handle URL generation (links should include locale)

### Option C: Blog Routes Check Content Existence First

Modify Publishing controller to verify the blog actually exists before claiming the route:

```elixir
def show(conn, %{"blog" => blog_slug, "language" => lang}) do
  case Publishing.get_blog_by_slug(blog_slug) do
    nil ->
      # Not a real blog - let Phoenix continue to next route
      raise Phoenix.Router.NoRouteError, conn: conn, router: PhoenixKitWeb.Router

    blog ->
      # Real blog, render it
      render_blog(conn, blog, lang)
  end
end
```

**Pros:** Blog routes only capture actual blog content
**Cons:** Database lookup on every request, including typos

## Recommended Approach

**Implement Option B (Centralized Locale Plug)** for these reasons:

1. **Universal:** All modules automatically get locale support
2. **No Route Duplication:** Single route definition works for all locales
3. **Clean Architecture:** Locale handling separated from business logic
4. **Future-Proof:** New modules automatically work with locales
5. **Performance:** No database lookups for route matching

## Implementation Steps

1. Create `PhoenixKitWeb.Plugs.LocaleExtractor` module
2. Add plug to `:browser` pipeline BEFORE routing
3. Update `Routes.path/2` to prepend locale when generating URLs
4. Remove `/:locale` scopes from route definitions (keep single version)
5. Update blog routes to only match actual configured blog slugs
6. Test all modules with locale prefixes

## Files to Modify

- `lib/phoenix_kit_web/plugs/locale_extractor.ex` (new)
- `lib/phoenix_kit_web/integration.ex` (router macro)
- `lib/phoenix_kit/utils/routes.ex` (URL generation)
- `lib/modules/publishing/web/controller.ex` (blog route constraints)

## Questions for Discussion

1. Should locale prefix be optional or required for non-default languages?
2. How to handle SEO (canonical URLs, hreflang tags)?
3. Should the plug also handle Accept-Language header detection?
4. How to persist locale preference across sessions?

---

**Author:** Claude Code Analysis
**Date:** 2026-01-23
**Related:** `lib/phoenix_kit_web/integration.ex`, `lib/modules/publishing/`
