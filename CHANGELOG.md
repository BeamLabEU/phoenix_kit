## 1.7.43 - 2026-02-17
- Fix Language struct Access error on admin modules page and all bracket-access-on-struct bugs
- Add 20 typed structs replacing plain maps across billing, entities, sync, emails, AI, and dashboard
  - Billing: CheckoutSession, SetupSession, WebhookEventData, PaymentMethodInfo, ChargeResult, RefundResult, ProviderInfo
  - Other: AIModel, FieldType, EmailLogData, LegalFramework, PageType, Group, TableSchema, ColumnInfo, SitemapFile, TimelineEvent, IbanData, SessionFingerprint
- Fix guest checkout flow: relax NOT NULL on legacy integer FK columns, fix transaction error double-wrapping
- Add return_to login redirect support for seamless post-login navigation (e.g., guest checkout)
- Add cart merge on login for guest checkout sessions
- Fix shop module .id to .uuid migration in Storage image lookups and import modules
- Fix hardcoded "PhoenixKit" fallback in admin header project title
- Fix 2 dialyzer warnings in checkout session and UUID migration

## 1.7.42 - 2026-02-17
- Use PostgreSQL IF NOT EXISTS / IF EXISTS for UUID column operations
  - Replace manual column_exists? checks with native DDL guards in V56 and UUIDFKColumns
  - Makes migrations more robust and idempotent

## 1.7.41 - 2026-02-16
- Fix FK constraint creation crash when UUID target tables lack unique indexes
  - Ensure unique indexes on all FK-target uuid columns before adding FK constraints
  - Fixes `invalid_foreign_key` error on `phoenix_kit_ai_endpoints` and other tables

## 1.7.40 - 2026-02-16
- Remove redundant mb-4 wrapper div around back buttons in 4 admin pages
- Add V57 migration to repair missing UUID FK columns
- Update language filter to use languages_official instead of languages_spoken

## 1.7.39 - 2026-02-16
- Complete UUID migration (Pattern 2) across all remaining modules
  - Migrate posts, tickets, storage, comments, referrals, and connections schemas to UUID-based user references
  - Migrate posts like/dislike/mention functions to accept UUID user identifiers
  - Fix stale `.id` access across posts, storage, tickets, email, connections, and image downloader
  - Fix ProcessFileJob and media_detail to use user_uuid instead of deprecated user_id
  - Replace legacy `.id` access with `.uuid` across mix tasks and admin presence
  - Remove legacy integer fields from RoleAssignment schema
  - Fix 10 Dialyzer warnings across comments, connections, referrals, and shop modules
- Harden permissions system with security and correctness fixes
  - Fix security and correctness issues in permissions system
  - Add permission edit protection for own role and higher-authority roles
  - Add Owner protection to `can_edit_role_permissions/2` and standardize UUID usage
  - Fix edge cases, silent failures, and crash risks in permissions and roles
  - Fix dual-write in `set_permissions/3` and cross-view PubSub refresh
  - Fix permissions summary to count only visible keys
  - Fix multiple bugs in custom permission keys and admin routing
  - Add auto-grant of custom permission keys to Admin role
  - Add defensive input validation to custom permission key registration
  - Fix `unless/else` to `if/else` for Credo compliance
- Add gettext i18n to roles and permissions admin UI
- Add Level 1 test suite for permissions, roles, and scope (156 tests)
- Fix responsive header layout across all admin pages
  - Add responsive text classes (`text-2xl sm:text-4xl` / `text-base sm:text-lg`) to all page headers
  - Fix missed responsive text classes in storage, media selector, and publishing pages
- Replace dropdown action menus with inline buttons in table rows
- Fix require_module_access plug to check feature_enabled like LiveView on_mount
- Fix admin sidebar wipe when enabling/disabling modules
- Add `get_role_by_uuid/1` API and update integration guide
- Restore admin edit button in user dropdown and add product links in cart
- Fix selected_ids to use MapSet for O(1) lookups
- Fix Dialyzer CI failure for ExUnit.CaseTemplate test support files
- Fix Credo nesting and Dialyzer MapSet opaque type warnings
- Update Permissions Matrix page title and section labels

## 1.7.38 - 2026-02-15
- Fix Ecto.ChangeError in entities by using DateTime instead of NaiveDateTime
- Fix infinite recursion risk in category circular reference validation
- Add DateTime inconsistency audit report with phased migration plan
- Add custom permission key auto-registration for admin tabs
  - Custom admin tabs with non-built-in permission keys now auto-register with the permission system
  - Custom keys appear in the permission matrix and roles popup under "Custom" section
  - Owner role automatically gets access to custom permission keys
  - Custom LiveView permission enforcement via cached `:persistent_term` mapping
  - New API: `Permissions.register_custom_key/2`, `unregister_custom_key/1`, `custom_keys/0`, `clear_custom_keys/0`
  - Key validation: format check (`~r/^[a-z][a-z0-9_]*$/`), `ArgumentError` on built-in key collision

## 1.7.37 - 2026-02-15
- Fix UUID PR review issues: aliases, dashboard_assigns, and naming issues
- Fix V56 migration: add subscription_plans to uuid column setup lists
- Add admin edit buttons and improve shop catalog UX
- Add registry-driven admin navigation system
- Fix localized field validation in Shop forms
- And bunch of bugs and optimizations

## 1.7.36 - 2026-02-13
- Add storefront sidebar filters, category grid, and dashboard shop integration
  - New `CatalogSidebar` component: reusable sidebar with collapsible filter sections and category tree navigation
  - New `FilterHelpers` module: filter data loading, URL query string building, price/vendor/metadata filtering
  - Storefront filter configuration in admin settings: enable/disable filters, edit labels, add metadata option filters
  - Auto-discovery of filterable product metadata options (e.g., Size, Color) with one-click filter creation
  - Price range filter with min/max inputs and range display
  - Vendor and metadata option filters with checkbox selection and active count badges
  - Filter state persisted in URL query params for shareable filtered views
  - "Show Categories in Shop" setting: displays category card grid above products on main shop page
  - Sidebar category navigation always visible in sidebar (decoupled from grid setting)
  - Dashboard layout integration: shop filters and categories rendered in dashboard sidebar for authenticated users
  - `sidebar_after_shop` slot in dashboard layout for injecting custom sidebar content
  - Product detail page updated to use shared sidebar and filter context for consistent navigation
  - Mobile filter drawer with toggle button and active filter count badge
  - Category page filters scoped to category products
  - Fix `phx-value-value` collision on filter checkboxes: renamed to `phx-value-val` to avoid HTML checkbox `value="on"` overwrite
  - **Known issue**: metadata option filters (e.g., Size) may not filter correctly in all cases; needs further investigation
- Add file upload field type to Entities module
  - New `file` field type with configurable max entries, file size, and accepted formats
  - `FormBuilder` renders file upload UI with drag-and-drop zone (admin entity forms, placeholder)
  - New `:advanced` field category
- Fix 3 remaining UUID migration bugs in billing forms
- Fix 8 UUID migration bugs found in PR #330 post-merge review
- Add UUIDv7 migration V56 with dual-write support

## 1.7.35 - 2026-02-12
- Rewrite Sitemap module to sitemapindex architecture with per-module files
  - `/sitemap.xml` now returns a `<sitemapindex>` referencing per-module files at `/sitemaps/sitemap-{source}.xml`
  - Dual mode support: "Index mode" (per-module files, default) and "Flat mode" (single urlset when Router Discovery enabled)
  - New `Source` behaviour callbacks: `sitemap_filename/0` and `sub_sitemaps/1` for per-group file splitting
  - New `Generator.generate_all/1` and `generate_module/2` with auto-splitting at 50,000 URLs
  - FileStorage rewrite with `save_module/2`, `load_module/1`, `delete_module/1`, `list_module_files/0`
  - Cache rewrite supporting `{:module_xml, filename}` and `{:module_entries, source}` keys
  - Per-module stats stored as JSON in Settings with `get_module_stats/0`
  - Per-module regeneration via `SchedulerWorker.regenerate_module_now/1` (Oban)
  - Settings UI overhaul: per-module sitemap cards with stats, regeneration buttons, mode indicators
  - Publishing source: per-blog sub-sitemaps via `sitemap_publishing_split_by_group` setting
  - Entities source: per-entity-type sub-sitemaps
  - Static source: login page excluded, registration conditionally included
  - Router Discovery default changed to `false` (index mode is new default)
  - Removed "cards" XSL style; added `sitemap-index-minimal.xsl` and `sitemap-index-table.xsl`
  - Sitemap routes no longer go through `:browser` pipeline (public XML endpoints)
- Add PDF support for Storage module
  - New `PdfProcessor` module using `poppler-utils` (`pdftoppm`, `pdfinfo`)
  - First page rendered to JPEG thumbnail at configurable DPI
  - PDF metadata extraction (page count, title, author, creator, creation date)
  - `VariantGenerator` extended for document/PDF MIME types
  - Media UI: inline PDF viewer on detail page, PDF badges on thumbnails, metadata display
  - New system dependency checks for poppler in `Dependencies` module
- Fix option price display for options with all-zero modifiers
  - New `has_nonzero_modifiers?/1` filters out option groups where all price modifiers are zero
  - Price modifiers displayed as badges on option buttons (e.g., "+$5.00")
  - Cart saves all selected specs including non-price-affecting options (e.g., Color)
  - `build_cart_display_name/3` includes all selected specs in display name
- Fix category icons fallback to legacy product images
  - `Category.get_image_url/2` falls back to `featured_product.featured_image` (legacy URL)
  - Product detail respects `shop_category_icon_mode` setting for category subtab icons
  - Guard clauses tightened for Storage vs legacy URL handling
- Add ImportConfig filtering at CSV preview stage
  - Config filters applied during CSV analysis/preview, not just during import
  - Import wizard shows skipped product count with warning badge
  - Category creation uses language normalization for consistent JSONB slug keys
  - Imported option labels use `_option_slots` metadata for proper display names
- Fix admin sidebar full-page reload after upstream merge
  - Comments and Sync routes merged into main admin `live_session`
- Add runtime sitemaps directory to gitignore

## 1.7.34 - 2026-02-11
- Extract Comments into standalone reusable module (V55 migration)
  - New `PhoenixKit.Modules.Comments` context with polymorphic `resource_type` + `resource_id` associations
  - New tables: `phoenix_kit_comments`, `phoenix_kit_comments_likes`, `phoenix_kit_comments_dislikes`
  - Reusable `CommentsComponent` LiveComponent that can be embedded in any resource detail page
  - Threaded comments with configurable max depth and content length
  - Like/dislike system with atomic counter cache
  - Moderation admin UI at `{prefix}/admin/comments` with filters, search, and bulk actions
  - Module settings page at `{prefix}/admin/settings/comments`
  - Resource handler callback system for notifying parent modules (e.g., Posts) of comment changes
  - "comments" permission key added (25 total permission keys, 20 feature modules)
  - Posts module refactored to consume Comments module API instead of inline implementation
  - Legacy `phoenix_kit_post_comments` tables preserved for backward compatibility
- Add shop enhancements, sitemap sources, and admin navigation fix
  - Shop module improvements: product options toggle, import configs, drag-and-drop reordering, catalog language redirects
  - Sitemap module: shop source (categories, products, catalog), data source toggles in settings UI
  - Admin sidebar seamless navigation (consolidate live_sessions)
  - Migration fixes and V54 addition
- Fix preview-to-editor round-trip state and data loss bugs
  - Fix 8 bugs in the preview_token handle_params path that had diverged from the other editor entry points as features were added over time
  - Merge disk metadata into preview post to prevent silent data loss when saving after a preview round-trip
  - Add error logging to enrich_from_disk for observability
- Add module-level permission system for role-based admin access control
  - Custom roles can now be granted granular access to specific admin sections and feature modules. Permissions are managed through a new interactive matrix UI, enforced at both route and sidebar level, and update in real-time across all admin tabs via PubSub.

## 1.7.33 - 2026-02-04
- Add module-level permission system (V53 migration)
  - `phoenix_kit_role_permissions` table with allowlist model (row present = granted)
  - 24 permission keys: 5 core sections + 19 feature modules
  - Owner bypasses all checks; Admin seeded with all 24 keys by default
  - Custom roles start with no permissions, assigned via matrix UI or API
  - `PhoenixKit.Users.Permissions` context for granting, revoking, and querying role permissions
  - Interactive permission matrix at `{prefix}/admin/users/permissions`
  - Inline permission editor in Roles page with grant/revoke all
  - Route-level enforcement via `phoenix_kit_ensure_admin` and `phoenix_kit_ensure_module_access`
  - Sidebar nav gated per-user based on granted permissions
  - Real-time PubSub updates: permission changes reflect across all admin tabs
  - Backward compatible: pre-existing Admins retain full access before V53 migration
- Add PubSub events for real-time updates in Tickets and Shop modules
  - Tickets.Events module with broadcast for ticket lifecycle (created, updated, status changed, assigned, priority changed)
  - Comment and internal note events for ticket discussions
  - Shop.Events extension with product, category, inventory events
  - LiveViews subscribe to events for real-time UI updates
- Add User Deletion API with GDPR-compliant data handling
  - delete_user/2 with cascade delete for related data (tokens, OAuth, billing profiles, carts)
  - Anonymization strategy for orders, posts, comments, tickets, email logs, files
  - Protection: cannot delete self, cannot delete last Owner
  - Admin UI with delete button, confirmation modal, and real-time list updates
  - Broadcast :user_deleted event for multi-admin synchronization
- Fix compilation errors in auth.ex (pin operator with dynamic Ecto queries)
- Update core PhoenixKit schemas and Referrals to new UUID standard
- Update Shop module with localized slug support and unified image gallery
- Add PubSub events for Tickets and Shop modules, User Deletion API
- Added support for uuid to referral module
- Add markdown rendering and bucket access types
- Update Sync module to new UUID standard pattern
- Update billing module to use DB-generated UUIDs
- Update entities module to UUID standard matching AI module

## 1.7.32 - 2026-02-03
- Storage Module: Smart file serving with bucket access types (V50 migration)
  - Add `access_type` field to buckets: "public", "private", "signed"
  - Local files are now served directly without temp file copying (performance improvement)
  - Public cloud buckets redirect to CDN URL (faster, reduces server load)
  - Private cloud buckets proxy files through server (for ACL-protected storage)
  - Add retry logic for bucket cache race conditions during file access

  **⚠️ BREAKING CHANGE: Cloud Bucket Access Type**

  Cloud buckets (S3, B2, R2) now default to `access_type = "public"`, which redirects
  users directly to the bucket's public URL instead of proxying through the server.

  **If you have private/ACL-protected buckets:**
  - Go to Storage → Buckets → Edit your bucket
  - Set "Access Type" to "Private"
  - Files will be proxied through the server using credentials (previous behavior)

  **If you have public buckets (redirect mode):**

  For redirect to work, your bucket must be publicly accessible:

  1. **Enable Public Access** in your cloud provider settings:
     - AWS S3: Disable "Block all public access" and set bucket policy
     - Backblaze B2: Set bucket to "Public"
     - Cloudflare R2: Configure public access or use Custom Domain

  2. **Configure CORS** if serving files cross-origin (required when your site
     domain differs from bucket domain):

     AWS S3 / R2 CORS configuration example:
     ```json
     [
       {
         "AllowedHeaders": ["*"],
         "AllowedMethods": ["GET", "HEAD"],
         "AllowedOrigins": ["https://yourdomain.com"],
         "ExposeHeaders": ["ETag", "Content-Length"],
         "MaxAgeSeconds": 3600
       }
     ]
     ```

     Replace `https://yourdomain.com` with your actual domain, or use `"*"` for
     any origin (less secure but simpler for testing).

  See AWS documentation: https://docs.aws.amazon.com/AmazonS3/latest/userguide/enabling-cors-examples.html

## 1.7.31 - 2026-01-29
- Refactor publishing module into submodules and improve URL slug handling
  - Storage module refactoring:
    - Split storage.ex into specialized submodules: Paths, Languages, Slugs, Versions, Deletion, and Helpers for better organization and maintainability
    - Move controller logic into submodules: Fallback, Language, Listing, PostFetching, PostRendering, Routing, SlugResolution, Translations
    - Move editor logic into submodules: Collaborative, Forms, Helpers, Persistence, Preview, Translation, Versions
  - Listing page improvements:
    - Show live version's translations and statuses instead of latest version
    - Fetch languages from filesystem when version_languages cache is empty
    - Fix paths to point to live version files when clicking language buttons
    - Add "showing vN" badge that combines with version count display
    - Fix public URL to always use post's primary language
  - URL slug priority system:
    - Directory slugs now have priority over custom url_slugs
    - Prevent setting url_slug that conflicts with another post's directory name
    - Auto-clear conflicting url_slugs instead of blocking saves
    - Show info notice when url_slugs are auto-cleared due to conflicts
    - Clear conflicting url_slugs from ALL translations, not just current one
    - Clear conflicting custom url_slugs when new post is created

## 1.7.30 - 2026-01-28
- Posts Module
  - Add likes and dislikes system for post comments (V48 migration)
  - Post body field is no longer required
- User Management
  - Add dropdown field type support for user custom fields
- Shop Module (E-commerce)
  - Fix JSONB search queries and add defensive guards for robustness
  - Fix JSONB localized fields consistency across product/category operations
  - Add shop import enhancements with V49 migration
  - Fix image migration robustness and catalog display issues
  - Add language selection dropdown to CSV import for localized content
  - Add variant image mapping support for Shop products
  - Add legacy image support for backward-compatible variant mappings
- Bug Fixes
  - Fix UUID column error for auth tables during upgrade - Users upgrading from PhoenixKit < 1.7.0 no longer get "column uuid does not exist" error when logging in. Added auth tables (users, tokens, roles, role_assignments) to UUIDRepair module.

## 1.7.29 - 2026-01-26
- Add primary language improvements and AI translation progress tracking
  - Real-time translation progress - Added progress bars to editor and listing pages showing AI translation status
  - Primary language improvements - Posts now store their primary language for isolation from global setting changes
  - Language handling fixes - Fixed base code to dialect mapping (e.g., en → en-US) across public URLs and editor
  - UI polish - Updated language switcher colors, modal text, and added prominent primary language display in editor
  - Documentation - Added comprehensive README for the Languages module

## 1.7.28 - 2026-01-24
- Major improvements to the Publishing module's multi-language workflow: renamed "master" to "primary" terminology, fixed URL routing with locales, added language migration tools, improved cache performance, and fixed several UI/UX issues in settings and admin pages.
  - Multi-Language System Improvements
    - Rename master to primary terminology - Updated all references from "master language" to "primary language" for consistency and clarity
    - Fix language in URL breaking navigation - Resolved issues where locale prefixes in URLs caused routing problems
    - Isolate posts from global primary_language changes - Posts now store their own primary language, preventing drift when global settings change
    - Add "Translate to This Language" button - Quick translation action for non-primary languages in the editor
    - Sort languages in dropdowns - Consistent alphabetical sorting across all language selectors
  - Migration Tools
    - Add version structure migration UI - Visual indicators and migration buttons throughout the publishing module
    - Fix legacy post migration - Resolved "post not found" errors when migrating from legacy to versioned structure
    - Handle dual directory structures - Fixed migration when both publishing/ and blogging/ directories exist
    - Add primary language migration system - Tools to migrate posts to use isolated primary language settings
  - Performance
    - Improve listing performance - Read from cache when possible, reducing database/filesystem hits
    - Language caching with WebSocket transport - Faster language resolution with proper cache invalidation
    - Add Create Group shortcut - Quick access button on publishing overview page
  - Settings & Admin UI Fixes
    - Fix General settings content language glitch - Resolved weird UI behavior when changing content language
    - Fix settings tab highlighting - General and Languages tabs now properly highlight on child pages
    - Fix admin header dropdowns - Theme and language dropdowns in admin header now work correctly
    - Update Entities module description - Clearer description on the Modules page
- Updated the languages module added front and backend tabs for languages
- Add localized routes for Shop module
  - Add locale-prefixed routes (/:locale/shop/...) for multi-language Shop module support
  - Add language validation to only allow enabled languages in URLs
  - Add language preview switcher for admin product detail page


## 1.7.27 - 2026-01-19
- Changed / Added
  - Added prefix-aware navigation helpers and dynamic URL prefix support across dashboard, tabs, auth pages, and project home URLs, fixing issues when locale or prefix is nil.
  - Introduced comprehensive dashboard branding and theming:
    - Configurable branding, title suffix, and logo handling.
    - Shared theme controller with daisyUI integration, color scheme guide, and improved theme switcher placement.
  - Enhanced dashboard navigation:
    - Configurable subtab styling, redirects, highlights, and mobile subtab support.
    - Multiple context selectors with dependency support.
    - Reserved additional locale path segments for dashboard and users.
  - Added context-aware features:
    - Context-aware badges with update helpers, guards for nil contexts, and improved preservation during tab refresh.
    - Consistent context-aware merge behavior.
  - Improved authentication and user setup:
    - Added fetch_phoenix_kit_current_user to the auto-setup pipeline.
    - Fixed auth pages and titles to use centralized Settings/Config branding.
  - Performance and quality improvements:
    - Optimized Presence and Config modules to reduce repeated checks and lookups.
    - Added dashboard_assigns/1 helper to prevent unnecessary layout re-rendering.
    - Fixed hardcoded branding and paths to rely on configuration fallbacks.
  - Documentation updates:
    - Added guides for dashboard theming, tab path formats, subtab behavior, and context selectors.
    - Added prominent built-in features section and reduced overall documentation size.
- Maintenance:
  - Fixed Credo/Dialyzer issues, formatting problems, and test failures.
  - Cleaned up unused Dialyzer ignores and added ignores for test support files.

## 1.7.26 - 2026-01-18
- Language switcher fix

## 1.7.25 - 2026-01-16
- Bug fix - Added check for nil on language_swithcer on log-in page

## 1.7.24 - 2026-01-15
- Add Shop module with products, categories, cart, and checkout flow
- Add user billing profiles for reusable billing information
- Add payment options selection in checkout (bank transfer, card payment)
- Add user order pages with UUID-based URLs
- Add PubSub broadcasts to Billing module for real-time updates
- Add automatic default currency for orders
- Add Billing and Shop tabs to user dashboard tab system
- Add automatic dashboard tabs refresh when modules are enabled/disabled
- Fix user dashboard layout sidebar height calculation
- Fix OAuth avatar display in admin navigation

## 1.7.23 - 2026-01-14
- Added user functions, language switcher on login page (also support for Estonian and Russian on login)
- Removed logs spamming about oban jobs

## 1.7.22 - 2026-01-13
- Add AWS config module with centralized credential management
- Add context selector for multi-tenant dashboard navigation
- Add comprehensive user dashboard tab system with CLI generator
- Consolidate Publishing module into self-contained structure
- Publishing Module: Versioning, AI Translation, Per-Language URLs & Real-time Updates
- Fixed referralcodes to referrals for more universal code


## 1.7.21 - 2026-01-10
- Publishing Module: Versioning, AI Translation, Per-Language URLs & Real-time Updates
- Fixed referralcodes to referrals for more universal code
- Consolidate OAuth config through Config.UeberAuth abstraction

## 1.7.20 - 2026-01-09
- Fix user avatar fallback when Gravatar is unavailable
- Fixed issues with phx_kit install
- Add scheduled job cancellation when disabling modules
- Fix race condition in file controller for parallel requests

## 1.7.19 - 2026-01-07
We are doing code cleanup and refactoring to move forward with more new modules and more features:
- Moved referral_codes module to correct location lib/modules and fixed issue with install not working
- Standardize admin UI styling and add reusable components
- Move Emails module to lib/modules/emails with PhoenixKit.Modules.Emails namespace
- Migrate Entities, AI, and Blogging modules to lib/modules/ with PhoenixKit.Modules namespace
- Updated the javascript usage to not create userspace javascript files
- Move Sitemap and Billing modules to lib/modules/ with consolidated namespace
- Move DB and Sync modules to lib/modules/ with PhoenixKit.Modules namespace
- Moved posts module files to lib/modules folder
- Add DB Explorer module 

## 1.7.18 - 2026-01-03

- Blog Versioning, Caching System, and Complete Programmatic API
- Add Cookie Consent Widget (Legal Module Phase 2)
- Add Legal module improvements and cookie consent enhancements

