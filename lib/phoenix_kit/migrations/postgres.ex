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

  ### V17 - Entities System (WordPress ACF-like)
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
  - Phoenix_kit_subscription_plans for subscription pricing plans
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

  ### V37 - DB Sync Connections & Transfer Tracking
  - Phoenix_kit_db_sync_connections for permanent site-to-site connections
  - Phoenix_kit_db_sync_transfers for tracking all data transfers
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

  ### V44 - Sync Table Rename ⚡ LATEST
  - Rename phoenix_kit_db_sync_connections → phoenix_kit_sync_connections
  - Rename phoenix_kit_db_sync_transfers → phoenix_kit_sync_transfers
  - Rename all related indexes to match new table names
  - Matches module rename from DBSync to Sync

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
  @current_version 44
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

  # Ensure repo is properly started for database operations
  # Note: For Mix tasks, the application should already be started
  defp ensure_repo_started(repo) do
    # Try Mix.Ecto.ensure_repo if available
    if Code.ensure_loaded?(Mix.Ecto) do
      Mix.Ecto.ensure_repo(repo, [])
      :ok
    else
      # Basic check if repo is available
      if Code.ensure_loaded?(repo) && function_exported?(repo, :__adapter__, 0) do
        :ok
      else
        {:error, "Repository #{inspect(repo)} is not available"}
      end
    end
  rescue
    error -> {:error, "Failed to start repo: #{inspect(error)}"}
  end
end
