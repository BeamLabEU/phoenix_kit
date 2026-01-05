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
  alias PhoenixKitWeb.Live.Modules.Blogging.ListingCache
  alias PhoenixKitWeb.Live.Modules.Blogging.PubSub, as: BloggingPubSub
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  @impl true
  def mount(params, _session, socket) do
    blog_slug = params["blog"] || params["category"] || params["type"]

    # Subscribe to PubSub for live updates when connected
    if connected?(socket) && blog_slug do
      BloggingPubSub.subscribe_to_posts(blog_slug)
      BloggingPubSub.subscribe_to_cache(blog_slug)
    end

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

    posts =
      if blog_slug,
        do: Blogging.list_posts(blog_slug, socket.assigns.current_locale_base),
        else: []

    current_path =
      case blog_slug do
        nil -> Routes.path("/admin/blogging", locale: socket.assigns.current_locale_base)
        slug -> Routes.path("/admin/blogging/#{slug}", locale: socket.assigns.current_locale_base)
      end

    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Blogging")
      |> assign(:current_path, current_path)
      |> assign(:blogs, blogs)
      |> assign(:current_blog, current_blog)
      |> assign(:blog_slug, blog_slug)
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:master_language, Storage.get_master_language())
      |> assign(:posts, posts)
      |> assign(:endpoint_url, nil)
      |> assign(:date_time_settings, date_time_settings)
      |> assign(:cache_info, get_cache_info(blog_slug))

    {:ok, redirect_if_missing(socket)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    blog_slug = socket.assigns.blog_slug

    posts =
      case blog_slug do
        nil -> []
        slug -> Blogging.list_posts(slug, socket.assigns.current_locale_base)
      end

    endpoint_url = extract_endpoint_url(uri)

    socket =
      socket
      |> assign(:posts, posts)
      |> assign(:endpoint_url, endpoint_url)
      |> assign(:cache_info, get_cache_info(blog_slug))

    {:noreply, redirect_if_missing(socket)}
  end

  @impl true
  def handle_event("create_post", _params, %{assigns: %{blog_slug: blog_slug}} = socket) do
    # Use redirect for full page refresh to ensure editor JS initializes properly
    {:noreply,
     redirect(socket,
       to:
         Routes.path(
           "/admin/blogging/#{blog_slug}/edit?new=true",
           locale: socket.assigns.current_locale_base
         )
     )}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     assign(
       socket,
       :posts,
       Blogging.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale_base)
     )}
  end

  def handle_event("add_language", %{"path" => post_path, "language" => lang_code}, socket) do
    # Use redirect for full page refresh to ensure editor JS initializes properly
    {:noreply,
     redirect(socket,
       to:
         Routes.path(
           "/admin/blogging/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(post_path)}&switch_to=#{lang_code}",
           locale: socket.assigns.current_locale_base
         )
     )}
  end

  def handle_event("language_action", %{"language" => _lang_code, "path" => path}, socket)
      when is_binary(path) and path != "" do
    # Use redirect for full page refresh to ensure editor JS initializes properly
    {:noreply,
     redirect(socket,
       to:
         Routes.path(
           "/admin/blogging/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(path)}",
           locale: socket.assigns.current_locale_base
         )
     )}
  end

  def handle_event("language_action", %{"language" => lang_code} = params, socket) do
    # For languages without a path (not yet created), add the language
    post_path = params["post_path"] || ""

    if post_path != "" do
      # Use redirect for full page refresh to ensure editor JS initializes properly
      {:noreply,
       redirect(socket,
         to:
           Routes.path(
             "/admin/blogging/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(post_path)}&switch_to=#{lang_code}",
             locale: socket.assigns.current_locale_base
           )
       )}
    else
      {:noreply, socket}
    end
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

            # Broadcast status change to other connected clients
            BloggingPubSub.broadcast_post_status_changed(socket.assigns.blog_slug, updated_post)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :posts,
               Blogging.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale_base)
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
          {:ok, updated_post} ->
            # Broadcast status change to other connected clients
            BloggingPubSub.broadcast_post_status_changed(socket.assigns.blog_slug, updated_post)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :posts,
               Blogging.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale_base)
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update status"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Post not found"))}
    end
  end

  def handle_event("regenerate_file_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug

    case ListingCache.regenerate_file_only(blog_slug) do
      :ok ->
        {:noreply,
         socket
         |> assign(:cache_info, get_cache_info(blog_slug))
         |> put_flash(:info, gettext("File cache regenerated"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to regenerate cache"))}
    end
  end

  def handle_event("invalidate_file_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug
    cache_path = ListingCache.cache_path(blog_slug)

    case File.rm(cache_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> :ok
    end

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(blog_slug))
     |> put_flash(:info, gettext("File cache cleared"))}
  end

  def handle_event("load_memory_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug

    # If file cache is disabled, scan posts directly into memory
    # Otherwise, load from existing file
    if ListingCache.file_cache_enabled?() do
      case ListingCache.load_into_memory(blog_slug) do
        :ok ->
          {:noreply,
           socket
           |> assign(:cache_info, get_cache_info(blog_slug))
           |> put_flash(:info, gettext("Cache loaded into memory"))}

        {:error, :no_file} ->
          {:noreply, put_flash(socket, :error, gettext("No file cache to load from"))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to load cache"))}
      end
    else
      # File cache disabled - scan posts directly into memory
      case ListingCache.regenerate(blog_slug) do
        :ok ->
          {:noreply,
           socket
           |> assign(:cache_info, get_cache_info(blog_slug))
           |> put_flash(:info, gettext("Cache loaded into memory from filesystem scan"))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to scan posts"))}
      end
    end
  end

  def handle_event("invalidate_memory_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug

    # Clear the cache, loaded_at, and file_generated_at timestamps
    try do
      :persistent_term.erase(ListingCache.persistent_term_key(blog_slug))
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(ListingCache.loaded_at_key(blog_slug))
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(ListingCache.file_generated_at_key(blog_slug))
    rescue
      ArgumentError -> :ok
    end

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(blog_slug))
     |> put_flash(:info, gettext("Memory cache cleared"))}
  end

  def handle_event("toggle_file_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug
    current = ListingCache.file_cache_enabled?()
    new_value = !current
    Settings.update_setting("blogging_file_cache_enabled", to_string(new_value))

    message =
      if new_value, do: gettext("File cache enabled"), else: gettext("File cache disabled")

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(blog_slug))
     |> put_flash(:info, message)}
  end

  def handle_event("toggle_memory_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug
    current = ListingCache.memory_cache_enabled?()
    new_value = !current
    Settings.update_setting("blogging_memory_cache_enabled", to_string(new_value))

    # If disabling, clear memory cache
    unless new_value do
      try do
        :persistent_term.erase(ListingCache.persistent_term_key(blog_slug))
      rescue
        ArgumentError -> :ok
      end

      try do
        :persistent_term.erase(ListingCache.loaded_at_key(blog_slug))
      rescue
        ArgumentError -> :ok
      end

      try do
        :persistent_term.erase(ListingCache.file_generated_at_key(blog_slug))
      rescue
        ArgumentError -> :ok
      end
    end

    message =
      if new_value, do: gettext("Memory cache enabled"), else: gettext("Memory cache disabled")

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(blog_slug))
     |> put_flash(:info, message)}
  end

  def handle_event("toggle_render_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug
    current = Renderer.blog_render_cache_enabled?(blog_slug)
    new_value = !current
    Settings.update_setting("blogging_render_cache_enabled_#{blog_slug}", to_string(new_value))

    message =
      if new_value, do: gettext("Render cache enabled"), else: gettext("Render cache disabled")

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(blog_slug))
     |> put_flash(:info, message)}
  end

  def handle_event("clear_render_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug

    case Renderer.clear_blog_cache(blog_slug) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:cache_info, get_cache_info(blog_slug))
         |> put_flash(:info, gettext("Cleared %{count} cached posts", count: count))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to clear cache"))}
    end
  end

  # PubSub handlers for live updates
  @impl true
  def handle_info({:post_created, _post}, socket) do
    # Refresh the posts list when a new post is created
    {:noreply, refresh_posts(socket)}
  end

  def handle_info({:post_updated, _post}, socket) do
    # Refresh the posts list when a post is updated
    {:noreply, refresh_posts(socket)}
  end

  def handle_info({:post_status_changed, _post}, socket) do
    # Refresh the posts list when a post status changes
    {:noreply, refresh_posts(socket)}
  end

  def handle_info({:post_deleted, _post_path}, socket) do
    # Refresh the posts list when a post is deleted
    {:noreply, refresh_posts(socket)}
  end

  def handle_info({:version_created, _post}, socket) do
    # Refresh the posts list when a new version is created
    {:noreply, refresh_posts(socket)}
  end

  def handle_info({:version_live_changed, _post_slug, _version}, socket) do
    # Refresh the posts list when the live version changes
    {:noreply, refresh_posts(socket)}
  end

  def handle_info({:cache_changed, blog_slug}, socket) do
    # Refresh cache info when cache state changes (from visitor loading it, etc.)
    {:noreply, assign(socket, :cache_info, get_cache_info(blog_slug))}
  end

  defp refresh_posts(socket) do
    case socket.assigns.blog_slug do
      nil ->
        socket

      blog_slug ->
        posts = Blogging.list_posts(blog_slug, socket.assigns.current_locale_base)
        assign(socket, :posts, posts)
    end
  end

  defp redirect_if_missing(%{assigns: %{current_blog: nil}} = socket) do
    case socket.assigns.blogs do
      [%{"slug" => slug} | _] ->
        push_navigate(socket,
          to: Routes.path("/admin/blogging/#{slug}", locale: socket.assigns.current_locale_base)
        )

      [] ->
        push_navigate(socket,
          to: Routes.path("/admin/settings/blogging", locale: socket.assigns.current_locale_base)
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

  @doc """
  Builds language data for the blog_language_switcher component.
  Returns a list of language maps with status, path, enabled flag, known flag, and metadata.

  The `enabled` field indicates if the language is currently active in the Languages module.
  The `known` field indicates if the language code is recognized (vs unknown files like "test.phk").
  The `is_master` field indicates if this is the master/primary language for versioning.

  Uses preloaded `language_statuses` from the post to avoid re-reading files on every render.
  """
  def build_post_languages(
        post,
        _blog_slug,
        enabled_languages,
        _current_locale,
        master_language \\ nil
      ) do
    # Use shared ordering function for consistent display across all views
    all_languages =
      Storage.order_languages_for_display(post.available_languages, enabled_languages)

    # Get preloaded language statuses (falls back to empty map for backwards compatibility)
    language_statuses = Map.get(post, :language_statuses) || %{}

    # Get master language if not provided
    master_lang = master_language || Storage.get_master_language()

    Enum.map(all_languages, fn lang_code ->
      lang_path =
        Path.join([
          Path.dirname(post.path),
          "#{lang_code}.phk"
        ])

      lang_info = Blogging.get_language_info(lang_code)
      file_exists = lang_code in post.available_languages
      is_enabled = Storage.language_enabled?(lang_code, enabled_languages)
      is_known = lang_info != nil
      is_master = lang_code == master_lang

      # Use preloaded status instead of re-reading file
      status = Map.get(language_statuses, lang_code)

      # Get display code (base or full dialect depending on enabled languages)
      display_code = Storage.get_display_code(lang_code, enabled_languages)

      %{
        code: lang_code,
        display_code: display_code,
        name: if(lang_info, do: lang_info.name, else: lang_code),
        flag: if(lang_info, do: lang_info.flag, else: ""),
        status: status,
        exists: file_exists,
        enabled: is_enabled,
        known: is_known,
        is_master: is_master,
        path: if(file_exists, do: lang_path, else: nil),
        post_path: post.path
      }
    end)
    |> Enum.filter(fn lang -> lang.exists || lang.enabled end)
  end

  # Cache info helper

  def format_cache_time(nil), do: ""

  def format_cache_time(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} ->
        # Format as relative time if recent, otherwise show date/time
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(now, dt, :second)

        cond do
          diff_seconds < 60 ->
            gettext("just now")

          diff_seconds < 3600 ->
            minutes = div(diff_seconds, 60)
            ngettext("%{count} minute ago", "%{count} minutes ago", minutes, count: minutes)

          diff_seconds < 86_400 ->
            hours = div(diff_seconds, 3600)
            ngettext("%{count} hour ago", "%{count} hours ago", hours, count: hours)

          true ->
            # Show date for older caches
            Calendar.strftime(dt, "%Y-%m-%d %H:%M")
        end

      _ ->
        iso_string
    end
  end

  defp get_cache_info(nil), do: nil

  defp get_cache_info(blog_slug) do
    cache_path = ListingCache.cache_path(blog_slug)
    file_enabled = ListingCache.file_cache_enabled?()
    memory_enabled = ListingCache.memory_cache_enabled?()
    render_enabled = Renderer.blog_render_cache_enabled?(blog_slug)
    render_global_enabled = Renderer.global_render_cache_enabled?()

    # Check if in :persistent_term
    in_memory =
      case :persistent_term.get(ListingCache.persistent_term_key(blog_slug), :not_found) do
        :not_found -> false
        _ -> true
      end

    # Get when memory cache was loaded and what file version it contains
    memory_loaded_at = ListingCache.memory_loaded_at(blog_slug)
    memory_file_generated_at = ListingCache.memory_file_generated_at(blog_slug)

    case File.stat(cache_path) do
      {:ok, stat} ->
        # Read cache to get post count and generated_at
        {post_count, generated_at} =
          case File.read(cache_path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, %{"post_count" => count, "generated_at" => gen_at}} -> {count, gen_at}
                {:ok, %{"post_count" => count}} -> {count, nil}
                _ -> {nil, nil}
              end

            _ ->
              {nil, nil}
          end

        %{
          exists: true,
          file_size: stat.size,
          modified_at: stat.mtime,
          post_count: post_count,
          generated_at: generated_at,
          in_memory: in_memory,
          memory_loaded_at: memory_loaded_at,
          memory_file_generated_at: memory_file_generated_at,
          file_enabled: file_enabled,
          memory_enabled: memory_enabled,
          render_enabled: render_enabled,
          render_global_enabled: render_global_enabled
        }

      {:error, :enoent} ->
        %{
          exists: false,
          file_size: 0,
          modified_at: nil,
          post_count: nil,
          generated_at: nil,
          in_memory: in_memory,
          memory_loaded_at: memory_loaded_at,
          memory_file_generated_at: memory_file_generated_at,
          file_enabled: file_enabled,
          memory_enabled: memory_enabled,
          render_enabled: render_enabled,
          render_global_enabled: render_global_enabled
        }
    end
  end
end
