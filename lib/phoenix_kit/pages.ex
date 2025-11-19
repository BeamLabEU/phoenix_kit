defmodule PhoenixKit.Pages do
  @moduledoc """
  Pages module for file-based content management.

  Provides filesystem operations for creating, editing, and organizing
  files and folders in a web-based interface.
  """
  require Logger

  alias PhoenixKit.Config
  alias PhoenixKit.Pages.FileOperations
  alias PhoenixKit.Pages.Metadata

  @not_found_enabled_key "pages_handle_not_found"
  @not_found_path_key "pages_not_found_page"
  @default_not_found_slug "/404"

  @doc """
  Checks if Pages module is enabled.

  ## Examples

      iex> PhoenixKit.Pages.enabled?()
      true
  """
  def enabled? do
    PhoenixKit.Settings.get_boolean_setting("pages_enabled", false)
  end

  @doc """
  Enables the Pages module.
  """
  def enable_system do
    PhoenixKit.Settings.update_boolean_setting("pages_enabled", true)
  end

  @doc """
  Disables the Pages module.
  """
  def disable_system do
    PhoenixKit.Settings.update_boolean_setting("pages_enabled", false)
  end

  @doc """
  Returns true when PhoenixKit should keep the 404 inside the Pages module.
  """
  def handle_not_found? do
    PhoenixKit.Settings.get_boolean_setting(@not_found_enabled_key, false)
  end

  @doc """
  Enables or disables the custom 404 handler.
  """
  def update_handle_not_found(enabled?) when is_boolean(enabled?) do
    PhoenixKit.Settings.update_boolean_setting(@not_found_enabled_key, enabled?)
  end

  @doc """
  Returns the stored slug (without extension) used for custom 404 pages.
  """
  def not_found_slug do
    PhoenixKit.Settings.get_setting(@not_found_path_key, @default_not_found_slug)
    |> normalize_slug()
  end

  @doc """
  Updates the slug used for the custom 404 page.
  """
  def update_not_found_slug(slug) when is_binary(slug) do
    normalized = normalize_slug(slug)
    PhoenixKit.Settings.update_setting(@not_found_path_key, normalized)
    normalized
  end

  @doc """
  Returns the relative file path (with `.md`) for the configured not found page.
  """
  def not_found_file_path do
    slug_to_file_path(not_found_slug())
  end

  @doc """
  Ensures the configured not found page exists on disk.

  Creates a published markdown file with sensible defaults if missing.
  """
  def ensure_not_found_page_exists do
    relative_path = not_found_file_path()

    if FileOperations.file_exists?(relative_path) do
      Logger.debug("Pages 404 already exists at #{FileOperations.absolute_path(relative_path)}")
    else
      full_path = FileOperations.absolute_path(relative_path)
      Logger.info("Creating default Pages 404 at #{full_path}")

      metadata =
        Metadata.default_metadata()
        |> Map.put(:status, "published")
        |> Map.put(:title, "Page Not Found")
        |> Map.put(:description, "Displayed when a page cannot be located.")
        |> Map.put(:slug, String.trim_leading(not_found_slug(), "/"))

      body = """
      # Page Not Found

      The page you are looking for could not be found. It may have been moved or removed.
      """

      content = Metadata.serialize(metadata) <> "\n\n" <> String.trim(body) <> "\n"

      case FileOperations.write_file(relative_path, content) do
        :ok ->
          Logger.info("Default Pages 404 created at #{full_path}")

        {:error, reason} ->
          Logger.error("Failed to create default Pages 404 at #{full_path}: #{inspect(reason)}")
      end
    end

    relative_path
  end

  @doc """
  Gets the root directory path for pages.

  Creates the directory if it doesn't exist.
  Uses the parent application's directory, not PhoenixKit's dependency directory.

  ## Examples

      iex> PhoenixKit.Pages.root_path()
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

  # Private Helpers

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

  defp normalize_slug(slug) do
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

  defp slug_to_file_path(slug) do
    normalized = normalize_slug(slug)

    if String.ends_with?(normalized, ".md") do
      normalized
    else
      normalized <> ".md"
    end
  end
end
