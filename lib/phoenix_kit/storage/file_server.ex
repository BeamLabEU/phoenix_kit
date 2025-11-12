defmodule PhoenixKit.Storage.FileServer do
  @moduledoc """
  File serving logic with multi-location failover support.

  Handles retrieving files from storage locations with automatic failover,
  CDN integration, and proper HTTP header management.

  ## Features

  - Query file locations from database
  - Priority-based location ordering
  - Automatic failover to next location on failure
  - CDN redirect support
  - HTTP header generation for streaming
  - Range request support (HTTP 206) for video streaming

  ## Examples

      iex> {:ok, file_info} = PhoenixKit.Storage.FileServer.get_file_location(
      ...>   "018e3c4a-9f6b-7890",
      ...>   "thumbnail"
      ...> )
      iex> file_info.path
      "/path/018e3c4a-9f6b-7890-thumbnail.jpg"
      iex> file_info.bucket.cdn_url
      "https://cdn.example.com"
  """

  import Ecto.Query

  alias PhoenixKit.Storage.FileInstance
  alias PhoenixKit.Storage.FileLocation

  @doc """
  Get file location with priority-ordered failover list.

  Queries the database for all active locations of a file instance,
  ordered by bucket priority and location priority for automatic failover.

  ## Arguments

  - `file_id` (binary) - File UUID v7
  - `instance_name` (binary) - Variant name (e.g., "thumbnail", "medium")

  ## Returns

  - `{:ok, file_info}` - Contains file metadata and location options
  - `{:error, :not_found}` - File instance or locations not found
  - `{:error, :no_active_locations}` - No active storage locations available

  ## Example Response

      {:ok, %{
        instance: %FileInstance{...},
        locations: [
          %FileLocation{
            path: "/path/018e3c4a-thumbnail.jpg",
            bucket: %Bucket{
              name: "Local SSD",
              provider: "local",
              cdn_url: nil,
              priority: 1
            },
            priority: 0,
            status: "active"
          },
          %FileLocation{
            path: "/path/018e3c4a-thumbnail.jpg",
            bucket: %Bucket{
              name: "Backblaze B2",
              provider: "b2",
              cdn_url: "https://cdn.example.com",
              priority: 2
            },
            priority: 0,
            status: "active"
          }
        ]
      }}
  """
  def get_file_location(file_id, instance_name)
      when is_binary(file_id) and is_binary(instance_name) do
    repo = get_repo()

    # Query for file instance with all its locations
    query =
      from fi in FileInstance,
        where: fi.file_id == ^file_id and fi.variant_name == ^instance_name,
        preload: [
          file_locations: [
            bucket: []
          ]
        ]

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      instance ->
        # Filter for active locations only
        active_locations =
          instance.file_locations
          |> Enum.filter(&(&1.status == "active"))
          |> Enum.sort_by(&location_priority/1)

        case active_locations do
          [] ->
            {:error, :no_active_locations}

          locations ->
            {:ok,
             %{
               instance: instance,
               locations: locations
             }}
        end
    end
  end

  @doc """
  Generate HTTP headers for file serving.

  Creates proper response headers including Content-Type, Content-Length,
  Cache-Control, and ETag for file streaming.

  ## Arguments

  - `file_instance` (FileInstance) - File instance record with mime_type and size
  - `options` (keyword) - Options for header generation
    - `:cache_control` - Cache-Control header (default: "max-age=31536000, public, immutable")
    - `:etag` - Include ETag header (default: true)

  ## Returns

  Keyword list of HTTP headers.

  ## Example

      iex> headers = PhoenixKit.Storage.FileServer.http_headers(file_instance)
      iex> headers[:content_type]
      "image/jpeg"
      iex> headers[:cache_control]
      "max-age=31536000, public, immutable"
  """
  def http_headers(file_instance, options \\ []) do
    cache_control =
      Keyword.get(options, :cache_control, "max-age=31536000, public, immutable")

    include_etag = Keyword.get(options, :etag, true)

    headers = [
      content_type: file_instance.mime_type,
      content_length: file_instance.size,
      cache_control: cache_control,
      x_sendfile: :disabled
    ]

    if include_etag do
      Keyword.put(headers, :etag, "\"#{file_instance.checksum}\"")
    else
      headers
    end
  end

  @doc """
  Handle range request for partial file serving (video streaming).

  Parses Range header and returns start/end positions for 206 Partial Content response.

  ## Arguments

  - `range_header` (binary) - Range header value (e.g., "bytes=0-1023")
  - `file_size` (integer) - Total file size in bytes

  ## Returns

  - `{:ok, start, end, headers}` - Valid range with response headers
  - `{:error, :invalid_range}` - Malformed range header
  - `{:error, :range_out_of_bounds}` - Range exceeds file size

  ## Example

      iex> PhoenixKit.Storage.FileServer.parse_range_header(
      ...>   "bytes=0-1023",
      ...>   5000
      ...> )
      {:ok, 0, 1023, [content_range: "bytes 0-1023/5000"]}

      iex> PhoenixKit.Storage.FileServer.parse_range_header(
      ...>   "bytes=1000-",
      ...>   5000
      ...> )
      {:ok, 1000, 4999, [content_range: "bytes 1000-4999/5000"]}
  """
  def parse_range_header(range_header, file_size) when is_binary(range_header) do
    case String.split(range_header, "=") do
      ["bytes", range_spec] ->
        parse_range_spec(range_spec, file_size)

      _ ->
        {:error, :invalid_range}
    end
  end

  def parse_range_header(nil, _file_size) do
    :no_range
  end

  @doc """
  Check if a file location is accessible (has a path).

  Verifies that a file location record contains a valid storage path.

  ## Arguments

  - `location` (FileLocation) - File location record with preloaded bucket

  ## Returns

  Boolean indicating if location has a path.
  """
  def location_accessible?(%FileLocation{path: path}) when is_binary(path) do
    String.length(path) > 0
  end

  def location_accessible?(_), do: false

  # Private Helpers

  @doc false
  defp location_priority(%FileLocation{} = location) do
    # Sort by: bucket priority first (lower = higher priority), then location priority
    bucket_priority = if location.bucket, do: location.bucket.priority, else: 999
    location_priority = location.priority || 0

    {bucket_priority, location_priority}
  end

  @doc false
  defp parse_range_spec(range_spec, file_size) do
    case String.split(range_spec, "-") do
      [start_str, end_str] ->
        start_pos = String.to_integer(start_str)

        end_pos =
          if String.length(end_str) > 0 do
            String.to_integer(end_str)
          else
            file_size - 1
          end

        if start_pos >= 0 and end_pos >= start_pos and end_pos < file_size do
          content_range = "bytes #{start_pos}-#{end_pos}/#{file_size}"
          {:ok, start_pos, end_pos, content_range: content_range}
        else
          {:error, :range_out_of_bounds}
        end

      _ ->
        {:error, :invalid_range}
    end
  rescue
    ArgumentError ->
      {:error, :invalid_range}
  end

  @doc false
  defp get_repo do
    Application.get_env(:phoenix_kit, :repo) || raise "PhoenixKit repo not configured"
  end
end
