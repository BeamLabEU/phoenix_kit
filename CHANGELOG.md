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
- **Email Blocklist System (V09 Migration)** - Complete email blocklist functionality with temporary/permanent blocks, reason tracking, and audit trail
- **Email Routes** - Added routes for all Email LiveView pages in admin integration
- **Users Menu Grouping** - Reorganized admin navigation with expandable Users and Email groups using HTML5 details/summary
- **Migration Documentation** - Comprehensive migration system documentation with all version paths and rollback options

### Fixed
- **Email Cleanup Task Pattern Matching** - Fixed Dialyzer warning about EmailTracking.enabled?() pattern matching
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
- **Dynamic Routing** - Replaced hardcoded /phoenix_kit/ paths with PhoenixKit.Utils.Routes.path() throughout referral system
- **Admin UI Experience** - Enhanced password management with both direct change and email reset options

## 1.2.5 - 2025-09-12

### Added
- **Email System Foundation** with email logging and event tracking schemas
- **Email Rate Limiting Core** with basic rate limiting functionality and blocklist management
- **Email Database Schema (V07)** with optimized tables and proper indexing
- **Email Interceptor System** for pre-send filtering and validation capabilities
- **Webhook Processing Foundation** for AWS SES event handling (bounces, complaints, opens, clicks)
- **get_mailer/0 function** in PhoenixKit.Config for improved mailer integration
- **RepoHelper Integration** for proper database access patterns in email tracking modules

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
- **Comprehensive input validation** for email tracking data
- **SQL injection protection** with parameterized queries
- **Professional code structure** following PhoenixKit conventions
- **Enhanced error handling** with proper rescue clauses and pattern matching

## 1.2.4 - 2025-09-11

### Added
- Complete referral codes system with comprehensive management interface
- Referral code creation, validation, and usage tracking functionality
- Admin modules page for system-wide module management and configuration
- Flexible expiration system with optional "no expiration" support for referral codes
- Advanced admin settings for referral code limits with real-time validation:
  - Maximum uses per referral code (configurable limit)
  - Maximum referral codes per user (configurable limit)
- Beneficiary system allowing referral codes to be assigned to specific users
- User search functionality with real-time filtering for beneficiary assignment
- Hierarchical navigation structure with "Modules" parent and nested "Referral System" item
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
- Comprehensive session management system for admin interface with real-time tracking
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
