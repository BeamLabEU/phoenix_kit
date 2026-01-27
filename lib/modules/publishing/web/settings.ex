defmodule PhoenixKit.Modules.Publishing.Web.Settings do
  @moduledoc """
  Admin configuration for site blogs.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # New settings keys (write to these)
  @file_cache_key "publishing_file_cache_enabled"
  @memory_cache_key "publishing_memory_cache_enabled"
  @render_cache_key "publishing_render_cache_enabled"

  # Legacy settings keys (read from these as fallback)
  @legacy_file_cache_key "blogging_file_cache_enabled"
  @legacy_memory_cache_key "blogging_memory_cache_enabled"
  @legacy_render_cache_key "blogging_render_cache_enabled"

  def mount(_params, _session, socket) do
    # Subscribe to group changes for live updates
    if connected?(socket) do
      PublishingPubSub.subscribe_to_groups()
    end

    blogs = Publishing.list_groups()
    languages_enabled = Languages.enabled?()

    # Add legacy status and primary language migration status to each blog
    blogs_with_status =
      blogs
      |> add_legacy_status()
      |> add_primary_language_status()

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Manage Publishing"))
      |> assign(
        :current_path,
        Routes.path("/admin/settings/publishing")
      )
      |> assign(:module_enabled, Publishing.enabled?())
      |> assign(:blogs, blogs_with_status)
      |> assign(:languages_enabled, languages_enabled)
      |> assign(:global_primary_language, Storage.get_primary_language())
      |> assign(:file_cache_enabled, get_cache_setting(@file_cache_key, @legacy_file_cache_key))
      |> assign(
        :memory_cache_enabled,
        get_cache_setting(@memory_cache_key, @legacy_memory_cache_key)
      )
      |> assign(
        :render_cache_enabled,
        get_cache_setting(@render_cache_key, @legacy_render_cache_key)
      )
      |> assign(:cache_status, build_cache_status(blogs))
      |> assign(:render_cache_stats, get_render_cache_stats())
      |> assign(:render_cache_per_blog, build_render_cache_per_blog(blogs))

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("remove_group", %{"slug" => slug}, socket) do
    case Publishing.trash_group(slug) do
      {:ok, trashed_name} ->
        # The `Publishing.trash_group` call triggers `remove_group`, which handles
        # the broadcast. This LiveView will catch the event and update its state.
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Blog moved to trash as: %{name}", name: trashed_name)
         )}

      {:error, :not_found} ->
        # Blog directory doesn't exist, just remove from config
        case Publishing.remove_group(slug) do
          {:ok, _} ->
            # The `Publishing.remove_group` call handles the broadcast. This
            # LiveView will catch the event and update its state.
            {:noreply,
             put_flash(socket, :info, gettext("Blog removed from configuration"))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to remove blog"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move blog to trash"))}
    end
  end

  def handle_event("regenerate_cache", %{"slug" => slug}, socket) do
    case ListingCache.regenerate(slug) do
      :ok ->
        {:noreply,
         socket
         |> assign(:cache_status, build_cache_status(socket.assigns.blogs))
         |> put_flash(:info, gettext("Cache regenerated for %{blog}", blog: slug))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to regenerate cache"))}
    end
  end

  def handle_event("invalidate_cache", %{"slug" => slug}, socket) do
    ListingCache.invalidate(slug)

    {:noreply,
     socket
     |> assign(:cache_status, build_cache_status(socket.assigns.blogs))
     |> put_flash(:info, gettext("Cache cleared for %{blog}", blog: slug))}
  end

  def handle_event("migrate_storage", %{"slug" => slug}, socket) do
    case Publishing.migrate_group(slug) do
      {:ok, _new_path} ->
        # Refresh blogs list with updated legacy status
        blogs =
          Publishing.list_groups()
          |> add_legacy_status()
          |> add_primary_language_status()

        {:noreply,
         socket
         |> assign(:blogs, blogs)
         |> assign(:cache_status, build_cache_status(blogs))
         |> put_flash(:info, gettext("Storage migrated for %{blog}", blog: slug))}

      {:error, :already_migrated} ->
        {:noreply,
         put_flash(socket, :info, gettext("Storage already migrated for %{blog}", blog: slug))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Blog not found: %{blog}", blog: slug))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to migrate storage: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("migrate_primary_language", %{"slug" => slug}, socket) do
    case Publishing.migrate_posts_to_current_primary_language(slug) do
      {:ok, count} ->
        # Refresh blogs list with updated status
        blogs =
          Publishing.list_groups()
          |> add_legacy_status()
          |> add_primary_language_status()

        {:noreply,
         socket
         |> assign(:blogs, blogs)
         |> assign(:cache_status, build_cache_status(blogs))
         |> put_flash(
           :info,
           gettext("Updated %{count} posts to use primary language: %{lang}",
             count: count,
             lang: socket.assigns.global_primary_language
           )
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to migrate primary language: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("regenerate_all_caches", _params, socket) do
    results =
      Enum.map(socket.assigns.blogs, fn blog ->
        {blog["slug"], ListingCache.regenerate(blog["slug"])}
      end)

    success_count = Enum.count(results, fn {_, result} -> result == :ok end)

    {:noreply,
     socket
     |> assign(:cache_status, build_cache_status(socket.assigns.blogs))
     |> put_flash(:info, gettext("Regenerated %{count} caches", count: success_count))}
  end

  def handle_event("toggle_file_cache", _params, socket) do
    new_value = !socket.assigns.file_cache_enabled
    Settings.update_setting(@file_cache_key, to_string(new_value))

    {:noreply,
     socket
     |> assign(:file_cache_enabled, new_value)
     |> put_flash(:info, cache_toggle_message("File cache", new_value))}
  end

  def handle_event("toggle_memory_cache", _params, socket) do
    new_value = !socket.assigns.memory_cache_enabled
    Settings.update_setting(@memory_cache_key, to_string(new_value))

    # If disabling memory cache, clear all :persistent_term entries
    if !new_value do
      Enum.each(socket.assigns.blogs, fn blog ->
        try do
          :persistent_term.erase(ListingCache.persistent_term_key(blog["slug"]))
        rescue
          ArgumentError -> :ok
        end
      end)
    end

    {:noreply,
     socket
     |> assign(:memory_cache_enabled, new_value)
     |> assign(:cache_status, build_cache_status(socket.assigns.blogs))
     |> put_flash(:info, cache_toggle_message("Memory cache", new_value))}
  end

  def handle_event("clear_render_cache", _params, socket) do
    Renderer.clear_all_cache()

    {:noreply,
     socket
     |> assign(:render_cache_stats, get_render_cache_stats())
     |> put_flash(:info, gettext("Render cache cleared"))}
  end

  def handle_event("clear_blog_render_cache", %{"slug" => slug}, socket) do
    case Renderer.clear_group_cache(slug) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:render_cache_stats, get_render_cache_stats())
         |> put_flash(
           :info,
           gettext("Cleared %{count} cached posts for %{blog}", count: count, blog: slug)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to clear cache"))}
    end
  end

  def handle_event("toggle_render_cache", _params, socket) do
    new_value = !socket.assigns.render_cache_enabled
    Settings.update_setting(@render_cache_key, to_string(new_value))

    {:noreply,
     socket
     |> assign(:render_cache_enabled, new_value)
     |> put_flash(:info, cache_toggle_message("Render cache", new_value))}
  end

  def handle_event("toggle_blog_render_cache", %{"slug" => slug}, socket) do
    # Use Renderer helper to get the new key for writes
    per_blog_key = Renderer.per_group_cache_key(slug)
    current_value = Renderer.group_render_cache_enabled?(slug)
    new_value = !current_value
    Settings.update_setting(per_blog_key, to_string(new_value))

    {:noreply,
     socket
     |> assign(:render_cache_per_blog, build_render_cache_per_blog(socket.assigns.blogs))
     |> put_flash(:info, cache_toggle_message("Render cache for #{slug}", new_value))}
  end

  # ============================================================================
  # PubSub Handlers - Live updates when groups change elsewhere
  # ============================================================================

  def handle_info({:group_created, _group}, socket) do
    {:noreply, refresh_blogs(socket)}
  end

  def handle_info({:group_deleted, _slug}, socket) do
    {:noreply, refresh_blogs(socket)}
  end

  def handle_info({:group_updated, _group}, socket) do
    {:noreply, refresh_blogs(socket)}
  end

  defp refresh_blogs(socket) do
    blogs =
      Publishing.list_groups()
      |> add_legacy_status()
      |> add_primary_language_status()

    socket
    |> assign(:blogs, blogs)
    |> assign(:cache_status, build_cache_status(blogs))
    |> assign(:render_cache_per_blog, build_render_cache_per_blog(blogs))
  end

  # Helper for dual-key cache setting reads
  defp get_cache_setting(new_key, legacy_key) do
    case Settings.get_setting(new_key, nil) do
      nil -> Settings.get_setting(legacy_key, "true") == "true"
      value -> value == "true"
    end
  end

  defp cache_toggle_message(cache_type, enabled) do
    if enabled do
      gettext("%{type} enabled", type: cache_type)
    else
      gettext("%{type} disabled", type: cache_type)
    end
  end

  # Build cache status for all blogs
  defp build_cache_status(blogs) do
    Map.new(blogs, fn blog ->
      slug = blog["slug"]
      {slug, get_cache_info(slug)}
    end)
  end

  defp get_cache_info(blog_slug) do
    cache_path = ListingCache.cache_path(blog_slug)

    case File.stat(cache_path) do
      {:ok, stat} ->
        # Read cache to get post count
        post_count =
          case File.read(cache_path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, %{"post_count" => count}} -> count
                _ -> nil
              end

            _ ->
              nil
          end

        # Check if in :persistent_term
        in_memory =
          case :persistent_term.get(ListingCache.persistent_term_key(blog_slug), :not_found) do
            :not_found -> false
            _ -> true
          end

        %{
          exists: true,
          file_size: stat.size,
          modified_at: stat.mtime,
          post_count: post_count,
          in_memory: in_memory
        }

      {:error, :enoent} ->
        %{exists: false, file_size: 0, modified_at: nil, post_count: nil, in_memory: false}
    end
  end

  defp get_render_cache_stats do
    PhoenixKit.Cache.stats(:publishing_posts)
  rescue
    _ -> %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}
  end

  defp build_render_cache_per_blog(blogs) do
    Map.new(blogs, fn blog ->
      slug = blog["slug"]
      {slug, Renderer.group_render_cache_enabled?(slug)}
    end)
  end

  # Add legacy storage status to each blog
  defp add_legacy_status(blogs) do
    Enum.map(blogs, fn blog ->
      slug = blog["slug"]
      Map.put(blog, "is_legacy", Publishing.legacy_group?(slug))
    end)
  end

  # Add primary language migration status to each blog
  defp add_primary_language_status(blogs) do
    Enum.map(blogs, fn blog ->
      slug = blog["slug"]
      status = Publishing.get_primary_language_migration_status(slug)
      needs_migration = status.needs_backfill > 0 or status.needs_migration > 0

      blog
      |> Map.put("primary_language_status", status)
      |> Map.put("needs_primary_lang_migration", needs_migration)
    end)
  end
end
