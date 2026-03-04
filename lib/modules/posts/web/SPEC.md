# Posts Module Specification

**Version**: 1.0
**Migration**: V29
**Status**: ✅ Phase 1 Complete
**Created**: 2025-11-27

---

## 🎯 Overview

Complete social posts system with media attachments, comments, likes, tags, user groups, and scheduled publishing for PhoenixKit.

### Key Features

- ✅ Multiple post types (post/snippet/repost) with different display layouts
- ✅ Multi-image uploads via PhoenixKit.Modules.Storage integration
- ✅ Unlimited nested comment threading
- ✅ User-created groups (Pinterest-style collections)
- ✅ Privacy controls (draft/public/unlisted/scheduled)
- ✅ Scheduled publishing via Oban
- ✅ Like/comment counters
- ✅ Hashtag tagging system
- ✅ User mentions/contributors
- ✅ View tracking (future release)

---

## 📊 Database Schema (Migration V28)

### 1. Posts Table (`phoenix_kit_posts`)

**Purpose**: Main posts storage with type-specific layouts

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key (time-sortable) |
| `user_uuid` | UUIDv7 | FK → users (post owner) |
| `title` | string | Post title (max length via settings) |
| `sub_title` | string | Tagline/subtitle (max length via settings) |
| `content` | text | Post content (max length via settings) |
| `type` | string | post/snippet/repost (affects display layout) |
| `status` | string | draft/public/unlisted/scheduled |
| `scheduled_at` | utc_datetime_usec | When to auto-publish (nullable) |
| `published_at` | utc_datetime_usec | When made public (nullable) |
| `repost_url` | string | Source URL for reposts (nullable) |
| `slug` | string | SEO-friendly URL slug |
| `like_count` | integer | Denormalized counter (default: 0) |
| `comment_count` | integer | Denormalized counter (default: 0) |
| `view_count` | integer | Page views counter (default: 0) |
| `metadata` | jsonb | Type-specific flexible data |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `user_uuid`, `status`, `type`, `slug`, `scheduled_at`, `published_at`

**Constraints**:
- FK: `user_uuid` → `phoenix_kit_users.uuid` (cascade delete)
- Unique: `slug` (per user or global - TBD)
- Check: `status IN ('draft', 'public', 'unlisted', 'scheduled')`
- Check: `type IN ('post', 'snippet', 'repost')`

---

### 2. Post Media Junction (`phoenix_kit_post_media`)

**Purpose**: Many-to-many relationship between posts and uploaded files

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key |
| `post_uuid` | UUIDv7 | FK → posts |
| `file_uuid` | UUIDv7 | FK → files (PhoenixKit.Modules.Storage) |
| `position` | integer | Display order (1, 2, 3...) |
| `caption` | text | Image caption/alt text (nullable) |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `post_uuid`, `file_uuid`, `position`

**Constraints**:
- FK: `post_uuid` → `phoenix_kit_posts.uuid` (cascade delete)
- FK: `file_uuid` → `phoenix_kit_files.uuid` (cascade delete)
- Unique: `(post_uuid, position)` - prevent duplicate ordering

---

### 3. Likes Table (`phoenix_kit_post_likes`)

**Purpose**: Track user likes on posts

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key |
| `post_uuid` | UUIDv7 | FK → posts |
| `user_uuid` | UUIDv7 | FK → users |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `post_uuid`, `user_uuid`

**Constraints**:
- FK: `post_uuid` → `phoenix_kit_posts.uuid` (cascade delete)
- FK: `user_uuid` → `phoenix_kit_users.uuid` (cascade delete)
- Unique: `(post_uuid, user_uuid)` - one like per user per post

---

### 4. Comments Table (`phoenix_kit_post_comments`)

**Purpose**: Nested threaded comments (unlimited depth)

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key |
| `post_uuid` | UUIDv7 | FK → posts |
| `user_uuid` | UUIDv7 | FK → users (commenter) |
| `parent_uuid` | UUIDv7 | FK → comments (nullable, for threading) |
| `content` | text | Comment text (required) |
| `status` | string | published/hidden/deleted/pending |
| `depth` | integer | Nesting level (0=top, 1=reply, 2=reply-to-reply...) |
| `like_count` | integer | Denormalized counter (default: 0, future feature) |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `post_uuid`, `user_uuid`, `parent_uuid`, `status`, `depth`

**Constraints**:
- FK: `post_uuid` → `phoenix_kit_posts.uuid` (cascade delete)
- FK: `user_uuid` → `phoenix_kit_users.uuid` (cascade delete)
- FK: `parent_uuid` → `phoenix_kit_post_comments.uuid` (cascade delete)
- Check: `status IN ('published', 'hidden', 'deleted', 'pending')`

---

### 5. Mentions/Contributors (`phoenix_kit_post_mentions`)

**Purpose**: Tag users related to a post (helped create it, featured in it, etc.)

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key |
| `post_uuid` | UUIDv7 | FK → posts |
| `user_uuid` | UUIDv7 | FK → users (mentioned user) |
| `mention_type` | string | contributor/mention |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `post_uuid`, `user_uuid`, `mention_type`

**Constraints**:
- FK: `post_uuid` → `phoenix_kit_posts.uuid` (cascade delete)
- FK: `user_uuid` → `phoenix_kit_users.uuid` (cascade delete)
- Unique: `(post_uuid, user_uuid)` - one mention per user per post
- Check: `mention_type IN ('contributor', 'mention')`

---

### 6. Tags Table (`phoenix_kit_post_tags`)

**Purpose**: Hashtag system for categorization

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key |
| `name` | string | Display name (e.g., "Web Development") |
| `slug` | string | URL-safe slug (e.g., "web-development") |
| `usage_count` | integer | How many posts use this tag (default: 0) |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `slug`, `usage_count`

**Constraints**:
- Unique: `slug` - case-insensitive unique slugs

---

### 7. Post-Tag Junction (`phoenix_kit_post_tag_assignments`)

**Purpose**: Many-to-many between posts and tags

| Column | Type | Description |
|--------|------|-------------|
| `post_uuid` | UUIDv7 | FK → posts |
| `tag_uuid` | UUIDv7 | FK → tags |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `post_uuid`, `tag_uuid`

**Constraints**:
- FK: `post_uuid` → `phoenix_kit_posts.uuid` (cascade delete)
- FK: `tag_uuid` → `phoenix_kit_post_tags.uuid` (cascade delete)
- Unique: `(post_uuid, tag_uuid)` - no duplicate tags on same post

---

### 8. User Groups Table (`phoenix_kit_post_groups`)

**Purpose**: User-created collections to organize their posts (Pinterest-style boards)

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key |
| `user_uuid` | UUIDv7 | FK → users (group owner) |
| `name` | string | Group name (e.g., "Travel Photos") |
| `slug` | string | URL-safe slug |
| `description` | text | Group description (nullable) |
| `cover_image_uuid` | UUIDv7 | FK → files (nullable, group thumbnail) |
| `post_count` | integer | Denormalized counter (default: 0) |
| `is_public` | boolean | Public groups visible to others (default: false) |
| `position` | integer | Manual ordering of user's groups |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `user_uuid`, `slug`, `is_public`, `position`

**Constraints**:
- FK: `user_uuid` → `phoenix_kit_users.uuid` (cascade delete)
- FK: `cover_image_uuid` → `phoenix_kit_files.uuid` (set null on delete)
- Unique: `(user_uuid, slug)` - unique slug per user

---

### 9. Post-Group Junction (`phoenix_kit_post_group_assignments`)

**Purpose**: Many-to-many between posts and groups (posts can be in multiple groups)

| Column | Type | Description |
|--------|------|-------------|
| `post_uuid` | UUIDv7 | FK → posts |
| `group_uuid` | UUIDv7 | FK → groups |
| `position` | integer | Manual ordering within group |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `post_uuid`, `group_uuid`, `position`

**Constraints**:
- FK: `post_uuid` → `phoenix_kit_posts.uuid` (cascade delete)
- FK: `group_uuid` → `phoenix_kit_post_groups.uuid` (cascade delete)
- Unique: `(post_uuid, group_uuid)` - post can't be in same group twice

---

### 10. Views Table (`phoenix_kit_post_views`)

**Purpose**: Analytics tracking (Phase 2 - future release)

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUIDv7 | Primary key |
| `post_uuid` | UUIDv7 | FK → posts |
| `user_uuid` | UUIDv7 | FK → users (nullable, logged-in only) |
| `ip_address` | string | Hashed IP for privacy (nullable) |
| `user_agent_hash` | string | Browser fingerprint (nullable) |
| `session_id` | string | Group views by session |
| `viewed_at` | utc_datetime_usec | When viewed |
| `date_added` | naive_datetime | Created timestamp |
| `date_modified` | naive_datetime | Updated timestamp |

**Indexes**: `post_uuid`, `user_uuid`, `viewed_at`, `session_id`

**Constraints**:
- FK: `post_uuid` → `phoenix_kit_posts.uuid` (cascade delete)
- FK: `user_uuid` → `phoenix_kit_users.uuid` (cascade delete)

---

## ⚙️ Module Settings

All settings stored in `phoenix_kit_settings` table via `PhoenixKit.Settings` context.

### Content Limits (User Validation)

| Setting Key | Default | Description |
|-------------|---------|-------------|
| `posts_max_media` | 10 | Max images per post |
| `posts_max_title_length` | 255 | Max title characters |
| `posts_max_subtitle_length` | 500 | Max subtitle characters |
| `posts_max_content_length` | 50000 | Max content characters |
| `posts_max_mentions` | 10 | Max users mentioned per post |
| `posts_max_tags` | 20 | Max hashtags per post |

### Module Configuration

| Setting Key | Default | Description |
|-------------|---------|-------------|
| `posts_enabled` | true | Enable/disable entire module |
| `posts_per_page` | 20 | Pagination limit |
| `posts_default_status` | "draft" | Default status for new posts |

### Feature Toggles

| Setting Key | Default | Description |
|-------------|---------|-------------|
| `posts_comments_enabled` | true | Global comment system toggle |
| `posts_likes_enabled` | true | Global likes system toggle |
| `posts_allow_scheduling` | true | Enable scheduled publishing |
| `posts_allow_groups` | true | Enable user groups feature |
| `posts_allow_reposts` | true | Enable repost type |
| `posts_seo_auto_slug` | true | Auto-generate URL slugs from titles |
| `posts_show_view_count` | true | Display view counts publicly |

### Moderation

| Setting Key | Default | Description |
|-------------|---------|-------------|
| `posts_require_approval` | false | All posts go to moderation queue |
| `posts_comment_moderation` | false | Require approval for comments |

---

## 📁 File Structure

```
lib/phoenix_kit/posts/
├── post.ex                      # Main post schema
├── post_media.ex                # Post-media junction schema
├── post_like.ex                 # Like schema
├── post_comment.ex              # Comment schema (with nesting)
├── post_mention.ex              # Mention/contributor schema
├── post_tag.ex                  # Tag schema
├── post_tag_assignment.ex       # Post-tag junction
├── post_group.ex                # User group schema
├── post_group_assignment.ex     # Post-group junction
├── post_view.ex                 # Analytics schema (future)
└── posts.ex                     # Context (business logic API)

lib/phoenix_kit_web/live/modules/posts/
├── SPEC.md                      # This file
├── README.md                    # User-facing documentation
├── posts.ex                     # List/index view
├── posts.html.heex              # List template
├── edit.ex                      # Create/edit form
├── edit.html.heex               # Form template
├── details.ex                   # Single post view
├── details.html.heex            # Detail template
├── settings.ex                  # Module settings LiveView
├── settings.html.heex           # Settings template
├── groups.ex                    # User's groups management
├── groups.html.heex             # Groups list template
├── group_edit.ex                # Create/edit group
├── group_edit.html.heex         # Group form template
└── components/
    ├── post_card.ex             # Post display (type-specific layouts)
    ├── comment_thread.ex        # Nested comments component
    ├── like_button.ex           # Like interaction
    ├── tag_picker.ex            # Tag selection/creation
    └── group_selector.ex        # Group assignment

lib/phoenix_kit/migrations/postgres/
└── v28.ex                       # Posts system migration
```

---

## 🎯 Implementation Checklist

### ✅ Phase 1: Database & Schemas (Foundation)

- [ ] **1.1 Create Migration V28**
  - [ ] Create `lib/phoenix_kit/migrations/postgres/v28.ex`
  - [ ] Define `up/1` function with all 10 tables
  - [ ] Define `down/1` function with rollback logic
  - [ ] Add all indexes and constraints
  - [ ] Seed default module settings (16 settings)
  - [ ] Update version tracking (comment on phoenix_kit table)
  - [ ] Test migration up/down idempotency

- [ ] **1.2 Create Post Schema** (`lib/phoenix_kit/posts/post.ex`)
  - [ ] Define schema with UUIDv7 primary key
  - [ ] Add all 16 fields with proper types
  - [ ] Define associations (user, media, comments, likes, tags, groups, mentions)
  - [ ] Create `changeset/2` with validations
  - [ ] Add helper functions (published?, scheduled?, can_comment?, etc.)
  - [ ] Add type specs (@type t :: ...)
  - [ ] Add module documentation

- [ ] **1.3 Create Post Media Schema** (`lib/phoenix_kit/posts/post_media.ex`)
  - [ ] Define junction schema
  - [ ] Add associations (post, file)
  - [ ] Create changeset with position validation
  - [ ] Add ordering helpers

- [ ] **1.4 Create Post Like Schema** (`lib/phoenix_kit/posts/post_like.ex`)
  - [ ] Define schema
  - [ ] Add associations (post, user)
  - [ ] Create changeset
  - [ ] Add unique validation

- [ ] **1.5 Create Post Comment Schema** (`lib/phoenix_kit/posts/post_comment.ex`)
  - [ ] Define schema with parent_id for threading
  - [ ] Add associations (post, user, parent, children)
  - [ ] Create changeset with depth calculation
  - [ ] Add helper functions (is_reply?, get_thread_root, etc.)

- [ ] **1.6 Create Post Mention Schema** (`lib/phoenix_kit/posts/post_mention.ex`)
  - [ ] Define schema
  - [ ] Add associations (post, user)
  - [ ] Create changeset with mention_type validation

- [ ] **1.7 Create Post Tag Schema** (`lib/phoenix_kit/posts/post_tag.ex`)
  - [ ] Define schema
  - [ ] Add slug generation logic
  - [ ] Create changeset with slug validation
  - [ ] Add usage counter helpers

- [ ] **1.8 Create Post Tag Assignment Schema** (`lib/phoenix_kit/posts/post_tag_assignment.ex`)
  - [ ] Define junction schema
  - [ ] Add associations (post, tag)
  - [ ] Create changeset

- [ ] **1.9 Create Post Group Schema** (`lib/phoenix_kit/posts/post_group.ex`)
  - [ ] Define schema
  - [ ] Add associations (user, cover_image, posts)
  - [ ] Create changeset with slug validation
  - [ ] Add helper functions (public?, user_owns?)

- [ ] **1.10 Create Post Group Assignment Schema** (`lib/phoenix_kit/posts/post_group_assignment.ex`)
  - [ ] Define junction schema
  - [ ] Add associations (post, group)
  - [ ] Create changeset with position validation

- [ ] **1.11 Create Post View Schema** (`lib/phoenix_kit/posts/post_view.ex`)
  - [ ] Define schema (for future analytics)
  - [ ] Add associations (post, user)
  - [ ] Create changeset
  - [ ] Add deduplication logic

- [ ] **1.12 Create Posts Context** (`lib/phoenix_kit/posts/posts.ex`)
  - [ ] **CRUD Operations**:
    - [ ] `create_post/2` - Create new post
    - [ ] `update_post/2` - Update existing post
    - [ ] `delete_post/1` - Delete post (cascade to all relations)
    - [ ] `get_post!/1` - Get by ID with preloads
    - [ ] `get_post_by_slug/1` - Get by slug
  - [ ] **Query Helpers**:
    - [ ] `list_posts/1` - Paginated list with filters
    - [ ] `list_user_posts/2` - User's posts
    - [ ] `list_public_posts/1` - Public posts only
    - [ ] `search_posts/2` - Search by title/content
    - [ ] `list_posts_by_tag/2` - Filter by tag
    - [ ] `list_posts_by_group/2` - Filter by group
  - [ ] **Counter Cache Updates**:
    - [ ] `increment_like_count/1`
    - [ ] `decrement_like_count/1`
    - [ ] `increment_comment_count/1`
    - [ ] `decrement_comment_count/1`
    - [ ] `increment_view_count/1`
  - [ ] **Like Operations**:
    - [ ] `like_post/2` - User likes post
    - [ ] `unlike_post/2` - User unlikes post
    - [ ] `post_liked_by?/2` - Check if user liked post
    - [ ] `list_post_likes/1` - Get all likes for post
  - [ ] **Comment Operations**:
    - [ ] `create_comment/2` - Add comment
    - [ ] `update_comment/2` - Edit comment
    - [ ] `delete_comment/1` - Delete comment
    - [ ] `get_comment_tree/1` - Get nested comment structure
    - [ ] `list_post_comments/2` - Paginated comments
  - [ ] **Tag Operations**:
    - [ ] `find_or_create_tag/1` - Get or create tag by name
    - [ ] `parse_hashtags/1` - Extract hashtags from text
    - [ ] `add_tags_to_post/2` - Assign tags to post
    - [ ] `remove_tag_from_post/2` - Remove tag from post
    - [ ] `list_popular_tags/1` - Top tags by usage
  - [ ] **Group Operations**:
    - [ ] `create_group/2` - Create user group
    - [ ] `update_group/2` - Update group
    - [ ] `delete_group/1` - Delete group
    - [ ] `add_post_to_group/2` - Add post to group
    - [ ] `remove_post_from_group/2` - Remove post from group
    - [ ] `list_user_groups/1` - User's groups
    - [ ] `reorder_groups/2` - Update group positions
  - [ ] **Mention Operations**:
    - [ ] `add_mention_to_post/3` - Mention user
    - [ ] `remove_mention_from_post/2` - Remove mention
    - [ ] `list_post_mentions/1` - Get mentioned users
  - [ ] **Publishing Logic**:
    - [ ] `publish_post/1` - Make post public
    - [ ] `schedule_post/2` - Set scheduled publish time
    - [ ] `process_scheduled_posts/0` - Publish scheduled posts (Oban job)
    - [ ] `draft_post/1` - Revert to draft
  - [ ] **Media Operations**:
    - [ ] `attach_media/3` - Add image to post
    - [ ] `detach_media/2` - Remove image from post
    - [ ] `reorder_media/2` - Update image positions
    - [ ] `list_post_media/1` - Get ordered images

### ✅ Phase 2: Admin Interface (LiveView Pages)

- [ ] **2.1 Posts List View** (`lib/phoenix_kit_web/live/modules/posts/posts.ex`)
  - [ ] Create LiveView module
  - [ ] Implement `mount/3` callback
  - [ ] Implement `handle_params/3` for filters
  - [ ] Add pagination (via `posts_per_page` setting)
  - [ ] Add filters (type, status, group, tag, date range)
  - [ ] Add search functionality
  - [ ] Add bulk actions (publish, delete, move to group)
  - [ ] Add statistics dashboard (total, drafts, scheduled)
  - [ ] Create template (`posts.html.heex`)

- [ ] **2.2 Post Create/Edit Form** (`lib/phoenix_kit_web/live/modules/posts/edit.ex`)
  - [ ] Create LiveView module with `:new` and `:edit` actions
  - [ ] Implement form changeset handling
  - [ ] Add rich text editor for content
  - [ ] Integrate media upload (multiple images)
  - [ ] Add drag-drop image ordering
  - [ ] Add tag input with autocomplete
  - [ ] Add mention picker (user search)
  - [ ] Add group multi-select
  - [ ] Add type selector (post/snippet/repost)
  - [ ] Add conditional fields per type
  - [ ] Add status controls (draft/public/unlisted/scheduled)
  - [ ] Add scheduled datetime picker
  - [ ] Add live preview
  - [ ] Implement validation against settings limits
  - [ ] Create template (`edit.html.heex`)

- [ ] **2.3 Post Details View** (`lib/phoenix_kit_web/live/modules/posts/details.ex`)
  - [ ] Create LiveView module
  - [ ] Implement type-specific layout rendering
  - [ ] Add media gallery display
  - [ ] Add nested comment thread
  - [ ] Add like/unlike button
  - [ ] Add edit/delete actions
  - [ ] Add statistics display (views, likes, comments)
  - [ ] Add share options
  - [ ] Implement view tracking
  - [ ] Create template (`details.html.heex`)

- [ ] **2.4 Module Settings** (`lib/phoenix_kit_web/live/modules/posts/settings.ex`)
  - [ ] Create LiveView module
  - [ ] Load all 16 settings on mount
  - [ ] Create form for content limits
  - [ ] Create toggles for feature flags
  - [ ] Create moderation controls
  - [ ] Add live validation
  - [ ] Add preview of limits
  - [ ] Implement save handler
  - [ ] Add success/error notifications
  - [ ] Create template (`settings.html.heex`)

- [ ] **2.5 Groups List View** (`lib/phoenix_kit_web/live/modules/posts/groups.ex`)
  - [ ] Create LiveView module
  - [ ] List user's groups with stats
  - [ ] Add create/edit/delete actions
  - [ ] Add drag-drop reordering
  - [ ] Add cover image upload
  - [ ] Add public/private toggle
  - [ ] Add "view posts in group" navigation
  - [ ] Create template (`groups.html.heex`)

- [ ] **2.6 Group Edit Form** (`lib/phoenix_kit_web/live/modules/posts/group_edit.ex`)
  - [ ] Create LiveView module
  - [ ] Implement group form
  - [ ] Add slug auto-generation
  - [ ] Add cover image selector
  - [ ] Add description editor
  - [ ] Add public/private toggle
  - [ ] Create template (`group_edit.html.heex`)

### ✅ Phase 3: Components & Integration

- [ ] **3.1 Post Card Component** (`components/post_card.ex`)
  - [ ] Create Phoenix Component
  - [ ] Define attrs (post, type, mode)
  - [ ] Implement layout for type="post"
  - [ ] Implement layout for type="snippet"
  - [ ] Implement layout for type="repost"
  - [ ] Add media gallery display
  - [ ] Add like/comment counts
  - [ ] Add action buttons

- [ ] **3.2 Comment Thread Component** (`components/comment_thread.ex`)
  - [ ] Create Phoenix Component
  - [ ] Define attrs (comments, depth, max_depth)
  - [ ] Implement recursive rendering
  - [ ] Add collapse/expand functionality
  - [ ] Add reply form
  - [ ] Add like button (if enabled)
  - [ ] Add edit/delete actions
  - [ ] Add "load more" pagination

- [ ] **3.3 Like Button Component** (`components/like_button.ex`)
  - [ ] Create Phoenix Component
  - [ ] Define attrs (post_id, liked, count)
  - [ ] Implement like/unlike handler
  - [ ] Add optimistic UI updates
  - [ ] Add animation on like
  - [ ] Handle authentication state

- [ ] **3.4 Tag Picker Component** (`components/tag_picker.ex`)
  - [ ] Create Phoenix Component
  - [ ] Define attrs (selected_tags, on_change)
  - [ ] Implement autocomplete search
  - [ ] Add tag creation on-the-fly
  - [ ] Add tag removal
  - [ ] Enforce max tags limit
  - [ ] Show popular tags

- [ ] **3.5 Group Selector Component** (`components/group_selector.ex`)
  - [ ] Create Phoenix Component
  - [ ] Define attrs (groups, selected, user_id)
  - [ ] Implement multi-select dropdown
  - [ ] Add "create new group" inline
  - [ ] Show group thumbnails

- [ ] **3.6 Router Integration**
  - [ ] Add posts routes to `PhoenixKitWeb.Integration.phoenix_kit_routes/0`
  - [ ] Add authentication guards
  - [ ] Add authorization checks (admin vs user)
  - [ ] Configure route paths:
    - [ ] `/posts` - list
    - [ ] `/posts/new` - create
    - [ ] `/posts/:id/edit` - edit
    - [ ] `/posts/:id` - details
    - [ ] `/posts/groups` - groups list
    - [ ] `/posts/groups/new` - create group
    - [ ] `/posts/groups/:id/edit` - edit group
    - [ ] `/admin/posts/settings` - module settings

- [ ] **3.7 Dashboard Integration**
  - [ ] Add posts widget to `lib/phoenix_kit_web/live/dashboard.ex`
  - [ ] Show total posts count
  - [ ] Show recent activity (last 24h)
  - [ ] Show scheduled posts count
  - [ ] Add "Create Post" quick action
  - [ ] Add "View All Posts" link

- [ ] **3.8 Navigation Integration**
  - [ ] Add "Posts" menu item to main admin nav
  - [ ] Add submenu items (All Posts, My Groups, Settings)
  - [ ] Add active state highlighting

### ✅ Phase 4: Background Jobs & Features

- [ ] **4.1 Scheduled Publishing Job**
  - [ ] Create `lib/phoenix_kit/posts/jobs/publish_scheduled_posts.ex`
  - [ ] Configure Oban worker
  - [ ] Implement job logic (find scheduled posts where scheduled_at <= now)
  - [ ] Update status to "public"
  - [ ] Set published_at timestamp
  - [ ] Schedule job to run every minute
  - [ ] Add error handling and retries
  - [ ] Add logging

- [ ] **4.2 View Tracking** (Optional/Future)
  - [ ] Create `lib/phoenix_kit/posts/jobs/track_view.ex`
  - [ ] Implement async view recording
  - [ ] Add session deduplication
  - [ ] Add IP-based deduplication (hashed)
  - [ ] Update view_count cache
  - [ ] Configure sampling rate (via settings)

- [ ] **4.3 Notification System** (Optional/Future)
  - [ ] Create notification helpers
  - [ ] Send notification when user is mentioned
  - [ ] Send notification on comment replies
  - [ ] Send notification on likes (optional)
  - [ ] Add email notifications (via PhoenixKit.Mailer)
  - [ ] Add in-app notifications

- [ ] **4.4 Image Processing Integration**
  - [ ] Verify PhoenixKit.Modules.Storage handles image uploads
  - [ ] Ensure variant generation (thumbnail, medium, large)
  - [ ] Add image optimization
  - [ ] Add dimension validation
  - [ ] Add file size validation

### ✅ Phase 5: Documentation & Testing

- [ ] **5.1 Create Module README**
  - [ ] Create `lib/phoenix_kit_web/live/modules/posts/README.md`
  - [ ] Document architecture overview
  - [ ] Add usage examples
  - [ ] Document configuration options
  - [ ] Add troubleshooting section
  - [ ] Document API reference
  - [ ] Add screenshots (optional)

- [ ] **5.2 Update Main Documentation**
  - [ ] Update `CLAUDE.md` with posts module info
  - [ ] Add to "Architecture" section
  - [ ] Add to "Key File Structure" section
  - [ ] Update installation guide
  - [ ] Add to feature list in README.md

- [ ] **5.3 Smoke Tests**
  - [ ] Create `test/phoenix_kit/posts_test.exs`
  - [ ] Test schema loading (all 10 schemas)
  - [ ] Test context module loading
  - [ ] Test basic CRUD operations
  - [ ] Test settings integration
  - [ ] Test associations (preloading)
  - [ ] Verify no compilation warnings

- [ ] **5.4 Migration Testing**
  - [ ] Test migration up (V27 → V28)
  - [ ] Test migration down (V28 → V27)
  - [ ] Test idempotency (run up twice)
  - [ ] Test with prefix
  - [ ] Test on fresh database
  - [ ] Verify all indexes created
  - [ ] Verify all constraints work

### ✅ Phase 6: Polish & Launch

- [ ] **6.1 Code Quality**
  - [ ] Run `mix format`
  - [ ] Run `mix credo --strict`
  - [ ] Run `mix dialyzer`
  - [ ] Fix all warnings
  - [ ] Add @doc to all public functions
  - [ ] Add @spec to key functions

- [ ] **6.2 User Experience**
  - [ ] Add loading states
  - [ ] Add error messages
  - [ ] Add success notifications
  - [ ] Add confirmation dialogs (delete actions)
  - [ ] Add keyboard shortcuts
  - [ ] Add mobile responsiveness
  - [ ] Test accessibility

- [ ] **6.3 Performance**
  - [ ] Add database indexes for common queries
  - [ ] Implement pagination everywhere
  - [ ] Add query result caching (if needed)
  - [ ] Optimize N+1 queries
  - [ ] Add lazy loading for images

- [ ] **6.4 Security**
  - [ ] Add authorization checks (user owns post)
  - [ ] Validate all user inputs
  - [ ] Sanitize HTML in content
  - [ ] Add CSRF protection (Phoenix default)
  - [ ] Add rate limiting (via PhoenixKit.Users.RateLimiter)
  - [ ] Add content moderation hooks

- [ ] **6.5 Final Review**
  - [ ] Test all user flows (create, edit, delete, publish, schedule)
  - [ ] Test edge cases (max limits, empty states, errors)
  - [ ] Review UI consistency with PhoenixKit design
  - [ ] Verify settings all work correctly
  - [ ] Test with different post types
  - [ ] Test comment threading (deep nesting)
  - [ ] Test group assignments
  - [ ] Test media uploads

---

## 🔑 Key Design Decisions

1. **UUIDv7 for Posts** - Time-sortable IDs for better chronological indexing
2. **Denormalized Counters** - Cache likes/comments/views for performance (avoid COUNT queries)
3. **Unlimited Comment Nesting** - Depth field + recursive queries (Reddit-style threading)
4. **User-Specific Groups** - Each user manages their own collections (Pinterest model)
5. **Scheduled Publishing** - Via Oban background jobs (leverages V27 migration)
6. **Type-Specific Layouts** - Single schema, different UI per type (post/snippet/repost)
7. **Media Integration** - Use existing PhoenixKit.Modules.Storage system (no new file tables)
8. **Settings-Based Validation** - Dynamic limits from admin settings (flexible configuration)
9. **Soft Deletes** - Status field instead of hard deletes (enables moderation/recovery)
10. **SEO-Friendly** - Auto-generate slugs, support for scheduled publishing, unlisted posts

---

## 🚀 Migration Path

- **Current Version**: V27 (Oban + Storage System)
- **New Version**: V28 (Posts System)
- **Upgrade**: `mix phoenix_kit.update` (automatic)
- **Rollback**: Migration includes down/1 function
- **Safety**: Idempotent operations (safe to re-run)
- **Compatibility**: No breaking changes to existing features

---

## 📝 Notes

- **Phase 1** must be completed before Phase 2 (database foundation required)
- **Phase 2** and **Phase 3** can be developed in parallel (LiveView + Components)
- **Phase 4** can be added incrementally (background jobs are optional enhancements)
- **Phase 5** should be done continuously (documentation as you build)
- **Phase 6** is final polish before merging

---

## 🎨 UI/UX Considerations

### Post Types Display Differences

- **Post**: Full-width layout, large media gallery, full content
- **Snippet**: Compact card, single image, truncated content with "read more"
- **Repost**: Original source attribution, embedded preview, quoted content

### Comment Threading

- Indent nested comments with visual thread lines
- Collapse deep threads (e.g., depth > 3)
- "Load more replies" button for performance
- Highlight OP (original poster) comments

### Responsive Design

- Mobile: Stack images, single column
- Tablet: 2-column grid for post list
- Desktop: 3-column grid, sidebar filters

---

## ⚠️ Known Limitations & Future Enhancements

### Current Limitations

- View tracking not implemented (Phase 2)
- No real-time updates (WebSocket/Phoenix PubSub)
- No content moderation queue UI
- No spam detection
- No post drafts auto-save
- No post revisions/history

### Future Enhancements

- [ ] Real-time like/comment updates via PubSub
- [ ] Content moderation queue
- [ ] Spam detection (Akismet integration)
- [ ] Auto-save drafts (local storage)
- [ ] Post edit history
- [ ] Post bookmarks/favorites
- [ ] Advanced analytics dashboard
- [ ] Post recommendations
- [ ] RSS feeds per tag/group
- [ ] Export posts to PDF/Markdown

---

## 📞 Support & Contribution

For questions, issues, or contributions related to this module:

1. Check `README.md` for usage documentation
2. Review this `SPEC.md` for architecture details
3. See `CLAUDE.md` in project root for development workflow
4. Follow PhoenixKit's contribution guidelines

---

**Last Updated**: 2025-11-25
**Specification Version**: 1.0
**Target PhoenixKit Version**: 1.4.0+
