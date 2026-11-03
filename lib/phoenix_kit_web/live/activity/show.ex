defmodule PhoenixKitWeb.Live.Activity.Show do
  @moduledoc """
  Admin LiveView for viewing a single activity entry.

  Provides a shareable URL for individual activity entries with full detail.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Activity
  alias PhoenixKit.Modules.Storage.Libraries.MembershipHistory
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "dashboard") do
      entry = Activity.get_entry(uuid)

      # A non-administrator may only open their OWN entries. Treat someone
      # else's as not-found (same response as a missing uuid) so the detail
      # page never leaks another user's audit record via its direct URL.
      if is_nil(entry) or not can_view_entry?(scope, entry) do
        {:ok,
         socket
         |> put_flash(:error, gettext("Activity not found"))
         |> push_navigate(to: Routes.path("/admin/activity"))}
      else
        project_title = Settings.get_project_title()
        resource_user = resolve_resource_user(entry)

        # Resolve deep-links for the resource AND the actor/target (both users),
        # so the who-did-it / who-it's-for identities are clickable too.
        links =
          [entry]
          |> Enum.concat(user_items(entry))
          |> PhoenixKit.ResourceLinks.resolve()

        socket =
          socket
          |> assign(:page_title, gettext("Activity Detail"))
          |> assign(:project_title, project_title)
          |> assign(:entry, entry)
          |> then(fn socket ->
            {changes, rest} = Activity.split_changes(entry.metadata)

            socket
            |> assign(:changes, changes)
            |> assign(:rest_metadata, rest)
          end)
          |> assign(:resource_user, resource_user)
          |> assign(:resource_link, links[{entry.resource_type, entry.resource_uuid}])
          |> assign(:actor_link, links[{"user", entry.actor_uuid}])
          |> assign(:target_link, links[{"user", entry.target_uuid}])

        {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Access denied"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, url, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(url).path)}
  end

  # Synthetic `"user"` items for the actor + target uuids, so ResourceLinks can
  # resolve them alongside the entry's own resource in one pass.
  defp user_items(entry) do
    [entry.actor_uuid, entry.target_uuid]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.map(&%{resource_type: "user", resource_uuid: &1})
  end

  defp resolve_resource_user(entry) do
    if entry.resource_type == "user" && entry.resource_uuid do
      resource_users = Activity.resolve_resource_users([entry])
      Map.get(resource_users, entry.resource_uuid)
    else
      nil
    end
  end

  defp mode_badge_color(mode), do: Activity.mode_badge_color(mode)
  defp action_badge_color(action), do: Activity.action_badge_color(action)

  # Administrators — Admin or Owner (or any "*" superadmin role) — may open any
  # entry; everyone else only their own. Mirrors the list-scoping gate in
  # Activity.Index — keep the two in lock-step.
  defp can_view_entry?(scope, entry) do
    # "Own" == authored by this user (actor), NOT merely targeted at them —
    # see Activity.own_entry?/2, the single definition shared with the list.
    Activity.full_log_access?(scope) or
      (Activity.own_entry?(scope, entry) and
         MembershipHistory.visible_entry?(scope, entry))
  end
end
