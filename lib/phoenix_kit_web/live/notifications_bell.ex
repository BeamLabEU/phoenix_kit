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

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.Events
  alias PhoenixKit.Notifications.Render
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  def mount(_params, %{"user_uuid" => user_uuid} = session, socket) when is_binary(user_uuid) do
    if connected?(socket), do: Events.subscribe(user_uuid)

    # The page's language, threaded from the layout: the bell is a nested
    # LiveView, so its own process has no Gettext locale until it installs one,
    # and its links need the locale for their prefix. The layout puts the
    # language in the bell's id, so a language switch mounts a new bell.
    put_locale(session["dialect"] || session["locale"])

    {:ok,
     socket
     |> assign(:user_uuid, user_uuid)
     |> assign(:locale, session["locale"])
     # Whether the recipient may open `/admin/notifications`, decided by the
     # embedder (`LayoutWrapper`) through the destination's own admin-view gate
     # — the bell is a nested LiveView with no scope of its own. Fails CLOSED so
     # an embedding that doesn't thread it never offers a rejecting link.
     |> assign(:can_open_inbox, session["can_open_inbox"] == true)
     |> refresh()}
  end

  # Graceful fallback for embeddings without a user session — renders an
  # empty element so the layout doesn't crash for anonymous visitors.
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:user_uuid, nil) |> assign(:locale, nil)}
  end

  # ── Events ─────────────────────────────────────────────────────────

  def handle_event("open_notification", %{"uuid" => uuid}, socket) do
    user_uuid = socket.assigns.user_uuid

    case Notifications.mark_seen(user_uuid, uuid) do
      {:ok, notification} ->
        # Effective target: the notification's own link, else the host's
        # configured catch-all default. Both are nil → no navigation (the row
        # is informational; the click still cleared its unread state above).
        link = Render.render(notification, socket.assigns.locale).link
        target = link || socket.assigns.default_link

        case target do
          nil ->
            warn_unlinked(notification)
            {:noreply, refresh(socket)}

          target ->
            {:noreply, push_navigate(socket, to: target)}
        end

      _ ->
        {:noreply, refresh(socket)}
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
             :notification_updated,
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
      <label tabindex="0" class="btn btn-ghost btn-circle" title={gettext("Notifications")}>
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
            <span class="font-semibold">{gettext("Notifications")}</span>
            <%= if @unread_count > 0 do %>
              <button
                type="button"
                phx-click="mark_all_seen"
                class="btn btn-ghost btn-xs"
              >
                {gettext("Mark all seen")}
              </button>
            <% end %>
          </div>

          <%= if @recent == [] do %>
            <div class="px-4 py-8 text-center text-sm text-base-content/60">
              {gettext("You're all caught up.")}
            </div>
          <% else %>
            <%!-- Plain vertical flex list, not daisyUI `menu`: `menu` sets
                 `flex-wrap: wrap`, so a tall list past max-h-96 wraps into extra
                 columns (horizontal overflow) instead of scrolling. --%>
            <ul class="flex flex-col flex-nowrap max-h-96 overflow-y-auto p-0 m-0">
              <%= for n <- @recent do %>
                <% view = Render.render(n, @locale) %>
                <% has_target = (view.link || @default_link) != nil %>
                <li class={[
                  "border-b border-base-200 last:border-b-0",
                  is_nil(n.seen_at) && "bg-primary/5"
                ]}>
                  <%!-- Always a button (clicking marks the notification seen);
                       pointer cursor only when there's somewhere to navigate, so
                       a link-less notification reads as informational, not broken. --%>
                  <button
                    type="button"
                    phx-click="open_notification"
                    phx-value-uuid={n.uuid}
                    class={[
                      "flex items-start gap-3 w-full px-4 py-3 hover:bg-base-200 text-left",
                      if(has_target, do: "cursor-pointer", else: "cursor-default")
                    ]}
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
                        {PhoenixKit.Utils.Date.ago(n.inserted_at)}
                      </p>
                    </div>
                  </button>
                </li>
              <% end %>
            </ul>
          <% end %>

          <%!-- Footer: the full inbox is one click away whenever the recipient
               can actually open it, even when the recent list is empty. Built
               via Routes.path with the recipient's own locale (like the
               notification links above). The whole bordered strip is dropped
               together with the link — a footer rule with nothing under it
               reads as a rendering bug. --%>
          <div :if={@can_open_inbox} class="border-t border-base-200 p-2">
            <.link
              navigate={Routes.path("/admin/notifications", locale: @locale)}
              class="btn btn-ghost btn-sm btn-block"
            >
              {gettext("View all")}
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
    |> assign(:default_link, default_link(socket.assigns[:locale]))
  end

  # Catch-all destination for notifications without a link of their own, from
  # the `notification_default_link` setting. Defaults to `/admin` — the one page
  # core declares unconditionally AND admits every authenticated visitor to
  # (`PhoenixKitWeb.Users.Auth.landing_view?/1` exempts the index from the
  # admin-area gate, so a recipient holding no permissions is greeted rather
  # than bounced). Blank → nil (non-navigating). Built through Routes.path so it
  # carries the URL prefix + the recipient's locale.
  #
  # It used to default to `/dashboard`. That page is DEPRECATED
  # (`PhoenixKit.Install.Deprecations.user_dashboard_warning/0`) and hosts can
  # compile it out with `user_dashboard_enabled: false`, so core must not steer
  # anyone there by default. Same reasoning as the terminal of
  # `PhoenixKit.Utils.Routes.safe_destination/2`.
  defp default_link(locale) do
    # Cache-backed read: refresh/1 runs on mount (twice) and on every notification
    # PubSub event, so this is a hot path — the uncached get_setting/2 would hit
    # the DB each time. The cache is invalidated when the setting is saved.
    case Settings.get_setting_cached("notification_default_link", "/admin")
         |> to_string()
         |> String.trim() do
      "" ->
        nil

      # Kept for hosts that saved the OLD default into the settings row while it
      # was still the prefilled value: /dashboard 404s when the user dashboard is
      # disabled, so fall back to no-op rather than send the user to a dead route.
      "/dashboard" ->
        if PhoenixKit.Config.user_dashboard_enabled?(),
          do: Routes.path("/dashboard", locale: locale),
          else: nil

      "/" <> _ = path ->
        Routes.path(path, locale: locale)

      _ ->
        nil
    end
  end

  # Dev nudge: when a clicked notification has neither its own link nor a
  # configured default, log how to wire it. Off unless the host opts in with
  # `config :phoenix_kit, warn_unlinked_notifications: true` — never noise in prod.
  defp warn_unlinked(notification) do
    if Application.get_env(:phoenix_kit, :warn_unlinked_notifications, false) do
      action = notification.activity && Map.get(notification.activity, :action)

      Logger.warning(
        "Notification #{inspect(action)} has no click-through link. Set a " <>
          "\"notification_link\" (built via PhoenixKit.Utils.Routes.path/1) in the activity " <>
          "metadata when logging it, or set the \"notification_default_link\" setting for a catch-all."
      )
    end
  end

  defp put_locale(locale) when is_binary(locale),
    do: UserAuth.put_gettext_locale(locale)

  defp put_locale(_none), do: :ok

  defp display_count(n) when n > 99, do: "99+"
  defp display_count(n), do: Integer.to_string(n)
end
