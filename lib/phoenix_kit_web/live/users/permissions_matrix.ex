defmodule PhoenixKitWeb.Live.Users.PermissionsMatrix do
  @moduledoc """
  Interactive permissions matrix view for PhoenixKit admin panel.

  Displays a matrix of roles vs module permission keys, showing which
  roles have access to which sections. Owner column shows "always" badge.
  Cells are clickable to toggle permissions directly.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_to_roles()
      Events.subscribe_to_permissions()
      Events.subscribe_to_modules()
    end

    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page_title, "Permissions Matrix")
      |> assign(:project_title, project_title)
      |> load_matrix()

    {:ok, socket}
  end

  # --- PubSub Handlers ---

  def handle_info({:role_created, _role}, socket) do
    {:noreply, load_matrix(socket)}
  end

  def handle_info({:role_updated, _role}, socket) do
    {:noreply, load_matrix(socket)}
  end

  def handle_info({:role_deleted, _role}, socket) do
    {:noreply, load_matrix(socket)}
  end

  def handle_info({:permission_granted, _role_id, _key}, socket) do
    {:noreply, refresh_matrix(socket)}
  end

  def handle_info({:permission_revoked, _role_id, _key}, socket) do
    {:noreply, refresh_matrix(socket)}
  end

  def handle_info({:permissions_synced, _role_id, _keys}, socket) do
    {:noreply, refresh_matrix(socket)}
  end

  def handle_info({:module_enabled, _key}, socket) do
    {:noreply, load_matrix(socket)}
  end

  def handle_info({:module_disabled, _key}, socket) do
    {:noreply, load_matrix(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Events ---

  def handle_event("toggle_permission", %{"role_id" => role_id_str, "key" => key}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    with role when not is_nil(role) <-
           Enum.find(socket.assigns.roles, &(to_string(&1.uuid) == role_id_str)),
         false <- role.name == "Owner",
         true <- scope != nil && Scope.has_module_access?(scope, "users") do
      grantable =
        if Scope.owner?(scope),
          do: MapSet.new(Permissions.all_module_keys()),
          else: Scope.accessible_modules(scope)

      if MapSet.member?(grantable, key) do
        granted_by_id = Scope.user_id(scope)
        role_uuid = to_string(role.uuid)
        role_keys = Map.get(socket.assigns.matrix, role_uuid, MapSet.new())
        label = Permissions.module_label(key)

        if MapSet.member?(role_keys, key) do
          Permissions.revoke_permission(role_uuid, key)

          {:noreply,
           socket |> put_flash(:info, "Revoked #{label} from #{role.name}") |> refresh_matrix()}
        else
          Permissions.grant_permission(role_uuid, key, granted_by_id)

          {:noreply,
           socket |> put_flash(:info, "Granted #{label} to #{role.name}") |> refresh_matrix()}
        end
      else
        {:noreply, put_flash(socket, :error, "You can only manage permissions you have")}
      end
    else
      _ ->
        {:noreply, socket}
    end
  end

  # --- Helpers ---

  defp load_matrix(socket) do
    roles = Roles.list_roles()
    matrix = Permissions.get_permissions_matrix()
    all_count = length(Permissions.all_module_keys())

    # Sort: Owner first, then by permission count descending, then name
    sorted_roles =
      Enum.sort_by(roles, fn role ->
        count =
          if role.name == "Owner",
            do: all_count,
            else: Map.get(matrix, to_string(role.uuid), MapSet.new()) |> MapSet.size()

        {role.name != "Owner", -count, role.name}
      end)

    enabled = Permissions.enabled_module_keys()

    enabled_feature_keys =
      Enum.filter(Permissions.feature_module_keys(), &MapSet.member?(enabled, &1))

    socket
    |> assign(:roles, sorted_roles)
    |> assign(:matrix, matrix)
    |> assign(:core_keys, Permissions.core_section_keys())
    |> assign(:feature_keys, enabled_feature_keys)
  end

  # Refresh matrix data only, keep existing role order stable
  defp refresh_matrix(socket) do
    matrix = Permissions.get_permissions_matrix()
    assign(socket, :matrix, matrix)
  end
end
