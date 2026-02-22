defmodule PhoenixKit.Modules.Publishing.Web.Controller.Language do
  @moduledoc """
  Language detection and resolution for the publishing controller.

  Handles detecting whether URL parameters represent language codes,
  resolving language codes to file languages, and determining
  canonical URL language codes.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Storage

  # ============================================================================
  # Language Detection
  # ============================================================================

  @doc """
  Detects whether the 'language' parameter is actually a language code or a group slug.

  This allows the same route pattern (/:language/:group/*path) to work for both:
  - Multi-language: /en/my-group/my-post (language=en, group=my-group)
  - Single-language: /my-group/my-post (language=my-group, needs adjustment)

  Returns {detected_language, adjusted_params}
  """
  def detect_language_or_group(language_param, params) do
    # First check if it's a known/predefined language
    # Then check if content exists for this language in the group (handles unknown languages like "af")
    group_slug = params["group"]

    cond do
      # Known/predefined language - use as-is
      valid_language?(language_param) ->
        {language_param, params}

      # Unknown language code but content exists for it in this group
      # This handles files like af.phk, test.phk, etc.
      group_slug && has_content_for_language?(group_slug, language_param) ->
        {language_param, params}

      # Not a language - shift parameters (group slug in language position)
      true ->
        default_language = get_default_language()

        adjusted_params =
          case params do
            # Pattern: %{"language" => group_slug, "group" => first_path_segment, "path" => rest}
            %{"group" => first_segment, "path" => rest} when is_list(rest) ->
              %{"group" => language_param, "path" => [first_segment | rest]}

            # Pattern: %{"language" => group_slug, "group" => first_path_segment}
            %{"group" => first_segment} ->
              %{"group" => language_param, "path" => [first_segment]}

            # Pattern: %{"language" => group_slug} (just listing)
            _ ->
              %{"group" => language_param}
          end

        {default_language, adjusted_params}
    end
  end

  @doc """
  Detects if the :group route param is actually a language code by checking if content exists.

  Returns {:language_detected, language, adjusted_params} or :not_a_language
  """
  def detect_language_in_group_param(
        %{"group" => potential_lang, "path" => [_ | _] = path} = _params
      )
      when is_binary(potential_lang) do
    [actual_group | rest_path] = path

    group_exists = group_exists?(actual_group)
    has_content = has_content_for_language?(actual_group, potential_lang)

    # Check if there's a group with slug matching actual_group
    # AND if there's content for potential_lang in that group
    if group_exists and has_content do
      adjusted_params = %{"group" => actual_group, "path" => rest_path}
      {:language_detected, potential_lang, adjusted_params}
    else
      :not_a_language
    end
  end

  def detect_language_in_group_param(_params), do: :not_a_language

  # ============================================================================
  # Language Validation
  # ============================================================================

  @doc """
  Validates if a code represents a valid language.
  """
  def valid_language?(code) when is_binary(code) do
    # Check if it's a language code pattern (enabled, disabled, or even unknown)
    # This allows access to legacy content in disabled languages
    cond do
      # Enabled language - definitely valid
      Languages.language_enabled?(code) ->
        true

      # Base code that maps to an enabled dialect
      String.length(code) == 2 and not String.contains?(code, "-") ->
        dialect = DialectMapper.base_to_dialect(code)

        if Languages.language_enabled?(dialect) do
          true
        else
          # Even if disabled, it's still a valid language code pattern
          # Check if it's a known language
          Languages.get_predefined_language(dialect) != nil
        end

      # Known but disabled language (full dialect like "fr-FR")
      Languages.get_predefined_language(code) != nil ->
        true

      # Check if it looks like a language code pattern (XX or XX-XX format)
      # This allows access to unknown files like legacy imports
      looks_like_language_code?(code) ->
        true

      true ->
        false
    end
  rescue
    _ -> false
  end

  def valid_language?(_), do: false

  @doc """
  Checks if a string looks like a language code pattern.
  Matches: 2-letter codes (en, fr), or dialect codes (en-US, pt-BR)
  """
  def looks_like_language_code?(code) when is_binary(code) do
    # 2-letter base code
    # Dialect code pattern (xx-XX or xx-XXX)
    (String.length(code) == 2 and String.match?(code, ~r/^[a-z]{2}$/i)) or
      String.match?(code, ~r/^[a-z]{2,3}-[A-Za-z]{2,4}$/i)
  end

  # ============================================================================
  # Language Resolution
  # ============================================================================

  @doc """
  Resolves a language code to an actual file language.
  Handles base codes by finding a matching dialect in available languages.
  """
  def resolve_language_for_post(language, available_languages) do
    cond do
      # Direct match - language exactly matches an available file
      language in available_languages ->
        language

      # Base code - try to find a dialect that matches
      base_code?(language) ->
        find_dialect_for_base_in_files(language, available_languages) ||
          DialectMapper.base_to_dialect(language)

      # Full dialect code not found - try base code match as fallback
      true ->
        base = DialectMapper.extract_base(language)
        find_dialect_for_base_in_files(base, available_languages) || language
    end
  end

  @doc """
  Find a dialect in available files that matches the given base code.
  """
  def find_dialect_for_base_in_files(base_code, available_languages) do
    base_lower = String.downcase(base_code)

    Enum.find(available_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  # ============================================================================
  # Canonical URL Language
  # ============================================================================

  @doc """
  Gets the canonical URL language code for a given language.
  If multiple dialects of the same base language are enabled, returns the full dialect.
  Otherwise returns the base code for cleaner URLs.
  """
  def get_canonical_url_language(language) do
    enabled_languages = get_enabled_languages()

    # Resolve base code to a specific dialect if needed
    resolved_language =
      if base_code?(language) do
        # Find the matching dialect in enabled languages
        find_dialect_for_base(language, enabled_languages) || language
      else
        language
      end

    # Now determine if we should use base or full dialect code
    Storage.get_display_code(resolved_language, enabled_languages)
  end

  @doc """
  Gets the canonical URL language code for a post's language.
  This uses the actual file language (e.g., "en-US") to determine the canonical URL code.
  """
  def get_canonical_url_language_for_post(post_language) do
    enabled_languages = get_enabled_languages()
    Storage.get_display_code(post_language, enabled_languages)
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Gets the list of enabled language codes.
  """
  def get_enabled_languages do
    Languages.enabled_locale_codes()
  rescue
    _ -> ["en"]
  end

  @doc """
  Checks if a code is a base (2-letter) language code.
  """
  def base_code?(code) when is_binary(code) do
    String.length(code) == 2 and not String.contains?(code, "-")
  end

  def base_code?(_), do: false

  @doc """
  Find a dialect in enabled languages that matches the given base code.
  """
  def find_dialect_for_base(base_code, enabled_languages) do
    base_lower = String.downcase(base_code)

    Enum.find(enabled_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  @doc """
  Gets the default language.
  """
  def get_default_language do
    case Languages.get_default_language() do
      %{"code" => code} -> code
      _ -> "en"
    end
  end

  @doc """
  Gets a language's display name.
  """
  def get_language_name(code) do
    case Languages.get_language(code) do
      %{"name" => name} -> name
      _ -> String.upcase(code)
    end
  end

  @doc """
  Gets a language's flag emoji.
  """
  def get_language_flag(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      _ -> "🌐"
    end
  end

  # ============================================================================
  # Content Checks
  # ============================================================================

  @doc """
  Check if any post in the group has content for the given language.
  Uses listing cache when available for fast lookups.
  """
  def has_content_for_language?(group_slug, language) do
    # Try cache first for fast lookup
    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        Enum.any?(posts, fn post ->
          language in (post.available_languages || [])
        end)

      {:error, _} ->
        # Cache miss - fall back to filesystem scan
        posts = Publishing.list_posts(group_slug, nil)

        Enum.any?(posts, fn post ->
          language in (post.available_languages || [])
        end)
    end
  rescue
    _ -> false
  end

  defp group_exists?(group_slug) do
    case Enum.find(Publishing.list_groups(), fn group ->
           case group["slug"] do
             slug when is_binary(slug) ->
               String.downcase(slug) == String.downcase(to_string(group_slug))

             _ ->
               false
           end
         end) do
      nil -> false
      _ -> true
    end
  end
end
