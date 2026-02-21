defmodule PhoenixKit.Modules.Publishing.Web.HTML do
  @moduledoc """
  HTML rendering functions for Publishing.Web.Controller.
  """
  use PhoenixKitWeb, :html

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage, as: PublishingStorage

  # Import publishing-specific components for templates
  import PhoenixKit.Modules.Publishing.Web.Components.LanguageSwitcher

  embed_templates("templates/*")

  @doc """
  Builds the public URL for a group listing page.
  When multiple languages are enabled, always includes locale prefix.
  When languages module is off or only one language, uses clean URLs.
  """
  def group_listing_path(language, group_slug, params \\ []) do
    segments =
      if single_language_mode?(), do: [group_slug], else: [language, group_slug]

    base_path = build_public_path(segments)

    case params do
      [] -> base_path
      _ -> base_path <> "?" <> URI.encode_query(params)
    end
  end

  @doc """
  Builds a post URL based on mode.
  When multiple languages are enabled, always includes locale prefix.
  When languages module is off or only one language, uses clean URLs.

  For slug mode posts, uses the language-specific URL slug (from post.url_slug
  or post.language_slugs[language]) for SEO-friendly localized URLs.

  For timestamp mode posts:
  - If only one post exists on the date, uses date-only URL (e.g., /group/2025-12-09)
  - If multiple posts exist on the date, includes time (e.g., /group/2025-12-09/16:26)
  """
  def build_post_url(group_slug, post, language) do
    case post.mode do
      :slug ->
        # Use language-specific URL slug for SEO-friendly localized URLs
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if single_language_mode?(),
            do: [group_slug, url_slug],
            else: [language, group_slug, url_slug]

        build_public_path(segments)

      :timestamp ->
        # For timestamp mode, use the date/time from the directory structure
        # (stored in post.date and post.time), not from metadata.published_at
        date = get_timestamp_date(post)

        # Check if we need time in URL (only if multiple posts on same date)
        post_count = count_posts_on_date(group_slug, date)

        segments =
          if post_count > 1 do
            # Multiple posts - include time
            time = get_timestamp_time(post)

            if single_language_mode?(),
              do: [group_slug, date, time],
              else: [language, group_slug, date, time]
          else
            # Single post or no posts - date only
            if single_language_mode?(),
              do: [group_slug, date],
              else: [language, group_slug, date]
          end

        build_public_path(segments)

      _ ->
        # Use language-specific URL slug for fallback mode as well
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if single_language_mode?(),
            do: [group_slug, url_slug],
            else: [language, group_slug, url_slug]

        build_public_path(segments)
    end
  end

  # Gets the URL slug for a specific language
  # Priority:
  # 1. Direct url_slug field on post (set by controller for specific language)
  # 2. language_slugs map (from cache, contains all languages)
  # 3. metadata.url_slug (from file, current language only)
  # 4. post.slug (directory name fallback)
  defp get_url_slug_for_language(post, language) do
    cond do
      # Direct url_slug on post (highest priority, set by controller)
      Map.get(post, :url_slug) not in [nil, ""] ->
        post.url_slug

      # language_slugs map from cache
      map_size(Map.get(post, :language_slugs, %{})) > 0 ->
        Map.get(post.language_slugs, language, post.slug)

      # metadata.url_slug
      is_map(Map.get(post, :metadata)) and Map.get(post.metadata, :url_slug) not in [nil, ""] ->
        post.metadata.url_slug

      # Default to directory slug
      true ->
        post.slug
    end
  end

  @doc """
  Builds a public path with explicit date and time (always includes time).
  Used when redirecting from date-only URLs to full timestamp URLs.
  """
  def build_public_path_with_time(language, group_slug, date, time) do
    segments =
      if single_language_mode?(),
        do: [group_slug, date, time],
        else: [language, group_slug, date, time]

    build_public_path(segments)
  end

  @doc """
  Formats a date for display using locale-aware month names.
  """
  def format_date(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> locale_strftime(gettext("%B %d, %Y"))
  end

  def format_date(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_date()
        |> locale_strftime(gettext("%B %d, %Y"))

      _ ->
        datetime_string
    end
  end

  def format_date(_), do: ""

  @doc """
  Formats a date with time for display.
  Used when multiple posts exist on the same date.
  """
  def format_date_with_time(datetime) when is_struct(datetime, DateTime) do
    date_str = locale_strftime(datetime, gettext("%B %d, %Y"))
    time_str = Calendar.strftime(datetime, "%H:%M")
    gettext("%{date} at %{time}", date: date_str, time: time_str)
  end

  def format_date_with_time(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        date_str = locale_strftime(datetime, gettext("%B %d, %Y"))
        time_str = Calendar.strftime(datetime, "%H:%M")
        gettext("%{date} at %{time}", date: date_str, time: time_str)

      _ ->
        datetime_string
    end
  end

  def format_date_with_time(_), do: ""

  @doc """
  Checks if a post has a publication date to display.
  For timestamp mode, the date comes from the directory structure.
  For slug mode, it comes from metadata.published_at.
  """
  def has_publication_date?(post) do
    case post.mode do
      :timestamp ->
        # Timestamp mode always has a date (from directory structure)
        post[:date] != nil

      _ ->
        # Slug mode uses metadata.published_at
        published_at = get_in(post, [:metadata, :published_at])
        published_at != nil and published_at != ""
    end
  end

  @doc """
  Formats a post's publication date, including time only when multiple posts exist on the same date.
  """
  def format_post_date(post, group_slug) do
    case post.mode do
      :timestamp ->
        # For timestamp mode, use date/time from directory structure
        date = get_timestamp_date(post)
        post_count = count_posts_on_date(group_slug, date)

        if post_count > 1 do
          format_timestamp_date_with_time(post)
        else
          format_timestamp_date(post)
        end

      _ ->
        format_date(post.metadata.published_at)
    end
  end

  @doc """
  Formats a date for URL.
  """
  def format_date_for_url(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  def format_date_for_url(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_date()
        |> Date.to_iso8601()

      _ ->
        "2025-01-01"
    end
  end

  def format_date_for_url(_), do: "2025-01-01"

  @doc """
  Formats time for URL (HH:MM).
  """
  def format_time_for_url(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
    |> String.slice(0..4)
  end

  def format_time_for_url(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_time()
        |> Time.truncate(:second)
        |> Time.to_string()
        |> String.slice(0..4)

      _ ->
        "00:00"
    end
  end

  def format_time_for_url(_), do: "00:00"

  @doc """
  Pluralizes a word based on count.
  """
  def pluralize(1, singular, _plural), do: "1 #{singular}"
  def pluralize(count, _singular, plural), do: "#{count} #{plural}"

  @doc """
  Extracts and renders an excerpt from post content.
  Returns content before <!-- more --> tag, or first paragraph if no tag.
  Renders markdown and strips HTML tags for plain text display.
  """
  def extract_excerpt(content) when is_binary(content) do
    excerpt_markdown =
      if String.contains?(content, "<!-- more -->") do
        # Extract content before <!-- more --> tag
        content
        |> String.split("<!-- more -->")
        |> List.first()
        |> String.trim()
      else
        # Get first paragraph (content before first double newline)
        content
        |> String.split(~r/\n\s*\n/, parts: 2)
        |> List.first()
        |> String.trim()
      end

    # Render markdown to HTML
    html = Renderer.render_markdown(excerpt_markdown)

    # Strip HTML tags to get plain text
    html
    |> Phoenix.HTML.raw()
    |> Phoenix.HTML.safe_to_string()
    |> strip_html_tags()
    |> String.trim()
  end

  def extract_excerpt(_), do: ""

  defp strip_html_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Formats a timestamp post's date for display (e.g., "December 31, 2025")
  defp format_timestamp_date(post) do
    cond do
      is_struct(post[:date], Date) ->
        locale_strftime(post.date, gettext("%B %d, %Y"))

      is_binary(post[:date]) ->
        case Date.from_iso8601(post.date) do
          {:ok, date} -> locale_strftime(date, gettext("%B %d, %Y"))
          _ -> post.date
        end

      true ->
        format_date(post.metadata.published_at)
    end
  end

  # Formats a timestamp post's date with time for display (e.g., "December 31, 2025 at 03:42")
  defp format_timestamp_date_with_time(post) do
    date_str = format_timestamp_date(post)
    time_str = get_timestamp_time(post)
    gettext("%{date} at %{time}", date: date_str, time: time_str)
  end

  # Gets the date for a timestamp-mode post from post.date field (directory structure)
  # Falls back to metadata.published_at if post.date not available
  defp get_timestamp_date(post) do
    cond do
      # Use post.date from directory structure (e.g., Date struct or "2025-12-31")
      is_struct(post[:date], Date) ->
        Date.to_iso8601(post.date)

      is_binary(post[:date]) ->
        post.date

      # Fallback to metadata.published_at if no post.date
      true ->
        format_date_for_url(post.metadata.published_at)
    end
  end

  # Gets the time for a timestamp-mode post from post.time field (directory structure)
  # Falls back to metadata.published_at if post.time not available
  defp get_timestamp_time(post) do
    cond do
      # Use post.time from directory structure (e.g., "03:42" or ~T[03:42:00])
      is_struct(post[:time], Time) ->
        post.time |> Time.to_string() |> String.slice(0..4)

      is_binary(post[:time]) ->
        # Ensure format is HH:MM (5 chars)
        String.slice(post.time, 0..4)

      # Fallback to metadata.published_at if no post.time
      true ->
        format_time_for_url(post.metadata.published_at)
    end
  end

  defp build_public_path(segments) do
    parts =
      url_prefix_segments() ++
        (segments
         |> Enum.reject(&(&1 in [nil, ""]))
         |> Enum.map(&to_string/1))

    case parts do
      [] -> "/"
      _ -> "/" <> Enum.join(parts, "/")
    end
  end

  defp url_prefix_segments do
    Config.get_url_prefix()
    |> case do
      "/" -> []
      prefix -> prefix |> String.trim("/") |> String.split("/", trim: true)
    end
  end

  # Check if we're in single language mode (no locale prefix needed)
  # Returns true when languages module is off OR only one language is enabled
  defp single_language_mode? do
    not Languages.enabled?() or length(Languages.get_enabled_languages()) <= 1
  end

  # Counts posts on a given date for a group
  # Used to determine if time should be included in URLs
  defp count_posts_on_date(group_slug, date) do
    PublishingStorage.count_posts_on_date(group_slug, date)
  end

  @doc """
  Resolves a featured image URL for a post, falling back to the original variant.
  """
  def featured_image_url(post, variant \\ "medium") do
    post.metadata
    |> Map.get(:featured_image_id)
    |> resolve_featured_image_url(variant)
  end

  defp resolve_featured_image_url(nil, _variant), do: nil
  defp resolve_featured_image_url("", _variant), do: nil

  defp resolve_featured_image_url(file_id, variant) when is_binary(file_id) do
    PhoenixKit.Modules.Storage.get_public_url_by_id(file_id, variant) ||
      PhoenixKit.Modules.Storage.get_public_url_by_id(file_id)
  rescue
    _ -> nil
  end

  @doc """
  Builds language data for the publishing_language_switcher component on public pages.
  Converts the @translations assign to the format expected by the component.
  """
  def build_public_translations(translations, _current_language) do
    Enum.map(translations, fn translation ->
      %{
        code: translation[:code] || translation.code,
        display_code: translation[:display_code] || translation[:code] || translation.code,
        name: translation[:name] || translation.name,
        flag: translation[:flag] || "",
        url: translation[:url] || translation.url,
        status: "published",
        exists: true
      }
    end)
  end

  # Locale-aware Calendar.strftime that translates month names via gettext.
  # The format string itself can also be translated (e.g., "%d %B %Y" for day-first locales).
  defp locale_strftime(date_or_datetime, format) do
    Calendar.strftime(date_or_datetime, format,
      month_names: fn month ->
        Enum.at(translated_month_names(), month - 1)
      end,
      abbreviated_month_names: fn month ->
        Enum.at(translated_abbreviated_month_names(), month - 1)
      end
    )
  end

  defp translated_month_names do
    [
      gettext("January"),
      gettext("February"),
      gettext("March"),
      gettext("April"),
      gettext("May"),
      gettext("June"),
      gettext("July"),
      gettext("August"),
      gettext("September"),
      gettext("October"),
      gettext("November"),
      gettext("December")
    ]
  end

  defp translated_abbreviated_month_names do
    [
      gettext("Jan"),
      gettext("Feb"),
      gettext("Mar"),
      gettext("Apr"),
      gettext("May"),
      gettext("Jun"),
      gettext("Jul"),
      gettext("Aug"),
      gettext("Sep"),
      gettext("Oct"),
      gettext("Nov"),
      gettext("Dec")
    ]
  end
end
