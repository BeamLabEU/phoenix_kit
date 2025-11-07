defmodule PhoenixKitWeb.Live.Modules.Blogging.Index do
  @moduledoc """
  Blogging module overview dashboard.
  Provides high-level stats, quick actions, and guidance for administrators.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    {blogs, insights, summary} = dashboard_snapshot(locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("Blogging"))
      |> assign(:current_path, Routes.path("/admin/blogging", locale: locale))
      |> assign(:blogs, blogs)
      |> assign(:dashboard_insights, insights)
      |> assign(:dashboard_summary, summary)
      |> assign(:empty_state?, blogs == [])
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:endpoint_url, nil)

    {:ok, socket}
  end

  def handle_params(_params, uri, socket) do
    {blogs, insights, summary} = dashboard_snapshot(socket.assigns.current_locale)
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

  defp dashboard_snapshot(locale) do
    blogs = Blogging.list_blogs()
    insights = Enum.map(blogs, &build_blog_insight(&1, locale))
    summary = build_summary(blogs, insights)

    {blogs, insights, summary}
  end

  defp build_blog_insight(blog, locale) do
    posts = Blogging.list_posts(blog["slug"], locale)
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
      last_published_at_text: format_datetime(latest_published_at)
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

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(DateTime.truncate(datetime, :second), "%B %d, %Y · %H:%M UTC")
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
