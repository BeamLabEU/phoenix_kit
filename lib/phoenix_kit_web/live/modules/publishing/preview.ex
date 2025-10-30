defmodule PhoenixKitWeb.Live.Modules.Publishing.Preview do
  @moduledoc """
  Preview rendering for .phk publishing entries.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.HTML
  alias PhoenixKitWeb.Live.Modules.Publishing
  # alias PhoenixKitWeb.Live.Modules.Publishing.PageBuilder  # COMMENTED OUT: Component system
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(%{"type" => type_slug} = params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Preview")
      |> assign(:type_slug, type_slug)
      |> assign(:type_name, Publishing.type_name(type_slug) || type_slug)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{type_slug}/preview", locale: locale)
      )
      |> assign(:rendered_content, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  def handle_params(%{"path" => path}, _uri, socket) do
    type_slug = socket.assigns.type_slug

    case Publishing.read_entry(type_slug, path) do
      {:ok, entry} ->
        case render_markdown_content(entry.content) do
          {:ok, rendered_html} ->
            {:noreply,
             socket
             |> assign(:entry, entry)
             |> assign(:rendered_content, rendered_html)
             |> assign(:error, nil)}

          {:error, error_message} ->
            {:noreply,
             socket
             |> assign(:entry, entry)
             |> assign(:rendered_content, nil)
             |> assign(:error, error_message)}
        end

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Entry not found"))
         |> push_navigate(
           to:
             Routes.path("/admin/publishing/#{type_slug}",
               locale: socket.assigns.current_locale
             )
         )}
    end
  end

  def handle_event("back_to_editor", _params, socket) do
    path = URI.encode(socket.assigns.entry.path)

    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/publishing/#{socket.assigns.type_slug}/edit?path=#{path}",
           locale: socket.assigns.current_locale
         )
     )}
  end

  # ============================================================================
  # COMMENTED OUT: Component-based rendering system - Preview assigns builder
  # ============================================================================
  # This was used to build sample data for the component rendering system.
  # Related to: lib/phoenix_kit/publishing/page_builder.ex
  # ============================================================================

  # Build sample assigns for preview rendering
  # defp build_preview_assigns(_socket) do
  #   %{
  #     user: %{
  #       name: "Preview User",
  #       greeting_time: "Today"
  #     },
  #     stats: %{
  #       total_users: "1,000",
  #       active_projects: 5
  #     },
  #     framework: "Phoenix"
  #   }
  # end
  defp render_markdown_content(content) do
    trimmed = content || ""

    case Earmark.as_html(trimmed) do
      {:ok, html, _warnings} ->
        {:ok, HTML.raw(html)}

      {:error, _html, errors} ->
        message =
          errors
          |> Enum.map(&format_markdown_error/1)
          |> Enum.join("; ")
          |> case do
            "" -> gettext("An unknown error occurred while rendering markdown.")
            err -> gettext("Failed to render markdown: %{message}", message: err)
          end

        {:error, message}
    end
  end

  defp format_markdown_error({severity, line, message})
       when is_atom(severity) and is_integer(line) and is_binary(message) do
    "#{severity} (line #{line}): #{message}"
  end

  defp format_markdown_error(%{line: line, message: message})
       when is_integer(line) and is_binary(message) do
    "line #{line}: #{message}"
  end

  defp format_markdown_error(other), do: inspect(other)
end
