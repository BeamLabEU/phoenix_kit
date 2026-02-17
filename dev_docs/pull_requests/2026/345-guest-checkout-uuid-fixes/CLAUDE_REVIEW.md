# PR #345 Review: Fix guest checkout flow and UUID migration constraints

**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/345
**Author**: timujinne
**Merged**: 2026-02-17
**Files changed**: 19 (+189 / -51)
**Reviewer**: Claude Opus 4.6

---

## Summary

Multi-concern PR that fixes guest checkout failures caused by NOT NULL constraints on legacy integer FK columns, improves checkout UX messaging, adds login redirect flow (`return_to`) for existing-email guests, migrates shop module from `.id` to `.uuid`, and fixes smaller bugs (Language struct access, hardcoded project title).

## Verdict: Approve with observations

The changes are well-structured and address real runtime failures. Security handling (open redirect prevention) is correct. The UUID migration work is consistent with the ongoing migration strategy.

---

## Detailed Review

### 1. Guest Checkout Transaction Fix (`shop.ex`)

**Change**: Fix double-wrapped error in `convert_cart_to_order` transaction rollback.

```elixir
# Before: rollback({:error, reason}) → transaction returns {:error, {:error, reason}}
error -> repo().rollback(error)

# After: unwrap before rollback
{:error, reason} -> repo().rollback(reason)
other -> repo().rollback(other)
```

**Assessment**: Correct fix. The `Ecto.Repo.rollback/1` wraps in `{:error, ...}`, so passing `{:error, reason}` caused double-wrapping. The catch-all `other ->` clause handles unexpected non-tuple errors gracefully.

### 2. Legacy Integer FK Relaxation (`uuid_fk_columns.ex`)

**Change**: Add `@relax_integer_fks` list and `relax_integer_not_null/4` to DROP NOT NULL on legacy integer FK columns where Ecto schemas now exclusively write UUID FKs.

**Affected columns**:
- `phoenix_kit_user_role_assignments.user_id`
- `phoenix_kit_user_role_assignments.role_id`
- `phoenix_kit_user_role_assignments.assigned_by`
- `phoenix_kit_role_permissions.role_id`

**Assessment**: Sound approach. The guard chain (`table_exists? && column_exists? && column_is_not_null?`) makes it idempotent. The `column_is_not_null?` helper queries `information_schema.columns` correctly.

**Observation**: The `@relax_integer_fks` list is intentionally scoped to only columns that are currently causing failures (role tables). Other integer FK columns that still get populated by code are correctly excluded. If more columns need relaxation as UUID migration progresses, this list should be extended.

### 3. `IF NOT EXISTS` for ADD COLUMN

**Change**: Replace `unless column_exists?` wrapper with SQL-native `ADD COLUMN IF NOT EXISTS`.

**Assessment**: Good improvement for idempotency. However, the `unless` wrapper was still kept around the `execute` block in the remote version. This was resolved in our merge (kept the cleaner unwrapped version).

### 4. Shop Module `.id` to `.uuid` Migration (6 web files + 2 import files)

**Change**: All `get_storage_image_url` functions in shop web modules now use `%{uuid: uuid}` pattern match and pass `uuid` to `Storage.get_file_instance_by_name/2`. Import modules similarly updated.

**Assessment**: Consistent, mechanical change across all shop web views. The pattern is identical in all 6 files:

```elixir
# Before
%{id: id} -> Storage.get_file_instance_by_name(id, variant)
# After
%{uuid: uuid} -> Storage.get_file_instance_by_name(uuid, variant)
```

**Note**: `URLSigner.signed_url(file_id, ...)` still uses the original `file_id` parameter (not `uuid`), which is correct since `file_id` comes from the caller and may already be UUID-based depending on context.

### 5. Cart Status Transition (`cart.ex`)

**Change**: Add `"converting"` intermediate status with transitions:
- `"active" -> "converting"` (new)
- `"converting" -> "converted"` or `"converting" -> "active"` (rollback)

**Assessment**: Good pattern for transaction safety. Prevents concurrent checkout attempts on the same cart. The `"converting" -> "active"` transition allows recovery on failure.

### 6. Login `return_to` Support (login.ex, login.html.heex, session.ex)

**Change**: Login LiveView reads `return_to` query param, passes as hidden form field, session controller stores it for post-login redirect.

**Security review**:
- `sanitize_return_to/1` in `login.ex`: Checks `String.starts_with?(path, "/")` and rejects `"//"` (protocol-relative URLs). Correct.
- `maybe_store_return_to_from_params/2` in `session.ex`: Same validation duplicated. Correct but slightly redundant.

**Assessment**: The open redirect prevention is correct. The dual validation (LiveView + Controller) is defense-in-depth since the form could be submitted directly bypassing LiveView.

### 7. Guest Cart Merge on Login (`auth.ex`)

**Change**: `maybe_merge_guest_cart/2` called before `renew_session()` to merge guest cart into user's cart on login.

```elixir
defp maybe_merge_guest_cart(conn, user) do
  shop_session_id = conn.cookies["shop_session_id"] || get_session(conn, :shop_session_id)
  if shop_session_id do
    try do
      Shop.merge_guest_cart(shop_session_id, user)
    rescue
      _ -> :ok
    end
  end
end
```

**Observation**: The bare `rescue _ -> :ok` silently swallows all errors including unexpected ones. This is intentional (cart merge failure shouldn't block login), but it means merge failures are invisible. Consider adding a `Logger.warning` in the rescue clause so failures are at least logged for debugging.

### 8. Email Exists Error UX (`checkout_page.ex`)

**Change**: Replace generic error flash with a dedicated `email_exists_error` card showing "Account already exists" with a "Log in to continue" button that redirects to login with `return_to=/checkout`.

**Assessment**: Much better UX than the previous generic error message. The flow: guest enters existing email → sees card with login button → logs in → redirected back to checkout with cart merged.

### 9. Checkout Complete UX (`checkout_complete.ex`)

**Change**: Soften guest confirmation messaging from `alert-warning` to `alert-info`, add numbered step-by-step instructions, add spam folder hint. Hide "confirmation email" text for non-guest orders (they already know).

**Assessment**: Good UX improvement. Numbered steps are clearer than the previous wall of text.

### 10. Minor Fixes

- **`layout_wrapper.ex`**: `project_title` default `"PhoenixKit"` → `nil` so it falls through to `Settings.get_project_title()`. Correct.
- **`modules.html.heex`**: `@languages_default["name"]` → `@languages_default.name` (Language is a struct, not a map). Correct.
- **`.dialyzer_ignore.exs`**: Added pattern_match ignore for `uuid_fk_columns.ex` where prefix parameter can be nil at runtime but Dialyzer infers binary-only.

---

## Issues Found

### Minor

1. **Silent cart merge failure** (`auth.ex:114-116`): The `rescue _ -> :ok` swallows errors silently. A `Logger.warning/1` would help debug production issues where carts don't merge as expected.

2. **Duplicated `get_storage_image_url/2`**: The exact same function is copy-pasted across 6 shop web modules (`catalog_category.ex`, `catalog_product.ex`, `product_detail.ex`, `products.ex`, `shop_catalog.ex`, and likely `checkout_page.ex`). This is a pre-existing issue, not introduced by this PR, but worth extracting to a shared helper (e.g., `PhoenixKit.Modules.Shop.Web.Helpers`) during a future cleanup.

3. **`@relax_integer_fks` scope**: Only role-related columns are relaxed. As UUID migration continues and more schemas drop integer FK writes, this list will need extending. Worth a comment or tracking issue.

---

## Security Assessment

- **Open redirect prevention**: Correctly validates `return_to` paths (must start with `/`, rejects `//`). Double-validated at both LiveView mount and controller action.
- **Cart merge**: Uses `try/rescue` so shop module errors can't disrupt authentication flow.
- **No SQL injection risk**: Migration SQL uses string interpolation but only with controlled module attributes (table/column names from `@relax_integer_fks`), not user input.

---

## Architecture Notes

- The `"converting"` cart status is a good pattern for preventing race conditions in multi-step transactions. Consider applying this pattern to other stateful resources.
- The `return_to` flow correctly threads through: query param → hidden field → session → redirect. This is the standard Phoenix pattern.
- The `@relax_integer_fks` approach (explicitly listing columns to relax) is safer than a blanket "relax all integer FKs" since some tables may still need both integer and UUID columns populated during the transition period.
