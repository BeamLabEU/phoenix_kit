defmodule PhoenixKitWeb.Live.Modules.Blogging.Metadata do
  @moduledoc """
  Metadata helpers for .phk (PhoenixKit) blogging posts.

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

  @type metadata :: %{
          status: String.t(),
          title: String.t(),
          description: String.t() | nil,
          slug: String.t(),
          published_at: String.t(),
          created_at: String.t() | nil,
          created_by_id: String.t() | nil,
          created_by_email: String.t() | nil,
          updated_by_id: String.t() | nil,
          updated_by_email: String.t() | nil
        }

  @doc """
  Parses .phk content, extracting metadata from frontmatter and returning the content.
  Title is extracted from the markdown content itself (first H1 heading).
  """
  @spec parse_with_content(String.t()) :: {:ok, metadata(), String.t()} | {:error, atom()}
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
      [:created_at, :created_by_id, :created_by_email, :updated_by_id, :updated_by_email]
      |> Enum.flat_map(fn key ->
        case metadata_value(metadata, key) do
          nil -> []
          "" -> []
          value -> ["#{Atom.to_string(key)}: #{value}"]
        end
      end)

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
  """
  @spec default_metadata() :: metadata()
  def default_metadata do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      status: "draft",
      title: "",
      description: nil,
      slug: "",
      published_at: DateTime.to_iso8601(now),
      created_at: nil,
      created_by_id: nil,
      created_by_email: nil,
      updated_by_id: nil,
      updated_by_email: nil
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
    |> extract_title_from_lines()
  end

  def extract_title_from_content(_), do: "Untitled"

  defp extract_title_from_lines(""), do: "Untitled"

  defp extract_title_from_lines(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.take(10)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

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

      length(lines) > 0 ->
        # Fallback to first non-empty line
        List.first(lines)
        |> String.slice(0, 100)

      true ->
        "Untitled"
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
      description: Map.get(metadata, "description"),
      created_at: Map.get(metadata, "created_at", default.created_at),
      created_by_id: Map.get(metadata, "created_by_id", default.created_by_id),
      created_by_email: Map.get(metadata, "created_by_email", default.created_by_email),
      updated_by_id: Map.get(metadata, "updated_by_id", default.updated_by_id),
      updated_by_email: Map.get(metadata, "updated_by_email", default.updated_by_email)
    }

    metadata_map
  end

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
      updated_by_email: nil
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
