defmodule PhoenixKit.Modules.Pages.FilePaths do
  @moduledoc """
  Path utilities for Pages module.

  Handles path resolution, validation, and conversion operations.
  """
  require Logger

  alias PhoenixKit.Config

  @default_not_found_slug "/404"

  @doc """
  Gets the root directory path for pages.

  Creates the directory if it doesn't exist.
  Uses the parent application's directory, not PhoenixKit's dependency directory.

  ## Examples

      iex> PhoenixKit.Modules.Pages.FilePaths.root_path()
      "/path/to/app/priv/static/pages"
  """
  def root_path do
    parent_app = Config.get_parent_app()
    path = resolve_pages_path(parent_app)

    Logger.debug("Pages root_path: parent_app=#{inspect(parent_app)}, path=#{inspect(path)}")

    case File.mkdir_p(path) do
      :ok -> path
      {:error, reason} -> raise "Failed to create pages directory at #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Normalizes a slug to ensure proper formatting.

  - Ensures slug starts with "/"
  - Removes trailing "/"
  - Returns default slug for empty or invalid inputs

  ## Examples

      iex> PhoenixKit.Modules.Pages.FilePaths.normalize_slug("")
      "/404"

      iex> PhoenixKit.Modules.Pages.FilePaths.normalize_slug("hello")
      "/hello"

      iex> PhoenixKit.Modules.Pages.FilePaths.normalize_slug("/hello/")
      "/hello"
  """
  def normalize_slug(slug) do
    slug =
      slug
      |> String.trim()
      |> case do
        "" -> @default_not_found_slug
        value -> value
      end

    slug =
      if String.starts_with?(slug, "/") do
        slug
      else
        "/" <> slug
      end

    slug =
      slug
      |> String.trim_trailing("/")
      |> case do
        "" -> @default_not_found_slug
        "/" -> @default_not_found_slug
        value -> value
      end

    slug
  end

  @doc """
  Converts a slug to a relative file path with .md extension.

  ## Examples

      iex> PhoenixKit.Modules.Pages.FilePaths.slug_to_file_path("/hello")
      "/hello.md"

      iex> PhoenixKit.Modules.Pages.FilePaths.slug_to_file_path("/hello.md")
      "/hello.md"
  """
  def slug_to_file_path(slug) do
    normalized = normalize_slug(slug)

    if String.ends_with?(normalized, ".md") do
      normalized
    else
      normalized <> ".md"
    end
  end

  @doc """
  Converts a relative file path to a slug (without .md extension).

  ## Examples

      iex> PhoenixKit.Modules.Pages.FilePaths.file_path_to_slug("/hello.md")
      "/hello"

      iex> PhoenixKit.Modules.Pages.FilePaths.file_path_to_slug("/hello")
      "/hello"
  """
  def file_path_to_slug(file_path) do
    file_path
    |> String.trim_leading("/")
    |> Path.rootname(".md")
    |> then(fn path -> "/" <> path end)
    |> normalize_slug()
  end

  @doc """
  Validates that a path is safe and doesn't attempt directory traversal.

  ## Examples

      iex> PhoenixKit.Modules.Pages.FilePaths.safe_path?("/hello")
      true

      iex> PhoenixKit.Modules.Pages.FilePaths.safe_path?("/../etc/passwd")
      false
  """
  def safe_path?(relative_path) do
    normalized =
      relative_path
      |> String.trim_leading("/")
      |> String.trim_trailing("/")

    not String.contains?(normalized, "..")
  end

  @doc """
  Builds the full absolute path for a relative pages path.

  Includes security checks to prevent directory traversal.

  ## Examples

      iex> PhoenixKit.Modules.Pages.FilePaths.build_full_path("/hello.md")
      "/app/priv/static/pages/hello.md"
  """
  def build_full_path(relative_path) do
    # Normalize path (remove leading/trailing slashes)
    normalized =
      relative_path
      |> String.trim_leading("/")
      |> String.trim_trailing("/")

    # Prevent directory traversal attacks
    if String.contains?(normalized, "..") do
      raise "Invalid path: directory traversal not allowed"
    end

    # Build full path
    root = root_path()
    full_path = Path.join(root, normalized)

    # Double-check path is within root directory (security check)
    if String.starts_with?(full_path, root) do
      full_path
    else
      raise "Invalid path: attempting to access outside root directory"
    end
  end

  @doc """
  Joins path segments safely for pages paths.

  Normalizes the result to ensure consistent formatting.

  ## Examples

      iex> PhoenixKit.Modules.Pages.FilePaths.join_path("/blog", "hello.md")
      "/blog/hello.md"

      iex> PhoenixKit.Modules.Pages.FilePaths.join_path("/blog/", "/hello.md")
      "/blog/hello.md"
  """
  def join_path(segments) when is_list(segments) do
    segments
    |> Enum.map(&String.trim/1)
    |> Path.join()
    |> then(fn path -> "/" <> path end)
    |> normalize_path_format()
  end

  def join_path(segment1, segment2) do
    join_path([segment1, segment2])
  end

  def join_path(segment1, segment2, segment3) do
    join_path([segment1, segment2, segment3])
  end

  # Private helpers

  defp resolve_pages_path(parent_app) do
    priv_dir = :code.priv_dir(parent_app) |> to_string()

    if contains_build_path?(priv_dir) do
      project_root = Path.expand("../../../../../", priv_dir)
      Path.join(project_root, "priv/static/pages")
    else
      Path.join(priv_dir, "static/pages")
    end
  end

  defp contains_build_path?(path) do
    String.contains?(path, "/_build/") || String.contains?(path, "\\_build\\")
  end

  defp normalize_path_format(path) do
    path
    # Replace multiple slashes with single slash
    |> String.replace(~r{/+}, "/")
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      path -> path
    end
  end
end
