defmodule PhoenixKit.Modules.Publishing.Web.Index do
  @moduledoc """
  Publishing module overview dashboard.
  Provides high-level stats, quick actions, and guidance for administrators.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
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

    {blogs, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        date_time_settings
      )

    # Subscribe to PubSub for live updates when connected
    if connected?(socket) do
      # Subscribe to all blogs' post updates
      Enum.each(blogs, fn blog ->
        PublishingPubSub.subscribe_to_posts(blog["slug"])
      end)

      # Subscribe to global blogs topic (for blog creation/deletion)
      PublishingPubSub.subscribe_to_groups()
    end

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Publishing"))
      |> assign(
        :current_path,
        Routes.path("/admin/publishing", locale: socket.assigns.current_locale_base)
      )
      |> assign(:blogs, blogs)
      |> assign(:dashboard_insights, insights)
      |> assign(:dashboard_summary, summary)
      |> assign(:empty_state?, blogs == [])
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:endpoint_url, nil)
      |> assign(:date_time_settings, date_time_settings)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {blogs, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        socket.assigns.date_time_settings
      )

    endpoint_url = extract_endpoint_url(uri)

    {:noreply,
     assign(socket,
       blogs: blogs,
       dashboard_insights: insights,
       dashboard_summary: summary,
       empty_state?: blogs == [],
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

  defp refresh_dashboard(socket) do
    {blogs, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        socket.assigns.date_time_settings
      )

    # Resubscribe to any new blogs that may have been created
    Enum.each(blogs, fn blog ->
      PublishingPubSub.subscribe_to_posts(blog["slug"])
    end)

    assign(socket,
      blogs: blogs,
      dashboard_insights: insights,
      dashboard_summary: summary,
      empty_state?: blogs == []
    )
  end

  defp dashboard_snapshot(locale, current_user, date_time_settings) do
    blogs = Publishing.list_groups()
    insights = Enum.map(blogs, &build_blog_insight(&1, locale, current_user, date_time_settings))
    summary = build_summary(blogs, insights)

    {blogs, insights, summary}
  end

  defp build_blog_insight(blog, locale, current_user, date_time_settings) do
    posts = Publishing.list_posts(blog["slug"], locale)
    status_counts = Enum.frequencies_by(posts, &Map.get(&1.metadata, :status, "draft"))

    languages =
      posts
      |> Enum.flat_map(&(&1.available_languages || []))
      |> Enum.uniq()
      |> Enum.sort()

    latest_published_at = find_latest_published_at(posts)

    %{
      name: blog["name"],
      slug: blog["slug"],
      mode: Map.get(blog, "mode", "timestamp"),
      posts_count: length(posts),
      published_count: Map.get(status_counts, "published", 0),
      draft_count: Map.get(status_counts, "draft", 0),
      archived_count: Map.get(status_counts, "archived", 0),
      languages: languages,
      last_published_at: latest_published_at,
      last_published_at_text:
        format_datetime(latest_published_at, current_user, date_time_settings)
    }
  end

  defp find_latest_published_at(posts) do
    posts
    |> Enum.map(&Map.get(&1.metadata, :published_at))
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

  defp build_summary(blogs, insights) do
    Enum.reduce(
      insights,
      %{
        total_blogs: length(blogs),
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
