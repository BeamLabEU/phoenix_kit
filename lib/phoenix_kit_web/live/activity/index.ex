defmodule PhoenixKitWeb.Live.Activity.Index do
  @moduledoc """
  Admin LiveView for the activity feed.

  Shows a real-time stream of business-level actions across the platform
  with filtering by action type, user, resource type, and date range.
  """

  use PhoenixKitWeb, :live_view

  # Imported per-LiveView rather than from `PhoenixKitWeb, :live_view`: a host
  # app that defines its own `row_link/1` would get an ambiguous import the
  # moment core wired this one in project-wide.
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKitWeb.Components.Core.ActivityList

  alias PhoenixKit.Activity
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Values

  # Per-admin grid/list preference for the activity table, persisted in the
  # current user's custom_fields (mirrors the users table view toggle).
  @view_mode_key "activity_view_mode"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "dashboard") do
      if connected?(socket) do
        PubSubManager.subscribe(Activity.pubsub_topic())
      end

      project_title = Settings.get_project_title()

      # The shared audit log is administrators-only: a full-access operator
      # (Admin/Owner, or any role holding every grantable permission) sees the
      # whole platform's activity; every other dashboard-holder is scoped to
      # their OWN actions — enforced here (not just in the UI) so it also holds
      # for the direct `?actor`-style URL and the per-resource deep link.
      full_access? = Activity.full_log_access?(scope)

      socket =
        socket
        |> assign(:page_title, gettext("Activity"))
        |> assign(:project_title, project_title)
        |> assign(:full_log_access?, full_access?)
        |> assign(:scoped_actor_uuid, scoped_actor_uuid(full_access?, scope))
        |> assign(:modules, Activity.list_modules())
        |> assign(:modes, Activity.list_modes())
        |> assign(:action_types, Activity.list_action_types())
        |> assign(:resource_types, Activity.list_resource_types())
        |> assign(:view_mode, load_user_view_mode(socket.assigns[:phoenix_kit_current_user]))
        # handle_params/3 always follows mount and loads with the URL's
        # filters — loading here too ran the query twice per mount, the first
        # time with defaults that a deep link immediately discards.
        |> assign_filter_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Access denied"))
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
      |> maybe_put("module", filter_params["module"])
      |> maybe_put("mode", filter_params["mode"])
      |> maybe_put("action", filter_params["action"])
      |> maybe_put("resource_type", filter_params["resource_type"])
      # No form input for resource_uuid — it's a URL-driven scope (e.g. a
      # "view this resource's activity" deep link); preserve it across filter
      # changes so tweaking module/action doesn't drop the resource scope.
      |> maybe_put("resource_uuid", socket.assigns.filter_resource_uuid)

    query = URI.encode_query(new_params)
    {:noreply, push_patch(socket, to: Routes.path("/admin/activity?#{query}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/activity"))}
  end

  @impl true
  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ["card", "table"] do
    user = persist_user_view_mode(socket.assigns[:phoenix_kit_current_user], mode)

    {:noreply,
     socket
     |> assign(:phoenix_kit_current_user, user)
     |> assign(:view_mode, mode)}
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
    |> assign(:filter_module, nil)
    |> assign(:filter_mode, nil)
    |> assign(:filter_action, nil)
    |> assign(:filter_resource_type, nil)
    |> assign(:filter_resource_uuid, nil)
  end

  defp apply_params(socket, params) do
    socket
    |> assign(:page, parse_int(params["page"], 1))
    |> assign(:filter_module, Values.blank_to_nil(params["module"]))
    |> assign(:filter_mode, Values.blank_to_nil(params["mode"]))
    |> assign(:filter_action, Values.blank_to_nil(params["action"]))
    |> assign(:filter_resource_type, Values.blank_to_nil(params["resource_type"]))
    |> assign(:filter_resource_uuid, Values.blank_to_nil(params["resource_uuid"]))
  end

  defp load_activities(socket) do
    result =
      Activity.list(
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        module: socket.assigns.filter_module,
        mode: socket.assigns.filter_mode,
        action: socket.assigns.filter_action,
        resource_type: socket.assigns.filter_resource_type,
        resource_uuid: socket.assigns.filter_resource_uuid,
        # nil for a full-access operator (all actors); the current user's uuid
        # otherwise — a hard server-side scope to own actions.
        actor_uuid: socket.assigns.scoped_actor_uuid,
        preload: [:actor, :target]
      )

    resource_users = Activity.resolve_resource_users(result.entries)
    resource_links = resolve_links(result.entries)

    socket
    |> assign(:entries, result.entries)
    |> assign(:resource_users, resource_users)
    |> assign(:resource_links, resource_links)
    |> assign(:total, result.total)
    |> assign(:total_pages, result.total_pages)
  end

  # Resolve deep-links for both each entry's resource AND its actor/target (both
  # users). Actor/target are added as synthetic `"user"` items so the resulting
  # map is keyed by `{resource_type, uuid}` for all three — the template reads
  # `{"user", actor_uuid}` / `{"user", target_uuid}` to link the who-did/who-for.
  defp resolve_links(entries) do
    user_items =
      entries
      |> Enum.flat_map(fn e -> [e.actor_uuid, e.target_uuid] end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(&%{resource_type: "user", resource_uuid: &1})

    PhoenixKit.ResourceLinks.resolve(entries ++ user_items)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Per-user table/card preference, defaulting to "table". Mirrors the users
  # table; persisted in the current user's custom_fields.
  defp load_user_view_mode(%User{} = user) do
    case Auth.get_user_field(user, @view_mode_key) do
      mode when mode in ["card", "table"] -> mode
      _ -> "table"
    end
  end

  defp load_user_view_mode(_), do: "table"

  defp persist_user_view_mode(%{uuid: uuid} = user, mode) when is_binary(uuid) do
    fresh = Auth.get_user(uuid) || user
    merged = Map.put(fresh.custom_fields || %{}, @view_mode_key, mode)

    # Internal view preference: skip the custom-field-definition registration
    # (so it never surfaces in the column customizer) and the profile-update
    # broadcast (so toggling the view doesn't reload the users list for every
    # admin). Mirrors the users table.
    case Auth.update_user_custom_fields(fresh, merged,
           ensure_definitions: false,
           broadcast: false
         ) do
      {:ok, updated} -> updated
      {:error, _} -> user
    end
  end

  defp persist_user_view_mode(user, _mode), do: user

  # Build a filtered activity path, merging the current filters with `overrides`
  # (a keyword list like `[module: "posts"]`; pass `""` to clear a filter). Used
  # by the toolbar filter dropdowns so picking one filter preserves the others.
  defp filter_path(assigns, overrides) do
    query =
      %{
        "module" => assigns[:filter_module],
        "mode" => assigns[:filter_mode],
        "action" => assigns[:filter_action],
        "resource_type" => assigns[:filter_resource_type],
        # Preserve the per-resource deep-link scope (#599) when picking a filter.
        "resource_uuid" => assigns[:filter_resource_uuid]
      }
      |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> URI.encode_query()

    Routes.path("/admin/activity" <> if(query == "", do: "", else: "?#{query}"))
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> max(n, 1)
      :error -> default
    end
  end

  defp action_badge_color(action), do: Activity.action_badge_color(action)
  defp mode_badge_color(mode), do: Activity.mode_badge_color(mode)

  # Which actor the list is pinned to: nil (unrestricted) for a full-access
  # operator, else the current user's own uuid. Pinning `actor_uuid` is what
  # makes "own" mean AUTHORED-BY — the same definition as Activity.own_entry?/2
  # that the single-entry page enforces; a record merely targeting the user is
  # deliberately not shown. Fail closed — a non-full scope with no resolvable
  # user sees nothing, never everything.
  defp scoped_actor_uuid(true, _scope), do: nil
  defp scoped_actor_uuid(false, %Scope{user: %User{uuid: uuid}}) when is_binary(uuid), do: uuid
  defp scoped_actor_uuid(false, _scope), do: Ecto.UUID.generate()

  # True when any of the four Activity filters is set. Drives both the
  # toolbar Clear-filters button and the filtered empty-state message.
  defp any_filter_active?(assigns) do
    [
      assigns.filter_module,
      assigns.filter_mode,
      assigns.filter_action,
      assigns.filter_resource_type
    ]
    |> Enum.any?(&(&1 not in [nil, ""]))
  end

  # The Details column's summary is shared with every other list of activity
  # (`ActivityList`).
  defp summarize_details(metadata), do: ActivityList.summarize_details(metadata)
end
