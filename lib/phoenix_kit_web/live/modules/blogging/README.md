# Blogging Module

The PhoenixKit Blogging module provides a filesystem-based content management system with multi-language support and dual storage modes. Posts are stored as `.phk` files (YAML frontmatter + Markdown content) rather than in the database, giving content creators a familiar file-based workflow with version control integration.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/blogging`
- **Public Blog**: `/{prefix}/{language}/{blog-slug}` (listing) or `/{prefix}/{blog-slug}` (single-language)
- **Settings**: Configure via `blogging_public_enabled` and `blogging_posts_per_page` in Settings

## Public Blog Display

The blogging module includes public-facing routes for displaying published posts to site visitors.

### Public URLs

**Multi-language mode:**
```
/{prefix}/{language}/{blog-slug}                  # Blog post listing
/{prefix}/{language}/{blog-slug}/{post-slug}      # Slug mode post
/{prefix}/{language}/{blog-slug}/{date}/{time}    # Timestamp mode post
```

**Single-language mode** (when only one language is enabled):
```
/{prefix}/{blog-slug}                             # Blog post listing
/{prefix}/{blog-slug}/{post-slug}                 # Slug mode post
/{prefix}/{blog-slug}/{date}/{time}               # Timestamp mode post
```

**Examples** (assuming `{prefix}` is `/phoenix_kit`):
- `/phoenix_kit/en/docs` - Lists all published posts in Docs blog (English)
- `/phoenix_kit/en/docs/getting-started` - Shows specific post (slug mode)
- `/phoenix_kit/en/news/2025-11-02/14:30` - Shows specific post (timestamp mode)
- `/phoenix_kit/docs` - Single-language mode listing

### Features

- **Status-Based Access Control** - Only `status: published` posts are visible
- **Markdown Rendering** - GitHub-style markdown CSS with syntax highlighting
- **Language Support** - Multi-language posts with language switcher
- **Content-Based Language Detection** - Custom language files (e.g., `af.phk`) work without predefinition
- **Flexible Fallbacks** - Missing language versions redirect to available alternatives
- **Pagination** - Configurable posts per page (default: 20)
- **SEO Ready** - Clean URLs, breadcrumbs, responsive design
- **Performance** - Content-hash-based caching with versioned keys (`v1:blog_post:...`)

### Language Detection

The blogging module uses a multi-step detection process to determine if a URL segment is a language code or a blog slug:

**Detection Flow (`detect_language_or_blog`):**
1. **Enabled language** - If the segment matches an enabled language code (e.g., `en`, `fr-CA`), treat as language
2. **Base code mapping** - If it's a 2-letter code that maps to an enabled dialect (e.g., `en` → `en-US`), treat as language
3. **Known language pattern** - If it matches a predefined language code (even if disabled), treat as language
4. **Content-based check** - If content exists for this language in the requested blog, treat as language
5. **Default** - Otherwise, treat as a blog slug and use the default language

**Supported Language Types:**
- **Predefined Languages** - Languages configured in the Languages module (e.g., `en`, `fr`, `es`)
- **Content-Based Languages** - Any `.phk` file in a post directory is treated as a valid language

This allows custom language files like `af.phk` (Afrikaans) or `test.phk` to work correctly even if not predefined in the Languages module. The language switcher will show these with a strikethrough to indicate they're not officially enabled, but they remain accessible.

**Single-Language Mode:**
When only one language is enabled, URLs don't require the language segment:
- `/phoenix_kit/docs/getting-started` works the same as `/phoenix_kit/en/docs/getting-started`

### Fallback Behavior

Fallbacks are triggered only for `:post_not_found` or `:unpublished` errors. Other errors (e.g., `:blog_not_found`, server errors) result in a standard 404 page.

**For slug-mode posts (`/{prefix}/en/docs/getting-started`):**
1. Try other languages for the same post (default language first)
2. If no published language versions exist, redirect to blog listing

**For timestamp-mode posts (`/{prefix}/en/news/2025-12-24/15:30`):**
1. Try other languages for the same date/time
2. Try other times on the same date
3. If no posts on that date, redirect to blog listing

**Fallback Priority:**
The system tries languages in this order:
1. Default language (from Settings)
2. Other available languages (in order they appear in the post directory)

**User Experience:**
- Redirects include a flash message: "The page you requested was not found. Showing closest match."
- Bookmarked URLs continue to work even if specific translations are removed
- Users are never shown a 404 if any published version of the content exists

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
status: published
published_at: 2025-01-15T09:30:00Z
created_at: 2025-01-15T09:30:00Z  # Only in slug mode
---

# Getting Started Guide

This is the **Markdown content** of your post.

- Supports all standard Markdown features
- Code blocks with syntax highlighting
- Images, links, tables, etc.
```

**Title Extraction:**

The post title is **extracted from the first Markdown heading** (`# Title`), not stored in frontmatter. This approach:
- Keeps the title visible in the content for authors
- Avoids duplication between frontmatter and content
- Makes the rendered output match the source file

**Frontmatter Fields:**

- `slug` – Post slug (required, used for file path in slug mode)
- `status` – Publication status: `draft`, `published`, or `archived`
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
- Status selector (draft/published/archived)
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

**Status:** Tests not yet implemented

The blogging module is tested through integration testing in parent Phoenix applications rather than unit tests within PhoenixKit itself. This is consistent with PhoenixKit's library-first architecture (see CLAUDE.md for testing philosophy).

**Recommended Testing Approach:**

1. **Integration Testing** - Test blogging functionality in your parent Phoenix application
2. **Manual Testing** - Use the admin interface at `/{prefix}/admin/blogging`
3. **Static Analysis** - Run `mix credo --strict` and `mix dialyzer` to catch logic errors

**Future Test Implementation:**

When blogging tests are added, they will use an in-memory settings stub to avoid database dependencies:

```elixir
# config/test.exs
config :phoenix_kit,
  blogging_settings_module: PhoenixKit.Test.FakeSettings
```

**Running Tests:**

```bash
# Run all blogging tests (when implemented)
mix test test/phoenix_kit_web/live/modules/blogging/
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
3. **Translate titles** – Each language file has its own `# Title` heading
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

## Getting Help

1. Review storage layer implementation: `lib/phoenix_kit_web/live/modules/blogging/context/storage.ex`
2. Inspect post struct in IEx: `{:ok, post} = Blogging.read_post("docs", "slug")` → `IO.inspect(post)`
3. Enable debug logging: `Logger.configure(level: :debug)`
4. Search GitHub issues: <https://github.com/phoenixkit/phoenix_kit/issues>
