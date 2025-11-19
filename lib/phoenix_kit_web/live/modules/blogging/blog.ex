defmodule PhoenixKitWeb.Live.Modules.Blogging.Blog do
  @moduledoc """
  Lists posts for a blog and provides creation actions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Blogging.Renderer
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.BlogHTML
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  @impl true
  def mount(params, _session, socket) do
    blog_slug = params["blog"] || params["category"] || params["type"]
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Load date/time format settings once for performance
    date_time_settings =
      Settings.get_settings_cached(
        ["date_format", "time_format", "time_zone"],
        %{
          "date_format" => "Y-m-d",
          "time_format" => "H:i",
          "time_zone" => "0"
        }
      )

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
      |> assign(:endpoint_url, nil)
      |> assign(:date_time_settings, date_time_settings)

    {:ok, redirect_if_missing(socket)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    posts =
      case socket.assigns.blog_slug do
        nil -> []
        slug -> Blogging.list_posts(slug, socket.assigns.current_locale)
      end

    endpoint_url = extract_endpoint_url(uri)

    socket =
      socket
      |> assign(:posts, posts)
      |> assign(:endpoint_url, endpoint_url)

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

  def handle_event("change_status", %{"path" => post_path, "status" => new_status}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Blogging.read_post(socket.assigns.blog_slug, post_path) do
      {:ok, post} ->
        case Blogging.update_post(socket.assigns.blog_slug, post, %{"status" => new_status}, %{
               scope: scope
             }) do
          {:ok, updated_post} ->
            # Invalidate cache for this post
            invalidate_post_cache(socket.assigns.blog_slug, updated_post)

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

  def handle_event(
        "toggle_status",
        %{"path" => post_path, "current-status" => current_status},
        socket
      ) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    new_status =
      case current_status do
        "draft" -> "published"
        "published" -> "archived"
        "archived" -> "draft"
        _ -> "draft"
      end

    case Blogging.read_post(socket.assigns.blog_slug, post_path) do
      {:ok, post} ->
        case Blogging.update_post(socket.assigns.blog_slug, post, %{"status" => new_status}, %{
               scope: scope
             }) do
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

  def format_datetime(
        %{date: %Date{} = date, time: %Time{} = time},
        current_user,
        date_time_settings
      ) do
    # Fallback to dummy user if current_user is nil
    user = current_user || %{user_timezone: nil}

    # Dates and times are already in the timezone they were created in
    # Just format them with user preferences
    date_str = UtilsDate.format_date_with_user_timezone_cached(date, user, date_time_settings)
    time_str = UtilsDate.format_time_with_user_timezone_cached(time, user, date_time_settings)
    "#{date_str} #{gettext("at")} #{time_str}"
  end

  def format_datetime(
        %{metadata: %{published_at: published_at}},
        current_user,
        date_time_settings
      )
      when is_binary(published_at) do
    # Fallback to dummy user if current_user is nil
    user = current_user || %{user_timezone: nil}

    case DateTime.from_iso8601(published_at) do
      {:ok, dt, _} ->
        # Convert DateTime to NaiveDateTime (assuming stored as UTC)
        naive_dt = DateTime.to_naive(dt)

        # Format date part with timezone conversion
        date_str =
          UtilsDate.format_date_with_user_timezone_cached(naive_dt, user, date_time_settings)

        # Format time part with timezone conversion
        time_str =
          UtilsDate.format_time_with_user_timezone_cached(naive_dt, user, date_time_settings)

        "#{date_str} #{gettext("at")} #{time_str}"

      _ ->
        gettext("Unsaved draft")
    end
  end

  def format_datetime(_post, _user, _settings), do: gettext("Unsaved draft")

  defp extract_endpoint_url(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, port: port} when not is_nil(scheme) and not is_nil(host) ->
        port_string = if port in [80, 443], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port_string}"

      _ ->
        ""
    end
  end

  defp extract_endpoint_url(_), do: ""

  defp invalidate_post_cache(blog_slug, post) do
    # Determine identifier based on post mode
    identifier =
      case post.mode do
        :slug -> post.slug
        _ -> post.path
      end

    # Invalidate the render cache for this post
    Renderer.invalidate_cache(blog_slug, identifier, post.language)
  end
end
