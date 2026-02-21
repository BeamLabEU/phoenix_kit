defmodule PhoenixKit.Modules.Publishing.Web.Controller.Fallback do
  @moduledoc """
  404 fallback handling for the publishing controller.

  Implements a smart fallback chain that attempts to redirect users
  to related content when the requested resource is not found:
  - Posts in other languages
  - Other posts on the same date
  - Group listing page
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostFetching
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  # ============================================================================
  # Main Entry Point
  # ============================================================================

  @doc """
  Handles 404 not found responses with smart fallback.
  """
  def handle_not_found(conn, reason) do
    # Try to fall back to nearest valid parent in the breadcrumb chain
    case attempt_breadcrumb_fallback(conn, reason) do
      {:ok, redirect_path} ->
        {:redirect_with_flash, redirect_path,
         gettext("The page you requested was not found. Showing closest match.")}

      :no_fallback ->
        {:render_404}
    end
  end

  # ============================================================================
  # Breadcrumb Fallback Logic
  # ============================================================================

  defp attempt_breadcrumb_fallback(conn, reason) do
    language = conn.assigns[:current_language] || "en"
    group_slug = conn.params["group"]
    path = conn.params["path"] || []

    # Build full path including group slug for proper fallback handling
    # Route params are: %{"group" => "date", "path" => ["2025-12-09", "15:02"]}
    # We need: ["date", "2025-12-09", "15:02"] for pattern matching
    full_path = if group_slug, do: [group_slug | path], else: path

    handle_fallback_case(reason, full_path, language)
  end

  # ============================================================================
  # Fallback Case Handlers
  # ============================================================================

  # Slug mode posts (2-element path) - try other languages before group listing
  defp handle_fallback_case(reason, [group_slug, post_slug], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_to_default_language(group_slug, post_slug, language)
  end

  # Timestamp mode posts (3-element path) - try other languages before group listing
  defp handle_fallback_case(reason, [group_slug, date, time], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_timestamp_to_other_language(group_slug, date, time, language)
  end

  defp handle_fallback_case(:group_not_found, [_group_slug], language) do
    fallback_to_default_group(language)
  end

  defp handle_fallback_case(:group_not_found, [], language) do
    fallback_to_default_group(language)
  end

  defp handle_fallback_case(_reason, _path, _language), do: :no_fallback

  # ============================================================================
  # Slug Mode Fallback
  # ============================================================================

  defp fallback_to_default_language(group_slug, post_slug, requested_language) do
    if group_exists?(group_slug) do
      find_any_available_language_version(group_slug, post_slug, requested_language)
    else
      :no_fallback
    end
  end

  @doc """
  Tries to find any available published language version of the post.

  Priority:
  1. Check for published versions in the SAME language first (across all versions)
  2. Then try other languages
  3. Falls back to group listing if no published versions exist

  Note: fetch_post now handles finding the latest published version automatically,
  so we can just use base URLs here (no version-specific URLs needed)
  """
  def find_any_available_language_version(group_slug, post_slug, requested_language) do
    default_lang = Language.get_default_language()

    # Find the post in the group to get available languages
    case find_post_by_slug(group_slug, post_slug) do
      {:ok, post} ->
        # The initial fetch failed, so we know no published version exists for the requested_language.
        # Proceed directly to trying other available languages.
        try_other_languages(group_slug, post_slug, post, requested_language, default_lang)

      :not_found ->
        # Post doesn't exist at all - fall back to group listing
        {:ok, PublishingHTML.group_listing_path(default_lang, group_slug)}
    end
  end

  # Finds the latest published version for a specific language
  defp find_published_version_for_language(group_slug, post_slug, language) do
    versions = Storage.list_versions(group_slug, post_slug)

    published_version =
      versions
      |> Enum.sort(:desc)
      |> Enum.find(fn version ->
        Storage.get_version_status(group_slug, post_slug, version, language) == "published"
      end)

    case published_version do
      nil -> :not_found
      version -> {:ok, version}
    end
  end

  # Tries other languages when requested language has no published versions
  defp try_other_languages(group_slug, post_slug, post, requested_language, default_lang) do
    available = post.available_languages || []

    # Build priority list: default first, then others (excluding already-tried language)
    languages_to_try =
      ([default_lang | available] -- [requested_language])
      |> Enum.uniq()

    find_first_published_version(group_slug, post_slug, post, languages_to_try, default_lang)
  end

  # Finds a post by its slug from the group's post list
  defp find_post_by_slug(group_slug, post_slug) do
    posts = Publishing.list_posts(group_slug, nil)

    case Enum.find(posts, fn p -> p.slug == post_slug end) do
      nil -> :not_found
      post -> {:ok, post}
    end
  end

  # Tries each language in order until finding a published version
  # Uses find_published_version_for_language to check across all versions
  # fetch_post will automatically find the right version when the URL is visited
  defp find_first_published_version(group_slug, post_slug, post, languages, fallback_lang) do
    result =
      Enum.find_value(languages, fn lang ->
        # Check if any published version exists for this language
        case find_published_version_for_language(group_slug, post_slug, lang) do
          {:ok, _version} ->
            # Published version exists - use base URL
            # fetch_post will find the right version
            {:ok, PublishingHTML.build_post_url(group_slug, post, lang)}

          :not_found ->
            nil
        end
      end)

    # If no published version found, fall back to group listing
    result || {:ok, PublishingHTML.group_listing_path(fallback_lang, group_slug)}
  end

  # ============================================================================
  # Timestamp Mode Fallback
  # ============================================================================

  @doc """
  Fallback for timestamp mode posts - comprehensive fallback chain:
  1. Try other languages for the exact date/time
  2. If time doesn't exist, try other times on the same date
  3. If date has no posts, fall back to group listing
  """
  def fallback_timestamp_to_other_language(group_slug, date, time, requested_language) do
    default_lang = Language.get_default_language()

    if group_exists?(group_slug) do
      # Step 1: Try other languages for this exact time
      post_dir = Path.join([Storage.group_path(group_slug), date, time])
      # Use version-aware language detection (handles both versioned and legacy)
      available = PostFetching.detect_available_languages_in_timestamp_dir(post_dir)

      # Time exists with language files - try other languages
      if available != [] do
        languages_to_try =
          ([default_lang | available] -- [requested_language])
          |> Enum.uniq()

        case find_first_published_timestamp_version(group_slug, date, time, languages_to_try) do
          {:ok, url} ->
            {:ok, url}

          :not_found ->
            # No published version at this time - try other times on this date
            fallback_to_other_time_on_date(group_slug, date, time, default_lang)
        end
      else
        # Time doesn't exist - try other times on this date
        fallback_to_other_time_on_date(group_slug, date, time, default_lang)
      end
    else
      :no_fallback
    end
  end

  # Fallback to another time on the same date
  defp fallback_to_other_time_on_date(group_slug, date, exclude_time, default_lang) do
    case Storage.list_times_on_date(group_slug, date) do
      [] ->
        # No posts on this date at all - try other dates or fall back to group listing
        fallback_to_other_date(group_slug, default_lang)

      times ->
        # Filter out the time we already tried
        other_times = times -- [exclude_time]

        case find_first_published_time(group_slug, date, other_times, default_lang) do
          {:ok, url} ->
            {:ok, url}

          :not_found ->
            # No published posts on this date - try other dates
            fallback_to_other_date(group_slug, default_lang)
        end
    end
  end

  # No posts found on this date - fall back to group listing
  # The group listing will show all available posts
  defp fallback_to_other_date(group_slug, default_lang) do
    {:ok, PublishingHTML.group_listing_path(default_lang, group_slug)}
  end

  # Find the first published post at any of the given times
  defp find_first_published_time(group_slug, date, times, preferred_lang) do
    Enum.find_value(times, fn time ->
      post_dir = Path.join([Storage.group_path(group_slug), date, time])
      # Use version-aware language detection (handles both versioned and legacy)
      available = PostFetching.detect_available_languages_in_timestamp_dir(post_dir)

      if available != [] do
        # Try preferred language first, then others
        languages = [preferred_lang | available] |> Enum.uniq()

        case find_first_published_timestamp_version(group_slug, date, time, languages) do
          {:ok, url} -> {:ok, url}
          :not_found -> nil
        end
      else
        nil
      end
    end) || :not_found
  end

  @doc """
  Tries each language for timestamp mode until finding a published version.
  Handles both versioned and legacy structures.
  """
  def find_first_published_timestamp_version(group_slug, date, time, languages) do
    post_dir = Path.join([Storage.group_path(group_slug), date, time])

    case Storage.detect_post_structure(post_dir) do
      :versioned ->
        find_first_published_versioned_timestamp(group_slug, date, time, languages, post_dir)

      :legacy ->
        find_first_published_legacy_timestamp(group_slug, date, time, languages)

      :empty ->
        :not_found
    end
  end

  # Find first published post in versioned timestamp structure
  # Iterates versions from highest to lowest, then tries each language
  defp find_first_published_versioned_timestamp(group_slug, date, time, languages, post_dir) do
    versions = PostFetching.list_timestamp_versions(post_dir) |> Enum.sort(:desc)

    Enum.find_value(versions, fn version ->
      version_dir = Path.join(post_dir, "v#{version}")
      available_languages = PostFetching.detect_available_languages_in_dir(version_dir)

      # Try preferred languages first, then fall back to what's available
      languages_to_try =
        (languages ++ available_languages)
        |> Enum.uniq()
        |> Enum.filter(&(&1 in available_languages))

      Enum.find_value(languages_to_try, fn lang ->
        path = "#{group_slug}/#{date}/#{time}/v#{version}/#{lang}.phk"

        case Publishing.read_post(group_slug, path) do
          {:ok, post} when post.metadata.status == "published" ->
            {:ok, build_timestamp_url(group_slug, date, time, lang)}

          _ ->
            nil
        end
      end)
    end) || :not_found
  end

  # Find first published post in legacy timestamp structure
  defp find_first_published_legacy_timestamp(group_slug, date, time, languages) do
    Enum.find_value(languages, fn lang ->
      path = "#{group_slug}/#{date}/#{time}/#{lang}.phk"

      case Publishing.read_post(group_slug, path) do
        {:ok, post} when post.metadata.status == "published" ->
          {:ok, build_timestamp_url(group_slug, date, time, lang)}

        _ ->
          nil
      end
    end) || :not_found
  end

  # ============================================================================
  # Group Fallback
  # ============================================================================

  defp fallback_to_default_group(language) do
    case Listing.default_group_listing(language) do
      nil -> :no_fallback
      path -> {:ok, path}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp group_exists?(group_slug) do
    case Listing.fetch_group(group_slug) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp build_timestamp_url(group_slug, date, time, language) do
    PublishingHTML.build_public_path_with_time(language, group_slug, date, time)
  end
end
