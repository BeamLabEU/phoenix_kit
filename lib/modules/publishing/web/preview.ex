defmodule PhoenixKit.Modules.Publishing.Web.Preview do
  @moduledoc """
  Preview rendering for publishing posts.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  # alias PhoenixKit.Modules.Publishing.PageBuilder  # COMMENTED OUT: Component system
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, "Preview")
      |> assign(:group_slug, group_slug)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{group_slug}/preview")
      )
      |> assign(:rendered_content, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"post_uuid" => post_uuid} = params, _uri, socket) do
    group_slug = socket.assigns.group_slug
    language = params["lang"]
    version = params["v"]

    case Publishing.read_post_by_uuid(post_uuid, language, version) do
      {:ok, post} ->
        case render_markdown_content(post.content) do
          {:ok, rendered_html} ->
            {:noreply,
             socket
             |> assign(:post, Map.put(post, :uuid, post_uuid))
             |> assign(:group_slug, post.group)
             |> assign(:group_name, Publishing.group_name(post.group) || post.group)
             |> assign(:rendered_content, rendered_html)
             |> assign(:error, nil)}

          {:error, error_message} ->
            {:noreply,
             socket
             |> assign(:post, Map.put(post, :uuid, post_uuid))
             |> assign(:group_slug, post.group)
             |> assign(:group_name, Publishing.group_name(post.group) || post.group)
             |> assign(:rendered_content, nil)
             |> assign(:error, error_message)}
        end

      {:error, reason} ->
        Logger.warning("[Publishing.Preview] Preview failed for #{post_uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("No post specified"))
     |> push_navigate(to: Routes.path("/admin/publishing/#{socket.assigns.group_slug}"))}
  end

  @impl true
  def handle_event("back_to_editor", _params, socket) do
    post = socket.assigns[:post]
    group_slug = socket.assigns.group_slug

    destination =
      if post && post[:uuid] do
        Helpers.build_edit_url(group_slug, post,
          lang: post[:language],
          version: post[:version]
        )
      else
        Routes.path("/admin/publishing/#{group_slug}")
      end

    {:noreply, push_navigate(socket, to: destination)}
  end

  defp render_markdown_content(content) when is_binary(content) do
    content
    |> Renderer.render_markdown()
    |> then(&{:ok, &1})
  rescue
    error ->
      Logger.error("[Publishing.Preview] Markdown rendering failed: #{inspect(error)}")
      {:error, gettext("Failed to render preview.")}
  end
end
