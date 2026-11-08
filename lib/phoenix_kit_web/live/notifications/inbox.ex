defmodule PhoenixKitWeb.Live.Notifications.Inbox do
  @moduledoc """
  "My Notifications" — the current user's personal notification inbox.

  Shows the full history of notifications addressed to the logged-in user
  (unlike the bell dropdown, which only shows the recent unseen ones), with
  per-row mark-seen / dismiss and a mark-all-seen action. Updates live over
  the user's PubSub topic, so a notification created elsewhere (another tab,
  the bell, another actor) appears without a refresh.

  Access is gated by the base `notifications` permission (the admin
  `live_session` `on_mount` + `@admin_view_permissions`). The recipient is
  ALWAYS the scope's user — never taken from params/URL/PubSub — so one user
  can only ever see and act on their own notifications.
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
    user_uuid = Scope.user_uuid(socket.assigns[:phoenix_kit_current_scope])

    if connected?(socket) and is_binary(user_uuid) do
      Events.subscribe(user_uuid)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("My Notifications"))
     |> assign(:project_title, Settings.get_project_title())
     # Notifications are private per person, so the view/filter state lives in
     # LiveView assigns, not the URL — nothing here is worth sharing or
     # deep-linking. `url_path` is the page's own path (for nav highlighting).
     |> assign(:url_path, Routes.path("/admin/notifications"))
     |> assign(:user_uuid, user_uuid)
     |> assign(:per_page, @per_page)
     |> assign(:view, :inbox)
     |> assign(:status, :all)
     |> assign(:limit, @per_page)
     |> load()}
  end

  @impl true
  def handle_event("mark_seen", %{"uuid" => uuid}, socket) do
    Notifications.mark_seen(socket.assigns.user_uuid, uuid)
    {:noreply, load(socket)}
  end

  def handle_event("dismiss", %{"uuid" => uuid}, socket) do
    Notifications.dismiss(socket.assigns.user_uuid, uuid)
    {:noreply, load(socket)}
  end

  def handle_event("mark_all_seen", _params, socket) do
    Notifications.mark_all_seen(socket.assigns.user_uuid)
    {:noreply, load(socket)}
  end

  # "Dismissed" filter toggle: off → active inbox, on → the dismissed ("trash")
  # list. Reset the unread filter when leaving the inbox (it doesn't apply there).
  def handle_event("toggle_dismissed", _params, socket) do
    view = if socket.assigns.view == :dismissed, do: :inbox, else: :dismissed
    {:noreply, socket |> assign(:view, view) |> assign(:status, :all) |> reset_limit() |> load()}
  end

  # "Unread" filter toggle: off → all, on → unread only.
  def handle_event("toggle_unread", _params, socket) do
    status = if socket.assigns.status == :unread, do: :all, else: :unread
    {:noreply, socket |> assign(:status, status) |> reset_limit() |> load()}
  end

  # In-memory "load more": grow the fetch window (no URL, no page params).
  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> assign(:limit, socket.assigns.limit + socket.assigns.per_page) |> load()}
  end

  # Restore (un-dismiss) a notification — the soft-delete "restore" action.
  def handle_event("restore", %{"uuid" => uuid}, socket) do
    Notifications.restore(socket.assigns.user_uuid, uuid)
    {:noreply, load(socket)}
  end

  # Clicking a notification's title marks it seen and navigates to its resource
  # link (mirrors the bell). A link-less notification just clears its unread
  # state and stays on the page.
  def handle_event("open_notification", %{"uuid" => uuid}, socket) do
    case Notifications.mark_seen(socket.assigns.user_uuid, uuid) do
      {:ok, notification} ->
        case Render.render(notification, socket.assigns[:current_locale]).link do
          nil -> {:noreply, load(socket)}
          link -> {:noreply, push_navigate(socket, to: link)}
        end

      _ ->
        {:noreply, load(socket)}
    end
  end

  # Live updates: any change to this user's notifications (own action, another
  # tab, the bell, or a new one arriving) reloads the current page.
  # `:notification_updated` is what `upsert_inapp/3` broadcasts when it
  # collapses a repeat event onto an existing row — without it here, an open
  # inbox kept the stale text and position while the bell refreshed.
  @impl true
  def handle_info({event, _payload}, socket)
      when event in [
             :notification_created,
             :notification_updated,
             :notification_seen,
             :notification_dismissed,
             :notifications_bulk_updated
           ] do
    {:noreply, load(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Internals ────────────────────────────────────────────────────────

  # Single read per refresh (list + unread count), no N+1 — list_for_user/2
  # already preloads activity + actor.
  # Fetch the first `limit` rows (grows via "load more") — no offset paging, so
  # a live update or filter change always re-reads a coherent window from the top.
  defp load(%{assigns: %{user_uuid: user_uuid}} = socket) when is_binary(user_uuid) do
    dismissed = if socket.assigns.view == :dismissed, do: :only, else: :exclude
    # The unread filter only applies to the active inbox.
    status = if socket.assigns.view == :dismissed, do: :all, else: socket.assigns.status

    {rows, total} =
      Notifications.list_for_user(user_uuid,
        page: 1,
        per_page: socket.assigns.limit,
        status: status,
        dismissed: dismissed
      )

    socket
    |> assign(:notifications, rows)
    |> assign(:total, total)
    |> assign(:unread_count, Notifications.count_unread(user_uuid))
  end

  defp load(socket) do
    socket
    |> assign(:notifications, [])
    |> assign(:total, 0)
    |> assign(:unread_count, 0)
  end

  defp reset_limit(socket), do: assign(socket, :limit, socket.assigns.per_page)

  # Group the rows into contiguous day buckets so a long history stays
  # scannable. chunk_by preserves order without a re-sort.
  #
  # The chunk key is `{unread?, day}`, not the day alone. `list_for_user/2`
  # returns unseen first and only then newest-first, so the day sequence
  # restarts at the seen block — chunking on the day alone emits "Today" once
  # for the unread run and again for the read one, two identical headers with
  # a week of history between them, reading as a bug. Chunking on both keeps
  # every header unique and puts the outstanding work in its own labelled run
  # at the top, which is the whole point of the order.
  defp grouped(notifications) do
    today = Date.utc_today()

    notifications
    |> Enum.chunk_by(&{is_nil(&1.seen_at), bucket_key(&1, today)})
    |> Enum.map(fn [first | _] = chunk -> {section_label(first, today), chunk} end)
  end

  defp section_label(%{seen_at: nil} = notification, today) do
    gettext("Unread · %{day}", day: bucket_label(bucket_key(notification, today)))
  end

  defp section_label(notification, today), do: bucket_label(bucket_key(notification, today))

  defp bucket_key(%{inserted_at: %DateTime{} = dt}, today) do
    case Date.diff(today, DateTime.to_date(dt)) do
      d when d <= 0 -> :today
      1 -> :yesterday
      d when d <= 6 -> :this_week
      _ -> :earlier
    end
  end

  defp bucket_key(_, _), do: :earlier

  defp bucket_label(:today), do: gettext("Today")
  defp bucket_label(:yesterday), do: gettext("Yesterday")
  defp bucket_label(:this_week), do: gettext("Earlier this week")
  defp bucket_label(:earlier), do: gettext("Earlier")

  # View/status-aware empty-state copy.
  defp empty_title(:dismissed, _), do: gettext("No dismissed notifications")
  defp empty_title(_, :unread), do: gettext("No unread notifications")
  defp empty_title(_, _), do: gettext("You're all caught up")

  defp empty_subtitle(:dismissed, _), do: gettext("Notifications you dismiss will appear here.")
  defp empty_subtitle(_, :unread), do: gettext("You've read everything here.")
  defp empty_subtitle(_, _), do: gettext("Notifications you receive will show up here.")

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={gettext("My Notifications")}
      page_subtitle={gettext("Notifications addressed to you")}
      current_path={@url_path}
      project_title={@project_title}
      current_locale={assigns[:current_locale]}
    >
      <div class="p-6 max-w-2xl mx-auto">
        <%!-- Toolbar: mark-all-read (left) · filter chips (right). We're already
             in the inbox, so the chips are on/off filters, not navigation tabs.
             Off = ghost/outlined pill, on = filled. The Unread filter doesn't
             apply to the dismissed ("trash") list, so it stays visible but
             disabled there rather than vanishing. --%>
        <div class="flex flex-wrap items-center gap-2 mb-5">
          <%= if @view == :inbox and @unread_count > 0 do %>
            <button type="button" phx-click="mark_all_seen" class="btn btn-ghost btn-sm gap-1.5">
              <.icon name="hero-check" class="w-4 h-4" /> {gettext("Mark all read")}
            </button>
          <% end %>

          <div class="flex items-center gap-2 ml-auto">
            <button
              type="button"
              phx-click="toggle_unread"
              disabled={@view == :dismissed}
              aria-pressed={@status == :unread}
              class={[
                "btn btn-sm rounded-full gap-1.5",
                if(@status == :unread, do: "btn-primary", else: "btn-ghost border border-base-300")
              ]}
            >
              {gettext("Unread")}
              <%= if @unread_count > 0 do %>
                <span class={["badge badge-xs", if(@status == :unread, do: "badge-ghost")]}>
                  {@unread_count}
                </span>
              <% end %>
            </button>

            <button
              type="button"
              phx-click="toggle_dismissed"
              aria-pressed={@view == :dismissed}
              class={[
                "btn btn-sm rounded-full gap-1.5",
                if(@view == :dismissed, do: "btn-primary", else: "btn-ghost border border-base-300")
              ]}
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {gettext("Dismissed")}
            </button>
          </div>
        </div>

        <%= if @notifications == [] do %>
          <div class="text-center py-20">
            <div class="w-14 h-14 rounded-full bg-base-200 grid place-items-center mx-auto mb-4">
              <.icon name="hero-bell-slash" class="w-6 h-6 text-base-content/40" />
            </div>
            <p class="font-medium">{empty_title(@view, @status)}</p>
            <p class="text-sm text-base-content/50 mt-1">{empty_subtitle(@view, @status)}</p>
          </div>
        <% else %>
          <div class="space-y-6">
            <%= for {label, group} <- grouped(@notifications) do %>
              <section>
                <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-2 px-1">
                  {label}
                </h2>
                <div class="card bg-base-100 shadow-sm border border-base-200 overflow-hidden">
                  <ul class="divide-y divide-base-200 m-0 p-0">
                    <%= for n <- group do %>
                      <% view = Render.render(n, assigns[:current_locale]) %>
                      <li class={[
                        "group/row flex items-start gap-3 px-4 py-3.5 transition-colors hover:bg-base-200/40",
                        is_nil(n.seen_at) && "bg-primary/[0.04]"
                      ]}>
                        <%!-- Type icon in a chip, tinted while unread --%>
                        <div class={[
                          "shrink-0 w-9 h-9 rounded-full grid place-items-center",
                          if(is_nil(n.seen_at),
                            do: "bg-primary/15 text-primary",
                            else: "bg-base-200 text-base-content/50"
                          )
                        ]}>
                          <.icon name={view.icon} class="w-5 h-5" />
                        </div>

                        <div class="flex-1 min-w-0 pt-0.5">
                          <button
                            type="button"
                            phx-click="open_notification"
                            phx-value-uuid={n.uuid}
                            class={[
                              "text-sm leading-snug text-left hover:underline focus:underline outline-none cursor-pointer",
                              is_nil(n.seen_at) && "font-semibold"
                            ]}
                          >
                            {view.text}
                          </button>
                          <p class="text-xs text-base-content/50 mt-1">
                            {PhoenixKit.Utils.Date.ago(n.inserted_at)}
                          </p>
                        </div>

                        <%!-- Actions: subtle by default, full on row hover/focus.
                             Stays visible enough to tap on touch. --%>
                        <div class="shrink-0 flex items-center gap-0.5 opacity-60 group-hover/row:opacity-100 focus-within:opacity-100 transition-opacity">
                          <%= if @view == :dismissed do %>
                            <button
                              type="button"
                              phx-click="restore"
                              phx-value-uuid={n.uuid}
                              class="btn btn-ghost btn-xs btn-square"
                              title={gettext("Restore")}
                            >
                              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                            </button>
                          <% else %>
                            <%= if is_nil(n.seen_at) do %>
                              <button
                                type="button"
                                phx-click="mark_seen"
                                phx-value-uuid={n.uuid}
                                class="btn btn-ghost btn-xs btn-square"
                                title={gettext("Mark read")}
                              >
                                <.icon name="hero-check" class="w-4 h-4" />
                              </button>
                            <% end %>
                            <button
                              type="button"
                              phx-click="dismiss"
                              phx-value-uuid={n.uuid}
                              class="btn btn-ghost btn-xs btn-square"
                              title={gettext("Dismiss")}
                            >
                              <.icon name="hero-x-mark" class="w-4 h-4" />
                            </button>
                          <% end %>
                        </div>
                      </li>
                    <% end %>
                  </ul>
                </div>
              </section>
            <% end %>
          </div>

          <%= if length(@notifications) < @total do %>
            <div class="mt-4 text-center">
              <button type="button" phx-click="load_more" class="btn btn-ghost btn-sm">
                {gettext("Load more")}
              </button>
            </div>
          <% end %>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
