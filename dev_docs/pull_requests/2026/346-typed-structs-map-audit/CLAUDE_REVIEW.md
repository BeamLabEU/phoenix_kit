# PR #346 Review: Fixes for struct issues (Typed Structs Replacing Plain Maps)

**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/346
**Author**: alexdont (Alexander Don)
**Merged**: 2026-02-17
**Files changed**: 50 (+1357 / -234)
**Commits**: 11
**Reviewer**: Claude Opus 4.6

---

## Summary

Large-scale refactoring PR that converts 20 plain maps acting as de-facto structs into proper Elixir structs with `@enforce_keys`, `@type t()`, and `defstruct`. Backed by a thorough audit document (`dev_docs/audits/2026-02-16-struct-vs-map-audit.md`) that categorizes 27 map shapes into 3 tiers. Includes 4 follow-up fix commits for consumer-side access pattern bugs discovered during verification.

## Verdict: Approve with observations

This is a well-executed, methodical refactoring. The audit-first approach (document all map shapes, categorize by impact, convert in phases) is exemplary. The follow-up fix commits show diligent verification. The main risks are around backward compatibility at module boundaries.

---

## Scope

### New Struct Files (20 total)

| Module | Struct | File | Fields | Enforce Keys |
|--------|--------|------|--------|--------------|
| Billing | `CheckoutSession` | `providers/types/checkout_session.ex` | 5 | `[:id, :url, :provider]` |
| Billing | `SetupSession` | `providers/types/setup_session.ex` | 4 | `[:id, :url, :provider]` |
| Billing | `WebhookEventData` | `providers/types/webhook_event_data.ex` | 5 | `[:type, :event_id, :provider]` |
| Billing | `PaymentMethodInfo` | `providers/types/payment_method_info.ex` | 10 | `[:id, :provider, :provider_payment_method_id]` |
| Billing | `ChargeResult` | `providers/types/charge_result.ex` | 6 | `[:id, :status]` |
| Billing | `RefundResult` | `providers/types/refund_result.ex` | 5 | `[:id, :status]` |
| Billing | `ProviderInfo` | `providers/types/provider_info.ex` | 4 | `[:name, :icon, :color]` |
| Billing | `TimelineEvent` | `web/invoice_detail/timeline_event.ex` | 3 | `[:type]` |
| Billing | `IbanData` | `utils/iban_data.ex` (extended) | 2 | `[:length, :sepa]` |
| AI | `AIModel` | `ai_model.ex` | 9 | `[:id]` |
| Entities | `FieldType` | `field_type.ex` | 7 | `[:name, :label, :category]` |
| Emails | `EmailLogData` | `email_log_data.ex` | 16 | `[:message_id, :to, :from, :subject]` |
| Legal | `LegalFramework` | `legal_framework.ex` | 7 | `[:id, :name, :consent_model, :required_pages]` |
| Legal | `PageType` | `page_type.ex` | 4 | `[:slug, :title, :template]` |
| Dashboard | `Group` | `group.ex` | 5 | `[:id]` |
| Sync | `TableSchema` | `table_schema.ex` | 4 | `[:table, :schema, :columns]` |
| Sync | `ColumnInfo` | `column_info.ex` | 8 | `[:name, :type]` |
| Sitemap | `SitemapFile` | `sitemap_file.ex` | 3 | `[:filename, :url_count]` |
| Utils | `SessionFingerprint` | `session_fingerprint.ex` (extended) | 2 | `[:ip_address, :user_agent_hash]` |

### Updated Consumer Files

- 3 billing providers (Stripe, PayPal, Razorpay) — return structs instead of maps
- `provider.ex` — `@type` aliases now reference struct `.t()` types
- `billing.ex` — dot access on `CheckoutSession` (`session.id`, `session.url`)
- `subscription_renewal_worker.ex` — `charge_result.provider_transaction_id`
- `actions.ex` — match `{:ok, checkout_url}` string instead of `{:ok, %{url: _}}`
- `helpers.ex` — 10 construction sites updated to `%TimelineEvent{}`
- `interceptor.ex` — `%EmailLogData{}` construction
- `openrouter_client.ex` — `%AIModel{}` construction + backward-compat map clauses
- `endpoint_form.ex` + `.html.heex` — 19 string-key accesses → dot access
- `field_types.ex` — `from_map/1` conversion at boundary
- `legal.ex` — `from_map/1` conversion for frameworks and page types
- `schema_inspector.ex` — `%TableSchema{}` and `%ColumnInfo{}` construction
- `data_importer.ex` — struct-aware `get_primary_keys/1`
- `generator.ex` — `%SitemapFile{}` construction
- `registry.ex` — `Group.new/1` conversion
- `user_dashboard_categories.ex` — returns `%Group{}` structs
- `sidebar.ex` + `admin_sidebar.ex` — 11 bracket-access → dot notation
- `languages.ex` — `normalize_language_map/1` for struct-to-map before `Map.put`
- `user_token.ex` — multi-clause fingerprint extraction for struct/map/nil
- `modules.html.heex` — bracket → dot access for Language struct
- `uuid_fk_columns.ex` — remove dead `nil` branch in prefix handling

---

## Detailed Review

### 1. Billing Provider Types (7 structs)

**Quality**: Excellent. Clean separation into `providers/types/` directory. Each struct has:
- `@moduledoc` with field descriptions
- `@enforce_keys` for required fields
- `@type t` spec
- Sensible defaults (`metadata: %{}`)

**Field naming**: The rename from `session_id` to `id` in `CheckoutSession` is a good normalization (PayPal/Razorpay used `session_id`, Stripe already used `id`). This required updating `billing.ex` line 3090 from `session[:session_id]` to `session.id`.

**`actions.ex` change**: The pattern `{:ok, %{url: checkout_url}}` → `{:ok, checkout_url}` when `is_binary(checkout_url)` is notable. This means `Billing.create_checkout_session/3` now returns `{:ok, url_string}` rather than `{:ok, struct}`. This is correct per the `billing.ex` code which extracts the URL before returning, but it's a public API signature change.

### 2. AI Module (AIModel struct)

**Quality**: Good. The key architectural decision is correct: convert string-keyed JSON maps to atom-keyed structs at the `normalize_models/2` boundary.

**Backward compatibility**: Well handled. Every function (`model_option/1`, `model_supports_parameter?/2`, `get_model_max_tokens/1`, `get_supported_params/1`) has dual clauses:
```elixir
def model_option(%AIModel{} = model) do ... end
def model_option(model) when is_map(model) do ... end  # fallback
```

This is defensive — any code still passing raw JSON maps won't crash. The fallback clauses can be removed once all callers are confirmed to use `%AIModel{}`.

**`pricing` sub-map**: Still uses string keys (`pricing["prompt"]`, `pricing["completion"]`) inside the struct. This is pragmatic — the pricing structure varies and isn't worth its own struct yet. Documented in the `@moduledoc`.

### 3. Dashboard Group

**Quality**: Good. Extends the existing `Tab`/`Badge`/`ContextSelector` family.

**Fields added during fix pass**: `icon` and `collapsible` were initially missing from the struct, causing sidebar templates to silently get `nil` via bracket access. This is exactly the kind of bug structs are meant to catch — and it was found during the verification pass. Good demonstration of the refactoring's value.

**`Group.new/1` pattern**: Config-loaded maps converted via `Group.new/1` at the registry boundary. Clean.

### 4. Sync TableSchema + ColumnInfo

**Quality**: Good. The `@enforce_keys` choices are appropriate — `[:table, :schema, :columns]` for TableSchema ensures the critical fields are always present.

**`data_importer.ex` fix**: Added struct-aware clause for `get_primary_keys/1`:
```elixir
defp get_primary_keys(%TableSchema{primary_key: pk}), do: pk
defp get_primary_keys(%{"primary_key" => pk}), do: pk  # fallback for wire data
```
The dual clause handles both local struct and wire-protocol string-keyed map. Good.

### 5. Emails EmailLogData (16 fields)

**Quality**: Good. The largest struct in the PR. All 16 fields are documented. `@enforce_keys [:message_id, :to, :from, :subject]` covers the minimum viable email log.

### 6. Entities FieldType

**Quality**: Good. The `from_map/1` boundary converter handles both atom and string keys, which is necessary since `@field_types` module attribute uses atom keys.

**Performance note**: `all/0`, `get_type/1`, `by_category/1`, and `categories/0` all call `FieldType.from_map/1` on every invocation, converting module-attribute maps to structs at runtime. This is fine for the current usage (UI rendering, not hot paths), but if these become hot paths, the conversion could be moved to compile time.

### 7. Legal LegalFramework + PageType

**Quality**: Good. Same `from_map/1` boundary pattern as FieldType. Internal `@frameworks` and `@page_types` module attributes stay as plain maps (compile-time limitation — structs can't be constructed in module attributes if the struct module isn't compiled yet in the same compilation unit). The boundary conversion is the right approach.

### 8. Languages Fix

**Change**: `normalize_language_map/1` converts `%Language{}` struct to plain map before `Map.put(:country, ...)` because structs reject unknown keys.

**Assessment**: Correct fix. `Map.put(%Language{}, :country, ...)` would raise `KeyError` since `:country` isn't a Language field. Converting to map first is the right approach when adding ad-hoc keys for grouping.

### 9. UserToken Fingerprint Fix

**Change**: Multi-clause helper for extracting fingerprint attributes that handles `%SessionFingerprint{}` structs, plain maps, and `nil`.

**Assessment**: Good defensive pattern. Existing tokens in the database may have fingerprints stored as plain maps (before the struct conversion), so the map fallback is necessary.

---

## Issues Found

### Minor

1. **`from_map/1` runtime conversion overhead** (`field_types.ex`, `legal.ex`): Every call to `all/0`, `get_type/1`, `by_category/1`, `categories/0`, `available_frameworks/0`, `available_page_types/0` converts module-attribute maps to structs. For the current usage patterns this is negligible, but if any of these become hot paths, consider compile-time conversion (e.g., build the struct list in a `@compiled_field_types` attribute using `for` comprehension at module level).

2. **Fallback map clauses in AI module**: The `model_option/1`, `model_supports_parameter?/2`, `get_model_max_tokens/1`, and `get_supported_params/1` all have dual `%AIModel{}` + `is_map` clauses. These should be tracked for eventual removal once all callers are confirmed to use structs. Without removal, it's easy to accidentally introduce new code that passes raw maps and bypasses compile-time checking.

3. **`CheckoutSession` field name change**: `session_id` → `id` is correct but is a breaking change for any parent app code that pattern-matched on `%{session_id: _}`. Since this is an internal type (not part of the public PhoenixKit API), the risk is low, but worth noting.

4. **`IbanData.all_specs/0` constructs structs on every call**: Converts the entire `@iban_specs` map (92 countries) to structs each time. Consider memoizing with a module attribute if this is called frequently.

5. **Audit doc location**: `dev_docs/audits/2026-02-16-struct-vs-map-audit.md` is placed flat in `dev_docs/` root rather than in the PR directory. This is fine since it's a living reference document rather than a PR review file, but worth noting the distinction.

---

## Architecture Assessment

### What went well

- **Audit-first approach**: The `struct-vs-map-audit.md` document is thorough — it categorizes every map shape in the codebase into 3 tiers with clear rationale for what to convert and what to leave as-is. This should be the template for future large-scale refactoring efforts.

- **Boundary conversion pattern**: Using `from_map/1` at module boundaries (Legal, Entities) rather than trying to change compile-time module attributes is the correct approach given Elixir's compilation model.

- **Defensive dual clauses**: The AI module's backward-compatible map fallbacks prevent hard crashes during the transition period.

- **Verification passes**: Commits 8-11 show the team did multiple rounds of verification after the initial conversion, catching 21 consumer-side access bugs (bracket access on structs, wrong field names, missing struct fields).

### What to watch

- **Struct proliferation**: 20 new modules is a lot. The `providers/types/` directory alone has 7 files. This is the right trade-off for type safety, but the directory structure should be kept clean.

- **Mixed access patterns**: During the transition, some code uses struct dot access while fallback clauses use bracket/string-key access. This dual pattern should converge over time.

- **Wire protocol compatibility** (Sync module): `TableSchema` and `ColumnInfo` travel over the wire. Ensure the sync protocol serialization/deserialization handles both struct and map representations, since remote peers may be on different versions.

---

## Commit Quality

The commit history tells a clear story:

1. **Commits 1-6**: Individual struct conversions (SessionFingerprint → IbanData → SitemapFile → TimelineEvent → LegalFramework/PageType)
2. **Commit 7**: Large batch of 15 structs across billing, entities, sync, emails, AI, dashboard
3. **Commits 8-11**: Verification fix passes catching consumer-side bugs

The incremental approach (small structs first, large batch second, fixes third) is reasonable. The fact that commits 8-11 exist (fixing 21 access bugs across 3 passes) honestly demonstrates the value of the entire exercise — these were all latent issues that structs surfaced.
