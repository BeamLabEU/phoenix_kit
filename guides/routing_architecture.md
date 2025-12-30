# Routing Architecture Guide

This guide documents the PhoenixKit routing architecture, compile-time optimization strategies, and recommendations for scaling as new modules are added.

## Table of Contents

- [The Problem](#the-problem)
- [Current Solution](#current-solution)
- [Scaling Strategies](#scaling-strategies)
  - [Strategy 1: Forward to Module Routers](#strategy-1-forward-to-module-routers-recommended)
  - [Strategy 2: Route Macros per Module](#strategy-2-route-macros-per-module)
  - [Strategy 3: Hybrid Approach](#strategy-3-hybrid-approach)
- [Implementation Examples](#implementation-examples)
- [Recommendations](#recommendations)

---

## The Problem

### Slow Router Compilation

Phoenix routers with many routes experience slow compilation times because:

1. **Macro Expansion**: Each `live` route macro expands into pattern matching code, plug pipelines, and metadata at compile time.

2. **Route Duplication**: PhoenixKit supports both localized (`/en/admin/...`) and non-localized (`/admin/...`) routes, effectively doubling route definitions.

3. **Single Compilation Unit**: All routes in one router file means any change triggers full recompilation.

### Original State

Before optimization, `integration.ex` had:

- **~160 LiveView routes** defined in `generate_localized_routes/2`
- **~160 LiveView routes** duplicated in `generate_non_localized_routes/1`
- **~320 total route definitions** expanding at compile time
- **859 lines** of code with significant duplication

Compilation warnings observed:

```
Compiling lib/phoenix_kit_web/router.ex (it's taking more than 10s)
Compiling lib/phoenix_kit_web/live/modules/billing/invoice_detail.ex (it's taking more than 10s)
```

---

## Current Solution

### Shared Route Macros

Routes are now defined once in shared macros and called from both scopes:

```elixir
# lib/phoenix_kit_web/integration.ex

# Shared macro defining routes once
defmacro phoenix_kit_admin_routes(suffix) do
  session_name = :"phoenix_kit_admin#{suffix}"

  quote do
    live_session unquote(session_name),
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
      live "/admin", Live.Dashboard, :index
      live "/admin/users", Live.Users.Users, :index
      # ... ~100 admin routes defined once
    end
  end
end

# Localized scope calls shared macro
defp generate_localized_routes(url_prefix, pattern) do
  quote do
    scope "#{unquote(url_prefix)}/:locale", PhoenixKitWeb do
      pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

      phoenix_kit_auth_routes(:_locale)
      phoenix_kit_confirmation_routes(:_locale)
      phoenix_kit_admin_routes(:_locale)
      phoenix_kit_dashboard_routes(:_locale)
    end
  end
end

# Non-localized scope calls same shared macro
defp generate_non_localized_routes(url_prefix) do
  quote do
    scope unquote(url_prefix), PhoenixKitWeb do
      pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

      phoenix_kit_auth_routes(:"")
      phoenix_kit_confirmation_routes(:"")
      phoenix_kit_admin_routes(:"")
      phoenix_kit_dashboard_routes(:"")
    end
  end
end
```

### Current Shared Macros

| Macro | Purpose | Route Count |
|-------|---------|-------------|
| `phoenix_kit_auth_routes/1` | Login, register, magic-link, reset-password | ~8 |
| `phoenix_kit_confirmation_routes/1` | Email confirmation | ~2 |
| `phoenix_kit_admin_routes/1` | All admin panel routes | ~100 |
| `phoenix_kit_dashboard_routes/1` | User dashboard | ~3 |

### Results

- **File size**: 859 → 704 lines (~18% reduction)
- **Code duplication**: Eliminated
- **Route consistency**: Fixed (localized and non-localized now identical)

---

## Scaling Strategies

As PhoenixKit grows with more modules, consider these strategies:

### Strategy 1: Forward to Module Routers (Recommended)

Split routes into separate router modules using Phoenix's `forward/2`:

```elixir
# lib/phoenix_kit_web/integration.ex
scope url_prefix, PhoenixKitWeb do
  pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

  forward "/admin/billing", Routers.BillingRouter
  forward "/admin/ai", Routers.AIRouter
  forward "/admin/entities", Routers.EntitiesRouter
  forward "/admin/posts", Routers.PostsRouter
  forward "/admin/emails", Routers.EmailsRouter
end
```

#### File Structure

```
lib/phoenix_kit_web/routers/
├── billing_router.ex      # ~40 billing routes
├── entities_router.ex     # ~10 entity routes
├── ai_router.ex           # ~10 AI routes
├── posts_router.ex        # ~10 posts routes
├── emails_router.ex       # ~10 email routes
└── storage_router.ex      # ~10 storage routes
```

#### Example Sub-Router

```elixir
# lib/phoenix_kit_web/routers/billing_router.ex
defmodule PhoenixKitWeb.Routers.BillingRouter do
  use PhoenixKitWeb, :router

  # Import shared pipelines and auth
  import PhoenixKitWeb.Users.Auth

  pipeline :billing_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: PhoenixKit.LayoutConfig.get_root_layout()
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_phoenix_kit_current_user
  end

  scope "/", PhoenixKitWeb do
    pipe_through [:billing_browser]

    live_session :billing_admin,
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
      live "/", Live.Modules.Billing.Index, :index
      live "/orders", Live.Modules.Billing.Orders, :index
      live "/orders/new", Live.Modules.Billing.OrderForm, :new
      live "/orders/:id", Live.Modules.Billing.OrderDetail, :show
      live "/orders/:id/edit", Live.Modules.Billing.OrderForm, :edit
      live "/invoices", Live.Modules.Billing.Invoices, :index
      live "/invoices/:id", Live.Modules.Billing.InvoiceDetail, :show
      live "/invoices/:id/print", Live.Modules.Billing.InvoicePrint, :print
      # ... remaining billing routes
    end
  end
end
```

#### Pros

- **Separate compilation units**: Changes to billing routes don't recompile the main router
- **Clean separation**: Each module owns its routes
- **Conditional loading**: Easy to disable modules by not forwarding
- **Scalability**: Add new modules without touching main router

#### Cons

- **`live_session` isolation**: Sessions don't cross `forward` boundaries; each sub-router needs its own `live_session` with the same `on_mount` hooks
- **Pipeline duplication**: Pipelines must be defined or imported in each sub-router
- **Path prefixes**: Routes in sub-router are relative to forward path

#### Important: live_session Caveat

When using `forward`, `live_session` scopes are isolated to each router. This means:

```elixir
# Main router
live_session :admin do  # This session...
  forward "/billing", BillingRouter
end

# BillingRouter - WRONG: won't inherit parent live_session
scope "/" do
  live "/orders", OrdersLive  # Not in any live_session!
end

# BillingRouter - CORRECT: define own live_session
scope "/" do
  live_session :billing_admin,
    on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
    live "/orders", OrdersLive
  end
end
```

---

### Strategy 2: Route Macros per Module

Extend the current approach where each module defines its own route macro:

```elixir
# lib/phoenix_kit_web/routers/billing_routes.ex
defmodule PhoenixKitWeb.Routers.BillingRoutes do
  @moduledoc "Billing module route definitions"

  defmacro billing_routes do
    quote do
      live "/admin/billing", Live.Modules.Billing.Index, :index
      live "/admin/billing/orders", Live.Modules.Billing.Orders, :index
      live "/admin/billing/orders/new", Live.Modules.Billing.OrderForm, :new
      # ... all billing routes
    end
  end
end

# lib/phoenix_kit_web/integration.ex
defmacro phoenix_kit_admin_routes(suffix) do
  quote do
    live_session unquote(session_name),
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do

      # Core admin routes
      live "/admin", Live.Dashboard, :index
      live "/admin/users", Live.Users.Users, :index

      # Module routes via macros
      import PhoenixKitWeb.Routers.BillingRoutes
      billing_routes()

      import PhoenixKitWeb.Routers.AIRoutes
      ai_routes()

      # ... other modules
    end
  end
end
```

#### File Structure

```
lib/phoenix_kit_web/routers/
├── billing_routes.ex      # defmacro billing_routes
├── ai_routes.ex           # defmacro ai_routes
├── entities_routes.ex     # defmacro entities_routes
└── posts_routes.ex        # defmacro posts_routes
```

#### Pros

- **Code organization**: Routes separated by module
- **Single live_session**: All routes share the same session
- **No pipeline duplication**: Uses parent router's pipelines
- **Easier refactoring**: Move routes between files easily

#### Cons

- **Single compilation unit**: All macros expand in main router
- **No compile-time isolation**: Changes trigger full router recompilation
- **Macro complexity**: More indirection in route definitions

---

### Strategy 3: Hybrid Approach

Combine both strategies based on module size and change frequency:

```elixir
# Large, frequently-changed modules → forward to separate routers
forward "/admin/billing", Routers.BillingRouter
forward "/admin/entities", Routers.EntitiesRouter

# Small, stable modules → inline macros
live_session :admin do
  # Core routes (rarely change)
  live "/admin", Live.Dashboard, :index
  live "/admin/users", Live.Users.Users, :index
  live "/admin/settings", Live.Settings, :index

  # Small modules via macros
  ai_routes()
  jobs_routes()
end
```

#### Decision Matrix

| Module | Routes | Change Frequency | Strategy |
|--------|--------|------------------|----------|
| Billing | ~40 | High | Forward |
| Entities | ~10 | High | Forward |
| AI | ~10 | Medium | Macro |
| Posts | ~10 | Medium | Macro |
| Emails | ~10 | Low | Macro |
| Core Admin | ~20 | Low | Inline |

---

## Implementation Examples

### Example: Billing Module as Separate Router

```elixir
# lib/phoenix_kit_web/routers/billing_router.ex
defmodule PhoenixKitWeb.Routers.BillingRouter do
  @moduledoc """
  Router for billing module routes.

  Mounted at `/admin/billing` via forward in main router.
  All paths here are relative to that mount point.
  """

  use PhoenixKitWeb, :router

  import PhoenixKitWeb.Users.Auth

  # Define pipeline for this router
  pipeline :billing do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: PhoenixKit.LayoutConfig.get_root_layout()
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_phoenix_kit_current_user
    plug :fetch_phoenix_kit_current_scope
  end

  scope "/", PhoenixKitWeb.Live.Modules.Billing do
    pipe_through :billing

    live_session :billing,
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}],
      root_layout: {PhoenixKitWeb.Layouts, :root} do

      # Index
      live "/", Index, :index

      # Orders
      live "/orders", Orders, :index
      live "/orders/new", OrderForm, :new
      live "/orders/:id", OrderDetail, :show
      live "/orders/:id/edit", OrderForm, :edit

      # Invoices
      live "/invoices", Invoices, :index
      live "/invoices/:id", InvoiceDetail, :show
      live "/invoices/:id/print", InvoicePrint, :print
      live "/invoices/:id/receipt", ReceiptPrint, :receipt
      live "/invoices/:id/credit-note/:transaction_id", CreditNotePrint, :credit_note
      live "/invoices/:id/payment/:transaction_id", PaymentConfirmationPrint, :payment_confirmation

      # Transactions
      live "/transactions", Transactions, :index

      # Subscriptions
      live "/subscriptions", Subscriptions, :index
      live "/subscriptions/new", SubscriptionForm, :new
      live "/subscriptions/:id", SubscriptionDetail, :show

      # Plans
      live "/plans", SubscriptionPlans, :index
      live "/plans/new", SubscriptionPlanForm, :new
      live "/plans/:id/edit", SubscriptionPlanForm, :edit

      # Profiles
      live "/profiles", BillingProfiles, :index
      live "/profiles/new", BillingProfileForm, :new
      live "/profiles/:id/edit", BillingProfileForm, :edit

      # Currencies
      live "/currencies", Currencies, :index
    end
  end
end
```

### Example: Mounting in Main Router

```elixir
# lib/phoenix_kit_web/integration.ex

defp generate_admin_forwards(url_prefix) do
  quote do
    # Forward to module routers (separate compilation units)
    scope unquote(url_prefix), PhoenixKitWeb do
      pipe_through [:browser, :phoenix_kit_auto_setup]

      # Large modules with separate routers
      forward "/admin/billing", Routers.BillingRouter
      forward "/admin/entities", Routers.EntitiesRouter

      # Check if module is enabled before forwarding
      if Code.ensure_loaded?(PhoenixKitWeb.Routers.BillingRouter) do
        forward "/admin/billing", Routers.BillingRouter
      end
    end
  end
end
```

### Example: Conditional Module Loading

```elixir
# Forward only if module is enabled
defmacro phoenix_kit_module_routes do
  quote do
    if PhoenixKit.Billing.enabled?() do
      forward "/admin/billing", Routers.BillingRouter
    end

    if PhoenixKit.AI.enabled?() do
      forward "/admin/ai", Routers.AIRouter
    end

    if PhoenixKit.Entities.enabled?() do
      forward "/admin/entities", Routers.EntitiesRouter
    end
  end
end
```

---

## Recommendations

### For Immediate Implementation

1. **Keep current shared macros** for core routes (auth, confirmation, dashboard)
2. **Extract large modules** (Billing, Entities) to separate routers using `forward`
3. **Keep small modules** (AI, Jobs) as inline routes or small macros

### For New Modules

When adding a new module:

1. **< 5 routes**: Add directly to `phoenix_kit_admin_routes/1` macro
2. **5-15 routes**: Create a route macro in `lib/phoenix_kit_web/routers/[module]_routes.ex`
3. **> 15 routes**: Create a separate router in `lib/phoenix_kit_web/routers/[module]_router.ex`

### Localization Handling

For modules using `forward`, handle localization in the sub-router:

```elixir
# Option A: Accept locale as path parameter
forward "/:locale/admin/billing", Routers.BillingRouter

# Option B: Handle locale in sub-router
defmodule BillingRouter do
  scope "/:locale" do
    # localized routes
  end

  scope "/" do
    # non-localized routes (fallback)
  end
end
```

### Testing Sub-Routers

```elixir
# test/phoenix_kit_web/routers/billing_router_test.exs
defmodule PhoenixKitWeb.Routers.BillingRouterTest do
  use PhoenixKitWeb.ConnCase

  describe "billing routes" do
    test "index requires admin", %{conn: conn} do
      conn = get(conn, "/phoenix_kit/admin/billing")
      assert redirected_to(conn) =~ "/users/log-in"
    end

    test "admin can access billing", %{conn: conn} do
      admin = insert(:user, role: :admin)
      conn = conn |> log_in_user(admin) |> get("/phoenix_kit/admin/billing")
      assert html_response(conn, 200) =~ "Billing"
    end
  end
end
```

---

## Summary

| Approach | Compile Isolation | Code Organization | Complexity | Best For |
|----------|-------------------|-------------------|------------|----------|
| Single Router | None | Poor | Low | Small apps |
| Shared Macros (current) | None | Good | Medium | Medium apps |
| Forward to Routers | Full | Excellent | Medium | Large apps |
| Hybrid | Partial | Excellent | High | Growing apps |

**Current state**: PhoenixKit uses shared macros, reducing duplication by ~18%.

**Next step**: Extract Billing and Entities modules to separate routers for compile-time isolation as the codebase grows.
