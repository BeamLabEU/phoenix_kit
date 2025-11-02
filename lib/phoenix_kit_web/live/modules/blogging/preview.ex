defmodule PhoenixKitWeb.Live.Modules.Blogging.Preview do
  @moduledoc """
  Preview rendering for .phk blogging posts.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.HTML
  alias PhoenixKitWeb.Live.Modules.Blogging
  # alias PhoenixKitWeb.Live.Modules.Blogging.PageBuilder  # COMMENTED OUT: Component system
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    blog_slug = params["blog"] || params["category"] || params["type"]
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Preview")
      |> assign(:blog_slug, blog_slug)
      |> assign(:blog_name, Blogging.blog_name(blog_slug) || blog_slug)
      |> assign(
        :current_path,
        Routes.path("/admin/blogging/#{blog_slug}/preview", locale: locale)
      )
      |> assign(:rendered_content, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"path" => path}, _uri, socket) do
    blog_slug = socket.assigns.blog_slug

    case Blogging.read_post(blog_slug, path) do
      {:ok, post} ->
        case render_markdown_content(post.content) do
          {:ok, rendered_html} ->
            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:rendered_content, rendered_html)
             |> assign(:error, nil)}

          {:error, error_message} ->
            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:rendered_content, nil)
             |> assign(:error, error_message)}
        end

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(
           to:
             Routes.path("/admin/blogging/#{blog_slug}",
               locale: socket.assigns.current_locale
             )
         )}
    end
  end

  @impl true
  def handle_event("back_to_editor", _params, socket) do
    path = URI.encode(socket.assigns.post.path)

    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/blogging/#{socket.assigns.blog_slug}/edit?path=#{path}",
           locale: socket.assigns.current_locale
         )
     )}
  end

  # ============================================================================
  # COMMENTED OUT: Component-based rendering system - Preview assigns builder
  # ============================================================================
  # This was used to build sample data for the component rendering system.
  # Related to: lib/phoenix_kit/blogging/page_builder.ex
  # ============================================================================

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
