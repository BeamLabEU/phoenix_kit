defmodule PhoenixKit.Modules.Publishing.Web.Preview do
  @moduledoc """
  Preview rendering for publishing posts.

  Shows the full public-facing interface with a preview banner,
  allowing editors to see exactly what visitors will see.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Modules.Publishing.Web.Controller.Translations
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  import PhoenixKit.Modules.Publishing.Web.Components.LanguageSwitcher

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Preview"))
      |> assign(:group_slug, group_slug)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{group_slug}/preview")
      )
      |> assign(:post, nil)
      |> assign(:html_content, nil)
      |> assign(:translations, [])
      |> assign(:breadcrumbs, [])
      |> assign(:version_dropdown, nil)
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
            post = Map.put(post, :uuid, post_uuid)

            # Build the same data as the public controller
            canonical_language = post.language

            translations =
              Translations.build_translation_links(group_slug, post, canonical_language)

            breadcrumbs = PostRendering.build_breadcrumbs(group_slug, post, canonical_language)

            version_dropdown =
              PostRendering.build_version_dropdown(group_slug, post, canonical_language)

            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:group_slug, post.group)
             |> assign(:group_name, Publishing.group_name(post.group) || post.group)
             |> assign(:html_content, rendered_html)
             |> assign(:current_language, canonical_language)
             |> assign(:translations, translations)
             |> assign(:breadcrumbs, breadcrumbs)
             |> assign(:version_dropdown, version_dropdown)
             |> assign(:page_title, post.metadata.title || Constants.default_title())
             |> assign(:error, nil)}

          {:error, error_message} ->
            {:noreply,
             socket
             |> assign(:post, Map.put(post, :uuid, post_uuid))
             |> assign(:group_slug, post.group)
             |> assign(:group_name, Publishing.group_name(post.group) || post.group)
             |> assign(:html_content, nil)
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

  # Delegate to PublishingHTML helpers used in the template
  defdelegate has_publication_date?(post), to: PublishingHTML
  defdelegate format_post_date(post, group_slug), to: PublishingHTML

  @doc false
  def build_preview_translations(translations, post, group_slug) do
    post_uuid = post[:uuid]
    version = post[:version]

    Enum.map(translations, fn translation ->
      code = translation[:code] || translation.code
      query_params = %{"lang" => code}
      query_params = if version, do: Map.put(query_params, "v", version), else: query_params
      query = URI.encode_query(query_params)

      %{
        code: code,
        display_code: translation[:display_code] || code,
        name: translation[:name] || translation.name,
        flag: translation[:flag] || "",
        url: Routes.path("/admin/publishing/#{group_slug}/#{post_uuid}/preview?#{query}"),
        status: "published",
        exists: true
      }
    end)
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
