defmodule PhoenixKit.Modules.Pages.Metadata do
  @moduledoc """
  Metadata helpers for .phk (PhoenixKit) pages posts.

  Metadata is stored as a simple key-value format at the top of the file:
  ```
  ---
  slug: home
  title: Welcome
  status: published
  published_at: 2025-10-29T18:48:00Z
  ---

  Content goes here...
  ```
  """

  alias PhoenixKit.Utils.Date, as: UtilsDate

  @type metadata :: %{
          status: String.t(),
          title: String.t(),
          description: String.t() | nil,
          slug: String.t(),
          published_at: String.t(),
          featured_image_id: String.t() | nil,
          created_at: String.t() | nil,
          created_by_id: String.t() | nil,
          created_by_email: String.t() | nil,
          updated_by_id: String.t() | nil,
          updated_by_email: String.t() | nil,
          # Version fields
          version: integer() | nil,
          version_created_at: String.t() | nil,
          version_created_from: integer() | nil,
          # Per-post version access control (allows public access to older versions)
          allow_version_access: boolean() | nil,
          # Per-language URL slug (optional, defaults to directory slug)
          url_slug: String.t() | nil,
          # Previous URL slugs for 301 redirects (list of old slugs)
          previous_url_slugs: [String.t()] | nil,
          # Primary language for this post (controls versioning/status inheritance)
          # If nil, uses the global content language setting
          primary_language: String.t() | nil
        }

  @doc """
  Parses .phk content, extracting metadata from frontmatter and returning the content.
  Title is extracted from the markdown content itself (first H1 heading).
  """
  @spec parse_with_content(String.t()) :: {:ok, metadata(), String.t()}
  def parse_with_content(content) do
    case extract_frontmatter(content) do
      {:ok, metadata, body_content} ->
        # Extract title from content
        title = extract_title_from_content(body_content)
        metadata_with_title = Map.put(metadata, :title, title)
        {:ok, metadata_with_title, body_content}

      {:error, _} ->
        # Fallback: try old XML format for backwards compatibility
        metadata = extract_metadata_from_xml(content)
        title = extract_title_from_content(content)
        metadata_with_title = Map.put(metadata, :title, title)
        {:ok, metadata_with_title, content}
    end
  end

  @doc """
  Serializes metadata as YAML-style frontmatter.
  Note: Title is NOT saved in frontmatter - it's extracted from content.
  """
  @spec serialize(metadata()) :: String.t()
  def serialize(metadata) do
    optional_lines =
      [
        :featured_image_id,
        :created_at,
        :created_by_id,
        :created_by_email,
        :updated_by_id,
        :updated_by_email,
        # Version fields (optional for backward compatibility)
        :version,
        :version_created_at,
        :version_created_from,
        :allow_version_access,
        # Per-language URL slug
        :url_slug,
        # Primary language for this post
        :primary_language
      ]
      |> Enum.flat_map(fn key ->
        case metadata_value(metadata, key) do
          nil -> []
          "" -> []
          # Handle boolean values for allow_version_access
          true -> ["#{Atom.to_string(key)}: true"]
          false -> ["#{Atom.to_string(key)}: false"]
          value -> ["#{Atom.to_string(key)}: #{value}"]
        end
      end)

    # Handle previous_url_slugs as a comma-separated list
    previous_slugs_line =
      case metadata_value(metadata, :previous_url_slugs) do
        nil -> []
        [] -> []
        slugs when is_list(slugs) -> ["previous_url_slugs: #{Enum.join(slugs, ",")}"]
        _ -> []
      end

    optional_lines = optional_lines ++ previous_slugs_line

    lines =
      [
        "slug: #{metadata.slug}",
        "status: #{metadata.status}",
        "published_at: #{metadata.published_at}"
      ]
      |> Enum.concat(optional_lines)
      |> Enum.join("\n")

    """
    ---
    #{lines}
    ---
    """
  end

  @doc """
  Returns default metadata for a new post.
  New posts default to version 1.
  """
  @spec default_metadata() :: metadata()
  def default_metadata do
    now = UtilsDate.utc_now()

    %{
      status: "draft",
      title: "",
      description: nil,
      slug: "",
      published_at: DateTime.to_iso8601(now),
      featured_image_id: nil,
      created_at: nil,
      created_by_id: nil,
      created_by_email: nil,
      updated_by_id: nil,
      updated_by_email: nil,
      # Version fields - new posts start at v1
      version: 1,
      version_created_at: DateTime.to_iso8601(now),
      version_created_from: nil,
      # Per-post version access - defaults to false (only published version accessible)
      allow_version_access: false,
      # Per-language URL slug - nil means use directory slug
      url_slug: nil,
      # Previous URL slugs for 301 redirects
      previous_url_slugs: nil,
      # Primary language - nil means use global content language setting
      primary_language: nil
    }
  end

  @doc """
  Extracts title from markdown content.
  Looks for the first H1 heading (# Title) within the first few lines.
  Falls back to the first line if no H1 found.
  """
  @spec extract_title_from_content(String.t()) :: String.t()
  def extract_title_from_content(content) when is_binary(content) do
    content
    |> String.trim()
    |> do_extract_title()
  end

  def extract_title_from_content(_), do: "Untitled"

  defp do_extract_title(""), do: "Untitled"

  defp do_extract_title(content) do
    content
    |> extract_title_from_lines()
    |> case do
      "Untitled" ->
        extract_title_from_components(content) || "Untitled"

      title ->
        title
    end
  end

  defp extract_title_from_lines(""), do: "Untitled"

  defp extract_title_from_lines(content) do
    lines =
      content
      |> extract_candidate_lines()
      |> Enum.take(15)

    # Look for first H1 heading (# Title)
    h1_line =
      Enum.find(lines, fn line ->
        String.starts_with?(line, "# ") and String.length(line) > 2
      end)

    cond do
      h1_line != nil ->
        h1_line
        |> String.trim_leading("# ")
        |> String.trim()

      not Enum.empty?(lines) ->
        # Fallback to first non-empty line
        List.first(lines)
        |> String.slice(0, 100)

      true ->
        "Untitled"
    end
  end

  defp extract_candidate_lines(content) do
    {lines, _depth} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], 0}, fn raw_line, {acc, depth} ->
        line = String.trim(raw_line)

        cond do
          line == "" and depth == 0 ->
            {acc, depth}

          component_self_closing?(line) ->
            {acc, depth}

          component_open?(line) ->
            {acc, depth + 1}

          depth > 0 and multiline_self_close?(raw_line) ->
            {acc, max(depth - 1, 0)}

          component_close?(line) and depth > 0 ->
            {acc, max(depth - 1, 0)}

          depth > 0 ->
            {acc, depth}

          true ->
            {[line | acc], depth}
        end
      end)

    lines
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp component_open?(line) do
    String.starts_with?(line, "<") and
      not String.starts_with?(line, "</") and
      Regex.match?(~r/^<[A-Z][\w-]*/, line)
  end

  defp component_close?(line) do
    Regex.match?(~r{^</[A-Z][\w-]*>}, line)
  end

  defp component_self_closing?(line) do
    component_open?(line) and String.ends_with?(line, "/>")
  end

  defp multiline_self_close?(line) do
    line
    |> String.trim()
    |> case do
      "/>" -> true
      ">" -> false
      other -> String.ends_with?(other, "/>")
    end
  end

  defp extract_title_from_components(content) do
    component_title(content, "Headline") ||
      component_attribute(content, "Hero", "title") ||
      component_title(content, "Title")
  end

  defp component_title(content, tag) do
    regex = ~r/<#{tag}\b[^>]*>(.*?)<\/#{tag}>/is

    case Regex.run(regex, content, capture: :all_but_first) do
      [inner | _] -> sanitize_component_text(inner)
      _ -> nil
    end
  end

  defp component_attribute(content, tag, attr) do
    regex = ~r/<#{tag}\b[^>]*#{attr}="([^"]+)"[^>]*>/i

    case Regex.run(regex, content, capture: :all_but_first) do
      [value | _] -> sanitize_component_text(value)
      _ -> nil
    end
  end

  defp sanitize_component_text(text) do
    text
    |> String.trim()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> String.slice(cleaned, 0, 100)
    end
  end

  # Extract metadata from YAML-style frontmatter
  defp extract_frontmatter(content) do
    case Regex.run(~r/^---\n(.*?)\n---\n(.*)$/s, content) do
      [_, frontmatter, body] ->
        metadata = parse_frontmatter_lines(frontmatter)
        {:ok, metadata, String.trim(body)}

      _ ->
        {:error, :no_frontmatter}
    end
  end

  defp parse_frontmatter_lines(frontmatter) do
    default = default_metadata()

    lines =
      frontmatter
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    metadata =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            Map.put(acc, String.trim(key), String.trim(value))

          _ ->
            acc
        end
      end)

    metadata_map = %{
      # Title is extracted from content, not from frontmatter
      # But we keep this for backward compatibility with old files
      title: Map.get(metadata, "title", default.title),
      status: Map.get(metadata, "status", default.status),
      slug: Map.get(metadata, "slug", default.slug),
      published_at: Map.get(metadata, "published_at", default.published_at),
      featured_image_id: Map.get(metadata, "featured_image_id", default.featured_image_id),
      description: Map.get(metadata, "description"),
      created_at: Map.get(metadata, "created_at", default.created_at),
      created_by_id: Map.get(metadata, "created_by_id", default.created_by_id),
      created_by_email: Map.get(metadata, "created_by_email", default.created_by_email),
      updated_by_id: Map.get(metadata, "updated_by_id", default.updated_by_id),
      updated_by_email: Map.get(metadata, "updated_by_email", default.updated_by_email),
      # Version fields - parse with defaults for backward compatibility
      version: parse_integer(Map.get(metadata, "version"), default.version),
      version_created_at: Map.get(metadata, "version_created_at", default.version_created_at),
      version_created_from: parse_integer(Map.get(metadata, "version_created_from"), nil),
      # Per-post version access control
      allow_version_access:
        parse_boolean(Map.get(metadata, "allow_version_access"), default.allow_version_access),
      # Per-language URL slug (optional)
      url_slug: parse_url_slug(Map.get(metadata, "url_slug")),
      # Previous URL slugs for 301 redirects (comma-separated list)
      previous_url_slugs: parse_previous_url_slugs(Map.get(metadata, "previous_url_slugs")),
      # Primary language for this post
      primary_language: Map.get(metadata, "primary_language")
    }

    # For backward compatibility, also read legacy is_live field if present
    # This allows migration to detect old posts
    legacy_is_live = parse_boolean(Map.get(metadata, "is_live"), nil)

    if legacy_is_live != nil do
      Map.put(metadata_map, :legacy_is_live, legacy_is_live)
    else
      metadata_map
    end
  end

  # Parse integer from string, returning default if nil or invalid
  defp parse_integer(nil, default), do: default
  defp parse_integer("", default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(_, default), do: default

  # Parse boolean from string
  defp parse_boolean(nil, default), do: default
  defp parse_boolean("true", _default), do: true
  defp parse_boolean("false", _default), do: false
  defp parse_boolean(value, _default) when is_boolean(value), do: value
  defp parse_boolean(_, default), do: default

  # Parse url_slug - returns nil if empty
  defp parse_url_slug(nil), do: nil
  defp parse_url_slug(""), do: nil
  defp parse_url_slug(value) when is_binary(value), do: String.trim(value)

  # Parse previous_url_slugs as comma-separated list
  defp parse_previous_url_slugs(nil), do: nil
  defp parse_previous_url_slugs(""), do: nil

  defp parse_previous_url_slugs(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      slugs -> slugs
    end
  end

  defp parse_previous_url_slugs(value) when is_list(value), do: value

  # Extract metadata from <Page> element attributes (legacy XML format)
  defp extract_metadata_from_xml(content) do
    default = default_metadata()

    # Simple regex-based extraction (for now)
    title = extract_attribute(content, "title") || default.title
    status = extract_attribute(content, "status") || default.status
    slug = extract_attribute(content, "slug") || default.slug
    published_at = extract_attribute(content, "published_at") || default.published_at
    description = extract_attribute(content, "description")

    %{
      title: title,
      status: status,
      slug: slug,
      published_at: published_at,
      description: description,
      created_at: nil,
      created_by_id: nil,
      created_by_email: nil,
      updated_by_id: nil,
      updated_by_email: nil,
      # Legacy posts default to v1 (will be migrated)
      version: 1,
      version_created_at: nil,
      version_created_from: nil,
      allow_version_access: false,
      url_slug: nil,
      previous_url_slugs: nil,
      primary_language: nil
    }
  end

  defp extract_attribute(content, attr_name) do
    regex = ~r/<Page[^>]*\s#{attr_name}="([^"]*)"/

    case Regex.run(regex, content) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
