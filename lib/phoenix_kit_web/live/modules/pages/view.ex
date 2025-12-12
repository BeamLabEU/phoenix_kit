defmodule PhoenixKitWeb.Live.Modules.Pages.View do
  @moduledoc """
  Rendered view for Pages markdown files.

  Displays markdown content with GitHub-style formatting.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Pages
  alias PhoenixKit.Pages.FileOperations
  alias PhoenixKit.Pages.Metadata
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    # Set locale
    locale = socket.assigns[:current_locale]

    # Check if module is enabled
    if Pages.enabled?() do
      socket =
        socket
        |> assign(:page_title, "View Page")
        |> assign(:file_path, nil)
        |> assign(:file_content, "")
        |> assign(:rendered_html, "")
        |> assign(:metadata, nil)
        |> assign(:project_title, PhoenixKit.Settings.get_setting("project_title", "PhoenixKit"))
        |> assign(:current_locale, locale)

      {:ok, socket}
    else
      socket =
        socket
        |> put_flash(:error, "Pages module is not enabled")
        |> redirect(to: Routes.path("/admin/modules"))

      {:ok, socket}
    end
  end

  def handle_params(%{"path" => path}, _uri, socket) do
    case FileOperations.read_file(path) do
      {:ok, content} ->
        # Parse metadata and content
        {metadata, markdown_content} =
          case Metadata.parse(content) do
            {:ok, meta, stripped} -> {meta, stripped}
            {:error, :no_metadata} -> {nil, content}
          end

        # Render markdown to HTML
        rendered_html =
          case Earmark.as_html(markdown_content) do
            {:ok, html, _} -> html
            {:error, _, _} -> "<p>Error rendering markdown</p>"
          end

        socket =
          socket
          |> assign(:file_path, path)
          |> assign(:file_content, markdown_content)
          |> assign(:rendered_html, rendered_html)
          |> assign(:metadata, metadata)
          |> assign(:page_title, get_page_title(metadata, path))

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          socket
          |> put_flash(:error, "File not found: #{path}")
          |> redirect(to: Routes.path("/admin/pages"))

        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    # No path provided, redirect to file list
    socket =
      socket
      |> put_flash(:error, "No file path provided")
      |> redirect(to: Routes.path("/admin/pages"))

    {:noreply, socket}
  end

  ## Private Helpers

  defp get_page_title(nil, path), do: "View: #{Path.basename(path)}"
  defp get_page_title(metadata, _path), do: "View: #{metadata.title}"
end
