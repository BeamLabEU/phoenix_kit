defmodule PhoenixKit.Sitemap.UrlEntry do
  @moduledoc """
  Struct representing a single URL entry in sitemap.

  Used for both XML and HTML sitemap generation. Contains all necessary
  metadata for proper sitemap formatting according to sitemaps.org protocol.

  ## Fields

  - `loc` - Full URL (required)
  - `lastmod` - Last modification date/time
  - `changefreq` - Change frequency hint (weekly, daily, monthly, etc.)
  - `priority` - Priority value 0.0-1.0
  - `title` - Display title for HTML sitemap
  - `category` - Category/group for organizing HTML sitemap
  - `source` - Source module that generated this entry (:entities, :blogging, etc.)
  - `alternates` - List of alternate language versions for hreflang (optional)
  - `canonical_path` - Canonical path without language prefix (for grouping alternates)

  ## Alternates Format

  Each alternate is a map with:
  - `hreflang` - Language code (e.g., "en", "et", "x-default")
  - `href` - Full URL for that language version

  ## Usage

      entry = UrlEntry.new(%{
        loc: "https://example.com/blog/my-post",
        lastmod: ~U[2025-01-15 10:00:00Z],
        changefreq: "weekly",
        priority: 0.8,
        title: "My Blog Post",
        category: "Blog",
        source: :blogging,
        alternates: [
          %{hreflang: "en", href: "https://example.com/blog/my-post"},
          %{hreflang: "et", href: "https://example.com/et/blog/my-post"},
          %{hreflang: "x-default", href: "https://example.com/blog/my-post"}
        ]
      })

      xml = UrlEntry.to_xml(entry)
  """

  @type alternate :: %{hreflang: String.t(), href: String.t()}

  @type t :: %__MODULE__{
          loc: String.t(),
          lastmod: DateTime.t() | Date.t() | NaiveDateTime.t() | nil,
          changefreq: String.t() | nil,
          priority: float() | String.t() | nil,
          title: String.t() | nil,
          category: String.t() | nil,
          source: atom(),
          alternates: [alternate()] | nil,
          canonical_path: String.t() | nil
        }

  defstruct [
    :loc,
    :lastmod,
    :changefreq,
    :priority,
    :title,
    :category,
    :source,
    :alternates,
    :canonical_path
  ]

  @valid_changefreq ~w(always hourly daily weekly monthly yearly never)

  @doc """
  Creates a new UrlEntry struct from attributes.

  ## Examples

      iex> UrlEntry.new(%{loc: "https://example.com/page"})
      %UrlEntry{loc: "https://example.com/page"}

      iex> UrlEntry.new(%{loc: "https://example.com", priority: 0.8, changefreq: "weekly"})
      %UrlEntry{loc: "https://example.com", priority: 0.8, changefreq: "weekly"}
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Converts a UrlEntry to XML format for sitemap.

  Supports hreflang alternate links via xhtml:link elements when `alternates` is set.

  ## Examples

      iex> entry = UrlEntry.new(%{loc: "https://example.com", lastmod: ~D[2025-01-15]})
      iex> UrlEntry.to_xml(entry)
      "<url>\\n  <loc>https://example.com</loc>\\n  <lastmod>2025-01-15</lastmod>\\n</url>"

      iex> entry = UrlEntry.new(%{
      ...>   loc: "https://example.com/page",
      ...>   alternates: [
      ...>     %{hreflang: "en", href: "https://example.com/page"},
      ...>     %{hreflang: "et", href: "https://example.com/et/page"}
      ...>   ]
      ...> })
      iex> UrlEntry.to_xml(entry) |> String.contains?("xhtml:link")
      true
  """
  @spec to_xml(t()) :: String.t()
  def to_xml(%__MODULE__{} = entry) do
    parts = [
      "  <loc>#{escape_xml(entry.loc)}</loc>"
    ]

    parts =
      if entry.lastmod do
        parts ++ ["  <lastmod>#{format_date(entry.lastmod)}</lastmod>"]
      else
        parts
      end

    parts =
      if entry.changefreq && entry.changefreq in @valid_changefreq do
        parts ++ ["  <changefreq>#{entry.changefreq}</changefreq>"]
      else
        parts
      end

    parts =
      if entry.priority do
        priority_value = normalize_priority(entry.priority)
        parts ++ ["  <priority>#{priority_value}</priority>"]
      else
        parts
      end

    # Add hreflang alternate links if present
    parts =
      if entry.alternates && length(entry.alternates) > 0 do
        alternate_links =
          Enum.map(entry.alternates, fn alt ->
            ~s(  <xhtml:link rel="alternate" hreflang="#{alt.hreflang}" href="#{escape_xml(alt.href)}"/>)
          end)

        parts ++ alternate_links
      else
        parts
      end

    "<url>\n#{Enum.join(parts, "\n")}\n</url>"
  end

  @doc """
  Formats date/datetime to ISO8601 string for lastmod element.
  """
  @spec format_date(DateTime.t() | Date.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def format_date(nil), do: nil
  def format_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def format_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  def format_date(%Date{} = d), do: Date.to_iso8601(d)

  def format_date(other) when is_binary(other) do
    # Already a string, return as-is
    other
  end

  def format_date(_), do: nil

  @doc """
  Normalizes priority value to a float between 0.0 and 1.0.
  """
  @spec normalize_priority(float() | String.t() | nil) :: float()
  def normalize_priority(nil), do: 0.5

  def normalize_priority(priority) when is_float(priority) do
    priority
    |> max(0.0)
    |> min(1.0)
    |> Float.round(1)
  end

  def normalize_priority(priority) when is_binary(priority) do
    case Float.parse(priority) do
      {value, _} -> normalize_priority(value)
      :error -> 0.5
    end
  end

  def normalize_priority(priority) when is_integer(priority) do
    normalize_priority(priority / 1.0)
  end

  def normalize_priority(_), do: 0.5

  @doc """
  Escapes XML special characters in a string.
  """
  @spec escape_xml(String.t()) :: String.t()
  def escape_xml(nil), do: ""

  def escape_xml(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  @doc """
  Parses priority from various formats.

  ## Examples

      iex> UrlEntry.parse_priority("0.8")
      0.8

      iex> UrlEntry.parse_priority(0.7)
      0.7

      iex> UrlEntry.parse_priority(nil)
      nil
  """
  @spec parse_priority(String.t() | float() | nil) :: float() | nil
  def parse_priority(nil), do: nil

  def parse_priority(priority) when is_float(priority), do: priority

  def parse_priority(priority) when is_binary(priority) do
    case Float.parse(priority) do
      {value, _} -> value
      :error -> nil
    end
  end

  def parse_priority(_), do: nil
end
