# Struct vs Map Audit Report

**Date:** 2026-02-16
**Last Recheck:** 2026-02-17 (post v1.7.41 pull — all items unchanged, no new patterns found)
**Severity:** Medium (data contract clarity, developer experience)
**Recommendation:** Convert high-traffic cross-module maps to structs; leave infrastructure/boundary maps as-is

---

## Why This Audit Exists

The Language module refactor (merged 2026-02-15) replaced a heavily-used `%{code, name, native_name, flag}` plain map with a proper `%Language{}` struct. That single change touched 15+ files because every consumer had to be updated. The question: **how many more plain maps are acting as de-facto structs across the codebase?**

Structs matter because:
- **Compile-time key checks** — `%Foo{bar: 1}` fails at compile time if `bar` isn't a field; `%{bar: 1}` silently passes
- **Pattern matching safety** — `%Foo{}` in function heads rejects wrong-shaped data; `%{}` matches anything
- **Documentation** — `defstruct` is self-documenting; a map buried in a function body requires reading the code
- **Dialyzer coverage** — `@type t :: %__MODULE__{}` gives Dialyzer something to check

---

## What's Already Done

These data contracts already use proper structs:

| Struct | File | Fields | Notes |
|--------|------|--------|-------|
| `Dashboard.Tab` | `lib/phoenix_kit/dashboard/tab.ex` | 27 | Full validation via `new!/1`, path matching, visibility functions |
| `Dashboard.Badge` | `lib/phoenix_kit/dashboard/badge.ex` | 16 | PubSub subscriptions, compound segments, pulse animations |
| `Dashboard.ContextSelector` | `lib/phoenix_kit/dashboard/context_selector.ex` | 16 | Dependencies, position control, session keys |
| `Sitemap.UrlEntry` | `lib/modules/sitemap/url_entry.ex` | 9 | XML serialization, hreflang alternates |
| `Shop.OptionState` | `lib/modules/shop/web/option_state.ex` | 5 | Interactive form state with modifiers |
| `Users.Auth.Scope` | `lib/phoenix_kit/users/auth/scope.ex` | 4 | Immutable auth context, permission MapSet |
| `Languages.Language` | `lib/modules/languages/language.ex` | 4 | Recently refactored from plain map |
| `Utils.SessionFingerprint` | `lib/phoenix_kit/utils/session_fingerprint.ex` | 2 | Converted 2026-02-17 from Tier 2 audit |
| `Billing.IbanData` | `lib/modules/billing/utils/iban_data.ex` | 2 | Converted 2026-02-17 from Tier 2 audit |
| `Sitemap.SitemapFile` | `lib/modules/sitemap/sitemap_file.ex` | 3 | Converted 2026-02-17 from Tier 2 audit |

All Ecto schemas (`User`, `Role`, `Cart`, `Post`, `Comment`, etc.) are also proper structs by virtue of `use Ecto.Schema`.

---

## Tier 1: Cross-Module Data Contracts (High Priority)

These maps cross module boundaries — they're constructed in one module and consumed (pattern-matched, accessed) in another. Converting them to structs catches shape mismatches at compile time.

### 1.1 Billing Provider Behaviour Types

**File:** `lib/modules/billing/providers/provider.ex`

The `Provider` behaviour defines 6 `@type` specs as plain maps. Every provider (Stripe, PayPal, Razorpay) returns these, and every consumer pattern-matches on them.

| Type | Lines | Fields | Returned By | Consumed By |
|------|-------|--------|-------------|-------------|
| `checkout_session` | 48–54 | `id`, `url`, `provider`, `expires_at`, `metadata` | 3 providers | `Providers`, templates |
| `setup_session` | 56–61 | `id`, `url`, `provider`, `metadata` | 2 providers | `Providers`, templates |
| `webhook_event` | 63–69 | `type`, `event_id`, `data`, `provider`, `raw_payload` | 3 providers | `WebhookProcessor` (line 44, 72–138) |
| `payment_method` | 71–82 | `id`, `provider`, `provider_payment_method_id`, `provider_customer_id`, `type`, `brand`, `last4`, `exp_month`, `exp_year`, `metadata` | 3 providers | `Providers.charge_payment_method/3` (line 240) |
| `charge_result` | 84–91 | `id`, `provider_transaction_id`, `amount`, `currency`, `status`, `metadata` | 3 providers | `WebhookProcessor`, billing context |
| `refund_result` | 93–99 | `id`, `provider_refund_id`, `amount`, `status`, `metadata` | 3 providers | billing context |

**Impact:** ~18 construction sites across 3 provider implementations + 4 consumer files.

**Recommendation:** Create structs in `lib/modules/billing/providers/types/` (e.g., `checkout_session.ex`, `webhook_event.ex`). Update the `@callback` specs to return `CheckoutSession.t()` instead of `checkout_session()`. Each provider's return maps become `%CheckoutSession{...}`.

### 1.2 Billing ProviderInfo

**File:** `lib/modules/billing/providers/providers.ex`, lines 325–352

```elixir
%{name: "Stripe", icon: "stripe", color: "#635BFF", description: "Accept cards, wallets, and more"}
```

4 fields (`name`, `icon`, `color`, `description`), 4 variations (Stripe, PayPal, Razorpay, Unknown). Consumed in LiveView templates for provider selection UI.

**Recommendation:** `%ProviderInfo{}` struct with 4 required fields. Small but crosses into template rendering.

### 1.3 Entities FieldType

**File:** `lib/modules/entities/field_types.ex`, lines 50–189

```elixir
%{name: "text", label: "Text", description: "...", category: :basic, icon: "hero-pencil",
  requires_options: false, default_props: %{max_length: 255}}
```

7 fields, 12 field type definitions (text, textarea, email, url, rich_text, number, boolean, date, select, radio, checkbox, file).

**Consumed by:**
- `Entities.Web.EntityForm` — field picker dropdown, type rendering (lines 70, 497, 1275–1292)
- `for_picker/0` — transforms to tuple format for UI
- `validate_field/1` — validates field map structure
- Entity form templates — accesses `field["type"]`, `field["label"]`, `field["icon"]`

**~41 occurrences** across entity form, templates, and validation pipeline.

**Recommendation:** `%FieldType{}` struct with `@enforce_keys [:name, :label, :category]`. The `default_props` field stays as a plain map (type-specific, dynamic shape).

### 1.4 Emails EmailLogData

**File:** `lib/modules/emails/interceptor.ex`, lines 374–391

```elixir
%{message_id: ..., to: ..., from: ..., subject: ..., headers: ..., body_preview: ...,
  body_full: ..., attachments_count: ..., size_bytes: ..., template_name: ...,
  campaign_id: ..., user_id: ..., user_uuid: ..., provider: ...,
  configuration_set: ..., message_tags: ...}
```

16 fields. Constructed in `extract_email_data/2`, passed to `Emails.create_log/1` (line 161). Core of the email tracking pipeline.

**Recommendation:** `%EmailLogData{}` struct. This is one of the largest untyped maps in the codebase and sits at the center of the email tracking pipeline.

### 1.5 Sync TableSchema + ColumnInfo

**File:** `lib/modules/sync/schema_inspector.ex`, lines 326–368

**TableSchema** (4 fields):
```elixir
%{table: "users", schema: "public", columns: [...], primary_key: ["id"]}
```

**ColumnInfo** (up to 8 fields):
```elixir
%{name: "id", type: "bigint", nullable: false, primary_key: true,
  default: nil, max_length: nil, precision: nil, scale: nil}
```

Constructed in `fetch_table_schema/2`. Consumed by:
- `DataImporter.ex` (lines 66–67) — extracts columns and primary keys
- `DataExporter.ex` — determines export columns
- `sync_live.ex` — displays schema in UI
- `client.ex` — received from remote peers over wire protocol

**~50 occurrences** across sync module.

**Recommendation:** Two structs: `%TableSchema{}` and `%ColumnInfo{}`. The sync module passes these across the wire protocol, so typed structs also serve as documentation for the sync API.

### 1.6 AI AIModel

**File:** `lib/modules/ai/openrouter_client.ex`, lines 191–267 (embedding models), 444–455 (normalization)

```elixir
%{"id" => "anthropic/claude-3-opus", "name" => "Claude 3 Opus",
  "description" => "...", "context_length" => 200000,
  "max_completion_tokens" => 4096, "supported_parameters" => ["temperature"],
  "pricing" => %{"prompt" => 0.015, "completion" => 0.075},
  "architecture" => %{"modality" => "text"}, "top_provider" => %{...}}
```

9 top-level fields, **string-keyed** (comes from JSON API). Consumed by:
- `AI.Web.EndpointForm` (lines 92–93) — `model["max_completion_tokens"]`, `model["context_length"]`
- `model_option/1` (lines 351–368) — formats for dropdown
- `model_supports_parameter?/2` (lines 515–518) — checks supported params

**~37 occurrences** across AI module.

**Note:** String keys come from the OpenRouter API JSON response. The struct should use atom keys internally, with `normalize_models/2` converting at the boundary.

**Recommendation:** `%AIModel{}` struct with atom keys. `normalize_models/2` becomes the conversion boundary from string-keyed JSON to typed struct.

### 1.7 Legal LegalFramework + PageType

**File:** `lib/modules/legal/legal.ex`, lines 42–106 (frameworks), 109–152 (page types)

**LegalFramework** (7 fields):
```elixir
%{id: "gdpr", name: "GDPR (European Union)", description: "...",
  regions: ["EU", "EEA"], consent_model: :opt_in,
  required_pages: ["privacy-policy", "cookie-policy"],
  optional_pages: ["data-retention-policy"]}
```

7 frameworks defined (GDPR, UK GDPR, CCPA, US States, LGPD, PIPEDA, Generic).

**PageType** (4 fields):
```elixir
%{slug: "privacy-policy", title: "Privacy Policy",
  template: "privacy_policy.eex", description: "..."}
```

7 page types defined. Both consumed in `legal.web.settings.ex` for UI rendering and template generation.

**~13 occurrences** total.

**Recommendation:** `%LegalFramework{}` and `%PageType{}` structs. Low occurrence count but clean data contracts that benefit from compile-time checks.

### 1.8 Dashboard Group

**Files:** `lib/phoenix_kit/dashboard/registry.ex` (lines 826–830), `lib/phoenix_kit/dashboard/admin_tabs.ex` (lines 70–74)

```elixir
%{id: :admin_main, label: nil, priority: 100}
```

4–5 fields (`id`, `label`, `priority`, `icon`, `collapsible`). Defined in defaults, loaded from config, stored in ETS via `register_groups/1`, retrieved via `get_groups/0`.

**~12 occurrences** across registry and admin tabs.

**Recommendation:** `%Dashboard.Group{}` struct alongside the existing `Tab`, `Badge`, and `ContextSelector` structs. Natural extension of the dashboard type system.

---

## Tier 2: Module-Internal Typed Data (Medium Priority)

These maps stay within a single module but would benefit from struct validation for maintainability.

### 2.1 SessionFingerprint — DONE (2026-02-17)

**File:** `lib/phoenix_kit/utils/session_fingerprint.ex`

Converted to `%SessionFingerprint{}` struct with `@enforce_keys [:ip_address, :user_agent_hash]` and `@type t`. `create_fingerprint/1` now returns struct. Consumer in `user_token.ex` uses `[:key]` access which works on structs.

### 2.2 Billing IbanSpec — DONE (2026-02-17)

**File:** `lib/modules/billing/utils/iban_data.ex`

Added `%IbanData{}` struct with `@enforce_keys [:length, :sepa]` and `@type t`. Internal `@iban_specs` module attribute stays as plain maps (compile-time limitation). Added `get_spec/1` returning typed struct. `all_specs/0` now returns structs.

### 2.3 Billing Timeline Events

**File:** `lib/modules/billing/web/invoice_detail/helpers.ex`, lines 72–168

```elixir
%{type: :created, datetime: invoice.inserted_at, data: nil}
%{type: :payment, datetime: txn.inserted_at, data: txn}
%{type: :refund,  datetime: txn.inserted_at, data: txn}
```

3 fields (`type`, `datetime`, `data`), 6 event variations. Used only in invoice detail timeline rendering.

**Recommendation:** `%TimelineEvent{}` — small scope but prevents typos in the `:type` atom.

### 2.4 Sitemap ModuleInfo — DONE (2026-02-17)

**File:** `lib/modules/sitemap/sitemap_file.ex` (new), `lib/modules/sitemap/generator.ex`

Created `%SitemapFile{}` struct with `@enforce_keys [:filename, :url_count]` and `@type t`. All 3 construction sites in `generator.ex` updated. `@spec` annotations on `generate_module/2` and `generate_index/4` updated to use `SitemapFile.t()`.

### 2.5 Filter/Pagination Params

**Pattern across ~48 `list_*` functions** using keyword lists:

```elixir
def list_posts(opts \\ []) do
  user_id = Keyword.get(opts, :user_id)
  status = Keyword.get(opts, :status)
  page = Keyword.get(opts, :page, 1)
  per_page = Keyword.get(opts, :per_page, 20)
  ...
end
```

Representative files:
- `lib/modules/posts/posts.ex` — `list_posts/1`, `list_user_posts/2`
- `lib/modules/comments/comments.ex` — `list_all_comments/1`, `list_comments/3`
- `lib/modules/entities/entities.ex` — `list_entity_data/2`
- `lib/modules/tickets/tickets.ex` — `list_tickets/1`

**Recommendation:** This is a judgment call. Keyword lists are idiomatic Elixir for optional params. A shared `%ListParams{page, per_page, search, sort_by, sort_order}` struct could work, but risks over-abstraction. **Defer** — address only if filter bugs become a pattern.

---

## Tier 3: Acceptable as Maps (No Action Needed)

These use plain maps appropriately at system boundaries or for genuinely dynamic data.

| Pattern | Location | Why It's Fine |
|---------|----------|---------------|
| **PubSub messages** | `lib/phoenix_kit/pubsub_helper.ex`, dashboard registry | Use tuples (`{:tab_updated, tab}`), not maps. Pattern matching in `handle_info` provides type safety. |
| **JSON API responses** | `lib/modules/ai/openrouter_client.ex` (raw responses) | String-keyed maps from `Jason.decode!/1`. Converted at boundary (the struct should live _after_ normalization, not replace JSON parsing). |
| **Entity import/export** | `lib/modules/entities/mirror/importer.ex` (lines 74–99) | String-keyed maps from JSON file I/O. Immediately converted to Ecto changesets. The map is a transient deserialization artifact. |
| **Ecto `:map` fields** | `metadata` fields across 8+ schemas | Intentionally dynamic (`%{"source" => "mobile", "utm" => "summer"}`). Schema `:map` type is correct for extensible key-value data. |
| **Config summaries** | `Comments.get_config/0`, module status maps | Internal read-only aggregations. Never persisted, never cross module boundaries, consumed immediately for display. |
| **Webhook raw payloads** | `WebhookEvent.payload` field | Provider-specific JSON. Shape varies per provider and event type. Cannot be meaningfully typed. |

---

## File Reference

Complete table of every file with a Tier 1 or Tier 2 gap:

| File | Lines | Current Shape | Target Struct | Tier |
|------|-------|---------------|---------------|------|
| `lib/modules/billing/providers/provider.ex` | 48–54 | `checkout_session` map | `CheckoutSession` | 1 |
| `lib/modules/billing/providers/provider.ex` | 56–61 | `setup_session` map | `SetupSession` | 1 |
| `lib/modules/billing/providers/provider.ex` | 63–69 | `webhook_event` map | `WebhookEvent` (struct) | 1 |
| `lib/modules/billing/providers/provider.ex` | 71–82 | `payment_method` map | `PaymentMethod` (struct) | 1 |
| `lib/modules/billing/providers/provider.ex` | 84–91 | `charge_result` map | `ChargeResult` | 1 |
| `lib/modules/billing/providers/provider.ex` | 93–99 | `refund_result` map | `RefundResult` | 1 |
| `lib/modules/billing/providers/providers.ex` | 325–352 | `provider_info` map | `ProviderInfo` | 1 |
| `lib/modules/entities/field_types.ex` | 50–189 | `field_type` map | `FieldType` | 1 |
| `lib/modules/emails/interceptor.ex` | 374–391 | `email_log_data` map | `EmailLogData` | 1 |
| `lib/modules/sync/schema_inspector.ex` | 326–368 | `table_schema` map | `TableSchema` | 1 |
| `lib/modules/sync/schema_inspector.ex` | 345–357 | `column_info` map | `ColumnInfo` | 1 |
| `lib/modules/ai/openrouter_client.ex` | 444–455 | normalized model map | `AIModel` | 1 |
| `lib/modules/legal/legal.ex` | 42–106 | `framework` map | `LegalFramework` | 1 |
| `lib/modules/legal/legal.ex` | 109–152 | `page_type` map | `PageType` | 1 |
| `lib/phoenix_kit/dashboard/registry.ex` | 826–830 | `group` map | `Dashboard.Group` | 1 |
| `lib/phoenix_kit/dashboard/admin_tabs.ex` | 70–74 | `group` map | `Dashboard.Group` | 1 |
| `lib/phoenix_kit/utils/session_fingerprint.ex` | 54–59 | ~~fingerprint map~~ | `SessionFingerprint` | 2 ✅ |
| `lib/modules/billing/utils/iban_data.ex` | 22–98 | ~~`iban_spec` map~~ | `IbanData` | 2 ✅ |
| `lib/modules/billing/web/invoice_detail/helpers.ex` | 72–168 | timeline event map | `TimelineEvent` | 2 |
| `lib/modules/sitemap/generator.ex` | 226–242 | ~~module info map~~ | `SitemapFile` | 2 ✅ |

---

## Recommendation: Conversion Order

Suggested order based on cross-boundary impact, consumer count, and bug risk:

### Phase 1 — Billing Provider Types (Highest Impact)

**Why first:** 6 map types × 3 providers = 18 construction sites. The `WebhookProcessor` pattern-matches on these maps without any compile-time guarantee the keys exist. A typo in a provider implementation (`provider_trasaction_id`) silently produces `nil`.

**Files to create:**
- `lib/modules/billing/providers/types/checkout_session.ex`
- `lib/modules/billing/providers/types/setup_session.ex`
- `lib/modules/billing/providers/types/webhook_event_data.ex` (name avoids clash with `WebhookEvent` schema)
- `lib/modules/billing/providers/types/payment_method_info.ex` (avoids clash with `PaymentMethod` schema)
- `lib/modules/billing/providers/types/charge_result.ex`
- `lib/modules/billing/providers/types/refund_result.ex`
- `lib/modules/billing/providers/types/provider_info.ex`

**Files to update:** `provider.ex` (callbacks), `providers.ex`, `stripe.ex`, `paypal.ex`, `razorpay.ex`, `webhook_processor.ex`

### Phase 2 — Entities FieldType + Dashboard Group

**Why second:** `FieldType` has ~41 occurrences in the entity form system. `Dashboard.Group` naturally extends the existing `Tab`/`Badge`/`ContextSelector` struct family.

**Files to create:**
- `lib/modules/entities/field_type.ex`
- `lib/phoenix_kit/dashboard/group.ex`

### Phase 3 — Sync TableSchema/ColumnInfo + EmailLogData

**Why third:** Both cross module boundaries. `TableSchema` travels over the wire protocol. `EmailLogData` is the widest map (16 fields) in the codebase.

**Files to create:**
- `lib/modules/sync/table_schema.ex`
- `lib/modules/sync/column_info.ex`
- `lib/modules/emails/email_log_data.ex`

### Phase 4 — AI, Legal, and Tier 2

**Why last:** Lower occurrence counts. AI model maps use string keys (need conversion boundary). Legal maps are static config. Tier 2 items are module-internal.

**Files to create:**
- `lib/modules/ai/ai_model.ex`
- `lib/modules/legal/legal_framework.ex`
- `lib/modules/legal/page_type.ex`
- `lib/phoenix_kit/utils/session_fingerprint.ex` (add struct to existing file)
- `lib/modules/billing/utils/iban_spec.ex`
- `lib/modules/billing/web/invoice_detail/timeline_event.ex`
- `lib/modules/sitemap/sitemap_file.ex`

---

## Summary

| Tier | Items | New Structs | Done | Remaining |
|------|-------|-------------|------|-----------|
| **Tier 1** (cross-module) | 16 map shapes | 16 structs | 0 | 16 |
| **Tier 2** (module-internal) | 5 map shapes | 5 structs | 3 ✅ | 2 |
| **Tier 3** (acceptable) | 6 categories | 0 | — | 0 |
| **Total** | 27 audited | **21 new structs** | **3** | **18** |
