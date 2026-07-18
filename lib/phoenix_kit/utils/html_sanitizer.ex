defmodule PhoenixKit.Utils.HtmlSanitizer do
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

      iex> PhoenixKit.Utils.HtmlSanitizer.sanitize("<p>Hello</p><script>alert('xss')</script>")
      "<p>Hello</p>"

      iex> PhoenixKit.Utils.HtmlSanitizer.sanitize("<a href=\"javascript:alert('xss')\">Click</a>")
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

      iex> PhoenixKit.Utils.HtmlSanitizer.sanitize("<p onclick=\"alert('xss')\">Hello</p>")
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
      iex> PhoenixKit.Utils.HtmlSanitizer.sanitize_rich_text_fields(fields, data)
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

  # Schemes a link/media URL may use; anything else (or an unlisted scheme) is
  # dropped. Relative/fragment/query URLs (no scheme) are allowed.
  @allowed_schemes ~w(http https mailto tel)
  @dangerous_scheme ~r/^(?:javascript|vbscript|data|file|blob):/
  @scheme ~r/^[a-z][a-z0-9+.\-]*:/i

  # A few named entities whose decoded form matters for scheme detection
  # (a browser decodes `javascript&colon;alert(1)` before dispatching).
  @named_entities %{
    "tab" => "\t",
    "newline" => "\n",
    "colon" => ":",
    "sol" => "/",
    "lpar" => "(",
    "rpar" => ")",
    "num" => "#"
  }

  # Sanitize `href`/`src` URLs with an ALLOWLIST over a normalized value, not a
  # scheme blacklist. MDEx renders raw HTML (`unsafe: true`) and the browser
  # decodes entities + ignores whitespace/control chars in the scheme, so a
  # blacklist is trivially bypassed (`jav&#x61;script:`, `java&Tab;script:`,
  # `java\tscript:`). We decode entities and strip those chars BEFORE checking,
  # and only ever REMOVE an attribute — never rewrite the visible URL — so the
  # transform is fail-safe even if decoding is imperfect.
  defp sanitize_urls(html) do
    html
    |> scrub_url_attr("href")
    |> scrub_url_attr("src")
  end

  defp scrub_url_attr(html, attr) do
    regex = ~r/\s#{attr}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i

    Regex.replace(regex, html, fn full, dquoted, squoted, unquoted ->
      value = dquoted <> squoted <> unquoted
      if safe_url?(value), do: full, else: ""
    end)
  end

  defp safe_url?(value) do
    normalized =
      value
      |> decode_entities()
      # Browsers ignore ASCII control chars + whitespace when parsing a scheme.
      |> String.replace(~r/[\x00-\x20\x7f]/u, "")
      |> String.downcase()

    cond do
      Regex.match?(@dangerous_scheme, normalized) -> false
      not Regex.match?(@scheme, normalized) -> true
      Regex.match?(~r/^(?:#{Enum.join(@allowed_schemes, "|")}):/, normalized) -> true
      true -> false
    end
  end

  defp decode_entities(str) do
    str
    |> replace_entities(~r/&#x([0-9a-f]+);?/i, &String.to_integer(&1, 16))
    |> replace_entities(~r/&#([0-9]+);?/, &String.to_integer/1)
    |> then(
      &Regex.replace(~r/&([a-z]+);/i, &1, fn whole, name ->
        Map.get(@named_entities, String.downcase(name), whole)
      end)
    )
  end

  defp replace_entities(str, regex, to_codepoint) do
    Regex.replace(regex, str, fn _whole, digits -> codepoint(to_codepoint.(digits)) end)
  end

  defp codepoint(n) when is_integer(n) and n in 0..0x10FFFF do
    <<n::utf8>>
  rescue
    # Surrogate/invalid code points can't be encoded — treat as removed.
    _ -> ""
  end

  defp codepoint(_), do: ""
end
