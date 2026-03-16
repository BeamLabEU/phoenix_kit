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
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
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

  # Post not found (trashed/deleted) — go straight to group listing, don't try other posts
  defp handle_fallback_case(:not_found, [group_slug | _], language) do
    if group_exists?(group_slug) do
      {:ok, PublishingHTML.group_listing_path(language, group_slug)}
    else
      fallback_to_default_group(language)
    end
  end

  # Slug mode posts (2-element path) - try other languages, then group listing
  defp handle_fallback_case(reason, [group_slug, post_slug], language)
       when reason in [:post_not_found, :unpublished, :version_access_disabled] do
    fallback_to_default_language(group_slug, post_slug, language)
  end

  # Timestamp mode posts (3-element path) - try other languages, then group listing
  defp handle_fallback_case(reason, [group_slug, date, time], language)
       when reason in [:post_not_found, :unpublished, :version_access_disabled] do
    fallback_timestamp_to_other_language(group_slug, date, time, language)
  end

  # Group not found with a path - try default group
  defp handle_fallback_case(:group_not_found, [_group_slug | _], language) do
    fallback_to_default_group(language)
  end

  defp handle_fallback_case(:group_not_found, [], language) do
    fallback_to_default_group(language)
  end

  # Any post-level error with a 2+ segment path — fall back to group listing
  # Catches errors like :invalid_version, unknown reasons from read_post, etc.
  defp handle_fallback_case(_reason, [group_slug | _rest], language) do
    if group_exists?(group_slug) do
      {:ok, PublishingHTML.group_listing_path(language, group_slug)}
    else
      fallback_to_default_group(language)
    end
  end

  defp handle_fallback_case(_reason, _path, _language), do: :no_fallback

  # ============================================================================
  # Slug Mode Fallback
  # ============================================================================

  defp fallback_to_default_language(group_slug, post_slug, requested_language) do
    if group_exists?(group_slug) do
      find_any_available_language_version(group_slug, post_slug, requested_language)
    else
      fallback_to_default_group(requested_language)
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
    versions = Publishing.list_versions(group_slug, post_slug)

    published_version =
      versions
      |> Enum.sort(:desc)
      |> Enum.find(fn version ->
        Publishing.get_version_status(group_slug, post_slug, version, language) == "published"
      end)

    case published_version do
      nil -> :not_found
      version -> {:ok, version}
    end
  end

  # Tries other languages when requested language has no published versions
  # Cap on how many languages to try in fallback chain to prevent excessive DB queries
  @max_fallback_languages 5

  defp try_other_languages(group_slug, post_slug, post, requested_language, default_lang) do
    available = post.available_languages || []

    # Build priority list: default first, then others (excluding already-tried language)
    languages_to_try =
      ([default_lang | available] -- [requested_language])
      |> Enum.uniq()
      |> Enum.take(@max_fallback_languages)

    find_first_published_version(group_slug, post_slug, post, languages_to_try, default_lang)
  end

  # Finds a post by its slug using a direct DB query
  defp find_post_by_slug(group_slug, post_slug) do
    case DBStorage.read_post(group_slug, post_slug) do
      {:ok, post} -> {:ok, post}
      {:error, _} -> :not_found
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
      # Use DB to get available languages for this timestamp post
      available = get_available_languages_for_timestamp(group_slug, date, time)

      # Time exists with language content - try other languages
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
      fallback_to_default_group(requested_language)
    end
  end

  # Fallback to another time on the same date
  defp fallback_to_other_time_on_date(group_slug, date, exclude_time, default_lang) do
    case Publishing.list_times_on_date(group_slug, date) do
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
      available = get_available_languages_for_timestamp(group_slug, date, time)

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
  """
  def find_first_published_timestamp_version(group_slug, date, time, languages) do
    identifier = "#{date}/#{time}"

    Enum.find_value(languages, fn lang ->
      case Publishing.read_post(group_slug, identifier, lang) do
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

  # Gets available languages for a timestamp post using a direct DB query
  defp get_available_languages_for_timestamp(group_slug, date, time) do
    parsed_date = parse_date(date)
    parsed_time = parse_time(time)

    if parsed_date && parsed_time do
      case DBStorage.read_post_by_datetime(group_slug, parsed_date, parsed_time) do
        {:ok, post} -> post.available_languages || []
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp parse_date(%Date{} = d), do: d

  defp parse_date(d) when is_binary(d) do
    case Date.from_iso8601(d) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp parse_time(%Time{} = t), do: t

  defp parse_time(t) when is_binary(t) do
    case String.split(t, ":") do
      [h, m | _] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m) do
          case Time.new(hour, minute, 0) do
            {:ok, time} -> time
            _ -> nil
          end
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_time(_), do: nil
end
