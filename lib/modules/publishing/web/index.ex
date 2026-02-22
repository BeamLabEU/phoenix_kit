defmodule PhoenixKit.Modules.Publishing.Web.Index do
  @moduledoc """
  Publishing module overview dashboard.
  Provides high-level stats, quick actions, and guidance for administrators.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBImporter
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Workers.MigrateLegacyStructureWorker
  alias PhoenixKit.Modules.Publishing.Workers.MigratePrimaryLanguageWorker
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  # Threshold for using background job vs synchronous migration
  @migration_async_threshold 20

  @impl true
  def mount(_params, _session, socket) do
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

    {groups, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        date_time_settings
      )

    # Subscribe to PubSub for live updates when connected
    if connected?(socket) do
      # Subscribe to all groups' post updates
      Enum.each(groups, fn group ->
        PublishingPubSub.subscribe_to_posts(group["slug"])
      end)

      # Subscribe to global groups topic (for group creation/deletion)
      PublishingPubSub.subscribe_to_groups()
    end

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Publishing"))
      |> assign(
        :current_path,
        Routes.path("/admin/publishing")
      )
      |> assign(:groups, groups)
      |> assign(:dashboard_insights, insights)
      |> assign(:dashboard_summary, summary)
      |> assign(:empty_state?, groups == [])
      |> assign(:fs_group_count, length(Publishing.list_groups()))
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:endpoint_url, nil)
      |> assign(:date_time_settings, date_time_settings)
      |> assign(:show_migration_modal, false)
      |> assign(:migration_modal_slug, nil)
      |> assign(:migration_modal_name, nil)
      |> assign(:migration_modal_count, 0)
      |> assign(:primary_language_name, get_language_name(Storage.get_primary_language()))
      |> assign(:migrations_in_progress, %{})
      # Version structure migration assigns
      |> assign(:show_version_migration_modal, false)
      |> assign(:version_migration_modal_slug, nil)
      |> assign(:version_migration_modal_name, nil)
      |> assign(:version_migration_modal_count, 0)
      |> assign(:version_migrations_in_progress, %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {groups, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        socket.assigns.date_time_settings
      )

    endpoint_url = extract_endpoint_url(uri)

    {:noreply,
     assign(socket,
       groups: groups,
       dashboard_insights: insights,
       dashboard_summary: summary,
       empty_state?: groups == [],
       endpoint_url: endpoint_url
     )}
  end

  # PubSub handlers for live updates
  @impl true
  def handle_info({:post_created, _post}, socket), do: {:noreply, refresh_dashboard(socket)}
  def handle_info({:post_updated, _post}, socket), do: {:noreply, refresh_dashboard(socket)}

  def handle_info({:post_status_changed, _post}, socket),
    do: {:noreply, refresh_dashboard(socket)}

  def handle_info({:post_deleted, _post_path}, socket), do: {:noreply, refresh_dashboard(socket)}
  def handle_info({:group_created, _group}, socket), do: {:noreply, refresh_dashboard(socket)}

  def handle_info({:group_deleted, _group_slug}, socket),
    do: {:noreply, refresh_dashboard(socket)}

  def handle_info({:group_updated, _group}, socket), do: {:noreply, refresh_dashboard(socket)}

  # DB import/migration handlers (broadcast on groups_topic)
  def handle_info({:db_import_started, _group_slug, _source}, socket), do: {:noreply, socket}

  def handle_info({:db_import_completed, _group_slug, _stats, _source}, socket),
    do: {:noreply, refresh_dashboard(socket)}

  def handle_info({:db_migration_started, _total_groups}, socket), do: {:noreply, socket}

  def handle_info({:db_migration_group_progress, _group_slug, _migrated, _total}, socket),
    do: {:noreply, socket}

  def handle_info({:db_migration_completed, _stats}, socket),
    do: {:noreply, refresh_dashboard(socket)}

  def handle_info({:migration_validation_completed, _results}, socket),
    do: {:noreply, refresh_dashboard(socket)}

  # Primary language migration progress handlers
  def handle_info({:primary_language_migration_started, _group_slug, _total_count}, socket) do
    # Already tracked in migrations_in_progress when job was enqueued
    {:noreply, socket}
  end

  def handle_info({:primary_language_migration_progress, group_slug, current, total}, socket) do
    # Update progress for the specific group
    migrations =
      if Map.has_key?(socket.assigns.migrations_in_progress, group_slug) do
        put_in(
          socket.assigns.migrations_in_progress,
          [group_slug],
          %{current: current, total: total}
        )
      else
        # Migration started elsewhere, add it
        Map.put(socket.assigns.migrations_in_progress, group_slug, %{
          current: current,
          total: total
        })
      end

    {:noreply, assign(socket, :migrations_in_progress, migrations)}
  end

  def handle_info(
        {:primary_language_migration_completed, group_slug, success_count, error_count,
         primary_language},
        socket
      ) do
    # Remove the completed migration from in-progress
    migrations = Map.delete(socket.assigns.migrations_in_progress, group_slug)

    socket =
      socket
      |> assign(:migrations_in_progress, migrations)
      |> refresh_dashboard()

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
  end

  # Legacy structure (version) migration progress handlers
  def handle_info({:legacy_structure_migration_started, _group_slug, _total_count}, socket) do
    # Already tracked in version_migrations_in_progress when job was enqueued
    {:noreply, socket}
  end

  def handle_info({:legacy_structure_migration_progress, group_slug, current, total}, socket) do
    # Update progress for the specific group
    migrations =
      if Map.has_key?(socket.assigns.version_migrations_in_progress, group_slug) do
        put_in(
          socket.assigns.version_migrations_in_progress,
          [group_slug],
          %{current: current, total: total}
        )
      else
        # Migration started elsewhere, add it
        Map.put(socket.assigns.version_migrations_in_progress, group_slug, %{
          current: current,
          total: total
        })
      end

    {:noreply, assign(socket, :version_migrations_in_progress, migrations)}
  end

  def handle_info(
        {:legacy_structure_migration_completed, group_slug, success_count, error_count},
        socket
      ) do
    # Remove the completed migration from in-progress
    migrations = Map.delete(socket.assigns.version_migrations_in_progress, group_slug)

    socket =
      socket
      |> assign(:version_migrations_in_progress, migrations)
      |> refresh_dashboard()

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
  end

  @impl true
  def handle_event("import_all_to_db", _params, socket) do
    case DBImporter.import_all_groups() do
      {:ok, stats} ->
        {:noreply,
         socket
         |> refresh_dashboard()
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
         |> refresh_dashboard()
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

  def handle_event(
        "show_migration_modal",
        %{"slug" => group_slug, "name" => group_name, "count" => count},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:show_migration_modal, true)
     |> assign(:migration_modal_slug, group_slug)
     |> assign(:migration_modal_name, group_name)
     |> assign(:migration_modal_count, String.to_integer(count))}
  end

  def handle_event("close_migration_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_migration_modal, false)
     |> assign(:migration_modal_slug, nil)
     |> assign(:migration_modal_name, nil)
     |> assign(:migration_modal_count, 0)}
  end

  # Version migration modal events
  def handle_event(
        "show_version_migration_modal",
        %{"slug" => group_slug, "name" => group_name, "count" => count},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:show_version_migration_modal, true)
     |> assign(:version_migration_modal_slug, group_slug)
     |> assign(:version_migration_modal_name, group_name)
     |> assign(:version_migration_modal_count, String.to_integer(count))}
  end

  def handle_event("close_version_migration_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_version_migration_modal, false)
     |> assign(:version_migration_modal_slug, nil)
     |> assign(:version_migration_modal_name, nil)
     |> assign(:version_migration_modal_count, 0)}
  end

  def handle_event("confirm_migrate_to_versioned", _params, socket) do
    group_slug = socket.assigns.version_migration_modal_slug
    total_count = socket.assigns.version_migration_modal_count

    # Use background job for large migrations
    if total_count > @migration_async_threshold do
      # Subscribe to this group's posts for progress updates
      PublishingPubSub.subscribe_to_posts(group_slug)

      case MigrateLegacyStructureWorker.enqueue(group_slug) do
        {:ok, _job} ->
          migrations =
            Map.put(socket.assigns.version_migrations_in_progress, group_slug, %{
              current: 0,
              total: total_count
            })

          {:noreply,
           socket
           |> assign(:show_version_migration_modal, false)
           |> assign(:version_migration_modal_slug, nil)
           |> assign(:version_migration_modal_name, nil)
           |> assign(:version_migration_modal_count, 0)
           |> assign(:version_migrations_in_progress, migrations)
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
       |> assign(:version_migration_modal_slug, nil)
       |> assign(:version_migration_modal_name, nil)
       |> assign(:version_migration_modal_count, 0)
       |> refresh_dashboard()
       |> put_flash(
         :info,
         gettext("Migrated %{count} posts to versioned structure", count: count)
       )}
    end
  end

  def handle_event("confirm_migrate_primary_language", _params, socket) do
    group_slug = socket.assigns.migration_modal_slug
    primary_language = Storage.get_primary_language()
    total_count = socket.assigns.migration_modal_count

    # Use background job for large migrations
    if total_count > @migration_async_threshold do
      # Subscribe to this group's posts for progress updates
      PublishingPubSub.subscribe_to_posts(group_slug)

      case MigratePrimaryLanguageWorker.enqueue(group_slug, primary_language) do
        {:ok, _job} ->
          migrations =
            Map.put(socket.assigns.migrations_in_progress, group_slug, %{
              current: 0,
              total: total_count
            })

          {:noreply,
           socket
           |> assign(:show_migration_modal, false)
           |> assign(:migration_modal_slug, nil)
           |> assign(:migration_modal_name, nil)
           |> assign(:migration_modal_count, 0)
           |> assign(:migrations_in_progress, migrations)
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
      # Synchronous migration — update DB records directly
      {:ok, count} = DBStorage.migrate_primary_language(group_slug, primary_language)

      {:noreply,
       socket
       |> assign(:show_migration_modal, false)
       |> assign(:migration_modal_slug, nil)
       |> assign(:migration_modal_name, nil)
       |> assign(:migration_modal_count, 0)
       |> refresh_dashboard()
       |> put_flash(
         :info,
         gettext("Updated %{count} posts to primary language: %{lang}",
           count: count,
           lang: get_language_name(primary_language)
         )
       )}
    end
  end

  defp get_language_name(language_code) do
    case Publishing.get_language_info(language_code) do
      %{name: name} -> name
      _ -> String.upcase(language_code)
    end
  end

  defp refresh_dashboard(socket) do
    {groups, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        socket.assigns.date_time_settings
      )

    # Resubscribe to any new groups that may have been created
    Enum.each(groups, fn group ->
      PublishingPubSub.subscribe_to_posts(group["slug"])
    end)

    assign(socket,
      groups: groups,
      dashboard_insights: insights,
      dashboard_summary: summary,
      empty_state?: groups == []
    )
  end

  defp dashboard_snapshot(_locale, current_user, date_time_settings) do
    # Admin side reads from database only — groups appear after import
    db_groups = DBStorage.list_groups()

    groups =
      Enum.map(db_groups, fn g ->
        %{
          "name" => g.name,
          "slug" => g.slug,
          "mode" => g.mode,
          "position" => g.position
        }
      end)

    insights =
      Enum.map(db_groups, &build_group_insight(&1, current_user, date_time_settings))

    summary = build_summary(groups, insights)

    {groups, insights, summary}
  end

  defp build_group_insight(db_group, current_user, date_time_settings) do
    posts = DBStorage.list_posts_with_metadata(db_group.slug)
    status_counts = Enum.frequencies_by(posts, &Map.get(&1[:metadata] || %{}, :status, "draft"))

    languages =
      posts
      |> Enum.flat_map(&(&1[:available_languages] || []))
      |> Enum.uniq()
      |> Enum.sort()

    latest_published_at = find_latest_published_at(posts)
    fs_post_count = length(Publishing.list_posts(db_group.slug))

    # Check DB records for primary language issues
    global_primary = Storage.get_primary_language()
    primary_lang_status = DBStorage.count_primary_language_status(db_group.slug, global_primary)

    lang_migration_count =
      primary_lang_status.needs_backfill + primary_lang_status.needs_migration

    %{
      name: db_group.name,
      slug: db_group.slug,
      mode: db_group.mode,
      posts_count: length(posts),
      needs_import: fs_post_count > 0 and posts == [],
      published_count: Map.get(status_counts, "published", 0),
      draft_count: Map.get(status_counts, "draft", 0),
      archived_count: Map.get(status_counts, "archived", 0),
      languages: languages,
      last_published_at: latest_published_at,
      last_published_at_text:
        format_datetime(latest_published_at, current_user, date_time_settings),
      primary_language_status: primary_lang_status,
      needs_primary_language_migration: lang_migration_count > 0,
      needs_migration_count: lang_migration_count,
      # Legacy structure is a filesystem concern — not relevant for DB records
      legacy_structure_status: %{legacy: 0, versioned: 0},
      needs_version_migration: false,
      legacy_count: 0
    }
  end

  defp find_latest_published_at(posts) do
    posts
    |> Enum.map(&get_in(&1, [:metadata, :published_at]))
    |> Enum.reduce(nil, &update_latest_datetime/2)
  end

  defp update_latest_datetime(value, acc) do
    case parse_datetime(value) do
      {:ok, dt} -> compare_and_select_latest(dt, acc)
      :error -> acc
    end
  end

  defp compare_and_select_latest(datetime, nil), do: datetime

  defp compare_and_select_latest(datetime, current) do
    if DateTime.compare(datetime, current) == :gt, do: datetime, else: current
  end

  defp build_summary(groups, insights) do
    Enum.reduce(
      insights,
      %{
        total_groups: length(groups),
        total_posts: 0,
        published_posts: 0,
        draft_posts: 0,
        archived_posts: 0
      },
      fn insight, acc ->
        %{
          acc
          | total_posts: acc.total_posts + insight.posts_count,
            published_posts: acc.published_posts + insight.published_count,
            draft_posts: acc.draft_posts + insight.draft_count,
            archived_posts: acc.archived_posts + insight.archived_count
        }
      end
    )
  end

  defp parse_datetime(nil), do: :error

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp format_datetime(nil, _user, _settings), do: nil

  defp format_datetime(%DateTime{} = datetime, current_user, date_time_settings) do
    # Fallback to dummy user if current_user is nil
    user = current_user || %{user_timezone: nil}

    # Convert DateTime to NaiveDateTime (assuming stored as UTC)
    naive_dt = DateTime.to_naive(datetime)

    # Format date part with timezone conversion
    date_str = UtilsDate.format_date_with_user_timezone_cached(naive_dt, user, date_time_settings)

    # Format time part with timezone conversion
    time_str = UtilsDate.format_time_with_user_timezone_cached(naive_dt, user, date_time_settings)

    "#{date_str} #{time_str}"
  rescue
    _ -> nil
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
end
