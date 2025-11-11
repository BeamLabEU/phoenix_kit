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
  + bounced_at (utc_datetime_usec)
  + complained_at (utc_datetime_usec)
  + opened_at (utc_datetime_usec)
  + clicked_at (utc_datetime_usec)

New Tables:
  + phoenix_kit_email_orphaned_events (track unmatched SQS events)
  + phoenix_kit_email_metrics (system metrics tracking)

New Indexes:
  + phoenix_kit_email_logs_aws_message_id_uidx (partial unique)
  + phoenix_kit_email_logs_message_ids_idx (composite)
  + phoenix_kit_email_events_log_type_idx (composite, 10-100x faster)
```

**Message ID Workflow:**
```
1. Email Created → message_id = "pk_12345" (internal)
2. Email Sent → aws_message_id = "0102abc..." (from AWS SES)
3. SQS Event → Searches by aws_message_id → Updates EmailLog
```

**Performance Improvements:**
- Event duplicate checking: 10-100x faster with composite index
- Message correlation: Instant lookup with dual message ID strategy
- Orphaned event tracking: No more lost SQS events

**Migration Notes:**
- All changes are backward compatible
