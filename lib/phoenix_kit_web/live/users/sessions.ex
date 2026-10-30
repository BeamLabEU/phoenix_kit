defmodule PhoenixKitWeb.Live.Users.Sessions do
  @moduledoc """
  Live component for managing active user sessions in the PhoenixKit admin panel.

  This module provides functionality to:
  - View all active sessions across the system
  - See session details including user info, creation time, and age
  - Revoke individual sessions
  - Revoke all sessions for a specific user
  - View session statistics

  Only accessible to users with Owner or Admin roles.
  """
  use PhoenixKitWeb, :live_view

  # Search, filter and page live in the query string, so a filtered list is a
  # real URL: shareable, reload-proof, and Back returns to the previous query
  # instead of leaving the page. `filter_user_status` defaults to "all", which
  # is therefore what gets omitted from the URL.
  use PhoenixKitWeb.Live.UrlState,
    params: [
      search_query: [default: "", url_key: "q"],
      filter_user_status: [default: "all", url_key: "status"],
      # Deep-linked from the dashboard's three session cards. Without it,
      # "Today's Sessions" and "Expired Sessions" had no report at all — and
      # linking them at the active list would have shown a set that does not
      # contain what the card counted.
      filter_scope: [
        default: :active,
        cast: :atom,
        in: [:active, :today, :expired],
        url_key: "scope"
      ],
      page: [default: 1, cast: :integer, min: 1],
      # Rows per page, picked with <.page_size_selector>. Allowlisted rather
      # than bounded: an arbitrary integer out of the URL is a LIMIT clause.
      per_page: [default: 20, cast: :integer, in: [10, 20, 25, 50, 100]]
    ]

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Sessions}
  alias PhoenixKit.Users.LoginAttempts
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # The page is "what is happening to sign-ins right now", so the failed-attempt
  # panel matches: a day, not the 90-day retention.
  @failed_window_hours 24

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Subscribe to session events for real-time updates
    if connected?(socket) do
      Events.subscribe_to_sessions()
    end

    # Get project title from settings
    project_title = Settings.get_project_title()

    # :page, :per_page, :search_query and :filter_user_status are assigned
    # from the query string by UrlState before mount/3 runs — re-assigning
    # them here would overwrite a shared link's state with the defaults.
    socket =
      socket
      |> assign(:page_title, gettext("Session Management"))
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:show_revoke_modal, false)
      |> assign(:selected_session, nil)
      |> assign(:revoke_type, nil)
      |> load_stats()

    {:ok, socket}
  end

  # The list is loaded here rather than in mount/3: UrlState calls this after
  # mount and on every change to the query string, so one code path serves the
  # first render, a shared link, and the Back button alike.
  #
  # Deliberately not annotated with @impl — a single @impl anywhere in a module
  # makes Elixir demand it on every other callback too, and this LiveView's
  # mount/handle_event/handle_params/handle_info carry none.
  def handle_url_state(_state, socket), do: load_sessions(socket)

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # `replace: true` — the box is debounced, so a typed-out query would
  # otherwise leave one history entry per pause and Back would walk the search
  # string backwards instead of leaving the page.
  def handle_event("search", %{"search" => search_query}, socket) do
    {:noreply, push_url_state(socket, [search_query: search_query], replace: true)}
  end

  def handle_event("filter_by_user_status", %{"status" => status}, socket) do
    {:noreply, push_url_state(socket, filter_user_status: status)}
  end

  # Hardcoded map rather than `String.to_existing_atom/1`: the value arrives
  # from a form and must never widen the atom table. Anything unrecognised
  # falls back to the default scope, which is also what `UrlState`'s `in:`
  # guard does for a hand-edited query string.
  def handle_event("filter_by_scope", %{"scope" => scope}, socket) do
    scope =
      case scope do
        "today" -> :today
        "expired" -> :expired
        _ -> :active
      end

    {:noreply, push_url_state(socket, filter_scope: scope)}
  end

  # `push_url_state` resets the page along with the size: page 7 of 20 rows
  # is not page 7 of 100.
  def handle_event("change_per_page", %{"per_page" => per_page}, socket) do
    case Integer.parse(per_page) do
      {per_page, ""} -> {:noreply, push_url_state(socket, per_page: per_page)}
      _ -> {:noreply, socket}
    end
  end

  # Ending someone's sessions takes the rank rule of changing their status
  # (`Sessions.can_revoke_sessions_of?/2`): checked when the dialog opens, and
  # again by the context when it is confirmed.
  def handle_event("show_revoke_session", %{"token_uuid" => token_uuid}, socket) do
    session_info = Sessions.get_session_info(token_uuid)

    cond do
      session_info == nil ->
        {:noreply, put_flash(socket, :error, gettext("Session not found or already expired"))}

      not may_revoke?(socket, Auth.get_user(session_info.user_uuid)) ->
        {:noreply, put_flash(socket, :error, revoke_refused_message())}

      true ->
        socket =
          socket
          |> assign(:selected_session, session_info)
          |> assign(:revoke_type, :single)
          |> assign(:show_revoke_modal, true)

        {:noreply, socket}
    end
  end

  def handle_event("show_revoke_user_sessions", %{"user_uuid" => user_uuid}, socket) do
    user = Auth.get_user!(user_uuid)

    if may_revoke?(socket, user) do
      user_sessions = Sessions.list_user_sessions(user)

      socket =
        socket
        |> assign(:selected_user, user)
        |> assign(:user_sessions_count, length(user_sessions))
        |> assign(:revoke_type, :user_all)
        |> assign(:show_revoke_modal, true)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, revoke_refused_message())}
    end
  end

  def handle_event("hide_revoke_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_revoke_modal, false)
      |> assign(:selected_session, nil)
      |> assign(:selected_user, nil)
      |> assign(:revoke_type, nil)

    {:noreply, socket}
  end

  def handle_event("confirm_revoke_session", _params, socket) do
    case socket.assigns.revoke_type do
      :single ->
        handle_single_session_revoke(socket)

      :user_all ->
        handle_user_sessions_revoke(socket)

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Invalid revoke operation"))}
    end
  end

  def handle_event("refresh_sessions", _params, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()
      |> put_flash(:info, gettext("Sessions refreshed successfully"))

    {:noreply, socket}
  end

  defp handle_single_session_revoke(socket) do
    session = socket.assigns.selected_session

    case Sessions.revoke_session(session.token_uuid, actor: actor(socket)) do
      {:error, :not_permitted} ->
        {:noreply,
         socket
         |> put_flash(:error, revoke_refused_message())
         |> assign(:show_revoke_modal, false)
         |> assign(:selected_session, nil)
         |> assign(:revoke_type, nil)}

      :ok ->
        socket =
          socket
          |> put_flash(:info, gettext("Session revoked successfully"))
          |> assign(:show_revoke_modal, false)
          |> assign(:selected_session, nil)
          |> assign(:revoke_type, nil)
          |> load_sessions()
          |> load_stats()

        {:noreply, socket}

      {:error, :not_found} ->
        socket =
          socket
          |> put_flash(:error, gettext("Session not found or already expired"))
          |> assign(:show_revoke_modal, false)
          |> load_sessions()

        {:noreply, socket}
    end
  end

  defp handle_user_sessions_revoke(socket) do
    user = socket.assigns.selected_user

    case Sessions.revoke_user_sessions(user, actor: actor(socket)) do
      {:error, :not_permitted} ->
        {:noreply,
         socket
         |> put_flash(:error, revoke_refused_message())
         |> assign(:show_revoke_modal, false)
         |> assign(:selected_user, nil)
         |> assign(:revoke_type, nil)}

      revoked_count ->
        user_sessions_revoked(socket, user, revoked_count)
    end
  end

  defp user_sessions_revoked(socket, user, revoked_count) do
    socket =
      socket
      |> put_flash(
        :info,
        ngettext(
          "1 session revoked for %{email}",
          "%{count} sessions revoked for %{email}",
          revoked_count,
          email: Auth.User.delivery_email(user)
        )
      )
      |> assign(:show_revoke_modal, false)
      |> assign(:selected_user, nil)
      |> assign(:revoke_type, nil)
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  defp actor(socket), do: socket.assigns.phoenix_kit_current_user

  defp may_revoke?(socket, target), do: Sessions.can_revoke_sessions_of?(target, actor(socket))

  defp revoke_refused_message,
    do: gettext("You are not allowed to end this person's sessions")

  # Filtering and paging happen in SQL: with the page size now user-chosen,
  # loading every session and slicing in memory would scale with the table
  # rather than with the page.
  defp load_sessions(socket) do
    %{sessions: sessions, total_count: total_count, total_pages: total_pages, page: page} =
      Sessions.list_sessions_paginated(
        scope: socket.assigns.filter_scope,
        search: socket.assigns.search_query,
        user_status: socket.assigns.filter_user_status,
        page: socket.assigns.page,
        per_page: socket.assigns.per_page
      )

    socket
    |> assign(:sessions, sessions)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:page, page)
  end

  defp load_stats(socket) do
    stats = Sessions.get_session_stats()
    since = DateTime.add(DateTime.utc_now(), -@failed_window_hours * 3600, :second)

    socket
    |> assign(:stats, stats)
    |> assign(:failed_stats, LoginAttempts.stats(since))
    |> assign(:failed_attempts, LoginAttempts.top_since(since, limit: 10))
    |> assign(:failed_window_hours, @failed_window_hours)
  end

  ## Live Event Handlers for Sessions

  def handle_info({:session_created, _user, _token_info}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:session_revoked, _token_uuid}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_sessions_revoked, _user_uuid, _count}, socket) do
    socket =
      socket
      |> load_sessions()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:sessions_stats_updated, stats}, socket) do
    socket =
      socket
      |> assign(:stats, stats)

    {:noreply, socket}
  end

  def outcome_label("invalid_credentials"), do: gettext("Wrong password")
  def outcome_label("rate_limited"), do: gettext("Rate limited")
  def outcome_label("inactive"), do: gettext("Correct password, deactivated")
  def outcome_label(other), do: other

  @doc """
  Readable "Browser · OS" for a session row, or an "Unknown device" fallback
  for sessions created before the device name was captured (pre-V148).
  """
  def device_name(session) do
    [session.browser, session.os]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
    |> case do
      "" -> gettext("Unknown device")
      label -> label
    end
  end
end
