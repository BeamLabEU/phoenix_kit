# Blogging Module

The PhoenixKit Blogging module provides a filesystem-based content management system with multi-language support and dual storage modes. Posts are stored as `.phk` files (YAML frontmatter + Markdown content) rather than in the database, giving content creators a familiar file-based workflow with version control integration.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/blogging`
- **Public Blog**: `/{language}/blog` (overview) or `/{language}/blog/{blog-slug}` (listing)
- **Settings**: Configure via `blogging_public_enabled` and `blogging_posts_per_page` in Settings

## Public Blog Display

The blogging module includes public-facing routes for displaying published posts to site visitors.

### Public URLs

```
/{language}/blog                              # All blogs overview
/{language}/blog/{blog-slug}                  # Blog post listing
/{language}/blog/{blog-slug}/{post-slug}      # Slug mode post
/{language}/blog/{blog-slug}/{date}/{time}    # Timestamp mode post
```

**Examples:**
- `/en/blog` - Shows all blogs (Docs, News, etc.)
- `/en/blog/docs` - Lists all published posts in Docs blog
- `/en/blog/docs/getting-started` - Shows specific post (slug mode)
- `/en/blog/news/2025-11-02/14:30` - Shows specific post (timestamp mode)

### Features

- **Status-Based Access Control** - Only `status: published` posts are visible
- **Markdown Rendering** - GitHub-style markdown CSS with syntax highlighting
- **Language Support** - Multi-language posts with language switcher
- **Content-Based Language Detection** - Custom language files (e.g., `af.phk`) work without predefinition
- **Flexible Fallbacks** - Missing language versions redirect to available alternatives
- **Pagination** - Configurable posts per page (default: 20)
- **SEO Ready** - Clean URLs, breadcrumbs, responsive design
- **Performance** - Content-hash-based caching with versioned keys (`v1:blog_post:...`)
- **Beta Badge** - Blog listings include Beta badge during v1.5.0 launch

### Language Detection

The blogging module supports two types of language detection:

1. **Predefined Languages** - Languages configured in the Languages module (e.g., `en`, `fr`, `es`)
2. **Content-Based Languages** - Any `.phk` file in a post directory is treated as a valid language

This allows custom language files like `af.phk` (Afrikaans) or `test.phk` to work correctly even if not predefined in the Languages module. The language switcher will show these with a strikethrough to indicate they're not officially enabled, but they remain accessible.

### Fallback Behavior

When a requested post or language version is not found, the system follows a fallback chain:

**For slug-mode posts (`/en/blog/docs/getting-started`):**
1. Try other languages for the same post (default language first)
2. If no published language versions exist, redirect to blog listing

**For timestamp-mode posts (`/en/blog/news/2025-12-24/15:30`):**
1. Try other languages for the same date/time
2. Try other times on the same date
3. If no posts on that date, redirect to blog listing

**User Experience:**
- Redirects include a flash message: "The page you requested was not found. Showing closest match."
- Bookmarked URLs continue to work even if specific translations are removed

### Configuration

Enable/disable public blog display and set pagination:

```elixir
# In your Settings admin interface at /{prefix}/admin/settings
blogging_public_enabled = true   # Enable public blog routes
blogging_posts_per_page = 20     # Posts per page in listings
```

Or programmatically:

```elixir
PhoenixKit.Settings.update_setting("blogging_public_enabled", "true")
PhoenixKit.Settings.update_setting("blogging_posts_per_page", "20")
```

### Templates

Public blog templates are located in:

- `lib/phoenix_kit_web/controllers/blog_html/show.html.heex` - Single post view
- `lib/phoenix_kit_web/controllers/blog_html/index.html.heex` - Blog listing
- `lib/phoenix_kit_web/controllers/blog_html/all_blogs.html.heex` - All blogs overview

### Admin Integration

When editing a post in the admin interface:

- **View Public** button appears for published posts
- Button links directly to the public URL
- Automatically updates when status changes to "published"

### Caching

The `PhoenixKit.Blogging.Renderer` module provides:

- **Content-hash-based cache keys** - Automatic invalidation when content changes
- **Versioned cache** - Keys include `v1:` prefix for cache busting
- **Published-only caching** - Draft and archived posts are not cached
- **Performance logging** - Debug logs include render time and content size

Example cache key: `v1:blog_post:docs:getting-started:en:a1b2c3d4`

## Architecture Overview

- **PhoenixKitWeb.Live.Modules.Blogging** – Main context module with mode-aware routing
- **PhoenixKitWeb.Live.Modules.Blogging.Storage** – Storage layer with CRUD operations for both modes
- **PhoenixKitWeb.Live.Modules.Blogging.Metadata** – YAML frontmatter parsing and serialization
- **PhoenixKitWeb.Live.Modules.Blogging.Settings** – Admin interface for blog configuration
- **PhoenixKitWeb.Live.Modules.Blogging.Editor** – Markdown editor with mode-specific UI
- **PhoenixKitWeb.Live.Modules.Blogging.Preview** – Live preview for blog posts

## Core Features

- **Dual Storage Modes** – Timestamp-based (date/time folders) or slug-based (semantic URLs)
- **Mode Immutability** – Storage mode locked at blog creation, cannot be changed
- **Slug Mutability** – Post slugs can be changed after creation (triggers file/directory movement)
- **Multi-Language Support** – Separate `.phk` files for each language translation
- **Filesystem Storage** – Posts stored as files, enabling Git workflows and external tooling
- **YAML Frontmatter** – Metadata stored as structured YAML at the top of each file
- **Markdown Content** – Full Markdown support with syntax highlighting
- **Backward Compatibility** – Legacy blogs without mode field default to "timestamp"

## Storage Modes

### 1. Timestamp Mode (Default, Legacy)

Posts organized by publication date and time:

```
blog-slug/
  └── 2025-01-15/
      └── 09:30/
          ├── en.phk
          ├── es.phk
          └── fr.phk
```

**Characteristics:**
- Auto-generates folder structure from `published_at` timestamp
- No slug field in editor UI
- Ideal for chronological content (news, announcements, changelogs)
- Path cannot be manually controlled by user

**Example Path:** `news/2025-01-15/09:30/en.phk`

### 2. Slug Mode (Semantic URLs)

Posts organized by semantic slug:

```
blog-slug/
  └── getting-started/
      ├── en.phk
      ├── es.phk
      └── fr.phk
```

**Characteristics:**
- User-provided or auto-generated slug from title
- Slug field visible in editor UI
- Slug validation: lowercase letters, numbers, hyphens only
- Ideal for documentation, guides, evergreen content
- Slug can be changed (all language files move to new directory)

**Example Path:** `docs/getting-started/en.phk`

## File Format (.phk files)

PhoenixKit posts use YAML frontmatter followed by Markdown content:

```yaml
---
slug: getting-started
title: Getting Started Guide
status: published
published_at: 2025-01-15T09:30:00Z
created_at: 2025-01-15T09:30:00Z  # Only in slug mode
---

# Welcome to the Guide

This is the **Markdown content** of your post.

- Supports all standard Markdown features
- Code blocks with syntax highlighting
- Images, links, tables, etc.
```

**Frontmatter Fields:**

- `slug` – Post slug (required, used for file path in slug mode)
- `title` – Display title (required)
- `status` – Publication status: `draft` or `published`
- `published_at` – Publication timestamp (ISO8601 format)
- `created_at` – Creation timestamp (slug mode only, for sorting)

## Context Layer API

The main context module (`blogging.ex`) routes operations based on blog mode:

### Blog Management

```elixir
# Create blog with storage mode
{:ok, blog} = Blogging.add_blog("Documentation", "slug")
{:ok, blog} = Blogging.add_blog("Company News", "timestamp")

# List all blogs (includes mode field)
blogs = Blogging.list_blogs()
# => [%{"name" => "Docs", "slug" => "docs", "mode" => "slug"}, ...]

# Get blog storage mode
mode = Blogging.get_blog_mode("docs")  # => "slug"

# Remove blog
{:ok, _} = Blogging.remove_blog("docs")
```

### Post Operations

The context layer automatically routes to the correct storage implementation:

```elixir
# Create post (routes by blog mode)
{:ok, post} = Blogging.create_post("docs", %{title: "Hello World"})
# Slug mode: auto-generates slug "hello-world"
# Timestamp mode: uses current date/time

# Create post with explicit slug (slug mode only)
{:ok, post} = Blogging.create_post("docs", %{
  title: "Getting Started",
  slug: "get-started"
})

# List posts (routes by blog mode)
posts = Blogging.list_posts("docs")
posts = Blogging.list_posts("docs", "es")  # With language preference

# Read post (routes by blog mode)
{:ok, post} = Blogging.read_post("docs", "getting-started")
{:ok, post} = Blogging.read_post("docs", "getting-started", "es")

# Update post (routes by post.mode field)
{:ok, updated} = Blogging.update_post("docs", post, %{
  "title" => "Updated Title",
  "slug" => "new-slug",  # Slug mode: moves files
  "content" => "Updated content..."
})

# Add translation
{:ok, spanish_post} = Blogging.add_language_to_post("docs", "getting-started", "es")
```

## Storage Layer Implementation

The storage layer (`storage.ex`) provides separate implementations for each mode:

### Slug Mode Functions

```elixir
# Validation
Storage.valid_slug?("hello-world")  # => true
Storage.valid_slug?("Hello World")  # => false

# Collision-free slug generation
slug = Storage.generate_unique_slug("docs", "Getting Started")
# => "getting-started"
# If exists: "getting-started-1", "getting-started-2", etc.

# CRUD operations
{:ok, post} = Storage.create_post_slug_mode("docs", "Hello", "hello")
{:ok, post} = Storage.read_post_slug_mode("docs", "hello", "en")
posts = Storage.list_posts_slug_mode("docs", "en")
{:ok, post} = Storage.update_post_slug_mode("docs", post, params)

# Move post to new slug (all languages)
{:ok, post} = Storage.move_post_to_new_slug("docs", post, "new-slug", params)
```

### Timestamp Mode Functions

```elixir
# CRUD operations (legacy, still supported)
{:ok, post} = Storage.create_post("news")
{:ok, post} = Storage.read_post("news", "news/2025-01-15/09:30/en.phk")
posts = Storage.list_posts("news", "en")
{:ok, post} = Storage.update_post("news", post, params)
```

## LiveView Interfaces

### Settings (`settings.ex`)

Blog configuration interface at `{prefix}/admin/blogging/settings`:

- Create new blogs with mode selector (radio buttons: Timestamp / Slug)
- View existing blogs with mode badges
- Delete blogs
- Mode is read-only after blog creation

**UI Elements:**
- Mode selector: Radio buttons defaulted to "Timestamp"
- Mode badge: Shows current mode for each blog (color-coded)
- Warning text: "Cannot be changed after blog creation"

### Editor (`editor.ex`)

Markdown editor at `{prefix}/admin/blogging/{blog}/edit`:

- Title input (all modes)
- **Slug input** (slug mode only, with validation)
- Status selector (draft/published)
- Published at timestamp picker
- Markdown editor with preview
- Language switcher for translations
- Auto-save with dirty detection

**Mode-Specific Behavior:**

**Timestamp Mode:**
- No slug field visible
- Virtual path shown: `blog/2025-01-15/09:30/en.phk`
- Path auto-generated on save from `published_at`

**Slug Mode:**
- Slug field visible with validation
- Auto-generates slug from title (debounced)
- User can override auto-generated slug
- Validation: lowercase, numbers, hyphens only
- Shows validation error for invalid slugs
- Path preview: `blog/post-slug/en.phk`

### Preview (`preview.ex`)

Live preview at `{prefix}/admin/blogging/{blog}/preview`:

- Renders Markdown content with Phoenix.Component
- Shows metadata preview (title, status, published date)
- Language switcher for viewing translations

## Multi-Language Support

Every post can have multiple language files in the same directory:

```
docs/
  └── getting-started/
      ├── en.phk    # English (primary)
      ├── es.phk    # Spanish translation
      └── fr.phk    # French translation
```

**Workflow:**

1. Create primary post (e.g., English)
2. Click language switcher → Select "Add Spanish"
3. System creates `es.phk` with empty content and title
4. Fill in translated content and save
5. All translations share same slug/path structure

**Post Struct Fields:**

```elixir
%{
  blog: "docs",
  slug: "getting-started",          # Slug mode only
  date: ~D[2025-01-15],             # Timestamp mode only
  time: ~T[09:30:00],               # Timestamp mode only
  path: "docs/getting-started/en.phk",
  full_path: "/var/app/content/docs/getting-started/en.phk",
  metadata: %{
    title: "Getting Started",
    status: "published",
    slug: "getting-started",
    published_at: "2025-01-15T09:30:00Z",
    created_at: "2025-01-15T09:30:00Z"  # Slug mode only
  },
  content: "# Markdown content...",
  language: "en",
  available_languages: ["en", "es", "fr"],
  language_statuses: %{"en" => "published", "es" => "draft", "fr" => "published"},
  mode: :slug  # or :timestamp
}
```

**Note on `language_statuses`:** This field is preloaded when posts are fetched via `list_posts` or `read_post` to avoid redundant file reads. It maps each available language code to its publication status.

## Migration Path

### Existing Blogs (Pre-Dual-Mode)

All existing blogs automatically default to `"timestamp"` mode via `normalize_blogs/1`:

```elixir
# Before (legacy blog without mode field)
%{"name" => "News", "slug" => "news"}

# After (normalized with default mode)
%{"name" => "News", "slug" => "news", "mode" => "timestamp"}
```

No migration script needed – backward compatibility is automatic.

### Creating New Blogs

Admin chooses mode at creation time:

1. Navigate to `{prefix}/admin/blogging/settings`
2. Enter blog name: "Documentation"
3. Select mode: **Slug** or **Timestamp**
4. Click "Add Blog"
5. Mode is now permanently locked for this blog

## Test Coverage

### Storage Layer Tests

**File:** `test/phoenix_kit_web/live/modules/blogging/storage_slug_test.exs`

**Coverage:** 62 tests for slug mode storage layer

- Slug validation (format, reserved words, edge cases)
- Slug generation (from titles, collision handling, uniqueness)
- Post creation (with/without explicit slug, title inference)
- Post reading (by slug, by language, error cases)
- Post listing (sorting by created_at, language filtering)
- Post updates (content, metadata, slug changes)
- Slug changes (file movement, directory cleanup)
- Multi-language (adding translations, reading specific languages)

### Context Layer Tests

**File:** `test/phoenix_kit_web/live/modules/blogging/blogging_mode_test.exs`

**Coverage:** 9 tests for mode routing

- Blog configuration (mode injection, persistence, defaults)
- Mode-aware routing (create, list, read, update, add language)
- Both timestamp and slug modes tested
- FakeSettings implementation for isolated testing

### UI Layer Tests

**File:** `test/phoenix_kit_web/live/modules/blogging/editor_test.exs`

**Coverage:** 5 tests for editor UI

- Slug field visibility (present for slug mode, absent for timestamp mode)
- Slug validation (invalid formats rejected)
- Auto-generation from title
- Custom slug persistence
- New post creation flow

### Shared Test Helper

**Status:** Future Implementation

**Planned File:** `test/support/blogging_fake_settings.ex`

When blogging tests are implemented, an in-memory settings stub will be used to avoid database dependencies. Configuration should be done via `config/test.exs`, NOT runtime `Application.put_env/2`:

```elixir
# config/test.exs (CORRECT approach)
import Config

config :phoenix_kit,
  blogging_settings_module: PhoenixKit.Test.FakeSettings

# In test files - FakeSettings will be pre-configured
# No need for Application.put_env calls
FakeSettings.update_json_setting("blogging_blogs", %{
  "blogs" => [%{"name" => "Docs", "slug" => "docs", "mode" => "slug"}]
})
```

### Running Tests

**Status:** Tests not yet implemented

When implemented, tests will be run as follows:

```bash
# Run all blogging tests
mix test test/phoenix_kit_web/live/modules/blogging/

# Run specific test suites
mix test test/phoenix_kit_web/live/modules/blogging/storage_slug_test.exs
mix test test/phoenix_kit_web/live/modules/blogging/blogging_mode_test.exs
mix test test/phoenix_kit_web/live/modules/blogging/editor_test.exs
```

## Configuration

Blogging module uses PhoenixKit Settings for configuration:

```elixir
# Enable/disable blogging system
Blogging.enable_system()
Blogging.disable_system()
Blogging.enabled?()  # => true/false

# Blog list stored as JSON setting
# Key: "blogging_blogs"
# Value: %{"blogs" => [%{"name" => "...", "slug" => "...", "mode" => "..."}]}
```

### Storage Path

Content is stored in the filesystem under:

```
priv/blogging/
  ├── docs/
  │   ├── getting-started/
  │   │   ├── en.phk
  │   │   └── es.phk
  │   └── advanced-guide/
  │       └── en.phk
  └── news/
      └── 2025-01-15/
          └── 09:30/
              └── en.phk
```

Default: `priv/blogging`

Note: The path is determined by the parent application's priv directory, not PhoenixKit's dependencies folder.

## Best Practices

### Choosing Storage Mode

**Use Timestamp Mode when:**
- Content is time-sensitive (news, announcements, changelogs)
- Chronological order is primary navigation pattern
- URLs should reflect publication date
- Posts are rarely renamed or restructured

**Use Slug Mode when:**
- Content is evergreen (documentation, guides, tutorials)
- Semantic URLs improve SEO and user experience
- Posts may be reorganized or renamed over time
- URL structure matters for branding

### Slug Design Guidelines

**Good slugs:**
- `getting-started` – Clear, readable
- `api-authentication` – Descriptive
- `migrate-from-v1-to-v2` – Self-explanatory

**Bad slugs:**
- `Getting Started` – Contains uppercase and spaces (invalid)
- `post-1` – Not descriptive
- `api_auth` – Uses underscores instead of hyphens (invalid)
- `article` – Too generic

### Multi-Language Strategy

1. **Always create English first** – Establish primary content structure
2. **Use consistent slugs** – All translations share the same slug/path
3. **Translate titles** – Each language file has its own frontmatter title
4. **Don't mix languages** – One language per `.phk` file
5. **Test translations** – Use language switcher in editor/preview

## Troubleshooting

### Problem: Slug validation fails with valid-looking slug

**Symptoms:**
```
Invalid slug format
```

**Root Cause:**

Slug contains uppercase letters, underscores, or special characters.

**Solution:**

Use only lowercase letters, numbers, and hyphens:

```elixir
# ✅ Valid slugs
"hello-world"
"api-v2-guide"
"2025-roadmap"

# ❌ Invalid slugs
"Hello-World"     # Uppercase
"api_guide"       # Underscore
"guide!"          # Special char
"my slug"         # Space
```

---

### Problem: Post not found after changing slug

**Symptoms:**
```
Post not found
```

**Root Cause:**

Old links still reference the previous slug.

**Solution:**

Slug changes move files to new directories. Update any hardcoded links:

```elixir
# Before slug change
Blogging.read_post("docs", "old-slug")

# After slug change (from "old-slug" to "new-slug")
Blogging.read_post("docs", "new-slug")  # ✅ Works
Blogging.read_post("docs", "old-slug")  # ❌ Not found
```

Consider implementing redirects in your application for user-facing URLs.

---

### Problem: Cannot change blog mode

**Symptoms:**

Mode field is read-only in settings UI.

**Root Cause:**

Mode immutability is by design – storage mode is locked at blog creation.

**Solution:**

To change modes, you must:

1. Create a new blog with the desired mode
2. Manually copy `.phk` files to new blog structure
3. Update internal references
4. Delete old blog

**No automatic migration is provided** – this is an infrequent operation best done manually.

---

### Problem: FakeSettings module not found in tests

**Status:** Not applicable - FakeSettings not yet implemented

**Future Implementation:**

When blogging tests are added, the FakeSettings module will be:

1. **Defined in:** `test/support/fake_settings.ex` (standard Phoenix test support location)
2. **Configured in:** `config/test.exs` (NOT runtime in test files)
3. **Used as:** `PhoenixKit.Test.FakeSettings` (standard namespace)

**Correct pattern:**

```elixir
# config/test.exs
config :phoenix_kit,
  blogging_settings_module: PhoenixKit.Test.FakeSettings

# test/support/fake_settings.ex
defmodule PhoenixKit.Test.FakeSettings do
  use Agent
  # Implementation details...
end
```

## Getting Help

1. Check test suite for usage examples: `test/phoenix_kit_web/live/modules/blogging/`
2. Review storage layer implementation: `lib/phoenix_kit_web/live/modules/blogging/context/storage.ex`
3. Inspect post struct in IEx: `{:ok, post} = Blogging.read_post("docs", "slug")` → `IO.inspect(post)`
4. Enable debug logging: `Logger.configure(level: :debug)`
5. Search GitHub issues: <https://github.com/phoenixkit/phoenix_kit/issues>
