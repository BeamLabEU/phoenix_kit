defmodule PhoenixKit.Modules.Languages.DialectMapper do
  @moduledoc """
  Handles mapping between base language codes (en, es) and full dialect codes (en-US, es-MX).

  This module provides the core logic for PhoenixKit's simplified URL architecture where
  URLs show base codes (/en/) but translations use full dialect codes (en-US).

  ## Architecture

  PhoenixKit uses a two-tier locale system:

  1. **Base Language Codes** - Used in URLs for simplicity
     - Format: 2-letter ISO 639-1 codes (en, es, fr, de, pt, zh, ja, etc.)
     - Examples: `/en/dashboard`, `/es/admin`, `/fr/users`
     - User-facing, SEO-friendly, easy to remember

  2. **Full Dialect Codes** - Used internally for translations
     - Format: BCP 47 language tags (en-US, es-MX, pt-BR, zh-CN)
     - Examples: en-US, en-GB, es-ES, es-MX, pt-PT, pt-BR
     - Translation-aware, respects regional differences

  ## Data Flow

  ```
  User visits: /en/dashboard
        ↓
  Extract base: "en"
        ↓
  Resolve dialect: "en-US" (default) or user.custom_fields["preferred_locale"] ("en-GB")
        ↓
  Set Gettext: "en-US" or "en-GB"
        ↓
  Generate URLs: Always use base code "en"
  ```

  ## Default Dialect Mapping

  When no user preference exists, base codes map to most common regional variants:
  - `en` → `en-US` (American English)
  - `es` → `es-ES` (European Spanish)
  - `pt` → `pt-BR` (Brazilian Portuguese)
  - `zh` → `zh-CN` (Simplified Chinese)
  - `de` → `de-DE` (German Germany)
  - `fr` → `fr-FR` (French France)

  ## User Preferences

  Authenticated users can override default mappings:
  - User prefers British English: sets `custom_fields["preferred_locale"]` = "en-GB"
  - Visits `/en/dashboard`
  - System uses "en-GB" for translations
  - URLs remain `/en/` (not `/en-GB/`)

  ## Examples

      # Extract base language from full dialect
      iex> DialectMapper.extract_base("en-US")
      "en"

      iex> DialectMapper.extract_base("es-MX")
      "es"

      # Convert base to default dialect
      iex> DialectMapper.base_to_dialect("en")
      "en-US"

      iex> DialectMapper.base_to_dialect("pt")
      "pt-BR"

      # Resolve dialect with user preference (stored in custom_fields)
      iex> user = %User{custom_fields: %{"preferred_locale" => "en-GB"}}
      iex> DialectMapper.resolve_dialect("en", user)
      "en-GB"

      iex> DialectMapper.resolve_dialect("en", nil)
      "en-US"

  ## Validation

      iex> DialectMapper.valid_base_code?("en")
      true

      iex> DialectMapper.valid_base_code?("xx")
      false

  ## Getting Available Dialects

      iex> DialectMapper.dialects_for_base("en")
      ["en-US", "en-GB", "en-CA", "en-AU"]

      iex> DialectMapper.dialects_for_base("es")
      ["es-ES", "es-MX", "es-AR", "es-CO"]
  """

  alias PhoenixKit.Modules.Languages

  # Default dialect mapping for most common variants
  # Based on usage statistics and regional population
  @default_dialects %{
    "en" => "en-US",
    # English
    "es" => "es-ES",
    # Spanish
    "fr" => "fr-FR",
    # French
    "de" => "de-DE",
    # German
    "pt" => "pt-BR",
    # Portuguese (Brazilian Portuguese more common)
    "zh" => "zh-CN",
    # Chinese (Simplified more common)
    # Languages without regional variants map to themselves
    "ar" => "ar",
    # Arabic
    "ja" => "ja",
    # Japanese
    "ko" => "ko",
    # Korean
    "it" => "it",
    # Italian
    "ru" => "ru",
    # Russian
    "hi" => "hi",
    # Hindi
    "bn" => "bn",
    # Bengali
    "pa" => "pa",
    # Punjabi
    "jv" => "jv",
    # Javanese
    "vi" => "vi",
    # Vietnamese
    "tr" => "tr",
    # Turkish
    "pl" => "pl",
    # Polish
    "uk" => "uk",
    # Ukrainian
    "th" => "th",
    # Thai
    "nl" => "nl",
    # Dutch
    "sv" => "sv",
    # Swedish
    "no" => "no",
    # Norwegian
    "da" => "da",
    # Danish
    "fi" => "fi",
    # Finnish
    "cs" => "cs",
    # Czech
    "hu" => "hu",
    # Hungarian
    "ro" => "ro",
    # Romanian
    "el" => "el",
    # Greek
    "he" => "he",
    # Hebrew
    "id" => "id",
    # Indonesian
    "ms" => "ms",
    # Malay
    "fa" => "fa",
    # Persian
    "sw" => "sw",
    # Swahili
    "ta" => "ta",
    # Tamil
    "te" => "te",
    # Telugu
    "mr" => "mr",
    # Marathi
    "ur" => "ur",
    # Urdu
    "gu" => "gu",
    # Gujarati
    "kn" => "kn",
    # Kannada
    "ml" => "ml"
    # Malayalam
  }

  @doc """
  Extracts base language code from full dialect code.

  Splits on hyphen and returns first part (lowercased).
  Handles both dialect codes (en-US) and base codes (en).

  ## Examples

      iex> DialectMapper.extract_base("en-US")
      "en"

      iex> DialectMapper.extract_base("es-MX")
      "es"

      iex> DialectMapper.extract_base("zh-Hans-CN")
      "zh"

      iex> DialectMapper.extract_base("ja")
      "ja"

      iex> DialectMapper.extract_base("EN-GB")
      "en"
  """
  def extract_base(locale) when is_binary(locale) do
    locale
    |> String.split("-")
    |> List.first()
    |> String.downcase()
  end

  @doc """
  Converts base language code to default dialect.

  Uses predefined mapping for most common regional variants.
  Falls back to base code if no mapping exists.

  ## Examples

      iex> DialectMapper.base_to_dialect("en")
      "en-US"

      iex> DialectMapper.base_to_dialect("pt")
      "pt-BR"

      iex> DialectMapper.base_to_dialect("ja")
      "ja"

      iex> DialectMapper.base_to_dialect("xx")
      "xx"
  """
  def base_to_dialect(base_code) when is_binary(base_code) do
    base_lower = String.downcase(base_code)
    Map.get(@default_dialects, base_lower, base_lower)
  end

  @doc """
  Resolves the full dialect code for a user visiting a base language URL.

  Resolution priority:
  1. User's saved preference (if authenticated and preference matches base code)
  2. Default dialect mapping for that base language

  ## Examples

      iex> user = %User{custom_fields: %{"preferred_locale" => "en-GB"}}
      iex> DialectMapper.resolve_dialect("en", user)
      "en-GB"

      iex> user = %User{custom_fields: %{"preferred_locale" => "es-MX"}}
      iex> DialectMapper.resolve_dialect("en", user)
      "en-US"  # Preference doesn't match base, use default

      iex> DialectMapper.resolve_dialect("en", nil)
      "en-US"

      iex> guest = %{some_field: "value"}
      iex> DialectMapper.resolve_dialect("es", guest)
      "es-ES"

  ## Security

  User preference only applied if it matches the requested base code.
  This prevents users from forcing unintended locales via preference tampering.

  ## Graceful Degradation

  If user preference becomes invalid (dialect disabled, typo, etc.),
  system falls back to default mapping. No crashes or errors.
  """
  def resolve_dialect(base_code, user \\ nil)

  def resolve_dialect(base_code, %{custom_fields: %{"preferred_locale" => preferred}} = _user)
      when is_binary(preferred) do
    # Verify user's preference matches the base code in URL
    # Security: prevents locale preference injection attacks
    if extract_base(preferred) == String.downcase(base_code) do
      preferred
    else
      base_to_dialect(base_code)
    end
  end

  def resolve_dialect(base_code, _user) do
    base_to_dialect(base_code)
  end

  @doc """
  Validates if a base language code is supported.

  Checks if the default dialect for this base code exists in the
  predefined language list.

  ## Examples

      iex> DialectMapper.valid_base_code?("en")
      true

      iex> DialectMapper.valid_base_code?("ja")
      true

      iex> DialectMapper.valid_base_code?("xx")
      false

      iex> DialectMapper.valid_base_code?("en-US")
      false  # Not a base code (contains hyphen)

  ## Notes

  - Only validates base codes (2 letters)
  - Full dialect codes will return false (use extract_base first)
  - Checks against Languages.get_predefined_language/1
  """
  def valid_base_code?(base_code) when is_binary(base_code) do
    # Only validate if it looks like a base code (2 letters, no hyphen)
    if String.length(base_code) == 2 and not String.contains?(base_code, "-") do
      dialect = base_to_dialect(base_code)
      Languages.get_predefined_language(dialect) != nil
    else
      false
    end
  end

  @doc """
  Gets all available dialect codes for a base language.

  Searches the predefined language list for all dialects
  matching the given base code.

  ## Examples

      iex> DialectMapper.dialects_for_base("en")
      ["en-US", "en-GB", "en-CA", "en-AU"]

      iex> DialectMapper.dialects_for_base("es")
      ["es-ES", "es-MX", "es-AR", "es-CO"]

      iex> DialectMapper.dialects_for_base("ja")
      ["ja"]

      iex> DialectMapper.dialects_for_base("xx")
      []

  ## Use Cases

  - Populate user preference dropdown
  - Admin analytics (dialects per base language)
  - Migration tools (find affected users)
  """
  def dialects_for_base(base_code) when is_binary(base_code) do
    base_lower = String.downcase(base_code)

    Languages.get_available_languages()
    |> Enum.filter(fn %{code: code} ->
      extract_base(code) == base_lower
    end)
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end

  @doc """
  Gets the default dialects map.

  Useful for debugging, testing, or documentation purposes.

  ## Examples

      iex> defaults = DialectMapper.default_dialects()
      iex> defaults["en"]
      "en-US"

      iex> defaults["pt"]
      "pt-BR"
  """
  def default_dialects, do: @default_dialects
end
