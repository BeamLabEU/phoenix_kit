defmodule PhoenixKit.Modules.Pages.HtmlMetadata do
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @moduledoc """
  Metadata management for Pages module.

  Handles parsing and serialization of metadata stored in HTML comment blocks
  with YAML content.

  ## Format

      <!-- METADATA
      status: published
      title: My Page Title
      description: A brief description
      slug: custom-url
      author: John Doe
      created_at: 2025-01-15T10:00:00Z
      updated_at: 2025-01-15T10:00:00Z
      -->

  ## Fields

  - `status` - `draft` | `published` | `archived` (default: `draft`)
  - `title` - Page title (optional, defaults to filename)
  - `description` - SEO description (optional)
  - `slug` - Custom URL slug (optional)
  - `author` - Content author (optional)
  - `created_at` - ISO 8601 datetime (auto-generated)
  - `updated_at` - ISO 8601 datetime (auto-updated)
  """

  @type metadata :: %{
          status: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          slug: String.t() | nil,
          author: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @metadata_start "<!-- METADATA"
  @metadata_end "-->"

  @doc """
  Parses metadata from file content.

  Searches for metadata block in first 20 lines (optimization),
  then searches entire file if not found.

  Returns metadata map and content without metadata block.

  ## Examples

      iex> content = \"\"\"
      ...> <!-- METADATA
      ...> status: published
      ...> title: My Page
      ...> -->
      ...> # Content
      ...> \"\"\"
      iex> {:ok, metadata, content} = HtmlMetadata.parse(content)
      iex> metadata.status
      "published"
  """
  @spec parse(String.t()) :: {:ok, metadata(), String.t()} | {:error, :no_metadata}
  def parse(content) when is_binary(content) do
    # Try first 20 lines (optimization)
    lines = String.split(content, "\n")
    first_20 = Enum.take(lines, 20) |> Enum.join("\n")

    case extract_metadata_block(first_20) do
      {:ok, yaml_content} ->
        parse_metadata_yaml(yaml_content, content)

      :not_found ->
        # Search entire file
        case extract_metadata_block(content) do
          {:ok, yaml_content} ->
            parse_metadata_yaml(yaml_content, content)

          :not_found ->
            {:error, :no_metadata}
        end
    end
  end

  @doc """
  Serializes metadata to HTML comment format.

  ## Examples

      iex> metadata = %{
      ...>   status: "published",
      ...>   title: "My Page",
      ...>   created_at: ~U[2025-01-15 10:00:00Z],
      ...>   updated_at: ~U[2025-01-15 10:00:00Z]
      ...> }
      iex> HtmlMetadata.serialize(metadata)
      "<!-- METADATA\\nstatus: published\\n...\\n-->"
  """
  @spec serialize(metadata()) :: String.t()
  def serialize(metadata) do
    yaml_content =
      metadata
      |> Map.take([
        :status,
        :title,
        :description,
        :slug,
        :author,
        :created_at,
        :updated_at
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join("\n", fn {key, value} ->
        formatted_value = format_value(value)
        "#{key}: #{formatted_value}"
      end)

    """
    #{@metadata_start}
    #{yaml_content}
    #{@metadata_end}
    """
  end

  @doc """
  Strips metadata block from content.

  Returns content without the metadata block.

  ## Examples

      iex> content = "<!-- METADATA\\nstatus: draft\\n-->\\n\\n# Content"
      iex> HtmlMetadata.strip_metadata(content)
      "# Content"
  """
  @spec strip_metadata(String.t()) :: String.t()
  def strip_metadata(content) do
    case extract_metadata_block(content) do
      {:ok, _yaml_content} ->
        # Remove the entire metadata block
        content
        |> String.replace(
          ~r/#{Regex.escape(@metadata_start)}.*?#{Regex.escape(@metadata_end)}/s,
          ""
        )
        |> String.trim()

      :not_found ->
        content
    end
  end

  @doc """
  Updates metadata in content.

  If metadata exists, replaces it. If not, prepends it.

  ## Examples

      iex> content = "# Content"
      iex> metadata = default_metadata()
      iex> updated = HtmlMetadata.update_metadata(content, metadata)
      iex> updated =~ "<!-- METADATA"
      true
  """
  @spec update_metadata(String.t(), metadata()) :: String.t()
  def update_metadata(content, metadata) do
    stripped_content = strip_metadata(content)
    serialized = serialize(metadata)

    serialized <> "\n\n" <> stripped_content
  end

  @doc """
  Returns default metadata for new files.

  ## Examples

      iex> metadata = HtmlMetadata.default_metadata()
      iex> metadata.status
      "draft"
  """
  @spec default_metadata() :: metadata()
  def default_metadata do
    now = UtilsDate.utc_now()

    %{
      status: "draft",
      title: nil,
      description: nil,
      slug: nil,
      author: nil,
      created_at: now,
      updated_at: now
    }
  end

  @doc """
  Merges user-provided metadata with defaults.

  Preserves custom fields that aren't in the standard set.

  ## Examples

      iex> user_data = %{"status" => "published", "custom_field" => "value"}
      iex> metadata = HtmlMetadata.merge_metadata(user_data, default_metadata())
      iex> metadata.status
      "published"
  """
  @spec merge_metadata(map(), metadata()) :: metadata()
  def merge_metadata(user_data, defaults) when is_map(user_data) do
    parsed =
      user_data
      |> Enum.map(fn {key, value} ->
        atom_key = to_atom_key(key)
        {atom_key, parse_value(atom_key, value)}
      end)
      |> Enum.into(%{})

    Map.merge(defaults, parsed)
  end

  # Private functions

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
  end

  defp extract_metadata_block(content) do
    # Match metadata block with regex
    regex = ~r/#{Regex.escape(@metadata_start)}\s*\n(.*?)\n\s*#{Regex.escape(@metadata_end)}/s

    case Regex.run(regex, content) do
      [_full_match, yaml_content] -> {:ok, yaml_content}
      nil -> :not_found
    end
  end

  defp parse_metadata_yaml(yaml_content, original_content) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, data} when is_map(data) ->
        metadata = merge_metadata(data, default_metadata())
        content_without_metadata = strip_metadata(original_content)
        {:ok, metadata, content_without_metadata}

      {:ok, _} ->
        # Invalid YAML structure (not a map)
        {:error, :no_metadata}

      {:error, _reason} ->
        # YAML parsing failed
        {:error, :no_metadata}
    end
  end

  defp format_value(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_value(value) when is_binary(value) do
    # Quote strings that contain special characters
    if String.contains?(value, ["\n", ":", "#", "[", "]", "{", "}"]) do
      "\"#{String.replace(value, "\"", "\\\"")}\""
    else
      value
    end
  end

  defp format_value(value), do: to_string(value)

  defp parse_value(:created_at, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> UtilsDate.utc_now()
    end
  end

  defp parse_value(:updated_at, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> UtilsDate.utc_now()
    end
  end

  defp parse_value(:status, value) when is_binary(value) do
    if value in ["draft", "published", "archived"], do: value, else: "draft"
  end

  defp parse_value(_key, value), do: value
end
