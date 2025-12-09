defmodule PhoenixKitWeb.BlogHTML do
  @moduledoc """
  HTML rendering functions for BlogController.
  """
  use PhoenixKitWeb, :html

  alias PhoenixKit.Blogging.Renderer
  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Storage

  embed_templates("blog_html/*")

  @doc """
  Builds the public URL for a blog listing page.
  When multiple languages are enabled, always includes locale prefix.
  When languages module is off or only one language, uses clean URLs.
  """
  def blog_listing_path(language, blog_slug, params \\ []) do
    segments =
      if single_language_mode?(), do: [blog_slug], else: [language, blog_slug]

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

  For timestamp mode posts:
  - If only one post exists on the date, uses date-only URL (e.g., /blog/2025-12-09)
  - If multiple posts exist on the date, includes time (e.g., /blog/2025-12-09/16:26)
  """
  def build_post_url(blog_slug, post, language) do
    case post.mode do
      :slug ->
        segments =
          if single_language_mode?(),
            do: [blog_slug, post.slug],
            else: [language, blog_slug, post.slug]

        build_public_path(segments)

      :timestamp ->
        date = format_date_for_url(post.metadata.published_at)

        # Check if we need time in URL (only if multiple posts on same date)
        post_count = count_posts_on_date(blog_slug, date)

        segments =
          if post_count > 1 do
            # Multiple posts - include time
            time = format_time_for_url(post.metadata.published_at)

            if single_language_mode?(),
              do: [blog_slug, date, time],
              else: [language, blog_slug, date, time]
          else
            # Single post or no posts - date only
            if single_language_mode?(),
              do: [blog_slug, date],
              else: [language, blog_slug, date]
          end

        build_public_path(segments)

      _ ->
        segments =
          if single_language_mode?(),
            do: [blog_slug, post.slug],
            else: [language, blog_slug, post.slug]

        build_public_path(segments)
    end
  end

  @doc """
  Builds a public path with explicit date and time (always includes time).
  Used when redirecting from date-only URLs to full timestamp URLs.
  """
  def build_public_path_with_time(language, blog_slug, date, time) do
    segments =
      if single_language_mode?(),
        do: [blog_slug, date, time],
        else: [language, blog_slug, date, time]

    build_public_path(segments)
  end

  @doc """
  Formats a date for display.
  """
  def format_date(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> Calendar.strftime("%B %d, %Y")
  end

  def format_date(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_date()
        |> Calendar.strftime("%B %d, %Y")

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
    Calendar.strftime(datetime, "%B %d, %Y at %H:%M")
  end

  def format_date_with_time(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        Calendar.strftime(datetime, "%B %d, %Y at %H:%M")

      _ ->
        datetime_string
    end
  end

  def format_date_with_time(_), do: ""

  @doc """
  Formats a post's publication date, including time only when multiple posts exist on the same date.
  """
  def format_post_date(post, blog_slug) do
    case post.mode do
      :timestamp ->
        date = format_date_for_url(post.metadata.published_at)
        post_count = count_posts_on_date(blog_slug, date)

        if post_count > 1 do
          format_date_with_time(post.metadata.published_at)
        else
          format_date(post.metadata.published_at)
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

  # Counts posts on a given date for a blog
  # Used to determine if time should be included in URLs
  defp count_posts_on_date(blog_slug, date) do
    alias PhoenixKitWeb.Live.Modules.Blogging.Storage
    Storage.count_posts_on_date(blog_slug, date)
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
    Storage.get_public_url_by_id(file_id, variant) ||
      Storage.get_public_url_by_id(file_id)
  rescue
    _ -> nil
  end

  @doc """
  Builds language data for the blog_language_switcher component on public pages.
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
end
