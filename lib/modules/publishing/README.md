# Publishing Module

The PhoenixKit Publishing module provides a database-backed content management system with multi-language support and dual URL modes (slug-based or timestamp-based). Posts are stored in PostgreSQL via four normalized tables (`publishing_groups`, `publishing_posts`, `publishing_versions`, `publishing_contents`) with UUIDv7 primary keys. A legacy filesystem reader remains for backward compatibility during migration from the older `.phk` file format.

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
/{prefix}/{language}/{group-slug}                  # Group post listing
/{prefix}/{language}/{group-slug}/{post-slug}      # Slug mode post
/{prefix}/{language}/{group-slug}/{post-slug}/v/{version}  # Versioned slug-mode post
/{prefix}/{language}/{group-slug}/{date}           # Timestamp mode (date-only shortcut)
/{prefix}/{language}/{group-slug}/{date}/{time}    # Timestamp mode post
```

**Single-language mode** (when only one language is enabled):
```
/{prefix}/{group-slug}                             # Group post listing
/{prefix}/{group-slug}/{post-slug}                 # Slug mode post
/{prefix}/{group-slug}/{post-slug}/v/{version}     # Versioned slug-mode post
/{prefix}/{group-slug}/{date}                      # Timestamp mode (date-only shortcut)
/{prefix}/{group-slug}/{date}/{time}               # Timestamp mode post
```

**Examples** (assuming `{prefix}` is `/phoenix_kit`):
- `/phoenix_kit/en/docs` - Lists all published posts in the Docs group (English)
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

The publishing module uses a multi-step detection process to determine if a URL segment is a language code or a group slug:

**Detection Flow (`detect_language_or_group`):**
1. **Enabled language** - If the segment matches an enabled language code (e.g., `en`, `fr-CA`), treat as language
2. **Base code mapping** - If it's a 2-letter code that maps to an enabled dialect (e.g., `en` → `en-US`), treat as language
3. **Known language pattern** - If it matches a predefined language code (even if disabled), treat as language
4. **Content-based check** - If content exists for this language in the requested group, treat as language
5. **Default** - Otherwise, treat as a group slug and use the default language

**Supported Language Types:**
- **Predefined Languages** - Languages configured in the Languages module (e.g., `en`, `fr`, `es`)
- **Content-Based Languages** - Any `.phk` file in a post directory is treated as a valid language

This allows custom language files like `af.phk` (Afrikaans) or `test.phk` to work correctly even if not predefined in the Languages module. In the **admin interface**, the language switcher shows these with a strikethrough to indicate they're not officially enabled. In the **public display**, only enabled languages appear in the language switcher, but custom language URLs remain accessible via direct link.

**Single-Language Mode:**
When only one language is enabled, URLs don't require the language segment:
- `/phoenix_kit/docs/getting-started` works the same as `/phoenix_kit/en/docs/getting-started`

### Fallback Behavior

Fallbacks are triggered when posts are missing (`:post_not_found`, `:unpublished`) **and** when a group
slug is invalid (`:group_not_found`). Server errors or other reasons still render the standard 404 page.

**For slug-mode posts (`/{prefix}/en/docs/getting-started`):**
1. Try other languages for the same post (default language first)
2. If no published language versions exist, redirect to group listing

**For timestamp-mode posts (`/{prefix}/en/news/2025-12-24/15:30`):**
1. Try other languages for the same date/time
2. Try other times on the same date
3. If no posts on that date, redirect to group listing

**Fallback Priority:**
The system tries languages in this order:
1. Default language (from Settings)
2. Other available languages (alphabetically sorted)

**User Experience:**
- Redirects include a flash message: "The page you requested was not found. Showing closest match."
- Bookmarked URLs continue to work even if specific translations are removed
- Users are never shown a 404 if any published version of the content exists
- Invalid group slugs fall back to the default group listing (if one exists) before showing a 404

### Configuration

Enable/disable public content display and set pagination programmatically:

```elixir
# Enable public content routes (default: true)
PhoenixKit.Settings.update_setting("publishing_public_enabled", "true")

# Set posts per page in listings (default: 20)
PhoenixKit.Settings.update_setting("publishing_posts_per_page", "20")
```

`publishing_public_enabled` gates the entire `PhoenixKit.Modules.Publishing.Web.Controller` – set it to `"false"` to return a 404 for every public content route. `publishing_posts_per_page` drives listing pagination.

**Note:** Legacy `blogging_*` settings keys are still supported for backward compatibility. The module checks `publishing_*` keys first, then falls back to `blogging_*`.

**Note:** These settings are currently only configurable via code. There is no admin UI for these options yet; expose them in your app if customers need runtime control.

### Templates

Public templates are located in:

- `lib/modules/publishing/web/templates/show.html.heex` - Single post view
- `lib/modules/publishing/web/templates/index.html.heex` - Group listing

### Admin Integration

When editing a post in the admin interface:

- **View Public** button appears for published posts
- Button links directly to the public URL
- Automatically updates when status changes to "published"

### Caching

PhoenixKit ships two cache layers:

1. **Listing cache** – `PhoenixKit.Modules.Publishing.ListingCache` writes summary JSON to
   `priv/publishing/<group>/.listing_cache.json` and mirrors parsed data into `:persistent_term`
   for sub-microsecond reads. File vs memory caching can be toggled via the
   `publishing_file_cache_enabled` / `publishing_memory_cache_enabled` settings or from the Publishing
   Settings UI, which also offers regenerate/clear actions per group.
2. **Render cache** – `PhoenixKit.Modules.Publishing.Renderer` stores rendered HTML for published posts in the
   `:publishing_posts` cache (6-hour TTL) with content-hash keys, a global
   `publishing_render_cache_enabled` toggle, and per-group overrides (`publishing_render_cache_enabled_<slug>`)
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

- **PhoenixKit.Modules.Publishing** – Main context module with mode-aware routing (all writes are DB-only)
- **PhoenixKit.Modules.Publishing.DBStorage** – Database CRUD layer for groups, posts, versions, and contents
- **PhoenixKit.Modules.Publishing.DBStorage.Mapper** – Converts DB records to the legacy map format consumed by web layer
- **PhoenixKit.Modules.Publishing.Storage** – Read-only filesystem layer (legacy `.phk` file reads for pre-migration content)
- **PhoenixKit.Modules.Publishing.Metadata** – YAML frontmatter parsing and serialization (used by FS reader and import workers)

**Schemas (V59 migration):**

- **PhoenixKit.Modules.Publishing.PublishingGroup** – Publishing group schema (name, slug, mode, data JSONB)
- **PhoenixKit.Modules.Publishing.PublishingPost** – Post schema (group FK, slug, status, mode, data JSONB)
- **PhoenixKit.Modules.Publishing.PublishingVersion** – Version schema (post FK, version_number, status, data JSONB)
- **PhoenixKit.Modules.Publishing.PublishingContent** – Content/translation schema (version FK, language, title, content, url_slug, data JSONB)

**Admin Interfaces:**

- **PhoenixKit.Modules.Publishing.Web.Settings** – Admin interface for group configuration and DB import
- **PhoenixKit.Modules.Publishing.Web.Editor** – Markdown editor with autosave and featured images (DB-only, gated by migration)
- **PhoenixKit.Modules.Publishing.Web.Preview** – Live preview for posts

**Public Display:**

- **PhoenixKit.Modules.Publishing.Web.Controller** – Public-facing routes for group listings and posts
- **PhoenixKit.Modules.Publishing.Web.HTML** – HTML helpers and view functions for public content

**Rendering & Caching:**

- **PhoenixKit.Modules.Publishing.ListingCache** – File + memory listing cache
- **PhoenixKit.Modules.Publishing.Renderer** – Markdown/PHK rendering with content-hash caching

**Collaborative Editing:**

- **PhoenixKit.Modules.Publishing.Presence** – Phoenix.Presence for real-time user tracking
- **PhoenixKit.Modules.Publishing.PresenceHelpers** – Owner/spectator logic helpers
- **PhoenixKit.Modules.Publishing.PubSub** – Real-time change broadcasting

**Workers:**

- **MigrateToDatabaseWorker** – Backfills filesystem posts into the database (Oban job)
- **MigratePrimaryLanguageWorker** – Ensures primary language metadata consistency
- **MigrateLegacyStructureWorker** – Upgrades legacy non-versioned posts to versioned structure

## Core Features

- **Dual URL Modes** – Timestamp-based (date/time URLs) or slug-based (semantic URLs)
- **Mode Immutability** – URL mode locked at group creation, cannot be changed
- **Slug Mutability** – Post slugs can be changed after creation (DB update, no file movement)
- **Multi-Language Support** – Separate content records per language, all stored in `publishing_contents` table
- **Database Storage** – All writes go to PostgreSQL; legacy `.phk` file reading preserved for migration
- **Markdown Content** – Full Markdown support with syntax highlighting
- **JSONB Metadata** – Flexible metadata via `data` JSONB columns on all four schemas
- **Backward Compatibility** – Legacy groups without mode field default to "timestamp"

## URL Modes

Each publishing group has an immutable URL mode that determines how post URLs are structured. The mode is set at creation and cannot be changed afterward. Both modes store data identically in the database.

### 1. Timestamp Mode (Default, Legacy)

Posts addressed by publication date and time:

```
/{prefix}/{language}/{group}/{YYYY-MM-DD}/{HH:MM}
```

**Characteristics:**
- URL auto-generated from `published_at` timestamp
- No slug field in editor UI
- Ideal for chronological content (news, announcements, changelogs)
- URL path cannot be manually controlled by user

**Example URL:** `/phoenix_kit/en/news/2025-01-15/09:30`

### 2. Slug Mode (Semantic URLs)

Posts addressed by semantic slug:

```
/{prefix}/{language}/{group}/{post-slug}
```

**Characteristics:**
- User-provided or auto-generated slug from title
- Slug field visible in editor UI
- Slug validation: lowercase letters, numbers, hyphens only
- Ideal for documentation, guides, evergreen content
- Slug can be changed (DB update, old URLs can redirect via `previous_url_slugs`)

**Example URL:** `/phoenix_kit/en/docs/getting-started`

## File Format (.phk files)

> **Note:** The `.phk` format is the legacy filesystem format. New posts are stored in the database. This section documents the format for migration purposes and for understanding the `Metadata` module.

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

The main context module (`publishing.ex`) provides the public API. All writes go to the database via `DBStorage`:

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
- Module settings live in `PhoenixKit.Settings` (with legacy `blogging_settings_module` fallback).

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
- Groups are stored in the `publishing_groups` DB table (and synced to Settings JSON for backward compatibility).

### Creating scope-aware posts

```elixir
iex> user = MyApp.Repo.get!(MyApp.Users.User, 123)
iex> scope = Scope.for_user(user)
iex> {:ok, post} = Publishing.create_post("documentation", %{title: "Intro", scope: scope})
iex> {:ok, post} = Publishing.create_post("docs", %{title: "Intro", slug: "getting-started"})
iex> {:ok, post} = Publishing.create_post("news", %{scope: Scope.for_user(nil)})
```

- Slug mode expects a title (auto-slug) or explicit `:slug`.
- Timestamp mode ignores slug and uses current UTC time for the URL.
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
- `update_post/4` updates the DB record directly; slug changes are tracked via `previous_url_slugs`.

### Versioning and translations

```elixir
iex> {:ok, draft_v2} = Publishing.create_version_from("docs", "getting-started", 1, %{"content" => "..."})
iex> :ok = Publishing.publish_version("docs", "getting-started", 2)
iex> {:ok, spanish} = Publishing.add_language_to_post("docs", "getting-started", "es")
iex> :ok = Publishing.delete_language("docs", "getting-started", "fr")
iex> :ok = Publishing.delete_version("docs", "getting-started", 1)
```

- `create_version_from/5` creates a new version by copying from source (or blank if `nil`); publish with `publish_version/3`.
- Languages are stored as separate `publishing_contents` rows sharing the same version.

### Cache helpers

```elixir
iex> posts = Publishing.list_posts("docs")
iex> :ok = Publishing.regenerate_cache("docs")
iex> {:ok, cached} = Publishing.find_cached_post("docs", "getting-started")
iex> {:ok, _} = Publishing.trash_post("docs", "getting-started")
```

- Listing cache uses file + `:persistent_term` for sub-microsecond reads.
- `trash_post/2` performs a DB soft-delete (sets `deleted_at` timestamp). Trashed posts can be restored via DB if needed.

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

# Remove group from settings list
{:ok, _} = Publishing.remove_group("docs")

# Trash group (soft-delete in DB, removes from settings)
{:ok, _} = Publishing.trash_group("docs")

# Get group name from slug
name = Publishing.group_name("docs")  # => "Documentation"

# Slug utilities
slug = Publishing.slugify("My First Post!")  # => "my-first-post"
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

The context layer routes all writes to the database:

```elixir
# Create post (DB insert, routes by group mode for URL generation)
{:ok, post} = Publishing.create_post("docs", %{title: "Hello World"})
# Slug mode: auto-generates slug "hello-world"
# Timestamp mode: uses current date/time for URL

# Create post with explicit slug and audit trail (slug mode only)
{:ok, post} = Publishing.create_post("docs", %{
  title: "Getting Started",
  slug: "get-started",
  scope: current_user_scope  # Optional: records created_by_id/email
})

# List posts (routes by group mode)
posts = Publishing.list_posts("docs")
posts = Publishing.list_posts("docs", "es")  # With language preference

# Read post (routes by group mode)
{:ok, post} = Publishing.read_post("docs", "getting-started")
{:ok, post} = Publishing.read_post("docs", "getting-started", "es")

# Update post (DB update)
{:ok, updated} = Publishing.update_post("docs", post, %{
  "title" => "Updated Title",
  "slug" => "new-slug",  # Slug mode: updates DB, tracks old slug for redirects
  "content" => "Updated content..."
}, scope: current_user_scope)  # Optional 4th arg: records updated_by_id/email

# Add translation
{:ok, spanish_post} = Publishing.add_language_to_post("docs", "getting-started", "es")
```

### Delete Operations

Delete operations use DB soft-deletes (setting `status` to `"archived"` or `deleted_at` timestamp):

```elixir
# Soft-delete post (sets deleted_at, all versions and languages)
{:ok, _} = Publishing.trash_post("docs", "getting-started")

# For timestamp mode, use the date/time path
{:ok, _} = Publishing.trash_post("news", "2025-01-15/14:30")

# Archive a specific translation (refuses if last active language)
:ok = Publishing.delete_language("docs", "getting-started", "es")
:ok = Publishing.delete_language("docs", "getting-started", "es", 2)  # specific version
{:error, :last_language} = Publishing.delete_language("docs", "post", "en")

# Archive a version (refuses if live or last active version)
:ok = Publishing.delete_version("docs", "getting-started", 1)
{:error, :cannot_delete_live} = Publishing.delete_version("docs", "post", 2)
{:error, :last_version} = Publishing.delete_version("docs", "post", 1)
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

# Fast post lookup from cache (O(1) via :persistent_term)
{:ok, post_data} = Publishing.find_cached_post("docs", "getting-started")
{:ok, post_data} = Publishing.find_cached_post_by_path("news", "2025-01-15", "14:30")
```

## Storage Architecture

### DB Storage (Primary — All Writes)

All create/update/delete operations go through `DBStorage`:

```elixir
alias PhoenixKit.Modules.Publishing.DBStorage

# Posts
{:ok, post} = DBStorage.create_post(group_uuid, %{slug: "hello", status: "draft", mode: "slug"})
{:ok, post} = DBStorage.get_post("docs", "hello")
{:ok, updated} = DBStorage.update_post(post, %{status: "published"})
{:ok, deleted} = DBStorage.soft_delete_post(post)

# Versions
{:ok, version} = DBStorage.create_version(post_uuid, %{version_number: 1, status: "draft"})
versions = DBStorage.list_versions(post_uuid)
{:ok, version} = DBStorage.get_version(post_uuid, 1)

# Contents (translations)
{:ok, content} = DBStorage.create_content(version_uuid, %{language: "en", title: "Hello", content: "# Hello"})
{:ok, content} = DBStorage.get_content(version_uuid, "en")
contents = DBStorage.list_contents(version_uuid)
```

The `Mapper` module converts DB records to the legacy map format that the web layer and templates consume:

```elixir
alias PhoenixKit.Modules.Publishing.DBStorage.Mapper

post_map = Mapper.to_legacy_map(group, post, version, content, available_languages)
listing_map = Mapper.to_listing_map(group, post, version, primary_content)
```

### Filesystem Storage (Read-Only — Legacy Migration)

The `Storage` module provides read-only access to legacy `.phk` files for pre-migration content:

```elixir
alias PhoenixKit.Modules.Publishing.Storage

# Read-only operations (used by public rendering before DB migration completes)
{:ok, post} = Storage.read_post_slug_mode("docs", "hello", "en")
posts = Storage.list_posts_slug_mode("docs", "en")
posts = Storage.list_posts("news", "en")

# Utility functions (still active)
Storage.valid_slug?("hello-world")  # => true
{:ok, "hello-world"} = Storage.validate_slug("hello-world")
Storage.slug_exists?("docs", "getting-started")  # => true/false
{:ok, slug} = Storage.generate_unique_slug("docs", "Getting Started")
Storage.content_changed?(post, params)  # => true/false
Storage.status_change_only?(post, params)  # => true/false

# Language helpers
Storage.enabled_language_codes()   # => ["en", "es", "fr"]
Storage.get_language_info("en")    # => %{code: "en", name: "English", flag: "🇺🇸"}
Storage.language_enabled?("en", ["en-US", "es"])  # => true
```

**Note:** All write functions (`create_post`, `update_post`, `trash_post`, `delete_language`, `delete_version`, etc.) have been removed from `Storage`. Use the context layer (`Publishing.*`) which routes to `DBStorage`.

## LiveView Interfaces

### Settings (`settings.ex`)

Group configuration interface at `{prefix}/admin/settings/publishing`:

- Create new groups with mode selector
- View existing groups with mode badges
- Delete groups
- Configure public display settings

**Group Creation (New Group Form):**
- Mode selector: Radio buttons (Timestamp / Slug)
- Warning text: "Cannot be changed after group creation"
- Mode is locked permanently after creation

### Editor (`editor.ex`)

Markdown editor at `{prefix}/admin/publishing/{group}/edit`:

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

**Migration Gate:**

The editor requires DB storage mode to be active. If filesystem posts exist but haven't been migrated, the editor redirects to the Publishing admin with a prompt to run the DB import. For fresh installs (no FS posts), DB mode is enabled automatically.

**Mode-Specific Behavior:**

**Timestamp Mode:**
- No slug field visible
- URL auto-generated from `published_at`

**Slug Mode:**
- Slug field visible with validation
- Auto-generates slug from title (debounced)
- User can override auto-generated slug
- Validation: lowercase, numbers, hyphens only
- **Reserved slugs**: Any language code from the Languages module cannot be used as a slug to prevent routing ambiguity
- Shows validation error for invalid slugs

### Preview (`preview.ex`)

Live preview at `{prefix}/admin/publishing/{group}/preview`:

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

- Users join a Presence topic (e.g., `publishing_edit:group-slug:post-slug`)
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

Every post version can have multiple language translations stored as separate `publishing_contents` rows:

```
publishing_contents table:
  version_uuid | language | title           | content    | url_slug
  abc-123      | en       | Getting Started | # Getting… | getting-started
  abc-123      | es       | Primeros Pasos  | # Primeros | primeros-pasos
  abc-123      | fr       | Prise en Main   | # Prise…   | prise-en-main
```

**Workflow:**

1. Create primary post (e.g., English)
2. Click language switcher → Select "Add Spanish"
3. System creates a new content record with empty content and title
4. Fill in translated content and save
5. All translations share same post/version, each with its own `url_slug`

**Post Map Fields (Legacy Format):**

The `Mapper` module converts DB records into this map format consumed by templates and the web layer:

```elixir
%{
  group: "docs",                    # Publishing group slug
  slug: "getting-started",          # Slug mode only
  uuid: "01234567-...",             # UUIDv7 from DB (nil for FS-only posts)
  date: ~D[2025-01-15],             # Timestamp mode only
  time: ~T[09:30:00],               # Timestamp mode only
  path: "docs/getting-started/v1/en.phk",  # Virtual path for compatibility
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
  is_legacy_structure: false
}
```

**Note on `uuid`:** Posts read from the database have a non-nil `uuid` field. The helper `Publishing.db_post?(post)` checks this to distinguish DB posts from legacy FS posts during the migration period.

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
4. **Records Created**: Translation content records are created or updated in the database
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

### Fresh Installs

New installs start with DB storage mode immediately. No filesystem content exists, so the editor is available right away.

### Existing Installs (Filesystem → Database)

Existing `.phk` file content must be imported into the database:

1. Navigate to `{prefix}/admin/publishing` (the listing page)
2. Click "Import to DB" for each publishing group
3. The `MigrateToDatabaseWorker` (Oban job) reads `.phk` files and creates DB records
4. When migration completes, the `publishing_storage` setting is auto-flipped to `"db"`
5. The editor becomes available

**Programmatic import:**

```elixir
# Import a specific group
PhoenixKit.Modules.Publishing.Workers.MigrateToDatabaseWorker.enqueue("docs")

# Or import via the context layer
PhoenixKit.Modules.Publishing.import_group_to_db("docs")
```

During migration, public rendering continues to read from the filesystem. After the setting flips to `"db"`, all reads switch to the database.

### Existing Groups (Pre-Dual-Mode)

All existing groups automatically default to `"timestamp"` mode via `normalize_groups/1`:

```elixir
# Before (legacy group without mode field)
%{"name" => "News", "slug" => "news"}

# After (normalized with default mode)
%{"name" => "News", "slug" => "news", "mode" => "timestamp"}
```

No migration script needed – backward compatibility is automatic.

### Creating New Groups

Admin chooses mode at creation time:

1. Navigate to `{prefix}/admin/publishing/settings`
2. Enter group name: "Documentation"
3. Select mode: **Slug** or **Timestamp**
4. Click "Add Group"
5. Mode is now permanently locked for this group

## Test Coverage

**Status:** 122+ unit tests across 6 test files (all pure-function, no database required).

**Test files:**

| File | Tests | Coverage |
|------|-------|----------|
| `test/modules/publishing/schema_test.exs` | 28 | All 4 schema changesets, JSONB accessors, defaults |
| `test/modules/publishing/metadata_test.exs` | 26 | parse/serialize round-trip, title extraction, legacy XML |
| `test/modules/publishing/mapper_test.exs` | 26 | `to_legacy_map`, `to_listing_map`, field mapping, edge cases |
| `test/modules/publishing/pubsub_test.exs` | 13 | Topic generation, form key generation |
| `test/modules/publishing/publishing_api_test.exs` | 20 | Module loading, slugify, valid_slug?, db_post?, extract helpers |
| `test/modules/publishing/storage_utils_test.exs` | 9 | content_changed?, status_change_only?, should_create_new_version? |

**Running Tests:**

```bash
# Run all publishing tests
mix test test/modules/publishing/

# Run a specific test file
mix test test/modules/publishing/schema_test.exs
```

**Testing Philosophy:**

PhoenixKit is a library module. Unit tests cover pure functions, changesets, and data transformations. Integration tests requiring a database (CRUD operations, LiveView flows) are run in parent Phoenix applications.

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
# Note: The inner "blogs" key is a legacy JSON key preserved for backward compatibility

# Cache toggles (with legacy blogging_* fallback)
PhoenixKit.Settings.update_setting("publishing_file_cache_enabled", "true")
PhoenixKit.Settings.update_setting("publishing_memory_cache_enabled", "true")

# Render cache (global + per group, with legacy fallback)
PhoenixKit.Settings.update_setting("publishing_render_cache_enabled", "true")
PhoenixKit.Settings.update_setting("publishing_render_cache_enabled_docs", "false")

# Custom settings backend (optional, with legacy blogging_settings_module fallback)
config :phoenix_kit, publishing_settings_module: MyApp.CustomSettings
```

### Storage

**Primary (DB):** All content is stored in PostgreSQL via the V59 migration tables:

| Table | Purpose |
|-------|---------|
| `phoenix_kit_publishing_groups` | Publishing groups (name, slug, mode, data JSONB) |
| `phoenix_kit_publishing_posts` | Posts (group FK, slug, status, mode, published_at) |
| `phoenix_kit_publishing_versions` | Versions (post FK, version_number, status) |
| `phoenix_kit_publishing_contents` | Content/translations (version FK, language, title, content, url_slug) |

**Legacy (FS, read-only):** Pre-migration `.phk` files in `priv/publishing/` (with `priv/blogging/` fallback) are read-only. The `MigrateToDatabaseWorker` imports these into the database. After migration completes, the `publishing_storage` setting is auto-flipped to `"db"` and the editor becomes available.

**Feature flag:** The `publishing_storage` setting controls the read path:
- `"filesystem"` (default) — Public rendering reads from FS; editor is gated/blocked
- `"db"` — All reads and writes use the database

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

Choose a different slug. Language codes are reserved to prevent URL routing ambiguity between `/{prefix}/en/docs` (language + group) and a post with slug `en`.

---

### Problem: Slug already exists

**Symptoms:**
```
A post with this slug already exists
```

**Root Cause:**

Another post in the same group already uses this slug.

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

Slug changes update the database record. Old URLs need redirects. Update any hardcoded links:

```elixir
# Before slug change
Publishing.read_post("docs", "old-slug")

# After slug change (from "old-slug" to "new-slug")
Publishing.read_post("docs", "new-slug")  # ✅ Works
Publishing.read_post("docs", "old-slug")  # ❌ Not found
```

Consider implementing redirects in your application for user-facing URLs.

---

### Problem: Cannot change group mode

**Symptoms:**

Mode field is read-only in settings UI.

**Root Cause:**

Mode immutability is by design – storage mode is locked at group creation.

**Solution:**

To change modes, you must:

1. Create a new group with the desired mode
2. Manually migrate posts (via IEx or scripts) to the new group
3. Update internal references
4. Delete old group

**No automatic migration is provided** – this is an infrequent operation best done manually.

---

### Problem: Cannot delete the last language

**Symptoms:**
```
{:error, :last_language}
```

**Root Cause:**

Every post version must have at least one active language. You cannot archive the only remaining translation.

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
{:error, :cannot_delete_live}
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
{:error, :last_version}
```

**Root Cause:**

Every post must have at least one active version. You cannot archive the only remaining version.

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
/en/docs/getting-started   →  post slug: "getting-started", content url_slug: "getting-started"
/es/docs/primeros-pasos    →  post slug: "getting-started", content url_slug: "primeros-pasos"
/fr/docs/prise-en-main     →  post slug: "getting-started", content url_slug: "prise-en-main"
```

**Key Concepts:**

1. **Post Slug = Internal Identifier** - The post's `slug` field in the database ties all translations together. This is the canonical identifier.

2. **url_slug = Public URL** - Each translation's `publishing_contents` row has its own `url_slug` for the public-facing URL.

3. **Backward Compatible** - If no `url_slug` is set, the post slug is used (existing behavior).

### Setting Up Per-Language Slugs

**In the Editor:**

1. Open a translation (non-primary language) in the editor
2. Find the "URL Slug" field in the metadata panel (only visible for translations)
3. Enter a localized slug (e.g., `primeros-pasos` for Spanish)
4. Save - the URL immediately updates

**In Database:**

The `url_slug` is stored on the `publishing_contents` record. For legacy `.phk` files, it's in the YAML frontmatter:

```yaml
---
slug: getting-started
url_slug: primeros-pasos
---
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

### Cold Start Fallback

On cold starts (no cache), the system queries the database to resolve URL slugs:

1. Queries `publishing_contents` for matching `url_slug` or entries in `data->previous_url_slugs`
2. Returns redirect for previous slugs, resolution for current slugs
3. For pre-migration installs, falls back to scanning `.phk` files on the filesystem

This ensures localized URLs work immediately after deployment without waiting for cache warm-up.

### SEO Benefits

- **Localized URLs**: Search engines prefer URLs in the user's language
- **Better Click-Through**: Users are more likely to click localized URLs in search results
- **Proper Hreflang**: The `<link rel="alternate" hreflang="xx">` tags use language-specific URLs
- **Canonical URLs**: Each translation has its own canonical URL with its localized slug

## Getting Help

1. Review DB storage layer: `lib/modules/publishing/db_storage.ex`
2. Review context module: `lib/modules/publishing/publishing.ex`
3. Inspect post map in IEx: `{:ok, post} = Publishing.read_post("docs", "slug")` → `IO.inspect(post)`
4. Enable debug logging: `Logger.configure(level: :debug)`
5. Search GitHub issues: <https://github.com/phoenixkit/phoenix_kit/issues>
