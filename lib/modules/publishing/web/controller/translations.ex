defmodule PhoenixKit.Modules.Publishing.Web.Controller.Translations do
  @moduledoc """
  Translation link building for the publishing controller.

  Handles building translation/language switcher links for:
  - Blog listing pages
  - Individual post pages
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  # ============================================================================
  # Listing Page Translations
  # ============================================================================

  @doc """
  Build translation links for blog listing page.
  Accepts posts to avoid redundant list_posts calls.
  """
  def build_listing_translations(blog_slug, current_language, posts) do
    # Get enabled languages - these are the ONLY languages that should show
    enabled_languages =
      try do
        Languages.enabled_locale_codes()
      rescue
        _ -> ["en"]
      end

    # Extract base code from current language for comparison
    current_base = DialectMapper.extract_base(current_language)

    # Get the primary/default language
    primary_language = List.first(enabled_languages) || "en"

    # For each enabled language, check if there's published content for it
    # Only show languages that are explicitly enabled (not just base code matches)
    translations =
      enabled_languages
      |> Enum.filter(fn lang ->
        # Check if this specific language has published content (using passed posts)
        has_published_content_for_language?(posts, lang)
      end)
      |> Enum.map(fn lang ->
        # Use display_code helper to determine if we show base or full code
        display_code = Storage.get_display_code(lang, enabled_languages)

        %{
          code: display_code,
          display_code: display_code,
          name: Language.get_language_name(lang),
          flag: Language.get_language_flag(lang),
          url: PublishingHTML.blog_listing_path(display_code, blog_slug),
          current: DialectMapper.extract_base(lang) == current_base
        }
      end)

    # Order: primary first, then the rest alphabetically
    if Enum.any?(
         translations,
         &(&1.code == Storage.get_display_code(primary_language, enabled_languages))
       ) do
      primary_display = Storage.get_display_code(primary_language, enabled_languages)
      {primary, others} = Enum.split_with(translations, &(&1.code == primary_display))
      primary ++ Enum.sort_by(others, & &1.code)
    else
      Enum.sort_by(translations, & &1.code)
    end
    |> Enum.uniq_by(& &1.code)
  end

  # Check if a specific enabled language has published content in the blog
  # ONLY checks for EXACT file matches - no base code fallback
  # This ensures only languages with actual files show in the public switcher
  # Uses passed posts to avoid redundant list_posts calls
  defp has_published_content_for_language?(posts, language) do
    Enum.any?(posts, fn post ->
      # Check if there's a published file for this EXACT language only
      # Use preloaded language_statuses map
      language in (post.available_languages || []) and
        Map.get(post.language_statuses, language) == "published"
    end)
  end

  # ============================================================================
  # Post Page Translations
  # ============================================================================

  @doc """
  Build translation links for a post page.
  """
  def build_translation_links(blog_slug, post, current_language, opts \\ []) do
    version = Keyword.get(opts, :version)

    # Get enabled languages
    enabled_languages =
      try do
        Languages.enabled_locale_codes()
      rescue
        _ -> ["en"]
      end

    # Extract base code from current language for comparison
    current_base = DialectMapper.extract_base(current_language)

    # Get the primary/default language
    primary_language = List.first(enabled_languages) || "en"

    # Fetch language_slugs from cache for per-language URL slugs
    # Falls back to using post.slug for all languages if cache miss
    language_slugs = fetch_language_slugs_from_cache(blog_slug, post)

    # Include ALL available languages that are published
    # This allows legacy/disabled languages to still show in the public switcher
    # (they'll be styled differently by the component based on enabled/known flags)
    available_and_published =
      post.available_languages
      |> normalize_languages(current_language)
      |> Enum.filter(fn lang ->
        translation_published_exact?(blog_slug, post, lang)
      end)

    # Remove legacy base code files when dialect files exist
    # e.g., if both "en" and "en-CA" exist, remove "en" to avoid duplicates
    deduplicated =
      deduplicate_base_and_dialect_files(available_and_published, enabled_languages)

    # Order: primary first (if present), then enabled languages, then disabled ones
    languages = order_languages_for_public(deduplicated, enabled_languages, primary_language)

    Enum.map(languages, fn lang ->
      # Use display_code helper to determine if we show base or full code
      display_code = Storage.get_display_code(lang, enabled_languages)
      is_enabled = language_enabled_for_public?(lang, enabled_languages)
      is_known = Languages.get_predefined_language(lang) != nil

      # Get the URL slug for this specific language
      # This enables SEO-friendly localized URLs (e.g., /es/docs/primeros-pasos)
      url_slug_for_lang = Map.get(language_slugs, lang, post.slug)
      post_with_url_slug = Map.put(post, :url_slug, url_slug_for_lang)

      # Build URL with version if viewing a specific version
      url =
        if version do
          PostRendering.build_version_url(blog_slug, post_with_url_slug, display_code, version)
        else
          PublishingHTML.build_post_url(blog_slug, post_with_url_slug, display_code)
        end

      %{
        code: display_code,
        display_code: display_code,
        name: Language.get_language_name(lang),
        flag: Language.get_language_flag(lang),
        url: url,
        current: DialectMapper.extract_base(lang) == current_base,
        enabled: is_enabled,
        known: is_known
      }
    end)
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Order languages for public display: primary first, then enabled, then disabled
  defp order_languages_for_public(languages, enabled_languages, primary_language) do
    {enabled, disabled} =
      Enum.split_with(languages, fn lang ->
        language_enabled_for_public?(lang, enabled_languages)
      end)

    # Put primary first if present
    {primary, other_enabled} = Enum.split_with(enabled, &(&1 == primary_language))

    primary ++ Enum.sort(other_enabled) ++ Enum.sort(disabled)
  end

  # Remove legacy base code files when dialect files of the same language exist
  # This prevents showing both "en" and "en-CA" in the switcher
  defp deduplicate_base_and_dialect_files(languages, _enabled_languages) do
    # Separate base codes and dialect codes
    {base_codes, dialect_codes} = Enum.split_with(languages, &Language.base_code?/1)

    # For each base code, check if any dialect files exist for it
    # If so, exclude the base code
    filtered_base_codes =
      Enum.reject(base_codes, fn base ->
        Enum.any?(dialect_codes, fn dialect ->
          DialectMapper.extract_base(dialect) == base
        end)
      end)

    # Return dialect codes plus any base codes that don't have dialect alternatives
    dialect_codes ++ filtered_base_codes
  end

  # Fetches language_slugs map from cache for per-language URL slugs
  # Returns a map of language -> url_slug for each available language
  defp fetch_language_slugs_from_cache(blog_slug, post) do
    # Use appropriate cache lookup based on post mode
    cache_result = find_cached_post(blog_slug, post)

    case cache_result do
      {:ok, cached_post} ->
        cached_post.language_slugs || %{}

      {:error, _} ->
        # Cache miss - return empty map (will fall back to post.slug)
        %{}
    end
  end

  # Find cached post using appropriate method based on post mode
  defp find_cached_post(blog_slug, post) do
    case Map.get(post, :mode) do
      :timestamp ->
        # For timestamp mode, use date/time lookup
        date = post[:date]
        time = post[:time]

        if date && time do
          date_str = if is_struct(date, Date), do: Date.to_iso8601(date), else: to_string(date)
          time_str = format_time_for_cache(time)
          ListingCache.find_post_by_path(blog_slug, date_str, time_str)
        else
          {:error, :not_found}
        end

      _ ->
        # For slug mode, use slug lookup
        ListingCache.find_post(blog_slug, post.slug)
    end
  end

  defp format_time_for_cache(%Time{} = time) do
    time |> Time.to_string() |> String.slice(0, 5)
  end

  defp format_time_for_cache(time) when is_binary(time), do: String.slice(time, 0, 5)
  defp format_time_for_cache(_), do: ""

  defp normalize_languages([], current_language), do: [current_language]
  defp normalize_languages(languages, _current_language) when is_list(languages), do: languages

  # Strict check for public display - only shows files that are:
  # 1. Directly in the enabled languages list, OR
  # 2. Base code files where any dialect of that base is enabled
  # This prevents showing en-US, en-GB etc when only en-CA is enabled
  defp language_enabled_for_public?(language, enabled_languages) do
    cond do
      # Direct match - file code exactly matches an enabled language
      language in enabled_languages ->
        true

      # Base code file (e.g., "en") - show if any dialect is enabled
      Language.base_code?(language) ->
        Enum.any?(enabled_languages, fn enabled_lang ->
          DialectMapper.extract_base(enabled_lang) == language
        end)

      # Dialect file (e.g., "en-US") not directly enabled - DON'T show
      # This is the key difference from language_enabled?
      true ->
        false
    end
  end

  # Checks if the exact language file exists and is published
  # Uses preloaded language_statuses map to avoid redundant file reads
  defp translation_published_exact?(_blog_slug, post, language) do
    language in (post.available_languages || []) and
      Map.get(post.language_statuses, language) == "published"
  end
end
