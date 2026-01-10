defmodule PhoenixKit.Modules.Publishing.Web.Blog do
  @moduledoc """
  Lists posts for a blog and provides creation actions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.BlogHTML

  @impl true
  def mount(params, _session, socket) do
    blog_slug = params["blog"] || params["category"] || params["type"]

    # Subscribe to PubSub for live updates when connected
    if connected?(socket) do
      # Global group updates (for sidebar)
      PublishingPubSub.subscribe_to_groups()

      if blog_slug do
        PublishingPubSub.subscribe_to_posts(blog_slug)
        PublishingPubSub.subscribe_to_cache(blog_slug)
        PublishingPubSub.subscribe_to_blog_editors(blog_slug)
      end
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

    blogs = Publishing.list_groups()
    current_blog = Enum.find(blogs, fn blog -> blog["slug"] == blog_slug end)

    # Don't load posts here - handle_params will load them with proper endpoint_url
    # This prevents double rendering where first render has nil endpoint_url

    current_path =
      case blog_slug do
        nil ->
          Routes.path("/admin/publishing", locale: socket.assigns.current_locale_base)

        slug ->
          Routes.path("/admin/publishing/#{slug}", locale: socket.assigns.current_locale_base)
      end

    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Publishing")
      |> assign(:current_path, current_path)
      |> assign(:blogs, blogs)
      |> assign(:current_blog, current_blog)
      |> assign(:blog_slug, blog_slug)
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:master_language, Storage.get_master_language())
      |> assign(:posts, [])
      |> assign(:loading, true)
      |> assign(:endpoint_url, "")
      |> assign(:date_time_settings, date_time_settings)
      |> assign(:cache_info, get_cache_info(blog_slug))
      |> assign(:active_editors, %{})
      |> assign(:translating_posts, %{})
      # Debounce timers for post updates (prevents disk hammering on rapid saves)
      |> assign(:pending_post_updates, %{})

    {:ok, redirect_if_missing(socket)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    new_blog_slug = params["blog"] || params["category"] || params["type"]
    old_blog_slug = socket.assigns[:blog_slug]

    # Handle subscription changes when switching blogs
    socket =
      if connected?(socket) && new_blog_slug != old_blog_slug do
        # Unsubscribe from old blog's topics
        if old_blog_slug do
          PublishingPubSub.unsubscribe_from_posts(old_blog_slug)
          PublishingPubSub.unsubscribe_from_cache(old_blog_slug)
          PublishingPubSub.unsubscribe_from_blog_editors(old_blog_slug)
        end

        # Subscribe to new blog's topics
        if new_blog_slug do
          PublishingPubSub.subscribe_to_posts(new_blog_slug)
          PublishingPubSub.subscribe_to_cache(new_blog_slug)
          PublishingPubSub.subscribe_to_blog_editors(new_blog_slug)
        end

        # Reset editor tracking state for new blog
        socket
        |> assign(:blog_slug, new_blog_slug)
        |> assign(:active_editors, %{})
        |> assign(:translating_posts, %{})
        |> assign(:pending_post_updates, %{})
      else
        assign(socket, :blog_slug, new_blog_slug)
      end

    # Update current blog
    blogs = socket.assigns[:blogs] || Publishing.list_groups()
    current_blog = Enum.find(blogs, fn blog -> blog["slug"] == new_blog_slug end)

    endpoint_url = extract_endpoint_url(uri)

    # Only load posts when connected to avoid double render flicker
    # During disconnected render, show loading state
    {posts, loading} =
      if connected?(socket) do
        posts =
          case new_blog_slug do
            nil -> []
            slug -> Publishing.list_posts(slug, socket.assigns.current_locale_base)
          end

        {posts, false}
      else
        {[], true}
      end

    socket =
      socket
      |> assign(:current_blog, current_blog)
      |> assign(:posts, posts)
      |> assign(:loading, loading)
      |> assign(:endpoint_url, endpoint_url)
      |> assign(:cache_info, get_cache_info(new_blog_slug))

    {:noreply, redirect_if_missing(socket)}
  end

  @impl true
  def handle_event("create_post", _params, %{assigns: %{blog_slug: blog_slug}} = socket) do
    # Use redirect for full page refresh to ensure editor JS initializes properly
    {:noreply,
     redirect(socket,
       to:
         Routes.path(
           "/admin/publishing/#{blog_slug}/edit?new=true",
           locale: socket.assigns.current_locale_base
         )
     )}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     assign(
       socket,
       :posts,
       Publishing.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale_base)
     )}
  end

  def handle_event("add_language", %{"path" => post_path, "language" => lang_code}, socket) do
    # Use redirect for full page refresh to ensure editor JS initializes properly
    {:noreply,
     redirect(socket,
       to:
         Routes.path(
           "/admin/publishing/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(post_path)}&switch_to=#{lang_code}",
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
           "/admin/publishing/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(path)}",
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
             "/admin/publishing/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(post_path)}&switch_to=#{lang_code}",
             locale: socket.assigns.current_locale_base
           )
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change_status", %{"path" => post_path, "status" => new_status}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Publishing.read_post(socket.assigns.blog_slug, post_path) do
      {:ok, post} ->
        case Publishing.update_post(socket.assigns.blog_slug, post, %{"status" => new_status}, %{
               scope: scope
             }) do
          {:ok, updated_post} ->
            # Invalidate cache for this post
            invalidate_post_cache(socket.assigns.blog_slug, updated_post)

            # Broadcast status change to other connected clients
            PublishingPubSub.broadcast_post_status_changed(socket.assigns.blog_slug, updated_post)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :posts,
               Publishing.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale_base)
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

    case Publishing.read_post(socket.assigns.blog_slug, post_path) do
      {:ok, post} ->
        case Publishing.update_post(socket.assigns.blog_slug, post, %{"status" => new_status}, %{
               scope: scope
             }) do
          {:ok, updated_post} ->
            # Broadcast status change to other connected clients
            PublishingPubSub.broadcast_post_status_changed(socket.assigns.blog_slug, updated_post)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :posts,
               Publishing.list_posts(socket.assigns.blog_slug, socket.assigns.current_locale_base)
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
        # Notify other dashboards about cache change
        PublishingPubSub.broadcast_cache_changed(blog_slug)

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

    # Notify other dashboards about cache change
    PublishingPubSub.broadcast_cache_changed(blog_slug)

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
          # Notify other dashboards about cache change
          PublishingPubSub.broadcast_cache_changed(blog_slug)

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
          # Notify other dashboards about cache change
          PublishingPubSub.broadcast_cache_changed(blog_slug)

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

    # Notify other dashboards about cache change
    PublishingPubSub.broadcast_cache_changed(blog_slug)

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(blog_slug))
     |> put_flash(:info, gettext("Memory cache cleared"))}
  end

  def handle_event("toggle_file_cache", _params, socket) do
    blog_slug = socket.assigns.blog_slug
    current = ListingCache.file_cache_enabled?()
    new_value = !current
    Settings.update_setting("publishing_file_cache_enabled", to_string(new_value))

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
    Settings.update_setting("publishing_memory_cache_enabled", to_string(new_value))

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
    Settings.update_setting(Renderer.per_blog_cache_key(blog_slug), to_string(new_value))

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
    # Add new post to the list (at beginning since sorted by published_at desc)
    # We do a full refresh since the new post needs to be in the right position
    # based on sorting and the broadcast post may not have all required fields
    {:noreply, refresh_posts(socket)}
  end

  def handle_info({:post_updated, updated_post}, socket) do
    # Debounce post updates to prevent disk hammering on rapid saves
    socket = schedule_debounced_update(socket, updated_post)
    {:noreply, socket}
  end

  def handle_info({:post_status_changed, updated_post}, socket) do
    # Debounce status changes as well
    socket = schedule_debounced_update(socket, updated_post)
    {:noreply, socket}
  end

  def handle_info({:debounced_post_update, post_slug}, socket) do
    # Timer fired - now do the actual update
    socket = do_debounced_update(socket, post_slug)
    {:noreply, socket}
  end

  def handle_info({:post_deleted, post_path}, socket) do
    # Remove the deleted post from the list
    socket = remove_post_from_list(socket, post_path)
    {:noreply, socket}
  end

  def handle_info({:version_created, updated_post}, socket) do
    # Incrementally update the post with new version info
    socket = update_post_in_list(socket, updated_post)
    {:noreply, socket}
  end

  def handle_info({:version_live_changed, post_slug, _version}, socket) do
    # Refresh the specific post since live version change affects displayed content
    socket = refresh_post_by_slug(socket, post_slug)
    {:noreply, socket}
  end

  def handle_info({:version_deleted, post_slug, _version}, socket) do
    # Refresh the specific post since version deletion affects available versions
    socket = refresh_post_by_slug(socket, post_slug)
    {:noreply, socket}
  end

  def handle_info({:cache_changed, blog_slug}, socket) do
    # Refresh cache info when cache state changes (from visitor loading it, etc.)
    {:noreply, assign(socket, :cache_info, get_cache_info(blog_slug))}
  end

  # Editor presence handlers - show who's currently editing posts
  def handle_info({:editor_joined, post_slug, user_info}, socket) do
    # Only show actual editors (owners), not spectators
    if user_info[:role] == :owner do
      active_editors = socket.assigns.active_editors
      post_editors = Map.get(active_editors, post_slug, [])

      # Add user if not already in the list
      updated_editors =
        if Enum.any?(post_editors, fn e -> e.socket_id == user_info.socket_id end) do
          post_editors
        else
          [user_info | post_editors]
        end

      {:noreply,
       assign(socket, :active_editors, Map.put(active_editors, post_slug, updated_editors))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_left, post_slug, user_info}, socket) do
    active_editors = socket.assigns.active_editors
    post_editors = Map.get(active_editors, post_slug, [])

    # Remove user from the list
    updated_editors = Enum.reject(post_editors, fn e -> e.socket_id == user_info.socket_id end)

    updated_active_editors =
      if updated_editors == [] do
        Map.delete(active_editors, post_slug)
      else
        Map.put(active_editors, post_slug, updated_editors)
      end

    {:noreply, assign(socket, :active_editors, updated_active_editors)}
  end

  # Translation progress handlers - show translation status on posts
  def handle_info({:translation_started, post_slug, language_count}, socket) do
    translating =
      Map.put(socket.assigns.translating_posts, post_slug, %{
        total: language_count,
        completed: 0,
        status: :in_progress
      })

    {:noreply, assign(socket, :translating_posts, translating)}
  end

  def handle_info({:translation_completed, post_slug, results}, socket) do
    # Mark translation as complete, then remove after a delay
    translating =
      Map.put(socket.assigns.translating_posts, post_slug, %{
        status: :completed,
        success_count: results.success_count,
        failure_count: results.failure_count
      })

    socket = assign(socket, :translating_posts, translating)

    # Also refresh posts to show new translations
    socket = refresh_posts(socket)

    # Clear the status after 5 seconds
    Process.send_after(self(), {:clear_translation_status, post_slug}, 5000)

    {:noreply, socket}
  end

  def handle_info({:clear_translation_status, post_slug}, socket) do
    translating = Map.delete(socket.assigns.translating_posts, post_slug)
    {:noreply, assign(socket, :translating_posts, translating)}
  end

  # Group change handlers - keep sidebar in sync
  def handle_info({:group_created, _group}, socket) do
    {:noreply, assign(socket, :blogs, Publishing.list_groups())}
  end

  def handle_info({:group_updated, group}, socket) do
    blogs = Publishing.list_groups()
    current_blog = Enum.find(blogs, fn b -> b["slug"] == socket.assigns.blog_slug end)

    socket =
      socket
      |> assign(:blogs, blogs)
      |> assign(:current_blog, current_blog || group)

    {:noreply, socket}
  end

  def handle_info({:group_deleted, deleted_slug}, socket) do
    blogs = Publishing.list_groups()

    socket =
      if socket.assigns.blog_slug == deleted_slug do
        # Current group was deleted - redirect to first available
        case blogs do
          [%{"slug" => slug} | _] ->
            push_navigate(socket,
              to:
                Routes.path("/admin/publishing/#{slug}",
                  locale: socket.assigns.current_locale_base
                )
            )

          [] ->
            push_navigate(socket,
              to:
                Routes.path("/admin/settings/publishing",
                  locale: socket.assigns.current_locale_base
                )
            )
        end
      else
        assign(socket, :blogs, blogs)
      end

    {:noreply, socket}
  end

  defp refresh_posts(socket) do
    case socket.assigns.blog_slug do
      nil ->
        socket

      blog_slug ->
        posts = Publishing.list_posts(blog_slug, socket.assigns.current_locale_base)
        assign(socket, :posts, posts)
    end
  end

  # Debounce interval for post updates (500ms)
  @update_debounce_ms 500

  # Schedule a debounced update for a post
  defp schedule_debounced_update(socket, updated_post) do
    post_slug = updated_post[:slug] || updated_post["slug"]

    if post_slug do
      pending = socket.assigns[:pending_post_updates] || %{}

      # Cancel existing timer for this post if any
      if timer_ref = Map.get(pending, post_slug) do
        Process.cancel_timer(timer_ref)
      end

      # Schedule new debounced update
      timer_ref =
        Process.send_after(self(), {:debounced_post_update, post_slug}, @update_debounce_ms)

      assign(socket, :pending_post_updates, Map.put(pending, post_slug, timer_ref))
    else
      socket
    end
  end

  # Execute debounced update when timer fires
  defp do_debounced_update(socket, post_slug) do
    # Clear the timer from pending
    pending = socket.assigns[:pending_post_updates] || %{}
    socket = assign(socket, :pending_post_updates, Map.delete(pending, post_slug))

    # Do the actual update
    refresh_post_by_slug(socket, post_slug)
  end

  # Incrementally update a single post in the list by slug
  # We refresh the full post from storage to ensure all fields are current
  # (available_versions, language_slugs, version_statuses, etc.)
  defp update_post_in_list(socket, updated_post) do
    post_slug = updated_post[:slug] || updated_post["slug"]
    can_update? = post_slug && socket.assigns[:posts] && socket.assigns[:blog_slug]

    if can_update? do
      fetch_and_update_post(socket, post_slug)
    else
      refresh_posts(socket)
    end
  end

  defp fetch_and_update_post(socket, post_slug) do
    case Publishing.read_post(
           socket.assigns.blog_slug,
           post_slug,
           socket.assigns.current_locale_base,
           nil
         ) do
      {:ok, fresh_post} ->
        replace_post_in_list(socket, post_slug, fresh_post)

      {:error, _} ->
        # Post may have been deleted or unreadable - full refresh
        refresh_posts(socket)
    end
  end

  defp replace_post_in_list(socket, post_slug, fresh_post) do
    updated_posts =
      Enum.map(socket.assigns.posts, fn post ->
        if post[:slug] == post_slug, do: fresh_post, else: post
      end)

    assign(socket, :posts, updated_posts)
  end

  # Remove a post from the list by path
  defp remove_post_from_list(socket, post_path) do
    if socket.assigns[:posts] do
      # Extract slug from path (e.g., "blog/my-post/v1/en.phk" -> "my-post")
      post_slug = extract_slug_from_path(post_path)

      updated_posts =
        Enum.reject(socket.assigns.posts, fn post ->
          post[:slug] == post_slug || post[:path] == post_path
        end)

      assign(socket, :posts, updated_posts)
    else
      socket
    end
  end

  # Refresh a single post by slug (used when we need fresh data from storage)
  defp refresh_post_by_slug(socket, post_slug) do
    case socket.assigns.blog_slug do
      nil ->
        socket

      blog_slug ->
        case Publishing.read_post(blog_slug, post_slug, socket.assigns.current_locale_base, nil) do
          {:ok, fresh_post} ->
            update_post_in_list(socket, fresh_post)

          {:error, _} ->
            # Post might have been deleted - refresh all
            refresh_posts(socket)
        end
    end
  end

  # Extract post slug from a full path
  defp extract_slug_from_path(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.at(1)
  end

  defp extract_slug_from_path(_), do: nil

  defp redirect_if_missing(%{assigns: %{current_blog: nil}} = socket) do
    case socket.assigns.blogs do
      [%{"slug" => slug} | _] ->
        push_navigate(socket,
          to: Routes.path("/admin/publishing/#{slug}", locale: socket.assigns.current_locale_base)
        )

      [] ->
        push_navigate(socket,
          to:
            Routes.path("/admin/settings/publishing", locale: socket.assigns.current_locale_base)
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

      lang_info = Publishing.get_language_info(lang_code)
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
