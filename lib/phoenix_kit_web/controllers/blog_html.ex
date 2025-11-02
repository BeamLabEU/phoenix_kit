defmodule PhoenixKitWeb.BlogHTML do
  @moduledoc """
  HTML rendering functions for BlogController.
  """
  use PhoenixKitWeb, :html

  embed_templates "blog_html/*"

  @doc """
  Builds a post URL based on mode.
  """
  def build_post_url(blog_slug, post, language) do
    case post.mode do
      :slug ->
        "/#{language}/blog/#{blog_slug}/#{post.slug}"

      :timestamp ->
        date = format_date_for_url(post.metadata.published_at)
        time = format_time_for_url(post.metadata.published_at)
        "/#{language}/blog/#{blog_slug}/#{date}/#{time}"

      _ ->
        "/#{language}/blog/#{blog_slug}/#{post.slug}"
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
end
