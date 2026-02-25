# Comprehensive UUID Migration Cleanup Analysis

**Date:** 2026-02-26  
**Analyst:** Mistral Vibe
**Scope:** Complete analysis of remaining `_id` field usage after V62 migration

## Executive Summary

This analysis builds upon the previous audit (2026-02-25) and provides a comprehensive view of the current state of UUID migration cleanup. The analysis reveals:

1. **Most schemas still have legacy `field :*_id, :integer` declarations** for database compatibility
2. **Many schemas have already removed `_id` fields from `cast()` functions** (good progress)
3. **Some schemas still cast both `_id` and `_uuid` fields** (need cleanup)
4. **Several context functions still support legacy integer IDs** (need cleanup)
5. **The pattern shows partial cleanup was done, but field declarations remain**

## Current State Analysis

### Pattern Observed

The codebase shows a **two-phase cleanup approach**:
1. **Phase 1 (Completed for some modules)**: Remove `_id` from `cast()` functions, keep field declarations for DB compatibility
2. **Phase 2 (Pending)**: Remove field declarations entirely once DB columns can be dropped

### Categories of Schemas

#### Category 1: Dual-Write Schemas (Both `_id` and `_uuid` in cast)

These schemas still cast both integer and UUID fields:

**Billing Module:**
- `invoice.ex`: `:user_id`, `:user_uuid`, `:order_id`, `:order_uuid` in cast
- `order.ex`: Need to verify current state
- `subscription.ex`: Need to verify current state

**Shop Module:**
- `cart.ex`: `:payment_option_id`, `:payment_option_uuid`, `:merged_into_cart_id`, `:merged_into_cart_uuid` in cast
- `category.ex`: `:featured_product_id`, `:featured_product_uuid`, `:parent_id`, `:parent_uuid` in cast
- `product.ex`: `:category_id`, `:category_uuid`, `:created_by`, `:created_by_uuid` in cast

**Referrals Module:**
- `referral_code_usage.ex`: `:code_id`, `:code_uuid`, `:used_by`, `:used_by_uuid` in cast

#### Category 2: Partially Cleaned Schemas (Field declarations remain, but not in cast)

These schemas have removed `_id` from `cast()` but still have field declarations:

**Comments Module:**
- `comment_like.ex`: Has `field :user_id, :integer` but only casts `:user_uuid`
- `comment_dislike.ex`: Has `field :user_id, :integer` but only casts `:user_uuid`
- `comment.ex`: Has `field :user_id, :integer` but casts both `:user_id` and `:user_uuid`

**Posts Module:**
- `post_like.ex`: Has `field :user_id, :integer` but need to check cast
- `post_dislike.ex`: Has `field :user_id, :integer` but need to check cast
- `comment_like.ex`: Has `field :user_id, :integer` but need to check cast
- `comment_dislike.ex`: Has `field :user_id, :integer` but need to check cast

**Billing Module:**
- `billing_profile.ex`: Has `field :user_id, :integer` but need to check cast
- `payment_method.ex`: Has `field :user_id, :integer` but need to check cast
- `transaction.ex`: Has `field :user_id, :integer` and `field :invoice_id, :integer` but need to check cast

#### Category 3: Context Functions with Legacy Support

Functions that still handle integer IDs:

**Billing Context:**
- `create_order/1`: Resolves `user_id` to `user_uuid` (line 958)
- Need to check if other functions still use integer IDs

**Shop Context:**
- `filter_by_category/2`: Handles both integer and UUID category IDs (lines 2631, 2642)
- Need to check other filter functions

**Comments Context:**
- `create_comment/4`: Has overloads for both integer and binary user_id
- Need to verify if this was cleaned up in recent commits

**Other Modules:**
- `AI.request.ex`: Has multiple `_id` fields that need analysis
- `Connections` module: Multiple schemas with `_id` fields
- `Entities` module: Has `entity_id` field and resolution functions
- `Legal` module: `consent_log.ex` has `user_id` with resolution
- `Storage` module: `file.ex` has `user_id` field
- `Sync` module: `transfer.ex` has `connection_id` field

## Detailed Findings by Module

### Billing Module

**Schemas with `_id` fields:**
- `billing_profile.ex`: `user_id`
- `invoice.ex`: `user_id`, `order_id`
- `order.ex`: `user_id`
- `payment_method.ex`: `user_id`
- `subscription.ex`: `user_id`, `plan_id`, `payment_method_id`
- `transaction.ex`: `invoice_id`, `user_id`

**Status:**
- `billing_profile_id` was removed from order/subscription schemas (commit 866ab18e)
- Other `_id` fields still present in both field declarations and cast functions

### Comments Module

**Schemas with `_id` fields:**
- `comment.ex`: `user_id`
- `comment_like.ex`: `user_id`
- `comment_dislike.ex`: `user_id`

**Status:**
- Like/dislike schemas removed `_id` from cast (good)
- Comment schema still casts both `user_id` and `user_uuid` (needs cleanup)
- Context functions may still have legacy support (need verification)

### Shop Module

**Schemas with `_id` fields:**
- `cart.ex`: `user_id`, `shipping_method_id`, `payment_option_id`, `merged_into_cart_id`
- `cart_item.ex`: `cart_id`, `product_id`
- `category.ex`: `parent_id`, `featured_product_id`
- `import_log.ex`: `user_id`, `product_ids`
- `product.ex`: `category_id`, `created_by`

**Status:**
- Multiple schemas still cast both `_id` and `_uuid` fields
- Context functions like `filter_by_category` handle both types
- High priority for cleanup

### Other Modules with `_id` Fields

**AI Module:**
- `request.ex`: `endpoint_id`, `prompt_id`, `account_id`, `user_id`

**Connections Module:**
- Multiple schemas with various `_id` fields for user relationships

**Entities Module:**
- `entity_data.ex`: `entity_id`
- Has resolution functions for UUID conversion

**Emails Module:**
- Multiple schemas with `user_id` fields

**Legal Module:**
- `consent_log.ex`: `user_id` with resolution logic

**Posts Module:**
- Multiple schemas with `user_id` fields

**Publishing Module:**
- `publishing_post.ex`: `created_by_id`, `updated_by_id`
- `publishing_version.ex`: `created_by_id`

**Referrals Module:**
- `referral_code_usage.ex`: `code_id`, `used_by`

**Storage Module:**
- `file.ex`: `user_id`

**Sync Module:**
- `transfer.ex`: `connection_id`

**Tickets Module:**
- Multiple schemas with `user_id` fields

## Recommendations

### Priority 1: High Impact (Active Dual-Write Schemas)

1. **Shop Module**
   - `cart.ex`: Remove `_id` fields from all cast functions
   - `category.ex`: Remove `_id` fields from cast
   - `product.ex`: Remove `_id` fields from cast
   - `shop.ex` context: Update `filter_by_category` to UUID-only

2. **Billing Module**
   - `invoice.ex`: Remove `user_id`, `order_id` from cast
   - `billing.ex` context: Remove `user_id` resolution from `create_order/1`

3. **Referrals Module**
   - `referral_code_usage.ex`: Remove `code_id`, `used_by` from cast

### Priority 2: Medium Impact (Field Declarations Only)

4. **Remove field declarations** from schemas that no longer use them in cast:
   - Comments: `comment_like.ex`, `comment_dislike.ex`
   - Posts: Various like/dislike schemas
   - Billing: `billing_profile.ex`, `payment_method.ex`, etc.

### Priority 3: Context Functions

5. **Update context functions** to remove legacy integer ID support:
   - Billing: `create_order/1` and related functions
   - Shop: `filter_by_category/2` and other filter functions
   - Comments: Verify if `create_comment/4` was cleaned up
   - Other modules as identified

### Priority 4: Comprehensive Cleanup

6. **Systematic approach** for remaining modules:
   - AI, Connections, Entities, Emails, Legal, Publishing, Storage, Sync, Tickets
   - Follow the same pattern: remove from cast first, then remove field declarations

## Files Requiring Immediate Attention

### High Priority (Dual-Write in Cast)
```elixir
# Billing
lib/modules/billing/schemas/invoice.ex
lib/modules/billing/billing.ex

# Shop  
lib/modules/shop/schemas/cart.ex
lib/modules/shop/schemas/category.ex
lib/modules/shop/schemas/product.ex
lib/modules/shop/shop.ex

# Referrals
lib/modules/referrals/schemas/referral_code_usage.ex
```

### Medium Priority (Field Declarations Only)
```elixir
# Comments
lib/modules/comments/schemas/comment_like.ex
lib/modules/comments/schemas/comment_dislike.ex

# Posts
lib/modules/posts/schemas/post_like.ex
lib/modules/posts/schemas/post_dislike.ex
lib/modules/posts/schemas/comment_like.ex
lib/modules/posts/schemas/comment_dislike.ex

# Billing
lib/modules/billing/schemas/billing_profile.ex
lib/modules/billing/schemas/payment_method.ex
lib/modules/billing/schemas/transaction.ex
```

## Migration Strategy

### Step 1: Remove from Cast Functions
- Remove `_id` fields from all `cast(attrs, [...])` calls
- Ensure only `_uuid` fields remain
- Update validation to use UUID fields only

### Step 2: Update Context Functions
- Remove functions that resolve UUIDs from integer IDs
- Update function signatures to accept only UUIDs
- Remove integer ID parameter overloads

### Step 3: Remove Field Declarations (Future)
- Once all code stops writing to `_id` fields
- Can be done in a separate PR after confirming no writes occur
- Requires database migration to drop columns

### Step 4: Database Cleanup (Future)
- Drop integer ID columns from database
- Remove related indexes
- Update migrations

## Verification Checklist

1. **Search for all `cast` functions** containing `_id` fields
2. **Search for context functions** with integer ID parameters
3. **Search for resolution functions** that convert ID → UUID
4. **Check test files** for integer ID usage
5. **Verify web/LiveView layers** don't pass integer IDs
6. **Check API endpoints** for integer ID parameters

## Tools for Verification

```bash
# Find all field declarations with _id
grep -r "field.*_id.*:integer" lib/modules/ --include="*.ex"

# Find cast functions with _id
grep -r "cast.*\[.*_id" lib/modules/ --include="*.ex"

# Find functions with _id parameters  
grep -r "def.*_id.*attrs" lib/modules/ --include="*.ex"

# Find resolution functions
grep -r "resolve.*uuid" lib/modules/ --include="*.ex"
```

## Estimated Effort

- **High Priority Cleanup**: 4-6 hours
- **Medium Priority Cleanup**: 2-3 hours  
- **Context Function Updates**: 3-4 hours
- **Comprehensive Cleanup**: 6-8 hours
- **Total**: 15-21 hours

## Next Steps

1. ✅ Complete comprehensive analysis (this document)
2. ⏳ Update original audit document with findings
3. ⏳ Create detailed cleanup plan with specific file changes
4. ⏳ Implement high-priority cleanup
5. ⏳ Test changes thoroughly
6. ⏳ Proceed with medium/low priority cleanup
