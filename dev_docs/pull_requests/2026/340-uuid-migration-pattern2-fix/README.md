# PR #340 — UUID Migration & Pattern 2 Fix

## What
Large-scale UUID migration across Connections, Comments, Referrals, Posts, Tickets, and Storage modules. Completes the Pattern 2 schema normalization (29 schemas changed from `@primary_key {:id, UUIDv7}` to `{:uuid, UUIDv7, source: :id}`).

## Why
The codebase had two conflicting primary key patterns: Pattern 1 schemas used `.uuid` for the UUID field, while Pattern 2 schemas used `.id`. This caused confusion and inconsistency. Additionally, ~20 schemas still had `belongs_to :user, type: :integer` which needed migration to UUID-based associations.

## How
- Migrated 29 Pattern 2 schemas to use `source: :id` (DB column stays `id`, Elixir field becomes `:uuid`)
- Converted ~20 `belongs_to :user, type: :integer` to UUID-based associations with dual-write
- Updated context modules, LiveViews, and templates from `.id` to `.uuid`
- Fixed `@foreign_key_type :id` bug in 3 connection history schemas
- Added explicit `foreign_key:` to 10 `has_many` associations
- Fixed 2 composite-PK schemas with missing `references: :uuid`
- Cleaned up 10 Dialyzer warnings

## Review
See `CLAUDE_REVIEW.md` for comprehensive audit findings including 2 runtime bugs and 1 incompletely migrated module.
