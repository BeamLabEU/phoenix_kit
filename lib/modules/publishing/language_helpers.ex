defmodule PhoenixKit.Modules.Publishing.LanguageHelpers do
  @moduledoc """
  Pure language utility functions for the Publishing module.

  Provides language detection, display ordering, language info lookup,
  and primary language management.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings

  @doc """
  Returns all enabled language codes for multi-language support.
  Falls back to content language if Languages module is disabled.
  """
  @spec enabled_language_codes() :: [String.t()]
  def enabled_language_codes do
    if Languages.enabled?() do
      Languages.get_enabled_language_codes()
    else
      [Settings.get_content_language()]
    end
  end

  @doc """
  Returns the primary/canonical language for versioning.
  Uses Settings.get_content_language().
  """
  @spec get_primary_language() :: String.t()
  def get_primary_language do
    Settings.get_content_language()
  end

  @doc """
  Gets language details (name, flag) for a given language code.

  Searches in order:
  1. Predefined languages (BeamLabCountries) - for full locale details
  2. User-configured languages - for custom/less common languages
  """
  @spec get_language_info(String.t()) ::
          %{code: String.t(), name: String.t(), flag: String.t()} | nil
  def get_language_info(language_code) do
    find_in_predefined_languages(language_code) ||
      find_in_configured_languages(language_code)
  end

  @doc """
  Checks if a language code is enabled, considering base code matching.

  Handles cases where:
  - The code is `en` and enabled languages has `"en-US"` -> matches
  - The code is `en-US` and enabled languages has `"en"` -> matches
  """
  @spec language_enabled?(String.t(), [String.t()]) :: boolean()
  def language_enabled?(language_code, enabled_languages) do
    if language_code in enabled_languages do
      true
    else
      base_code = DialectMapper.extract_base(language_code)

      Enum.any?(enabled_languages, fn enabled_lang ->
        enabled_lang == language_code or
          DialectMapper.extract_base(enabled_lang) == base_code
      end)
    end
  end

  @doc """
  Determines the display code for a language based on whether multiple dialects
  of the same base language are enabled.

  If only one dialect of a base language is enabled (e.g., just "en-US"),
  returns the base code ("en") for cleaner display.

  If multiple dialects are enabled (e.g., "en-US" and "en-GB"),
  returns the full dialect code ("en-US") to distinguish them.
  """
  @spec get_display_code(String.t(), [String.t()]) :: String.t()
  def get_display_code(language_code, enabled_languages) do
    base_code = DialectMapper.extract_base(language_code)

    dialects_count =
      Enum.count(enabled_languages, fn lang ->
        DialectMapper.extract_base(lang) == base_code
      end)

    if dialects_count > 1 do
      language_code
    else
      base_code
    end
  end

  @doc """
  Orders languages for display in the language switcher.

  Order: primary language first, then languages with translations (sorted),
  then languages without translations (sorted).
  """
  @spec order_languages_for_display([String.t()], [String.t()], String.t() | nil) :: [String.t()]
  def order_languages_for_display(available_languages, enabled_languages, primary_language \\ nil) do
    primary_lang = primary_language || get_primary_language()

    langs_with_content =
      available_languages
      |> Enum.reject(&(&1 == primary_lang))
      |> Enum.sort()

    langs_without_content =
      enabled_languages
      |> Enum.reject(&(&1 in available_languages or &1 == primary_lang))
      |> Enum.sort()

    [primary_lang] ++ langs_with_content ++ langs_without_content
  end

  @doc """
  Checks if a language code is reserved (cannot be used as a slug).
  """
  @spec reserved_language_code?(String.t()) :: boolean()
  def reserved_language_code?(slug) do
    language_codes =
      try do
        Languages.get_language_codes()
      rescue
        _ -> []
      end

    slug in language_codes
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp find_in_predefined_languages(language_code) do
    case Languages.get_available_language_by_code(language_code) do
      nil ->
        base_code = DialectMapper.extract_base(language_code)
        is_base_code = language_code == base_code and not String.contains?(language_code, "-")
        default_dialect = DialectMapper.base_to_dialect(base_code)

        case Languages.get_available_language_by_code(default_dialect) do
          nil ->
            all_languages = Languages.get_available_languages()

            Enum.find(all_languages, fn lang ->
              DialectMapper.extract_base(lang.code) == base_code
            end)

          default_match ->
            if is_base_code do
              %{default_match | name: extract_base_language_name(default_match.name)}
            else
              default_match
            end
        end

      exact_match ->
        exact_match
    end
  end

  defp extract_base_language_name(name) when is_binary(name) do
    case String.split(name, " (", parts: 2) do
      [base_name, _region] -> base_name
      [base_name] -> base_name
    end
  end

  defp extract_base_language_name(name), do: name

  defp find_in_configured_languages(language_code) do
    configured_languages = Languages.get_languages()

    exact_match =
      Enum.find(configured_languages, fn lang -> lang.code == language_code end)

    result =
      if exact_match do
        exact_match
      else
        base_code = DialectMapper.extract_base(language_code)
        default_dialect = DialectMapper.base_to_dialect(base_code)

        default_match =
          Enum.find(configured_languages, fn lang -> lang.code == default_dialect end)

        if default_match do
          default_match
        else
          Enum.find(configured_languages, fn lang ->
            DialectMapper.extract_base(lang.code) == base_code
          end)
        end
      end

    if result do
      %{
        code: result.code,
        name: result.name || result.code,
        flag: result.flag || ""
      }
    else
      nil
    end
  end

  # ===========================================================================
  # Post Language Building
  # ===========================================================================

  @doc """
  Builds language data for a post's language switcher.
  Returns a list of language maps with status, enabled flag, known flag, and metadata.
  """
  def build_post_languages(post, enabled_languages, primary_language \\ nil) do
    primary_lang =
      primary_language || post[:primary_language] || get_primary_language()

    all_languages =
      order_languages_for_display(
        post.available_languages || [],
        enabled_languages,
        primary_lang
      )

    all_languages
    |> Enum.map(&build_language_entry(&1, post, enabled_languages, primary_lang))
    |> Enum.filter(fn lang -> lang.exists || lang.enabled end)
  end

  @doc """
  Builds a single language entry map for a post.
  """
  def build_language_entry(lang_code, post, enabled_languages, primary_lang) do
    lang_info = get_language_info(lang_code)
    available = post.available_languages || []
    content_exists = lang_code in available
    post_status = post[:metadata] && post.metadata.status

    %{
      code: lang_code,
      display_code: get_display_code(lang_code, enabled_languages),
      name: if(lang_info, do: lang_info.name, else: lang_code),
      flag: if(lang_info, do: lang_info.flag, else: ""),
      status: if(content_exists, do: post_status, else: nil),
      exists: content_exists,
      enabled: language_enabled?(lang_code, enabled_languages),
      known: lang_info != nil,
      is_primary: lang_code == primary_lang,
      uuid: post[:uuid]
    }
  end
end
