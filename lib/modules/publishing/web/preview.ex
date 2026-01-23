defmodule PhoenixKit.Modules.Publishing.Web.Preview do
  @moduledoc """
  Preview rendering for .phk publishing posts.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger
  alias Phoenix.HTML
  alias PhoenixKit.Modules.Publishing
  # alias PhoenixKit.Modules.Publishing.PageBuilder  # COMMENTED OUT: Component system
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    blog_slug = params["blog"] || params["category"] || params["type"]

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, "Preview")
      |> assign(:blog_slug, blog_slug)
      |> assign(:blog_name, Publishing.group_name(blog_slug) || blog_slug)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{blog_slug}/preview")
      )
      |> assign(:rendered_content, nil)
      |> assign(:error, nil)
      |> assign(:preview_source, :saved)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    cond do
      Map.has_key?(params, "preview_token") ->
        handle_preview_token(params, socket)

      Map.has_key?(params, "path") ->
        handle_saved_preview(params, socket)

      true ->
        {:noreply, socket}
    end
  end

  defp handle_preview_token(%{"preview_token" => token} = params, socket) do
    endpoint = socket.endpoint || PhoenixKitWeb.Endpoint

    case Phoenix.Token.verify(endpoint, "blog-preview", token, max_age: 300) do
      {:ok, data} ->
        post =
          build_preview_post(data, socket.assigns.blog_slug, socket.assigns.current_locale_base)

        case render_markdown_content(data[:content] || "") do
          {:ok, rendered_html} ->
            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:blog_slug, post.group)
             |> assign(:blog_name, Publishing.group_name(post.group) || post.group)
             |> assign(:rendered_content, rendered_html)
             |> assign(:preview_token, token)
             |> assign(:preview_data, data)
             |> assign(:error, nil)
             |> assign(:preview_source, :unsaved)}

          {:error, error_message} ->
            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:blog_slug, post.group)
             |> assign(:blog_name, Publishing.group_name(post.group) || post.group)
             |> assign(:rendered_content, nil)
             |> assign(:preview_token, token)
             |> assign(:preview_data, data)
             |> assign(:error, error_message)
             |> assign(:preview_source, :unsaved)}
        end

      {:error, _reason} ->
        params
        |> Map.delete("preview_token")
        |> handle_saved_preview(socket)
    end
  end

  defp handle_saved_preview(%{"path" => path}, socket) do
    blog_slug = socket.assigns.blog_slug

    case Publishing.read_post(blog_slug, path) do
      {:ok, post} ->
        case render_markdown_content(post.content) do
          {:ok, rendered_html} ->
            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:rendered_content, rendered_html)
             |> assign(:preview_token, nil)
             |> assign(:preview_data, nil)
             |> assign(:error, nil)
             |> assign(:preview_source, :saved)}

          {:error, error_message} ->
            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:rendered_content, nil)
             |> assign(:preview_token, nil)
             |> assign(:preview_data, nil)
             |> assign(:error, error_message)
             |> assign(:preview_source, :saved)}
        end

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{blog_slug}"))}
    end
  end

  defp handle_saved_preview(_params, socket), do: {:noreply, socket}
  @impl true
  def handle_event("back_to_editor", _params, socket) do
    query = socket |> preview_return_params() |> encode_query()

    destination =
      Routes.path("/admin/publishing/#{socket.assigns.blog_slug}/edit#{query}")

    {:noreply, push_navigate(socket, to: destination)}
  end

  # ============================================================================
  # COMMENTED OUT: Component-based rendering system - Preview assigns builder
  # ============================================================================
  # This was used to build sample data for the component rendering system.
  # Related to: lib/modules/publishing/page_builder.ex
  # ============================================================================

  defp render_markdown_content(content) when is_binary(content) do
    content
    |> Renderer.render_markdown()
    |> HTML.raw()
    |> then(&{:ok, &1})
  rescue
    error ->
      Logger.error("Preview markdown rendering failed", error: inspect(error))
      {:error, gettext("Failed to render markdown preview.")}
  end

  defp build_preview_post(data, fallback_blog_slug, fallback_locale) do
    blog_slug = data[:blog_slug] || fallback_blog_slug
    language = data[:language] || fallback_locale
    mode = data[:mode] || :timestamp
    metadata = extract_preview_metadata(data[:metadata] || %{})
    path = resolve_preview_path(data[:path], blog_slug, metadata[:slug], language, mode)

    available_languages = data[:available_languages] || []

    available_languages =
      [language | available_languages] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      group: blog_slug,
      slug: metadata[:slug],
      date: nil,
      time: nil,
      path: path,
      full_path: nil,
      metadata: metadata,
      content: data[:content] || "",
      language: language,
      available_languages: available_languages,
      mode: mode
    }
  end

  defp extract_preview_metadata(raw_metadata) do
    Enum.reduce(raw_metadata, %{title: "", status: "draft", published_at: nil, slug: nil}, fn
      {key, value}, acc when key in [:title, :status, :published_at, :slug] ->
        Map.put(acc, key, value)

      {"title", value}, acc ->
        Map.put(acc, :title, value)

      {"status", value}, acc ->
        Map.put(acc, :status, value)

      {"published_at", value}, acc ->
        Map.put(acc, :published_at, value)

      {"slug", value}, acc ->
        Map.put(acc, :slug, value)

      _, acc ->
        acc
    end)
  end

  defp resolve_preview_path(path, _blog_slug, _slug, _language, _mode)
       when is_binary(path) and path != "" do
    path
  end

  defp resolve_preview_path(_path, blog_slug, slug, language, :slug)
       when is_binary(slug) and slug != "" do
    Path.join([blog_slug, slug, "#{language}.phk"])
  end

  defp resolve_preview_path(_, _blog_slug, _slug, _language, _mode), do: nil

  defp preview_return_params(socket) do
    base =
      %{}
      |> maybe_put_path_param(socket.assigns.post.path)

    base
    |> maybe_put_preview_token(socket.assigns[:preview_token])
    |> maybe_put_new_flag(socket.assigns[:preview_data])
  end

  defp maybe_put_path_param(params, path) when is_binary(path) and path != "" do
    Map.put(params, "path", path)
  end

  defp maybe_put_path_param(params, _), do: params

  defp maybe_put_preview_token(params, token) when is_binary(token) and token != "" do
    Map.put(params, "preview_token", token)
  end

  defp maybe_put_preview_token(params, _), do: params

  defp maybe_put_new_flag(params, %{is_new_post: true}), do: Map.put(params, "new", "true")
  defp maybe_put_new_flag(params, _), do: params

  defp encode_query(params) do
    case URI.encode_query(params) do
      "" -> ""
      encoded -> "?" <> encoded
    end
  end
end
