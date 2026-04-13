defmodule PhoenixKit.Migrations.Postgres do
  @moduledoc """
  PhoenixKit PostgreSQL Migration System

  This module handles versioned migrations for PhoenixKit, supporting incremental
  updates and rollbacks between different schema versions.

  ## Migration Versions

  ### V01 - Initial Setup (Foundation)
  - Creates basic authentication system
  - Phoenix_kit_users table with email/password authentication
  - Phoenix_kit_user_tokens for email confirmation and password reset
  - CITEXT extension for case-insensitive email storage
  - Version tracking table (phoenix_kit)

  ### V02 - Role System Foundation
  - Phoenix_kit_user_roles table for role definitions
  - Phoenix_kit_user_role_assignments for user-role relationships
  - System roles (Owner, Admin, User) with protection
  - Automatic Owner assignment for first user

  ### V03 - Settings System
  - Phoenix_kit_settings table for system configuration
  - Key/value storage with timestamps
  - Default settings for time zones, date formats

  ### V04 - Role System Enhancements
  - Enhanced role assignments with audit trail
  - Assigned_by and assigned_at tracking
  - Active/inactive role states

  ### V05 - Settings Enhancements
  - Extended settings with better validation
  - Additional configuration options

  ### V06 - Additional System Tables
  - Extended system configuration
  - Performance optimizations

  ### V07 - Email System
  - Phoenix_kit_email_logs for comprehensive email logging
  - Phoenix_kit_email_events for delivery event tracking (open, click, bounce)
  - Advanced email analytics and monitoring
  - Provider integration and webhook support

  ### V08 - Username Support
  - Username field for phoenix_kit_users
  - Unique username constraints
  - Email-based username generation for existing users

  ### V09 - Email Blocklist System
  - Phoenix_kit_email_blocklist for blocked email addresses
  - Temporary and permanent blocks with expiration
  - Reason tracking and audit trail
  - Efficient indexes for rate limiting and spam prevention

  ### V10 - User Registration Analytics
  - Registration analytics columns for IP and location tracking
  - Geolocation data storage (country, region, city)
  - Privacy-focused design with configurable tracking
  - Efficient indexes for analytics queries

  ### V11 - Per-User Timezone Settings
  - Individual timezone preferences for each user
  - Personal timezone column in phoenix_kit_users table
  - Fallback system: user timezone → system timezone → UTC
  - Enhanced date formatting with per-user timezone support

  ### V12 - JSON Settings Support
  - JSONB column (value_json) in phoenix_kit_settings table
  - Support for complex structured data storage
  - Removes NOT NULL constraint from value column
  - Enables proper JSON-only settings storage
  - Backward compatible with existing string settings
  - Dual storage model: string OR JSON values
  - Enhanced cache system for JSON data

  ### V13 - Enhanced Email Tracking with AWS SES Integration
  - AWS message ID correlation (aws_message_id column)
  - Specific timestamp tracking (bounced_at, complained_at, opened_at, clicked_at)
  - Extended event types (reject, delivery_delay, subscription, rendering_failure)
  - Enhanced status management (rejected, delayed, hard_bounced, soft_bounced, complaint)
  - Unique constraint on aws_message_id for duplicate prevention
  - Additional event fields (reject_reason, delay_type, subscription_type, failure_reason)

  ### V14 - Email Body Compression Support
  - Adds body_compressed boolean field to phoenix_kit_email_logs
  - Enables efficient archival and storage management
  - Backward compatible with existing data

  ### V15 - Email Templates System
  - Phoenix_kit_email_templates table for template storage and management
  - Template variables with {{variable}} syntax support
  - Template categories (system, marketing, transactional)
  - Template versioning and usage tracking
  - Integration with existing email logging system

  ### V16 - OAuth Providers System & Magic Link Registration
  - Phoenix_kit_user_oauth_providers for OAuth integration
  - Support for Google, Apple, GitHub authentication
  - Account linking by email address
  - OAuth token storage with encryption support
  - Multiple providers per user support
  - Magic link registration tokens with nullable user_id

  ### V17 - Entities System (Dynamic Content Types)
  - Phoenix_kit_entities for dynamic content type definitions
  - Phoenix_kit_entity_data for entity records
  - JSONB storage for flexible field schemas
  - Plural display names for better UI wording
  - 13 field types support (text, number, date, select, etc.)
  - Admin interfaces for entity and data management
  - Settings integration (entities_enabled, entities_max_per_user, etc.)

  ### V18 - User Custom Fields
  - JSONB custom_fields column in phoenix_kit_users table
  - Flexible key-value storage for user metadata
  - API functions for custom field management
  - Support for arbitrary user data without schema changes

  ### V19 - Storage System Tables (Part 1)
  - Initial storage system infrastructure
  - See V20 for complete distributed storage system

  ### V20 - Distributed File Storage System
  - Phoenix_kit_buckets for storage provider configurations (local, S3, B2, R2)
  - Phoenix_kit_files for original file uploads with metadata
  - Phoenix_kit_file_instances for file variants (thumbnails, resizes, video qualities)
  - Phoenix_kit_file_locations for physical storage locations (multi-location redundancy)
  - Phoenix_kit_storage_dimensions for admin-configurable dimension presets
  - UUIDv7 primary keys for time-sortable identifiers
  - Smart bucket selection with priority system
  - Token-based URL security to prevent enumeration attacks
  - Automatic variant generation system

  ### V21 - Message ID Search Performance Optimization
  - Composite index on (message_id, aws_message_id) for faster lookups
  - Improved performance of AWS SES event correlation
  - Optimized message ID search queries throughout email system

  ### V22 - Email System Improvements & Audit Logging
  - AWS message ID tracking with aws_message_id field in phoenix_kit_email_logs
  - Enhanced event management with composite indexes for faster duplicate checking
  - Phoenix_kit_email_orphaned_events table for tracking unmatched SQS events
  - Phoenix_kit_email_metrics table for system metrics tracking
  - Phoenix_kit_audit_logs table for comprehensive administrative action tracking
  - Complete audit trail for admin password resets (WHO, WHAT, WHEN, WHERE)
  - Metadata storage for additional context in audit logs
  - Performance indexes for efficient querying by user, action, and date

  ### V23 - Session Fingerprinting
  - Session fingerprinting columns (ip_address, user_agent_hash) in phoenix_kit_users_tokens
  - Prevents session hijacking by detecting suspicious session usage patterns
  - IP address tracking: Detects when session is used from different IP
  - User agent hashing: Detects when session is used from different browser/device
  - Backward compatible: Existing sessions without fingerprints remain valid
  - Configurable strictness: Can log warnings or force re-authentication
  - Performance indexes for efficient fingerprint verification

  ### V24 - File Checksum Unique Index
  - Unique index on phoenix_kit_files.checksum for O(1) duplicate detection
  - Enables automatic deduplication of uploaded files
  - Prevents redundant storage of identical files
  - Improves performance of duplicate file lookups

  ### V25 - Aspect Ratio Control for Dimensions
  - Adds maintain_aspect_ratio boolean column to phoenix_kit_storage_dimensions
  - Allows choosing between aspect ratio preservation (width-only) or fixed dimensions
  - Per-dimension control for responsive sizing vs exact crops
  - Defaults to maintaining aspect ratio for all dimensions

  ### V26 - Rename Checksum Fields & Per-User Deduplication
  - Renames `checksum` to `file_checksum` (clearer naming)
  - Removes unique index on file_checksum (allows same file from different users)
  - Adds `user_file_checksum` column (SHA256 of user_id + file_checksum)
  - Creates unique index on user_file_checksum for per-user duplicate detection
  - Same user cannot upload same file twice (enforced by user_file_checksum)
  - Different users CAN upload same file (different user_file_checksum values)
  - Preserves file_checksum field for popularity analytics across all users
  - Clearer naming convention: file_checksum vs user_file_checksum

  ### V27 - Oban Background Job System
  - Creates Oban tables for background job processing
  - Oban_jobs table for job queue management
  - Oban_peers table for distributed coordination
  - Performance indexes for efficient job processing
  - Enables file processing (variant generation, metadata extraction)
  - Enables email processing (sending, tracking, analytics)
  - Uses Oban's latest schema version automatically (forward-compatible)
  - Integrated with PhoenixKit configuration system

  ### V28 - User Preferred Locale
  - Adds `preferred_locale` column to `phoenix_kit_users` table
  - Supports user-specific language dialect preferences
  - Enables simplified URL structure with dialect preferences

  ### V29 - Posts System
  - Complete social posts system with media attachments
  - Posts with privacy controls (draft/public/unlisted/scheduled)
  - Post comments with nested threading
  - Post likes and user mentions
  - Post tags and user groups

  ### V30 - Move Preferred Locale to Custom Fields
  - Migrates preferred_locale from column to custom_fields JSONB
  - Reduces schema complexity
  - Backward compatible data access

  ### V31 - Billing System (Phase 1)
  - Phoenix_kit_currencies for multi-currency support
  - Phoenix_kit_billing_profiles for user billing information (EU Standard)
  - Phoenix_kit_orders for order management with line items
  - Phoenix_kit_invoices for invoice generation with receipt functionality
  - Phoenix_kit_transactions for payment tracking
  - Bank transfer payment workflow (manual payment marking)
  - Default currencies seeding (EUR, USD, GBP)
  - Billing settings for prefixes and configuration

  ### V32 - AI System
  - Phoenix_kit_ai_accounts for AI provider account management
  - Phoenix_kit_ai_requests for usage tracking and statistics
  - OpenRouter integration with API key validation
  - Text processing slots configuration (3 presets/fallback chain)
  - JSONB storage for flexible settings and metadata
  - AI system enable/disable toggle
  - Usage statistics and request history

  ### V33 - Payment Providers and Subscriptions
  - Phoenix_kit_payment_methods for saved payment methods (cards, wallets)
  - Phoenix_kit_subscription_types for subscription pricing types
  - Phoenix_kit_subscriptions for user subscription management
  - Phoenix_kit_payment_provider_configs for provider credentials
  - Phoenix_kit_webhook_events for idempotent webhook processing
  - Orders: checkout session fields
  - Invoices: subscription reference
  - Settings: provider enable/disable, grace period, dunning configuration

  ### V34 - AI Endpoints System
  - Phoenix_kit_ai_endpoints for unified AI configuration
  - Combines provider credentials, model selection, and generation parameters
  - Replaces the Accounts + Slots architecture with single Endpoint entities
  - Updates phoenix_kit_ai_requests with endpoint_id reference
  - Removes slot settings from Settings table

  ### V35 - Support Tickets System
  - Phoenix_kit_tickets for customer support request management
  - Phoenix_kit_ticket_comments for threaded comments with internal notes
  - Phoenix_kit_ticket_attachments for file attachments on tickets/comments
  - Phoenix_kit_ticket_status_history for complete audit trail
  - Status workflow: open → in_progress → resolved → closed
  - SupportAgent role for ticket access control
  - Internal notes feature (staff-only visibility)
  - Settings: enabled, per_page, comments, internal notes, attachments, allow_reopen

  ### V36 - Connections Module (Social Relationships)
  - Phoenix_kit_user_follows for one-way follow relationships
  - Phoenix_kit_user_connections for two-way mutual connections
  - Phoenix_kit_user_blocks for user blocking
  - Public API for parent applications to use
  - Follow: no consent required, instant
  - Connection: requires acceptance from both parties
  - Block: prevents all interaction, removes existing relationships
  - Settings: connections_enabled

  ### V37 - Sync Connections & Transfer Tracking
  - phoenix_kit_sync_connections for permanent site-to-site connections (renamed in V44)
  - phoenix_kit_sync_transfers for tracking all data transfers (renamed in V44)
  - Approval modes: auto_approve, require_approval, per_table
  - Expiration and download limits (max_downloads, max_records_total)
  - Additional security: password protection, IP whitelist, time restrictions
  - Receiver-side settings: conflict strategy, auto-sync
  - Full audit trail for connections and transfers

  ### V38 - AI Prompts System
  - Phoenix_kit_ai_prompts for reusable prompt templates
  - Variable substitution with {{VariableName}} syntax
  - Auto-extracted variables stored for validation
  - Usage tracking (count and last used timestamp)
  - Sorting and organization support

  ### V39 - Admin Notes System
  - Phoenix_kit_admin_notes for internal admin notes about users
  - Admin-to-admin communication about user accounts
  - Author tracking for accountability
  - Any admin can view/edit/delete any note

  ### V40 - UUID Column Addition
  - Adds `uuid` column to all 33 legacy tables using bigserial PKs
  - Non-breaking: keeps existing bigserial primary keys intact
  - Backfills existing records with generated UUIDs
  - Creates unique indexes on uuid columns
  - Enables gradual transition to UUID-based lookups

  ### V41 - AI Prompt Tracking & Reasoning Parameters
  - Adds `prompt_id` and `prompt_name` to phoenix_kit_ai_requests
  - Tracks which prompt template was used for AI completions
  - Denormalized prompt_name preserved for historical display
  - Foreign key with ON DELETE SET NULL for prompt deletion
  - Adds reasoning/thinking parameters to phoenix_kit_ai_endpoints:
    - `reasoning_enabled` (boolean) - Enable reasoning with default effort
    - `reasoning_effort` (string) - none/minimal/low/medium/high/xhigh
    - `reasoning_max_tokens` (integer) - Hard cap on thinking tokens (1024-32000)
    - `reasoning_exclude` (boolean) - Hide reasoning from response

  ### V42 - Universal Scheduled Jobs System
  - Phoenix_kit_scheduled_jobs for polymorphic scheduled task management
  - Behaviour-based handler pattern for extensibility
  - Priority-based job execution ordering
  - Retry logic with max_attempts and last_error tracking
  - Status management: pending, executed, failed, cancelled
  - Replaces single-purpose PublishScheduledPostsJob with generic processor
  - Supports any schedulable resource (posts, emails, notifications, etc.)

  ### V43 - Legal Module
  - Phoenix_kit_consent_logs for user consent tracking (GDPR/CCPA compliance)
  - Supports logged-in users and anonymous visitors via session_id
  - Consent types: necessary, analytics, marketing, preferences
  - Settings seeds for legal module configuration:
    - legal_enabled, legal_frameworks, legal_company_info
    - legal_dpo_contact, legal_consent_widget_enabled
    - legal_cookie_banner_position

  ### V44 - Sync Table Rename
  - Rename phoenix_kit_db_sync_connections → phoenix_kit_sync_connections
  - Rename phoenix_kit_db_sync_transfers → phoenix_kit_sync_transfers
  - Rename all related indexes to match new table names
  - Rename settings keys: db_sync_* → sync_*
  - Matches module rename from DBSync to Sync

  ### V45 - E-commerce Shop Module
  - Phoenix_kit_shop_categories for product organization with nesting
  - Phoenix_kit_shop_products for physical and digital products
  - Phoenix_kit_shop_shipping_methods, phoenix_kit_shop_carts, phoenix_kit_shop_cart_items
  - Phoenix_kit_payment_options for checkout payment methods (COD, bank transfer, Stripe, PayPal)
  - Cart supports payment_option_id for payment method selection
  - JSONB fields for tags, images, option_names, metadata
  - Settings: shop_enabled, shop_currency, shop_tax_enabled, shop_tax_rate, shop_inventory_tracking

  ### V46 - Product Options with Dynamic Pricing + Import Logs
  - Phoenix_kit_shop_config table for global Shop configuration (key-value JSONB)
  - Adds option_schema JSONB column to phoenix_kit_shop_categories
  - Two-level option system: global options + category-specific options
  - Option schema format with types: text, number, boolean, select, multiselect
  - Price modifiers support: fixed (+$10) and percent (+20%) modifier types
  - Price calculation order: fixed modifiers first, then percent applied to result
  - Adds featured_image_id UUID column to products for Storage integration
  - Adds image_ids UUID[] array column to products for gallery images
  - Adds selected_specs JSONB column to cart_items for specification storage
  - Cart items freeze calculated price at add-to-cart time
  - Phoenix_kit_shop_import_logs for CSV import history tracking
  - Import status tracking: pending, processing, completed, failed
  - Import statistics: imported, updated, skipped, errors counts
  - Error details stored in JSONB for debugging
  - User association for audit trail (who initiated import)
  - Enables admin UI for Shopify CSV import management

  ### V47 - Shop Localized Fields
  - Converts Shop module from separate translations JSONB to localized fields approach
  - Product fields (title, slug, description, body_html, seo_title, seo_description) become JSONB maps
  - Category fields (name, slug, description) become JSONB maps
  - Removes translations column from products and categories
  - Each field stores language → value map: %{"en" => "Product", "ru" => "Продукт"}
  - Migration merges existing canonical data with translations field data
  - Default language determined from phoenix_kit_settings.default_language
  - GIN indexes on slug fields for efficient localized URL lookups
  - Enables explicit language tagging for CSV imports
  - Solves language ambiguity problem when changing default language

  ### V48 - Post and Comment Dislikes
  - Creates `phoenix_kit_post_dislikes` table for post dislikes
  - Creates `phoenix_kit_comment_likes` table for comment likes
  - Creates `phoenix_kit_comment_dislikes` table for comment dislikes
  - Adds `dislike_count` column to `phoenix_kit_posts`
  - Adds `dislike_count` column to `phoenix_kit_post_comments`
  - Unique constraint ensures one like/dislike per user per post/comment
  - Frontend can choose to display likes, dislikes, both, or net score

  ### V49 - Shop Import Enhancements
  - Adds option_mappings JSONB column to import_configs for CSV option mapping
  - Supports mapping CSV options to global options with slot configuration
  - Structure: [{csv_name, slot_key, source_key, auto_add, label}]
  - Adds product_ids INTEGER[] column to import_logs for tracking imported products
  - Enables import detail view showing all products created/updated during import

  ### V50 - Bucket Access Type
  - Adds access_type VARCHAR column to phoenix_kit_buckets
  - Three access modes: "public" (redirect), "private" (proxy), "signed" (future)
  - Public: redirect to bucket URL (default, fastest, uses CDN)
  - Private: proxy through server (for ACL-protected S3 buckets)
  - Enables FileController to handle both public and private S3 buckets

  ### V51 - Cart Items Unique Constraint + User Deletion FK Fixes
  - Fix unique constraint to allow same product with different options
  - Include selected_specs in uniqueness check via MD5 hash
  - orders.user_id: RESTRICT → SET NULL (preserve orders, anonymize user)
  - billing_profiles.user_id: CASCADE → SET NULL (preserve for history)
  - tickets.user_id: DELETE_ALL → SET NULL (preserve support history)
  - Enables GDPR-compliant user deletion while preserving financial records

  ### V52 - Shop Localized Slug Functional Unique Index
  - Creates extract_primary_slug() SQL function for JSONB slug extraction
  - Creates functional unique index on products (primary slug only)
  - Creates functional unique index on categories (primary slug only)
  - Fixes upsert behavior after V47 JSONB migration
  - Language-agnostic: uses alphabetically first key for deterministic extraction

  ### V53 - Module-Level Permission System
  - Creates phoenix_kit_role_permissions table for granular access control
  - Allowlist model: row present = granted, absent = denied
  - Owner role bypasses permissions entirely (hardcoded in code)
  - Admin role gets ALL permissions seeded by default
  - Unique constraint on (role_id, module_key) prevents duplicates
  - 25 permission keys: 5 core sections + 20 feature modules

  ### V54 - Category Featured Product + Import Config fix
  - Replaces image_url with featured_product_id FK to products
  - Auto-populates featured_product_id from first active product with image
  - Creates index on featured_product_id
  - Drops image_url column from categories
  - Image priority: image_id (Storage) → featured_product's featured_image_id
  - Adds download_images BOOLEAN to import_configs (schema field was missing from DB)

  ### V55 - Standalone Comments Module
  - Creates polymorphic phoenix_kit_comments table (resource_type + resource_id)
  - Creates phoenix_kit_comments_likes and phoenix_kit_comments_dislikes tables
  - Self-referencing parent_id for unlimited threading depth
  - Counter caches for like_count and dislike_count
  - Seeds default comments settings and Admin role permission

  ### V56 - UUID Column Consistency Fix + UUID FK Columns
  - Adds missing uuid column to phoenix_kit_consent_logs (V43 schema expected it)
  - Switches 17 tables from gen_random_uuid() (v4) to uuid_generate_v7() (v7)
  - Fixes V55 Comments tables UUID PK defaults (gen_random_uuid → uuid_generate_v7)
  - Adds NOT NULL constraint to 11 tables (V43, V46, V53, and uuid_repair.ex core tables)
  - Adds missing unique indexes on uuid for 13 tables (V43, V45 Shop + uuid_repair.ex core)
  - Fixes uuid_repair.ex upgrade path where V40 skipped core tables already having uuid column
  - Adds ~80 UUID FK columns alongside integer FKs across ~40 tables
  - Backfills UUID FK values via JOIN from source tables (batched for large tables)
  - Creates indexes on all new UUID FK columns
  - Prepares for UUID primary key switch in Ecto schemas
  - All operations idempotent — safe on fresh installs and all upgrade paths
  - Existing non-NULL UUID values unchanged

  ### V57 - UUID FK Column Repair
  - Re-runs idempotent UUID FK column operations from V56
  - Fixes missing role_uuid and granted_by_uuid on phoenix_kit_role_permissions
  - Catches any other UUID FK columns missed when V56 was applied with earlier code
  - Safe no-op on databases where V56 already created everything correctly

  ### V58 - Timestamp Column Type Standardization
  - Converts ALL timestamp columns across 68 tables from `timestamp` to `timestamptz`
  - Completes DateTime standardization (Elixir `:utc_datetime` + PostgreSQL `timestamptz`)
  - No USING clause needed for up (PostgreSQL treats timestamp as UTC implicitly)
  - Down uses `USING col AT TIME ZONE 'UTC'` for safe revert to `timestamp(0)`
  - Fully idempotent: checks table/column existence and current type before altering

  ### V59 - Publishing Module Database Tables
  - Creates 4 core publishing tables: groups, posts, versions, contents
  - JSONB `data` column on every table for extensibility without future migrations
  - UUID v7 primary keys, dual-write user FKs, timestamptz timestamps
  - One content row per language (mirrors filesystem one-file-per-language model)
  - Seeds `publishing_storage` setting (default: "filesystem")

  ### V60 - Email Templates UUID FK Columns
  - Adds `created_by_user_uuid` and `updated_by_user_uuid` columns to phoenix_kit_email_templates
  - Fixes schema/migration mismatch where Template schema referenced UUID columns never created
  - Idempotent: checks column existence before adding (safe for fresh installs where V15 now includes them)
  - Resolves fresh install crash at V30 caused by V15 seed query failing on missing columns

  ### V61 - UUID Column Safety Net (V40 Flush Fix)
  - Adds missing `uuid` column to 6 tables that V40 silently skipped due to Ecto command buffering
  - Root cause: V40 used `repo().query()` (immediate) for table existence checks, but V32-V39 table
    creation commands were still buffered (not yet flushed). V31's `flush()` was the last flush before V40.
  - Tables fixed: admin_notes, ai_requests, subscriptions, payment_provider_configs, webhook_events, sync_transfers
  - Also adds `created_by_uuid` FK column to phoenix_kit_scheduled_jobs
  - V40 now includes `flush()` at start of `up()` to prevent recurrence on new installations
  - All operations idempotent — safe on any installation

  ### V62 - UUID Column Naming Cleanup (`_id` → `_uuid`)
  - Renames 35 UUID-typed FK columns from `_id` suffix to `_uuid` suffix
  - Enforces naming convention: `_id` = integer (legacy/deprecated), `_uuid` = UUID
  - Groups: Posts (15), Comments (4), Tickets (6), Storage (3), Publishing (3), Shop (3), Scheduled Jobs (1)
  - No data migration — columns already hold correct UUID values, pure rename
  - All operations idempotent (IF EXISTS guards) — safe if module tables don't exist
  - PostgreSQL auto-updates FK/index column references; constraint object names are unchanged

  ### V63 - UUID Companion Column Safety Net Round 2
  - Adds `uuid` identity column to `phoenix_kit_ai_accounts` (missed by V61 due to wrong table name)
  - Adds `account_uuid` companion to `phoenix_kit_ai_requests` (backfilled from ai_accounts)
  - Adds `matched_email_log_uuid` companion to `phoenix_kit_email_orphaned_events` (backfilled from email_logs)
  - Adds `subscription_uuid` companion to `phoenix_kit_invoices` (backfilled from subscriptions)

  ### V64 - Fix user token check constraint for UUID-only inserts
  - Drops V16's `user_id_required_for_non_registration_tokens` constraint (checks `user_id`)
  - Adds `user_uuid_required_for_non_registration_tokens` constraint (checks `user_uuid`)
  - Fixes login crash after UUID cleanup removed `user_id` from UserToken schema

  ### V65 - Rename SubscriptionPlan → SubscriptionType
  - Renames `phoenix_kit_subscription_plans` table → `phoenix_kit_subscription_types`
  - Renames unique slug index accordingly
  - Renames `plan_id` / `plan_uuid` FK columns in `phoenix_kit_subscriptions`
    to `subscription_type_id` / `subscription_type_uuid`
  - All operations idempotent (IF EXISTS guards)

  ### V66 - Make legacy user_id nullable on posts tables
  - Drops NOT NULL on `user_id` for 5 posts tables where schemas only set `user_uuid`
  - Tables: post_groups, post_comments, post_likes, post_dislikes, post_mentions
  - Fixes create_group and like/dislike/comment/mention inserts failing with not_null_violation

  ### V67 - Make all remaining NOT NULL integer FK columns nullable
  - Drops NOT NULL on 42 legacy integer FK columns across 30 tables
  - Covers: roles, posts, tickets, storage, admin, auth, audit, connections, billing,
    entities, referrals, standalone comments, and shop modules
  - Handles V65 plan_id → subscription_type_id rename (checks both names)
  - All operations idempotent (table/column existence + NOT NULL guards)

  ### V68 - Allow NULL slug for timestamp-mode publishing posts
  - Drops NOT NULL on `slug` in `phoenix_kit_publishing_posts`
  - Replaces unique index with partial index (slug-mode only, WHERE slug IS NOT NULL)
  - Adds unique index on `(group_uuid, post_date, post_time)` for timestamp-mode posts

  ### V69 - Make legacy integer FK columns nullable on role tables
  - Drops NOT NULL on `user_id` and `role_id` in `phoenix_kit_user_role_assignments`
  - Drops NOT NULL on `role_id` in `phoenix_kit_role_permissions`
  - Fixes role assignment and permission inserts failing with not_null_violation
  - All operations idempotent (table/column existence + NOT NULL guards)
  - Drops NOT NULL on `slug` in `phoenix_kit_publishing_posts`
  - Replaces unique index with partial index (slug-mode only, WHERE slug IS NOT NULL)
  - Adds unique index on `(group_uuid, post_date, post_time)` for timestamp-mode posts

  ### V97 - Storage dimension alternative formats ⚡ LATEST
  - Adds `alternative_formats` (`text[]`) to `phoenix_kit_storage_dimensions`
  - Enables multi-format variant generation (e.g., WebP + AVIF alongside JPEG)

  ### V96 - Catalogue items linked directly to catalogues
  - Adds nullable `catalogue_uuid` FK on `phoenix_kit_cat_items` so items can
    belong to a catalogue independently of having a category
  - Backfills existing items from their category's catalogue_uuid
  - Pins any remaining orphans to the oldest non-deleted catalogue
  - Adds indexes on `catalogue_uuid` and `(catalogue_uuid, status)`

  ### V95 - Media folders and folder links
  - Creates `phoenix_kit_media_folders` and `phoenix_kit_media_folder_links` tables
  - Adds organizational folder hierarchy for media files (metadata-only;
    storage buckets are unaware of them)

  ### V94 - Document Creator local DB sync
  - Adds `google_doc_id` (VARCHAR(255)) to `phoenix_kit_doc_templates`, `phoenix_kit_doc_documents`, `phoenix_kit_doc_headers_footers`
  - Adds `status` (VARCHAR(20), DEFAULT 'published') to `phoenix_kit_doc_documents`
  - Partial unique indexes on `google_doc_id WHERE google_doc_id IS NOT NULL`

  ### V93 - Settings prefix index
  - Adds `text_pattern_ops` B-tree index on `phoenix_kit_settings.key` for efficient LIKE prefix queries
  - Used by the integrations system for `LIKE 'integration:provider:%'` lookups

  ### V92 - Organization Accounts
  - Adds `account_type` column (VARCHAR(20), NOT NULL, DEFAULT 'person') with CHECK constraint
  - Adds `organization_name` column (VARCHAR(255)) for organization display names
  - Adds `organization_uuid` self-referencing FK to link persons to organizations
  - Indexes on `account_type` and `organization_uuid`

  ### V91 - Locations tables
  - `phoenix_kit_location_types` for user-defined location categories
  - `phoenix_kit_locations` for physical locations with type reference
  - `phoenix_kit_location_type_assignments` for many-to-many join

  ### V90 - Activity feed
  - `phoenix_kit_activities` table for business-level action logging

  ### V89 - Catalogue pricing
  - Renames `price` to `base_price` in `phoenix_kit_cat_items`
  - Adds `markup_percentage` decimal column to `phoenix_kit_cat_catalogues`

  ### V88 - Publishing schema V2
  - Restructures posts/versions/contents for publishing module
  - Adds `active_version_uuid`, `trashed_at` to posts
  - Adds `published_at` to versions
  - Data migration from legacy columns
  - Drops legacy post columns: `scheduled_at`, `status`, `published_at`, `primary_language`, `data`

  ### V87 - Add Catalogue tables
  - Creates `phoenix_kit_cat_manufacturers` — manufacturer directory
  - Creates `phoenix_kit_cat_suppliers` — supplier directory
  - Creates `phoenix_kit_cat_manufacturer_suppliers` — many-to-many join with unique constraint
  - Creates `phoenix_kit_cat_catalogues` — top-level catalogue groupings
  - Creates `phoenix_kit_cat_categories` — subdivisions within a catalogue (with position ordering)
  - Creates `phoenix_kit_cat_items` — individual products/materials with SKU, price, unit

  ### V86 - Add Document Creator tables
  - Creates `phoenix_kit_doc_headers_footers` — reusable header/footer designs
  - Creates `phoenix_kit_doc_templates` — document templates with GrapesJS editor content
  - Creates `phoenix_kit_doc_documents` — documents created from templates with baked header/footer

  ### V85 - Add system_prompt to AI prompts
  - Adds `system_prompt` (text) column to `phoenix_kit_ai_prompts`
  - Allows storing system-level instructions separately from user prompt content

  ### V84 - Rename mailing tables to newsletters
  - Idempotently renames `phoenix_kit_mailing_*` tables to `phoenix_kit_newsletters_*`
  - Fixes databases that ran the old V79 (which created `mailing_*` tables)
  - Safe to run multiple times — uses IF EXISTS guards

  ### V83 - Add status to publishing groups
  - Adds `status` column (varchar(20), default 'active') to `phoenix_kit_publishing_groups`
  - Supports soft-delete via "trashed" status
  - Adds index on `(status)` for filtering

  ### V82 - Add metadata JSONB column to comments
  - Adds `metadata` column (jsonb, default `'{}'`) to `phoenix_kit_comments`
  - Enables storing arbitrary extra data on comments without schema changes

  ### V81 - Add position column to entity_data
  - Adds `position` integer column to `phoenix_kit_entity_data` for manual reordering
  - Backfills existing records based on creation date
  - Adds composite index on `(entity_uuid, position)`

  ### V80 - Emails i18n: JSON language fields
  - Converts 5 fields in `phoenix_kit_email_templates` to JSONB for multilingual support
    (`subject`, `html_body`, `text_body`, `display_name`, `description`)
  - Existing string values are wrapped as `{"en": "original_value"}`
  - Adds `locale VARCHAR(10)` to `phoenix_kit_email_logs` for tracking sent language

  ### V79 - Newsletters module: newsletter lists, broadcasts, deliveries
  - Creates `phoenix_kit_newsletters_lists`, `phoenix_kit_newsletters_list_members`,
    `phoenix_kit_newsletters_broadcasts`, `phoenix_kit_newsletters_deliveries`

  ### V77 - Rename Tickets module to Customer Service
  - Renames settings keys from `tickets_*` → `customer_service_*`
  - Renames `auto_granted_perm:tickets` → `auto_granted_perm:customer_service`
  - Updates `phoenix_kit_role_permissions.module_key` from `tickets` → `customer_service`

  ### V70 - Re-backfill UUID FK columns silently skipped in V56/V63
  - Fixes installs where `phoenix_kit_email_logs.uuid` was `character varying` instead
    of native `uuid` type, causing V56's backfill to fail or be silently skipped
  - Converts `phoenix_kit_email_logs.uuid` to native `uuid` type if needed
  - Re-backfills `email_log_uuid` in `phoenix_kit_email_events` (resets stale random
    UUIDs written by the V56 NULL-fill fallback, then re-runs the proper JOIN backfill)
  - Re-backfills `matched_email_log_uuid` in `phoenix_kit_email_orphaned_events`
  - All operations idempotent — safe on every install

  ### V72 - Rename `id` → `uuid` on 30 Category A tables
  - Metadata-only column rename (instant, zero downtime)
  - Add 4 missing FK constraints (comments, scheduled_jobs)

  ### V73 - Pre-drop prerequisites for Category B tables
  - SET NOT NULL on 7 uuid columns
  - CREATE UNIQUE INDEX on 3 tables
  - ALTER INDEX RENAME on 4 indexes

  ### V74 - Drop integer columns, promote `uuid` to PK
  - Drop all FK constraints referencing integer `id` columns
  - Drop ~95 integer FK columns across all tables
  - Drop bigint `id` PK + promote `uuid` to PK on 47 Category B tables
  - After V74, every PhoenixKit table uses `uuid` as its primary key

  ### V75 - Fix uuid column defaults, cleanup
  - Set DEFAULT uuid_generate_v7() on 27 tables missing it (Category A)
  - Fix 4 tables using gen_random_uuid() → uuid_generate_v7()
  - Drop orphaned phoenix_kit_id_seq sequence

  ## Migration Paths

  ### Fresh Installation (0 → Current)
  Runs all migrations V01 through V27 in sequence.

  ### Incremental Updates
  - V01 → V27: Runs V02 through V27 in sequence
  - V26 → V27: Runs V27 only (adds Oban tables)
  - V25 → V27: Runs V26 and V27 in sequence
  - V24 → V27: Runs V25, V26, and V27 in sequence
  - V20 → V27: Runs V21 through V27 in sequence

  ### Rollback Support
  - V27 → V26: Removes Oban tables and background job system
  - V26 → V25: Removes user_file_checksum, renames file_checksum back to checksum, restores checksum unique index
  - V25 → V24: Removes aspect ratio control from dimensions
  - V24 → V23: Removes unique index on checksum
  - V23 → V22: Removes session fingerprinting columns and indexes
  - V22 → V21: Removes audit logging system, email orphaned events, and email metrics
  - V21 → V20: Removes composite message ID index
  - V15 → V14: Removes email templates system
  - V14 → V13: Removes body compression support
  - V13 → V12: Removes enhanced email tracking and AWS SES integration
  - V12 → V11: Removes JSON settings support and restores NOT NULL constraint
  - V11 → V10: Removes per-user timezone settings
  - V10 → V09: Removes registration analytics system
  - V09 → V08: Removes email blocklist system
  - V08 → V07: Removes username support
  - V07 → V06: Removes email tracking system
  - Full rollback to V01: Keeps only basic authentication

  ## Usage Examples

      # Update to latest version (V27)
      PhoenixKit.Migrations.Postgres.up(prefix: "myapp")

      # Update to specific version
      PhoenixKit.Migrations.Postgres.up(prefix: "myapp", version: 27)

      # Rollback to specific version
      PhoenixKit.Migrations.Postgres.down(prefix: "myapp", version: 26)

      # Complete rollback
      PhoenixKit.Migrations.Postgres.down(prefix: "myapp", version: 0)

  ## PostgreSQL Features
  - Schema prefix support for multi-tenant applications
  - Optimized indexes for performance
  - Foreign key constraints with proper cascading
  - Extension support (citext)
  - Version tracking with table comments
  """

  @behaviour PhoenixKit.Migration

  use Ecto.Migration

  @initial_version 1
  @current_version 97
  @default_prefix "public"

  @doc false
  def initial_version, do: @initial_version

  @doc false
  def current_version, do: @current_version

  @impl PhoenixKit.Migration
  def up(opts) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 ->
        change(@initial_version..opts.version, :up, opts)

      initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      true ->
        :ok
    end
  end

  @impl PhoenixKit.Migration
  def down(opts) do
    # For down operations, don't set a default version - let target_version logic handle it
    opts = Enum.into(opts, %{prefix: @default_prefix})

    opts =
      opts
      |> Map.put(:quoted_prefix, inspect(opts.prefix))
      |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
      |> Map.put_new(:create_schema, opts.prefix != @default_prefix)

    current_version = migrated_version(opts)

    # Determine target version:
    # - If version not specified, rollback to complete removal (0)
    # - If version specified, rollback to that version
    target_version = Map.get(opts, :version, 0)

    if current_version > target_version do
      # For rollback from version N to version M, execute down for versions N, N-1, ..., M+1
      # This means we don't execute down for the target version itself
      change(current_version..(target_version + 1)//-1, :down, opts)
    end
  end

  @impl PhoenixKit.Migration
  def migrated_version(opts) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    # First check if phoenix_kit table exists
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'phoenix_kit'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        # Table exists, check for version comment
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo().query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
          # Table exists but no version comment - assume version 1 (legacy V01 installation)
          _ -> 1
        end

      {:ok, %{rows: [[false]]}} ->
        # Table doesn't exist - no PhoenixKit installed
        0

      _ ->
        0
    end
  end

  @doc """
  Get current migrated version from database in runtime context (outside migrations).

  This function can be called from Mix tasks and other non-migration contexts.
  """
  def migrated_version_runtime(opts) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    # Add retry logic for better reliability
    retry_version_detection(opts, escaped_prefix, 3)
  rescue
    _ ->
      0
  end

  # Retry version detection with exponential backoff
  defp retry_version_detection(opts, escaped_prefix, retries_left) when retries_left > 0 do
    # Use hybrid repo detection with fallback strategies
    case get_repo_with_fallback() do
      nil when retries_left > 1 ->
        # Wait a bit and retry
        Process.sleep(100)
        retry_version_detection(opts, escaped_prefix, retries_left - 1)

      nil ->
        0

      repo ->
        # Ensure repo is started before querying database
        case ensure_repo_started(repo) do
          :ok ->
            case check_version_with_runtime_repo(repo, escaped_prefix) do
              0 when retries_left > 1 ->
                # If we get 0 but repo is available, retry once more
                Process.sleep(50)
                check_version_with_runtime_repo(repo, escaped_prefix)

              version ->
                version
            end

          {:error, _reason} when retries_left > 1 ->
            # If repo can't be started, wait and retry
            Process.sleep(100)
            retry_version_detection(opts, escaped_prefix, retries_left - 1)

          {:error, _reason} ->
            # Final retry failed - return 0 (not installed)
            0
        end
    end
  rescue
    _ ->
      if retries_left > 1 do
        Process.sleep(100)
        retry_version_detection(opts, escaped_prefix, retries_left - 1)
      else
        0
      end
  end

  defp retry_version_detection(_opts, _escaped_prefix, 0), do: 0

  # Check version using runtime repo (same logic as migrated_version)
  defp check_version_with_runtime_repo(repo, escaped_prefix) do
    # First check if phoenix_kit table exists
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'phoenix_kit'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo.query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        # Table exists, check for version comment
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo.query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
          # Table exists but no version comment - assume version 1 (legacy V01 installation)
          _ -> 1
        end

      {:ok, %{rows: [[false]]}} ->
        # Table doesn't exist - no PhoenixKit installed
        0

      _ ->
        0
    end
  end

  @doc """
  Heal version comment if schema artifacts exist for a higher version.

  V83 had a bug where the COMMENT ON TABLE statement used an incorrect prefix,
  leaving the comment at the previous version even though the migration ran
  successfully. This function detects and corrects the mismatch.

  Returns `{:healed, new_version}` if the comment was fixed, or `:ok` if
  no healing was needed.
  """
  def heal_version_comment(reported_version, opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, opts[:prefix] || "public")
    prefix_str = if escaped_prefix != "public", do: "#{escaped_prefix}.", else: ""

    case get_repo_with_fallback() do
      nil ->
        :ok

      repo ->
        healed =
          version_checks()
          |> Enum.filter(fn {v, _query} -> v > reported_version and v <= @current_version end)
          |> Enum.sort_by(fn {v, _} -> v end)
          |> Enum.reduce(reported_version, fn {v, check_query_fn}, acc ->
            query = check_query_fn.(escaped_prefix, prefix_str)

            case repo.query(query, [], log: false) do
              {:ok, %{rows: [[true]]}} -> v
              _ -> acc
            end
          end)

        if healed > reported_version do
          comment_query =
            "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '#{healed}'"

          repo.query(comment_query, [], log: false)
          {:healed, healed}
        else
          :ok
        end
    end
  rescue
    _ -> :ok
  end

  # Schema artifact checks for versions that may have had comment bugs.
  # Each entry is {version, fn(escaped_prefix, prefix_str) -> verification_query}.
  defp version_checks do
    [
      {83,
       fn escaped_prefix, _prefix_str ->
         """
         SELECT EXISTS (
           SELECT FROM information_schema.columns
           WHERE table_schema = '#{escaped_prefix}'
           AND table_name = 'phoenix_kit_publishing_groups'
           AND column_name = 'status'
         )
         """
       end}
    ]
  end

  defp change(range, direction, opts) do
    range_list = Enum.to_list(range)
    total_steps = length(range_list)

    show_migration_header(range_list, direction, total_steps)
    execute_migration_steps(range_list, direction, opts, total_steps)
    show_completion_message(total_steps)
    handle_version_recording(direction, range, opts, total_steps)
  end

  # Show migration progress header for multi-step migrations
  defp show_migration_header(range_list, direction, total_steps) do
    if total_steps > 1 do
      {start_version, end_version} =
        case direction do
          :up -> {Enum.min(range_list), Enum.max(range_list)}
          :down -> {Enum.max(range_list), Enum.min(range_list)}
        end

      action = if direction == :up, do: "Applying", else: "Rolling back"

      IO.puts(
        "🔄 #{action} PhoenixKit V#{String.pad_leading(to_string(start_version), 2, "0")}→V#{String.pad_leading(to_string(end_version), 2, "0")}"
      )
    end
  end

  # Execute migration steps with progress tracking
  defp execute_migration_steps(range_list, direction, opts, total_steps) do
    range_list
    |> Enum.with_index()
    |> Enum.each(fn {index, step_index} ->
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      # Show progress bar for multi-step migrations
      if total_steps > 1 do
        show_migration_progress(step_index + 1, total_steps, "V#{pad_idx}")
      end

      [__MODULE__, "V#{pad_idx}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end)
  end

  # Show completion message for multi-step migrations
  defp show_completion_message(total_steps) do
    if total_steps > 1 do
      IO.puts("✅ PhoenixKit migration complete\n")
    end
  end

  # Handle version recording based on direction
  defp handle_version_recording(direction, range, opts, total_steps) do
    case direction do
      :up ->
        # For up migrations, only set final version comment for multi-step migrations
        # Individual migrations handle their own version comments for single steps
        if total_steps > 1 do
          record_version(opts, Enum.max(range))
        end

      :down ->
        # For down migrations, let individual migration handle version comments
        # This prevents conflicts with version comments in migration down() functions
        :ok
    end
  end

  # Show migration progress bar
  defp show_migration_progress(current_step, total_steps, version_info) do
    percentage = div(current_step * 100, total_steps)
    progress_width = 20
    filled_width = div(current_step * progress_width, total_steps)
    empty_width = progress_width - filled_width

    filled_bar = String.duplicate("█", filled_width)
    empty_bar = String.duplicate("▒", empty_width)

    progress_bar = "#{filled_bar}#{empty_bar}"

    # Use carriage return to update the same line
    IO.write(
      "\r#{progress_bar} #{percentage}% (#{current_step}/#{total_steps} migrations) #{version_info}"
    )

    # Add newline after the last step
    if current_step == total_steps do
      IO.puts("")
    end
  end

  defp record_version(_opts, 0) do
    # Handle rollback to version 0 - tables are dropped, so we can't update comment
    # This is expected behavior for complete rollback
    :ok
  end

  defp record_version(%{prefix: prefix}, version) do
    # Use execute for migration context - only once per migration cycle
    execute "COMMENT ON TABLE #{prefix}.phoenix_kit IS '#{version}'"
  end

  # Get the application that owns the repo module

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
    |> Map.put_new(:create_schema, opts.prefix != @default_prefix)
  end

  # Hybrid repo detection with fallback strategies (shared with status command)
  defp get_repo_with_fallback do
    # Strategy 1: Try to get from PhoenixKit application config
    case PhoenixKit.Config.get_repo() do
      nil ->
        # Strategy 2: Try to ensure PhoenixKit application is started
        case ensure_phoenix_kit_started() do
          repo when not is_nil(repo) ->
            repo

          nil ->
            # Strategy 3: Auto-detect from project configuration
            detect_repo_from_project()
        end

      repo ->
        repo
    end
  end

  # Try to start PhoenixKit application and get repo config
  defp ensure_phoenix_kit_started do
    Application.ensure_all_started(:phoenix_kit)
    PhoenixKit.Config.get_repo()
  rescue
    _ -> nil
  end

  # Auto-detect repository from project configuration
  defp detect_repo_from_project do
    parent_app_name = Mix.Project.config()[:app]

    # Try :ecto_repos config first
    case try_ecto_repos_config(parent_app_name) do
      nil -> try_naming_patterns(parent_app_name)
      repo -> repo
    end
  end

  # Try to get repo from :ecto_repos application config
  defp try_ecto_repos_config(nil), do: nil

  defp try_ecto_repos_config(app_name) do
    case Application.get_env(app_name, :ecto_repos, []) do
      [repo | _] when is_atom(repo) ->
        if ensure_repo_loaded?(repo), do: repo, else: nil

      [] ->
        nil
    end
  rescue
    _ -> nil
  end

  # Try common naming patterns
  defp try_naming_patterns(nil), do: nil

  defp try_naming_patterns(app_name) do
    # Try most common pattern: AppName.Repo
    repo_module = Module.concat([Macro.camelize(to_string(app_name)), "Repo"])

    if ensure_repo_loaded?(repo_module) do
      repo_module
    else
      nil
    end
  end

  # Check if repo module exists and is loaded
  defp ensure_repo_loaded?(repo) when is_atom(repo) and not is_nil(repo) do
    Code.ensure_loaded?(repo) && function_exported?(repo, :__adapter__, 0)
  rescue
    _ -> false
  end

  defp ensure_repo_loaded?(_), do: false

  # Ensure repo is properly started for database operations.
  # In --no-start context, Repo process may not be running yet.
  defp ensure_repo_started(repo) do
    if Process.whereis(repo) != nil do
      :ok
    else
      start_repo_with_config(repo)
    end
  rescue
    error -> {:error, "Failed to start repo: #{inspect(error)}"}
  end

  defp start_repo_with_config(repo) do
    # Try Mix.Ecto.ensure_repo first (handles config resolution)
    if Code.ensure_loaded?(Mix.Ecto) do
      Mix.Ecto.ensure_repo(repo, [])

      # ensure_repo loads but doesn't start — start the process
      if Process.whereis(repo) == nil do
        do_start_repo(repo)
      else
        :ok
      end
    else
      do_start_repo(repo)
    end
  end

  defp do_start_repo(repo) do
    # Get config from parent app's application env
    app =
      if Code.ensure_loaded?(Mix) and function_exported?(Mix.Project, :config, 0),
        do: Mix.Project.config()[:app]

    config = if app, do: Application.get_env(app, repo, []), else: []

    # Ensure required applications are started before starting repo
    # These must be started for repo.start_link/1 to work:
    # - :telemetry (for DBConnection metrics)
    # - :db_connection (provides DBConnection.Watcher)
    # - :ecto (provides Ecto.Repo.Registry)
    # - :postgrex (provides Postgrex.SCRAM.LockedCache)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:db_connection)
    Application.ensure_all_started(:ecto)
    Application.ensure_all_started(:postgrex)

    case repo.start_link(config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, "Failed to start #{inspect(repo)}: #{inspect(reason)}"}
    end
  end
end
