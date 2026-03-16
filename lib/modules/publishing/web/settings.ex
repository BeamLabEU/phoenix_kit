defmodule PhoenixKit.Modules.Publishing.Web.Settings do
  @moduledoc """
  Admin configuration for publishing groups.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Settings keys
  @memory_cache_key "publishing_memory_cache_enabled"
  @render_cache_key "publishing_render_cache_enabled"

  def mount(_params, _session, socket) do
    # Subscribe to group changes for live updates
    if connected?(socket) do
      PublishingPubSub.subscribe_to_groups()
    end

    cache_groups = db_groups_to_maps()

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Publishing Settings"))
      |> assign(
        :current_path,
        Routes.path("/admin/settings/publishing")
      )
      |> assign(:module_enabled, Publishing.enabled?())
      |> assign(:cache_groups, cache_groups)
      |> assign(
        :memory_cache_enabled,
        Settings.get_setting(@memory_cache_key, "true") == "true"
      )
      |> assign(
        :render_cache_enabled,
        Settings.get_setting(@render_cache_key, "true") == "true"
      )
      |> assign(:cache_status, build_cache_status(cache_groups))
      |> assign(:render_cache_stats, get_render_cache_stats())
      |> assign(:render_cache_per_group, build_render_cache_per_group(cache_groups))

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("regenerate_cache", %{"slug" => slug}, socket) do
    case ListingCache.regenerate(slug) do
      :ok ->
        {:noreply,
         socket
         |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
         |> put_flash(:info, gettext("Cache regenerated for %{group}", group: slug))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to regenerate cache"))}
    end
  end

  def handle_event("invalidate_cache", %{"slug" => slug}, socket) do
    ListingCache.invalidate(slug)

    {:noreply,
     socket
     |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
     |> put_flash(:info, gettext("Cache cleared for %{group}", group: slug))}
  end

  def handle_event("regenerate_all_caches", _params, socket) do
    results =
      Enum.map(socket.assigns.cache_groups, fn group ->
        {group["slug"], ListingCache.regenerate(group["slug"])}
      end)

    success_count = Enum.count(results, fn {_, result} -> result == :ok end)

    {:noreply,
     socket
     |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
     |> put_flash(:info, gettext("Regenerated %{count} caches", count: success_count))}
  end

  def handle_event("toggle_memory_cache", _params, socket) do
    new_value = !socket.assigns.memory_cache_enabled
    Settings.update_setting(@memory_cache_key, to_string(new_value))

    # If disabling memory cache, clear all :persistent_term entries
    if !new_value do
      Enum.each(socket.assigns.cache_groups, fn group ->
        try do
          :persistent_term.erase(ListingCache.persistent_term_key(group["slug"]))
        rescue
          ArgumentError -> :ok
        end
      end)
    end

    {:noreply,
     socket
     |> assign(:memory_cache_enabled, new_value)
     |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
     |> put_flash(:info, cache_toggle_message("Memory cache", new_value))}
  end

  def handle_event("clear_render_cache", _params, socket) do
    Renderer.clear_all_cache()

    {:noreply,
     socket
     |> assign(:render_cache_stats, get_render_cache_stats())
     |> put_flash(:info, gettext("Render cache cleared"))}
  end

  def handle_event("clear_group_render_cache", %{"slug" => slug}, socket) do
    case Renderer.clear_group_cache(slug) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:render_cache_stats, get_render_cache_stats())
         |> put_flash(
           :info,
           gettext("Cleared %{count} cached posts for %{group}", count: count, group: slug)
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

  def handle_event("toggle_group_render_cache", %{"slug" => slug}, socket) do
    # Use Renderer helper to get the new key for writes
    per_group_key = Renderer.per_group_cache_key(slug)
    current_value = Renderer.group_render_cache_enabled?(slug)
    new_value = !current_value
    Settings.update_setting(per_group_key, to_string(new_value))

    {:noreply,
     socket
     |> assign(:render_cache_per_group, build_render_cache_per_group(socket.assigns.cache_groups))
     |> put_flash(:info, cache_toggle_message("Render cache for #{slug}", new_value))}
  end

  # ============================================================================
  # PubSub Handlers - Live updates when groups change elsewhere
  # ============================================================================

  def handle_info({:group_created, _group}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info({:group_deleted, _slug}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info({:group_updated, _group}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  defp refresh_groups(socket) do
    groups = db_groups_to_maps()

    socket
    |> assign(:cache_groups, groups)
    |> assign(:cache_status, build_cache_status(groups))
    |> assign(:render_cache_per_group, build_render_cache_per_group(groups))
  end

  defp db_groups_to_maps do
    Publishing.list_groups()
  end

  defp cache_toggle_message(cache_type, enabled) do
    if enabled do
      gettext("%{type} enabled", type: cache_type)
    else
      gettext("%{type} disabled", type: cache_type)
    end
  end

  # Build cache status for all groups
  defp build_cache_status(groups) do
    Map.new(groups, fn group ->
      slug = group["slug"]
      {slug, get_cache_info(slug)}
    end)
  end

  defp get_cache_info(group_slug) do
    get_cache_info_db(group_slug)
  end

  defp get_cache_info_db(group_slug) do
    in_memory =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> false
        _ -> true
      end

    post_count =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> length(Publishing.list_posts(group_slug))
        posts -> length(posts)
      end

    %{
      exists: in_memory,
      content_size: 0,
      modified_at: nil,
      post_count: post_count,
      in_memory: in_memory
    }
  end

  defp get_render_cache_stats do
    PhoenixKit.Cache.stats(:publishing_posts)
  rescue
    _ -> %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}
  end

  defp build_render_cache_per_group(groups) do
    Map.new(groups, fn group ->
      slug = group["slug"]
      {slug, Renderer.group_render_cache_enabled?(slug)}
    end)
  end
end
