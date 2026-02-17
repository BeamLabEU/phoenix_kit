# Languages Module

The PhoenixKit Languages module provides multi-language support with a two-tier locale system (base codes for URLs, full dialects for translations). It manages both frontend user-facing languages and backend admin panel languages.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/settings/languages`
- **Enable Module**: `PhoenixKit.Modules.Languages.enable_system/0`
- **Check Status**: `PhoenixKit.Modules.Languages.enabled?/0`
- **Get Primary Language**: `PhoenixKit.Modules.Languages.get_default_language/0`
- **Get All Languages**: `PhoenixKit.Modules.Languages.get_display_languages/0`

## Storage Details

**Important**: Language configuration is stored in the `phoenix_kit_settings` table using the `value_json` column (not `value`).

| Setting Key | Column | Description |
|-------------|--------|-------------|
| `languages_enabled` | `value` | Boolean flag (`true`/`false`) |
| `languages_config` | `value_json` | JSON with `{"languages": [...]}` structure |
| `admin_languages` | `value` | JSON array of admin language codes |

### Querying Configuration

**From within the application** (recommended):

```elixir
# Get all configured languages
PhoenixKit.Modules.Languages.get_display_languages()

# Get the default/primary language
PhoenixKit.Modules.Languages.get_default_language()
# => %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true}

# Get the primary language code for Publishing module
PhoenixKit.Settings.get_content_language()
# => "en"

# Check if module is enabled
PhoenixKit.Modules.Languages.enabled?()
# => true
```

**Direct database query** (for debugging):

```sql
-- Check if enabled
SELECT value FROM phoenix_kit_settings WHERE key = 'languages_enabled';

-- Get full configuration (note: value_json, not value)
SELECT value_json FROM phoenix_kit_settings WHERE key = 'languages_config';

-- Get admin languages
SELECT value FROM phoenix_kit_settings WHERE key = 'admin_languages';
```

## Language Configuration Structure

Each language in `languages_config` has this structure:

```json
{
  "languages": [
    {
      "code": "en",
      "name": "English",
      "is_default": true,
      "is_enabled": true,
      "position": 0
    },
    {
      "code": "sq",
      "name": "Albanian",
      "is_default": false,
      "is_enabled": true,
      "position": 1
    }
  ]
}
```

## Two-Tier Locale System

The module uses two types of language codes:

| Type | Example | Used For |
|------|---------|----------|
| **Base codes** | `en`, `es`, `fr` | URLs (SEO-friendly) |
| **Full dialect codes** | `en-US`, `es-ES`, `fr-FR` | Gettext translations |

### Default Dialect Mapping

| Base | Default Dialect |
|------|-----------------|
| `en` | `en-US` |
| `es` | `es-ES` |
| `pt` | `pt-BR` |
| `zh` | `zh-CN` |
| `de` | `de-DE` |
| `fr` | `fr-FR` |

### DialectMapper Functions

```elixir
alias PhoenixKit.Modules.Languages.DialectMapper

DialectMapper.extract_base("en-US")           # => "en"
DialectMapper.base_to_dialect("en")           # => "en-US"
DialectMapper.resolve_dialect("en", user)     # Considers user.custom_fields["preferred_locale"]
```

## Frontend vs Backend Languages

| Setting | Purpose | Storage Key |
|---------|---------|-------------|
| **Frontend Languages** | User-facing language switcher | `languages_config` |
| **Backend Languages** | Admin panel language switcher | `admin_languages` |

These are **independent** - admins can use different languages than site visitors.

### Admin Languages

```elixir
# Get admin languages (returns list of base codes)
PhoenixKit.Settings.get_setting_cached("admin_languages", nil)
# => "[\"en-US\",\"ja\"]"
```

## Key API Functions

### System Management

```elixir
Languages.enable_system()    # Enable with default English
Languages.disable_system()   # Disable (preserves config)
Languages.enabled?()         # Check if enabled
```

### Query Functions

```elixir
Languages.get_languages()              # All configured languages
Languages.get_enabled_languages()      # Only enabled, sorted by position
Languages.get_default_language()       # Language with is_default: true
Languages.get_display_languages()      # Configured (if enabled) or top 12 defaults
Languages.get_language("es-ES")        # Specific language by code
Languages.enabled_locale_codes()       # For URL routing
```

### Management Functions

```elixir
Languages.add_language("es-ES")           # Add from predefined list
Languages.remove_language("es-ES")        # Remove (not if default or last)
Languages.set_default_language("es-ES")   # Change default
Languages.enable_language("fr-FR")        # Reactivate disabled
Languages.disable_language("de-DE")       # Hide from frontend
Languages.move_language_up("es-ES")       # Reorder
Languages.move_language_down("es-ES")     # Reorder
```

## Language Switcher Components

```heex
<%!-- Dropdown (recommended) --%>
<.language_switcher_dropdown current_locale={@current_locale} />

<%!-- Button group --%>
<.language_switcher_buttons current_locale={@current_locale} />

<%!-- Inline text --%>
<.language_switcher_inline current_locale={@current_locale} />
```

## Integration with Entities Module

The Entities module uses Languages for **multi-language content storage**. When 2+ languages are enabled, all entity data automatically supports multilang.

### How It Works

1. `PhoenixKit.Modules.Entities.Multilang.enabled?/0` checks if Languages has 2+ enabled languages
2. `Multilang.primary_language/0` reads `Languages.get_default_language()`
3. `Multilang.enabled_languages/0` reads `Languages.get_enabled_language_codes()`
4. Entity data JSONB is structured by language code (e.g., `"en-US"`, `"es-ES"`)

### Programmatic Translation Setup

```elixir
# 1. Enable languages
PhoenixKit.Modules.Languages.enable_system()
PhoenixKit.Modules.Languages.add_language("es-ES")
PhoenixKit.Modules.Languages.add_language("fr-FR")

# 2. Multilang is now active — use the convenience API
alias PhoenixKit.Modules.Entities.EntityData

record = EntityData.get(uuid)
EntityData.set_translation(record, "es-ES", %{"name" => "Producto"})
EntityData.set_title_translation(record, "es-ES", "Mi Producto")
```

### Primary Language Changes

When `Languages.set_default_language/1` is called, existing entity data records lazily re-key on next edit. The new primary is promoted to have all fields. See `lib/modules/entities/OVERVIEW.md` for full details.

### Key Dependency

The Entities Multilang module gracefully degrades when Languages is unavailable — it uses `Code.ensure_loaded?/1` checks and falls back to `"en-US"` as the default language.

---

## Integration with Publishing Module

The Publishing module uses Languages for:

1. **Primary Language**: `PhoenixKit.Settings.get_content_language()` returns the default language code
2. **Multi-language URLs**: `/en/blog/post` vs `/es/blog/post`
3. **Per-post primary_language**: Stored in `.phk` file metadata
4. **Language detection**: Determines if URL segment is language or blog slug

## Troubleshooting

### Languages show empty in database but work in app

The configuration is stored in `value_json` column, not `value`. Query with:

```sql
SELECT value_json FROM phoenix_kit_settings WHERE key = 'languages_config';
```

Or use the application API:

```elixir
PhoenixKit.Modules.Languages.get_display_languages()
```

### Module enabled but no languages showing

Check if `languages_config` has the `{"languages": [...]}` structure:

```elixir
PhoenixKit.Settings.get_json_setting("languages_config", nil)
```

### Primary language returns nil

The primary language comes from `Languages.get_default_language()`. Ensure at least one language has `"is_default": true` in the config.
