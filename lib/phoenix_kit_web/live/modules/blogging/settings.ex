defmodule PhoenixKitWeb.Live.Modules.Blogging.Settings do
  @moduledoc """
  Admin configuration for site blogs.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.ListingCache
  alias PhoenixKitWeb.Live.Modules.Blogging.PubSub, as: BloggingPubSub

  @file_cache_key "blogging_file_cache_enabled"
  @memory_cache_key "blogging_memory_cache_enabled"

  def mount(_params, _session, socket) do
    blogs = Blogging.list_blogs()
    languages_enabled = Languages.enabled?()

    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("Manage Blogging"))
      |> assign(
        :current_path,
        Routes.path("/admin/settings/blogging", locale: socket.assigns.current_locale_base)
      )
      |> assign(:module_enabled, Blogging.enabled?())
      |> assign(:blogs, blogs)
      |> assign(:languages_enabled, languages_enabled)
      |> assign(:file_cache_enabled, Settings.get_setting(@file_cache_key, "true") == "true")
      |> assign(:memory_cache_enabled, Settings.get_setting(@memory_cache_key, "true") == "true")
      |> assign(:cache_status, build_cache_status(blogs))

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("remove_blog", %{"slug" => slug}, socket) do
    case Blogging.trash_blog(slug) do
      {:ok, trashed_name} ->
        # Broadcast blog deleted for live dashboard updates
        BloggingPubSub.broadcast_blog_deleted(slug)

        {:noreply,
         socket
         |> assign(:blogs, Blogging.list_blogs())
         |> put_flash(
           :info,
           gettext("Blog moved to trash as: %{name}", name: trashed_name)
         )}

      {:error, :not_found} ->
        # Blog directory doesn't exist, just remove from config
        case Blogging.remove_blog(slug) do
          {:ok, _} ->
            # Broadcast blog deleted for live dashboard updates
            BloggingPubSub.broadcast_blog_deleted(slug)

            {:noreply,
             socket
             |> assign(:blogs, Blogging.list_blogs())
             |> put_flash(:info, gettext("Blog removed from configuration"))}

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
end
