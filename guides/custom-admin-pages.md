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
    path: "/admin/analytics",
    permission: "dashboard",
    priority: 150,
    group: :admin_main,
    live_view: {MyAppWeb.AdminAnalyticsLive, :index}
  }
]
```

---

## Igniter Generator

For automated setup, use the built-in Igniter task to generate admin pages:

```bash
mix phoenix_kit.gen.admin_page Analytics Reports "Reports Dashboard" \
  --url="/admin/analytics/reports" \
  --icon="hero-chart-bar"
```

### Arguments

| Argument | Description | Example |
|----------|-------------|---------|
| `category` | Category name for grouping | `Analytics` |
| `page_name` | Module name (PascalCase) | `Reports` |
| `page_title` | Display title | `"Reports Dashboard"` |

### Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `--url` | ✅ Yes | - | URL path (must start with `/`) |
| `--icon` | No | `"hero-document-text"` | Heroicon name |
| `--description` | No | - | Brief description |
| `--category-icon` | No | `"hero-folder"` | Category icon |

### What It Generates

1. **LiveView module** at `lib/{app_name}_web/phoenix_kit/live/admin/{category}/{page}.ex`
2. **Config entry** in `config/config.exs` for the admin category
3. **Template-based** boilerplate code

### After Generation

**Important:** You must add the route to your router manually:

```elixir
# lib/my_app_web/router.ex
scope "/" do
  pipe_through :browser

  live_session :phoenix_kit_admin_custom_categories,
    on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
    live "/admin/analytics/reports", MyAppWeb.PhoenixKit.Live.Admin.Analytics.Reports, :index
  end
end
```

### Example: Create Analytics Dashboard

```bash
mix phoenix_kit.gen.admin_page Analytics Dashboard "Analytics Dashboard" \
  --url="/admin/analytics" \
  --icon="hero-chart-bar" \
  --category-icon="hero-chart-bar"
```

This generates:
- Module: `MyAppWeb.PhoenixKit.Live.Admin.Analytics.Dashboard`
- Route: `/admin/analytics`
- File: `lib/my_app_web/phoenix_kit/live/admin/analytics/dashboard.ex`

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
    path: "/admin/analytics",                       # Route path
    permission: "dashboard",                        # Required permission key
    priority: 150,                                  # Sort order (lower = first)
    group: :admin_main,                             # Sidebar group
    live_view: {MyAppWeb.AdminAnalyticsLive, :index}
  }
]
```

### Tab Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `id` | atom | ✅ Yes | Unique identifier for the tab (prefix with `admin_` by convention) |
| `label` | string | ✅ Yes | Display text in sidebar |
| `path` | string | ⚠️ Usually | Route path (auto-generated from `live_view` if provided) |
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

### Using `live_view` for Seamless Navigation

When you provide the `live_view` tuple, PhoenixKit automatically generates a route inside the shared admin `live_session`. This means:

- ✅ No full page reload when navigating from other admin pages
- ✅ Preserves live navigation state
- ✅ Consistent with built-in PhoenixKit admin pages

**If you omit `live_view`**, you must define the route manually in your router.

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
  path: "/admin/blog",
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
  path: "/admin/billing",
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
    path: "/admin/blog",
    permission: "entities",
    group: :admin_content,
    live_view: {MyAppWeb.AdminBlogPostsLive, :index}
  }
]
```

---

## Manual Route Definition

If you don't use the `live_view` option, define routes manually:

```elixir
# lib/my_app_web/router.ex
import PhoenixKitWeb.Integration

scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user, :phoenix_kit_ensure_admin]

  live "/admin/custom", CustomAdminLive
end
```

> **Note**: Manual routes won't get seamless LiveView navigation from other admin pages. Prefer the `live_view` option when possible.

---

**See also**: [Admin Navigation Reference](./lib/phoenix_kit/dashboard/ADMIN_README.md) for complete tab system documentation.

**Last Updated**: 2026-03-02
