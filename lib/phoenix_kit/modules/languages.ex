defmodule PhoenixKit.Modules.Languages do
  @moduledoc """
  Languages management for PhoenixKit - complete language configuration in a single module.

  This module provides management for language module in PhoenixKit applications.
  It handles language configuration, settings, and language data through JSON settings.

  ## Language Structure

  Each language has the following structure:
  - `code`: Language code (e.g., "en-US", "es-ES", "fr-FR")
  - `name`: Full language name (e.g., "English (United States)", "Spanish (Spain)", "French (France)")
  - `is_default`: Boolean indicating if this is the default language
  - `is_enabled`: Boolean indicating if this language is active

  ## Core Functions

  ### Languages Management
  - `enabled?/0` - Check if languages are enabled
  - `enable_system/0` - Enable languages with default English
  - `disable_system/0` - Disable languages
  - `get_config/0` - Get complete configuration

  ### Language Management
  - `get_languages/0` - Get all configured languages
  - `get_enabled_languages/0` - Get only enabled languages
  - `get_default_language/0` - Get the default language
  - `get_language/1` - Get a specific language by code
  - `get_language_codes/0` - Get list of all language codes
  - `get_enabled_language_codes/0` - Get list of enabled language codes
  - `valid_language?/1` - Check if a language code exists
  - `language_enabled?/1` - Check if a language is enabled
  - `add_language/1` - Add a new language to the system
  - `update_language/2` - Update an existing language
  - `remove_language/1` - Remove a language from the system
  - `set_default_language/1` - Set a new default language
  - `enable_language/1` - Enable a specific language
  - `disable_language/1` - Disable a specific language

  ## Usage Examples

      # Check if languages are enabled
      if PhoenixKit.Modules.Languages.enabled?() do
        # Languages are active
      end

      # Enable languages (creates default English language)
      {:ok, config} = PhoenixKit.Modules.Languages.enable_system()

      # Add a new language
      {:ok, config} = PhoenixKit.Modules.Languages.add_language("es")

      # Get all languages
      languages = PhoenixKit.Modules.Languages.get_languages()
      # => [%{code: "en-US", name: "English (United States)", is_default: true, is_enabled: true}, ...]

      # Get only enabled languages (most common use case)
      enabled_languages = PhoenixKit.Modules.Languages.get_enabled_languages()
      # => [%{code: "en-US", name: "English (United States)", ...}, %{code: "es-ES", name: "Spanish (Spain)", ...}]

      # Get a specific language by code
      spanish = PhoenixKit.Modules.Languages.get_language("es-ES")
      # => %{code: "es-ES", name: "Spanish (Spain)", is_enabled: true}

      # Get just the language codes
      codes = PhoenixKit.Modules.Languages.get_enabled_language_codes()
      # => ["en-US", "es-ES", "fr-FR"]

      # Check if a language is valid and enabled
      if PhoenixKit.Modules.Languages.language_enabled?("es-ES") do
        # Use Spanish language
      end

  ## JSON Storage Format

  Languages are stored in the `languages_config` setting as JSON.
  The array order determines the display order:

      {
        "languages": [
          {
            "code": "en-US",
            "name": "English (United States)",
            "is_default": true,
            "is_enabled": true
          },
          {
            "code": "es-ES",
            "name": "Spanish (Spain)",
            "is_default": false,
            "is_enabled": true
          }
        ]
      }
  """

  alias PhoenixKit.Settings

  @config_key "languages_config"
  @enabled_key "languages_enabled"
  @module_name "languages"

  # Predefined list of available languages
  # Each language includes a countries list for grouping (language can appear under multiple countries)
  @available_languages [
    %{code: "sq", name: "Albanian", native: "Shqip", flag: "🇦🇱", countries: ["Albania"]},
    %{code: "am", name: "Amharic", native: "አማርኛ", flag: "🇪🇹", countries: ["Ethiopia"]},
    %{
      code: "ar",
      name: "Arabic",
      native: "العربية",
      flag: "🇸🇦",
      countries: ["Saudi Arabia", "Egypt", "United Arab Emirates", "Morocco", "Iraq", "Jordan"]
    },
    %{code: "hy", name: "Armenian", native: "Հայdelays", flag: "🇦🇲", countries: ["Armenia"]},
    %{
      code: "az",
      name: "Azerbaijani",
      native: "Azərbaycan",
      flag: "🇦🇿",
      countries: ["Azerbaijan"]
    },
    %{
      code: "eu",
      name: "Basque",
      native: "Euskera",
      flag: "🏴",
      countries: ["Basque Country", "Spain"]
    },
    %{code: "bn", name: "Bengali", native: "বাংলা", flag: "🇧🇩", countries: ["Bangladesh", "India"]},
    %{
      code: "bs",
      name: "Bosnian",
      native: "Bosanski",
      flag: "🇧🇦",
      countries: ["Bosnia and Herzegovina"]
    },
    %{code: "bg", name: "Bulgarian", native: "Български", flag: "🇧🇬", countries: ["Bulgaria"]},
    %{
      code: "ca",
      name: "Catalan",
      native: "Català",
      flag: "🏴",
      countries: ["Catalonia", "Spain"]
    },
    %{
      code: "zh-CN",
      name: "Chinese (Simplified)",
      native: "简体中文",
      flag: "🇨🇳",
      countries: ["China", "Singapore", "Malaysia"]
    },
    %{
      code: "zh-TW",
      name: "Chinese (Traditional)",
      native: "繁體中文",
      flag: "🇹🇼",
      countries: ["Taiwan", "Hong Kong", "Macau"]
    },
    %{
      code: "hr",
      name: "Croatian",
      native: "Hrvatski",
      flag: "🇭🇷",
      countries: ["Croatia", "Bosnia and Herzegovina"]
    },
    %{code: "cs", name: "Czech", native: "Čeština", flag: "🇨🇿", countries: ["Czech Republic"]},
    %{code: "da", name: "Danish", native: "Dansk", flag: "🇩🇰", countries: ["Denmark"]},
    %{
      code: "nl",
      name: "Dutch",
      native: "Nederlands",
      flag: "🇳🇱",
      countries: ["Netherlands", "Belgium"]
    },
    %{
      code: "en-US",
      name: "English (United States)",
      native: "English (US)",
      flag: "🇺🇸",
      countries: [
        "United States",
        "Canada",
        "United Kingdom",
        "Australia",
        "Ireland",
        "New Zealand"
      ]
    },
    %{
      code: "en-GB",
      name: "English (United Kingdom)",
      native: "English (UK)",
      flag: "🇬🇧",
      countries: [
        "United Kingdom",
        "United States",
        "Canada",
        "Australia",
        "Ireland",
        "New Zealand"
      ]
    },
    %{
      code: "en-CA",
      name: "English (Canada)",
      native: "English (CA)",
      flag: "🇨🇦",
      countries: ["Canada", "United States", "United Kingdom", "Australia"]
    },
    %{
      code: "en-AU",
      name: "English (Australia)",
      native: "English (AU)",
      flag: "🇦🇺",
      countries: ["Australia", "United States", "United Kingdom", "New Zealand"]
    },
    %{code: "et", name: "Estonian", native: "Eesti", flag: "🇪🇪", countries: ["Estonia"]},
    %{code: "tl", name: "Filipino", native: "Filipino", flag: "🇵🇭", countries: ["Philippines"]},
    %{code: "fi", name: "Finnish", native: "Suomi", flag: "🇫🇮", countries: ["Finland"]},
    %{
      code: "fr-FR",
      name: "French (France)",
      native: "Français (France)",
      flag: "🇫🇷",
      countries: ["France", "Canada", "Belgium", "Switzerland"]
    },
    %{
      code: "fr-CA",
      name: "French (Canada)",
      native: "Français (Canada)",
      flag: "🇨🇦",
      countries: ["Canada", "France", "Belgium"]
    },
    %{code: "gl", name: "Galician", native: "Galego", flag: "🏴", countries: ["Galicia", "Spain"]},
    %{code: "ka", name: "Georgian", native: "ქართული", flag: "🇬🇪", countries: ["Georgia"]},
    %{
      code: "de-DE",
      name: "German (Germany)",
      native: "Deutsch (Deutschland)",
      flag: "🇩🇪",
      countries: ["Germany", "Austria", "Switzerland"]
    },
    %{
      code: "de-AT",
      name: "German (Austria)",
      native: "Deutsch (Österreich)",
      flag: "🇦🇹",
      countries: ["Austria", "Germany", "Switzerland"]
    },
    %{
      code: "de-CH",
      name: "German (Switzerland)",
      native: "Deutsch (Schweiz)",
      flag: "🇨🇭",
      countries: ["Switzerland", "Germany", "Austria"]
    },
    %{code: "gu", name: "Gujarati", native: "ગુજરાતી", flag: "🇮🇳", countries: ["India"]},
    %{code: "he", name: "Hebrew", native: "עברית", flag: "🇮🇱", countries: ["Israel"]},
    %{code: "hi", name: "Hindi", native: "हिन्दी", flag: "🇮🇳", countries: ["India"]},
    %{code: "hu", name: "Hungarian", native: "Magyar", flag: "🇭🇺", countries: ["Hungary"]},
    %{code: "is", name: "Icelandic", native: "Íslenska", flag: "🇮🇸", countries: ["Iceland"]},
    %{
      code: "id",
      name: "Indonesian",
      native: "Bahasa Indonesia",
      flag: "🇮🇩",
      countries: ["Indonesia"]
    },
    %{
      code: "ga",
      name: "Irish",
      native: "Gaeilge",
      flag: "🇮🇪",
      countries: ["Ireland", "United Kingdom"]
    },
    %{
      code: "it",
      name: "Italian",
      native: "Italiano",
      flag: "🇮🇹",
      countries: ["Italy", "Switzerland"]
    },
    %{code: "ja", name: "Japanese", native: "日本語", flag: "🇯🇵", countries: ["Japan"]},
    %{code: "kn", name: "Kannada", native: "ಕನ್ನಡ", flag: "🇮🇳", countries: ["India"]},
    %{code: "kk", name: "Kazakh", native: "Қазақша", flag: "🇰🇿", countries: ["Kazakhstan"]},
    %{code: "km", name: "Khmer", native: "ខ្មែរ", flag: "🇰🇭", countries: ["Cambodia"]},
    %{
      code: "ko",
      name: "Korean",
      native: "한국어",
      flag: "🇰🇷",
      countries: ["South Korea", "North Korea"]
    },
    %{code: "ky", name: "Kyrgyz", native: "Кыргызча", flag: "🇰🇬", countries: ["Kyrgyzstan"]},
    %{code: "lo", name: "Lao", native: "ລາວ", flag: "🇱🇦", countries: ["Laos"]},
    %{code: "lv", name: "Latvian", native: "Latviešu", flag: "🇱🇻", countries: ["Latvia"]},
    %{code: "lt", name: "Lithuanian", native: "Lietuvių", flag: "🇱🇹", countries: ["Lithuania"]},
    %{
      code: "mk",
      name: "Macedonian",
      native: "Македонски",
      flag: "🇲🇰",
      countries: ["North Macedonia"]
    },
    %{
      code: "ms",
      name: "Malay",
      native: "Bahasa Melayu",
      flag: "🇲🇾",
      countries: ["Malaysia", "Singapore", "Brunei"]
    },
    %{code: "ml", name: "Malayalam", native: "മലയാളം", flag: "🇮🇳", countries: ["India"]},
    %{code: "mt", name: "Maltese", native: "Malti", flag: "🇲🇹", countries: ["Malta"]},
    %{code: "mr", name: "Marathi", native: "मराठी", flag: "🇮🇳", countries: ["India"]},
    %{code: "mn", name: "Mongolian", native: "Монгол", flag: "🇲🇳", countries: ["Mongolia"]},
    %{
      code: "me",
      name: "Montenegrin",
      native: "Crnogorski",
      flag: "🇲🇪",
      countries: ["Montenegro"]
    },
    %{code: "my", name: "Myanmar", native: "မြန်မာ", flag: "🇲🇲", countries: ["Myanmar"]},
    %{code: "ne", name: "Nepali", native: "नेपाली", flag: "🇳🇵", countries: ["Nepal", "India"]},
    %{code: "no", name: "Norwegian", native: "Norsk", flag: "🇳🇴", countries: ["Norway"]},
    %{
      code: "fa",
      name: "Persian",
      native: "فارسی",
      flag: "🇮🇷",
      countries: ["Iran", "Afghanistan", "Tajikistan"]
    },
    %{code: "pl", name: "Polish", native: "Polski", flag: "🇵🇱", countries: ["Poland"]},
    %{
      code: "pt-PT",
      name: "Portuguese (Portugal)",
      native: "Português (Portugal)",
      flag: "🇵🇹",
      countries: ["Portugal", "Brazil"]
    },
    %{
      code: "pt-BR",
      name: "Portuguese (Brazil)",
      native: "Português (Brasil)",
      flag: "🇧🇷",
      countries: ["Brazil", "Portugal"]
    },
    %{code: "pa", name: "Punjabi", native: "ਪੰਜਾਬੀ", flag: "🇮🇳", countries: ["India", "Pakistan"]},
    %{
      code: "ro",
      name: "Romanian",
      native: "Română",
      flag: "🇷🇴",
      countries: ["Romania", "Moldova"]
    },
    %{
      code: "ru",
      name: "Russian",
      native: "Русский",
      flag: "🇷🇺",
      countries: ["Russia", "Belarus", "Kazakhstan", "Ukraine"]
    },
    %{
      code: "gd",
      name: "Scottish Gaelic",
      native: "Gàidhlig",
      flag: "🏴",
      countries: ["Scotland", "United Kingdom"]
    },
    %{
      code: "sr",
      name: "Serbian",
      native: "Српски",
      flag: "🇷🇸",
      countries: ["Serbia", "Bosnia and Herzegovina", "Montenegro"]
    },
    %{code: "si", name: "Sinhala", native: "සිංහල", flag: "🇱🇰", countries: ["Sri Lanka"]},
    %{code: "sk", name: "Slovak", native: "Slovenčina", flag: "🇸🇰", countries: ["Slovakia"]},
    %{code: "sl", name: "Slovenian", native: "Slovenščina", flag: "🇸🇮", countries: ["Slovenia"]},
    %{
      code: "es-ES",
      name: "Spanish (Spain)",
      native: "Español (España)",
      flag: "🇪🇸",
      countries: ["Spain", "Mexico", "Argentina", "Colombia", "Chile", "Peru", "United States"]
    },
    %{
      code: "es-MX",
      name: "Spanish (Mexico)",
      native: "Español (México)",
      flag: "🇲🇽",
      countries: ["Mexico", "Spain", "Argentina", "Colombia", "United States"]
    },
    %{
      code: "es-AR",
      name: "Spanish (Argentina)",
      native: "Español (Argentina)",
      flag: "🇦🇷",
      countries: ["Argentina", "Spain", "Mexico", "Colombia", "Chile"]
    },
    %{
      code: "es-CO",
      name: "Spanish (Colombia)",
      native: "Español (Colombia)",
      flag: "🇨🇴",
      countries: ["Colombia", "Spain", "Mexico", "Argentina"]
    },
    %{
      code: "sw",
      name: "Swahili",
      native: "Kiswahili",
      flag: "🇰🇪",
      countries: ["Kenya", "Tanzania", "Uganda"]
    },
    %{
      code: "sv",
      name: "Swedish",
      native: "Svenska",
      flag: "🇸🇪",
      countries: ["Sweden", "Finland"]
    },
    %{
      code: "ta",
      name: "Tamil",
      native: "தமிழ்",
      flag: "🇱🇰",
      countries: ["Sri Lanka", "India", "Singapore", "Malaysia"]
    },
    %{code: "te", name: "Telugu", native: "తెలుగు", flag: "🇮🇳", countries: ["India"]},
    %{code: "th", name: "Thai", native: "ไทย", flag: "🇹🇭", countries: ["Thailand"]},
    %{code: "tr", name: "Turkish", native: "Türkçe", flag: "🇹🇷", countries: ["Turkey", "Cyprus"]},
    %{code: "tk", name: "Turkmen", native: "Türkmen", flag: "🇹🇲", countries: ["Turkmenistan"]},
    %{code: "ur", name: "Urdu", native: "اردو", flag: "🇵🇰", countries: ["Pakistan", "India"]},
    %{code: "uz", name: "Uzbek", native: "O'zbek", flag: "🇺🇿", countries: ["Uzbekistan"]},
    %{code: "vi", name: "Vietnamese", native: "Tiếng Việt", flag: "🇻🇳", countries: ["Vietnam"]},
    %{
      code: "cy",
      name: "Welsh",
      native: "Cymraeg",
      flag: "🏴",
      countries: ["Wales", "United Kingdom"]
    }
  ]

  # Default configuration when system is first enabled
  @default_config %{
    "languages" => [
      %{
        "code" => "en-US",
        "name" => "English (United States)",
        "is_default" => true,
        "is_enabled" => true
      }
    ]
  }

  # Top 10 most common languages for permanent display in admin
  @top_10_languages [
    %{
      "code" => "en-US",
      "name" => "English (United States)",
      "is_default" => true,
      "is_enabled" => true
    },
    %{
      "code" => "es-ES",
      "name" => "Spanish (Spain)",
      "is_default" => false,
      "is_enabled" => true
    },
    %{
      "code" => "fr-FR",
      "name" => "French (France)",
      "is_default" => false,
      "is_enabled" => true
    },
    %{
      "code" => "de-DE",
      "name" => "German (Germany)",
      "is_default" => false,
      "is_enabled" => true
    },
    %{"code" => "ja", "name" => "Japanese", "is_default" => false, "is_enabled" => true},
    %{
      "code" => "pt-BR",
      "name" => "Portuguese (Brazil)",
      "is_default" => false,
      "is_enabled" => true
    },
    %{"code" => "it", "name" => "Italian", "is_default" => false, "is_enabled" => true},
    %{"code" => "ko", "name" => "Korean", "is_default" => false, "is_enabled" => true},
    %{"code" => "ru", "name" => "Russian", "is_default" => false, "is_enabled" => true},
    %{"code" => "nl", "name" => "Dutch", "is_default" => false, "is_enabled" => true},
    %{
      "code" => "zh-CN",
      "name" => "Chinese (Mandarin)",
      "is_default" => false,
      "is_enabled" => true
    },
    %{"code" => "ar", "name" => "Arabic", "is_default" => false, "is_enabled" => true}
  ]

  ## --- System Management Functions ---

  @doc """
  Checks if the language module is enabled.

  Returns true if the module is enabled, false otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Languages.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  end

  @doc """
  Enables the language module and creates default configuration.

  Creates the initial module configuration with English as the default language.
  If a previous configuration exists, it will be restored instead of reset.
  Updates both the enabled flag and the JSON configuration.

  Returns `{:ok, config}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> PhoenixKit.Modules.Languages.enable_system()
      {:ok, %{"languages" => [%{"code" => "en-US", ...}]}}
  """
  def enable_system do
    # Enable the system
    case Settings.update_boolean_setting_with_module(@enabled_key, true, @module_name) do
      {:ok, _setting} ->
        # Check if a previous configuration exists to preserve languages
        existing_config = Settings.get_json_setting(@config_key, nil)
        config_to_save = if is_nil(existing_config), do: @default_config, else: existing_config

        # Save the configuration (either existing or new default)
        case Settings.update_json_setting_with_module(@config_key, config_to_save, @module_name) do
          {:ok, _setting} -> {:ok, config_to_save}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Disables the language module.

  Turns off the language module but preserves the language configuration.

  Returns `{:ok, setting}` on success, `{:error, changeset}` on failure.

  ## Examples

      iex> PhoenixKit.Modules.Languages.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, @module_name)
  end

  @doc """
  Gets the complete language module configuration.

  Returns a map with module status and language configuration.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_config()
      %{
        enabled: true,
        languages: [%{"code" => "en-US", "name" => "English (United States)", ...}],
        language_count: 1,
        enabled_count: 1,
        default_language: %{"code" => "en-US", "name" => "English (United States)", ...}
      }
  """
  def get_config do
    enabled = enabled?()
    languages = get_languages()
    enabled_languages = Enum.filter(languages, & &1["is_enabled"])
    default_language = Enum.find(languages, & &1["is_default"])

    %{
      enabled: enabled,
      languages: languages,
      language_count: length(languages),
      enabled_count: length(enabled_languages),
      default_language: default_language
    }
  end

  ## --- Language Management Functions ---

  @doc """
  Gets all configured languages from the JSON setting.

  Returns a list of language maps, or empty list if not configured.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_languages()
      [%{"code" => "en-US", "name" => "English (United States)", "is_default" => true, ...}]

      # When system is disabled:
      iex> PhoenixKit.Modules.Languages.get_languages()
      []
  """
  def get_languages do
    if enabled?() do
      case Settings.get_json_setting_cached(@config_key, nil) do
        %{"languages" => languages} when is_list(languages) -> languages
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Gets only enabled languages, sorted by position.

  Returns a list of enabled language maps.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_enabled_languages()
      [%{"code" => "en-US", "name" => "English (United States)", ...}]
  """
  def get_enabled_languages do
    get_languages()
    |> Enum.filter(& &1["is_enabled"])
    |> Enum.sort_by(& &1["position"])
  end

  @doc """
  Gets the default language.

  Returns the language map marked as default, or nil if none found.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_default_language()
      %{"code" => "en-US", "name" => "English (United States)", "is_default" => true, ...}

      # When system is disabled:
      iex> PhoenixKit.Modules.Languages.get_default_language()
      nil
  """
  def get_default_language do
    if enabled?() do
      get_languages()
      |> Enum.find(& &1["is_default"])
    else
      nil
    end
  end

  @doc """
  Gets a specific language by its code.

  Returns the language map if found, or nil if not found.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_language("es-ES")
      %{"code" => "es-ES", "name" => "Spanish (Spain)", "is_enabled" => true}

      iex> PhoenixKit.Modules.Languages.get_language("invalid")
      nil
  """
  def get_language(code) when is_binary(code) do
    if enabled?() do
      get_languages()
      |> Enum.find(&(&1["code"] == code))
    else
      nil
    end
  end

  @doc """
  Gets a list of all language codes.

  Returns a list of language code strings.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_language_codes()
      ["en-US", "es-ES", "fr-FR"]
  """
  def get_language_codes do
    get_languages()
    |> Enum.map(& &1["code"])
  end

  @doc """
  Gets a list of enabled language codes, sorted by position.

  Returns a list of enabled language code strings.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_enabled_language_codes()
      ["en-US", "es-ES"]
  """
  def get_enabled_language_codes do
    get_enabled_languages()
    |> Enum.map(& &1["code"])
  end

  @doc """
  Gets enabled language codes for locale-based routing.

  Returns a list of enabled language codes that can be used in URL routing.
  Falls back to ["en"] when the language module is disabled.

  ## Examples

      iex> PhoenixKit.Modules.Languages.enabled_locale_codes()
      ["en-US", "es-ES", "fr-FR"]

      # When system is disabled:
      iex> PhoenixKit.Modules.Languages.enabled_locale_codes()
      ["en-US"]
  """
  def enabled_locale_codes do
    # Return enabled language codes from the frontend language module only
    # Admin navbar languages are managed separately in settings
    if enabled?() do
      codes = get_enabled_language_codes()
      # Ensure we always have at least "en-US" as a fallback
      if Enum.empty?(codes), do: ["en-US"], else: codes
    else
      ["en-US"]
    end
  end

  @doc """
  Gets the appropriate language list for frontend display.

  Returns the configured languages if the module is enabled.
  Otherwise, returns the permanent top 12 most common languages for display.

  This allows the frontend to always show a language list, reverting to the top 12 when
  the module is disabled.

  ## Examples

      # When enabled (any number of languages)
      iex> PhoenixKit.Modules.Languages.get_display_languages()
      [%{"code" => "en-US", "name" => "English (United States)", ...}]

      # When disabled
      iex> PhoenixKit.Modules.Languages.get_display_languages()
      [%{"code" => "en-US", ...}, %{"code" => "es-ES", ...}, ...]  # Top 12 default
  """
  def get_display_languages do
    if enabled?() do
      # Show configured languages when enabled (even if just 1)
      get_languages()
    else
      # Show top 12 default languages when disabled
      @top_10_languages
    end
  end

  @doc """
  Checks if currently in configured mode (showing user-configured languages vs defaults).

  Returns true if the module is enabled and has 2+ configured languages.
  Returns false if showing the default top 10 languages.

  ## Examples

      iex> PhoenixKit.Modules.Languages.in_configured_mode?()
      true  # When enabled with 2+ languages

      iex> PhoenixKit.Modules.Languages.in_configured_mode?()
      false  # When disabled or only 1 language
  """
  def in_configured_mode? do
    enabled?() and length(get_languages()) >= 2
  end

  @doc """
  Checks if a language code is valid (exists in configuration).

  Returns true if the language exists, false otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Languages.valid_language?("es-ES")
      true

      iex> PhoenixKit.Modules.Languages.valid_language?("invalid")
      false
  """
  def valid_language?(code) when is_binary(code) do
    not is_nil(get_language(code))
  end

  @doc """
  Checks if a language is enabled.

  Returns true if the language exists and is enabled, false otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Languages.language_enabled?("es-ES")
      true

      iex> PhoenixKit.Modules.Languages.language_enabled?("disabled_lang")
      false
  """
  def language_enabled?(code) when is_binary(code) do
    enabled?() &&
      case get_language(code) do
        %{"is_enabled" => true} -> true
        _ -> false
      end
  end

  @doc """
  Gets the 12 default popular languages for admin panel display.

  Returns a list of the most commonly used language codes that should
  be available in the admin panel language selector.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_default_language_codes()
      ["en-US", "es-ES", "fr-FR", "de-DE", "pt-BR", "it", "nl", "ru", "ja", "ko", "zh-CN", "ar"]
  """
  def get_default_language_codes do
    @top_10_languages
    |> Enum.map(& &1["code"])
  end

  @doc """
  Gets all available predefined languages.

  Returns the complete list of languages that can be added to the system.
  This list is used to populate dropdown selections.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_available_languages()
      [%{code: "en-US", name: "English (United States)", native: "English (US)", flag: "🇺🇸"}, ...]
  """
  def get_available_languages do
    @available_languages
  end

  @doc """
  Gets available languages for selection (excludes already added languages).

  Returns languages that can be added to the system, filtered to exclude
  languages that have already been configured.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_available_languages_for_selection()
      [%{code: "es-ES", name: "Spanish (Spain)", native: "Español (España)", flag: "🇪🇸"}, ...]
  """
  def get_available_languages_for_selection do
    if enabled?() do
      current_codes = get_languages() |> Enum.map(& &1["code"])

      @available_languages
      |> Enum.reject(fn lang -> lang.code in current_codes end)
    else
      @available_languages
    end
  end

  @doc """
  Gets a predefined language by code.

  Returns the language definition from the available languages list.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_predefined_language("es-ES")
      %{code: "es-ES", name: "Spanish (Spain)", native: "Español (España)", flag: "🇪🇸"}

      iex> PhoenixKit.Modules.Languages.get_predefined_language("invalid")
      nil
  """
  def get_predefined_language(code) when is_binary(code) do
    Enum.find(@available_languages, &(&1.code == code))
  end

  @doc """
  Gets all available languages grouped by country.

  Returns a list of {country, languages} tuples sorted alphabetically by country name.
  Languages are sorted by name within each country group.
  A language can appear under multiple countries based on its `countries` list.
  This is useful for displaying languages in a grouped dropdown or list.

  ## Examples

      iex> PhoenixKit.Modules.Languages.get_languages_grouped_by_country()
      [
        {"Argentina", [%{code: "es-AR", name: "Spanish (Argentina)", ...}, %{code: "es-ES", ...}]},
        {"Australia", [%{code: "en-AU", ...}, %{code: "en-GB", ...}, %{code: "en-US", ...}]},
        {"Canada", [%{code: "en-CA", ...}, %{code: "en-GB", ...}, %{code: "fr-CA", ...}, %{code: "fr-FR", ...}]},
        ...
      ]
  """
  def get_languages_grouped_by_country do
    @available_languages
    |> Enum.flat_map(fn lang ->
      # Create one entry per country for this language
      Enum.map(lang.countries, fn country ->
        Map.put(lang, :country, country)
      end)
    end)
    |> Enum.group_by(& &1.country)
    |> Enum.sort_by(fn {country, _languages} -> country end)
    |> Enum.map(fn {country, languages} ->
      {country, Enum.sort_by(languages, & &1.name)}
    end)
  end

  @doc """
  Adds a predefined language to the module by language code.

  Takes a language code and adds the corresponding predefined language
  to the module configuration. Only languages from the predefined list
  can be added.

  ## Examples

      iex> PhoenixKit.Modules.Languages.add_language("es-ES")
      {:ok, updated_config}

      iex> PhoenixKit.Modules.Languages.add_language("en-US")  # if already exists
      {:error, "Language already exists"}

      iex> PhoenixKit.Modules.Languages.add_language("invalid")
      {:error, "Language not found in available languages"}
  """
  def add_language(code) when is_binary(code) do
    # Check if language exists in predefined list
    case get_predefined_language(code) do
      nil ->
        {:error, "Language not found in available languages"}

      predefined_lang ->
        current_config = Settings.get_json_setting(@config_key, @default_config)
        current_languages = Map.get(current_config, "languages", [])

        # Check if language code already exists
        if Enum.any?(current_languages, &(&1["code"] == code)) do
          {:error, "Language already exists"}
        else
          # Create new language from predefined data
          new_language = %{
            "code" => predefined_lang.code,
            "name" => predefined_lang.name,
            "is_default" => false,
            "is_enabled" => true
          }

          # Add new language to the end of the list
          final_languages = current_languages ++ [new_language]
          updated_config = Map.put(current_config, "languages", final_languages)

          # Save updated configuration
          case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
            {:ok, _setting} -> {:ok, updated_config}
            {:error, changeset} -> {:error, changeset}
          end
        end
    end
  end

  @doc """
  Updates an existing language in the system.

  Takes a language code and map of attributes to update.

  ## Examples

      iex> PhoenixKit.Modules.Languages.update_language("es-ES", %{name: "Español"})
      {:ok, updated_config}

      iex> PhoenixKit.Modules.Languages.update_language("nonexistent", %{name: "Test"})
      {:error, "Language not found"}
  """
  def update_language(code, attrs) when is_binary(code) and is_map(attrs) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    case Enum.find_index(current_languages, &(&1["code"] == code)) do
      nil ->
        {:error, "Language not found"}

      index ->
        do_update_language_at_index(current_config, current_languages, index, attrs)
    end
  end

  @doc """
  Removes a language from the system.

  Cannot remove the default language or the last remaining language.

  ## Examples

      iex> PhoenixKit.Modules.Languages.remove_language("es-ES")
      {:ok, updated_config}

      iex> PhoenixKit.Modules.Languages.remove_language("en-US")  # if it's default
      {:error, "Cannot remove default language"}
  """
  def remove_language(code) when is_binary(code) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    language_to_remove = Enum.find(current_languages, &(&1["code"] == code))

    cond do
      is_nil(language_to_remove) ->
        {:error, "Language not found"}

      language_to_remove["is_default"] ->
        {:error, "Cannot remove default language"}

      length(current_languages) <= 1 ->
        {:error, "Cannot remove the last language"}

      true ->
        updated_languages = Enum.reject(current_languages, &(&1["code"] == code))
        updated_config = Map.put(current_config, "languages", updated_languages)

        # Save updated configuration
        case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
          {:ok, _setting} -> {:ok, updated_config}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Sets a new default language.

  Removes default status from all other languages and sets the specified language as default.

  ## Examples

      iex> PhoenixKit.Modules.Languages.set_default_language("es-ES")
      {:ok, updated_config}

      iex> PhoenixKit.Modules.Languages.set_default_language("nonexistent")
      {:error, "Language not found"}
  """
  def set_default_language(code) when is_binary(code) do
    update_language(code, %{"is_default" => true})
  end

  @doc """
  Enables a specific language.

  ## Examples

      iex> PhoenixKit.Modules.Languages.enable_language("es-ES")
      {:ok, updated_config}
  """
  def enable_language(code) when is_binary(code) do
    update_language(code, %{"is_enabled" => true})
  end

  @doc """
  Disables a specific language.

  Cannot disable the default language.

  ## Examples

      iex> PhoenixKit.Modules.Languages.disable_language("es-ES")
      {:ok, updated_config}

      iex> PhoenixKit.Modules.Languages.disable_language("en-US")  # if it's default
      {:error, "Cannot disable default language"}
  """
  def disable_language(code) when is_binary(code) do
    current_languages = get_languages()
    language = Enum.find(current_languages, &(&1["code"] == code))

    if language && language["is_default"] do
      {:error, "Cannot disable default language"}
    else
      update_language(code, %{"is_enabled" => false})
    end
  end

  @doc """
  Moves a language up one position in the array.

  Moves the language one index earlier in the languages array. Cannot move the first language up.

  ## Examples

      iex> PhoenixKit.Modules.Languages.move_language_up("es-ES")
      {:ok, updated_config}

      iex> PhoenixKit.Modules.Languages.move_language_up("en-US")  # if first in array
      {:error, "Language is already at the top"}
  """
  def move_language_up(code) when is_binary(code) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    # Find the index of the language to move
    current_index = Enum.find_index(current_languages, &(&1["code"] == code))

    if current_index do
      if current_index == 0 do
        {:error, "Language is already at the top"}
      else
        # Swap with the previous element in the array
        updated_languages =
          current_languages
          |> List.update_at(current_index, fn _ ->
            Enum.at(current_languages, current_index - 1)
          end)
          |> List.update_at(current_index - 1, fn _ ->
            Enum.at(current_languages, current_index)
          end)

        updated_config = Map.put(current_config, "languages", updated_languages)

        # Save updated configuration
        case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
          {:ok, _setting} -> {:ok, updated_config}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:error, "Language not found"}
    end
  end

  @doc """
  Moves a language down one position in the array.

  Moves the language one index later in the languages array. Cannot move the last language down.

  ## Examples

      iex> PhoenixKit.Modules.Languages.move_language_down("en-US")
      {:ok, updated_config}

      iex> PhoenixKit.Modules.Languages.move_language_down("es-ES")  # if last in array
      {:error, "Language is already at the bottom"}
  """
  def move_language_down(code) when is_binary(code) do
    current_config = Settings.get_json_setting(@config_key, @default_config)
    current_languages = Map.get(current_config, "languages", [])

    # Find the index of the language to move
    current_index = Enum.find_index(current_languages, &(&1["code"] == code))

    if current_index do
      max_index = length(current_languages) - 1

      if current_index == max_index do
        {:error, "Language is already at the bottom"}
      else
        # Swap with the next element in the array
        updated_languages =
          current_languages
          |> List.update_at(current_index, fn _ ->
            Enum.at(current_languages, current_index + 1)
          end)
          |> List.update_at(current_index + 1, fn _ ->
            Enum.at(current_languages, current_index)
          end)

        updated_config = Map.put(current_config, "languages", updated_languages)

        # Save updated configuration
        case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
          {:ok, _setting} -> {:ok, updated_config}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:error, "Language not found"}
    end
  end

  ## --- Private Helper Functions ---

  # Update a language at a specific index with proper default handling
  defp do_update_language_at_index(current_config, current_languages, index, attrs) do
    # Update the language
    current_language = Enum.at(current_languages, index)
    updated_language = Map.merge(current_language, stringify_keys(attrs))

    # If setting as default, remove default from other languages
    updated_languages =
      if updated_language["is_default"] do
        update_languages_with_new_default(current_languages, index, updated_language)
      else
        List.replace_at(current_languages, index, updated_language)
      end

    updated_config = Map.put(current_config, "languages", updated_languages)

    # Save updated configuration
    case Settings.update_json_setting_with_module(@config_key, updated_config, @module_name) do
      {:ok, _setting} -> {:ok, updated_config}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Update languages list when setting a new default language
  defp update_languages_with_new_default(current_languages, index, updated_language) do
    current_languages
    |> List.replace_at(index, updated_language)
    |> Enum.with_index()
    |> Enum.map(fn {lang, idx} ->
      if idx != index, do: Map.put(lang, "is_default", false), else: lang
    end)
  end

  # Convert atom keys to string keys for JSON storage
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
