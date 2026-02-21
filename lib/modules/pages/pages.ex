defmodule PhoenixKit.Modules.Pages do
  @moduledoc """
  Pages module for file-based content management.

  Provides filesystem operations for creating, editing, and organizing
  files and folders in a web-based interface.
  """
  require Logger

  alias PhoenixKit.Modules.Pages.FileOperations
  alias PhoenixKit.Modules.Pages.FilePaths
  alias PhoenixKit.Modules.Pages.HtmlMetadata

  @not_found_enabled_key "pages_handle_not_found"
  @not_found_path_key "pages_not_found_page"

  @doc """
  Checks if Pages module is enabled.

  ## Examples

      iex> PhoenixKit.Modules.Pages.enabled?()
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
    PhoenixKit.Settings.get_setting(@not_found_path_key, "/404")
    |> FilePaths.normalize_slug()
  end

  @doc """
  Updates the slug used for the custom 404 page.
  """
  def update_not_found_slug(slug) when is_binary(slug) do
    normalized = FilePaths.normalize_slug(slug)
    PhoenixKit.Settings.update_setting(@not_found_path_key, normalized)
    normalized
  end

  @doc """
  Returns the relative file path (with `.md`) for the configured not found page.
  """
  def not_found_file_path do
    FilePaths.slug_to_file_path(not_found_slug())
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
        HtmlMetadata.default_metadata()
        |> Map.put(:status, "published")
        |> Map.put(:title, "Page Not Found")
        |> Map.put(:description, "Displayed when a page cannot be located.")
        |> Map.put(:slug, String.trim_leading(not_found_slug(), "/"))

      body = """
      # Page Not Found

      The page you are looking for could not be found. It may have been moved or removed.
      """

      content = HtmlMetadata.serialize(metadata) <> "\n\n" <> String.trim(body) <> "\n"

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
  Returns the storage mode for a group slug.

  Pages always uses timestamp mode (copied from Publishing's listing cache
  which supports both timestamp and slug modes).
  """
  def get_group_mode(_group_slug), do: "timestamp"

  @doc """
  Gets the root directory path for pages.

  Creates the directory if it doesn't exist.
  Uses the parent application's directory, not PhoenixKit's dependency directory.

  ## Examples

      iex> PhoenixKit.Modules.Pages.root_path()
      "/path/to/app/priv/static/pages"
  """
  def root_path, do: FilePaths.root_path()
end
