defmodule PhoenixKitWeb.Live.Modules.Blogging.Blog do
  @moduledoc """
  Lists posts for a blog and provides creation actions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    blog_slug = params["blog"] || params["category"] || params["type"]
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    blogs = Blogging.list_blogs()
    current_blog = Enum.find(blogs, fn blog -> blog["slug"] == blog_slug end)
    posts = if blog_slug, do: Blogging.list_posts(blog_slug, locale), else: []

    current_path =
      case blog_slug do
        nil -> Routes.path("/admin/blogging", locale: locale)
        slug -> Routes.path("/admin/blogging/#{slug}", locale: locale)
      end

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Blogging")
      |> assign(:current_path, current_path)
      |> assign(:blogs, blogs)
      |> assign(:current_blog, current_blog)
      |> assign(:blog_slug, blog_slug)
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:posts, posts)

    {:ok, redirect_if_missing(socket)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    posts =
      case socket.assigns.blog_slug do
        nil -> []
        slug -> Blogging.list_posts(slug, socket.assigns.current_locale)
      end

    socket =
      socket
      |> assign(:posts, posts)

    {:noreply, redirect_if_missing(socket)}
  end

  @impl true
  def handle_event("create_post", _params, %{assigns: %{blog_slug: blog_slug}} = socket) do
    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/blogging/#{blog_slug}/edit?new=true",
           locale: socket.assigns.current_locale
         )
     )}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     assign(
       socket,
       :posts,
       Blogging.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale)
     )}
  end

  def handle_event("add_language", %{"path" => post_path, "language" => lang_code}, socket) do
    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/blogging/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(post_path)}&switch_to=#{lang_code}",
           locale: socket.assigns.current_locale
         )
     )}
  end

  def handle_event(
        "toggle_status",
        %{"path" => post_path, "current-status" => current_status},
        socket
      ) do
    new_status =
      case current_status do
        "draft" -> "published"
        "published" -> "archived"
        "archived" -> "draft"
        _ -> "draft"
      end

    case Blogging.read_post(socket.assigns.blog_slug, post_path) do
      {:ok, post} ->
        case Blogging.update_post(socket.assigns.blog_slug, post, %{"status" => new_status}) do
          {:ok, _updated_post} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :posts,
               Blogging.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale)
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update status"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Post not found"))}
    end
  end

  defp redirect_if_missing(%{assigns: %{current_blog: nil}} = socket) do
    case socket.assigns.blogs do
      [%{"slug" => slug} | _] ->
        push_navigate(socket,
          to: Routes.path("/admin/blogging/#{slug}", locale: socket.assigns.current_locale)
        )

      [] ->
        push_navigate(socket,
          to: Routes.path("/admin/settings/blogging", locale: socket.assigns.current_locale)
        )
    end
  end

  defp redirect_if_missing(socket), do: socket

  defp format_datetime(%{date: %Date{} = date, time: %Time{} = time}) do
    date_str = Calendar.strftime(date, "%B %d, %Y")
    time_str = Calendar.strftime(time, "%I:%M %p")
    "#{date_str} #{gettext("at")} #{time_str}"
  end

  defp format_datetime(%{metadata: %{published_at: published_at}}) when is_binary(published_at) do
    with {:ok, dt, _} <- DateTime.from_iso8601(published_at) do
      date_str = Calendar.strftime(dt, "%B %d, %Y")
      time_str = Calendar.strftime(dt, "%I:%M %p")
      "#{date_str} #{gettext("at")} #{time_str}"
    else
      _ -> gettext("Unsaved draft")
    end
  end

  defp format_datetime(_post), do: gettext("Unsaved draft")
end
