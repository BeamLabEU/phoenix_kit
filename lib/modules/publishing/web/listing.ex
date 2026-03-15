defmodule PhoenixKit.Modules.Publishing.Web.Listing do
  @moduledoc """
  Lists posts for a publishing group and provides creation actions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.StaleFixer
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  # Import publishing-specific components
  import PhoenixKit.Modules.Publishing.Web.Components.LanguageSwitcher

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    if connected?(socket), do: subscribe_to_pubsub(group_slug)

    # Load initial data in mount so the connected render's join reply matches
    # the dead render output, preventing the visual flash caused by morphdom
    # patching empty assigns before handle_params fills them.
    {groups, current_group, filtered_posts, default_mode, status_counts, all_posts} =
      load_initial_data(group_slug)

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, "Publishing")
      |> assign(:current_path, Routes.path("/admin/publishing/#{group_slug}"))
      |> assign(:groups, groups)
      |> assign(:current_group, current_group)
      |> assign(:group_slug, group_slug)
      |> assign(:enabled_languages, Publishing.enabled_language_codes())
      |> assign(:primary_language, Publishing.get_primary_language())
      |> assign(:primary_language_name, get_language_name(Publishing.get_primary_language()))
      |> assign(:posts, filtered_posts)
      |> assign(:loading, false)
      |> assign(:endpoint_url, "")
      |> assign(:date_time_settings, load_date_time_settings())
      |> assign(:primary_language_status, primary_language_status_from_posts(all_posts))
      |> assign(:active_editors, %{})
      |> assign(:translating_posts, %{})
      |> assign(:pending_post_updates, %{})
      |> assign(:visible_count, 20)
      |> assign(:post_view_mode, default_mode)
      |> assign(:post_status_counts, status_counts)
      |> assign(:mount_group_slug, group_slug)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    new_group_slug = params["group"] || params["category"] || params["type"]
    old_group_slug = socket.assigns[:group_slug]

    socket = handle_subscription_change(socket, old_group_slug, new_group_slug)

    # Run stale fixer for this group's posts on first connected load.
    # Includes trashed posts so empty ones get hard-deleted instead of
    # sitting in trash with no recoverable content.
    if connected?(socket) and new_group_slug do
      Task.start(fn ->
        active = DBStorage.list_posts(new_group_slug)
        trashed = DBStorage.list_posts(new_group_slug, "trashed")
        Enum.each(active ++ trashed, &StaleFixer.fix_stale_post/1)
      end)
    end

    # Skip full reload if mount already loaded data for this group.
    # This prevents the visual flash on hard refresh (dead render → connected render).
    # On live navigation to a different group, mount_group_slug won't match so we reload.
    skip_reload? = socket.assigns[:mount_group_slug] == new_group_slug

    socket =
      if skip_reload? do
        socket
        |> assign(:endpoint_url, extract_endpoint_url(uri))
        |> assign(:mount_group_slug, nil)
      else
        apply_full_reload(socket, new_group_slug, uri)
      end

    {:noreply, redirect_if_missing(socket)}
  end

  @impl true
  def handle_event("create_post", _params, %{assigns: %{group_slug: group_slug}} = socket) do
    {:noreply, push_navigate(socket, to: Helpers.build_new_post_url(group_slug))}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, assign(socket, :visible_count, socket.assigns.visible_count + 20)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, reload_current_view(socket)}
  end

  @valid_post_views ["published", "draft", "archived", "trashed"]

  def handle_event("switch_post_view", %{"mode" => mode}, socket)
      when mode in @valid_post_views do
    send(self(), {:deferred_tab_switch, mode})

    {:noreply,
     socket
     |> assign(:post_view_mode, mode)
     |> assign(:posts, [])
     |> assign(:visible_count, 20)
     |> assign(:loading, true)}
  end

  def handle_event("trash_post", %{"uuid" => post_uuid}, socket) do
    group_slug = socket.assigns.group_slug

    case Publishing.trash_post(group_slug, post_uuid) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload_current_view()
         |> put_flash(:info, gettext("Post moved to trash"))}

      {:error, reason} ->
        Logger.warning("[Publishing.Listing] Trash post failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to trash post"))}
    end
  end

  def handle_event("restore_post", %{"uuid" => post_uuid}, socket) do
    group_slug = socket.assigns.group_slug

    case DBStorage.get_post_by_uuid(post_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Post not found"))}

      db_post ->
        case DBStorage.update_post(db_post, %{status: "draft"}) do
          {:ok, _} ->
            ListingCache.regenerate(group_slug)

            {:noreply,
             socket
             |> reload_current_view()
             |> put_flash(:info, gettext("Post restored as draft"))}

          {:error, reason} ->
            Logger.warning("[Publishing.Listing] Restore post failed: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, gettext("Failed to restore post"))}
        end
    end
  end

  def handle_event("add_language", params, socket) do
    lang_code = params["language"]
    group_slug = socket.assigns.group_slug

    uuid = params["uuid"]
    url = Helpers.build_edit_url(group_slug, %{uuid: uuid}, lang: lang_code)

    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("language_action", %{"language" => lang_code} = params, socket) do
    group_slug = socket.assigns.group_slug

    case params["uuid"] do
      uuid when is_binary(uuid) and uuid != "" ->
        url = Helpers.build_edit_url(group_slug, %{uuid: uuid}, lang: lang_code)
        {:noreply, push_navigate(socket, to: url)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("change_status", %{"uuid" => post_uuid, "status" => new_status}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Publishing.read_post_by_uuid(post_uuid) do
      {:ok, post} ->
        # Determine if this is the primary language for status propagation
        primary_language = post[:primary_language] || Publishing.get_primary_language()
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
             |> reload_current_view()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update status"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Post not found"))}
    end
  end

  def handle_event(
        "toggle_status",
        %{"uuid" => post_uuid, "current-status" => current_status},
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

    case Publishing.read_post_by_uuid(post_uuid) do
      {:ok, post} ->
        # Determine if this is the primary language for status propagation
        primary_language = post[:primary_language] || Publishing.get_primary_language()
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
             |> reload_current_view()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update status"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Post not found"))}
    end
  end

  def handle_event("update_primary_language", _params, socket) do
    group_slug = socket.assigns.group_slug

    case Publishing.update_posts_primary_language(group_slug) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, gettext("All posts already up to date"))}

      {:ok, count} ->
        {:noreply,
         socket
         |> refresh_posts()
         |> put_flash(
           :info,
           gettext("Updated %{count} posts to primary language: %{lang}",
             count: count,
             lang: get_language_name(Publishing.get_primary_language())
           )
         )}
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing.Listing] Primary language update failed: #{Exception.message(e)}"
      )

      {:noreply, put_flash(socket, :error, gettext("Failed to update primary language"))}
  end

  # ============================================================================
  # Post View Helpers
  # ============================================================================

  defp reload_current_view(socket), do: load_posts_for_view(socket)

  defp load_posts_for_view(socket) do
    group_slug = socket.assigns.group_slug
    mode = socket.assigns.post_view_mode

    # Always load all non-trashed posts for counting
    all_posts = DBStorage.list_posts_with_metadata(group_slug)
    trashed_count = length(DBStorage.list_posts(group_slug, "trashed"))

    posts =
      case mode do
        "trashed" ->
          DBStorage.list_posts_with_metadata(group_slug, "trashed")

        status ->
          Enum.filter(all_posts, fn p -> p[:metadata] && p.metadata.status == status end)
      end

    socket
    |> assign(:posts, posts)
    |> assign(:post_status_counts, build_status_counts(all_posts, trashed_count))
    |> assign(:loading, false)
  end

  defp build_status_counts(posts, trashed_count) do
    counts =
      Enum.reduce(posts, %{}, fn post, acc ->
        status = post[:metadata] && post.metadata.status
        if status, do: Map.update(acc, status, 1, &(&1 + 1)), else: acc
      end)

    Map.put(counts, "trashed", trashed_count)
  end

  @impl true
  def handle_info({:deferred_tab_switch, _mode}, socket) do
    {:noreply, load_posts_for_view(socket)}
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
    # Debounce post updates to prevent DB hammering on rapid saves
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

  def handle_info({:post_deleted, _post_identifier}, socket) do
    {:noreply, reload_current_view(socket)}
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

  def handle_info({:cache_changed, _group_slug}, socket) do
    {:noreply, socket}
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

  # Primary language update completed (from this page or elsewhere)
  def handle_info(
        {:primary_language_migration_completed, group_slug, count, _errors, primary_language},
        socket
      ) do
    if group_slug == socket.assigns.group_slug do
      {:noreply,
       socket
       |> refresh_posts()
       |> put_flash(
         :info,
         gettext("Updated %{count} posts to primary language: %{lang}",
           count: count,
           lang: get_language_name(primary_language)
         )
       )}
    else
      {:noreply, socket}
    end
  end

  # Group change handlers - keep sidebar in sync
  def handle_info({:group_created, _group}, socket) do
    {:noreply, assign(socket, :groups, load_db_groups())}
  end

  def handle_info({:group_updated, group}, socket) do
    groups = load_db_groups()
    current_group = Enum.find(groups, fn b -> b["slug"] == socket.assigns.group_slug end)

    socket =
      socket
      |> assign(:groups, groups)
      |> assign(:current_group, current_group || group)

    {:noreply, socket}
  end

  def handle_info({:group_deleted, deleted_slug}, socket) do
    if socket.assigns.group_slug == deleted_slug do
      # Current group was trashed/deleted — redirect to publishing index
      {:noreply, push_navigate(socket, to: Routes.path("/admin/publishing"))}
    else
      {:noreply, assign(socket, :groups, load_db_groups())}
    end
  end

  defp refresh_posts(socket) do
    case socket.assigns.group_slug do
      nil ->
        socket

      group_slug ->
        all_posts = DBStorage.list_posts_with_metadata(group_slug)
        trashed_count = length(DBStorage.list_posts(group_slug, "trashed"))
        mode = socket.assigns.post_view_mode

        filtered_posts =
          case mode do
            "trashed" ->
              DBStorage.list_posts_with_metadata(group_slug, "trashed")

            status ->
              Enum.filter(all_posts, fn p -> p[:metadata] && p.metadata.status == status end)
          end

        socket
        |> assign(:posts, filtered_posts)
        |> assign(:primary_language_status, primary_language_status_from_posts(all_posts))
        |> assign(:post_status_counts, build_status_counts(all_posts, trashed_count))
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

  @impl true
  def terminate(_reason, socket) do
    pending = socket.assigns[:pending_post_updates] || %{}

    for {_slug, timer_ref} <- pending do
      Process.cancel_timer(timer_ref)
    end

    :ok
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
  # We refresh the full post from the database to ensure all fields are current
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

      {:error, reason} ->
        Logger.warning(
          "[Publishing.Listing] fetch_and_update_post failed for #{post_slug}: #{inspect(reason)}, doing full refresh"
        )

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

  # Refresh a single post by slug (used when we need fresh data from the database)
  defp refresh_post_by_slug(socket, post_slug) do
    case socket.assigns.group_slug do
      nil ->
        socket

      group_slug ->
        case Publishing.read_post(group_slug, post_slug, socket.assigns.current_locale_base, nil) do
          {:ok, fresh_post} ->
            # Replace directly — data is already fresh from DB, no need to re-read
            replace_post_in_list(socket, post_slug, fresh_post)

          {:error, reason} ->
            Logger.warning(
              "[Publishing.Listing] Post #{post_slug} not found during refresh: #{inspect(reason)}, doing full refresh"
            )

            refresh_posts(socket)
        end
    end
  end

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

      # Cancel any pending debounce timers before switching groups
      pending = socket.assigns[:pending_post_updates] || %{}

      for {_slug, timer_ref} <- pending do
        Process.cancel_timer(timer_ref)
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
    {groups, current_group}
  end

  defp load_initial_data(group_slug) do
    {groups, current_group} = load_groups_and_current(group_slug)

    all_posts =
      case group_slug do
        nil -> []
        slug -> DBStorage.list_posts_with_metadata(slug)
      end

    trashed_count =
      case group_slug do
        nil -> 0
        slug -> length(DBStorage.list_posts(slug, "trashed"))
      end

    status_counts = build_status_counts(all_posts, trashed_count)
    default_mode = default_tab_mode(status_counts)
    filtered_posts = filter_posts_for_mode(group_slug, default_mode, all_posts)

    {groups, current_group, filtered_posts, default_mode, status_counts, all_posts}
  end

  defp apply_full_reload(socket, group_slug, uri) do
    {groups, current_group, filtered_posts, default_mode, status_counts, all_posts} =
      load_initial_data(group_slug)

    socket
    |> assign(:groups, groups)
    |> assign(:current_group, current_group)
    |> assign(:posts, filtered_posts)
    |> assign(:post_view_mode, default_mode)
    |> assign(:visible_count, 20)
    |> assign(:endpoint_url, extract_endpoint_url(uri))
    |> assign(:primary_language_status, primary_language_status_from_posts(all_posts))
    |> assign(:post_status_counts, status_counts)
    |> assign(:loading, false)
  end

  defp default_tab_mode(status_counts) do
    cond do
      Map.get(status_counts, "published", 0) > 0 -> "published"
      Map.get(status_counts, "draft", 0) > 0 -> "draft"
      Map.get(status_counts, "archived", 0) > 0 -> "archived"
      Map.get(status_counts, "trashed", 0) > 0 -> "trashed"
      true -> "published"
    end
  end

  defp filter_posts_for_mode(group_slug, mode, all_posts) do
    case mode do
      "trashed" ->
        DBStorage.list_posts_with_metadata(group_slug, "trashed")

      status ->
        Enum.filter(all_posts, fn p -> p[:metadata] && p.metadata.status == status end)
    end
  end

  defp load_db_groups do
    DBStorage.list_groups()
    |> Enum.map(fn g ->
      %{"name" => g.name, "slug" => g.slug, "mode" => g.mode, "position" => g.position}
    end)
  end

  defp redirect_if_missing(%{assigns: %{current_group: nil}} = socket) do
    push_navigate(socket, to: Routes.path("/admin/publishing"))
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
      primary_language || post[:primary_language] || Publishing.get_primary_language()

    # Use shared ordering function for consistent display
    all_languages =
      Publishing.order_languages_for_display(
        available_languages,
        enabled_languages,
        primary_lang
      )

    Enum.map(all_languages, fn lang_code ->
      lang_info = Publishing.get_language_info(lang_code)
      content_exists = lang_code in available_languages
      is_enabled = Publishing.language_enabled?(lang_code, enabled_languages)
      is_known = lang_info != nil
      is_primary = lang_code == primary_lang

      # Status matches the version's status
      lang_status = if content_exists, do: status, else: nil

      # Get display code (base or full dialect depending on enabled languages)
      display_code = Publishing.get_display_code(lang_code, enabled_languages)

      %{
        code: lang_code,
        display_code: display_code,
        name: if(lang_info, do: lang_info.name, else: lang_code),
        flag: if(lang_info, do: lang_info.flag, else: ""),
        status: lang_status,
        exists: content_exists,
        enabled: is_enabled,
        known: is_known,
        is_primary: is_primary,
        uuid: post[:uuid]
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
    identifier = post[:uuid] || post.slug

    # Invalidate the render cache for this post
    Renderer.invalidate_cache(group_slug, identifier, post.language)
  end

  @doc """
  Builds language data for the publishing_language_switcher component.
  Returns a list of language maps with status, enabled flag, known flag, and metadata.

  The `enabled` field indicates if the language is currently active in the Languages module.
  The `known` field indicates if the language code is recognized.
  The `is_primary` field indicates if this is the primary language for versioning.
  """
  def build_post_languages(
        post,
        _group_slug,
        enabled_languages,
        _current_locale,
        primary_language \\ nil
      ) do
    primary_lang =
      primary_language || post[:primary_language] || Publishing.get_primary_language()

    all_languages =
      Publishing.order_languages_for_display(
        post.available_languages || [],
        enabled_languages,
        primary_lang
      )

    all_languages
    |> Enum.map(&build_language_entry(&1, post, enabled_languages, primary_lang))
    |> Enum.filter(fn lang -> lang.exists || lang.enabled end)
  end

  defp build_language_entry(lang_code, post, enabled_languages, primary_lang) do
    lang_info = Publishing.get_language_info(lang_code)
    available = post.available_languages || []
    content_exists = lang_code in available

    # Status comes from the post level (primary language), not per-translation
    post_status = post[:metadata] && post.metadata.status

    %{
      code: lang_code,
      display_code: Publishing.get_display_code(lang_code, enabled_languages),
      name: if(lang_info, do: lang_info.name, else: lang_code),
      flag: if(lang_info, do: lang_info.flag, else: ""),
      status: if(content_exists, do: post_status, else: nil),
      exists: content_exists,
      enabled: Publishing.language_enabled?(lang_code, enabled_languages),
      known: lang_info != nil,
      is_primary: lang_code == primary_lang,
      uuid: post[:uuid]
    }
  end

  defp primary_language_status_from_posts([]), do: nil

  defp primary_language_status_from_posts(posts) do
    global_primary = Publishing.get_primary_language()
    DBStorage.count_primary_language_status_from_posts(posts, global_primary)
  end

  defp get_language_name(language_code) do
    case Publishing.get_language_info(language_code) do
      %{name: name} -> name
      _ -> String.upcase(language_code)
    end
  end
end
