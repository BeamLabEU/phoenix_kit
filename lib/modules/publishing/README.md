# Publishing Module

The PhoenixKit Publishing module provides a filesystem-based content management system with multi-language support and dual storage modes. Posts are stored as `.phk` files (YAML frontmatter + Markdown content) rather than in the database, giving content creators a familiar file-based workflow with version control integration.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/publishing`
- **Public Content**: `/{prefix}/{language}/{group-slug}` (listing) or `/{prefix}/{group-slug}` (single-language)
- **Settings**: Configure via `publishing_public_enabled` and `publishing_posts_per_page` in Settings
- **Enable Module**: Activate via Admin → Modules or run `PhoenixKit.Modules.Publishing.enable_system/0`
- **Cache Settings**: Toggle `publishing_file_cache_enabled`, `publishing_memory_cache_enabled`, and `publishing_render_cache_enabled[_<slug>]`
- **What it ships**: Listing cache, render cache, collaborative editor, public fallback routing, and optional per-post version history

## Public Content Display

The publishing module includes public-facing routes for displaying published posts to site visitors.

### Public URLs

**Multi-language mode:**
```
/{prefix}/{language}/{blog-slug}                  # Blog post listing
/{prefix}/{language}/{blog-slug}/{post-slug}      # Slug mode post
/{prefix}/{language}/{blog-slug}/{post-slug}/v/{version}  # Versioned slug-mode post
/{prefix}/{language}/{blog-slug}/{date}           # Timestamp mode (date-only shortcut)
/{prefix}/{language}/{blog-slug}/{date}/{time}    # Timestamp mode post
```

**Single-language mode** (when only one language is enabled):
```
/{prefix}/{blog-slug}                             # Blog post listing
/{prefix}/{blog-slug}/{post-slug}                 # Slug mode post
/{prefix}/{blog-slug}/{post-slug}/v/{version}     # Versioned slug-mode post
/{prefix}/{blog-slug}/{date}                      # Timestamp mode (date-only shortcut)
/{prefix}/{blog-slug}/{date}/{time}               # Timestamp mode post
```

**Examples** (assuming `{prefix}` is `/phoenix_kit`):
- `/phoenix_kit/en/docs` - Lists all published posts in Docs blog (English)
- `/phoenix_kit/en/docs/getting-started` - Shows specific post (slug mode)
- `/phoenix_kit/en/news/2025-11-02/14:30` - Shows specific post (timestamp mode)
- `/phoenix_kit/en/news/2025-11-02` - Date-only timestamp URL (auto-resolves to the first published time)
- `/phoenix_kit/docs` - Single-language mode listing
- `/phoenix_kit/news/2025-11-02` - Date-only timestamp URL (renders if single post exists, otherwise redirects to the first time slot on that date)

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

The publishing module uses a multi-step detection process to determine if a URL segment is a language code or a blog slug:

**Detection Flow (`detect_language_or_blog`):**
1. **Enabled language** - If the segment matches an enabled language code (e.g., `en`, `fr-CA`), treat as language
2. **Base code mapping** - If it's a 2-letter code that maps to an enabled dialect (e.g., `en` → `en-US`), treat as language
3. **Known language pattern** - If it matches a predefined language code (even if disabled), treat as language
4. **Content-based check** - If content exists for this language in the requested blog, treat as language
5. **Default** - Otherwise, treat as a blog slug and use the default language

**Supported Language Types:**
- **Predefined Languages** - Languages configured in the Languages module (e.g., `en`, `fr`, `es`)
- **Content-Based Languages** - Any `.phk` file in a post directory is treated as a valid language

This allows custom language files like `af.phk` (Afrikaans) or `test.phk` to work correctly even if not predefined in the Languages module. In the **admin interface**, the language switcher shows these with a strikethrough to indicate they're not officially enabled. In the **public blog**, only enabled languages appear in the language switcher, but custom language URLs remain accessible via direct link.

**Single-Language Mode:**
When only one language is enabled, URLs don't require the language segment:
- `/phoenix_kit/docs/getting-started` works the same as `/phoenix_kit/en/docs/getting-started`

### Fallback Behavior

Fallbacks are triggered when posts are missing (`:post_not_found`, `:unpublished`) **and** when a blog
slug is invalid (`:blog_not_found`). Server errors or other reasons still render the standard 404 page.

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
2. Other available languages (alphabetically sorted)

**User Experience:**
- Redirects include a flash message: "The page you requested was not found. Showing closest match."
- Bookmarked URLs continue to work even if specific translations are removed
- Users are never shown a 404 if any published version of the content exists
- Invalid blog slugs fall back to the default blog listing (if one exists) before showing a 404

### Configuration

Enable/disable public blog display and set pagination programmatically:

```elixir
# Enable public blog routes (default: true)
PhoenixKit.Settings.update_setting("publishing_public_enabled", "true")

# Set posts per page in listings (default: 20)
PhoenixKit.Settings.update_setting("publishing_posts_per_page", "20")
```

`publishing_public_enabled` gates the entire `PhoenixKit.Modules.Publishing.Web.Controller` – set it to `"false"` to return a 404 for every public blog route. `publishing_posts_per_page` drives listing pagination.

**Note:** Legacy `blogging_*` settings keys are still supported for backward compatibility. The module checks `publishing_*` keys first, then falls back to `blogging_*`.

**Note:** These settings are currently only configurable via code. There is no admin UI for these options yet; expose them in your app if customers need runtime control.

### Templates

Public blog templates are located in:

- `lib/modules/publishing/web/templates/show.html.heex` - Single post view
- `lib/modules/publishing/web/templates/index.html.heex` - Blog listing

### Admin Integration

When editing a post in the admin interface:

- **View Public** button appears for published posts
- Button links directly to the public URL
- Automatically updates when status changes to "published"

### Caching

PhoenixKit ships two cache layers:

1. **Listing cache** – `PhoenixKit.Modules.Publishing.ListingCache` writes summary JSON to
   `priv/publishing/<group>/.listing_cache.json` (with `priv/blogging/` legacy fallback) and mirrors parsed data into `:persistent_term`
   for sub-microsecond reads. File vs memory caching can be toggled via the
   `publishing_file_cache_enabled` / `publishing_memory_cache_enabled` settings (with legacy `blogging_*` fallback) or from the Publishing
   Settings UI, which also offers regenerate/clear actions per group.
2. **Render cache** – `PhoenixKit.Modules.Publishing.Renderer` stores rendered HTML for published posts in the
   `:publishing_posts` cache (6-hour TTL) with content-hash keys, a global
   `publishing_render_cache_enabled` toggle (with legacy `blogging_render_cache_enabled` fallback), and per-group overrides (`publishing_render_cache_enabled_<slug>`)
   plus UI buttons to clear stats or individual group caches.

Example render cache key: `v1:blog_post:docs:getting-started:en:a1b2c3d4`

Manual cache operations remain available when scripting:

```elixir
alias PhoenixKit.Modules.Publishing.ListingCache

ListingCache.regenerate("my-blog")
ListingCache.invalidate("my-blog")
ListingCache.read("my-blog")
ListingCache.exists?("my-blog")

# Context helpers that wrap ListingCache
PhoenixKit.Modules.Publishing.regenerate_cache("my-blog")
PhoenixKit.Modules.Publishing.invalidate_cache("my-blog")

alias PhoenixKit.Modules.Publishing.Renderer

Renderer.clear_group_cache("my-blog")
Renderer.clear_all_cache()
```

## Architecture Overview

**Core Modules:**

- **PhoenixKit.Modules.Publishing** – Main context module with mode-aware routing
- **PhoenixKit.Modules.Publishing.Storage** – Storage layer with CRUD operations for both modes
- **PhoenixKit.Modules.Publishing.Metadata** – YAML frontmatter parsing and serialization

**Admin Interfaces:**

- **PhoenixKit.Modules.Publishing.Web.Settings** – Admin interface for blog configuration
- **PhoenixKit.Modules.Publishing.Web.Editor** – Markdown editor with autosave and featured images
- **PhoenixKit.Modules.Publishing.Web.Preview** – Live preview for blog posts

**Public Display:**

- **PhoenixKit.Modules.Publishing.Web.Controller** – Public-facing routes for blog listings and posts
- **PhoenixKit.Modules.Publishing.Web.HTML** – HTML helpers and view functions for public blog

**Rendering & Caching:**

- **PhoenixKit.Modules.Publishing.ListingCache** – File + memory listing cache
- **PhoenixKit.Modules.Publishing.Renderer** – Markdown/PHK rendering with content-hash caching

**Collaborative Editing:**

- **PhoenixKit.Modules.Publishing.Presence** – Phoenix.Presence for real-time user tracking
- **PhoenixKit.Modules.Publishing.PresenceHelpers** – Owner/spectator logic helpers
- **PhoenixKit.Modules.Publishing.PubSub** – Real-time change broadcasting

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
created_at: 2025-01-15T09:30:00Z
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
- `featured_image_id` – Optional reference to a featured image asset
- `description` – Optional post description/excerpt for SEO
- `version`, `version_created_at`, `version_created_from` – Managed automatically for versioned posts
- `allow_version_access` – Enables public viewing of historical versions when set to `true`

**Audit Fields (optional):**

- `created_at` – Creation timestamp (for audit purposes)
- `created_by_id` – User ID who created the post
- `created_by_email` – Email of user who created the post
- `updated_by_id` – User ID who last updated the post
- `updated_by_email` – Email of user who last updated the post

**Advanced: PHK Component Format**

In addition to Markdown, `.phk` files can contain PHK components for structured page layouts:

```html
---
slug: landing-page
status: published
published_at: 2025-01-15T09:30:00Z
---

<Hero variant="centered" title="Welcome" />

# Introduction

Regular **Markdown** content can be mixed with components.

<Image src="hero.jpg" alt="Hero image" />

<EntityForm entity="contact" />
```

Supported components: `Image`, `Hero`, `CTA`, `Headline`, `Subheadline`, `Video`, `EntityForm`. The renderer processes these via the PageBuilder system.

## Context Layer API

The main context module (`publishing.ex`) routes operations based on group mode:

## Command-Line / IEx Usage

PhoenixKit exposes the entire publishing system through the `PhoenixKit.Modules.Publishing`
module, so you can manage publishing groups from IEx or any script without touching the UI. This is extremely
useful when seeding sample content, migrating posts, or when an AI assistant has CLI access.

### Bootstrapping a session

```bash
$ iex -S mix
iex> alias PhoenixKit.Modules.Publishing
iex> alias PhoenixKit.Users.Auth.Scope
iex> Publishing.enable_system()
```

- `Publishing` is available anywhere via the alias above.
- `Scope` is optional but lets you stamp `created_by_*` / `updated_by_*` metadata.
- Module settings live in `PhoenixKit.Settings` (with legacy `blogging_settings_module` support).

### Managing publishing groups

```elixir
iex> {:ok, docs} = Publishing.add_group("Documentation", mode: "slug")
iex> Publishing.list_groups()
[%{"name" => "Documentation", "slug" => "documentation", "mode" => "slug"}]
iex> {:ok, group} = Publishing.get_group("documentation")
iex> {:ok, _} = Publishing.update_group("documentation", %{"name" => "Docs"})
iex> Publishing.trash_group("documentation")
{:ok, "trash/documentation-2025-01-15-09-30-00"}
```

- `mode` must be `"slug"` or `"timestamp"` and is immutable after creation.
- Publishing group directories live under `priv/publishing/<group-slug>` (with `priv/blogging` legacy fallback).

### Creating scope-aware posts

```elixir
iex> user = MyApp.Repo.get!(MyApp.Users.User, 123)
iex> scope = Scope.for_user(user)
iex> {:ok, post} = Publishing.create_post("documentation", %{title: "Intro", scope: scope})
iex> {:ok, post} = Publishing.create_post("docs", %{title: "Intro", slug: "getting-started"})
iex> {:ok, post} = Publishing.create_post("news", %{scope: Scope.for_user(nil)})
```

- Slug mode expects a title (auto-slug) or explicit `:slug`.
- Timestamp mode ignores slug and uses current UTC time for the folder.
- `scope` is optional; pass `Scope.for_user(nil)` for system automation.
- Replace `MyApp.*` with your host application's modules/Repo.

### Reading and updating posts

```elixir
iex> {:ok, post} = Publishing.read_post("docs", "getting-started")
iex> {:ok, post_es} = Publishing.read_post("docs", "getting-started", "es")
iex> {:ok, updated} = Publishing.update_post("docs", post, %{"content" => "# v2"}, scope: scope)
```

- Slug-mode identifiers can include versions, e.g. `"getting-started/v2/en.phk"`.
- Timestamp-mode identifiers are `"YYYY-MM-DD/HH:MM"` paths.
- `update_post/4` automatically moves files when slugs or timestamps change.

### Versioning and translations

```elixir
iex> {:ok, draft_v2} = Publishing.create_version_from("docs", "getting-started", 1, %{"content" => "..."})
iex> :ok = Publishing.publish_version("docs", "getting-started", 2)
iex> {:ok, spanish} = Publishing.add_language_to_post("docs", "getting-started", "es")
iex> :ok = Publishing.delete_language("docs", "getting-started", "fr")
iex> :ok = Publishing.delete_version("docs", "getting-started", 1)
```

- `create_version_from/5` creates a new version by copying from source (or blank if `nil`); publish with `publish_version/3`.
- Languages live beside each other (`en.phk`, `es.phk`, etc.) and share cache + slug metadata.

### Filesystem + cache helpers

```elixir
iex> posts = Publishing.list_posts("docs")
iex> :ok = Publishing.regenerate_cache("docs")
iex> {:ok, cached} = Publishing.find_cached_post("docs", "getting-started")
iex> {:ok, trash_path} = Publishing.trash_post("docs", "getting-started")
```

- `.listing_cache.json` sits inside each blog directory; cache helpers wrap direct JSON access.
- All destructive helpers move content into `priv/publishing/trash/...` (or `priv/blogging/trash/...` for legacy groups) so you can restore manually.

### Group Management

```elixir
# Create group with storage mode
{:ok, group} = Publishing.add_group("Documentation", mode: "slug")
{:ok, group} = Publishing.add_group("Company News", mode: "timestamp")

# With custom slug
{:ok, group} = Publishing.add_group("My API Docs", mode: "slug", slug: "api-docs")

# List all groups (includes mode field)
groups = Publishing.list_groups()
# => [%{"name" => "Docs", "slug" => "docs", "mode" => "slug"}, ...]

# Get group storage mode
mode = Publishing.get_group_mode("docs")  # => "slug"

# Update group name/slug
{:ok, group} = Publishing.update_group("docs", %{"name" => "New Name", "slug" => "new-docs"})

# Remove group from list (keeps files)
{:ok, _} = Publishing.remove_group("docs")

# Move group to trash (renames directory with timestamp)
{:ok, trash_path} = Publishing.trash_group("docs")

# Get group name from slug
name = Publishing.group_name("docs")  # => "Documentation"

# Slug utilities
slug = Publishing.slugify("My Blog Post!")  # => "my-blog-post"
Publishing.valid_slug?("my-slug")  # => true
Publishing.valid_slug?("en")       # => false (reserved language code)

# Slug validation with error reason
{:ok, "hello-world"} = Publishing.validate_slug("hello-world")
{:error, :invalid_format} = Publishing.validate_slug("Hello World")
{:error, :reserved_language_code} = Publishing.validate_slug("en")

# Check if slug exists and generate unique slugs
Publishing.slug_exists?("docs", "getting-started")  # => true/false
{:ok, slug} = Publishing.generate_unique_slug("docs", "Getting Started")
# => {:ok, "getting-started"} or {:ok, "getting-started-1"} if exists

# Language utilities
Publishing.enabled_language_codes()  # => ["en", "es", "fr"]
Publishing.get_primary_language()    # => "en"
Publishing.language_enabled?("en", ["en-US", "es"])  # => true
Publishing.get_display_code("en", ["en-US", "es"])   # => "en-US"
Publishing.order_languages_for_display(["fr", "en"], ["en", "es"])
# => ["en", "fr"] (enabled first, then others)

# Language info
info = Publishing.get_language_info("en")
# => %{code: "en", name: "English", flag: "🇺🇸"}
```

### Post Operations

The context layer automatically routes to the correct storage implementation:

```elixir
# Create post (routes by blog mode)
{:ok, post} = Publishing.create_post("docs", %{title: "Hello World"})
# Slug mode: auto-generates slug "hello-world"
# Timestamp mode: uses current date/time

# Create post with explicit slug and audit trail (slug mode only)
{:ok, post} = Publishing.create_post("docs", %{
  title: "Getting Started",
  slug: "get-started",
  scope: current_user_scope  # Optional: records created_by_id/email
})

# List posts (routes by blog mode)
posts = Publishing.list_posts("docs")
posts = Publishing.list_posts("docs", "es")  # With language preference

# Read post (routes by blog mode)
{:ok, post} = Publishing.read_post("docs", "getting-started")
{:ok, post} = Publishing.read_post("docs", "getting-started", "es")

# Update post (routes by post.mode field)
{:ok, updated} = Publishing.update_post("docs", post, %{
  "title" => "Updated Title",
  "slug" => "new-slug",  # Slug mode: moves files
  "content" => "Updated content..."
}, scope: current_user_scope)  # Optional 4th arg: records updated_by_id/email

# Add translation
{:ok, spanish_post} = Publishing.add_language_to_post("docs", "getting-started", "es")
```

### Delete Operations

All delete operations move content to a trash folder rather than permanent deletion:

```elixir
# Move post to trash (all versions and languages)
{:ok, trash_path} = Publishing.trash_post("docs", "getting-started")
# => {:ok, "trash/docs/getting-started-2025-01-02-14-30-00"}

# For timestamp mode, use the date/time path
{:ok, trash_path} = Publishing.trash_post("news", "2025-01-15/14:30")

# Delete a specific translation (refuses if last language)
:ok = Publishing.delete_language("docs", "getting-started", "es")
:ok = Publishing.delete_language("docs", "getting-started", "es", 2)  # specific version
{:error, :cannot_delete_last_language} = Publishing.delete_language("docs", "post", "en")

# Delete a version (moves to trash, refuses if live or last version)
:ok = Publishing.delete_version("docs", "getting-started", 1)
{:error, :cannot_delete_live_version} = Publishing.delete_version("docs", "post", 2)
{:error, :cannot_delete_last_version} = Publishing.delete_version("docs", "post", 1)
```

### Versioning Operations

```elixir
# List all versions of a post
versions = Publishing.list_versions("docs", "getting-started")
# => [1, 2, 3]

# Get specific version info
{:ok, 3} = Publishing.get_latest_version("docs", "getting-started")
{:ok, 2} = Publishing.get_published_version("docs", "getting-started")

# Get version metadata
{:ok, metadata} = Publishing.get_version_metadata("docs", "getting-started", 1, "en")

# Create new version from existing post
# Create a new version from an existing version (branching)
{:ok, new_post} = Publishing.create_version_from("docs", "getting-started", 1, %{
  "content" => "Updated content..."
}, scope: current_user_scope)

# Create a blank new version
{:ok, new_post} = Publishing.create_version_from("docs", "getting-started", nil, %{},
  scope: current_user_scope)

# For timestamp mode, use the date/time path as identifier
{:ok, new_post} = Publishing.create_version_from("news", "2025-01-15/14:30", 1, %{},
  scope: current_user_scope)

# Publish a version (archives all other published versions)
:ok = Publishing.publish_version("docs", "getting-started", 2)

# Get the currently published version
{:ok, version} = Publishing.get_published_version("docs", "getting-started")

# Check version structure and migration
:versioned = Publishing.detect_post_structure("/path/to/post")
{:ok, post} = Publishing.migrate_post_to_versioned(legacy_post)

# Helpers for version logic
Publishing.content_changed?(post, params)  # => true/false
Publishing.status_change_only?(post, params)  # => true/false
```

### Variant Versioning System

Both slug-mode and timestamp-mode posts support **variant versioning** - versions are independent
attempts or drafts rather than sequential history. Only ONE version can be published at a time.

**Key Concepts:**

- **Radio-style publishing**: When you publish a version, all other published versions are
  automatically archived. Only the newly published version is visible to the public.
- **Versions are editable**: Unlike historical versioning, all versions remain editable regardless
  of status. You can modify drafts, archived versions, or even the published version.
- **Branching**: Create new versions by copying from an existing version or starting blank.
- **Translation inheritance**: When publishing, all translations inherit the primary language's status.

**Creating New Versions:**

1. Open any post in the editor
2. Click the **"New Version"** button next to the version switcher
3. Choose to copy from an existing version or start blank
4. The new version is created as a draft

**Publishing a Version:**

1. Open the version you want to publish
2. Change status to "Published" and save
3. All other published versions are automatically archived
4. The public URL now shows this version's content

**Version Statuses:**

- `published` - The live version visible to the public (only ONE per post)
- `draft` - Work in progress, not visible publicly
- `archived` - Previously published or intentionally hidden versions

**Editor UI:**

The editor provides a complete version management interface:

- **Version Switcher** - Dropdown showing all versions with status indicators (green=published, yellow=draft, gray=archived)
- **New Version Button** - Opens a modal to create a new version
- **New Version Modal** - Choose to start blank or copy from any existing version
- **Status Dropdown** - Change status directly in the metadata panel

**Translation Status Inheritance:**

Translations always follow the primary language's status:

- When the primary language status changes, all translations are updated to match
- Users can temporarily change a translation's status (e.g., set to "draft" while reviewing)
- However, the next primary status change will reset all translations to match
- Translations can only be changed to "draft" or "archived" if the primary is already published

Example workflow:
1. Primary (English) is published with v2 → all translations become "published"
2. French translation has an issue, translator sets it to "draft" temporarily
3. When English v3 is published, French becomes "published" again (along with all translations)

**Public URLs:**

Public URLs always show the published version's content:
- `/{prefix}/{language}/{group}/{post}` - Shows the published version

**Version Browsing (Opt-in):**

By default, only the published version is accessible. To enable public access to older
published versions, set `allow_version_access: true` in the post's metadata:

```yaml
allow_version_access: true
```

When enabled, versioned URLs become accessible:
- `/{prefix}/{language}/{group}/{post}/v/{version}` - Direct version access

The version dropdown appears on the public post page, showing all published versions.
This is useful for documentation sites where users may need to reference older versions.

### Cache Operations

```elixir
# Regenerate listing cache (called automatically on post changes)
:ok = Publishing.regenerate_cache("docs")

# Invalidate (delete) cache
:ok = Publishing.invalidate_cache("docs")

# Check if cache exists
Publishing.cache_exists?("docs")  # => true/false

# Fast post lookup from cache (O(1) instead of filesystem scan)
{:ok, post_data} = Publishing.find_cached_post("docs", "getting-started")
{:ok, post_data} = Publishing.find_cached_post_by_path("news", "2025-01-15", "14:30")
```

## Storage Layer Implementation

The storage layer (`storage.ex`) provides separate implementations for each mode:

### Slug Mode Functions

```elixir
# Validation (returns boolean)
Storage.valid_slug?("hello-world")  # => true
Storage.valid_slug?("Hello World")  # => false

# Validation with error reason
{:ok, "hello-world"} = Storage.validate_slug("hello-world")
{:error, :invalid_format} = Storage.validate_slug("Hello World")
{:error, :reserved_language_code} = Storage.validate_slug("en")

# Check if slug exists in blog
Storage.slug_exists?("docs", "getting-started")  # => true/false

# Collision-free slug generation
{:ok, slug} = Storage.generate_unique_slug("docs", "Getting Started")
# => {:ok, "getting-started"}
# If exists: {:ok, "getting-started-1"}, etc.

# CRUD operations
{:ok, post} = Storage.create_post_slug_mode("docs", "Hello", "hello")
{:ok, post} = Storage.create_post_slug_mode("docs", "Hello", "hello", %{
  created_by_id: user.id,
  created_by_email: user.email
})
{:ok, post} = Storage.read_post_slug_mode("docs", "hello", "en")
posts = Storage.list_posts_slug_mode("docs", "en")
{:ok, post} = Storage.update_post_slug_mode("docs", post, params)

# Move post to new slug (all languages)
{:ok, post} = Storage.move_post_to_new_slug("docs", post, "new-slug", params)
{:ok, post} = Storage.move_post_to_new_slug("docs", post, "new-slug", params, %{
  updated_by_id: user.id,
  updated_by_email: user.email
})

# Add translation to existing post
{:ok, spanish_post} = Storage.add_language_to_post_slug_mode("docs", "getting-started", "es")
```

### Timestamp Mode Functions

```elixir
# CRUD operations (legacy, still supported)
{:ok, post} = Storage.create_post("news")
{:ok, post} = Storage.read_post("news", "news/2025-01-15/09:30/en.phk")
posts = Storage.list_posts("news", "en")
{:ok, post} = Storage.update_post("news", post, params)

# Add translation to existing post
{:ok, spanish_post} = Storage.add_language_to_post("news", "news/2025-01-15/09:30", "es")

# Date-based queries
count = Storage.count_posts_on_date("news", ~D[2025-01-15])
times = Storage.list_times_on_date("news", ~D[2025-01-15])
# => ["09:30", "14:00", ...]
```

### Utility Functions

```elixir
# File system paths
Storage.root_path()  # => "/path/to/app/priv/publishing" (or priv/blogging for legacy)
Storage.absolute_path("docs/getting-started/en.phk")

# Blog directory management
Storage.ensure_blog_root("docs")  # Creates directory if needed
Storage.rename_blog_directory("old-slug", "new-slug")
Storage.move_blog_to_trash("docs")  # Renames with timestamp

# Post/version/language deletion (moves to trash)
{:ok, path} = Storage.trash_post("docs", "getting-started")
:ok = Storage.delete_language("docs", "getting-started", "es", 1)
:ok = Storage.delete_version("docs", "getting-started", 1)

# Language helpers
Storage.language_filename()        # => "en.phk" (based on content language setting)
Storage.language_filename("es")    # => "es.phk"
Storage.enabled_language_codes()   # => ["en", "es", "fr"]
Storage.get_language_info("en")    # => %{code: "en", name: "English", flag: "🇺🇸"}
Storage.language_enabled?("en", ["en-US", "es"])  # => true (base code match)

# Language display helpers (for UI)
Storage.get_display_code("en-US", ["en-US", "es"])  # => "en-US"
Storage.get_display_code("en", ["en-US", "es"])     # => "en-US" (maps to enabled dialect)
Storage.order_languages_for_display(["fr", "en", "es"], ["en", "es"])
# => ["en", "es", "fr"] (enabled first, then others alphabetically)
```

## LiveView Interfaces

### Settings (`settings.ex`)

Blog configuration interface at `{prefix}/admin/settings/publishing`:

- Create new blogs with mode selector
- View existing blogs with mode badges
- Delete blogs
- Configure public display settings

**Blog Creation (New Blog Form):**
- Mode selector: Radio buttons (Timestamp / Slug)
- Warning text: "Cannot be changed after blog creation"
- Mode is locked permanently after creation

### Editor (`editor.ex`)

Markdown editor at `{prefix}/admin/publishing/{blog}/edit`:

- Title input (all modes)
- **Slug input** (slug mode only, with validation)
- Status selector (draft/published/archived)
- Published at timestamp picker
- Featured image selector (integrates with Media module)
- Markdown editor with preview
- Language switcher for translations

**Autosave:**

The editor automatically saves changes after 2 seconds of inactivity:
- Debounced saves prevent excessive writes
- Status indicator shows: "Saving...", "Saved", or error state
- Dirty detection tracks unsaved changes
- Navigation warnings when leaving with unsaved changes

**Featured Images:**

Posts can have an optional featured image:
- Click "Select Featured Image" to open the media picker
- Preview displays below the image selector
- Click "Clear" to remove the featured image
- Stored as `featured_image_id` in frontmatter

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
- **Reserved slugs**: Any language code from the Languages module cannot be used as a slug to prevent routing ambiguity
- Shows validation error for invalid slugs
- Path preview: `blog/post-slug/en.phk`

### Preview (`preview.ex`)

Live preview at `{prefix}/admin/publishing/{blog}/preview`:

- Renders Markdown content with Phoenix.Component
- Shows metadata preview (title, status, published date)
- Language switcher for viewing translations

### Collaborative Editing

The editor uses Phoenix.Presence to coordinate multiple users editing the same post.

**Owner/Spectator Model:**

1. First user to open a post becomes the **owner** (full edit access)
2. Subsequent users become **spectators** (read-only mode)
3. When the owner leaves, the next spectator auto-promotes to owner
4. All users see who else is viewing the post in real-time

**How It Works:**

- Users join a Presence topic (e.g., `blog_edit:group-slug:post-slug`)
- Users sorted by `joined_at` timestamp (FIFO ordering)
- First user in sorted list = owner (`readonly?: false`)
- All other users = spectators (`readonly?: true`)
- Phoenix.Presence auto-cleans disconnected users

**UI Indicators:**

- Spectator mode shows a banner: "Another user is currently editing this post"
- Users see avatars/names of other connected editors
- Read-only mode disables form inputs and save button

**Files:**

- `presence.ex` – Phoenix.Presence configuration
- `presence_helpers.ex` – Helper functions for owner/spectator logic
- `editor.ex` – Presence integration in the editor LiveView

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
  group: "docs",                    # Publishing group slug
  slug: "getting-started",          # Slug mode only
  date: ~D[2025-01-15],             # Timestamp mode only
  time: ~T[09:30:00],               # Timestamp mode only
  path: "docs/getting-started/v1/en.phk",
  full_path: "/var/app/content/docs/getting-started/v1/en.phk",
  metadata: %{
    title: "Getting Started",
    status: "published",            # "published", "draft", or "archived"
    slug: "getting-started",
    published_at: "2025-01-15T09:30:00Z",
    created_at: "2025-01-15T09:30:00Z",
    version: 1,
    version_created_at: "2025-01-15T09:30:00Z",
    version_created_from: nil       # Source version when branching
  },
  content: "# Markdown content...",
  language: "en",
  available_languages: ["en", "es", "fr"],
  language_statuses: %{"en" => "published", "es" => "draft", "fr" => "published"},
  mode: :slug,                      # :slug or :timestamp
  version: 1,                       # Current version number
  available_versions: [1, 2, 3],    # All versions for this post
  version_statuses: %{1 => "archived", 2 => "archived", 3 => "published"},
  is_legacy_structure: false        # True for pre-versioned posts
}
```

**Note on `language_statuses`:** This field is preloaded when posts are fetched via `list_posts` or `read_post` to avoid redundant file reads. It maps each available language code to its publication status.

## AI Translation

The Publishing module integrates with the AI module to provide automated translation of posts to multiple languages using an Oban background job.

### Prerequisites

1. **AI Module Enabled**: The AI module must be enabled (`PhoenixKit.Modules.AI.enable_system()`)
2. **AI Endpoint Configured**: At least one AI endpoint must be configured with a capable model
3. **Languages Enabled**: The Languages module should have multiple languages enabled

### Editor UI

When prerequisites are met, a collapsible **AI Translation** panel appears in the post editor (for primary language posts only):

1. Open any post in the primary language
2. Expand the "AI Translation" section (marked with Beta badge)
3. Select an AI endpoint from the dropdown
4. Click one of the translation buttons:
   - **Translate All Languages** - Translates to ALL enabled languages
   - **Translate Missing Only** - Only translates languages that don't have a translation file yet

The translation runs as a background job. Progress can be monitored in the Oban dashboard or via logs.

### Quick Start (Programmatic)

```elixir
# Translate a post to all enabled languages
{:ok, job} = Publishing.translate_post_to_all_languages("docs", "getting-started",
  endpoint_id: 1
)

# Translate to specific languages only
{:ok, job} = Publishing.translate_post_to_all_languages("docs", "getting-started",
  endpoint_id: 1,
  target_languages: ["es", "fr", "de"]
)

# Translate a specific version
{:ok, job} = Publishing.translate_post_to_all_languages("docs", "getting-started",
  endpoint_id: 1,
  version: 2
)
```

### Configuration

Set a default AI endpoint for translations (optional):

```elixir
PhoenixKit.Settings.update_setting("publishing_translation_endpoint_id", "1")
```

With a default endpoint configured, you can omit the `endpoint_id` option:

```elixir
{:ok, job} = Publishing.translate_post_to_all_languages("docs", "getting-started")
```

### How It Works

1. **Job Enqueued**: An Oban job is created in the `:default` queue
2. **Source Read**: The primary language content is read from the specified post
3. **AI Translation**: For each target language, the content is sent to the AI with a translation prompt
4. **Files Created**: Translation files are created or updated (e.g., `es.phk`, `fr.phk`)
5. **Cache Updated**: The listing cache is regenerated to include new translations

### Translation Features

**Format Preservation:**
- The AI preserves the EXACT formatting of the original content
- If the original has `# headings`, translations keep them; if not, they don't add them
- All Markdown formatting is preserved (bold, italic, lists, code blocks, links)
- Line breaks and spacing are maintained
- Code blocks and inline code are NOT translated

**URL Slug Translation:**
- The AI generates a localized URL slug for each translation
- Example: `getting-started` → `primeros-pasos` (Spanish)
- Slugs are automatically sanitized (lowercase, hyphens, no special characters)
- See [Per-Language URL Slugs](#per-language-url-slugs) for more details

**Title Extraction:**
- The AI extracts and translates the title separately
- Title is stored in metadata for listings and SEO
- Original document structure is preserved

### Translation Prompt

The worker uses a built-in translation prompt that instructs the AI to:
- Preserve exact formatting (headings, spacing, structure)
- Keep Markdown syntax intact
- Not translate code blocks or inline code
- Translate naturally and idiomatically
- Generate SEO-friendly URL slugs in the target language

### Options

| Option | Type | Description |
|--------|------|-------------|
| `endpoint_id` | integer | AI endpoint ID (required if not set in settings) |
| `source_language` | string | Source language code (defaults to primary language) |
| `target_languages` | list | Target language codes (defaults to all enabled except source) |
| `version` | integer | Version number to translate (defaults to latest) |
| `user_id` | integer | User ID for audit trail |

### Job Monitoring

Translation jobs can be monitored via:
- **Oban Dashboard**: View job status, retries, and errors
- **Jobs Module**: Enable at `/{prefix}/admin/modules` → Jobs
- **Logs**: Jobs log progress and errors with `[TranslatePostWorker]` prefix

Example log output:
```
[TranslatePostWorker] Starting translation of docs/getting-started from en to 5 languages
[TranslatePostWorker] Translating to es (Spanish)...
[TranslatePostWorker] AI call for es completed in 2341ms
[TranslatePostWorker] Got translated slug for es: primeros-pasos
[TranslatePostWorker] Creating new es translation
[TranslatePostWorker] Successfully translated to es
...
[TranslatePostWorker] Completed: 5 succeeded, 0 failed
```

### Error Handling

- **Partial Failures**: If some languages fail, the job reports which languages succeeded and which failed
- **Retries**: Jobs retry up to 3 times with exponential backoff
- **Timeout**: Jobs have a 10-minute timeout for large posts or many languages
- **Language Fallback Protection**: The worker verifies each translation is saved to the correct language file (prevents overwriting primary)

### Programmatic Usage

```elixir
alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

# Create a job without inserting
job = TranslatePostWorker.create_job("docs", "getting-started", endpoint_id: 1)

# Insert the job
{:ok, oban_job} = Oban.insert(job)

# Or use the convenience function
{:ok, oban_job} = TranslatePostWorker.enqueue("docs", "getting-started", endpoint_id: 1)

# Translate only missing languages
missing_langs = ["de", "ja", "zh"]  # Languages without translation files
{:ok, job} = TranslatePostWorker.enqueue("docs", "getting-started",
  endpoint_id: 1,
  target_languages: missing_langs
)
```

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

1. Navigate to `{prefix}/admin/publishing/settings`
2. Enter blog name: "Documentation"
3. Select mode: **Slug** or **Timestamp**
4. Click "Add Blog"
5. Mode is now permanently locked for this blog

## Test Coverage

**Status:** Tests not yet implemented

The publishing module is tested through integration testing in parent Phoenix applications rather than unit tests within PhoenixKit itself. This is consistent with PhoenixKit's library-first architecture (see CLAUDE.md for testing philosophy).

**Recommended Testing Approach:**

1. **Integration Testing** - Test publishing functionality in your parent Phoenix application
2. **Manual Testing** - Use the admin interface at `/{prefix}/admin/publishing`
3. **Static Analysis** - Run `mix credo --strict` and `mix dialyzer` to catch logic errors

**Future Test Implementation:**

When publishing tests are added, they will use an in-memory settings stub to avoid database dependencies:

```elixir
# config/test.exs
config :phoenix_kit,
  publishing_settings_module: PhoenixKit.Test.FakeSettings
```

**Running Tests:**

```bash
# Run all publishing tests (when implemented)
mix test test/modules/publishing/
```

## Configuration

Publishing module uses PhoenixKit Settings for configuration:

```elixir
# Enable/disable publishing system
Publishing.enable_system()
Publishing.disable_system()
Publishing.enabled?()  # => true/false

# Publishing groups stored as JSON setting
# Key: "publishing_groups" (with legacy "blogging_blogs" fallback)
# Value: %{"blogs" => [%{"name" => "...", "slug" => "...", "mode" => "...", "type" => "..."}]}

# Cache toggles (with legacy blogging_* fallback)
PhoenixKit.Settings.update_setting("publishing_file_cache_enabled", "true")
PhoenixKit.Settings.update_setting("publishing_memory_cache_enabled", "true")

# Render cache (global + per group, with legacy fallback)
PhoenixKit.Settings.update_setting("publishing_render_cache_enabled", "true")
PhoenixKit.Settings.update_setting("publishing_render_cache_enabled_docs", "false")

# Custom settings backend (optional, with legacy blogging_settings_module fallback)
config :phoenix_kit, publishing_settings_module: MyApp.CustomSettings
```

### Storage Path

Content is stored in the filesystem under:

```
priv/publishing/
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

Default: `priv/publishing` (with automatic fallback to `priv/blogging` for existing content)

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

Use only lowercase letters, numbers, and hyphens. Avoid language codes:

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
"en"              # Reserved language code
"fr"              # Reserved language code
```

---

### Problem: Slug is a reserved language code

**Symptoms:**
```
Slug cannot be a reserved language code
```

**Root Cause:**

The slug matches a language code defined in the Languages module (e.g., `en`, `es`, `fr-CA`).

**Solution:**

Choose a different slug. Language codes are reserved to prevent URL routing ambiguity between `/{prefix}/en/blog` (language + blog) and a post with slug `en`.

---

### Problem: Slug already exists

**Symptoms:**
```
A post with this slug already exists
```

**Root Cause:**

Another post in the same blog already uses this slug.

**Solution:**

Choose a unique slug or append a number (e.g., `my-post-2`). The auto-slug generator handles this automatically when creating new posts.

---

### Problem: Editor is in read-only mode

**Symptoms:**

Form inputs are disabled and a banner says "Another user is currently editing this post".

**Root Cause:**

Another user opened the editor first and is the current "owner". The collaborative editing system only allows one person to edit at a time.

**Solution:**

Wait for the other user to leave, or coordinate with them. When they close the editor, you'll automatically become the owner and gain edit access.

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
Publishing.read_post("docs", "old-slug")

# After slug change (from "old-slug" to "new-slug")
Publishing.read_post("docs", "new-slug")  # ✅ Works
Publishing.read_post("docs", "old-slug")  # ❌ Not found
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

### Problem: Cannot delete the last language

**Symptoms:**
```
{:error, :cannot_delete_last_language}
```

**Root Cause:**

Every post must have at least one language file. You cannot delete the only remaining translation.

**Solution:**

Either add another translation first, or trash the entire post:

```elixir
# Add another language first
{:ok, _} = Publishing.add_language_to_post("docs", "post", "es")
# Then delete the unwanted one
:ok = Publishing.delete_language("docs", "post", "en")

# Or trash the entire post
{:ok, _} = Publishing.trash_post("docs", "post")
```

---

### Problem: Cannot delete the live version

**Symptoms:**
```
{:error, :cannot_delete_live_version}
```

**Root Cause:**

The version you're trying to delete is currently the live (public-facing) version.

**Solution:**

Publish a different version first:

```elixir
# Publish another version (this archives the current published version)
:ok = Publishing.publish_version("docs", "post", 2)
# Now delete the old version
:ok = Publishing.delete_version("docs", "post", 1)
```

---

### Problem: Cannot delete the last version

**Symptoms:**
```
{:error, :cannot_delete_last_version}
```

**Root Cause:**

Every post must have at least one version. You cannot delete the only remaining version.

**Solution:**

Either create a new version first, or trash the entire post:

```elixir
# Trash the entire post instead
{:ok, _} = Publishing.trash_post("docs", "post")
```

## Per-Language URL Slugs

Each language translation can have its own SEO-friendly URL slug, enabling localized URLs for better search engine optimization and user experience.

**Example:**
```
# Each language has its own URL slug
/en/docs/getting-started   →  docs/getting-started/en.phk  (url_slug: "getting-started")
/es/docs/primeros-pasos    →  docs/getting-started/es.phk  (url_slug: "primeros-pasos")
/fr/docs/prise-en-main     →  docs/getting-started/fr.phk  (url_slug: "prise-en-main")
```

**Key Concepts:**

1. **Directory = Internal Identifier** - The post directory name (e.g., `getting-started/`) is the internal ID that ties all translations together. This never changes.

2. **url_slug = Public URL** - Each translation's `.phk` file can specify its own `url_slug` in frontmatter for the public-facing URL.

3. **Backward Compatible** - If no `url_slug` is set, the directory name is used (existing behavior).

### Setting Up Per-Language Slugs

**In the Editor:**

1. Open a translation (non-primary language) in the editor
2. Find the "URL Slug" field in the metadata panel (only visible for translations)
3. Enter a localized slug (e.g., `primeros-pasos` for Spanish)
4. Save - the URL immediately updates

**In Frontmatter:**

```yaml
---
slug: getting-started
status: published
published_at: 2025-01-15T09:30:00Z
url_slug: primeros-pasos
---

# Primeros Pasos

Contenido en español...
```

**Auto-Generation:**

When creating or editing a translation, the URL slug is automatically generated from the content title (first `# Heading`). You can override this by manually typing in the URL Slug field.

### URL Slug Validation

URL slugs are validated before saving:

| Rule | Example | Error |
|------|---------|-------|
| Lowercase, numbers, hyphens only | `Hello-World` | Invalid format |
| Cannot be a language code | `en`, `es`, `fr-CA` | Reserved language code |
| Cannot be a reserved route | `admin`, `api`, `assets` | Reserved route word |
| Must be unique per language | Duplicate in same group+language | Already in use |

**Reserved Route Words:** `admin`, `api`, `assets`, `phoenix_kit`, `auth`, `login`, `logout`, `register`, `settings`

### 301 Redirects for Changed Slugs

When you change a URL slug, the old slug is automatically stored in `previous_url_slugs` for 301 redirects:

```yaml
---
url_slug: nuevo-slug
previous_url_slugs: antiguo-slug,otro-slug-viejo
---
```

**Redirect Behavior:**
- Old URLs automatically 301 redirect to the new URL
- Multiple previous slugs are supported (comma-separated)
- Works even on cold starts (no cache) via filesystem fallback

**Example:**
```
# User changed Spanish slug from "empezando" to "primeros-pasos"
GET /es/docs/empezando
→ 301 Redirect to /es/docs/primeros-pasos
```

### Language Switcher Integration

The language switcher automatically shows localized URLs for each language:

```html
<!-- Language switcher shows different URLs per language -->
<a href="/en/docs/getting-started">English</a>
<a href="/es/docs/primeros-pasos">Español</a>
<a href="/fr/docs/prise-en-main">Français</a>
```

### Cache Structure

The listing cache stores per-language slug mappings for O(1) lookups:

```json
{
  "slug": "getting-started",
  "language_slugs": {
    "en": "getting-started",
    "es": "primeros-pasos",
    "fr": "prise-en-main"
  },
  "language_previous_slugs": {
    "es": ["empezando", "comenzar"],
    "fr": ["demarrage"]
  }
}
```

### Programmatic API

```elixir
# Find post by URL slug (any language)
{:ok, post} = ListingCache.find_by_url_slug("docs", "es", "primeros-pasos")
# => Returns post with slug: "getting-started"

# Find post by previous URL slug (for redirects)
{:ok, post} = ListingCache.find_by_previous_url_slug("docs", "es", "empezando")
# => Returns post so you can build redirect URL

# Validate URL slug before saving
{:ok, "primeros-pasos"} = Storage.validate_url_slug("docs", "primeros-pasos", "es", "getting-started")
{:error, :slug_already_exists} = Storage.validate_url_slug("docs", "existing-slug", "es", nil)
```

### Filesystem Fallback

On cold starts (no cache), the system scans the filesystem to resolve URL slugs:

1. Scans all post directories in the group
2. Reads each language file's metadata
3. Checks both `url_slug` and `previous_url_slugs`
4. Returns redirect for previous slugs, resolution for current slugs

This ensures localized URLs work immediately after deployment without waiting for cache warm-up.

### SEO Benefits

- **Localized URLs**: Search engines prefer URLs in the user's language
- **Better Click-Through**: Users are more likely to click localized URLs in search results
- **Proper Hreflang**: The `<link rel="alternate" hreflang="xx">` tags use language-specific URLs
- **Canonical URLs**: Each translation has its own canonical URL with its localized slug

## Getting Help

1. Review storage layer implementation: `lib/modules/publishing/storage.ex`
2. Inspect post struct in IEx: `{:ok, post} = Publishing.read_post("docs", "slug")` → `IO.inspect(post)`
3. Enable debug logging: `Logger.configure(level: :debug)`
4. Search GitHub issues: <https://github.com/phoenixkit/phoenix_kit/issues>
