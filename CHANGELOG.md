## 1.7.94 - 2026-04-10

### Added
- Media folder system with sidebar, select mode, list/grid view, drag-drop file moving
- Folder colors, inline rename, select folders, and context menus
- Search bar and folder path column to media page
- Media Health page for redundancy monitoring
- Sync with progress tracking, pause/resume/stop controls, real-time sync log
- Media sync moved to Oban worker for persistence and reliability
- Multipart S3 uploads
- Tigris storage provider support
- Test Connection button to bucket form
- Configurable max upload size setting
- Reusable SearchableSelect LiveComponent
- Provider-specific labels for B2, R2, and S3 bucket configuration
- AWS regions dropdown via `aws_regions` hex package

### Changed
- Rename Storage to Media, use thumbnail variant for media grid
- Redesign media sidebar with proper file explorer conventions
- Migrate bucket and dimensions tables to `table_default` component
- Restyle bucket/dimension forms with card sections and DaisyUI 5 fieldset/legend
- Persist folder tree expand state and sidebar collapsed in localStorage
- Remove LLMText module (preserved in feature/llmtext branch)
- Remove CDN URL field from bucket configuration form

### Fixed
- Fix #478: register CSS sources compiler and create stub file on install
- Fix integration activity logs always having nil actor_uuid
- Fix S3 upload failures and false file location records
- Fix folder card hover lag (use `transition-colors` instead of `transition-all`)
- Fix folder name truncation, rename animation, and input autofocus
- Fix select mode content jump and improve render performance
- Fix mix tasks: `Routes.path` unavailable, `ecto.migrate` skips host repo
- Fix OAuth users getting signed out after ~1-2 hours

## 1.7.93 - 2026-04-08

### Fixed
- Fix installer to auto-inject PhoenixKitHooks into app.js
- Fix decrypt after legacy integration migration
- Improve OAuth login with remember_me by default

### Added
- Activity logging for Integrations (setup, connect, disconnect, token refresh, validation)
- Cookie max_age set to 60 days

### Changed
- Simplify integration status: `configured` removed, now `connected` or `disconnected`
- Validate connection checks provider exists before credentials

## 1.7.92 - 2026-04-07

### Fixed
- Fix Google token refresh for named integration connections (e.g. google:work)
- Add resolve_provider_lookup_key/2 and resolve_storage_key/2 helpers

### Added
- Add V94 migration for Document Creator sync (google_doc_id, status, path, folder_id columns)

## 1.7.91 - 2026-04-06

### Added
- Add centralized Integrations system for external service connections (OAuth, API keys, bot tokens)
- Add AES-256-GCM encryption at rest for stored credentials
- Add OAuth 2.0 CSRF state parameter protection
- Add `required_integrations/0` and `integration_providers/0` callbacks to PhoenixKit.Module
- Add IntegrationPicker reusable component
- Add Integrations admin settings tab
- Add provider registry with Google and OpenRouter built-in

### Fixed
- Fix password field overwrite bug when editing integrations
- Fix duplicate line in `maybe_set_userinfo/2`
- Consolidate validation logic into Integrations context
- Make validation URL provider-configurable (no more hardcoded Telegram URL)

## 1.7.90 - 2026-04-04

### Added
- Add organization accounts support with person/organization user types
- Add organization invitations system with token-based invite flow
- Add V91 locations migration: location types, locations, and type assignments tables
- Add V92 organization accounts migration (invitations, user type fields)
- Add JS hooks integration for parent app install and update workflows
- Add LLMText module for AI/LLM-friendly content generation
- Add auth logo from settings to admin header
- Add billing tabs component

### Changed
- Move tax rate and CountryData from Billing to core PhoenixKit
- Remove hardcoded Billing and E-Commerce module cards in favor of auto-discovery
- Update AGENTS.md with severity level definitions and JS hooks documentation

### Fixed
- Fix double sidebar for core modules and improve struct compatibility
- Hide hamburger menu button when sidebar is permanently visible
- Fix token security, gettext, and validation issues in organization invitations
- Fix tax data loss, invitation status guard, and IbanData safety

## 1.7.88 - 2026-04-02

### Changed
- Migrate select elements to daisyUI 5 label wrapper pattern (#472)

### Fixed
- Fix negated condition in maintenance toggle flash message
- Fix dialyzer warnings for CSS sources compiler, clean up 6 stale ignore entries

## 1.7.87 - 2026-03-31

### Added
- Add V89 migration: catalogue pricing with base_price and markup_percentage
- Add status_badge component and wrapper_class attr to table_default
- Add inline and auto display modes to table_row_menu
- Add show_toggle attr to table_default and sync TableCardView instances
- Add continent grouping to language switcher for many languages
- Add language system tests, docs, error handling, and group_by_continent option

### Changed
- Unify admin and frontend language systems into single source of truth
- Unify status badge components into single status_badge
- Remove deprecated select-bordered class for daisyUI 5 compatibility
- Disable automatic CI triggers, switch to manual-only

### Fixed
- Fix language switcher URL generation for prefixed admin paths
- Fix dialyzer warnings in language switcher URL generation

## 1.7.86 - 2026-03-30

### Changed
- Update Shop module references from `PhoenixKit.Modules.Shop` to `PhoenixKitEcommerce` namespace
- Update Billing module references from `PhoenixKit.Modules.Billing` to `PhoenixKitBilling` namespace
- Restore LayoutWrapper in core module templates (not auto-applied to bundled modules)
- Document `extra_applications` requirement for external module auto-discovery

### Fixed
- Fix missing `url_path` assign in referrals LiveViews causing runtime crash after LayoutWrapper restoration
- Fix media selector modal mobile responsiveness (header overflow, button sizing, padding)

## 1.7.85 - 2026-03-30

### Added
- Add user-scoped media selector for avatar and fix custom fields position bug

### Changed
- Remove Pages module from core and clean up all references
- Extract Connections module into external `phoenix_kit_user_connections` package
- Remove unused Storage alias from user settings

## 1.7.84 - 2026-03-28

### Added
- Add missing cookie consent widget to dashboard layout
- Add user dashboard routes for billing profiles

### Changed
- Remove Legal module from core (extracted to `phoenix_kit_legal` package)
- Remove LayoutWrapper from remaining storage and maintenance templates
- Remove duplicate LayoutWrapper from admin module templates

### Fixed
- Fix core modules misclassified as external plugin views causing double admin chrome

## 1.7.83 - 2026-03-27

### Added
- Add V88 migration: Publishing schema V2 restructure
- Add user dashboard generator with LiveView templates and standardize layout
- Add `--index` flag to user dashboard generator for overriding default dashboard
- Add Estonian to backend languages, fix Chinese code zh-CN → zh
- Add CountryData to core utils for billing extraction
- Add sitemap scheduler startup recovery

### Changed
- Extract Comments module into external `phoenix_kit_comments` package
- Remove Shop module from core (extracted to `phoenix_kit_ecommerce` package)
- Remove Billing module from core (extracted to `phoenix_kit_billing` package)
- Replace hardcoded external module stats with generic `module_stats` callback
- Remove hardcoded module cards for extracted packages
- Rename and simplify admin page generator
- Update Leaf dependency to v0.2.6

### Fixed
- Fix V88 migration: index prefix and partial re-run safety
- Fix orphan files query to use `publishing_versions` table
- Fix post-review issues from PR #453: Shop.Cart guard, consent attrs, language naming
- Fix shop modules: remove billing struct patterns and fix nil clause ordering
- Fix double navbar on comments admin pages
- Fix auth page background breaking footer and page layout

## 1.7.82 - 2026-03-24

### Added
- Add V86 migration: Document Creator tables (headers_footers, templates, documents)
- Add V87 migration: Catalogue tables (manufacturers, suppliers, catalogues, categories, items)
- Add `system_prompt` field to AI prompts and AI Playground page
- Add database connection check to install and update tasks
- Add AdminEditHelper for universal admin edit links in public views
- Add email provider behaviour, refactor Mailer and UserNotifier
- Add lastmod to sitemap group listings and homepage
- Enrich external module cards with config stats, settings link, and `module_card` component

### Changed
- Extract Emails module from core to standalone `phoenix_kit_emails` package
- Extract Publishing module to standalone `phoenix_kit_publishing` package
- Extract Entities module to standalone `phoenix_kit_entities` package
- Extract AI module to standalone `phoenix_kit_ai` package
- Remove hardcoded Emails block from Modules page — now rendered as external package
- Guard all Publishing references behind `Code.ensure_loaded?` for external module support
- Guard EntityForm render call with `Code.ensure_loaded?` check in Pages renderer
- Suppress warnings for optional external modules with `@compile :no_warn_undefined`
- Exclude external module namespaces from Credo alias usage check
- Make module registry and permissions tests count-independent after module extractions
- Document `ensure_compiled` vs `ensure_loaded?` choice in integration route collection
- Update Leaf dependency to v0.2.5

### Fixed
- Fix V86/V87 migrations to use `uuid_generate_v7()` instead of `gen_random_uuid()`
- Fix post-merge issues from Emails extraction
- Fix `extract_admin_links`: skip parent tabs, deduplicate paths
- Fix `external_plugin_view?` to recognize `PhoenixKit.Modules.*.Web` as external packages
- Fix DbConnectionCheck: correct spec, naming, and remove hard exit from status task
- Fix media selector modal z-index to appear above all overlays
- Fix `module_card` to render `hero-*` icons properly
- Fix cookie consent: dynamic legal links, theme-aware backdrop, daisyUI toggle

## 1.7.81 - 2026-03-21

### Changed
- Extract Posts module to standalone `phoenix_kit_posts` package
- Update Comments module to conditionally load Posts handler via `Code.ensure_loaded?/1`
- Update scheduled jobs worker with extracted catch-up helpers for optional Posts dispatch

## 1.7.80 - 2026-03-20

### Added
- Add `uuid` type to custom fields system
- Add auto-registration of custom field definitions on save with type inference

### Changed
- Extract Sync module to standalone `phoenix_kit_sync` package
- Move custom fields domain logic to `CustomFields` module, deduplicate UUID regex, add error logging
- Fix permissions table style — replace manual zebra striping with daisyUI `table-zebra`, use primary-colored header

### Fixed
- Fix avatar upload handling and `custom_fields` preservation in UserSettings
- Fix admin page and user dashboard styles
- Fix plugin reference name in module system guide

## 1.7.79 - 2026-03-20

### Fixed
- Fix UserSettings regressions from PR #436 redesign:
  - Restore timezone selector (timezone select, mismatch warning, browser detection)
  - Restore Apple OAuth provider icon (`hero-device-phone-mobile`)
  - Restore OAuth-only password warning for users without passwords
  - Restore provider email display in connected accounts list
  - Fix custom field `select` using index-based values instead of actual option values (data compatibility break)
  - Restore all custom field input types (`textarea`, `number`, `email`, `url`, `date`) — were collapsed to plain text
  - Restore `required` attribute on custom field inputs
  - Restore unique `id` attributes on password/email form hidden inputs
  - Restore profile/avatar success and error messages in template
  - Fix `shadow-xl` → `shadow-sm` for card styling consistency
  - Fix divider placement — move out of username field, add "Additional Information" heading for custom fields
  - Extract `extract_custom_fields/1` and `merge_custom_fields/3` helpers to DRY duplicated logic

## 1.7.78 - 2026-03-18

### Added
- Add Tailwind/daisyUI class injection for markdown rendering — replaces inline `<style>` block with classes injected during Earmark post-processing (works without `@tailwindcss/typography` plugin)
- Add blank line preservation in markdown content — intentional double blank lines render as visible spacing
- Add translation worker retry resilience — on retry, already-translated languages are skipped by checking content timestamps against job `inserted_at`
- Add dynamic timeout scaling for translation worker (~1.5 min per language, minimum 15 minutes)
- Add structured logging with consistent prefixes (`[Sync.Notifier]`, `[Sync.API]`, `[Sync.Connections]`) throughout Sync connection flow
- Add connection event logging on both sender and receiver sides for debugging

### Changed
- Rename Sync "Sender/Receiver" terminology to "Outgoing/Incoming" across UI
- Allow editing incoming Sync connections (previously restricted to outgoing only)
- Remove "with permanent connections" from Sync index page subtitle
- Bump markdown render cache version to v2 to invalidate stale cached HTML

### Fixed
- Fix Sync sender URL resolving to `localhost:4000` — now checks DB `site_url` setting before falling back to endpoint config
- Fix `auth_token_hash` logged in full — truncate to first 8 characters in Sync connection logs
- Fix double `get_our_site_url()` call per notification — pass resolved URL instead of recomputing
- Fix Sync crash on non-UTF8 binary data — base64-encode raw binaries during serialization, decode on import
- Fix Sync pull error responses silently ignored — add `Logger.error` to all failure paths (401, 404, HTTP errors, offline, invalid response)
- Fix Sync completion UI not showing skipped/errored records — track and display per-table import counts with warning state

## 1.7.77 - 2026-03-17

### Added
- Add Open Graph and Twitter Card meta tags for public publishing pages (og:title, og:description, og:image, og:url, og:locale, canonical link, and Twitter Card tags)
- Add `og:site_name` meta tag using project title
- Add `resolve_language_key/2` helper to `LanguageHelpers` for base code to dialect code matching in language maps
- Add Tailwind Typography prose overrides using daisyUI theme variables (oklch(--bc), oklch(--p), oklch(--b2), oklch(--b3)) for theme-aware markdown styling
- Add automated scheduled jobs cleanup to prevent table bloat (deletes completed jobs older than 7 days)
- Add `lastmod` (last modified) to sitemap entries for SEO — router-discovered routes use beam file mtime, static entries use current date

### Changed
- Replace inline markdown CSS with centralized prose overrides in `app.css` using `@layer base` (removes 323 lines of duplication)
- Update publishing preview template to show full public interface with working language switcher
- Move `MarkdownContent` component to use Tailwind prose classes instead of custom inline styles
- Extract duplicated `resolve_language_key/2` from `listing.ex` and `html.ex` to shared `LanguageHelpers` module
- Extract `update_post_from_form/3` from publishing editor to reduce cyclomatic complexity (from >10 to <10)
- Update Leaf content editor dependency from v0.1.0 to v0.2.0

### Fixed
- Fix `mix phoenix_kit.status` showing V01 instead of actual migration version — properly start Repo with parent app config when using `--no-start`
- Fix language map lookup when canonical URL uses base code (e.g., "en" → "en-US" matching)
- Fix `absolute_url/2` to use stricter URL protocol checking ("http://" or "https://" instead of just "http")
- Fix preview language links to conditionally include version parameter only when version is non-nil
- Fix translation reload showing primary language content instead of translated content
- Fix PubSub subscription mismatch for translation and version events on timestamp-mode posts (slug vs uuid topic mismatch)
- Fix email template seeding failing on fresh install (wrap string fields in i18n maps)
- Fix whitespace in slug format examples on publishing group pages

## 1.7.76 - 2026-03-16

### Fixed
- Fix `mix phoenix_kit.status` port conflict when app is already running (use `--no-start` to avoid booting the HTTP endpoint)
- Add self-healing version comment detection — automatically corrects V83 comment bug where migrations ran but version stayed at V82

## 1.7.75 - 2026-03-16

### Added
- Add `custom_fields` support to `registration_changeset/3` for atomic user creation with custom metadata
- Add entity data view extension documentation and route override pattern

### Fixed
- Fix mobile overflow issues in email module UI (queue, blocklist, metrics, template editor)
- Fix early validation in template editor — errors only shown after first user interaction
- Fix Send Test Email modal overflowing on mobile (max-w-4xl → max-w-2xl)
- Fix V83 migration missing `down/1` version comment rollback
- Fix V83 migration prefix_str inconsistency in version comment
- Fix dialyzer `guard_fail` warnings from upstream publishing merge
- Fix remaining doc warnings for delegated hidden functions

## 1.7.74 - 2026-03-16

### Fixed
- Remove dead `should_regenerate_cache?/1` from Shared module (uncalled function returning `true` in every branch)
- Remove obsolete `bulk_operation_topic` test referencing deleted PubSub function
- Fix missing trailing newline in `shared.ex`

## 1.7.73 - 2026-03-13

### Changed
- Move module access guards from individual mount functions to centralized `enforce_admin_view_permission` hook
- Disabled modules now block all roles (including Owner/Admin) at the `on_mount` level, covering all ~50 admin LiveViews automatically
- Remove per-LiveView `enabled?()` mount guards from AI, Entities, Publishing, Sitemap, Billing, Customer Service, Emails, Email Tracking, Legal, Referrals, Shop settings

## 1.7.72 - 2026-03-13

### Added
- Add module access guards — disabled modules now hide action buttons and block mount on settings/endpoints
- Add error flash auto-dismiss after 8 seconds
- Add `enabled?()` mount guards to AI, Media, Entities, Publishing, Sitemap endpoints
- Add error logging in Legal `list_generated_pages` instead of silent rescue

### Fixed
- Fix Legal module broken connection with DB-backed Publishing (`post.path` → `post.uuid`, `updated_at` → `published_at`)
- Fix Legal module Configure button guard when module is disabled
- Fix Sitemap RouterDiscovery including routes from disabled modules
- Fix DB.Listener missing `{:eventually, _ref}` case for auto_reconnect

### Changed
- Remove duplicate enable/disable toggles from 7 module settings pages (Emails, Email Tracking, Legal, Referrals, Billing, Customer Service, Shop)
- Simplify primary_language lookup in Publishing.DBStorage

## 1.7.71 - 2026-03-12

### Fixed
- Fix mixed atom/string key error in `EntityData.maybe_add_position/1` when auto-assigning position to string-keyed params
- Fix same mixed key error in `EntityData.maybe_add_created_by/1`
- Fix `FOR UPDATE` with aggregate function error in `EntityData.next_position/1` (PostgreSQL `0A000 feature_not_supported`)

## 1.7.70 - 2026-03-12

### Added
- Add PhoenixKitGlobals component for JavaScript globals injection
- Add metadata JSONB field to comments schema (V82 migration)
- Add reply indicators to admin comments page
- Add test comments seed script for visual verification
- Add admin page generator category index pages with automatic route registration
- Add duplicate validation (ID, URL, label) to admin page generator
- Add compile-time warning for unresolved legacy admin LiveView modules
- Add `phoenix_kit_app_base/0` helper to Routes utility

### Fixed
- Fix dimension form inputs clearing each other on change
- Fix MarkdownEditor toolbar not working on LiveView navigation
- Fix CommentsComponent crash on post details page (`resource_id` → `resource_uuid`)
- Fix credo alias ordering in integration module
- Fix WebP transparency loss in center-crop image processing
- Fix 304 Not Modified support in FileController

### Changed
- Update admin page generator to use flat `admin_dashboard_tabs` config with `live_view` field
- Deprecate legacy `admin_dashboard_categories` config format (warning on use)
- Auto-infer LiveView modules from URL paths for legacy admin categories
- Add `attr :rest, :global` to `phoenix_kit_globals` component

## 1.7.69 - 2026-03-10
- Add responsive multi-column card grid to `table_default` component: 1 col on mobile, 2 cols on md, 3 cols on lg breakpoints
- Style card view cards with `bg-base-200` and `shadow-sm` to visually distinguish them from the page background

## 1.7.68 - 2026-03-10
- Merge upstream changes: publishing editor rework, AI translation, bulk group actions, V77/V78 migration fixes, scheduled jobs queue, Settings.Queries module, plugin migration callbacks

## 1.7.67 - 2026-03-10

### Breaking Changes (requires manual steps in parent app)
- V79 migration rewritten in-place: drops `phoenix_kit_mailing_*` tables, creates `phoenix_kit_newsletters_*`
- Oban queue renamed: `mailing_delivery` → `newsletters_delivery` (update `config/config.exs`)
- Settings keys changed: `mailing_enabled` → `newsletters_enabled`, `mailing_default_template` → `newsletters_default_template`, `mailing_rate_limit` → `newsletters_rate_limit`
- Email template category value changed: `"mailing"` → `"newsletters"` (existing templates need DB update)
- URL paths changed: `/admin/mailing/*` → `/admin/newsletters/*`, `/mailing/unsubscribe` → `/newsletters/unsubscribe`

### Changed
- Rename `PhoenixKit.Modules.Mailing` → `PhoenixKit.Modules.Newsletters` and all submodules
- Rename DB tables: `phoenix_kit_mailing_lists/list_members/broadcasts/deliveries` → `phoenix_kit_newsletters_*`
- Rename Elixir modules: `Mailing.List`, `Mailing.Broadcast`, `Mailing.Delivery`, `Mailing.ListMember`, `Mailing.Broadcaster`, `Mailing.Workers.DeliveryWorker` → `Newsletters.*`
- Rename web modules: `Mailing.Web.*` → `Newsletters.Web.*`
- Rename route module: `PhoenixKitWeb.Routes.MailingRoutes` → `NewslettersRoutes`
- Rename dashboard tabs: `:admin_mailing` → `:admin_newsletters`

## 1.7.66 - 2026-03-09
- Clean up publishing module: fix UUID routing bugs (slug vs UUID in version creation, PubSub broadcasts, translation status), remove dead code and filesystem path references
- Optimize publishing DB queries: batch loading, ListingCache for dashboard, bulk UPDATE for translation statuses, debounced PubSub updates
- Rework editor to two-column layout with content-first design (title + editor left, metadata right)
- Rework AI translation: integrate AI prompt system, modal UI replacing slidedown, translation progress recovery across page refreshes
- Replace primary language banner with compact tooltip on language switcher
- Add skeleton loading UI for language switching in publishing editor
- Fix collaborative editing: spectator initial sync, lock promotion JS updates, lock expiration timer
- Fix admin sidebar highlighting for publishing group pages
- Fix custom fields card hidden when no field definitions are registered
- Add bulk "Add to Group" action on posts index with dynamic group filter dropdown

## 1.7.65 - 2026-03-08
- Fix V77 migration crash: role_id column renamed to role_uuid in UUID migration

## 1.7.64 - 2026-03-08
- Remove legacy filesystem paths from publishing module — strip all `.phk` virtual path references from mapper, editor, listing, and preview
- Switch all event handlers and navigation from path-based to UUID-based routing
- Fix timestamp-mode posts returning 404: normalize post_time to zero seconds, with hour:minute-only fallback query for legacy data
- Add collision prevention for same-minute timestamp posts (auto-bump to next minute, max 60 attempts)
- Add unique_constraint on (group_uuid, post_date, post_time) to schema
- Render empty listing page instead of 404 when group exists but has no published posts
- Show Primary Language banner during new post creation
- Add missing PubSub handlers to publishing Index view (version_created, version_live_changed, version_deleted) with catch-all
- Fix primary language migration using removed path field — now uses UUID/slug directly
- Remove cache management UI from listing page (accessible via settings only)
- Add safety guards to URL builders: raise ArgumentError on nil UUID instead of producing broken URLs

## 1.7.63 - 2026-03-06
- Remove filesystem storage from publishing module — delete Storage, DualWrite, and all storage/* submodules (~7k lines removed)
- Add LanguageHelpers and SlugHelpers as standalone modules, simplify to DB-only throughout
- Fix slug conflict clearing bug: `clear_url_slugs_for_conflicts` passed wrong slug to DB cleanup
- Fix ngettext interpolation in primary language migration modal (literal `%{count}` in UI)
- Clean up stale filesystem references in comments, docs, and user-facing strings
- Fix V77/V78 migration crashes when UUID columns are missing (tables created after V56 ran)
- Simplify V77/V78 migrations — remove over-engineered column detection, rely on idempotent patterns
- Fix email tracking bug: `handle_delivery_result` used `get_log!` (raises) in a nil-matching branch; add `get_log/1` non-bang wrapper and remove unused public functions
- Add `migration_module/0` callback to plugin module system — `mix phoenix_kit.update` auto-discovers and runs plugin migrations
- Add `Settings.Queries` module for database operations
- Add dedicated queue and 1-day pruner for scheduled jobs cron worker
- Fix user dashboard navigation links
- Fix ueberauth providers configuration format in installer

## 1.7.62 - 2026-03-05
- Fix UnicodeConversionError crash in integration plug when response body contains non-UTF8 binary data
- Fix DB browser rendering of raw binary values (e.g. UUID bytes) in table and activity views
- Add V78 migration: backfill missing AI module columns skipped by V41 conditional checks
  - Add `reasoning_enabled`, `reasoning_effort`, `reasoning_max_tokens`, `reasoning_exclude` to `phoenix_kit_ai_endpoints`
  - Add `prompt_uuid`, `prompt_name` to `phoenix_kit_ai_requests` with index and FK constraint

## 1.7.61 - 2026-03-04
- Replace `plug_cowboy` with `bandit ~> 1.0` as HTTP adapter (Phoenix 1.8 default)
- Remove stale deps from lock: `cowboy`, `cowlib`, `cowboy_telemetry`, `plug_cowboy`, `combine`, `dns_cluster`, `phoenix_live_dashboard`, `poolboy`, `timex`, `tzdata`
- Remove deprecated `fetch_live_flash` plug
- Add audit_log query limits
- Fix atom table exhaustion risk and remove duplicate function
- Update excluded_apps list in route resolver to match current deps
- Update HTML comments to EEx format in templates and components
- Clean up stale dep spec and dead commented-out code

## 1.7.60 - 2026-03-03
- Remove legacy FS→DB migration modules: `DBImporter`, `MigrateToDatabaseWorker`, `ValidateMigrationWorker`
- Remove `JsIntegration` install/update module (JS setup is now manual)
- Remove all "Import to DB" / "Migrate to Database" UI buttons from publishing pages
- Remove DB import/migration PubSub broadcast functions and LiveView handlers
- Simplify publishing listing: drop `fs_post_count`, `needs_import`, `db_import_in_progress` assigns
- Move post title field into the editor content column with larger styling
- Simplify editor save button logic (always clickable unless readonly/autosaving)
- Add `enrich_with_db_uuids/2` to ListingCache for UUID-based admin links in filesystem mode
- Refine Sync module: migrate `connection_id` references to `connection_uuid`
- Update publishing README to reflect DB-only storage model

## 1.7.59 - 2026-03-03
- Fix V75: use CASCADE when dropping `phoenix_kit_id_seq` (meta table `phoenix_kit.id` DEFAULT depends on it)

## 1.7.58 - 2026-03-03
- Add V75 migration: fix uuid column defaults and cleanup
  - Set `DEFAULT uuid_generate_v7()` on 27 tables missing it (Category A tables — V72 rename dropped old sequence DEFAULT)
  - Fix 4 tables using `gen_random_uuid()` (UUIDv4) → `uuid_generate_v7()` (UUIDv7)
  - Drop orphaned `phoenix_kit_id_seq` sequence

## 1.7.57 - 2026-03-03
- Fix V74 migration: skip tables without bigint `id` (e.g. publishing tables created with UUID PKs)
- Fix V74: use `DROP COLUMN id CASCADE` to handle dependent FK constraints in one statement

## 1.7.56 - 2026-03-03
- Add V74 migration: drop integer `id`/`_id` columns, promote `uuid` to PK on all tables
  - Drop all FK constraints referencing integer `id` columns (dynamic discovery)
  - Drop ~95 integer FK columns across all tables (sourced from uuid_fk_columns.ex + extras)
  - Drop bigint `id` PK + promote `uuid` to PK on 47 Category B tables
  - After V74, every PhoenixKit table uses `uuid` as its primary key — no integer PKs remain
- Remove `source: :id` from `webhook_event.ex` schema (DB column now matches field name)

## 1.7.55 - 2026-03-03
- Fix scheduled_job.ex `source: :id` regression — PR #383 reintroduced mapping to dropped DB column
- Add V73 migration: pre-drop prerequisites for Category B UUID migration
  - SET NOT NULL on 7 uuid columns (`ai_endpoints`, `ai_prompts`, `consent_logs`, `payment_methods`, `role_permissions`, `subscription_types`, `sync_connections`)
  - CREATE UNIQUE INDEX on 3 tables (`consent_logs`, `payment_methods`, `subscription_types`)
  - ALTER INDEX RENAME on 4 indexes to match renamed columns (`post_tag_assignments`, `post_group_assignments`, `post_media`, `file_instances`)
- Add `RepoHelper.get_pk_column/1` — queries `pg_index` for PK column name, falls back to `"id"`
- Fix DB explorer to use dynamic PK column in `fetch_row`, `table_preview`, and notify trigger
- Fix Sync API controller to use dynamic PK column in `fetch_filtered_records` and `build_where_clause`
- Fix Sync connection notifier to use dynamic PK column in `insert_record` and `build_update_clause`
- Update 4 schema constraint names to match V72 column renames (`post_id` → `post_uuid`, `file_id` → `file_uuid`)
- Remove dead `:user_id` from OAuth `replace_all_except` list

## 1.7.54 - 2026-03-03
- Add V72 migration: rename PK column `id` → `uuid` on 30 Category A tables (metadata-only, instant)
- Add 4 missing FK constraints: `comments.user_uuid`, `comments_dislikes.user_uuid`, `comments_likes.user_uuid`, `scheduled_jobs.created_by_uuid`
- Remove `source: :id` mapping from 29 Category A Ecto schemas — DB column now matches field name directly

## 1.7.53 - 2026-03-02
- Add `mix phoenix_kit.doctor` diagnostic command — detects migration version vs `schema_migrations` discrepancies, stale COMMENT tags, and common DB issues
- Add `update_mode` to `mix phoenix_kit.update` — skips heavy DB components (Oban, cache warmers, settings queries) and caps Ecto pool at 2 during migrations to prevent DB saturation
- Run `ecto.migrate` in-process instead of `System.cmd` for better error reporting and reliability
- Fix three migration hang root causes: NULL UUIDs causing infinite backfill loop, orphaned FK references blocking constraint creation, varchar uuid columns crashing Ecto schema loader
- Fix migration hang: disable DDL transaction in generated migration wrapper — prevents entire multi-version migration from running in a single transaction holding AccessExclusiveLock
- Fix V50 migration hang: add `lock_timeout` for `phoenix_kit_buckets` ALTER TABLE and check column existence before ALTER
- Fix settings cache race: warm synchronously in `init/1` when `sync_init: true`; fix `warm_critical_data` inserting `{key, value, nil}` 3-tuples when TTL is nil
- Fix cache `sync_init` blocking supervisor for 60s when DB is overloaded
- Fix startup DB timeout: defer `Dashboard.Registry` init and reorder supervisor children
- Silence cache warmer spam and auto-grant warning when `role_permissions` table doesn't exist yet
- Fix `gen.migration` task: generate UUID primary keys and `user_uuid` FK instead of integer-based
- Fix broken GDPR anonymization: remove leftover `user_id: nil` from `update_all` calls
- Rename `_id` → `_uuid` across all remaining application code: billing, shop, storage, entities, sync, emails, tickets, permissions, roles, connections, publishing, and user_notifier
- Rename function names: `find_role_by_id` → `find_role_by_uuid`, `parse_id` → `parse_uuid`, `import_id` → `import_uuid`
- Fix Dialyzer warning: remove unreachable pattern match in cache warming
- Fix V56/V63 migration crash: `email_log_uuid` backfill fails with `datatype_mismatch` when `phoenix_kit_email_logs.uuid` is `character varying` instead of native `uuid` type
- Fix UUIDFKColumns: replace broken Elixir `rescue` with PostgreSQL `EXCEPTION` handler inside DO blocks — prevents outer transaction abort on backfill failure
- Add `::uuid` explicit cast in all UUIDFKColumns backfill SQL to handle varchar source columns gracefully
- Fix V56: add pre-step to convert varchar `uuid` columns on all FK source tables to native `uuid` type before `UUIDFKColumns.up` runs
- Fix V63: wrap `matched_email_log_uuid` backfill in DO block with EXCEPTION handler and `::uuid` cast
- Add V70 migration: re-backfills `email_log_uuid` and `matched_email_log_uuid` for installs where V56/V63 silently skipped the backfill; resets stale random UUIDs written by the V56 NULL-fill fallback
- Add investigation doc: `dev_docs/investigations/2026-03-01-varchar-uuid-migration-bug.md`

## 1.7.52 - 2026-02-28
- Add translatable `title` field to posts and fix timestamp-mode post handling
- Add V69 migration: make role table integer FK columns nullable
- Add `mix precommit` alias (`compile → format → credo --strict`) to `mix.exs`
- Update AGENTS.md with pre-commit instructions, replacing old minimal checklist
- Rename `Scope.user_id` → `Scope.user_uuid` for consistency
- Rename `user_id` → `user_uuid` across event handlers, templates, and messages
- Rename `user_id` → `user_uuid` in emails rate_limiter; `log_id` → `log_uuid` in emails interceptor, SQS processor, and sync task
- Rename `user_id` → `aws_user_id` in AWS credentials verifier
- Rename `resource_id` → `resource_uuid` in scheduled jobs
- Rename `_id` → `_uuid` in billing, shop, AI, entities, legal, posts, tickets, storage, scheduled jobs, and permissions
- Rename `_id` → `_uuid` across metadata, forms, helpers, and tests
- Replace `DateTime.utc_now()` with `UtilsDate.utc_now()` across codebase
- Remove redundant `connection_id` parameter from sync `connection_notifier`
- Fix crash bugs: `.user_id` struct access → `.user_uuid` in billing events and order_form
- Fix UUID field references for webhook_events and post images
- Fix duplicate map keys left from UUID migration in hooks and rate_limiter
- Fix alias ordering Credo violations across 18 files
- Fix timestamp-mode post lookups, migration ordering, and admin UI (PR #376 review follow-up)
- Fix `tab_callback_context` missing clause; demote double-wrap log to debug
- Add dialyzer ignore for unused `tab_callback_context` clause
- Update integration guide, making-pages-live guide, dashboard README, and usage-rules to use UUID terminology

## 1.7.51 - 2026-02-26
- Add V64 migration: fix login crash by replacing `user_id` check constraint with `user_uuid` on user tokens table
- Add V65 migration: rename `SubscriptionPlan` to `SubscriptionType` (table, columns, indexes, constraints)
- Rename `SubscriptionPlan` schema, context functions, events, routes, LiveViews, and workers to `SubscriptionType`
- Add orphaned media file cleanup system
  - `mix phoenix_kit.cleanup_orphaned_files` task with dry-run and `--delete` modes
  - `DeleteOrphanedFileJob` Oban worker with 60s delay and orphan re-check before deletion
  - Orphan filter toggle and "Delete all orphaned" button in Media admin UI
- Add Delete File button with confirmation modal to Media Detail page
- Add secondary language slug uniqueness validation via JSONB query in entity data
- Rename `seed_title_in_data` to `seed_translatable_fields` in entity data form
- Unify slug labels to "Slug (URL-friendly identifier)" across entity forms
- Standardize dev_docs file naming convention (`{date}-{kebab-case}-{type}.md`)
- Fix orphan detection crash: remove references to non-existent `phoenix_kit_shop_variants` table
- Fix `String.trim(nil)` crash in SQS workers when AWS credentials not configured
- Fix default preload `:plan` to `:subscription_type` in `list_subscriptions/1` and `list_user_subscriptions/2`
- Fix `auth.ex` storing integer `file.id` instead of `file.uuid` for avatar custom field
- Fix `create_subscription/2` dead code and key mismatch — now accepts `:subscription_type_uuid` as preferred key
- Fix `change_subscription_type/3` reading stale `subscription_type_id` instead of `subscription_type_uuid`
- Fix AWS Config returning empty string instead of nil when credentials unconfigured
- Fix email log `Access` behaviour error when called with `EmailLogData` struct
- Fix `Interceptor` using deprecated `log.id` instead of `log.uuid` in header and event
- Fix shop billing cascade: check `disable_system()` result and log on failure
- Replace `defp` proxy wrappers with `import` in 4 shop LiveViews (cart, catalog, checkout)
- Rename `post_id` to `post_uuid` in 5 private post functions
- Remove legacy integer ID function clauses from posts and billing modules
- Remove accidentally committed `.beam` files, add `*.beam` to `.gitignore`
- Remove empty legacy `subscription_plan_form.ex` and `subscription_plans.ex`
- Add doc notes about performance for `all_admin_tabs/0` and `get_config/0`
- Remove dead `_plugin_session_name` variable from integration routes

## 1.7.50 - 2026-02-25
- Fix `defp show_dev_notice?` CLAUDE.md violation: replace private helper with `<.dev_mailbox_notice>` Phoenix Component
  - New component at `lib/phoenix_kit_web/components/core/dev_notice.ex` with `message` and `class` attrs
  - Removed from `login.ex`, `registration.ex`, `magic_link.ex`, `forgot_password.ex`, `dashboard/settings.ex`
  - Updated all corresponding HEEX templates to use `<.dev_mailbox_notice>`
- Fix duplicate route alias compilation warnings in `phoenix_kit_authenticated_routes/1`
  - Split module-scope routes into `authenticated_live_routes/0` and `authenticated_live_locale_routes/0`
  - Locale variants now use `_locale` suffix (e.g. `:shop_user_orders_locale`)
- Fix undeclared `sidebar_after_shop` attr in `shop_layout/1` component
- Fix `maybe_redirect_authenticated/1` hardcoded `"/"` redirect — use `signed_in_path(socket)` consistently
- Fix double `Map.from_struct` in `Emails.Interceptor.create_email_log/2` — redundant call removed

## 1.7.49 - 2026-02-24
- Add V63 migration: UUID companion column safety net round 2
  - Add `uuid` identity column to `phoenix_kit_ai_accounts` (missed by V61 due to wrong table name)
  - Add `account_uuid` companion to `phoenix_kit_ai_requests` (backfilled from ai_accounts)
  - Add `matched_email_log_uuid` to `phoenix_kit_email_orphaned_events` (backfilled from email_logs)
  - Add `subscription_uuid` to `phoenix_kit_invoices` (backfilled from subscriptions)
  - Add `variant_uuid` to `phoenix_kit_shop_cart_items` (nullable, no variants table)
  - Update Invoice, AI Request, and CartItem schemas with new uuid companion fields

## 1.7.48 - 2026-02-24
- Add V62 migration: rename 35 UUID-typed FK columns from `_id` suffix to `_uuid` suffix
  - Enforces naming convention: `_id` = integer (legacy/deprecated), `_uuid` = UUID
  - Groups: Posts module (15 renames), Comments (4), Tickets (6), Storage (3), Publishing (3), Shop (3), Scheduled Jobs (1)
  - No data migration — columns already held correct UUID values, pure rename
  - All DB operations idempotent (IF EXISTS guards) — safe on installs with optional modules disabled
  - Update all Ecto schemas, context files, web files, and tests to use new field names

## 1.7.47 - 2026-02-24
- Fix V13 migration down/0 to use `remove_if_exists` instead of `remove` for idempotency
  - Fixes "column aws_message_id does not exist" error when rolling back V13

## 1.7.46 - 2026-02-24
- Add plugin module system with `PhoenixKit.Module` behaviour, `ModuleRegistry`, and zero-config auto-discovery
  - 5 required + 8 optional callbacks with sensible defaults via `use PhoenixKit.Module`
  - Auto-discovers external modules by scanning `.beam` files for `@phoenix_kit_module` attribute
  - All 21 internal modules now implement the behaviour, removing 786 lines of hardcoded tab enumeration
  - External module admin routes auto-generated at compile time from `admin_tabs` with `live_view` field
- Add live sidebar updates via PubSub when modules are enabled/disabled
- Add server-side authorization on module toggle events (prevents crafted WebSocket bypass)
- Add startup validation: duplicate module keys, permission key mismatches, duplicate tab IDs, missing permission fields
- Add compile-time warnings for route module and LiveView compilation failures
- Standardize AI, Billing, and Shop to use `update_boolean_setting_with_module/3` (consistent with all other modules)
- Fix billing→shop cascade: shop now disabled after billing toggle succeeds (prevents orphaned state)
- Fix `Tab.permission_granted?/2` to handle atom permission keys instead of silently bypassing checks
- Fix `static_children/0` to catch module `children/0` failures instead of crashing the supervisor

## 1.7.45 - 2026-02-23
- Fix auth forms mobile overflow on small screens (px-4 added to all form containers)
- Fix daisyUI v5 compliance: remove deprecated `input-bordered` from `<.input>` component and all auth templates
- Fix `<.header>` hardcoded `text-zinc-*` colors replaced with semantic `text-base-content` for dark theme support
- Convert forgot_password, reset_password, confirmation, confirmation_instructions to unified card layout
- Add missing `LayoutWrapper.app_layout` wrapper to confirmation form
- Fix V40 migration silently skipping V32-V39 tables due to Ecto command buffering
  - Root cause: `repo().query()` (immediate) couldn't see buffered table creation commands
  - V31's `flush()` was the last flush before V40, creating a clean V31/V32 split
  - Add `flush()` to V40 and V56 to prevent recurrence on new installations
- Add V61 migration: uuid column safety net for 6 tables missed by V40
  - Tables fixed: admin_notes, ai_requests, subscriptions, payment_provider_configs, webhook_events, sync_transfers
  - Also adds `created_by_uuid` FK column to phoenix_kit_scheduled_jobs

## 1.7.44 - 2026-02-23
- Add Publishing module: DB storage, public post rendering, and i18n support
- Add unified `admin_page_header` component, replace all per-page admin headers
- Add try/rescue to all form save handlers to prevent silent data loss on validation errors
- Add skeleton loading placeholders for entity language tab switching
- Add "Update Entity" submit button at top of entity form for quicker saves
- Add responsive card view to entities listing, remove stats/filters
- Memoize `IbanData.all_specs/0` with compile-time module attribute for performance
- Auto-register built-in comment resource handlers
- Make entity slug translatable and move it into Entity Information section
- Move multilang info alert above language tabs with improved explanation
- Tighten language tab spacing, replace daisyUI tab classes with compact utilities
- Remove hardcoded category column, filter, and bulk action from data navigator
- Fix CommentsComponent crash on post detail page
- Fix Entity update crash from DateTime microseconds in `:utc_datetime` fields
- Fix `email_templates` schema/migration mismatch breaking fresh installs
- Fix locale disappearing from admin URLs on sidebar navigation
- Fix badge component height on mobile devices
- Fix cached plan error spam during migrations with column type changes
- Fix CSS specificity debt and inline styles replaced with Tailwind classes
- Fix mobile responsiveness across admin panel
- Replace remaining `DateTime.utc_now()` with `UtilsDate.utc_now()` in all DB write contexts

## 1.7.43 - 2026-02-18
- Standardize all schemas to `:utc_datetime` and `DateTime.utc_now()` across 73 files
  - Replace `:utc_datetime_usec` with `:utc_datetime` and `NaiveDateTime` with `DateTime`
  - Add V58 migration to convert all timestamp columns across 68 tables from `timestamp` to `timestamptz`
  - Fix UUID FK backfill to handle NULL UUIDs before applying NOT NULL constraints
- Fix DateTime.utc_now() microsecond crashes in 19 files after `:utc_datetime` schema migration
  - Add `DateTime.truncate(:second)` to all `DateTime.utc_now()` calls in contexts
  - Affected: settings, billing, shop, emails, referrals, tickets, comments, auth, permissions, roles
- Fix Language struct Access error on admin modules page and all bracket-access-on-struct bugs
- Add 20 typed structs replacing plain maps across billing, entities, sync, emails, AI, and dashboard
  - Billing: CheckoutSession, SetupSession, WebhookEventData, PaymentMethodInfo, ChargeResult, RefundResult, ProviderInfo
  - Other: AIModel, FieldType, EmailLogData, LegalFramework, PageType, Group, TableSchema, ColumnInfo, SitemapFile, TimelineEvent, IbanData, SessionFingerprint
- Fix `register_groups` to convert plain maps to `Group` structs, preventing sidebar crashes
- Fix CastError in live sessions page by using UUID lookup instead of integer id
- Fix guest checkout flow: relax NOT NULL on legacy integer FK columns, fix transaction error double-wrapping
- Add return_to login redirect support for seamless post-login navigation (e.g., guest checkout)
- Add cart merge on login for guest checkout sessions
- Fix shop module .id to .uuid migration in Storage image lookups and import modules
- Fix hardcoded "PhoenixKit" fallback in admin header project title
- Fix admin sidebar submenu not opening on localized routes
- Fix 2 dialyzer warnings in checkout session and UUID migration
- Add multi-language support for Entities module
  - New `Multilang` module with pure-function helpers for multilang JSONB data
  - Language tabs in entity form, data form, and data view (adaptive compact mode for >5 languages)
  - Override-only storage for secondary languages with ghost-text placeholders
  - Lazy re-keying when global primary language changes (recomputes all secondary overrides)
  - Translation convenience API: `Entities.set_entity_translation/3`, `EntityData.set_translation/3`, `EntityData.set_title_translation/3`, and related get/remove functions
  - Multilang-aware category extraction in data navigator and entity data
  - Non-translatable fields (slug, status) separated into their own card
  - Required field indicators hidden on secondary language tabs
  - Title translations stored as `_title` in JSONB data column (unified with other field translations)
  - Slug generation disabled on secondary language tabs
  - Validation error messages wrapped in gettext for i18n
  - 124 pure function tests for Multilang, HtmlSanitizer, FieldTypes, FieldType
- Fix entities multilang review issues
  - Unify title storage in JSONB data column, fix rekey logic for primary language changes
  - Add `seed_title_in_data` for lazy backwards-compat migration on mount
  - Replace `String.to_existing_atom` with compile-time `@preserve_fields` map
  - Fix 7 remaining issues from PR #341 permissions review
  - Add catch-all fallback clauses to Scope functions to prevent FunctionClauseError
  - Sort `custom_keys/0` explicitly instead of relying on Erlang map ordering

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

