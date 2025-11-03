## 1.4.9 - 2025-11-03

### Added
- **Comprehensive OAuth module testing** - Added 43 tests covering all OAuth components
  - OAuthConfigLoader worker: 7 tests for initialization, retry logic, and error handling
  - OAuthConfig module: 23 tests for provider configuration and credential validation
  - EnsureOAuthConfig plug: 13 tests for fallback mechanism and error responses
  - Tests work without database access for library integration

### Changed
- **Improved OAuth error handling** - Enhanced error categorization and recovery
  - Distinguish between retriable errors (cache not ready, DB connection) and non-retriable errors
  - Added specific error handling for RuntimeError, UndefinedFunctionError, DBConnection errors
  - OAuthConfigLoader now provides detailed status information through new APIs
- **Enhanced OAuth configuration APIs** - Added new public methods for monitoring
  - `OAuthConfigLoader.get_status/0` - Returns current configuration status with reason
  - `OAuthConfigLoader.reload_config/0` - Allows manual configuration reload
  - Better visibility into OAuth configuration state for debugging
- **Optimized supervisor startup order** - Moved OAuth loader after cache initialization
  - OAuthConfigLoader now starts after Settings cache is warmed
  - Reduces startup errors related to cache availability
  - More reliable OAuth configuration loading during application boot

### Fixed
- **Logging levels optimization** - Adjusted log levels for better observability
  - Changed debug logs to info for important OAuth configuration events
  - Added warning logs for missing credentials and configuration failures
  - Better distinction between expected startup behavior and actual issues
- **Code quality improvements**
  - Fixed Credo warning: converted explicit try blocks to implicit try with rescue
  - Fixed Dialyzer warning: removed unreachable pattern match in error handling
  - All code passes strict quality checks (Credo, Dialyzer, formatted)

### Impact
- OAuth module is now thoroughly tested and more resilient to startup race conditions
- Better error messages and logging help diagnose OAuth configuration issues
- New APIs enable monitoring tools and admin interfaces to check OAuth health
- Improved reliability when PhoenixKit is used as a library in parent applications

## 1.4.8 - 2025-11-02

### Fixes and improvements
- Improved and update project configuration files
- Changes to publishing module
  - Rrenamed to Blogs
  - Better 404 handling
  - Comprehensive markdown styling
  - Support both slug-mode and timestamp-mode blog URLs
  - Multi-language support with automatic fallback to default language
  - Trash logic for safe blog deletion
  - Various UI/UX enhancements to the blogging module in general

## 1.4.7 - 2025-10-30

### Fixed
- **CRITICAL: OAuth base_path preservation** - Fixed Ueberauth base_path being lost during provider configuration
  - Function `configure_ueberauth_base/0` now preserves existing base_path from configuration
  - Added `get_oauth_base_path/0` helper to automatically determine base path from PhoenixKit URL prefix
  - Prevents "Ueberauth plugin did not process request for provider" error
  - Ensures OAuth routes like `/phoenix_kit/users/auth/google` work correctly
  - File: lib/phoenix_kit/users/oauth_config.ex
- **CRITICAL: OAuth struct field access** - Fixed UndefinedFunctionError when processing OAuth callbacks
  - Replaced bracket notation `auth.credentials[:token]` with dot notation `auth.credentials.token`
  - Replaced `auth.credentials[:refresh_token]` with `auth.credentials.refresh_token`
  - Added safe `get_raw_info/1` helper for extracting raw_info with pattern matching
  - Fixes "Ueberauth.Auth.Credentials does not implement Access behaviour" error
  - OAuth callback processing now works correctly for all providers
  - File: lib/phoenix_kit/users/oauth.ex

### Impact
- OAuth authentication with Google, GitHub, Apple, and Facebook now works correctly
- Both bugs were critical and prevented OAuth from functioning entirely
- All existing OAuth configurations will work without any changes required

### Added
- New Publishing module for Blogs and News (date related posts)
- Pages Module disabled for now

## 1.4.6 - 2025-10-26

### Fixed
- **CRITICAL: Ueberauth MatchError timing issue** - Fixed OAuth provider initialization race condition
  - MatchError occurred when accessing `/phoenix_kit/users/auth/google`: `Ueberauth.get_providers/2 no match of right hand side value: :error`
  - Root cause: PhoenixKit.Supervisor often starts AFTER parent application's Endpoint
  - When Endpoint starts, router compiles and Ueberauth.init() requires :providers in config
  - But OAuth configuration wasn't loaded yet, causing :providers key to be missing
  - **Solution**: Created OAuthConfigLoader GenServer worker in PhoenixKit.Supervisor
    - Loads OAuth configuration SYNCHRONOUSLY during supervisor startup
    - Runs as FIRST child (before PubSub, Cache, etc.)
    - Waits up to 1 second for Settings cache to be ready with automatic retry
  - **Fallback**: Added EnsureOAuthConfig plug before Ueberauth plug
    - Detects missing :providers configuration at request time
    - Loads configuration synchronously if missing
    - Provides 503 error page if configuration cannot be loaded
    - Ensures OAuth always works even if supervisor ordering is incorrect
  - Files: lib/phoenix_kit/workers/oauth_config_loader.ex (new), lib/phoenix_kit_web/plugs/ensure_oauth_config.ex (new)
  - **Impact**: OAuth authentication now works reliably regardless of application startup order
  - **Auto-enable providers**: When OAuth credentials are saved, oauth_X_enabled auto-set to "true"

### Added
- **OAuthConfigLoader Worker** - `PhoenixKit.Workers.OAuthConfigLoader`
  - GenServer worker that loads OAuth configuration synchronously during startup
  - Runs as first child in PhoenixKit.Supervisor
  - Automatic retry with 100ms intervals (up to 10 attempts) if Settings cache not ready
  - Ensures OAuth providers are configured before any requests are processed
  - Prevents Ueberauth MatchError timing issues
- **EnsureOAuthConfig Plug** - `PhoenixKitWeb.Plugs.EnsureOAuthConfig`
  - Fallback plug that ensures OAuth configuration is loaded before Ueberauth plug
  - Detects missing :providers key in Ueberauth config
  - Loads configuration synchronously if missing
  - Returns 503 Service Unavailable if configuration cannot be loaded
  - Provides safety net for applications where PhoenixKit.Supervisor starts after Endpoint

### Upgrade Notes
- **No action required** - All changes are backward compatible
- OAuth authentication now works reliably regardless of supervisor ordering
- Existing OAuth credentials will auto-enable their providers on next settings save

## 1.4.5 - 2025-10-26

### Fixed
- **CRITICAL: OAuth halt() missing in request handler** - Fixed 500 errors when clicking OAuth sign-in buttons
  - Added missing `halt(conn)` in `handle_oauth_request()` to prevent Phoenix from attempting to render non-existent template
  - OAuth redirects to provider now work correctly without server errors
  - Ueberauth plug properly halts connection after processing
  - Fixed in lib/phoenix_kit_web/users/oauth.ex:106
- **HIGH PRIORITY: IPv6 Protocol.UndefinedError** - Fixed crashes when extracting IPv6 addresses
  - Created centralized `PhoenixKit.Utils.IpAddress` module with proper pattern matching
  - IPv4 addresses: `{a, b, c, d}` pattern with is_integer guards
  - IPv6 addresses: `{a, b, c, d, e, f, g, h}` pattern with is_integer guards
  - Invalid/nil handling: returns "unknown" safely
  - Removed 7 duplicate implementations across codebase (dashboard, login, registration, magic_link, live_sessions, geolocation, oauth modules)
- **Google OAuth credentials test not working after save** - Fixed credentials validation after update
  - Auto-reload OAuth configuration immediately after credentials save via `OAuthConfig.configure_providers()`
  - Test Credentials button now works immediately without manual reload
  - Runtime Ueberauth configuration updates with new database values
  - Fixed in lib/phoenix_kit_web/live/settings.ex with provider configuration reload
- **OAuth credentials error messages unclear** - Improved user-friendly error reporting
  - Changed field names in error messages: 'client_id' → 'Client ID', 'client_secret' → 'Client Secret', etc.
  - Google: Shows 'Missing Google OAuth credentials: Client ID, Client Secret'
  - Apple: Shows team_id, key_id, private_key with proper names
  - GitHub and Facebook: Clear field names for all required credentials
  - Fixed in lib/phoenix_kit/users/oauth_config.ex
- **AWS credentials verification issues** - Simplified verification process
  - Removed misleading permission checks from AWS credentials validator
  - Focus on essential credential validation without speculative permission testing
  - Cleaner error feedback for AWS SES/SNS/SQS setup
- **Settings save error diagnostics** - Improved error collection on batch updates
  - Detailed error information for each failed setting
  - Clear field-specific error messages: 'Failed to save settings: field_name (reason)'
  - Better troubleshooting information in logs
  - Fixed in lib/phoenix_kit/settings/settings.ex
- **CRITICAL: AWS Infrastructure Setup** - Email sending now works in containerized environments
  - Removed AWS CLI dependency for SES configuration (steps 8-9)
  - Fixed sweet_xml compatibility when library is installed
  - Fixed SQS queue attribute format (atom keys instead of string keys)
  - Infrastructure setup now works reliably in Docker, Kubernetes, and all environments

### Changed
- **IPv6/IPv4 Extraction** - Centralized IP extraction utility
  - `IpAddress.extract_from_socket/1` - Extract from LiveView socket
  - `IpAddress.extract_from_conn/1` - Extract from Plug.Conn
  - `IpAddress.extract_ip_address/1` - Extract from peer_data directly
  - Updated 7 files to use centralized module instead of duplicate implementations
- **OAuth Configuration Management** - Automatic runtime reload on credential updates
  - Credentials now updated immediately after save without manual intervention
  - Ueberauth providers reconfigured from database values
  - Settings integration with live configuration updates
- **AWS Credentials Validation** - Streamlined verification process
  - Focus on credential format and basic validation
  - No speculative AWS API calls during validation
  - Clearer feedback for users configuring AWS services
- **AWS Integration** - Improved reliability and idempotency
  - SES configuration set creation now uses SES v2 REST API
  - SES event destination setup now uses SES v2 REST API
  - Response parsing handles both atom-key and string-key formats
  - Queue creation properly handles existing resources

### Added
- **IpAddress Utility Module** - `PhoenixKit.Utils.IpAddress`
  - Proper IPv4 and IPv6 address parsing with guard clauses
  - Comprehensive documentation with usage examples
  - Full test coverage (17 tests: 4 doctests + 13 unit tests)
  - Support for LiveView sockets and Plug.Conn connections
- **OAuth Auto-Configuration** - Automatic provider setup on credential save
  - `OAuthConfig.configure_providers()` called after settings update
  - Ensures Ueberauth runtime config matches database configuration
  - No restart required for credential changes
- **Improved Error Messages** - User-friendly OAuth field names
  - Human-readable field names in validation errors
  - Clear guidance on missing required credentials
  - Supports all OAuth providers (Google, Apple, GitHub, Facebook)
- **SES v2 API Module** - `PhoenixKit.AWS.SESv2`
  - `create_configuration_set/2` - Creates SES configuration set via API
  - `create_configuration_set_event_destination/4` - Configures event tracking
  - Automatic "already exists" error handling
  - Production-ready error messages

### Technical Details
- **OAuth Request Handling:** Missing halt(conn) in handle_oauth_request() caused Phoenix to attempt rendering non-existent template
  - Fixed: Added halt(conn) with detailed explanation (lib/phoenix_kit_web/users/oauth.ex:106)
- **IPv6 Address Extraction:** Calling to_string() on IPv6 tuples caused Protocol.UndefinedError
  - Root cause: Seven files had duplicate extract_ip_address() implementations without proper guards
  - Fixed: Centralized to IpAddress module with is_integer guard clauses
  - Impact: Users with IPv6 addresses no longer get crashes when IPs are extracted
- **Google OAuth Credentials:** Test button showed "missing credentials" after save
  - Root cause: OAuth runtime configuration not reloaded after database update
  - Fixed: Added OAuthConfig.configure_providers() call in settings save handler
  - Impact: Credentials work immediately after save without manual reload
- **OAuth Error Messages:** Field names were cryptic (client_id, client_secret, etc.)
  - Fixed: Map field names to user-friendly equivalents (Client ID, Client Secret)
  - Improves user experience for credential configuration
- **AWS Credentials Validation:** Permission checks were speculative and misleading
  - Fixed: Remove AWS API calls from validator, focus on format validation
  - Cleaner error feedback without false negatives
- **AWS Issue #1 (sweet_xml):** ExAws + sweet_xml returns flat maps with atom keys
  - Fixed: Account ID, SNS Topic ARN, Subscription ARN parsing
- **AWS Issue #2 (SQS attributes):** ExAws.SQS requires keyword lists with atom keys
  - Fixed: Queue creation and policy setting across all steps
- **AWS Issue #3 (AWS CLI):** Email sending failed silently in Docker/Kubernetes
  - Fixed: Complete SES v2 API implementation without external dependencies

### Files Changed
- **New:** lib/phoenix_kit/utils/ip_address.ex (102 lines)
- **Updated:**
  - lib/phoenix_kit_web/live/settings.ex - Add OAuth config reload on credential save
  - lib/phoenix_kit_web/users/login.ex - Use centralized IpAddress module
  - lib/phoenix_kit_web/users/registration.ex - Use centralized IpAddress module
  - lib/phoenix_kit_web/users/magic_link.ex - Use centralized IpAddress module
  - lib/phoenix_kit_web/live/dashboard.ex - Use centralized IpAddress module
  - lib/phoenix_kit_web/live/users/live_sessions.ex - Use centralized IpAddress module
  - lib/phoenix_kit_web/users/oauth.ex - Add halt(conn) + use centralized IpAddress module
  - lib/phoenix_kit/utils/geolocation.ex - Use centralized IpAddress module
  - lib/phoenix_kit/users/oauth_config.ex - Improve OAuth credential error messages
  - lib/phoenix_kit/settings/settings.ex - Improve error collection on batch updates

### Commits Included
- bfe808f - Fix critical OAuth and IPv6 handling issues
- 9aeb5ca - Fix Google OAuth credentials test and improve OAuth configuration
- 25df3a7 - Simplify AWS credentials verification to remove misleading permission checks
- b29de2d - Add AWS credentials verification with permission checks
- bf2dd73 - Fix critical AWS infrastructure setup for containerized environments

### Upgrade Notes
- **No action required** - All changes are backward compatible
- OAuth sign-in buttons now work reliably without 500 errors
- Google OAuth credentials save immediately without manual reload
- Users with IPv6 addresses no longer experience crashes
- AWS SES email delivery works in containerized environments
- Existing AWS infrastructure continues to work
- Docker/Kubernetes deployments now work without manual intervention
- Re-run setup if previous AWS attempts failed: `PhoenixKit.AWS.InfrastructureSetup.run(project_name: "yourapp")`

## 1.4.4 - 2025-10-23

### Fixed
- Refactor parent project modules identification
- Update OAuth settings UI with new components
- Updated igniter script with more bulletproofing

## 1.4.3 - 2025-10-22

### Fixed
- **Installer Robustness** - Universal compatibility with complex config files
  - Added support for runtime.exs with Dotenvy and environment variables
  - Comprehensive error handling prevents crashes on complex syntax
  - Smart import_config detection ensures proper configuration order
  - Multiple fallback strategies (AST parsing → File operations → manual instructions)
- **Duplicate Prevention** - Installation now truly idempotent
  - Added duplicate detection for all configurations (repo, layout, mailer, Swoosh)
  - Integration plug no longer duplicates on multiple installs
  - All config checks prevent adding same configuration twice
- **Igniter Tracking** - Fixed file change tracking warnings
  - All file modifications now properly tracked by Igniter
  - Eliminated "file changed since read" warnings

### Changed
- **Error Recovery** - Graceful degradation with clear user feedback
  - All installer modules wrapped in comprehensive try/rescue blocks
  - Clear manual configuration instructions when automatic fails
  - IO.warn messages for debugging failed operations
 
## 1.4.2 - 2025-10-22

### Fixed
- We removed unecessary catch all for routing
- Fixed issue with runtime not working when installing with project is setup to use .env files

## 1.4.1 - 2025-10-21

### Added
- **OAuth User Settings** - Connected Accounts management interface in user settings
  - View all linked OAuth providers (Google, Apple, GitHub, Facebook)
  - Connect additional OAuth accounts to existing user profile
  - Disconnect OAuth providers with security validation
  - User-friendly instructions for OAuth account linking
  - Email verification matching for OAuth connections
- **OAuth Setup Instructions** - In-app Google OAuth configuration guide
  - Step-by-step Google Cloud Console setup instructions
  - Callback URL display for easy copying
  - Collapsible instructions panel in admin settings
  - Reverse proxy configuration examples (nginx/apache)

### Changed
- **OAuth Infrastructure** - Automatic HTTPS detection and deployment improvements
  - X-Forwarded-Proto header detection for reverse proxies
  - OAuth callbacks work out-of-box behind nginx/apache
  - Manual oauth_base_url override for edge cases
  - OAuth2.AccessToken serialization in JSONB fields
- **Email UI** - Enhanced table components
  - Replace HTML tables with reusable `.table_default` component
  - Consistent table styling across email details

### Fixed
- **OAuth Integration** - EnsureOAuthScheme plug integration
- **Code Quality** - Credo readability improvements in OAuth modules
- **Icon Management** - Centralized all OAuth icons to Core.Icons module

### Upgrade Notes
- OAuth providers require matching email addresses between provider and PhoenixKit account
- Users can manage connected accounts at `/users/settings`
- At least one authentication method (password or OAuth) required for account access

## 1.4.0 - 2025-10-17

### Added
- **Pages Content System** - Full Markdown-driven site with admin file navigator, metadata-aware editor, and public rendering at `/pages/*` routes
- **User Custom Fields** - WordPress ACF-like JSONB custom fields system with column filtering, reordering, and management interface
- **Collaborative Editing** - FIFO locking system for entities with real-time presence tracking and PubSub event broadcasting
- **Content Language Module** - Multi-language support with language switcher, locale routing, and language management interface
- **User Settings** - Default user status on creation, automatic email confirmation for first user, timezone settings with geolocation IP tracking

### Changed
- **Email Operations** - Sender profile configuration, one-click AWS infrastructure setup, prioritized credentials (Settings DB → ENV)
- **Developer Experience** - OAuth/email dependencies now mandatory, `mix phoenix_kit.* --help` support, `IgniterCompat` for cleaner installs
- **Navigation** - Admin navigation uses LiveView navigate for instant transitions, disabled long-polling for faster cleanup

### Fixed
- **Custom Fields** - Column updates when deleting custom fields
- **Critical Bugs** - Ecto.SubQueryError in user role filtering, OAuth checkbox errors, PhoenixKit.Config usage issues
- **Email System** - AWS credential bugs, SQS message loss, chart initialization, idempotency/deduplication improvements
- **Code Quality** - Cleaned up Dialyzer/Credo warnings, improved logging, removed excessive debug output

### Upgrade Notes
- Run `mix deps.get` to install mandatory OAuth/email packages
- Enable Pages module from `/admin/modules` to use content management
- Custom fields available in user management submenu

## 1.3.5 - 2025-10-16

### Added
- **Pages Module** - File-based content management system spanning admin and public workflows
  - Tree-based navigator in `/admin/pages` for creating, moving, duplicating, and deleting Markdown content
  - Full-screen editor with metadata controls (status, timestamps) and unsaved-change safeguards
  - Public rendering pipeline that serves published pages at `/pages/*` and the catch-all root route
- **Email Sender Configuration** - Dynamic from_email and from_name settings via admin interface
  - New Sender Configuration form at `/admin/settings/emails`
  - 3-tier priority system: Settings DB → Config → Defaults
  - Live preview showing how emails will appear to recipients
  - All outgoing emails now use dynamic sender information
  - Settings update immediately without restart

### Fixed
- **Email Dashboard Chart Initialization** - Resolved chart rendering issues on initial page load
  - Added Promise-based Chart.js library loading with retry mechanism
  - Implemented event buffering for chart data when charts not ready
  - Enhanced lifecycle handling with multiple LiveView events
  - Added exponential backoff retry (up to 5 attempts)
  - Charts now reliably render even with slow network conditions
- **Code Quality Issues** - Fixed Dialyzer warnings and Credo recommendations
  - Resolved nested module aliasing warnings across 26 files
  - Fixed function complexity issues (cyclomatic complexity reduced)
  - Improved code efficiency with Enum.map_join instead of map + join
  - Fixed "last clause in with is redundant" patterns
  - Alphabetized module aliases for better organization

### Improved
- **Documentation** - Reduced CLAUDE.md to core guidance and moved module-specific content into Emails/Pages/Entities READMEs plus a new OAuth & Magic Link guide
- **Installer Experience** - Added an `IgniterCompat` helper so installer modules compile quietly even when Igniter isn't installed

## 1.3.4 - 2025-10-15

### Added
- **AWS Infrastructure Automation** - One-click AWS email infrastructure setup from admin web interface
  - New PhoenixKit.AWS.InfrastructureSetup module for automated resource creation
  - Creates SNS Topic, SQS Queues, DLQ, and SES Configuration Set with one click
  - Idempotent operations (safe to run multiple times)
  - Web interface at `/admin/settings/emails` with "Setup AWS Infrastructure" button
  - Auto-fills AWS settings form with created resource details
  - Added `ex_aws_sns ~> 2.3` dependency for SNS operations
- **Mix Tasks Help System** - Comprehensive `--help` flag support for installation and update tasks
  - `mix phoenix_kit.install --help` - Detailed installation options with examples
  - `mix phoenix_kit.update --help` - Update task documentation with CI/CD guidelines
  - Usage examples, option descriptions, and troubleshooting tips
  - Auto-detection capabilities explanation
- **Public AWS Credentials API** - Centralized AWS credentials management with smart fallback
  - `PhoenixKit.Emails.aws_configured?()` - Public function for checking AWS setup
  - Settings Database as primary source, Environment Variables as fallback
  - Improved error messages mentioning both Web UI and ENV configuration

### Changed
- **AWS Credentials Priority** - Settings Database now takes precedence over Environment Variables
  - Primary: Settings Database (runtime configuration via Web UI)
  - Fallback: Environment Variables (for production secrets)
  - Users can configure credentials via Web UI without ENV duplication
  - Maintains backward compatibility for ENV-only deployments
- **Documentation Updates** - Comprehensive guide for AWS setup and credentials management
  - CLAUDE.md expanded with 540+ new lines
  - Added AWS Credentials Priority section with configuration scenarios
  - Removed obsolete config-based email configuration examples
  - Added Installation and Update help system documentation

### Fixed
- **AWS Credentials Configuration Bug** - Fixed issue where Settings DB credentials were ignored
  - `get_sqs_config()` now uses helper functions with Settings DB → ENV fallback
  - `has_aws_credentials()` properly checks both Settings DB and ENV
  - SQS Worker now respects Web UI configured credentials
- **Test Email URLs** - Fixed test email links to use site_url from settings instead of localhost

## 1.3.3 - 2025-10-14

### Changed
- **Dependency Management** - Made OAuth authentication dependencies mandatory instead of optional
  - `ueberauth`, `ueberauth_google`, `ueberauth_apple`, and `ueberauth_github` are now required dependencies
  - Ensures OAuth functionality works out-of-the-box without manual dependency configuration
  - Simplifies installation process for new users
- **Email System Dependencies** - Added required dependencies for complete email functionality
  - `gen_smtp` - Required for Amazon SES SMTP email adapter
  - `saxy` - Required for AWS SQS XML response parsing
  - `finch` - HTTP client for AWS API communication (already included)
  - Ensures complete email system support without additional configuration
  - Improves reliability of email delivery and event tracking through AWS SES/SQS

### Fixed
- **AWS Credentials Configuration** - Fixed critical issue where AWS credentials entered via Web UI were ignored
  - Problem: Settings Database credentials were not being used, system only checked Environment Variables
  - Solution: Updated `get_sqs_config()` to use Settings DB → ENV fallback pattern
  - Updated `has_aws_credentials()` to properly check both Settings DB and ENV
  - Made `aws_configured?()` public function for use across modules
  - Enhanced error messages to mention both Web UI and ENV configuration methods
  - Added comprehensive documentation in CLAUDE.md about credentials priority system

### Improved
- **Settings DB Priority System** - Clarified and enforced credentials configuration priority
  - Primary: Settings Database (runtime configuration via Web UI at `/admin/settings/emails`)
  - Fallback: Environment Variables (for production secrets and legacy deployments)
  - Users can now configure credentials via Web UI without ENV duplication
  - Maintains backward compatibility for ENV-only deployments

### Migration Notes
- Projects upgrading from 1.3.2 must run `mix deps.get` to install new required dependencies
- OAuth features now work automatically without manual dependency installation
- Amazon SES email adapter now fully functional without additional setup
- AWS credentials can now be configured via Web UI; ENV variables optional

## 1.3.2 - 2025-10-10

### Fixed
- **Critical: Email System SQS Message Loss Bug** - Fixed critical bug where manual email status sync was deleting ALL messages from SQS queue, including non-matching ones
  - Issue #1: Non-matching messages now stay in queue for normal SQS worker processing
  - Prevents permanent data loss of delivery events from AWS SES

- **Email Event Deduplication** - Added deduplication for events from multiple queues
  - Issue #2: Events from both SQS and DLQ are now deduplicated by message_id + event_type
  - Prevents duplicate event records when same event exists in both queues

- **Email Event Idempotency** - Enhanced idempotency checks for all event types
  - Issue #3: Added duplicate prevention for bounce, complaint, and reject events
  - Completes idempotency coverage (delivery, open, click already had checks)
  - Prevents duplicate events during retry scenarios and race conditions

- **SQS Polling Optimization** - Reduced AWS API calls by up to 80%
  - Issue #4: Manual sync now stops after first match instead of polling all batches
  - Saves API costs and reduces latency (from 10s to 2s average)

- **System Settings Integration** - Fixed hardcoded values in manual sync
  - Issue #5: Now uses `get_sqs_max_messages()` and `get_sqs_visibility_timeout()` from settings
  - Issue #6: Visibility timeout increased from 30s to system default (300s)
  - Prevents race conditions during long-running operations

### Improved
- **Error Logging** - Stacktrace formatting improved for better debugging
  - Issue #7: Uses `Exception.format_stacktrace()` for readable log output

- **Code Quality** - Removed redundant `require Logger` statements
  - Issue #8: Single module-level `require Logger` instead of 11 duplicate requires
  - Cleaner codebase following Elixir best practices

### Technical Details
- Modified files:
  - `lib/phoenix_kit/emails/emails.ex` (77 changes)
  - `lib/phoenix_kit/emails/sqs_processor.ex` (66 changes)
- All changes verified with successful compilation
- Based on comprehensive code review identifying 8 issues (1 critical, 2 high, 3 medium, 2 low priority)

## 1.3.1 - 2025-10-07

  ### Fix: Admin Role Access with Real-time Scope Refresh
  Implemented a PubSub-based scope refresh system that updates sessions in real-time without forcing
  logouts:
  - **New Module**: `PhoenixKit.Users.ScopeNotifier` manages user-specific PubSub topics for role changes
  - **LiveView Integration**: Sessions automatically subscribe to their user's topic and rebuild the cached
  scope when roles change
  - **Admin Demotion Handling**: Users who lose admin privileges are immediately redirected from admin pages
   with clear error messaging
  - **Transaction Safety**: Role mutations use broadcast flags to prevent partial-state notifications during
   database transactions

  Additional Improvements:

  - **Better Error Messages**: Now distinguishes between "not logged in" vs "logged in but insufficient
  role" scenarios
  - **Subscription Lifecycle**: Proper subscription management when users switch or sessions end
  - **Safe User Fetching**: Added `get_user/1` helper that returns `nil` instead of raising exceptions

  Technical Details:

  - Broadcasts happen on `phoenix_kit:user_scope:#{user_id}` topics
  - LiveViews attach a `:handle_info` hook to process `{:phoenix_kit_scope_roles_updated, user_id}` messages
  - Scope refresh compares old vs new admin status to trigger redirects only when necessary
  - Edge cases handled: user deletion mid-session, owner role protection, non-admin page refreshes

## 1.3.0 - 2025-10-06

### Added
- **Magic Link Registration System** - Passwordless two-step registration via email
  - New `PhoenixKit.Users.MagicLinkRegistration` context for registration link management
  - Magic link request LiveView at `{prefix}/users/register/magic-link`
  - Registration completion LiveView at `{prefix}/users/register/complete/:token`
  - Configurable expiry time (default: 30 minutes)
  - Automatic email verification on completion
  - Referral code support in registration flow
  - Database V16 migration: Modified tokens table to allow null user_id for magic_link_registration context
  - Check constraint ensuring user_id required for all non-registration token contexts
- **OAuth Provider Validation** - Enhanced OAuth request handling with configuration checks
  - Provider existence validation before authentication flow
  - Helpful error messages when OAuth not configured or provider not found
  - Debug logging for OAuth authentication flow
  - Graceful fallback to login page with user-friendly error messages

### Changed
- **OAuth Dependencies Made Optional** - OAuth authentication dependencies (`ueberauth`, `ueberauth_google`, `ueberauth_apple`) are now marked as optional
  - Reduces dependency bloat for applications not using OAuth
  - Applications wanting OAuth must explicitly add dependencies to their `mix.exs`
  - Detailed setup instructions added to CLAUDE.md with step-by-step configuration guide
  - Improved referral code handling in OAuth flow with safe fallback when ReferralCodes module not loaded

### Improved
- **OAuth Documentation** - Comprehensive setup guide with environment variable configuration
  - Clear dependency installation instructions
  - Provider configuration examples for Google and Apple Sign-In
  - Environment variable setup guide for development and production
  - Migration notes for V16 oauth_providers table and magic link registration

### Fixed
- **Dialyzer Warnings** - Updated line number references for OAuth controller pattern matching
- **Entities Menu Navigation** - Fixed main Entities menu staying selected when clicking entity submenus by adding `disable_active={true}` attribute
- **New Nav Bar** - Added new top nav bar with update interface for comfort and ease of use

### UI/UX Improvements
- **Hero Icons Migration** - Migrated modules page to use Heroicons for consistent icon system
  - Replaced custom icon components with hero-icons: `hero-arrow-left`, `hero-cog-6-tooth`, `hero-users`, `hero-envelope`, `hero-information-circle`
  - Consistent sizing and theming across dashboard and modules pages

## 1.2.14 - 2025-09-30

### Added
- **Email Queue LiveView** - Complete real-time queue monitoring interface with system status, rate limit tracking, and failed email management
  - System status cards showing online status, daily sent count, failed emails (24h), and retention settings
  - Rate limit status display with visual progress bars for global, recipient, sender limits and blocklist statistics
  - Failed emails management table with individual retry and bulk operations support
  - Recent activity table displaying last 20 emails with delivery, open, and click event badges
  - Auto-refresh every 10 seconds for real-time monitoring
  - Bulk retry and delete operations with confirmation workflow
- **Email Blocklist LiveView** - Full-featured blocklist management interface with comprehensive filtering and bulk operations
  - Statistics dashboard showing total blocks, active blocks, and expired blocks
  - Advanced search and filtering by email address, reason, and status (active/expired)
  - Add block form with support for temporary blocks (expiration dates) and multiple block reasons
  - CSV import/export functionality for bulk blocklist management
  - Bulk operations: remove selected addresses and export selected to CSV
  - Pagination support (50 entries per page) with navigation controls
  - Auto-refresh every 30 seconds with manual refresh option
  - Visual status indicators for active and expired blocks
- **Template-Mailer Integration** - Production-ready template system integration with automatic tracking
  - New `PhoenixKit.Mailer.send_from_template/4` main API for sending templated emails
  - Convenience wrapper `PhoenixKit.Emails.Templates.send_email/4` for cleaner API
  - Automatic template loading by name with status validation
  - Variable substitution with template rendering
  - Automatic usage tracking (usage_count and last_used_at updates)
  - EmailLog system integration for delivery tracking
  - Support for custom from addresses, reply-to, and metadata
  - Comprehensive error handling (template_not_found, template_inactive)
- **RateLimiter Blocklist API** - Three new public API methods for blocklist management
  - `list_blocklist/1` - Query blocklists with filtering (search, reason, status), sorting, and pagination
  - `count_blocklist/1` - Count blocked emails with optional filters
  - `get_blocklist_stats/0` - Retrieve blocklist statistics including total, active, expired, and by-reason breakdowns
- **Emails.delete_log/1** - New public API method for email log deletion with proper error handling
- **Email Headers Management** - Complete headers tracking system with AWS SES integration
  - New `email_save_headers` setting to control headers saving behavior
  - Headers automatically populated from AWS SES events via SQS processor
  - Headers extracted from all SES event types (send, delivery, bounce, complaint, open, click, reject, delay, subscription)
  - New API methods: `save_headers_enabled?()`, `set_save_headers(enabled)`
  - Admin UI toggle for enabling/disabling headers collection
  - Headers button in email details hidden when no headers exist
- **Emails Advanced Settings** - Expanded configuration API for lifecycle and monitoring
  - `set_compress_after_days(days)` - Configure email body compression timing (7-365 days)
  - `set_s3_archival(enabled)` - Enable/disable S3 archival for old email data
  - `set_cloudwatch_metrics(enabled)` - Toggle CloudWatch metrics integration
  - `set_sqs_max_messages(count)` - Configure SQS polling batch size (1-10 messages)
  - `set_sqs_visibility_timeout(seconds)` - Set SQS message visibility timeout (30-43200 seconds)
  - Enhanced Emails Settings LiveView with compression, archival, CloudWatch, and SQS controls

### Changed
- **Template Editor** - Enhanced with test send and draft save capabilities
  - Test send functionality now available in both new and edit modes (previously edit-only)
  - New "Save as Draft" button in creation mode for saving incomplete templates
  - Smart status handling: regular save creates active templates, draft save creates draft templates
  - Improved user experience allowing template testing before final save
- **Template Variable System** - Complete overhaul with automatic management
  - Automatic variable extraction from template content (subject, html_body, text_body)
  - Smart default descriptions for 20+ common variables (user_name, email, url, etc.)
  - Inline editing of variable descriptions with real-time updates
  - Variables automatically added to changeset during validation and save
  - Removed manual "Add" button workflow in favor of automatic detection
  - Visual improvements with better empty states and usage instructions
- **Template Editor Preview** - Iframe-based isolation for template preview
  - HTML preview now rendered in sandboxed iframe to prevent style leakage
  - Template styles no longer affect editor UI layout
  - Automatic height adjustment based on content
  - Improved security with sandbox restrictions
- **Template Form Validation** - Fixed changeset handling and error display
  - Corrected form binding from nested map to direct changeset
  - Fixed error extraction using `Keyword.get` instead of `get_in`
  - Applied fixes to all 8 form fields (name, slug, display_name, category, status, description, subject, html_body, text_body)
- **Template Slug Auto-generation** - Improved logic for reliable slug creation
  - Moved slug generation before validation in changeset pipeline
  - Enhanced to check both changeset changes and existing field values
  - Handles both nil and empty string cases properly
  - Made slug field visible on editor form with helper text

### Fixed
- **Template Creation Errors** - Resolved Access.get/3 function clause errors in template editor forms
- **Variable Description Editing** - Fixed inability to edit variable descriptions after auto-addition
- **Template Editor Modal** - Removed unnecessary modal step in template creation workflow
- **Slug Validation** - Fixed "slug can't be blank" errors with improved auto-generation timing
- **Code Quality Issues** - Fixed all compiler warnings, Credo issues, and Dialyzer errors
  - Fixed nested module aliasing in SQS processor (Credo software design warning)
  - Removed Logger metadata keys not found in config (compiler warnings)
  - Fixed nested code depth issue by extracting helper function (Credo refactoring warning)
  - Removed unreachable pattern match clause in email interceptor (Dialyzer error)

### Improved
- **Emails Code Quality** - Enhanced error handling and logging across emails modules
- **SQS Processor Architecture** - Refactored headers update logic with proper function extraction and reduced nesting depth
- **LiveView Performance** - Optimized data loading and real-time updates in queue and blocklist interfaces
- **User Experience** - Streamlined template creation and management workflows

## 1.2.13 - 2025-09-29

### Added
- **Email Template Management System** - Complete database-driven template system with CRUD operations and variable substitution
- **Template Editor Interface** - Full-featured LiveView editor with HTML structure, preview, and test functionality
- **Template List Interface** - Comprehensive template management with search, filtering, and status management
- **Mix Task for Template Seeding** - New `mix phoenix_kit.seed_templates` task for creating default system templates
- **Migration V15** - Database tables for email template storage with system template protection
- **Version Tracking in Migrations** - Enhanced migration system with PostgreSQL table comments for version tracking
- **Debug Logging for Email Metrics** - Enhanced error handling and debugging for chart data preparation
- **Automatic Variable Extraction** - Smart detection and extraction of template variables with intelligent descriptions
- **Smart Variable Descriptions** - Automatic mapping of common template variables to user-friendly descriptions

### Changed
- **Mailer Integration** - Updated to use database templates with fallback to hardcoded templates for backward compatibility
- **User Notifier** - Enhanced to support template-based email generation with variable substitution
- **Email Metrics Dashboard** - Improved chart data initialization and error handling for better reliability
- **Email Templates Search** - Simplified search form layout for better user experience
- **Template Editor Workflow** - Simplified template creation process with automatic variable detection and validation

### Fixed
- **Email Metrics Chart Data** - Fixed initialization errors and null value handling in chart data preparation
- **Migration Rollback** - Added proper version tracking for migration rollback operations
- **Linter Issues** - Resolved alias ordering and function complexity issues for better code quality
- **Pre-commit Hooks** - Enhanced pre-commit validation with proper error handling
- **Template Slug Generation** - Fixed auto-generation logic for better handling of template names and slugs
- **Template Validation Flow** - Improved validation sequence for better user experience during template editing

### Removed
- **Modal Template Creation** - Removed modal-based template creation interface in favor of simplified direct editor workflow

## 1.2.12 - 2025-09-27

### Added
- **Complete Emails Architecture** - New email_system module replacing legacy email_tracking with enhanced AWS SES integration and comprehensive event management
- **AWS SES Configuration Task** - New `mix phoenix_kit.configure_aws_ses` task for automated AWS infrastructure setup with configuration sets, SNS topics, and SQS queues
- **Enhanced SQS Processing** - New Mix tasks for queue processing and Dead Letter Queue management:
  - `mix phoenix_kit.process_sqs_queue` - Real-time SQS message processing for email events
  - `mix phoenix_kit.process_dlq` - Dead Letter Queue processing for failed messages
  - `mix phoenix_kit.sync_email_status` - Manual email status synchronization
- **V12 Migration** - Enhanced email tracking with AWS SES message ID correlation and specific event timestamps (bounced_at, complained_at, opened_at, clicked_at)
- **Emails LiveView Interfaces** - Reorganized email management interfaces with improved navigation and functionality
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
- **Emails Integration** - Improved integration patterns for better performance and reliability
- **SQS Message Processing** - Enhanced message processing with proper error recovery and retry mechanisms
- **Email Event Handling** - Better handling of AWS SES events with improved message parsing and validation

## 1.2.11 - 2025-09-24

### Added
- **AWS SQS Integration** - Complete SQS worker and processor for real-time email event processing from AWS SES through SNS
- **Manual Email Sync** - New `sync_email_status/1` function to manually fetch and process SES events for specific messages
- **DLQ Processing** - Dead Letter Queue support for handling failed messages with comprehensive retry mechanisms
- **Mix Tasks for Emails**:
  - `mix phoenix_kit.email.send_test` - Test email sending functionality with system options
  - `mix phoenix_kit.email.debug_sqs` - Debug SQS messages and emails with detailed diagnostics
  - `mix phoenix_kit.email.process_dlq` - Process Dead Letter Queue messages and handle stuck events
- **Emails Supervisor** - OTP supervision tree for SQS worker management with graceful startup/shutdown
- **Application Integration Module** - Enhanced integration patterns for emails initialization

### Improved
- **Email Interceptor** - Enhanced with provider-specific data extraction for multiple email services (SendGrid, Mailgun, AWS SES)
- **Emails API** - Added manual synchronization and event fetching capabilities for both main queue and DLQ
- **Mailer Module** - Improved integration with emails and enhanced error handling patterns
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

### Improved
- **Icon System Centralization** - Consolidated all inline SVG icons across the codebase into centralized PhoenixKitWeb.Components.Core.Icons module for better maintainability and consistency
- **Authentication Pages Icons** - Migrated 10 inline SVG icons from login, registration, and magic link pages to centralized icon components (email, lock, user profile, user add, login icons)
- **Component Reusability** - Migrated 50+ SVG icons from 20+ template files to reusable component functions with configurable CSS classes
- **Code Quality** - Eliminated duplicate SVG code and standardized icon usage patterns throughout admin interfaces, forms, and user authentication flows
- **LiveView Module Organization** - Reorganized LiveView modules into logical subfolders for better structure
- **Route Organization** - Restructured admin routes with improved hierarchical organization
- **Email URL Generation** - Enhanced Routes.url/1 function to prioritize site_url setting from Settings over dynamic endpoint detection, ensuring consistent email links across PROD and DEV environments

### Changed
- **User Routes** - Moved all user-related routes under `/admin/users/` prefix:
  - `/admin/roles` → `/admin/users/roles`
  - `/admin/live_sessions` → `/admin/users/live_sessions`
  - `/admin/sessions` → `/admin/users/sessions`
  - `/admin/referral-codes` → `/admin/users/referral-codes`
- **Email Routes** - Reorganized email routes for better clarity:
  - `/admin/email-logs` → `/admin/emails`
  - `/admin/email-logs/:id` → `/admin/emails/email/:id`
  - `/admin/email-metrics` → `/admin/emails/dashboard`
  - `/admin/email-queue` → `/admin/emails/queue`
  - `/admin/email-blocklist` → `/admin/emails/blocklist`

### Added
- **icon_login Component** - Added new login icon component (arrow entering door) to Icons module for authentication pages
- **New Icon Components** - Added icon_download, icon_lock, and icon_search components to Icons module for comprehensive coverage
- **Icon Documentation** - Enhanced Icons module with detailed component documentation and usage examples
- **HTML Email Templates** - Added professional HTML versions for all authentication emails (confirmation, password reset, email update) with responsive design and consistent branding
- **Site URL Configuration** - Email links now use site_url setting from Settings panel when configured, providing full control over email URLs in production environments

### Fixed
- **Icon Reference** - Fixed incorrect icon_check_circle reference to icon_check_circle_filled in magic_link_live.ex
- **Code Readability** - Removed unnecessary alias expansion braces for single module imports

## 1.2.8 - 2025-09-17

### Improved
- **Asset Build Pipeline** - Enhanced asset rebuilding using standard Phoenix asset pipeline (mix assets.build) with intelligent fallbacks to esbuild, tailwind, and npm commands for better compatibility
- **Dynamic URL Prefix Handling** - Replaced hardcoded /phoenix_kit/ paths with dynamic Routes.path() throughout the codebase for proper prefix support
- **Code Quality** - Improved code formatting, comment alignment, and whitespace consistency across all modules
- **Installation Messages** - Enhanced user feedback messages with dynamic prefix support and clearer instructions

### Fixed
- **Hardcoded Paths** - Replaced static URL paths with dynamic prefix resolution using PhoenixKit.Utils.Routes
- **Asset Rebuild Process** - Asset builder now tries multiple commands in order of preference for maximum compatibility

### Removed
- **SimpleTest File** - Removed unused development test artifact (simple_test.ex)

## 1.2.7 - 2025-09-16

### Added
- **Email Navigation** - Added Email Metrics, Email Queue, and Email Blocklist pages to admin navigation menu
- **Email Blocklist System (V09 Migration)** - Complete email blocklist functionality with temporary/permanent blocks, reason management, and audit trail
- **Email Routes** - Added routes for all Email LiveView pages in admin integration
- **Users Menu Grouping** - Reorganized admin navigation with expandable Users and Email groups using HTML5 details/summary
- **Migration Documentation** - Comprehensive migration system documentation with all version paths and rollback options

### Fixed
- **Email Cleanup Task Pattern Matching** - Fixed Dialyzer warning about Emails.enabled?() pattern matching
- **Dashboard Add User Button** - Corrected navigation from dashboard Add User button to proper /admin/users/new route
- **Migration V09 Primary Key** - Fixed duplicate column 'id' error in phoenix_kit_email_blocklist table creation

### Improved
- **Navigation Menu Structure** - Replaced custom JavaScript with native HTML5 details/summary for better reliability and performance
- **Email Group Organization** - Email, Metrics, Queue, and Blocklist now properly grouped under Email section


## 1.2.6 - 2025-09-15

### Added
- **Admin Password Change Feature** - Direct password change capability for administrators in user edit form
- **Username Search Integration** - Added username search to referral code beneficiary selection and main user dashboard
- **Username Implementation** - Added optional username field with automatic generation from email for new user registrations

### Fixed
- **Form Validation Display Issues** - Replaced static validator hints with proper Phoenix LiveView components using phx-no-feedback:hidden
- **Dark Theme Compatibility** - Improved password management sections with theme-adaptive styling

### Improved
- **Date Formatting** - Updated referral dashboard to use user settings-aware date formatting
- **Dynamic Routing** - Replaced hardcoded /phoenix_kit/ paths with PhoenixKit.Utils.Routes.path() throughout referral codes
- **Admin UI Experience** - Enhanced password management with both direct change and email reset options

## 1.2.5 - 2025-09-12

### Added
- **Emails Foundation** with email logging and event management schemas
- **Email Rate Limiting Core** with basic rate limiting functionality and blocklist management
- **Email Database Schema (V07)** with optimized tables and proper indexing
- **Email Interceptor System** for pre-send filtering and validation capabilities
- **Webhook Processing Foundation** for AWS SES event handling (bounces, complaints, opens, clicks)
- **get_mailer/0 function** in PhoenixKit.Config for improved mailer integration
- **RepoHelper Integration** for proper database access patterns in emails modules

### Fixed
- **All compilation warnings (40 → 0)** - 100% improvement in code cleanliness
- **PhoenixKit.Repo undefined references** - proper integration with PhoenixKit.RepoHelper
- **Unused variable warnings** throughout the codebase
- **Pattern matching issues** in error handling code
- **Missing @moduledoc** for EmailBlocklist schema

### Improved
- **Credo warnings (30 → 5)** - 83% improvement in code quality metrics
- **Dialyzer warnings (40 → 4)** - 90% improvement in type checking
- **Code formatting** with proper number formatting (86_400 vs 86400)
- **Code efficiency** with optimized Enum operations (map_join vs map + join)
- **Function complexity** by extracting nested logic into helper functions
- **Error handling** by replacing explicit try blocks with case/with patterns
- **Alias ordering** alphabetically in imports
- **Trailing whitespace** removal across codebase

### Technical Improvements
- **Memory-efficient patterns** preparation for future batch processing
- **Comprehensive input validation** for emails data
- **SQL injection protection** with parameterized queries
- **Professional code structure** following PhoenixKit conventions
- **Enhanced error handling** with proper rescue clauses and pattern matching

## 1.2.4 - 2025-09-11

### Added
- Complete referral codes with comprehensive management interface
- Referral code creation, validation, and usage management functionality
- Admin modules page for system-wide module management and configuration
- Flexible expiration system with optional "no expiration" support for referral codes
- Advanced admin settings for referral code limits with real-time validation:
  - Maximum uses per referral code (configurable limit)
  - Maximum referral codes per user (configurable limit)
- Beneficiary system allowing referral codes to be assigned to specific users
- User search functionality with real-time filtering for beneficiary assignment
- Hierarchical navigation structure with "Modules" parent and nested "Referral Codes" item
- Professional referral code generation with confusion-resistant character set
- Settings persistence system with module-specific organization
- Introduced custom prefix in the config (/phoenix_kit to something else)

### Changed
- Improved form component alignment and styling in referral code forms
- Updated core input components to fix layout issues with conditional labels
- Reorganized admin settings order for better user experience
- Strengthened form validation with real-time feedback and error handling

### Fixed
- Settings persistence ensuring values are properly saved and loaded from database

## 1.2.3 - 2025-09-11

### Added
- Enhanced `mix phoenix_kit.status` task with hybrid repository detection and fallback strategies
- Comprehensive status diagnostics with detailed database connection reporting
- Application startup management for reliable status checking in various project configurations
- Intelligent repository detection supporting both configured and auto-detected repositories
- Mailer delegation support with automatic parent application mailer detection
- Comprehensive AWS SES configuration with automatic Finch HTTP client setup
- Finch HTTP client integration for email adapters (SendGrid, Mailgun, AWS SES)
- Auto-detection of existing mailer modules in parent applications
- Enhanced email configuration with configurable sender name and email address
- Production-ready email templates for SMTP, SendGrid, Mailgun, and AWS SES
- Complete AWS SES setup guide with step-by-step checklist and region configuration
- Automatic dependency management for gen_smtp when using AWS SES
- Swoosh API client configuration for HTTP-based email adapters

### Changed
- Asset rebuild system simplified to consistently recommend rebuilds for better reliability
- Status task now provides more detailed verbose diagnostics for troubleshooting
- Update task now delegates status display to dedicated status command for consistency
- Removed complex asset checking logic in favor of straightforward rebuild recommendations
- Email system architecture now supports both delegation and built-in modes
- Mailer configuration defaults to using parent application's existing mailer when available
- Installation process automatically configures appropriate email dependencies
- Documentation restructured with detailed provider-specific setup guides
- PhoenixKit.Mailer module enhanced with delegation capabilities

### Fixed
- Critical CSS integration bug where regex patterns incorrectly matched file paths containing "phoenix_kit" substring
- CSS integration now properly detects only exact PhoenixKit dependency paths (../../deps/phoenix_kit) and ignores false matches like "test_phoenix_kit_v1_web"
- Improved pattern matching specificity to prevent installation failures in projects with similar naming
- Trailing whitespace issues across multiple files for better code quality
- Unused alias imports in tasks and modules
- Dialyzer warnings by updating ignore patterns for better type checking
- Email sender configuration now properly supports custom from_email and from_name settings
- Production email setup documentation with comprehensive provider examples
- Mailer integration patterns for better parent application compatibility

## 1.2.2 - 2025-09-08

### Added
- Comprehensive asset rebuild system with `mix phoenix_kit.assets.rebuild` task for automatic CSS integration
- System status checker with `mix phoenix_kit.status` task for installation diagnostics
- Asset management tools for PhoenixKit CSS integration updates and Tailwind CSS compatibility
- Common utility functions in `PhoenixKit.Install.Common` for version checking and installation management
- Helper functions for better code organization and separation of concerns
- Progress tracking and enhanced user feedback for migration operations
- Type specifications for Mix.Task modules and asset rebuild functions

### Changed
- CSS integration workflow simplified with better Tailwind CSS 4 support and @source directive optimization
- Migration function refactored to reduce cyclomatic complexity and improve maintainability
- Code organization improved with extraction of helper functions across multiple modules
- Enhanced error handling and user notifications for asset rebuild operations

### Fixed
- All Credo static analysis warnings (trailing whitespace, formatting issues, deep nesting)
- All Dialyzer type analysis warnings with proper function specifications
- CSS integration logic and @source directive paths for correct asset compilation
- Complex migration function broken down into smaller, more maintainable functions
- Conditional statements simplified (cond to if) for better code clarity

## 1.2.1 - 2025-09-07

### Added
- Project title customization system with dynamic branding across all admin interfaces
- Project title integration in authentication pages (login and registration)
- Time display enhancement showing both date and time in Users and Sessions tables
- Settings-aware date/time formatting functions for consistent user preferences

### Changed
- Date handling moved from PhoenixKit.Date to PhoenixKit.Utils.Date for better organization
- All admin pages now consistently display custom project title instead of hardcoded "PhoenixKit"
- Enhanced admin interface with unified project branding throughout navigation
- Login and registration pages now show custom project title in headings and browser tabs
- Changed config and magic link

## Fixed
- Fixed asset rebuilding integration in migration strategy

## 1.2.0 - 2025-09-03

### Added
- User settings system with customizable time zone, date format, and time format preferences
- Comprehensive session management system for admin interface with real-time monitoring
- Live data updates system for admin panels with automatic refresh capabilities
- Automatic user logout functionality when role changes occur for enhanced security
- DateTime formatting functions with Timex library integration for better date/time handling
- Enhanced authentication session management for improved user experience

### Changed
- Authentication components updated with GitHub-inspired design and unified development notices
- Date handling refactored into separate PhoenixKit.Date module (aliased as PKDate) for better organization
- User dashboard "Registered" field now uses enhanced date formatting from settings
- Improved code quality and PubSub integration for better real-time communication

### Fixed
- Missing admin routes for settings and modules sections
- Dialyzer type errors resolved across the codebase
- Live Activity link in dashboard now correctly navigates to intended destination
- Settings tab information updated with accurate user preferences display

## 1.1.1 - 2025-09-02

### Added
- Profile settings functionality with first name and last name fields
- Profile changeset function for user profile updates
- Complete profile editing interface in user settings

### Fixed
- Router integration by removing unnecessary redirect pipe for login route
- Added admin shortcut route for improved navigation
- Enhanced admin dashboard accessibility

## 1.1.0 - 2025-09-01

### Changed
- **BREAKING**: Simplified role system by removing `is_active` column from role assignments
- Role removal now permanently deletes assignment records instead of soft deactivation
- All role-related functions updated to work with direct deletion approach
- Improved performance by eliminating `is_active` filtering in database queries
- Documenatation link fixed for hex

### Added
- V02 migration for upgrading existing installations to simplified role system
- Enhanced migration system with comprehensive upgrade path from V01 to V02
- Pre-migration reporting with warnings about inactive assignments that will be deleted
- Rollback support for V02 migration (though inactive assignments cannot be restored)

### Fixed
- Test suite updated to reflect schema new changes

### Migration Notes
- Existing V01 installations can upgrade using `mix phoenix_kit.update`
- V02 migration will permanently delete any inactive role assignments
- New installations will use V02 schema without `is_active` column

## 1.0.0 - 2025-08-29

Initial version with basic functionality, mostly around authorization and user registration with roles. Also admin page for admin users with User section.
