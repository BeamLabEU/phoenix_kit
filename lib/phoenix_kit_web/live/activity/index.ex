defmodule PhoenixKitWeb.Live.Activity.Index do
  @moduledoc """
  Admin LiveView for the activity feed.

  Shows a real-time stream of business-level actions across the platform
  with filtering by action type, user, resource type, and date range.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Activity
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "dashboard") do
      if connected?(socket) do
        PhoenixKit.PubSub.Manager.subscribe(Activity.pubsub_topic())
      end

      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "Activity")
        |> assign(:project_title, project_title)
        |> assign(:action_types, Activity.list_action_types())
        |> assign(:resource_types, Activity.list_resource_types())
        |> assign_filter_defaults()
        |> load_activities()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Access denied")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    socket =
      socket
      |> assign(:url_path, URI.parse(url).path)
      |> apply_params(params)
      |> load_activities()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter_params = Map.get(params, "filter", %{})

    new_params =
      %{"page" => "1"}
      |> maybe_put("action", filter_params["action"])
      |> maybe_put("resource_type", filter_params["resource_type"])

    query = URI.encode_query(new_params)
    {:noreply, push_patch(socket, to: Routes.path("/admin/activity?#{query}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/activity"))}
  end

  @impl true
  def handle_info({:activity_logged, _entry}, socket) do
    # Reload on new activity (real-time update)
    {:noreply, load_activities(socket)}
  end

  ## Private

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, 50)
    |> assign(:filter_action, nil)
    |> assign(:filter_resource_type, nil)
  end

  defp apply_params(socket, params) do
    socket
    |> assign(:page, parse_int(params["page"], 1))
    |> assign(:filter_action, blank_to_nil(params["action"]))
    |> assign(:filter_resource_type, blank_to_nil(params["resource_type"]))
  end

  defp load_activities(socket) do
    result =
      Activity.list(
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        action: socket.assigns.filter_action,
        resource_type: socket.assigns.filter_resource_type,
        preload: [:actor, :target]
      )

    socket
    |> assign(:entries, result.entries)
    |> assign(:total, result.total)
    |> assign(:total_pages, result.total_pages)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> max(n, 1)
      :error -> default
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp action_badge_color(action) do
    cond do
      String.contains?(action, "created") ->
        "badge-success"

      String.contains?(action, "deleted") ->
        "badge-error"

      String.contains?(action, "updated") or String.contains?(action, "changed") ->
        "badge-warning"

      String.contains?(action, "liked") or String.contains?(action, "followed") ->
        "badge-info"

      true ->
        "badge-ghost"
    end
  end

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end
end
