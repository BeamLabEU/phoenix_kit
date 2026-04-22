defmodule PhoenixKitWeb.Live.Users.Notifications do
  @moduledoc """
  Inbox LiveView at `/notifications`.

  Lists notifications for the signed-in user, newest first. Supports:

    * status filter (All / Unread only)
    * per-row "Mark seen" + "Dismiss"
    * bulk "Mark all seen" + "Clear all"
    * live refresh on PubSub events (`:notification_created`,
      `:notifications_bulk_updated`, …)

  Uses `LayoutWrapper.app_layout` for consistent chrome.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.Events
  alias PhoenixKit.Notifications.Render
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    user = scope && Scope.user(scope)

    if user do
      if connected?(socket), do: Events.subscribe(user.uuid)

      project_title = Settings.get_project_title()

      {:ok,
       socket
       |> assign(:page_title, "Notifications")
       |> assign(:project_title, project_title)
       |> assign(:user_uuid, user.uuid)
       |> assign(:status, :all)
       |> assign(:page, 1)
       |> assign(:per_page, @per_page)
       |> load_notifications()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please sign in to see your notifications.")
       |> push_navigate(to: Routes.path("/users/log-in"))}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    status =
      case params["status"] do
        "unread" -> :unread
        _ -> :all
      end

    page =
      case Integer.parse(params["page"] || "1") do
        {n, _} when n > 0 -> n
        _ -> 1
      end

    {:noreply,
     socket
     |> assign(:url_path, URI.parse(url).path)
     |> assign(:status, status)
     |> assign(:page, page)
     |> load_notifications()}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("set_filter", %{"status" => status}, socket) do
    target = build_path(status: status)
    {:noreply, push_patch(socket, to: target)}
  end

  def handle_event("set_page", %{"page" => page}, socket) do
    target = build_path(page: page, status: socket.assigns.status)
    {:noreply, push_patch(socket, to: target)}
  end

  def handle_event("mark_seen", %{"uuid" => uuid}, socket) do
    Notifications.mark_seen(socket.assigns.user_uuid, uuid)
    {:noreply, load_notifications(socket)}
  end

  def handle_event("dismiss", %{"uuid" => uuid}, socket) do
    Notifications.dismiss(socket.assigns.user_uuid, uuid)
    {:noreply, load_notifications(socket)}
  end

  def handle_event("open_notification", %{"uuid" => uuid}, socket) do
    case Notifications.mark_seen(socket.assigns.user_uuid, uuid) do
      {:ok, notification} ->
        target = Render.render(notification).link

        if target do
          {:noreply, push_navigate(socket, to: target)}
        else
          {:noreply, load_notifications(socket)}
        end

      _ ->
        {:noreply, load_notifications(socket)}
    end
  end

  def handle_event("mark_all_seen", _params, socket) do
    Notifications.mark_all_seen(socket.assigns.user_uuid)
    {:noreply, load_notifications(socket)}
  end

  def handle_event("dismiss_all", _params, socket) do
    Notifications.dismiss_all(socket.assigns.user_uuid)
    {:noreply, load_notifications(socket)}
  end

  # ── PubSub ─────────────────────────────────────────────────────────

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [
             :notification_created,
             :notification_seen,
             :notification_dismissed,
             :notifications_bulk_updated
           ] do
    {:noreply, load_notifications(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Helpers ────────────────────────────────────────────────────────

  defp load_notifications(socket) do
    {rows, total} =
      Notifications.list_for_user(socket.assigns.user_uuid,
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        status: socket.assigns.status
      )

    socket
    |> assign(:notifications, rows)
    |> assign(:total_count, total)
    |> assign(:total_pages, max(ceil(total / socket.assigns.per_page), 1))
    |> assign(:unread_count, Notifications.count_unread(socket.assigns.user_uuid))
  end

  defp build_path(opts) do
    status = Keyword.get(opts, :status, :all)
    page = Keyword.get(opts, :page, 1)

    params =
      %{}
      |> then(&if status in [:unread, "unread"], do: Map.put(&1, "status", "unread"), else: &1)
      |> then(&if page > 1, do: Map.put(&1, "page", to_string(page)), else: &1)

    base = Routes.path("/notifications")

    if params == %{} do
      base
    else
      base <> "?" <> URI.encode_query(params)
    end
  end

  # Exposed to the template.
  @doc false
  def render_notification(notification), do: Render.render(notification)

  @doc false
  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  def relative_time(_), do: ""
end
