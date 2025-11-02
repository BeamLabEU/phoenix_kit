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
          created_at: String.t() | nil
        }

  @doc """
  Parses .phk content, extracting metadata from frontmatter and returning the content.
  """
  @spec parse_with_content(String.t()) :: {:ok, metadata(), String.t()} | {:error, atom()}
  def parse_with_content(content) do
    case extract_frontmatter(content) do
      {:ok, metadata, body_content} ->
        {:ok, metadata, body_content}

      {:error, _} ->
        # Fallback: try old XML format for backwards compatibility
        metadata = extract_metadata_from_xml(content)
        {:ok, metadata, content}
    end
  end

  @doc """
  Serializes metadata as YAML-style frontmatter.
  """
  @spec serialize(metadata()) :: String.t()
  def serialize(metadata) do
    created_at =
      case Map.get(metadata, :created_at) || Map.get(metadata, "created_at") do
        nil -> nil
        value -> "created_at: #{value}"
      end

    lines =
      [
        "slug: #{metadata.slug}",
        "title: #{metadata.title || ""}",
        "status: #{metadata.status}",
        "published_at: #{metadata.published_at}",
        created_at
      ]
      |> Enum.filter(& &1)
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
      created_at: nil
    }
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
      title: Map.get(metadata, "title", default.title),
      status: Map.get(metadata, "status", default.status),
      slug: Map.get(metadata, "slug", default.slug),
      published_at: Map.get(metadata, "published_at", default.published_at),
      description: Map.get(metadata, "description"),
      created_at: Map.get(metadata, "created_at", default.created_at)
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
      created_at: nil
    }
  end

  defp extract_attribute(content, attr_name) do
    regex = ~r/<Page[^>]*\s#{attr_name}="([^"]*)"/

    case Regex.run(regex, content) do
      [_, value] -> value
      _ -> nil
    end
  end
end
