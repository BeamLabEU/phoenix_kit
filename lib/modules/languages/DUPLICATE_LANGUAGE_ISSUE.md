# Duplicate Language Issue: Generic vs Regional Codes

## Problem

The language switcher shows duplicate entries for the same language because both a generic code and its regional variants are enabled simultaneously.

**Current state in database** (`languages_config`):
- `"en"` (English) - `is_enabled: true`
- `"en-US"` (English United States) - `is_enabled: true`

This causes the language switcher to show:
- "English" (from code "en")
- "English (United States)" (from code "en-US")

## Why This Happens

1. `BeamLabCountries.Languages.all_locales()` includes both generic codes ("en") and regional variants ("en-US", "en-GB")
2. The Languages module doesn't prevent enabling both a base code and its variants
3. The `DialectMapper.extract_base()` function extracts "en" from both codes, but they're displayed separately in the UI

## Impact

- Confusing UX with duplicate language options
- Both would map to `/en/...` URLs (same base code)
- The dialect mapper already converts "en" → "en-US" for translations anyway

## Technical Details

**Relevant files:**
- `lib/modules/languages/languages.ex` - `add_language/1` and `enable_language/1` functions
- `lib/modules/languages/dialect_mapper.ex` - `extract_base/1` function
- `lib/phoenix_kit_web/components/core/language_switcher.ex` - displays languages

**Database location:**
```sql
SELECT value_json FROM phoenix_kit_settings WHERE key = 'languages_config';
```

## Proposed Solutions

### Option 1: Add Validation (Recommended)

Prevent enabling both a generic code and its regional variants in `languages.ex`:

```elixir
defp find_base_code_conflict(code, current_languages) do
  alias PhoenixKit.Modules.Languages.DialectMapper
  new_base = DialectMapper.extract_base(code)

  current_languages
  |> Enum.filter(& &1["is_enabled"])
  |> Enum.find_value(fn lang ->
    existing_code = lang["code"]
    existing_base = DialectMapper.extract_base(existing_code)

    if existing_base == new_base and existing_code != code do
      existing_code
    else
      nil
    end
  end)
end
```

Then check this in `add_language/1` and `enable_language/1`.

### Option 2: Fix Existing Data Only

Just disable the generic "en" in the database (keep "en-US"):

```sql
UPDATE phoenix_kit_settings
SET value_json = jsonb_set(
  value_json,
  '{languages}',
  (SELECT jsonb_agg(
    CASE
      WHEN lang->>'code' = 'en'
      THEN jsonb_set(lang, '{is_enabled}', 'false')
      ELSE lang
    END
  ) FROM jsonb_array_elements(value_json->'languages') AS lang)
)
WHERE key = 'languages_config';
```

### Option 3: UI Warning

Show a warning in the Languages settings UI when conflicting codes are detected, letting the admin choose which to keep.

## Quick Fix (Manual)

To immediately fix the current database state, disable generic "en" via IEx:

```elixir
PhoenixKit.Modules.Languages.disable_language("en")
```

Or keep "en" and disable regional variants:

```elixir
PhoenixKit.Modules.Languages.disable_language("en-US")
PhoenixKit.Modules.Languages.disable_language("en-GB")
# etc.
```

## Notes

- For a CMS, having both doesn't make practical sense
- Generic codes like "en" are valid ISO 639-1 codes, but typically you'd use either generic OR regional variants, not both
- The dialect mapper's fallback behavior already handles the mapping, so having both enabled is redundant
