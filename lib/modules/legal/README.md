# PhoenixKit Legal Module

**Version:** 1.0
**Status:** Production Ready

## Overview

Comprehensive legal compliance module for PhoenixKit with GDPR/CCPA compliant legal page generation and cookie consent management.

---

## Features

### Phase 1: Legal Pages Generation
- Multi-framework compliance (GDPR, CCPA, LGPD, PIPEDA, etc.)
- Company information management
- DPO (Data Protection Officer) contact
- Automated legal page generation via Blogging module
- Page publishing workflow

### Phase 2: Cookie Consent Widget
- Floating consent icon with customizable position
- Full preferences modal with category toggles
- Google Consent Mode v2 integration
- Script blocking by consent category
- Cross-tab synchronization
- Auto-inject via JavaScript (no layout changes required)

---

## Architecture

### File Structure

```
lib/modules/legal/
├── legal.ex                    # Main context module
├── schemas/
│   └── consent_log.ex          # Consent logging schema (optional)
├── services/
│   └── template_generator.ex   # Legal page template generation
├── web/
│   └── settings.ex             # LiveView settings page
└── README.md                   # This file

lib/phoenix_kit_web/components/core/
└── cookie_consent.ex           # Cookie consent Phoenix component

priv/static/assets/
└── phoenix_kit_consent.js      # Client-side consent logic
```

### Database Tables

#### phoenix_kit_consent_logs (Optional - Phase 2)

Stores consent records for audit trail (if enabled).

```sql
- id (bigserial, PK)
- uuid (uuid, unique)
- user_id (bigint, FK, nullable)
- session_id (varchar)
- consent_given (boolean)
- consent_categories (jsonb)
- ip_address (varchar)
- user_agent (text)
- policy_version (varchar)
- inserted_at (timestamp)
- updated_at (timestamp)
```

---

## Compliance Frameworks

| Framework | Region | Consent Model | Icon |
|-----------|--------|---------------|------|
| GDPR | EU/EEA | Opt-in | Show |
| UK GDPR | UK | Opt-in | Show |
| CCPA/CPRA | California | Opt-out | Hide |
| US States | US | Opt-out | Hide |
| LGPD | Brazil | Opt-in | Show |
| PIPEDA | Canada | Opt-in | Show |
| Generic | Other | Notice | Hide |

**Opt-in frameworks** require explicit consent before setting cookies.
**Opt-out frameworks** allow cookies by default with "Do Not Sell" option.

---

## Quick Start

### Enable the Module

```elixir
# Blogging module must be enabled first
PhoenixKit.Modules.Blogging.enable_system()

# Then enable Legal module
PhoenixKit.Modules.Legal.enable_system()
```

### Configure Frameworks

```elixir
# Set compliance frameworks
PhoenixKit.Modules.Legal.set_frameworks(["gdpr", "ccpa"])

# Update company information
PhoenixKit.Modules.Legal.update_company_info(%{
  "name" => "ACME Corp",
  "address_line1" => "123 Main St",
  "city" => "New York",
  "country" => "US",
  "website_url" => "https://acme.com"
})
```

### Generate Legal Pages

```elixir
# Generate all required pages
PhoenixKit.Modules.Legal.generate_all_pages()

# Or generate individual page
PhoenixKit.Modules.Legal.generate_page("privacy-policy")

# Publish a page
PhoenixKit.Modules.Legal.publish_page("privacy-policy")
```

### Enable Cookie Consent Widget

```elixir
# Enable widget
PhoenixKit.Modules.Legal.enable_consent_widget()

# Configure position (bottom-right, bottom-left, top-right, top-left)
PhoenixKit.Modules.Legal.update_icon_position("bottom-right")

# Enable Google Consent Mode v2
PhoenixKit.Modules.Legal.enable_google_consent_mode()
```

---

## API Reference

### Module Status

```elixir
Legal.enabled?()                    # Check if module is enabled
Legal.enable_system()               # Enable module
Legal.disable_system()              # Disable module
```

### Configuration

```elixir
Legal.get_config()                  # Get full configuration
Legal.available_frameworks()        # List all frameworks
Legal.get_selected_frameworks()     # Get enabled frameworks
Legal.set_frameworks(["gdpr"])      # Set active frameworks
```

### Company Information

```elixir
Legal.get_company_info()            # Get company details
Legal.update_company_info(params)   # Update company details
Legal.get_dpo_contact()             # Get DPO contact
Legal.update_dpo_contact(params)    # Update DPO contact
```

### Legal Pages

```elixir
Legal.available_page_types()        # List page types
Legal.generate_page("privacy-policy", scope: scope)
Legal.generate_all_pages(scope: scope)
Legal.publish_page("privacy-policy", scope: scope)
Legal.list_generated_pages()
Legal.get_required_pages_for_frameworks(["gdpr"])
Legal.get_all_pages_for_frameworks(["gdpr"])
Legal.get_unpublished_required_pages()
Legal.all_required_pages_published?()
```

### Cookie Consent Widget

```elixir
Legal.consent_widget_enabled?()     # Check if widget enabled
Legal.enable_consent_widget()       # Enable widget
Legal.disable_consent_widget()      # Disable widget
Legal.should_show_consent_icon?()   # Check if icon should show
Legal.has_opt_in_framework?()       # Check for opt-in frameworks

# Position
Legal.get_icon_position()           # Get icon position
Legal.update_icon_position("bottom-right")

# Consent Mode
Legal.get_consent_mode()            # "strict" or "permissive"
Legal.update_consent_mode("strict")

# Hide for authenticated users
Legal.hide_for_authenticated?()
Legal.update_hide_for_authenticated(true)

# Google Consent Mode
Legal.google_consent_mode_enabled?()
Legal.enable_google_consent_mode()
Legal.disable_google_consent_mode()

# Policy Version
Legal.get_policy_version()
Legal.update_policy_version("2.0")
Legal.get_auto_policy_version()     # Auto-calculated from page updates

# Full widget config (for component)
Legal.get_consent_widget_config()
```

---

## Cookie Consent Widget

### How It Works

1. **Auto-inject**: JavaScript automatically creates widget if not in DOM
2. **API Endpoint**: `/phoenix_kit/api/consent-config` returns configuration
3. **Storage**: Preferences saved to `localStorage` (key: `pk_consent`)
4. **Cross-tab Sync**: Changes propagate to all open tabs

### Parent App Integration

Add the following to your root layout (`root.html.heex`):

```heex
<%!-- In your <head> section --%>
<%!-- Meta tag for URL prefix detection --%>
<meta name="phoenix-kit-prefix" content={PhoenixKit.Utils.Routes.url_prefix()} />

<%!-- Cookie Consent Script (auto-initializes on DOMContentLoaded) --%>
<script defer src={"#{PhoenixKit.Utils.Routes.url_prefix()}/assets/phoenix_kit_consent.js"}>
</script>
```

The script will automatically:
1. Fetch configuration from `/phoenix_kit/api/consent-config`
2. Create and inject the widget if consent is needed
3. Handle consent storage and cross-tab synchronization

### JavaScript API

```javascript
// Check consent
PhoenixKitConsent.getConsent()
// => { necessary: true, analytics: true, marketing: false, preferences: true }

// Open preferences modal
PhoenixKitConsent.openPreferences()

// Accept all cookies
PhoenixKitConsent.acceptAll()

// Reject non-essential
PhoenixKitConsent.rejectAll()

// Save current preferences
PhoenixKitConsent.savePreferences()

// Revoke consent
PhoenixKitConsent.revokeConsent()
```

### Script Blocking

Block scripts until consent is granted:

```html
<script data-consent-category="analytics" type="text/plain">
  // Google Analytics - blocked until analytics consent
  gtag('config', 'GA-XXXXX');
</script>

<script data-consent-category="marketing" type="text/plain">
  // Facebook Pixel - blocked until marketing consent
  fbq('init', 'XXXXX');
</script>
```

### Google Consent Mode v2

When enabled, the widget manages Google Consent Mode:

```javascript
// Default state (before consent)
gtag('consent', 'default', {
  'ad_storage': 'denied',
  'analytics_storage': 'denied',
  'ad_user_data': 'denied',
  'ad_personalization': 'denied'
});

// After user accepts analytics
gtag('consent', 'update', {
  'analytics_storage': 'granted'
});
```

---

## Settings Interface

Access at: `/{prefix}/admin/settings/legal`

### Sections

1. **Module Enable/Disable** - Toggle legal module
2. **Compliance Frameworks** - Select active frameworks
3. **Company Information** - Business details for legal pages
4. **DPO Contact** - Data Protection Officer information
5. **Cookie Consent Widget** - Widget configuration
6. **Legal Pages** - Generate and manage pages

---

## Consent Categories

| Category | Description | Can Disable |
|----------|-------------|-------------|
| Necessary | Essential cookies for site function | No |
| Analytics | Usage tracking and analytics | Yes |
| Marketing | Advertising and retargeting | Yes |
| Preferences | User preferences and settings | Yes |

---

## Dependencies

- **Blogging Module**: Required for page storage
- **PhoenixKit.UUID**: For UUIDv7 generation
- **Settings Module**: For configuration storage

---

## Migration

Legal module uses migration **V36** for consent_logs table:

```elixir
# Run migrations
mix phoenix_kit.update
```

---

## Settings Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `legal_enabled` | boolean | false | Module enabled |
| `legal_frameworks` | json | [] | Selected frameworks |
| `legal_company_info` | json | {} | Company details |
| `legal_dpo_contact` | json | {} | DPO contact |
| `legal_consent_widget_enabled` | boolean | false | Widget enabled |
| `legal_consent_icon_position` | string | "bottom-right" | Icon position |
| `legal_consent_mode` | string | "strict" | Consent mode |
| `legal_hide_for_authenticated` | boolean | false | Hide for logged-in users |
| `legal_google_consent_mode` | boolean | false | Google Consent Mode |
| `legal_policy_version` | string | "1.0" | Policy version |

---

## Examples

### Check Compliance Status

```elixir
# Get all configuration
config = Legal.get_config()
# => %{enabled: true, frameworks: ["gdpr"], company_info: %{...}, ...}

# Check if ready for production
Legal.all_required_pages_published?()
# => true

# Get unpublished pages
Legal.get_unpublished_required_pages()
# => ["cookie-policy"]
```

### Programmatic Page Generation

```elixir
# Generate privacy policy with custom scope
{:ok, post} = Legal.generate_page("privacy-policy", scope: current_scope)

# Publish immediately
{:ok, _} = Legal.publish_page("privacy-policy", scope: current_scope)
```

### Widget Configuration

```elixir
# Full widget config for frontend
Legal.get_consent_widget_config()
# => %{
#   enabled: true,
#   frameworks: ["gdpr"],
#   consent_mode: "strict",
#   icon_position: "bottom-right",
#   show_icon: true,
#   policy_version: "1.0",
#   cookie_policy_url: "/phoenix_kit/legal/cookie-policy",
#   privacy_policy_url: "/phoenix_kit/legal/privacy-policy",
#   google_consent_mode: true,
#   hide_for_authenticated: false
# }
```

---

## Troubleshooting

### Widget not showing

1. Check module is enabled: `Legal.enabled?()`
2. Check widget is enabled: `Legal.consent_widget_enabled?()`
3. Check opt-in framework selected: `Legal.has_opt_in_framework?()`
4. Verify meta tag in layout: `<meta name="phoenix-kit-prefix" ...>`
5. Verify consent script is loaded: `<script src=".../assets/phoenix_kit_consent.js">`
6. Check browser console for errors
7. Verify API endpoint works: `curl http://localhost:4000/phoenix_kit/api/consent-config`

### Pages not generating

1. Verify Blogging module enabled
2. Check "legal" blog exists
3. Review company info is filled
4. Check scope permissions

### Google Consent Mode not working

1. Verify `Legal.google_consent_mode_enabled?()`
2. Check `dataLayer` exists before widget loads
3. Verify `gtag` function is available

---

## Security Considerations

- Consent data stored client-side only (localStorage)
- No PII stored in consent preferences
- Optional server-side logging via consent_logs table
- IP addresses stored only if consent logging enabled
- HTTPS required for secure cookie handling
