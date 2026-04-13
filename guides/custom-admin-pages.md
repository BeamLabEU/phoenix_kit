# Custom Admin Pages

**Add custom pages to the PhoenixKit admin sidebar.**

This guide shows you how to create custom admin pages that integrate seamlessly with PhoenixKit's navigation and layout system.

---

## Quick Start

```elixir
# 1. Create the LiveView
defmodule MyAppWeb.AdminAnalyticsLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Analytics")}
  end

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      page_title={@page_title}
      current_path={@url_path}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_locale={assigns[:current_locale]}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <h1 class="text-2xl font-bold mb-6">Analytics</h1>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end

# 2. Register in config/config.exs
config :phoenix_kit, :admin_dashboard_tabs, [
  %{
    id: :admin_analytics,
    label: "Analytics",
    icon: "hero-chart-bar",
    path: "analytics",
    permission: "dashboard",
    priority: 150,
    group: :admin_main,
    live_view: {MyAppWeb.AdminAnalyticsLive, :index}
  }
]
```

---

## Igniter Generator

For automated setup, use the built-in Igniter task to generate admin pages. The task takes **one positional argument** — the display title — and everything else is optional flags:

```bash
mix phoenix_kit.gen.admin.page "Reports Dashboard"
```

That minimal invocation creates a page titled "Reports Dashboard" in the default `General` category, with an auto-derived URL slug, using the default heroicon.

### Arguments

| Argument | Required | Description | Example |
|----------|----------|-------------|---------|
| `title` | ✅ Yes | Display title for the page — must be under 100 characters | `"Reports Dashboard"` |

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--url` | derived from title via `slugify/1` | URL path (must start with `/`) |
| `--category` | `"General"` | Category name for grouping — first page in a category creates the parent tab |
| `--icon` | `"hero-document-text"` | Heroicon name for the page tab |
| `--permission` | `"dashboard"` | Permission key for the parent tab |
| `--category-icon` | `"hero-folder"` | Heroicon name for the category parent tab |

Short aliases also work: `-u` (url), `-c` (category), `-i` (icon), `-p` (permission), `-ci` (category-icon).

### What It Generates

1. **LiveView module** at `lib/{app_name}_web/phoenix_kit/live/admin/{category}/{page}.ex`
2. **`:admin_dashboard_tabs` entry** in `config/config.exs` — including the `live_view:` field so the route is auto-wired into PhoenixKit's `live_session :phoenix_kit_admin`
3. **Parent tab** for the category if this is the first page in it; subsequent pages in the same category only add child tabs

### After Generation

**You do not need to touch your router.** The generated config entry carries a `live_view:` field, which PhoenixKit compiles into its own `live_session :phoenix_kit_admin` at build time. Just restart your server (routes are generated at compile time, not hot-reloaded) and the page will show up in the admin sidebar.

> ⚠️ **Do not add a `live_session` block for the generated page in your `router.ex`.** Declaring a separate `live_session` — even one that uses `{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}` as its `on_mount` — puts the page in a different session than core admin, and every `push_navigate` from another admin page will tear down the socket with `navigate event failed because you are redirecting across live_sessions. A full page reload will be performed instead`. You also cannot declare a second `live_session :phoenix_kit_admin` block of your own — Phoenix raises at compile time on duplicate names. See [Do Not Hand-Register Admin Routes in Your Parent Router](#do-not-hand-register-admin-routes-in-your-parent-router) below.

### More Examples

```bash
# Put the page under a custom category
mix phoenix_kit.gen.admin.page "User Management" --category="Users"

# Custom icon
mix phoenix_kit.gen.admin.page "Analytics" --icon="hero-chart-bar"

# Full control — category, URL, and icons
mix phoenix_kit.gen.admin.page "Reports" \
  --url="/admin/analytics/reports" \
  --category="Analytics" \
  --icon="hero-chart-bar" \
  --category-icon="hero-chart-bar"
```

The last form generates:
- Module: `MyAppWeb.PhoenixKit.Live.Admin.Analytics.Reports`
- Route: `/admin/analytics/reports`
- File: `lib/my_app_web/phoenix_kit/live/admin/analytics/reports.ex`
- Parent tab: `Analytics` (created on first page in this category)
- Child tab: `Reports` under `Analytics`

Run `mix phoenix_kit.gen.admin.page --help` to see the built-in help.

---

## Manual Setup

If you prefer manual setup or need more control, follow these steps:

Your custom admin LiveView needs to use PhoenixKit's layout wrapper and handle the assigns provided by PhoenixKit's on_mount hooks.

### Basic Template

```elixir
# lib/my_app_web/phoenix_kit_live/admin_analytics_live.ex
defmodule MyAppWeb.AdminAnalyticsLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Analytics")}
  end

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      page_title={@page_title}
      current_path={@url_path}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_locale={assigns[:current_locale]}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <h1 class="text-2xl font-bold mb-6">Analytics</h1>
        <!-- Your content here -->
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
```

### Required Assigns

| Assign | Purpose | Source |
|--------|---------|--------|
| `@flash` | Flash messages for notifications | Phoenix |
| `@page_title` | Page title for browser/tab | Your LiveView |
| `@url_path` | Current request path | PhoenixKit on_mount |
| `@phoenix_kit_current_scope` | Auth scope for permissions | PhoenixKit on_mount |
| `assigns[:current_locale]` | Optional locale for i18n | Your app |

---

## Registering the Tab

Register your custom page in `config/config.exs` using the `:admin_dashboard_tabs` config:

```elixir
config :phoenix_kit, :admin_dashboard_tabs, [
  %{
    id: :admin_analytics,                           # Unique atom ID
    label: "Analytics",                             # Display text
    icon: "hero-chart-bar",                         # Heroicon name
    path: "analytics",                              # Route path (relative — see note below)
    permission: "dashboard",                        # Required permission key
    priority: 150,                                  # Sort order (lower = first)
    group: :admin_main,                             # Sidebar group
    live_view: {MyAppWeb.AdminAnalyticsLive, :index}
  }
]
```

> **About the `path` field.** Tab paths are **relative by convention**. PhoenixKit's `Tab.resolve_path/2` (in `lib/phoenix_kit/dashboard/tab.ex`) prepends the context prefix automatically:
> - `admin_tabs/0` tabs → `/admin/<path>`  (e.g. `"analytics"` → `/admin/analytics`)
> - `settings_tabs/0` tabs → `/admin/settings/<path>`
> - `user_dashboard_tabs/0` tabs → `/dashboard/<path>`
>
> Absolute paths (starting with `/`) pass through unchanged, and both forms are valid. The relative form is preferred because it's what every real plugin module uses (`phoenix_kit_emails`, `phoenix_kit_catalogue`, `phoenix_kit_entities`, etc.), it's shorter, and the same tab can be reused across contexts (admin vs settings) without hardcoding the prefix.

### Tab Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `id` | atom | ✅ Yes | Unique identifier for the tab (prefix with `admin_` by convention) |
| `label` | string | ✅ Yes | Display text in sidebar |
| `path` | string | ⚠️ Usually | Route path — **relative by convention** (e.g. `"analytics"`), resolved to `/admin/analytics` by `Tab.resolve_path/2`. Absolute paths work too but are discouraged |
| `icon` | string | No | Heroicon name (e.g., "hero-chart-bar") |
| `permission` | string | ⚠️ Recommended | Permission key for access control |
| `priority` | integer | No | Sort order (default: 500, lower = higher in sidebar) |
| `group` | atom | No | Sidebar group (default: :admin_main) |
| `parent` | atom | No | Parent tab ID for subtab relationships |
| `match` | atom | No | Path matching: `:exact`, `:prefix`, or `{:regex, ~r/...}` |
| `visible` | function | No | `(scope -> boolean)` for conditional visibility |
| `live_view` | tuple | ⚠️ Recommended | `{Module, :action}` to auto-generate route |
| `subtab_display` | atom | No | `:when_active` or `:always` (default: :when_active) |
| `highlight_with_subtabs` | boolean | No | Highlight parent when subtab is active |

### Using `live_view` is Required, Not Optional

When you provide the `live_view` tuple, PhoenixKit generates the route inside its shared `live_session :phoenix_kit_admin`. You get:

- ✅ The admin layout (sidebar + header) applied by the `:phoenix_kit_ensure_admin` on_mount hook
- ✅ No full page reload when navigating from other admin pages — `push_navigate` stays on the same socket
- ✅ Preserved LiveView state across admin pages
- ✅ Consistent admin permission enforcement

**Omitting `live_view:` and declaring the route yourself in `router.ex` is not a supported alternative** — you will lose the admin layout entirely, and every click from another admin page will tear down the WebSocket. See [Do Not Hand-Register Admin Routes in Your Parent Router](#do-not-hand-register-admin-routes-in-your-parent-router) below for the full explanation.

---

## Sidebar Groups

PhoenixKit organizes admin tabs into groups for better organization:

| Group | Description | Example Tabs |
|-------|-------------|--------------|
| `:admin_main` | Primary admin functions | Dashboard, Users, Settings |
| `:admin_content` | Content management | Entities, Publishing |
| `:admin_modules` | Feature modules | AI, Billing, Commerce |
| `:admin_system` | System-level | Logs, Background Jobs |

```elixir
# Content group example
%{
  id: :blog_posts,
  label: "Blog Posts",
  icon: "hero-document-text",
  path: "blog",
  permission: "entities",
  group: :admin_content,  # <-- Groups under "Content"
  live_view: {MyAppWeb.BlogPostsLive, :index}
}
```

---

## Permission Gates

### Simple Permission Check

Use the `permission` option to restrict access:

```elixir
%{
  id: :admin_billing,
  label: "Billing",
  icon: "hero-credit-card",
  path: "billing",
  permission: "billing",  # Users need "billing" permission
  live_view: {MyAppWeb.BillingLive, :index}
}
```

### In-LiveView Permission Check

For additional permission checks within your LiveView:

```elixir
def mount(_params, _session, socket) do
  scope = socket.assigns.phoenix_kit_current_scope

  if PhoenixKit.Users.Auth.Scope.system_role?(scope) or
     PhoenixKit.Users.Auth.Scope.has_module_access?(scope, "billing") do
    {:ok, assign(socket, page_title: "Billing")}
  else
    {:ok, redirect_or_show_error(socket)}
  end
end
```

---

## Common Patterns

### Data Fetching in mount/3

```elixir
def mount(_params, _session, socket) do
  # Fetch your data
  products = MyApp.Catalog.list_products()

  {:ok, assign(socket,
    page_title: "Products",
    products: products
  )}
end
```

### Handle Events

```elixir
def handle_event("delete_product", %{"id" => id}, socket) do
  {:ok, _product} = MyApp.Catalog.delete_product(id)

  {:noreply, put_flash(socket, :info, "Product deleted")}
end
```

### Pagination

```elixir
def mount(params, _session, socket) do
  page = String.to_integer(params["page"] || "1")
  per_page = 20

  {products, pagination} = MyApp.Catalog.paginate_products(page, per_page)

  {:ok, assign(socket,
    page_title: "Products",
    products: products,
    pagination: pagination
  )}
end
```

---

## Full Example: Blog Posts Admin

```elixir
# lib/my_app_web/phoenix_kit_live/admin_blog_posts_live.ex
defmodule MyAppWeb.AdminBlogPostsLive do
  use MyAppWeb, :live_view

  alias MyApp.Blog

  def mount(_params, _session, socket) do
    posts = Blog.list_posts()
    {:ok, assign(socket, posts: posts, page_title: "Blog Posts")}
  end

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      page_title={@page_title}
      current_path={@url_path}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_locale={assigns[:current_locale]}
    >
      <div class="container mx-auto px-4 py-6">
        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">Blog Posts</h1>
          <.link navigate="/admin/blog/new" class="btn btn-primary">
            New Post
          </.link>
        </div>

        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Title</th>
              <th>Status</th>
              <th>Date</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={post <- @posts}>
              <td><%= post.title %></td>
              <td><%= post.status %></td>
              <td><%= post.published_at %></td>
              <td class="flex gap-2">
                <.link navigate={"/admin/blog/#{post.id}/edit"} class="btn btn-xs">
                  Edit
                </.link>
                <button phx-click="delete" phx-value-id={post.id} class="btn btn-xs btn-error">
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _post} = Blog.delete_post(id)
    posts = Blog.list_posts()
    {:noreply, assign(socket, posts: posts) |> put_flash(:info, "Post deleted")}
  end
end

# config/config.exs
config :phoenix_kit, :admin_dashboard_tabs, [
  # ... other tabs
  %{
    id: :admin_blog_posts,
    label: "Blog Posts",
    icon: "hero-document-text",
    path: "blog",
    permission: "entities",
    group: :admin_content,
    live_view: {MyAppWeb.AdminBlogPostsLive, :index}
  }
]
```

---

## Do Not Hand-Register Admin Routes in Your Parent Router

**Never** declare `live` routes for PhoenixKit admin LiveViews in your parent app's `router.ex`. Always go through the tab system (`live_view:` field) or a plugin route module. Hand-writing the route breaks two things:

1. **The admin layout disappears.** The sidebar and header are applied by the `:phoenix_kit_ensure_admin` on_mount hook (`lib/phoenix_kit_web/users/auth.ex`), which calls `maybe_apply_plugin_layout/1`. That hook only runs inside PhoenixKit's `live_session :phoenix_kit_admin`. A route declared in your own router sits in a different (or unnamed) live_session and never gets the layout.
2. **Cross-`live_session` navigation crashes the socket.** Phoenix LiveView refuses to `push_navigate` across live_session boundaries — the server logs `navigate event to <url> failed because you are redirecting across live_sessions. A full page reload will be performed instead`, the WebSocket is torn down, and the user gets a full page reload every time they click from another admin page into yours.

**Note on `:phoenix_kit_ensure_admin`.** It is an **`on_mount` hook**, not a Plug. You cannot put it in a `pipe_through` list. It only functions when attached to a `live_session` block via `on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}]`.

**Note on reusing the `live_session` name.** You cannot work around this by declaring a second `live_session :phoenix_kit_admin` block in your router — Phoenix LiveView raises at compile time (`attempting to redefine live_session :phoenix_kit_admin. live_session routes must be declared in a single named block`). There is exactly one `:phoenix_kit_admin` block, and PhoenixKit owns it.

### The two supported ways to add an admin page

Both patterns compile routes into the same shared `live_session :phoenix_kit_admin`. You get the admin layout, seamless navigation, and the admin permission check with either one. **Both support dynamic path segments** (`:id`, `:uuid`, `:slug`, etc.) — `tab_to_route/1` in `lib/phoenix_kit_web/integration.ex` splices the `path` string verbatim into a Phoenix `live` route, so anything Phoenix router accepts works here.

**1. `live_view:` on a tab** — the lightweight pattern. Each tab generates exactly one route:

```elixir
config :phoenix_kit, :admin_dashboard_tabs, [
  %{
    id: :admin_analytics,
    label: "Analytics",
    icon: "hero-chart-bar",
    path: "analytics",
    permission: "dashboard",
    group: :admin_main,
    live_view: {MyAppWeb.AdminAnalyticsLive, :index}
  }
]
```

For CRUD pages that shouldn't appear in the sidebar (e.g. `analytics/:id/edit`, `analytics/new`), add additional tabs with `visible: false` and a `parent:` link — dynamic segments are fine in the `path` field:

```elixir
%{
  id: :admin_analytics_edit,
  label: "Edit Report",
  path: "analytics/:id/edit",
  parent: :admin_analytics,
  visible: false,
  live_view: {MyAppWeb.AdminAnalyticsFormLive, :edit}
}
```

This is how `phoenix_kit_posts`, `phoenix_kit_catalogue`, `phoenix_kit_locations`, `phoenix_kit_emails`, and most other plugins wire their CRUD routes — see `phoenix_kit_posts/lib/phoenix_kit_posts.ex:213` and `phoenix_kit_catalogue/lib/phoenix_kit_catalogue.ex:198` for reference.

**2. Plugin route module** — the flexible pattern. Extract your pages into a PhoenixKit plugin that exports `route_module/0`, returning a module with `admin_routes/0` and `admin_locale_routes/0`. Each function returns a quoted block of **`live` route declarations** that get spliced into `:phoenix_kit_admin` at compile time.

> **These admin functions can only contain `live` routes.** `admin_routes/0` and `admin_locale_routes/0` are spliced directly inside Phoenix's `live_session :phoenix_kit_admin do … end` block (see `phoenix_kit/lib/phoenix_kit_web/integration.ex:481`), and Phoenix LiveView's `live_session` only permits `live` declarations inside its body — controllers (`get`, `post`, `put`, etc.), `forward`, nested `scope` blocks, and `pipe_through` all raise at compile time when placed there. Non-LiveView admin functionality isn't supported by this pattern. For non-LiveView module routes (controllers, API endpoints, forwards, catch-all public pages), use the **`generate/1`** or **`public_routes/1`** entry points on the same route module — they splice into separate router locations outside any `live_session`. `phoenix_kit_sync/lib/phoenix_kit_sync/routes.ex` is a good reference (`post "/sync/api/…"` and `forward "…/sync/websocket"` live in `generate/1`).

Use the route-module `admin_routes/0` / `admin_locale_routes/0` pattern when:

- You want many admin `live` routes without a `Tab` entry for each (e.g. admin routes that don't need a sidebar item)
- You need **separate localized and non-localized variants** with distinct `:as` aliases — `admin_tabs/0` generates one route per tab and can't do this split
- You want to mix both patterns in one module — `phoenix_kit_ai` is a good reference: it uses `admin_tabs/0` for sidebar structure plus a route module for supplementary CRUD form routes. See `phoenix_kit_ai/lib/phoenix_kit_ai/routes.ex`.

Other reference implementations: `phoenix_kit_entities/lib/phoenix_kit_entities/routes.ex` (admin `live` routes + public form submission routes via `generate/1`), `phoenix_kit_publishing/lib/phoenix_kit_publishing/routes.ex` (admin `live` routes via `admin_locale_routes/0` + public controller routes via `public_routes/1`).

---

**See also**: [Admin Navigation Reference](./lib/phoenix_kit/dashboard/ADMIN_README.md) for complete tab system documentation.

**Last Updated**: 2026-03-02
