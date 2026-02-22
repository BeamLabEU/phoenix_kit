defmodule PhoenixKit.Modules.Publishing.Web.Listing do
  @moduledoc """
  Lists posts for a publishing group and provides creation actions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBImporter
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Modules.Publishing.Workers.MigrateLegacyStructureWorker
  alias PhoenixKit.Modules.Publishing.Workers.MigratePrimaryLanguageWorker
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  # Threshold for using background job vs synchronous migration
  @migration_async_threshold 20

  # Import publishing-specific components
  import PhoenixKit.Modules.Publishing.Web.Components.LanguageSwitcher

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    if connected?(socket), do: subscribe_to_pubsub(group_slug)

    date_time_settings = load_date_time_settings()
    {groups, current_group, fs_post_count} = load_groups_and_current(group_slug)

    initial_posts =
      case group_slug do
        nil -> []
        slug -> DBStorage.list_posts_with_metadata(slug)
      end

    current_path =
      case group_slug do
        nil -> Routes.path("/admin/publishing")
        slug -> Routes.path("/admin/publishing/#{slug}")
      end

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, "Publishing")
      |> assign(:current_path, current_path)
      |> assign(:groups, groups)
      |> assign(:current_group, current_group)
      |> assign(:group_slug, group_slug)
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:primary_language, Storage.get_primary_language())
      |> assign(:primary_language_name, get_language_name(Storage.get_primary_language()))
      |> assign(:posts, initial_posts)
      |> assign(:fs_post_count, fs_post_count)
      |> assign(:loading, false)
      |> assign(:endpoint_url, "")
      |> assign(:date_time_settings, date_time_settings)
      |> assign(:group_files_root, get_group_files_root(group_slug))
      |> assign(:cache_info, get_cache_info(group_slug))
      |> assign(:primary_language_status, get_primary_language_status(group_slug))
      |> assign(:active_editors, %{})
      |> assign(:translating_posts, %{})
      |> assign(:pending_post_updates, %{})
      |> assign(:show_migration_modal, false)
      |> assign(:migration_in_progress, false)
      |> assign(:migration_progress, nil)
      |> assign(:legacy_structure_status, get_legacy_structure_status(group_slug))
      |> assign(:show_version_migration_modal, false)
      |> assign(:version_migration_in_progress, false)
      |> assign(:version_migration_progress, nil)
      |> assign(:db_storage, Publishing.db_storage?())
      |> assign(:db_import_in_progress, false)

    {:ok, redirect_if_missing(socket)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    new_group_slug = params["group"] || params["category"] || params["type"]
    old_group_slug = socket.assigns[:group_slug]

    socket = handle_subscription_change(socket, old_group_slug, new_group_slug)

    {_groups, current_group, fs_post_count} = load_groups_and_current(new_group_slug)

    posts =
      case new_group_slug do
        nil -> []
        slug -> DBStorage.list_posts_with_metadata(slug)
      end

    socket =
      socket
      |> assign(:current_group, current_group)
      |> assign(:posts, posts)
      |> assign(:fs_post_count, fs_post_count)
      |> assign(:endpoint_url, extract_endpoint_url(uri))
      |> assign(:group_files_root, get_group_files_root(new_group_slug))
      |> assign(:cache_info, get_cache_info(new_group_slug))
      |> assign(:primary_language_status, get_primary_language_status(new_group_slug))
      |> assign(:legacy_structure_status, get_legacy_structure_status(new_group_slug))
      |> assign(:db_storage, Publishing.db_storage?())

    {:noreply, redirect_if_missing(socket)}
  end

  @impl true
  def handle_event("import_to_db", _params, socket) do
    group_slug = socket.assigns.group_slug

    # DBImporter broadcasts :db_import_started / :db_import_completed via PubSub.
    # The handle_info handlers refresh posts and groups for all connected clients.
    case DBImporter.import_group(group_slug) do
      {:ok, _stats} ->
        # Refresh immediately for the triggering user (PubSub handle_info runs after return)
        {:noreply,
         socket
         |> assign(:db_import_in_progress, false)
         |> refresh_posts()
         |> refresh_groups()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:db_import_in_progress, false)
         |> put_flash(
           :error,
           gettext("Import failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("create_post", _params, %{assigns: %{group_slug: group_slug}} = socket) do
    # Use redirect for full page refresh to ensure editor JS initializes properly
    {:noreply,
     redirect(socket,
       to: Helpers.build_new_post_url(group_slug)
     )}
  end

  def handle_event("refresh", _params, socket) do
    group_slug = socket.assigns.group_slug

    {:noreply,
     socket
     |> assign(:posts, DBStorage.list_posts_with_metadata(group_slug))
     |> assign(:cache_info, get_cache_info(group_slug))}
  end

  def handle_event("add_language", params, socket) do
    lang_code = params["language"]
    group_slug = socket.assigns.group_slug

    url =
      if uuid = params["uuid"] do
        Helpers.build_edit_url(group_slug, %{uuid: uuid}, lang: lang_code)
      else
        post_path = params["path"] || ""

        Routes.path(
          "/admin/publishing/#{group_slug}/edit?path=#{URI.encode(post_path)}&lang=#{lang_code}"
        )
      end

    # Use redirect for full page refresh to ensure editor JS initializes properly
    {:noreply, redirect(socket, to: url)}
  end

  def handle_event("language_action", %{"language" => _lang_code} = params, socket)
      when is_map_key(params, "uuid") do
    uuid = params["uuid"]
    group_slug = socket.assigns.group_slug

    url =
      if params["path"] && params["path"] != "" do
        # Language file exists — open it directly
        Helpers.build_edit_url(group_slug, %{uuid: uuid}, lang: params["language"])
      else
        # Language doesn't exist yet — open editor to create it
        Helpers.build_edit_url(group_slug, %{uuid: uuid}, lang: params["language"])
      end

    {:noreply, redirect(socket, to: url)}
  end

  def handle_event("language_action", %{"language" => _lang_code, "path" => path}, socket)
      when is_binary(path) and path != "" do
    # Legacy path-based fallback
    {:noreply,
     redirect(socket,
       to:
         Routes.path(
           "/admin/publishing/#{socket.assigns.group_slug}/edit?path=#{URI.encode(path)}"
         )
     )}
  end

  def handle_event("language_action", %{"language" => lang_code} = params, socket) do
    # For languages without a path (not yet created), add the language
    post_path = params["post_path"] || ""

    if post_path != "" do
      {:noreply,
       redirect(socket,
         to:
           Routes.path(
             "/admin/publishing/#{socket.assigns.group_slug}/edit?path=#{URI.encode(post_path)}&lang=#{lang_code}"
           )
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change_status", %{"path" => post_path, "status" => new_status}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Publishing.read_post(socket.assigns.group_slug, post_path) do
      {:ok, post} ->
        # Determine if this is the primary language for status propagation
        primary_language = post[:primary_language] || Storage.get_primary_language()
        is_primary_language = post.language == primary_language

        case Publishing.update_post(socket.assigns.group_slug, post, %{"status" => new_status}, %{
               scope: scope,
               is_primary_language: is_primary_language
             }) do
          {:ok, updated_post} ->
            # Invalidate cache for this post
            invalidate_post_cache(socket.assigns.group_slug, updated_post)

            # Broadcast status change to other connected clients
            PublishingPubSub.broadcast_post_status_changed(
              socket.assigns.group_slug,
              updated_post
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :posts,
               Publishing.list_posts(
                 socket.assigns.group_slug,
                 socket.assigns.current_locale_base
               )
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

    case Publishing.read_post(socket.assigns.group_slug, post_path) do
      {:ok, post} ->
        # Determine if this is the primary language for status propagation
        primary_language = post[:primary_language] || Storage.get_primary_language()
        is_primary_language = post.language == primary_language

        case Publishing.update_post(socket.assigns.group_slug, post, %{"status" => new_status}, %{
               scope: scope,
               is_primary_language: is_primary_language
             }) do
          {:ok, updated_post} ->
            # Broadcast status change to other connected clients
            PublishingPubSub.broadcast_post_status_changed(
              socket.assigns.group_slug,
              updated_post
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :posts,
               Publishing.list_posts(
                 socket.assigns.group_slug,
                 socket.assigns.current_locale_base
               )
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update status"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Post not found"))}
    end
  end

  def handle_event("regenerate_file_cache", _params, socket) do
    group_slug = socket.assigns.group_slug

    case ListingCache.regenerate_file_only(group_slug) do
      :ok ->
        # Notify other dashboards about cache change
        PublishingPubSub.broadcast_cache_changed(group_slug)

        {:noreply,
         socket
         |> assign(:cache_info, get_cache_info(group_slug))
         |> put_flash(:info, gettext("File cache regenerated"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to regenerate cache"))}
    end
  end

  def handle_event("invalidate_file_cache", _params, socket) do
    group_slug = socket.assigns.group_slug
    cache_path = ListingCache.cache_path(group_slug)

    case File.rm(cache_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> :ok
    end

    # Notify other dashboards about cache change
    PublishingPubSub.broadcast_cache_changed(group_slug)

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(group_slug))
     |> put_flash(:info, gettext("File cache cleared"))}
  end

  def handle_event("load_memory_cache", _params, socket) do
    group_slug = socket.assigns.group_slug

    # If file cache is disabled, scan posts directly into memory
    # Otherwise, load from existing file
    if ListingCache.file_cache_enabled?() do
      case ListingCache.load_into_memory(group_slug) do
        :ok ->
          # Notify other dashboards about cache change
          PublishingPubSub.broadcast_cache_changed(group_slug)

          {:noreply,
           socket
           |> assign(:cache_info, get_cache_info(group_slug))
           |> put_flash(:info, gettext("Cache loaded into memory"))}

        {:error, :no_file} ->
          {:noreply, put_flash(socket, :error, gettext("No file cache to load from"))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to load cache"))}
      end
    else
      # File cache disabled - scan posts directly into memory
      case ListingCache.regenerate(group_slug) do
        :ok ->
          # Notify other dashboards about cache change
          PublishingPubSub.broadcast_cache_changed(group_slug)

          {:noreply,
           socket
           |> assign(:cache_info, get_cache_info(group_slug))
           |> put_flash(:info, gettext("Cache loaded into memory from filesystem scan"))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to scan posts"))}
      end
    end
  end

  def handle_event("invalidate_memory_cache", _params, socket) do
    group_slug = socket.assigns.group_slug

    # Clear the cache, loaded_at, and file_generated_at timestamps
    try do
      :persistent_term.erase(ListingCache.persistent_term_key(group_slug))
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(ListingCache.loaded_at_key(group_slug))
    rescue
      ArgumentError -> :ok
    end

    try do
      :persistent_term.erase(ListingCache.file_generated_at_key(group_slug))
    rescue
      ArgumentError -> :ok
    end

    # Notify other dashboards about cache change
    PublishingPubSub.broadcast_cache_changed(group_slug)

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(group_slug))
     |> put_flash(:info, gettext("Memory cache cleared"))}
  end

  def handle_event("toggle_file_cache", _params, socket) do
    group_slug = socket.assigns.group_slug
    current = ListingCache.file_cache_enabled?()
    new_value = !current
    Settings.update_setting("publishing_file_cache_enabled", to_string(new_value))

    message =
      if new_value, do: gettext("File cache enabled"), else: gettext("File cache disabled")

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(group_slug))
     |> put_flash(:info, message)}
  end

  def handle_event("toggle_memory_cache", _params, socket) do
    group_slug = socket.assigns.group_slug
    current = ListingCache.memory_cache_enabled?()
    new_value = !current
    Settings.update_setting("publishing_memory_cache_enabled", to_string(new_value))

    # If disabling, clear memory cache
    unless new_value do
      try do
        :persistent_term.erase(ListingCache.persistent_term_key(group_slug))
      rescue
        ArgumentError -> :ok
      end

      try do
        :persistent_term.erase(ListingCache.loaded_at_key(group_slug))
      rescue
        ArgumentError -> :ok
      end

      try do
        :persistent_term.erase(ListingCache.file_generated_at_key(group_slug))
      rescue
        ArgumentError -> :ok
      end
    end

    message =
      if new_value, do: gettext("Memory cache enabled"), else: gettext("Memory cache disabled")

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(group_slug))
     |> put_flash(:info, message)}
  end

  def handle_event("toggle_render_cache", _params, socket) do
    group_slug = socket.assigns.group_slug
    current = Renderer.group_render_cache_enabled?(group_slug)
    new_value = !current
    Settings.update_setting(Renderer.per_group_cache_key(group_slug), to_string(new_value))

    message =
      if new_value, do: gettext("Render cache enabled"), else: gettext("Render cache disabled")

    {:noreply,
     socket
     |> assign(:cache_info, get_cache_info(group_slug))
     |> put_flash(:info, message)}
  end

  def handle_event("clear_render_cache", _params, socket) do
    group_slug = socket.assigns.group_slug

    case Renderer.clear_group_cache(group_slug) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:cache_info, get_cache_info(group_slug))
         |> put_flash(:info, gettext("Cleared %{count} cached posts", count: count))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to clear cache"))}
    end
  end

  def handle_event("show_migration_modal", _params, socket) do
    {:noreply, assign(socket, :show_migration_modal, true)}
  end

  def handle_event("close_migration_modal", _params, socket) do
    {:noreply, assign(socket, :show_migration_modal, false)}
  end

  def handle_event("confirm_migrate_primary_language", _params, socket) do
    group_slug = socket.assigns.group_slug
    primary_language = Storage.get_primary_language()
    status = socket.assigns.primary_language_status
    total_count = status.needs_backfill + status.needs_migration

    # Use background job for large migrations
    if total_count > @migration_async_threshold do
      case MigratePrimaryLanguageWorker.enqueue(group_slug, primary_language) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:show_migration_modal, false)
           |> assign(:migration_in_progress, true)
           |> assign(:migration_progress, %{current: 0, total: total_count})
           |> put_flash(
             :info,
             gettext("Migration started for %{count} posts. You can continue working.",
               count: total_count
             )
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:show_migration_modal, false)
           |> put_flash(
             :error,
             gettext("Failed to start migration: %{reason}", reason: inspect(reason))
           )}
      end
    else
      # Synchronous migration for small counts
      case Publishing.migrate_posts_to_current_primary_language(group_slug) do
        {:ok, count} ->
          {:noreply,
           socket
           |> assign(:show_migration_modal, false)
           |> assign(:primary_language_status, get_primary_language_status(group_slug))
           |> put_flash(
             :info,
             gettext("Updated %{count} posts to primary language: %{lang}",
               count: count,
               lang: get_language_name(primary_language)
             )
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:show_migration_modal, false)
           |> put_flash(
             :error,
             gettext("Failed to migrate: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  # Version structure migration events
  def handle_event("show_version_migration_modal", _params, socket) do
    {:noreply, assign(socket, :show_version_migration_modal, true)}
  end

  def handle_event("close_version_migration_modal", _params, socket) do
    {:noreply, assign(socket, :show_version_migration_modal, false)}
  end

  def handle_event("confirm_migrate_to_versioned", _params, socket) do
    group_slug = socket.assigns.group_slug
    status = socket.assigns.legacy_structure_status
    total_count = status.legacy

    # Use background job for large migrations
    if total_count > @migration_async_threshold do
      case MigrateLegacyStructureWorker.enqueue(group_slug) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:show_version_migration_modal, false)
           |> assign(:version_migration_in_progress, true)
           |> assign(:version_migration_progress, %{current: 0, total: total_count})
           |> put_flash(
             :info,
             gettext("Version migration started for %{count} posts. You can continue working.",
               count: total_count
             )
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:show_version_migration_modal, false)
           |> put_flash(
             :error,
             gettext("Failed to start migration: %{reason}", reason: inspect(reason))
           )}
      end
    else
      # Synchronous migration for small counts
      {:ok, count} = Publishing.migrate_posts_to_versioned_structure(group_slug)

      {:noreply,
       socket
       |> assign(:show_version_migration_modal, false)
       |> assign(:legacy_structure_status, get_legacy_structure_status(group_slug))
       |> refresh_posts()
       |> put_flash(
         :info,
         gettext("Migrated %{count} posts to versioned structure", count: count)
       )}
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

  def handle_info({:cache_changed, group_slug}, socket) do
    # Refresh cache info when cache state changes (from visitor loading it, etc.)
    {:noreply, assign(socket, :cache_info, get_cache_info(group_slug))}
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

  def handle_info({:translation_progress, post_slug, completed, total}, socket) do
    # Update progress for this post
    case Map.get(socket.assigns.translating_posts, post_slug) do
      nil ->
        # Post not in our tracking, add it
        translating =
          Map.put(socket.assigns.translating_posts, post_slug, %{
            total: total,
            completed: completed,
            status: :in_progress
          })

        {:noreply, assign(socket, :translating_posts, translating)}

      existing ->
        # Update existing entry
        translating =
          Map.put(socket.assigns.translating_posts, post_slug, %{
            existing
            | completed: completed,
              total: total
          })

        {:noreply, assign(socket, :translating_posts, translating)}
    end
  end

  def handle_info({:translation_completed, post_slug, results}, socket) do
    # Mark translation as complete - status stays visible
    translating =
      Map.put(socket.assigns.translating_posts, post_slug, %{
        status: :completed,
        success_count: results.success_count,
        failure_count: results.failure_count
      })

    socket = assign(socket, :translating_posts, translating)

    # Refresh posts to show new translations
    socket = refresh_posts(socket)

    {:noreply, socket}
  end

  # Primary language migration progress handlers
  def handle_info({:primary_language_migration_started, group_slug, total_count}, socket) do
    # Only track if it's for our current group
    if group_slug == socket.assigns.group_slug do
      {:noreply,
       socket
       |> assign(:migration_in_progress, true)
       |> assign(:migration_progress, %{current: 0, total: total_count})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:primary_language_migration_progress, group_slug, current, total}, socket) do
    if group_slug == socket.assigns.group_slug do
      {:noreply, assign(socket, :migration_progress, %{current: current, total: total})}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:primary_language_migration_completed, group_slug, success_count, error_count,
         primary_language},
        socket
      ) do
    # Only handle if it's for our current group
    if group_slug == socket.assigns.group_slug do
      group_slug = socket.assigns.group_slug

      socket =
        socket
        |> assign(:migration_in_progress, false)
        |> assign(:migration_progress, nil)
        |> assign(:primary_language_status, get_primary_language_status(group_slug))

      socket =
        if error_count > 0 do
          put_flash(
            socket,
            :warning,
            gettext("Migration completed: %{success} succeeded, %{errors} failed",
              success: success_count,
              errors: error_count
            )
          )
        else
          put_flash(
            socket,
            :info,
            gettext("Updated %{count} posts to primary language: %{lang}",
              count: success_count,
              lang: get_language_name(primary_language)
            )
          )
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Legacy structure (version) migration progress handlers
  def handle_info({:legacy_structure_migration_started, group_slug, total_count}, socket) do
    # Only track if it's for our current group
    if group_slug == socket.assigns.group_slug do
      {:noreply,
       socket
       |> assign(:version_migration_in_progress, true)
       |> assign(:version_migration_progress, %{current: 0, total: total_count})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:legacy_structure_migration_progress, group_slug, current, total}, socket) do
    if group_slug == socket.assigns.group_slug do
      {:noreply, assign(socket, :version_migration_progress, %{current: current, total: total})}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:legacy_structure_migration_completed, group_slug, success_count, error_count},
        socket
      ) do
    # Only handle if it's for our current group
    if group_slug == socket.assigns.group_slug do
      group_slug = socket.assigns.group_slug

      socket =
        socket
        |> assign(:version_migration_in_progress, false)
        |> assign(:version_migration_progress, nil)
        |> assign(:legacy_structure_status, get_legacy_structure_status(group_slug))
        |> refresh_posts()

      socket =
        if error_count > 0 do
          put_flash(
            socket,
            :warning,
            gettext("Version migration completed: %{success} succeeded, %{errors} failed",
              success: success_count,
              errors: error_count
            )
          )
        else
          put_flash(
            socket,
            :info,
            gettext("Migrated %{count} posts to versioned structure", count: success_count)
          )
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # DB import handlers - live updates during sync import and async migration
  def handle_info({:db_import_started, group_slug, _source}, socket) do
    if group_slug == socket.assigns.group_slug do
      {:noreply,
       socket
       |> assign(:db_import_in_progress, true)
       |> put_flash(:info, gettext("Importing posts to database..."))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:db_import_completed, group_slug, stats, _source}, socket) do
    if group_slug == socket.assigns.group_slug do
      {:noreply,
       socket
       |> assign(:db_import_in_progress, false)
       |> refresh_posts()
       |> refresh_groups()
       |> put_flash(
         :info,
         gettext(
           "Imported %{posts} posts, %{versions} versions, %{contents} contents to database",
           posts: stats.posts,
           versions: stats.versions,
           contents: stats.contents
         )
       )}
    else
      # Different group imported — still refresh groups sidebar
      {:noreply, refresh_groups(socket)}
    end
  end

  def handle_info({:db_migration_started, _total_groups}, socket) do
    {:noreply,
     socket
     |> assign(:db_import_in_progress, true)
     |> put_flash(:info, gettext("Database migration started..."))}
  end

  def handle_info({:db_migration_group_progress, group_slug, _posts_migrated, _total}, socket) do
    if group_slug == socket.assigns.group_slug do
      {:noreply, refresh_posts(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:db_migration_completed, stats}, socket) do
    {:noreply,
     socket
     |> assign(:db_import_in_progress, false)
     |> refresh_posts()
     |> refresh_groups()
     |> put_flash(
       :info,
       gettext(
         "Migration complete: %{groups} groups, %{posts} posts imported",
         groups: stats.groups,
         posts: stats.posts
       )
     )}
  end

  # Group change handlers - keep sidebar in sync
  def handle_info({:group_created, _group}, socket) do
    {:noreply, assign(socket, :groups, Publishing.list_groups())}
  end

  def handle_info({:group_updated, group}, socket) do
    groups = Publishing.list_groups()
    current_group = Enum.find(groups, fn b -> b["slug"] == socket.assigns.group_slug end)

    socket =
      socket
      |> assign(:groups, groups)
      |> assign(:current_group, current_group || group)

    {:noreply, socket}
  end

  def handle_info({:migration_validation_completed, _results}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info({:group_deleted, deleted_slug}, socket) do
    groups = Publishing.list_groups()

    socket =
      if socket.assigns.group_slug == deleted_slug do
        # Current group was deleted - redirect to first available
        case groups do
          [%{"slug" => slug} | _] ->
            push_navigate(socket, to: Routes.path("/admin/publishing/#{slug}"))

          [] ->
            push_navigate(socket, to: Routes.path("/admin/settings/publishing"))
        end
      else
        assign(socket, :groups, groups)
      end

    {:noreply, socket}
  end

  defp refresh_posts(socket) do
    case socket.assigns.group_slug do
      nil ->
        socket

      group_slug ->
        posts = Publishing.list_posts(group_slug, socket.assigns.current_locale_base)
        assign(socket, :posts, posts)
    end
  end

  defp refresh_groups(socket) do
    db_groups = DBStorage.list_groups()

    groups =
      Enum.map(db_groups, fn g ->
        %{"name" => g.name, "slug" => g.slug, "mode" => g.mode, "position" => g.position}
      end)

    current_group = Enum.find(groups, fn group -> group["slug"] == socket.assigns.group_slug end)

    socket
    |> assign(:groups, groups)
    |> assign(:current_group, current_group || socket.assigns[:current_group])
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
    can_update? = post_slug && socket.assigns[:posts] && socket.assigns[:group_slug]

    if can_update? do
      fetch_and_update_post(socket, post_slug)
    else
      refresh_posts(socket)
    end
  end

  defp fetch_and_update_post(socket, post_slug) do
    case Publishing.read_post(
           socket.assigns.group_slug,
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
      # Extract slug from path (e.g., "group/my-post/v1/en.phk" -> "my-post")
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
    case socket.assigns.group_slug do
      nil ->
        socket

      group_slug ->
        case Publishing.read_post(group_slug, post_slug, socket.assigns.current_locale_base, nil) do
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

  # ============================================================================
  # Shared Mount/HandleParams Helpers
  # ============================================================================

  defp subscribe_to_pubsub(group_slug) do
    PublishingPubSub.subscribe_to_groups()

    if group_slug do
      PublishingPubSub.subscribe_to_posts(group_slug)
      PublishingPubSub.subscribe_to_cache(group_slug)
      PublishingPubSub.subscribe_to_group_editors(group_slug)
    end
  end

  defp handle_subscription_change(socket, old_slug, new_slug) do
    if connected?(socket) && new_slug != old_slug do
      if old_slug do
        PublishingPubSub.unsubscribe_from_posts(old_slug)
        PublishingPubSub.unsubscribe_from_cache(old_slug)
        PublishingPubSub.unsubscribe_from_group_editors(old_slug)
      end

      if new_slug do
        PublishingPubSub.subscribe_to_posts(new_slug)
        PublishingPubSub.subscribe_to_cache(new_slug)
        PublishingPubSub.subscribe_to_group_editors(new_slug)
      end

      socket
      |> assign(:group_slug, new_slug)
      |> assign(:active_editors, %{})
      |> assign(:translating_posts, %{})
      |> assign(:pending_post_updates, %{})
    else
      assign(socket, :group_slug, new_slug)
    end
  end

  defp load_date_time_settings do
    Settings.get_settings_cached(
      ["date_format", "time_format", "time_zone"],
      %{"date_format" => "Y-m-d", "time_format" => "H:i", "time_zone" => "0"}
    )
  end

  defp load_groups_and_current(group_slug) do
    groups = load_db_groups()
    current_group = Enum.find(groups, fn group -> group["slug"] == group_slug end)
    {current_group, fs_post_count} = resolve_group_with_fs_fallback(current_group, group_slug)
    {groups, current_group, fs_post_count}
  end

  defp load_db_groups do
    DBStorage.list_groups()
    |> Enum.map(fn g ->
      %{"name" => g.name, "slug" => g.slug, "mode" => g.mode, "position" => g.position}
    end)
  end

  defp resolve_group_with_fs_fallback(nil, slug) when is_binary(slug) do
    case Publishing.get_group(slug) do
      {:ok, fs_group} ->
        {
          %{
            "name" => fs_group["name"],
            "slug" => fs_group["slug"],
            "mode" => fs_group["mode"] || "timestamp",
            "position" => fs_group["position"] || 0
          },
          length(Publishing.list_posts(slug))
        }

      _ ->
        {nil, 0}
    end
  end

  defp resolve_group_with_fs_fallback(group, group_slug) do
    fs_count =
      if Publishing.db_storage?() do
        0
      else
        case group_slug do
          nil -> 0
          slug -> length(Publishing.list_posts(slug))
        end
      end

    {group, fs_count}
  end

  defp redirect_if_missing(%{assigns: %{current_group: nil}} = socket) do
    case socket.assigns.groups do
      [%{"slug" => slug} | _] ->
        push_navigate(socket, to: Routes.path("/admin/publishing/#{slug}"))

      [] ->
        push_navigate(socket, to: Routes.path("/admin/settings/publishing"))
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

  @doc """
  Gets the published version number from a post's version_statuses map.
  Returns nil if no version is published.
  """
  def get_published_version(post) do
    version_statuses = Map.get(post, :version_statuses, %{})

    version_statuses
    |> Enum.find(fn {_version, status} -> status == "published" end)
    |> case do
      {version, _status} -> version
      nil -> nil
    end
  end

  @doc """
  Gets the display version info for a post based on priority:
  1. Published version (if exists) - what visitors see
  2. Newest draft version (if no published) - work in progress
  3. Latest version (fallback)

  Returns `{version_number, status, label}` where label is :live, :draft, or :latest
  """
  def get_display_version(post) do
    version_statuses = Map.get(post, :version_statuses, %{})
    available_versions = Map.get(post, :available_versions, [])

    # 1. Check for published version
    published =
      version_statuses
      |> Enum.find(fn {_version, status} -> status == "published" end)

    case published do
      {version, _status} ->
        {version, "published", :live}

      nil ->
        # 2. Check for newest draft version
        draft_versions =
          version_statuses
          |> Enum.filter(fn {_version, status} -> status == "draft" end)
          |> Enum.map(fn {version, _} -> version end)
          |> Enum.sort(:desc)

        case draft_versions do
          [newest_draft | _] ->
            {newest_draft, "draft", :draft}

          [] ->
            # 3. Fall back to latest version
            latest = Enum.max(available_versions, fn -> post[:version] || 1 end)
            status = Map.get(version_statuses, latest, "draft")
            {latest, status, :latest}
        end
    end
  end

  @doc """
  Builds language data for the display version (live > draft > latest).
  """
  def build_display_version_languages(post, enabled_languages, primary_language \\ nil) do
    {version, status, _label} = get_display_version(post)

    # Get languages for this specific version
    version_languages = Map.get(post, :version_languages, %{})
    available_languages = Map.get(version_languages, version, post[:available_languages] || [])

    # Get primary language - prefer passed param, then post's stored value, then global
    primary_lang =
      primary_language || post[:primary_language] || Storage.get_primary_language()

    # Use shared ordering function for consistent display
    all_languages =
      Storage.order_languages_for_display(
        available_languages,
        enabled_languages,
        primary_lang
      )

    Enum.map(all_languages, fn lang_code ->
      lang_path =
        Path.join([
          Path.dirname(post.path),
          "#{lang_code}.phk"
        ])

      lang_info = Publishing.get_language_info(lang_code)
      file_exists = lang_code in available_languages
      is_enabled = Storage.language_enabled?(lang_code, enabled_languages)
      is_known = lang_info != nil
      is_primary = lang_code == primary_lang

      # Status matches the version's status
      lang_status = if file_exists, do: status, else: nil

      # Get display code (base or full dialect depending on enabled languages)
      display_code = Storage.get_display_code(lang_code, enabled_languages)

      %{
        code: lang_code,
        display_code: display_code,
        name: if(lang_info, do: lang_info.name, else: lang_code),
        flag: if(lang_info, do: lang_info.flag, else: ""),
        status: lang_status,
        exists: file_exists,
        enabled: is_enabled,
        known: is_known,
        is_primary: is_primary,
        path: if(file_exists, do: lang_path, else: nil),
        post_path: post.path
      }
    end)
    |> Enum.filter(fn lang -> lang.exists end)
  end

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

  defp invalidate_post_cache(group_slug, post) do
    # Determine identifier based on post mode
    identifier =
      case post.mode do
        :slug -> post.slug
        _ -> post.path
      end

    # Invalidate the render cache for this post
    Renderer.invalidate_cache(group_slug, identifier, post.language)
  end

  @doc """
  Builds language data for the publishing_language_switcher component.
  Returns a list of language maps with status, path, enabled flag, known flag, and metadata.

  The `enabled` field indicates if the language is currently active in the Languages module.
  The `known` field indicates if the language code is recognized (vs unknown files like "test.phk").
  The `is_primary` field indicates if this is the primary language for versioning.

  For versioned posts with a live version, shows the live version's languages and paths.
  """
  def build_post_languages(
        post,
        _group_slug,
        enabled_languages,
        _current_locale,
        primary_language \\ nil
      ) do
    primary_lang =
      primary_language || post[:primary_language] || Storage.get_primary_language()

    version_info = get_version_display_info(post, primary_lang)

    all_languages =
      Storage.order_languages_for_display(
        version_info.available_languages,
        enabled_languages,
        primary_lang
      )

    all_languages
    |> Enum.map(&build_language_entry(&1, post, version_info, enabled_languages, primary_lang))
    |> Enum.filter(fn lang -> lang.exists || lang.enabled end)
  end

  defp get_version_display_info(post, primary_lang) do
    if post[:mode] == :slug and not Map.get(post, :is_legacy_structure, true) do
      get_versioned_post_display_info(post, primary_lang)
    else
      get_default_display_info(post)
    end
  end

  defp get_versioned_post_display_info(post, primary_lang) do
    case get_published_version(post) do
      nil ->
        get_default_display_info(post)

      published_version ->
        langs = get_live_version_languages(post, published_version)
        path_base = Path.join([post.group, post.slug, "v#{published_version}"])
        live_post_path = Path.join([path_base, "#{primary_lang}.phk"])

        %{
          available_languages: langs,
          version_status: "published",
          path_base: path_base,
          display_post_path: live_post_path
        }
    end
  end

  defp get_default_display_info(post) do
    %{
      available_languages: post.available_languages || [],
      version_status: nil,
      path_base: Path.dirname(post.path),
      display_post_path: post.path
    }
  end

  defp get_live_version_languages(post, published_version) do
    version_languages = Map.get(post, :version_languages, %{})
    langs = Map.get(version_languages, published_version, [])

    if langs == [] do
      alias PhoenixKit.Modules.Publishing.Storage.Versions
      version_langs = Versions.load_version_languages(post.group, post.slug, [published_version])
      Map.get(version_langs, published_version, [])
    else
      langs
    end
  end

  defp build_language_entry(lang_code, post, version_info, enabled_languages, primary_lang) do
    lang_path = Path.join([version_info.path_base, "#{lang_code}.phk"])
    lang_info = Publishing.get_language_info(lang_code)
    file_exists = lang_code in version_info.available_languages

    status = get_language_status(lang_code, file_exists, version_info, post)

    %{
      code: lang_code,
      display_code: Storage.get_display_code(lang_code, enabled_languages),
      name: if(lang_info, do: lang_info.name, else: lang_code),
      flag: if(lang_info, do: lang_info.flag, else: ""),
      status: status,
      exists: file_exists,
      enabled: Storage.language_enabled?(lang_code, enabled_languages),
      known: lang_info != nil,
      is_primary: lang_code == primary_lang,
      path: if(file_exists, do: lang_path, else: nil),
      post_path: if(file_exists, do: lang_path, else: version_info.display_post_path),
      uuid: post[:uuid]
    }
  end

  defp get_language_status(lang_code, file_exists, version_info, post) do
    if version_info.version_status && file_exists do
      version_info.version_status
    else
      language_statuses = Map.get(post, :language_statuses) || %{}
      Map.get(language_statuses, lang_code)
    end
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

  defp get_cache_info(group_slug) do
    if Publishing.db_storage?() do
      get_cache_info_db(group_slug)
    else
      get_cache_info_fs(group_slug)
    end
  end

  # DB mode: no file cache, just persistent_term + render cache
  defp get_cache_info_db(group_slug) do
    memory_enabled = ListingCache.memory_cache_enabled?()
    render_enabled = Renderer.group_render_cache_enabled?(group_slug)
    render_global_enabled = Renderer.global_render_cache_enabled?()

    in_memory =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> false
        _ -> true
      end

    memory_loaded_at = ListingCache.memory_loaded_at(group_slug)

    # In DB mode, get post count from persistent_term cache or DB
    post_count =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> length(DBStorage.list_posts(group_slug))
        posts -> length(posts)
      end

    %{
      exists: false,
      file_size: 0,
      modified_at: nil,
      post_count: post_count,
      generated_at: memory_loaded_at,
      in_memory: in_memory,
      memory_loaded_at: memory_loaded_at,
      memory_file_generated_at: memory_loaded_at,
      file_enabled: false,
      memory_enabled: memory_enabled,
      render_enabled: render_enabled,
      render_global_enabled: render_global_enabled
    }
  end

  # Filesystem mode: check JSON file + persistent_term + render cache
  defp get_cache_info_fs(group_slug) do
    cache_path = ListingCache.cache_path(group_slug)
    file_enabled = ListingCache.file_cache_enabled?()
    memory_enabled = ListingCache.memory_cache_enabled?()
    render_enabled = Renderer.group_render_cache_enabled?(group_slug)
    render_global_enabled = Renderer.global_render_cache_enabled?()

    # Check if in :persistent_term
    in_memory =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> false
        _ -> true
      end

    # Get when memory cache was loaded and what file version it contains
    memory_loaded_at = ListingCache.memory_loaded_at(group_slug)
    memory_file_generated_at = ListingCache.memory_file_generated_at(group_slug)

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

  defp get_primary_language_status(nil), do: nil

  defp get_primary_language_status(group_slug) do
    Publishing.get_primary_language_migration_status(group_slug)
  end

  defp get_legacy_structure_status(nil), do: %{versioned: 0, legacy: 0}

  defp get_legacy_structure_status(group_slug) do
    Publishing.get_legacy_structure_status(group_slug)
  end

  defp get_language_name(language_code) do
    case Publishing.get_language_info(language_code) do
      %{name: name} -> name
      _ -> String.upcase(language_code)
    end
  end

  # Returns the relative path prefix for files (e.g., "priv/blogging/" or "priv/publishing/")
  defp get_group_files_root(nil), do: "priv/publishing/"

  defp get_group_files_root(group_slug) do
    group_path = Storage.group_path(group_slug)

    cond do
      String.contains?(group_path, "/blogging/") -> "priv/blogging/"
      String.contains?(group_path, "/publishing/") -> "priv/publishing/"
      true -> "priv/publishing/"
    end
  end
end
