## 1.7.33 - 2026-02-04
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

