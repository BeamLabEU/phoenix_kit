## 1.7.16 - 2025-12-29

### Legal Module - Phase 1
- **New Legal module** for privacy compliance and legal page management
- **Compliance framework selection** - Support for GDPR, CCPA, LGPD, PDPA, POPIA, and Generic frameworks
- **Company information form** - Store company details for legal page generation
- **DPO contact form** - Data Protection Officer contact information
- **Legal page generation** - Generate pages from EEx templates:
  - Privacy Policy, Terms of Service, Cookie Policy
  - Data Retention Policy, CCPA Notice, Acceptable Use Policy, Do Not Sell
- **Blogging integration** - Generated pages stored as blog posts in dedicated "legal" blog
- **Consent logging schema** - Track user consent for cookies and data processing (V43 migration)
- **Admin settings interface** - Manage legal settings at `/admin/settings/legal`
- **Module organization** - Files structured in `lib/modules/legal/` following Storage module pattern

## 1.7.15 - 2025-12-29
- Major AI Module enhancements: real-time PubSub updates across tabs, client-side TimeAgo hook for efficient time displays, reasoning/thinking parameters for AI endpoints, prompt tracking in request logs, and pagination with date filtering on admin pages.
- Initial Job Module release with basic functionality

## 1.7.14 - 2025-12-26
- Improve V40 UUID migration UX and documentation
- Add UUIDv7 generation to all Ecto schemas
- Add fallback to default en when site_content_language setting

## 1.7.13 - 2025-12-25
- Fix email sender to use Settings Database
- Add V40 migration for UUIDv7 columns on all legacy tables
- Fixed/Updated posts and stopped the logs spamming
- Fix incorect routes

## 1.7.12 - 2025-12-24
### Blog Language Detection & Fallbacks
- **Content-based language detection** - Custom language files (e.g., `af.phk`, `test.phk`) now work correctly without needing to be predefined in the Languages module
- **Flexible fallback chain** for missing blog posts:
  - If requested language version doesn't exist, tries other available languages (default language prioritized)
  - For timestamp posts: tries other times on the same date if specific time doesn't exist
  - Falls back to blog listing with informative flash message when no alternatives found
- **Language switcher fix** - Status dot colors now correctly show green/yellow/gray for unknown language files (previously all showed gray)

### Blog Performance Improvements
- **Preload language statuses** - `language_statuses` field added to posts when loading via `list_posts` and `read_post`
- **Eliminates redundant file reads** - Previously O(posts × languages) file reads per page render, now reads files once during post loading
- **Faster blog listing pages** - Significant performance improvement for blogs with many posts and language translations

## 1.7.11 - 2025-12-24
- Fixed blog url issue
- Fix for show username error on save
- Translated comments to English in billing and AWS modules for consistency

## 1.7.10 - 2025-12-24
- New Connections Module initial commit
- Show tickets navigation only when tickets module is enabled
- Add AI Prompts feature and sitemap fixes
  - AI Prompts Feature (V38): New prompt template system with variable substitution ({{VariableName}} syntax), usage tracking, and full CRUD API
  - Waterfall Model Selection: Two-step Provider → Model selection in AI endpoint form for better UX
  - Sitemap Fixes: URL generation and blog fallback redirect fixes
  - Tickets Navigation: Show tickets nav only when module is enabled
  - DB Sync Updates (V37): Connection management improvements
  - Code Quality: Fixed Credo/Dialyzer warnings
- Fix settings cache to prevent repeated queries for non-existent settings
- Added user view page, added username visibility and registration location fix

## 1.7.9 - 2025-12-22

### Sitemap File-Only Architecture
- **300x faster responses** - Sitemap.xml now loads in ~20ms instead of 6000ms
- **File-based storage** - XML stored in `priv/static/sitemap.xml` for direct nginx/CDN serving
- **ETag from file mtime** - Cache validation uses file modification time instead of database config
- **On-demand generation** - First request generates sitemap if file doesn't exist (no 503 errors)
- **Simplified architecture** - Removed ETS caching layer for XML, single file instead of per-style files

### FileStorage Module
- New unified API: `save/1`, `load/0`, `exists?/0`, `delete/0`, `get_file_stat/0`
- Path changed to `priv/static/sitemap.xml` (was `priv/phoenix_kit/sitemaps/`)
- Legacy API compatibility maintained for existing code

### Admin UI Changes
- "Clear Cache" button renamed to "Clear Sitemap" for clarity
- Clear Sitemap now also resets "Last Generated" timestamp

## 1.7.8 - 2025-12-22

### Route Priority Fix
- **Non-localized routes first** - Fixed 105 route conflicts where paths like `/admin` were incorrectly matched as `/:locale/dashboard` with `locale="admin"`
- **Locale scope ordering** - Non-localized scope now comes before localized scope in router macros

### Sitemap Performance Improvements
- **Parallel language collection** - Multilingual sitemap generation now runs in parallel using `Task.async_stream`, reducing generation time from N×T to ~T for N languages
- **Style-independent caching** - Cache URL entries instead of full XML, allowing different XSL styles (table/cards/minimal) to share the same cache
- **Fast HTTP responses** - Sitemap.xml now responds in ~10ms with cached entries vs seconds for full regeneration

### Sitemap Fixes
- **Timezone display** - "Last Generated" timestamp now displays in system timezone from Settings
- **Date/time format** - Apply user's date_format and time_format preferences to timestamps

### Other Fixes
- Fix Routes.path call in SEO settings to use keyword list

## 1.7.7 - 2025-12-22
- Optimize sitemap generation and fix routing issues
  - Optimize sitemap source modules to reduce RouteResolver calls
  - Fix entities not appearing when using catchall routes
  - Fix homepage appearing as /en/ instead of /

## 1.7.6 - 2025-12-20

### New Module: Support Tickets (V35)
- **Complete ticket system** - Customer support request management with status workflow
- **Ticket comments** - Threaded comments with internal notes (staff-only visibility)
- **File attachments** - Attachments on tickets and comments with position ordering
- **Status history** - Complete audit trail for all status changes
- **Status workflow** - open → in_progress → resolved → closed
- **SupportAgent role** - New role for ticket access control
- **Admin interface** - Full CRUD at /phoenix_kit/admin/tickets
- **Settings** - Module enable/disable, per_page, comments, internal notes, attachments, allow_reopen

## 1.7.5 - 2025-12-20

### Email System Improvements
- **Oban-based SQS polling** - Replace GenServer with Oban Worker for AWS SES event processing
  - Self-scheduling pattern for continuous queue polling
  - Automatic retries and job persistence
  - Graceful handling of application restarts
- **SQSPollingManager API** - New management interface with enable/disable/status operations
- **Improved reliability** - Better error handling and recovery for SQS message processing

### Sitemap Improvements
- **Auth route filtering** - Exclude routes requiring authentication from sitemap generation

### Install/Update Improvements
- **Oban config fix** - Regex patterns now correctly ignore commented-out config blocks
- **SQS polling queue** - Automatically added to Oban configuration during install/update

### Other changes
- Add DB Transfer module, fix sitemap language prefix, and add module documentation
- Language admin navbar issues fixes
- Fix admin layout languages
- Refactor AI module to unified endpoints & rename DB Transfer to DB Sync

## 1.7.4 - 2025-12-17

### Sitemap Improvements
- **Translation filtering** - Blog posts without translation files are excluded from sitemap for that language
- **Default language only** - Static, Entities, and Posts sources generate URLs only for default language (prevents 404s)
- **Disable auto_pattern** - Changed `sitemap_entities_auto_pattern` default to false (entities require real routes)
- **Async regeneration** - PubSub broadcast for real-time UI updates after regeneration
- **ETag caching** - Add ETag headers to sitemap controller for HTTP caching
- **UI cleanup** - Remove non-functional source toggles, improve layout

### Billing Improvements
- **Auto status sync** - Orders auto-confirm when invoice is fully paid
- **Refund handling** - Mark order as refunded and invoice as void on full refund
- **Payment method sync** - Update order payment_method from invoice transaction
- **Invoice print** - Add refund information and payment history
- **V33 migration fix** - Make payment_method nullable for draft orders

### Other Changes
- Update beamlab_countries dependency to 1.0.4
- Hide suggested VAT rate when it matches current rate

## 1.7.3 - 2025-12-16
- Add AI module and per-entity backup controls
- Updated languages settings page by continent, updated gitignore to include assets

## 1.7.2 - 2025-12-15

### Added
- **Multilingual Sitemap Support**
  - Add hreflang alternate links for SEO optimization
  - Automatic language detection from Languages module
  - XML sitemap with xhtml:link elements for all language versions
  - x-default hreflang for default language pages
- **Posts Sitemap Source** - new source module for PhoenixKit Posts system
- **RouteResolver** - add :posts support in find_content_route/find_index_route
- **BeamLabCountries Integration for Billing**
  - Add CountryData wrapper module with billing-specific functions
  - Replace hardcoded 11-country select with dynamic 250-country dropdown with flags
  - Use CountryData.eu_member?/1 for dynamic EU membership validation
  - Add calculate_totals_for_country/3 for automatic VAT rate by country
  - Auto tax rate calculation in OrderForm when billing profile is selected
  - Include workaround for BeamLabCountries charlist bug in reduced VAT rates
  - PR #2 submitted to fix upstream charlist bug in beamlab_countries

### Changed
- Update Blogging, Entities, Static sitemap sources with language prefix support
- Add canonical_path field to UrlEntry for hreflang grouping
- Make project title a clickable link to home page in admin header

## 1.7.1 - 2025-12-14
### Fixes
- Fix sitemap module: restore missing routes and add sidebar menu

## 1.7.0 - 2025-12-12

### Added
- **Billing Module** (V31 migration)
  - Multi-currency support with ISO 4217 codes (EUR, USD, GBP)
  - Billing profiles for individuals and companies (EU Standard)
  - Orders with line items and status tracking
  - Invoices with receipt functionality
  - Payment transactions and receipts
  - Credit notes support
  - Tax rate calculations
  - Print templates (invoice, receipt, credit note, payment confirmation)
  - Email integration for billing documents
  - Admin UI for billing management
- **Add file mirror/export system** for Entities with import UI

### Changed
- Email templates system enhancements for billing documents
- User avatars in admin UI with cascading fallback
- Theme-aware dropdown for email status legend
- Add custom admin dashboard sections
- Update to the language module to use new beamlab dep 
- Refactor locale usages
- Fix admin category page template
- Moved all storage files to the modules/storage folder

### Merged from upstream
- Posts system (V29 migration) - social posts with comments, likes, tags
- Preferred locale moved to custom_fields (V30 migration)
- Collaborative editing and live updating dashboards for blogging
- IPv4/IPv6 session creation fixes
- Ueberauth igniter setup fixes

## 1.6.20 - 2025-12-11
- Posts (for user generated content) module inital commit
- Add authentication-aware route filtering for sitemap
- blogging: add collaborative editing, live updating dashboards
- Update for the language module (organizing by country)

## 1.6.19 - 2025-12-09
- Add smart timestamp URL handling for blog posts

## 1.6.18 - 2025-12-09
- Fix blogging editor issues and add publish button

## 1.6.17 - 2025-12-09
- Fix blog language switcher and update entities module examples (Fix public blog language switcher to only show languages with actual published content, improve editor JS initialization, and replace blog post examples with brand examples in the entities module to avoid confusion.)

## 1.6.16 - 2025-12-07
- Move path functions to the corresponding module
- Improve blog language switcher UI and URL handling
- Remove static Ueberauth configuration requirements 
  - OAuth is now fully dynamic - no compile-time Ueberauth config needed
  - Providers loaded from database at runtime via OAuthConfigLoader

## 1.6.15 - 2025-12-05

### Added
- **Sitemap Module** - Complete sitemap generation system for SEO
  - XML sitemap generation following sitemaps.org protocol
  - HTML sitemap with 3 display styles (hierarchical, grouped, flat)
  - Automatic sitemap index for large sites (>50,000 URLs)
  - Multiple content sources: Blogging, Entities, Pages, Static routes
  - Router discovery - automatic detection of parent app routes
  - XSL stylesheets for beautiful XML rendering (table, cards, minimal)
  - ETS-based caching for fast repeated access
  - Oban worker for scheduled automatic regeneration
  - Admin UI for sitemap settings configuration
  - Routes: `/sitemap.xml`, `/sitemap.html`, `/sitemap.xsl`

### Changed
- Update blogging editor to use markdown image syntax instead of custom component

## 1.6.14 - 2025-12-02
- Refactor Endpoint usage
- Fixes to admin languages, fixes oban implemntation and support for ipv4 and v6
  - Making sure that admin panel langauge list cannot be empty
  - Fixed issue with application.ex igniter implementation of oban
  - Fixed issue with support for IPv4 and IPv6
  - Fixed issues with dialyzer
- Fix Oban config, OAuth auto-confirm, and AWS email settings
  - Fix Oban configuration loading in parent app supervisor child spec
  - Add auto-confirm email for OAuth authentication
  - Fix AWS settings validation and form event handling
  - Fix SES configuration set creation for existing sets

## 1.6.13 - 2025-11-26
- Fixed issue with locales not working correctly on fresh install

## 1.6.12 - 2025-11-26
- Fixed locale switching to correct base codes

## 1.6.11 - 2025-11-25
- Fix OAuth buttons generating incorrect URLs with locale prefix

## 1.6.10 - 2025-11-25
- Added language dialects, more locations to timezones, graying out main menu buttons when inside submenus
- Remove critical_warmer parameter: Simplified cache initialization to load all data in single operation instead of loading critical settings first then remaining settings
- Add retry mechanism: Implement exponential backoff retry logic for empty cache results (repository not ready yet)
- Improve handle_continue: Load all settings data synchronously when sync_init is enabled, preventing overwrites from async operations

## 1.6.9 - 2025-11-24
- Fix critical supervisor ordering issue in application.ex
- Fixed username generation
- Improve blogging and entity UX with autosave, slug handling, and module page polish
- **CRITICAL: Supervisor Ordering** - Fixed startup crashes caused by incorrect supervisor order in application.ex
- PhoenixKit.Supervisor and Oban now correctly start AFTER Repo instead of before
- Added explicit positioning using `after: [repo]` in Igniter installation logic
- Replaced text-based supervisor injection with proper Igniter.Project.Application API
- Added automatic fix in `mix phoenix_kit.update` to correct existing installations
- Prevents crashes: "Repo not ready" errors when loading Settings cache or Oban jobs
- Ensures correct order: Repo → PhoenixKit.Supervisor → Oban → Endpoint

## 1.6.8 - 2025-11-23
- Fix Oban configuration detection and automatic restart
- Improve status check messages to include Oban configuration
- Fix database connection check in phoenix_kit.status

## 1.6.7 - 2025-11-22
- Fixed redundant copies, label and database file_location row generation issue when uploading images
- Refactor Application usage and Modules names

## 1.6.6 - 2025-11-20
- Refactor ueberauth config usage
- DevAdd SEO module, blogging editor improvements, and navigation UX enhancements
- Media page fixes, and removal of timex
- Install igniter by default

## 1.6.5 - 2025-11-17
- Fixed readme versions
- Refactor Config and repository usage
- Added media selector modal window
- Improve blogging editor UX and component rendering
- Polish the featured-image selector with clearer labels, preview states, and mobile-friendly actions.
- Add LiveView + JS tooling for inserting images/videos, simplify the toolbar, and debounce content updates.
- Fix markdown rendering so block components (e.g., ) parse correctly alongside self-closing tags, ensuring inserted video snippets display as expected.
- Updated unique key to file_user_checksum instead of file_checksum, to allow duplicates but by different users

## 1.6.4 - 2025-11-15

### Fixed
- **AWS Credentials Verification** - Fixed STS response parsing to support ExAws map format
  - Added support for both XML string and parsed map responses from AWS STS
  - Fixed `parse_sts_response/1` to handle ExAws automatic XML-to-map conversion
  - Resolved `CaseClauseError` when verifying credentials with valid AWS keys
  - Added comprehensive error handling for all AWS verification failure types

### Changed
- **AWS Region Selection UX** - Streamlined region input workflow from 7 steps to 4
  - Replace dropdown-only region field with text input by default
  - Add optional "Load regions" button to fetch and display region dropdown
  - Enable manual region entry without waiting for region list loading
  - Remove requirement for double-saving credentials and region
  - Update setup instructions to reflect simplified workflow
- **Code Quality** - Refactored AWS credentials verification handler
  - Extract verification logic into separate helper functions
  - Reduce cyclomatic complexity from 14 to acceptable level
  - Improve code readability and maintainability

## 1.6.3 - 2025-11-12

### Added
- **Configurable Password Requirements** - Comprehensive password strength validation system with customizable requirements
  - Optional uppercase character requirement
  - Optional lowercase character requirement
  - Optional digit requirement
  - Optional special character requirement (!?@#$%^&*_)
  - Configurable minimum and maximum password length
  - Application-wide configuration via `:password_requirements` config key
  - Default behavior maintains backward compatibility (length validation only)

### Changed
- **Password Validation Logic** - Refactored `validate_password/2` to use configurable requirements instead of hardcoded validations
- **User Schema Documentation** - Enhanced documentation with detailed password requirements configuration examples

## 1.6.2 - Unreleased

### Added
- **Audit Logging System** - Comprehensive audit trail for administrative actions with detailed context tracking
- **Migration V22 Enhancement** - Added audit log entries table with optimized indexes
  - Added `phoenix_kit_audit_logs` table for tracking administrative actions
  - Records admin user, target user, action type, IP address, and user agent
  - JSONB metadata field for flexible additional context
  - Optimized indexes for querying by user, action, and timestamp
  - Composite indexes for common query patterns
- **Admin Password Reset Logging** - Automatic logging of password resets with full audit trail
  - WHO: Admin user ID and email
  - WHAT: Password reset action
  - WHEN: Timestamp with microsecond precision
  - WHERE: IP address of the admin
  - HOW: User agent string

### Changed
- **Admin Password Update** - Enhanced `admin_update_user_password/3` to accept optional context parameter
  - Backward compatible - context parameter is optional
  - Non-failing design - logging errors don't prevent password updates
  - Records complete audit trail when context is provided
- **User Form** - Updated to pass admin user and IP context when updating user passwords
  - New `build_audit_context/1` helper extracts context from LiveView socket
  - Automatically captures admin user, IP address, and user agent
  - Seamless integration with existing password update workflow

## 1.6.1 - 2025-11-11

### Added
- **Rate Limiting System** - Protection for authentication endpoints using Hammer library (login: 5/min, magic link: 3/5min, password reset: 3/5min, registration: 3/hour per email + 10/hour per IP)
- **PhoenixKit.Users.RateLimiter** - Module for rate limit management with admin reset/inspection functions
- **Security Logging** - Rate limit violations logged for monitoring

### Changed
- **Breaking**: `get_user_by_email_and_password/3` now returns `{:ok, user} | {:error, reason}` tuple
- **Breaking**: `register_user/2` accepts optional IP parameter
- **Breaking**: `deliver_user_reset_password_instructions/2` returns `{:ok, _} | {:error, :rate_limit_exceeded}`
- Updated `generate_magic_link/1` with rate limiting
- Enhanced controllers and LiveViews with rate limit error handling

### Fixed
- Brute-force attack, token enumeration, and email enumeration vulnerabilities
- Timing attacks with consistent response times

## 1.6.0 - 2025-11-11

### Added
- **Migration V22: Email System Improvements** - Enhanced email tracking and AWS SES integration
  - Added `aws_message_id` field to `phoenix_kit_email_logs` for AWS SES message ID correlation
  - Added event timestamp fields: `bounced_at`, `complained_at`, `opened_at`, `clicked_at`
  - Added partial unique index on `aws_message_id` (WHERE aws_message_id IS NOT NULL) to prevent duplicates
  - Added composite index `(message_id, aws_message_id)` for fast message correlation
  - Added composite index `(email_log_id, event_type)` for 10-100x faster duplicate event checking
  - Created `phoenix_kit_email_orphaned_events` table for tracking unmatched SQS events
  - Created `phoenix_kit_email_metrics` table for email system metrics and monitoring

### Changed
- **Dual Message ID Strategy** - Comprehensive documentation for email tracking
  - Internal `message_id` (pk_XXXXX format) - generated before sending, always unique
  - Provider `aws_message_id` - obtained after sending, used for AWS SES event correlation
  - 3-tier search strategy for matching SQS events to email logs
  - Enhanced debugging capabilities with both IDs stored in metadata

### Fixed
- **RateLimiter compilation warnings** - Resolved all Elixir compiler and Credo warnings
  - Added `require Logger` to fix Logger.warning/info/error undefined warnings
  - Replaced `Settings.set_setting/2` with correct `Settings.update_setting/2` function
  - Removed unused default value from `monitor_user/3` function signature
  - Fixed Dialyzer warnings for nested module aliases

### Technical Details

**Database Schema Changes:**
```
phoenix_kit_email_logs:
  + aws_message_id (string, nullable, unique when present)
  + bounced_at, complained_at, opened_at, clicked_at (naive_datetime)
  + Index: (aws_message_id) partial unique
  + Index: (message_id, aws_message_id) composite

phoenix_kit_email_events:
  + Index: (email_log_id, event_type) composite (10-100x performance)

phoenix_kit_email_orphaned_events: NEW
  + id (pk)
  + aws_message_id, event_type, event_timestamp
  + raw_data (map/jsonb)
  + matched_at (when orphan matched to log)

phoenix_kit_email_metrics: NEW
  + id (pk)
  + metric_name, metric_value
  + dimensions (map/jsonb for filtering)
  + recorded_at (timestamp)
```

**Event Processing Flow:**
1. **Search by internal message_id** - Primary lookup (fastest)
2. **Search by aws_message_id** - Secondary lookup for SQS events
3. **Create orphaned event** - If no match found, store for future correlation
4. **Match orphans periodically** - Background job to link late-arriving logs

**Benefits:**
- No false positives in duplicate detection (was catching different events with same type)
- 10-100x faster duplicate checking with composite indexes
- Reliable event matching with dual-ID strategy
- Complete audit trail with orphaned events tracking
- Better debugging with aws_message_id correlation

## 1.5.0 - 2025-11-10

### Added
- **Migration V21: Enhanced Security** - Indexes on security-critical fields for performance
  - Index on `phoenix_kit_users(email)` for faster authentication queries
  - Index on `phoenix_kit_user_tokens(user_id)` for efficient token lookups
  - Index on `phoenix_kit_sessions(user_id)` for session management
  - Index on `phoenix_kit_sessions(token)` for active session verification
  - Index on `phoenix_kit_user_role_assignments(user_id)` for role checks
  - Index on `phoenix_kit_settings(key)` for settings lookups

### Changed
- **Performance**: Authentication and authorization queries optimized with proper indexing
- **Security**: Faster session validation and token verification

## 1.4.0 - 2025-11-09

### Added
- **Idle Session Timeout** - Automatic logout after 30 minutes of inactivity
  - Configurable via `:idle_timeout_minutes` (default: 30 minutes)
  - Warning modal appears 2 minutes before logout
  - Countdown timer shows remaining time
  - Optional auto-renewal on user activity
  - Grace period for network latency (3 seconds)

### Changed
- **Session Management** - Enhanced with activity tracking
  - New `last_activity_at` field in sessions table
  - Automatic updates on page navigation and interactions
  - LiveView integration for real-time activity monitoring

### Fixed
- **Session Security** - Inactive sessions now automatically expire

## 1.3.0 - 2025-11-08

### Added
- **Session Fingerprinting** - Enhanced security with device fingerprinting
  - User agent tracking for device identification
  - IP address monitoring for location changes
  - Browser fingerprint detection using ClientJS
  - Session invalidation on suspicious activity
  - Automatic security alerts for users

### Changed
- **Session Schema** - New fields for fingerprinting
  - `user_agent` - Browser and device information
  - `ip_address` - Connection IP address
  - `fingerprint` - Unique browser fingerprint hash

### Fixed
- **Session Hijacking Protection** - Multiple security enhancements
  - Detects session stealing attempts
  - Validates device consistency
  - Monitors IP address changes
  - Alerts users to suspicious activity

## 1.2.13 - 2025-09-29

### Added
- **Email Template Management System** - Complete database-driven template system with CRUD operations and variable substitution
- **Template Editor Interface** - Full-featured LiveView editor with HTML structure, preview, and test functionality
- **Template List Interface** - Comprehensive template management with search, filtering, and status management
- **Mix Task for Template Seeding** - New `mix phoenix_kit.seed_templates` task for creating default system templates
- **Migration V15** - Database tables for email template storage with system template protection
- **Version Tracking in Migrations** - Enhanced migration system with PostgreSQL table comments for version tracking
- **Debug Logging for Email Metrics** - Enhanced error handling and debugging for chart data preparation

### Changed
- **Mailer Integration** - Updated to use database templates with fallback to hardcoded templates for backward compatibility
- **User Notifier** - Enhanced to support template-based email generation with variable substitution
- **Email Metrics Dashboard** - Improved chart data initialization and error handling for better reliability
- **Email Templates Search** - Simplified search form layout for better user experience

### Fixed
- **Email Metrics Chart Data** - Fixed initialization errors and null value handling in chart data preparation
- **Migration Rollback** - Added proper version tracking for migration rollback operations
- **Linter Issues** - Resolved alias ordering and function complexity issues for better code quality
- **Pre-commit Hooks** - Enhanced pre-commit validation with proper error handling

## 1.2.12 - 2025-09-27

### Added
- **Complete Email System Architecture** - New email_system module replacing legacy email_tracking with enhanced AWS SES integration and comprehensive event management
- **AWS SES Configuration Task** - New `mix phoenix_kit.configure_aws_ses` task for automated AWS infrastructure setup with configuration sets, SNS topics, and SQS queues
- **Enhanced SQS Processing** - New Mix tasks for queue processing and Dead Letter Queue management:
  - `mix phoenix_kit.process_sqs_queue` - Real-time SQS message processing for email events
  - `mix phoenix_kit.process_dlq` - Dead Letter Queue processing for failed messages
  - `mix phoenix_kit.sync_email_status` - Manual email status synchronization
- **V12 Migration** - Enhanced email tracking with AWS SES message ID correlation and specific event timestamps (bounced_at, complained_at, opened_at, clicked_at)
- **Email System LiveView Interfaces** - Reorganized email management interfaces with improved navigation and functionality
- **Extended Event Support** - Support for new AWS SES event types: reject, delivery_delay, subscription, and rendering_failure
- **Enhanced Status Management** - Expanded email status types including rejected, delayed, hard_bounced, soft_bounced, and complaint

### Changed
- **Email Architecture Refactoring** - Complete transition from email_tracking to email_system module for better organization and AWS SES integration
- **Email Event Processing** - Enhanced event handling with provider-specific data extraction and improved error recovery patterns
- **Database Schema** - Updated email logging with aws_message_id field and specific timestamp tracking for different event types
- **LiveView Organization** - Reorganized email-related LiveView modules under email_system namespace for better structure

### Removed
- **Legacy Email Tracking Module** - Removed entire email_tracking module and all associated files in favor of new email_system architecture
- **Old Email LiveView Interfaces** - Removed legacy email_tracking LiveView components and templates
- **Deprecated Email Processing** - Removed outdated email event processing and archiver implementations

### Fixed
- **Email System Integration** - Improved integration patterns for better performance and reliability
- **SQS Message Processing** - Enhanced message processing with proper error recovery and retry mechanisms
- **Email Event Handling** - Better handling of AWS SES events with improved message parsing and validation

## 1.2.11 - 2025-09-24

### Added
- **AWS SQS Integration** - Complete SQS worker and processor for real-time email event processing from AWS SES through SNS
- **Manual Email Sync** - New `sync_email_status/1` function to manually fetch and process SES events for specific messages
- **DLQ Processing** - Dead Letter Queue support for handling failed messages with comprehensive retry mechanisms
- **Mix Tasks for Email System**:
  - `mix phoenix_kit.email.send_test` - Test email sending functionality with system options
  - `mix phoenix_kit.email.debug_sqs` - Debug SQS messages and email system with detailed diagnostics
  - `mix phoenix_kit.email.process_dlq` - Process Dead Letter Queue messages and handle stuck events
- **Email System Supervisor** - OTP supervision tree for SQS worker management with graceful startup/shutdown
- **Application Integration Module** - Enhanced integration patterns for email system initialization

### Improved
- **Email Interceptor** - Enhanced with provider-specific data extraction for multiple email services (SendGrid, Mailgun, AWS SES)
- **Email System API** - Added manual synchronization and event fetching capabilities for both main queue and DLQ
- **Mailer Module** - Improved integration with email system and enhanced error handling patterns
- **Email Event Processing** - Better handling of AWS SES events with improved message parsing and validation

### Fixed
- **Email Status Processing** - Improved handling of delivery confirmations, bounce events, and open management
- **SQS Message Handling** - Enhanced message processing with proper error recovery and retry logic

### Added
- **Update Task Enhancement** - Added `--yes/-y` flag for skipping confirmation prompts and automatic migration execution

## 1.2.10 - 2025-09-21

### Improved
- **Authentication UI Consistency** - Unified design across all authentication pages (login, registration, magic link, account settings) with consistent card layouts, shadows, and spacing
- **Icon Integration** - Added icon slot support to input component enabling consistent iconography throughout forms using PhoenixKit's centralized icon system
- **User Experience** - Enhanced interaction feedback with hover scale animations and focus transitions on buttons and form elements
- **Visual Cohesion** - Removed background color inconsistencies and standardized visual hierarchy across all authentication flows
- **Development Documentation** - Comprehensive contributor guide with Phoenix built-in live reloading (primary method), custom FileWatcher fallback, GitHub workflow, and complete CONTRIBUTING.md documentation

### Added
- **Magic Link Integration** - Added Magic Link authentication option to login page with elegant divider and themed button
- **Account Settings Redesign** - Complete visual overhaul of settings page to match authentication pages design language
- **Flash Message Auto-dismiss** - Implemented automatic flash message dismissal after 10 seconds for improved user experience
- **Form Field Icons** - Email, password, and profile fields now display contextual icons (email, lock, user profile) for better visual clarity

### Changed
- **Magic Link Page Layout** - Redesigned magic link page with card-based layout matching login and registration pages
- **Settings Page Structure** - Restructured account settings with centered layout, improved typography, and consistent spacing
- **Input Component Enhancement** - Extended core input component to support icon slots while maintaining backward compatibility

## 1.2.9 - 2025-09-18

### Added
- **Auto-dismiss Flash Messages** - Flash messages now automatically dismiss after 5 seconds for improved UX
- **Smooth Animations** - Added fade-out transition effects for flash message dismissal
- **Manual Dismiss** - Retained close button functionality for immediate dismissal

### Changed
- **Flash Message Component** - Enhanced with JavaScript hooks for auto-dismiss functionality
- **Timer Behavior** - Timer resets on mouse hover, pauses dismissal until mouse leaves

## 1.2.8 - 2025-09-15

### Added
- **File Watcher System** - Custom file watching for automatic compilation and reloading during development
- **Live Reload Support** - Real-time updates when PhoenixKit files change in parent applications
- **Development Mix Tasks**:
  - `mix phoenix_kit.dev` - Start development mode with file watching
  - `mix phoenix_kit.dev.watch` - Watch specific paths for changes
  - `mix phoenix_kit.dev.compile` - Manual compilation trigger

### Improved
- **Developer Experience** - No need to restart server after PhoenixKit changes
- **Integration Testing** - Easier to test PhoenixKit changes in parent applications

## 1.2.7 - 2025-09-12

### Added
- **Role System** - Complete role-based access control
  - Three system roles: Owner, Admin, User
  - Many-to-many role assignments with audit trail
  - First registered user automatically becomes Owner
  - Admin dashboard with system statistics
  - User management interface
- **Admin Dashboard** - Built-in dashboard at `{prefix}/admin`
- **User Management** - Complete interface at `{prefix}/admin/users`

### Changed
- **User Registration** - Integrated with role system
- **Authentication Scope** - Enhanced with role checks

## 1.2.6 - 2025-09-08

### Added
- **Settings System** - Database-driven configuration management
  - Time zone configuration (UTC-12 to UTC+12)
  - Date format preferences (6 formats supported)
  - Time format options (12/24 hour)
- **Settings Interface** - Admin settings page at `{prefix}/admin/settings`
- **Date Utilities** - `PhoenixKit.Utils.Date` module for formatting

### Fixed
- **Date Display** - Consistent formatting across all pages

## 1.2.5 - 2025-09-05

### Added
- **Magic Link Authentication** - Passwordless login via email
- **Magic Link Routes** - Integrated into router macro

### Changed
- **Email Templates** - Added magic link email template

## 1.2.4 - 2025-09-02

### Fixed
- **Layout Integration** - Improved parent app layout support
- **Asset Loading** - Better handling of CSS/JS assets

## 1.2.3 - 2025-08-30

### Added
- **Theme System** - daisyUI integration with 35+ themes
- **Theme Configuration** - Customizable via application config

## 1.2.2 - 2025-08-25

### Fixed
- **Migration System** - Improved idempotent operations
- **Prefix Support** - Better PostgreSQL schema isolation

## 1.2.1 - 2025-08-20

### Added
- **Professional Migrations** - Oban-style versioned migration system
- **Update Task** - `mix phoenix_kit.update` for existing installations

## 1.2.0 - 2025-08-15

### Added
- **Installation System** - Igniter-based installation for new projects
- **Repository Auto-detection** - Automatic Ecto repo discovery

### Changed
- **Breaking**: New installation process via `mix phoenix_kit.install`

## 1.1.0 - 2025-08-10

### Added
- **Email Confirmation** - User email verification workflow
- **Password Reset** - Secure password recovery via email

## 1.0.0 - 2025-08-05

### Added
- **Initial Release** - Complete authentication system
- **User Schema** - Email-based authentication with bcrypt
- **Session Management** - Secure session handling
- **LiveView Components** - Registration, login, account settings
