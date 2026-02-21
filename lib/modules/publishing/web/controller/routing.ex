defmodule PhoenixKit.Modules.Publishing.Web.Controller.Routing do
  @moduledoc """
  URL path parsing and routing helpers for the publishing controller.

  Handles segment building from params and path pattern matching
  to determine the type of request (listing, slug post, timestamp post, etc.).
  """

  # ============================================================================
  # Segment Building
  # ============================================================================

  @doc """
  Builds path segments from route params.

  Returns a list of path segments starting with the group slug,
  followed by any additional path segments.
  """
  def build_segments(%{"group" => group} = params) when is_binary(group) do
    case Map.get(params, "path") do
      nil -> [group]
      path when is_list(path) -> [group | path]
      path when is_binary(path) -> [group, path]
      _ -> [group]
    end
  end

  def build_segments(_), do: []

  # ============================================================================
  # Path Parsing
  # ============================================================================

  @doc """
  Parses path segments to determine the request type.

  Returns one of:
  - `{:listing, group_slug}`
  - `{:slug_post, group_slug, post_slug}`
  - `{:timestamp_post, group_slug, date, time}`
  - `{:date_only_post, group_slug, date}`
  - `{:versioned_post, group_slug, post_slug, version}`
  - `{:error, reason}`
  """
  def parse_path([]), do: {:error, :invalid_path}
  def parse_path([group_slug]), do: {:listing, group_slug}

  def parse_path([group_slug, segment1, segment2]) do
    # Check if this is timestamp mode: segment1 matches date, segment2 matches time
    if date?(segment1) and time?(segment2) do
      {:timestamp_post, group_slug, segment1, segment2}
    else
      # Invalid format
      {:error, :invalid_path}
    end
  end

  # Version-specific URL: /group/post-slug/v/2
  def parse_path([group_slug, post_slug, "v", version_str]) do
    case Integer.parse(version_str) do
      {version, ""} when version > 0 ->
        {:versioned_post, group_slug, post_slug, version}

      _ ->
        {:error, :invalid_version}
    end
  end

  def parse_path([group_slug, segment]) do
    # Check if segment is a date (for date-only timestamp URLs)
    # If it's a date, treat as date-only timestamp post
    # Otherwise, treat as slug mode post
    if date?(segment) do
      {:date_only_post, group_slug, segment}
    else
      {:slug_post, group_slug, segment}
    end
  end

  def parse_path(_), do: {:error, :invalid_path}

  # ============================================================================
  # Date/Time Validation
  # ============================================================================

  @doc """
  Validates a date string (YYYY-MM-DD format).
  """
  def date?(str) when is_binary(str) do
    String.match?(str, ~r/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/)
  end

  def date?(_), do: false

  @doc """
  Validates a time string (HH:MM 24-hour format).
  """
  def time?(str) when is_binary(str) do
    String.match?(str, ~r/^([01]\d|2[0-3]):[0-5]\d$/)
  end

  def time?(_), do: false
end
