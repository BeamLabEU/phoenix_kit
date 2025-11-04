defmodule PhoenixKitWeb.BlogHTML do
  @moduledoc """
  HTML rendering functions for BlogController.
  """
  use PhoenixKitWeb, :html

  alias PhoenixKit.Config

  embed_templates "blog_html/*"

  @doc """
  Builds the public URL for a blog listing page.
  """
  def blog_listing_path(language, blog_slug, params \\ []) do
    segments = if single_language_mode?(), do: [blog_slug], else: [language, blog_slug]
    base_path = build_public_path(segments)

    case params do
      [] -> base_path
      _ -> base_path <> "?" <> URI.encode_query(params)
    end
  end

  @doc """
  Builds a post URL based on mode.
  """
  def build_post_url(blog_slug, post, language) do
    case post.mode do
      :slug ->
        segments = if single_language_mode?(), do: [blog_slug, post.slug], else: [language, blog_slug, post.slug]
        build_public_path(segments)

      :timestamp ->
        date = format_date_for_url(post.metadata.published_at)
        time = format_time_for_url(post.metadata.published_at)
        segments = if single_language_mode?(), do: [blog_slug, date, time], else: [language, blog_slug, date, time]
        build_public_path(segments)

      _ ->
        segments = if single_language_mode?(), do: [blog_slug, post.slug], else: [language, blog_slug, post.slug]
        build_public_path(segments)
    end
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
  Formats a date for URL.
  """
  def format_date_for_url(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601()
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
      cond do
        # Check for <!-- more --> tag
        String.contains?(content, "<!-- more -->") ->
          content
          |> String.split("<!-- more -->")
          |> List.first()
          |> String.trim()

        # Otherwise, get first paragraph (content before first double newline)
        true ->
          content
          |> String.split(~r/\n\s*\n/, parts: 2)
          |> List.first()
          |> String.trim()
      end

    # Render markdown to HTML
    html = PhoenixKit.Blogging.Renderer.render_markdown(excerpt_markdown)

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

  defp single_language_mode? do
    enabled_count =
      try do
        PhoenixKit.Module.Languages.enabled_locale_codes()
        |> length()
      rescue
        _ -> 1
      end

    enabled_count == 1
  end
end
