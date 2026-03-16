defmodule PhoenixKit.Modules.Publishing.Web.Index do
  @moduledoc """
  Publishing module overview dashboard.
  Provides high-level stats, quick actions, and guidance for administrators.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers

  @group_statuses Constants.group_statuses()
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

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
      |> assign(:enabled_languages, Publishing.enabled_language_codes())
      |> assign(:endpoint_url, "")
      |> assign(:date_time_settings, date_time_settings)
      |> assign(
        :primary_language_name,
        Helpers.get_language_name(Publishing.get_primary_language())
      )
      |> assign(:dashboard_refresh_timer, nil)
      |> assign(:view_mode, "active")
      |> assign(:loading, false)
      |> assign(:trashed_count, length(Publishing.list_groups("trashed")))

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :endpoint_url, extract_endpoint_url(uri))}
  end

  # PubSub handlers for live updates — debounced to prevent rapid re-renders
  @dashboard_debounce_ms 500

  @impl true
  def handle_info({:deferred_view_switch, _mode}, socket) do
    {:noreply,
     socket
     |> refresh_dashboard()
     |> assign(:loading, false)}
  end

  def handle_info({:post_created, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:post_updated, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:post_status_changed, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:post_deleted, _post_identifier}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:group_created, _group}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:group_deleted, _group_slug}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:group_updated, _group}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:version_created, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:version_live_changed, _uuid, _version}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:version_deleted, _slug, _version}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info(:debounced_dashboard_refresh, socket),
    do: {:noreply, socket |> assign(:dashboard_refresh_timer, nil) |> refresh_dashboard()}

  # Primary language update completed (from this page or elsewhere)
  def handle_info(
        {:primary_language_migration_completed, _group_slug, count, _errors, primary_language},
        socket
      ) do
    {:noreply,
     socket
     |> refresh_dashboard()
     |> put_flash(
       :info,
       gettext("Updated %{count} posts to primary language: %{lang}",
         count: count,
         lang: Helpers.get_language_name(primary_language)
       )
     )}
  end

  # Catch-all for other PubSub messages (translation progress, cache changes, etc.)
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("update_primary_language", %{"slug" => group_slug}, socket) do
    case Publishing.update_posts_primary_language(group_slug) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, gettext("All posts already up to date"))}

      {:ok, count} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(
           :info,
           gettext("Updated %{count} posts to primary language: %{lang}",
             count: count,
             lang: Helpers.get_language_name(Publishing.get_primary_language())
           )
         )}
    end
  rescue
    e ->
      Logger.error("[Publishing.Index] Primary language update failed: #{Exception.message(e)}")
      {:noreply, put_flash(socket, :error, gettext("Failed to update primary language"))}
  end

  def handle_event("switch_view", %{"mode" => mode}, socket) when mode in @group_statuses do
    send(self(), {:deferred_view_switch, mode})

    {:noreply,
     socket
     |> assign(:view_mode, mode)
     |> assign(:dashboard_insights, [])
     |> assign(:empty_state?, false)
     |> assign(:loading, true)}
  end

  def handle_event("trash_group", %{"slug" => slug}, socket) do
    case Publishing.trash_group(slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, gettext("Group moved to trash"))}

      {:error, reason} ->
        Logger.warning("[Publishing.Index] Trash group failed for #{slug}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to trash group"))}
    end
  end

  def handle_event("restore_group", %{"slug" => slug}, socket) do
    case Publishing.restore_group(slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, gettext("Group restored"))}

      {:error, reason} ->
        Logger.warning("[Publishing.Index] Restore group failed for #{slug}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to restore group"))}
    end
  end

  def handle_event("delete_group", %{"slug" => slug}, socket) do
    case Publishing.remove_group(slug, force: true) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, gettext("Group permanently deleted"))}

      {:error, reason} ->
        Logger.warning("[Publishing.Index] Delete group failed for #{slug}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to delete group"))}
    end
  end

  defp schedule_dashboard_refresh(socket) do
    if timer = socket.assigns[:dashboard_refresh_timer] do
      Process.cancel_timer(timer)
    end

    timer = Process.send_after(self(), :debounced_dashboard_refresh, @dashboard_debounce_ms)
    assign(socket, :dashboard_refresh_timer, timer)
  end

  defp refresh_dashboard(socket) do
    view_mode = socket.assigns[:view_mode] || "active"

    {groups, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        socket.assigns.date_time_settings,
        view_mode
      )

    trashed_count = length(Publishing.list_groups("trashed"))

    # Resubscribe to any new groups that may have been created
    Enum.each(groups, fn group ->
      PublishingPubSub.subscribe_to_posts(group["slug"])
    end)

    assign(socket,
      groups: groups,
      dashboard_insights: insights,
      dashboard_summary: summary,
      empty_state?: groups == [] and view_mode == "active",
      trashed_count: trashed_count
    )
  end

  defp dashboard_snapshot(_locale, current_user, date_time_settings, view_mode \\ "active") do
    # Admin side reads from database only
    db_groups = Publishing.list_groups(view_mode)

    groups = db_groups

    insights =
      Enum.map(db_groups, &build_group_insight(&1, current_user, date_time_settings))

    summary = build_summary(groups, insights)

    {groups, insights, summary}
  end

  defp build_group_insight(db_group, current_user, date_time_settings) do
    group_slug = db_group["slug"]

    # Use ListingCache when available (sub-microsecond), fall back to DB
    posts =
      case ListingCache.read(group_slug) do
        {:ok, cached_posts} -> cached_posts
        {:error, _} -> Publishing.list_posts(group_slug)
      end

    status_counts = Enum.frequencies_by(posts, &Map.get(&1[:metadata] || %{}, :status, "draft"))

    languages =
      posts
      |> Enum.flat_map(&(&1[:available_languages] || []))
      |> Enum.uniq()
      |> Enum.sort()

    latest_published_at = find_latest_published_at(posts)

    # Reuse already-loaded posts for primary language check (avoids redundant DB query)
    global_primary = Publishing.get_primary_language()

    primary_lang_status =
      Publishing.count_primary_language_status(posts, global_primary)

    lang_migration_count =
      if primary_lang_status,
        do: primary_lang_status.needs_backfill + primary_lang_status.needs_migration,
        else: 0

    %{
      name: db_group["name"],
      slug: group_slug,
      mode: db_group["mode"],
      posts_count: length(posts),
      published_count: Map.get(status_counts, "published", 0),
      draft_count: Map.get(status_counts, "draft", 0),
      archived_count: Map.get(status_counts, "archived", 0),
      languages: languages,
      last_published_at: latest_published_at,
      last_published_at_text:
        format_datetime(latest_published_at, current_user, date_time_settings),
      primary_language_status: primary_lang_status,
      needs_primary_language_migration: lang_migration_count > 0,
      needs_migration_count: lang_migration_count
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
