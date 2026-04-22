defmodule PhoenixKitWeb.Live.NotificationsBell do
  @moduledoc """
  Nested LiveView that renders the notifications bell in the global layout.

  Embedded from `layout_wrapper.ex` via `live_render/3` with `sticky: true`
  so it keeps its socket across page navigations and its own PubSub
  subscription stays live. It owns its `handle_info` callbacks for
  `{:notification_created, _}` / `{:notification_seen, _}` /
  `{:notification_dismissed, _}` / `{:notifications_bulk_updated, _}`,
  refreshing the badge count and dropdown contents on each event.

  Not routable on its own — mount expects `user_uuid` in the nested session.
  """
  use Phoenix.LiveView, layout: false

  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.Events
  alias PhoenixKit.Notifications.Render
  alias PhoenixKit.Utils.Routes

  def mount(_params, %{"user_uuid" => user_uuid}, socket) when is_binary(user_uuid) do
    if connected?(socket), do: Events.subscribe(user_uuid)

    {:ok,
     socket
     |> assign(:user_uuid, user_uuid)
     |> refresh()}
  end

  # Graceful fallback for embeddings without a user session — renders an
  # empty element so the layout doesn't crash for anonymous visitors.
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :user_uuid, nil)}
  end

  # ── Events ─────────────────────────────────────────────────────────

  def handle_event("open_notification", %{"uuid" => uuid}, socket) do
    user_uuid = socket.assigns.user_uuid

    case Notifications.mark_seen(user_uuid, uuid) do
      {:ok, notification} ->
        target = Render.render(notification).link || Routes.path("/notifications")
        {:noreply, push_navigate(socket, to: target)}

      _ ->
        {:noreply, push_navigate(socket, to: Routes.path("/notifications"))}
    end
  end

  def handle_event("dismiss", %{"uuid" => uuid}, socket) do
    Notifications.dismiss(socket.assigns.user_uuid, uuid)
    {:noreply, refresh(socket)}
  end

  def handle_event("mark_all_seen", _params, socket) do
    Notifications.mark_all_seen(socket.assigns.user_uuid)
    {:noreply, refresh(socket)}
  end

  # ── PubSub ─────────────────────────────────────────────────────────

  def handle_info({event, _payload}, socket)
      when event in [
             :notification_created,
             :notification_seen,
             :notification_dismissed,
             :notifications_bulk_updated
           ] do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ─────────────────────────────────────────────────────────

  def render(%{user_uuid: nil} = assigns) do
    ~H"""
    <div></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <label tabindex="0" class="btn btn-ghost btn-circle" title="Notifications">
        <div class="indicator">
          <.icon name="hero-bell" class="w-5 h-5" />
          <%= if @unread_count > 0 do %>
            <span class="badge badge-xs badge-primary indicator-item">
              {display_count(@unread_count)}
            </span>
          <% end %>
        </div>
      </label>
      <div
        tabindex="0"
        class="dropdown-content z-[100] mt-3 w-80 max-w-[95vw] card card-compact bg-base-100 shadow-xl border border-base-200"
      >
        <div class="card-body p-0">
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-200">
            <span class="font-semibold">Notifications</span>
            <%= if @unread_count > 0 do %>
              <button
                type="button"
                phx-click="mark_all_seen"
                class="btn btn-ghost btn-xs"
              >
                Mark all seen
              </button>
            <% end %>
          </div>

          <%= if @recent == [] do %>
            <div class="px-4 py-8 text-center text-sm text-base-content/60">
              You're all caught up.
            </div>
          <% else %>
            <ul class="menu menu-sm max-h-96 overflow-y-auto p-0">
              <%= for n <- @recent do %>
                <% view = Render.render(n) %>
                <li class={[
                  "border-b border-base-200 last:border-b-0",
                  is_nil(n.seen_at) && "bg-primary/5"
                ]}>
                  <button
                    type="button"
                    phx-click="open_notification"
                    phx-value-uuid={n.uuid}
                    class="flex items-start gap-3 w-full px-4 py-3 hover:bg-base-200 text-left"
                  >
                    <.icon name={view.icon} class="w-5 h-5 mt-0.5 shrink-0 text-base-content/70" />
                    <div class="flex-1 min-w-0">
                      <p class={[
                        "text-sm",
                        is_nil(n.seen_at) && "font-semibold"
                      ]}>
                        {view.text}
                      </p>
                      <p class="text-xs text-base-content/50 mt-0.5">
                        {relative_time(n.inserted_at)}
                      </p>
                    </div>
                  </button>
                </li>
              <% end %>
            </ul>
          <% end %>

          <div class="border-t border-base-200">
            <.link
              navigate={Routes.path("/notifications")}
              class="block text-center text-sm py-2 hover:bg-base-200"
            >
              See all
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp refresh(socket) do
    user_uuid = socket.assigns.user_uuid

    socket
    |> assign(:unread_count, Notifications.count_unread(user_uuid))
    |> assign(:recent, Notifications.recent_for_user(user_uuid, 10))
  end

  defp display_count(n) when n > 99, do: "99+"
  defp display_count(n), do: Integer.to_string(n)

  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  defp relative_time(_), do: ""
end
