defmodule PhoenixKit.Modules.Publishing.Web.Settings do
  @moduledoc """
  Admin configuration for publishing groups.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBImporter
  alias PhoenixKit.Modules.Publishing.DBStorage
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

    # Admin side reads from database only — groups appear after import
    groups = db_groups_to_maps()
    fs_groups = fs_groups_to_maps()
    # Cache management uses DB groups if imported, else FS groups (caches serve public pages)
    cache_groups = if groups != [], do: groups, else: fs_groups
    languages_enabled = Languages.enabled?()

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Manage Publishing"))
      |> assign(
        :current_path,
        Routes.path("/admin/settings/publishing")
      )
      |> assign(:module_enabled, Publishing.enabled?())
      |> assign(:publishing, groups)
      |> assign(:cache_groups, cache_groups)
      |> assign(:fs_group_count, length(fs_groups))
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
      |> assign(:cache_status, build_cache_status(cache_groups))
      |> assign(:render_cache_stats, get_render_cache_stats())
      |> assign(:render_cache_per_group, build_render_cache_per_group(cache_groups))

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
           gettext("Group moved to trash as: %{name}", name: trashed_name)
         )}

      {:error, :not_found} ->
        # Group directory doesn't exist, just remove from config
        case Publishing.remove_group(slug) do
          {:ok, _} ->
            # The `Publishing.remove_group` call handles the broadcast. This
            # LiveView will catch the event and update its state.
            {:noreply, put_flash(socket, :info, gettext("Group removed from configuration"))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to remove group"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move group to trash"))}
    end
  end

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

  def handle_event("migrate_primary_language", %{"slug" => slug}, socket) do
    primary_lang = socket.assigns.global_primary_language
    {:ok, count} = DBStorage.migrate_primary_language(slug, primary_lang)

    {:noreply,
     socket
     |> refresh_groups()
     |> put_flash(
       :info,
       gettext("Updated %{count} posts to use primary language: %{lang}",
         count: count,
         lang: primary_lang
       )
     )}
  end

  def handle_event("import_all_to_db", _params, socket) do
    case DBImporter.import_all_groups() do
      {:ok, stats} ->
        {:noreply,
         socket
         |> refresh_groups()
         |> put_flash(
           :info,
           gettext(
             "Migrated %{groups} groups, %{posts} posts, %{versions} versions, %{contents} contents to database",
             groups: stats.groups,
             posts: stats.posts,
             versions: stats.versions,
             contents: stats.contents
           )
         )}
    end
  end

  def handle_event("import_to_db", %{"slug" => slug}, socket) do
    case DBImporter.import_group(slug) do
      {:ok, stats} ->
        {:noreply,
         socket
         |> refresh_groups()
         |> put_flash(
           :info,
           gettext(
             "Migrated %{posts} posts, %{versions} versions, %{contents} contents to database",
             posts: stats.posts,
             versions: stats.versions,
             contents: stats.contents
           )
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Migration failed: %{reason}", reason: inspect(reason))
         )}
    end
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

  # DB import events — refresh groups when import completes (from any client)
  def handle_info({:db_import_started, _group_slug, _source}, socket) do
    {:noreply, socket}
  end

  def handle_info({:db_import_completed, _group_slug, _stats, _source}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info({:db_migration_started, _total_groups}, socket) do
    {:noreply, socket}
  end

  def handle_info({:db_migration_completed, _stats}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info({:migration_validation_completed, results}, socket) do
    total_discrepancies = Enum.sum(Enum.map(results, & &1.discrepancies))

    socket =
      if total_discrepancies > 0 do
        put_flash(
          socket,
          :warning,
          gettext("Validation found %{count} discrepancies between filesystem and database",
            count: total_discrepancies
          )
        )
      else
        put_flash(
          socket,
          :info,
          gettext("Validation passed — filesystem and database are in sync")
        )
      end

    {:noreply, refresh_groups(socket)}
  end

  defp refresh_groups(socket) do
    groups = db_groups_to_maps()
    fs_groups = fs_groups_to_maps()
    cache_groups = if groups != [], do: groups, else: fs_groups

    socket
    |> assign(:publishing, groups)
    |> assign(:cache_groups, cache_groups)
    |> assign(:fs_group_count, length(fs_groups))
    |> assign(:cache_status, build_cache_status(cache_groups))
    |> assign(:render_cache_per_group, build_render_cache_per_group(cache_groups))
  end

  defp db_groups_to_maps do
    global_primary = Storage.get_primary_language()

    DBStorage.list_groups()
    |> Enum.map(fn g ->
      fs_posts = length(Publishing.list_posts(g.slug))
      db_posts = length(DBStorage.list_posts(g.slug))

      # Check DB records for primary language issues (not filesystem)
      primary_lang_status = DBStorage.count_primary_language_status(g.slug, global_primary)

      needs_lang_migration =
        primary_lang_status.needs_backfill + primary_lang_status.needs_migration > 0

      %{
        "name" => g.name,
        "slug" => g.slug,
        "mode" => g.mode,
        "position" => g.position,
        "needs_import" => fs_posts > 0 and db_posts == 0,
        "needs_primary_lang_migration" => needs_lang_migration,
        "primary_language_status" => primary_lang_status
      }
    end)
  end

  defp fs_groups_to_maps do
    Publishing.list_groups()
    |> Enum.map(fn g ->
      %{
        "name" => g["name"],
        "slug" => g["slug"],
        "mode" => g["mode"],
        "position" => g["position"]
      }
    end)
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

  # Build cache status for all groups
  defp build_cache_status(groups) do
    Map.new(groups, fn group ->
      slug = group["slug"]
      {slug, get_cache_info(slug)}
    end)
  end

  defp get_cache_info(group_slug) do
    if Publishing.db_storage?() do
      get_cache_info_db(group_slug)
    else
      get_cache_info_fs(group_slug)
    end
  end

  defp get_cache_info_db(group_slug) do
    in_memory =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> false
        _ -> true
      end

    post_count =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> length(DBStorage.list_posts(group_slug))
        posts -> length(posts)
      end

    %{
      exists: in_memory,
      file_size: 0,
      modified_at: nil,
      post_count: post_count,
      in_memory: in_memory
    }
  end

  defp get_cache_info_fs(group_slug) do
    cache_path = ListingCache.cache_path(group_slug)

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
          case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
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

  defp build_render_cache_per_group(groups) do
    Map.new(groups, fn group ->
      slug = group["slug"]
      {slug, Renderer.group_render_cache_enabled?(slug)}
    end)
  end
end
