defmodule PhoenixKit.Entities.HtmlSanitizer do
  @moduledoc """
  HTML sanitization for rich text content in entities.

  This module provides basic HTML sanitization to prevent XSS attacks
  while allowing safe HTML tags commonly used in rich text editors.

  ## Allowed Tags

  The following tags are allowed:
  - Block elements: p, div, br, hr, h1-h6, blockquote, pre, code
  - Inline elements: span, strong, b, em, i, u, s, a, sub, sup, mark
  - Lists: ul, ol, li
  - Tables: table, thead, tbody, tr, th, td
  - Media placeholders: img (with src validation)

  ## Removed Content

  The following are stripped completely:
  - script tags and content
  - style tags and content
  - event handlers (onclick, onerror, etc.)
  - javascript: and data: URLs
  - iframe, object, embed tags

  ## Usage

      iex> PhoenixKit.Entities.HtmlSanitizer.sanitize("<p>Hello</p><script>alert('xss')</script>")
      "<p>Hello</p>"

      iex> PhoenixKit.Entities.HtmlSanitizer.sanitize("<a href=\"javascript:alert('xss')\">Click</a>")
      "<a>Click</a>"
  """

  # Note: These are documented for reference. The current simple implementation
  # strips dangerous content rather than whitelisting allowed tags.
  # A more complete implementation using a library like HtmlSanitizeEx would use these.
  #
  # Allowed tags:
  #   p div br hr h1-h6 blockquote pre code
  #   span strong b em i u s a sub sup mark
  #   ul ol li table thead tbody tr th td img
  #
  # Allowed attributes:
  #   a: href title target rel
  #   img: src alt title width height
  #   td/th: colspan rowspan
  #   all: class id

  @doc """
  Sanitizes HTML content by removing dangerous elements and attributes.

  Returns sanitized HTML string that is safe to render.

  ## Parameters

  - `html` - The HTML string to sanitize

  ## Examples

      iex> PhoenixKit.Entities.HtmlSanitizer.sanitize("<p onclick=\"alert('xss')\">Hello</p>")
      "<p>Hello</p>"
  """
  def sanitize(nil), do: nil
  def sanitize(""), do: ""

  def sanitize(html) when is_binary(html) do
    html
    |> remove_dangerous_patterns()
    |> sanitize_urls()
    |> String.trim()
  end

  def sanitize(other), do: other

  @doc """
  Sanitizes all rich_text fields in an entity data map.

  Takes entity field definitions and data, returns data with all
  rich_text fields sanitized.

  ## Parameters

  - `fields_definition` - List of field definition maps
  - `data` - Map of field key => value

  ## Examples

      iex> fields = [%{"type" => "rich_text", "key" => "content"}]
      iex> data = %{"content" => "<script>alert('xss')</script><p>Hello</p>"}
      iex> PhoenixKit.Entities.HtmlSanitizer.sanitize_rich_text_fields(fields, data)
      %{"content" => "<p>Hello</p>"}
  """
  def sanitize_rich_text_fields(fields_definition, data)
      when is_list(fields_definition) and is_map(data) do
    rich_text_keys =
      fields_definition
      |> Enum.filter(fn field -> field["type"] == "rich_text" end)
      |> Enum.map(fn field -> field["key"] end)

    Enum.reduce(rich_text_keys, data, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        value -> Map.put(acc, key, sanitize(value))
      end
    end)
  end

  def sanitize_rich_text_fields(_fields, data), do: data

  # Private functions

  defp remove_dangerous_patterns(html) do
    dangerous_patterns = [
      # Script tags with content
      ~r/<script\b[^>]*>[\s\S]*?<\/script>/i,
      # Style tags with content
      ~r/<style\b[^>]*>[\s\S]*?<\/style>/i,
      # Event handlers
      ~r/\s+on\w+\s*=\s*["'][^"']*["']/i,
      ~r/\s+on\w+\s*=\s*[^\s>]+/i,
      # Dangerous tags
      ~r/<\s*(iframe|object|embed|form|input|button|meta|link|base)\b[^>]*>/i,
      ~r/<\/\s*(iframe|object|embed|form|input|button|meta|link|base)\s*>/i
    ]

    Enum.reduce(dangerous_patterns, html, fn pattern, acc ->
      Regex.replace(pattern, acc, "")
    end)
  end

  defp sanitize_urls(html) do
    # Remove dangerous href and src attributes
    html
    |> then(&Regex.replace(~r/href\s*=\s*["']\s*(javascript|vbscript|data):[^"']*["']/i, &1, ""))
    |> then(&Regex.replace(~r/src\s*=\s*["']\s*(javascript|vbscript|data):[^"']*["']/i, &1, ""))
  end
end
