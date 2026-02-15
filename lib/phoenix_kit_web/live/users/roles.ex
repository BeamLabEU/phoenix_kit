defmodule PhoenixKitWeb.Live.Users.Roles do
  @moduledoc """
  Role management LiveView for PhoenixKit admin panel.

  Provides interface for viewing and managing user roles and permissions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.{Role, Roles}

  def mount(_params, _session, socket) do
    # Attach locale hook for automatic locale handling

    # Subscribe to role events for live updates
    if connected?(socket) do
      Events.subscribe_to_roles()
      Events.subscribe_to_stats()
      Events.subscribe_to_permissions()
      Events.subscribe_to_modules()
    end

    # Load optimized role statistics once
    role_stats = load_role_statistics()

    # Get project title from settings
    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:roles, [])
      |> assign(:show_create_form, false)
      |> assign(:show_edit_form, false)
      |> assign(:create_role_form, nil)
      |> assign(:edit_role_form, nil)
      |> assign(:editing_role, nil)
      |> assign(:delete_confirmation, %{show: false})
      |> assign(:show_permissions_editor, false)
      |> assign(:permissions_role, nil)
      |> assign(:permissions_role_keys, MapSet.new())
      |> assign(:permissions_grantable_keys, MapSet.new())
      |> assign(:permissions_preserved_keys, MapSet.new())
      |> assign(:page_title, "Roles")
      |> assign(:role_stats, role_stats)
      |> assign(:project_title, project_title)
      |> load_roles()

    {:ok, socket}
  end

  def handle_event("show_create_form", _params, socket) do
    form = to_form(Role.changeset(%Role{}, %{}))

    socket =
      socket
      |> assign(:show_create_form, true)
      |> assign(:create_role_form, form)

    {:noreply, socket}
  end

  def handle_event("show_edit_role", %{"role_id" => role_id_str}, socket) do
    role = find_role_by_id(socket.assigns.roles, role_id_str)

    if role && !role.is_system_role do
      form = to_form(Role.changeset(role, %{}))

      socket =
        socket
        |> assign(:show_edit_form, true)
        |> assign(:edit_role_form, form)
        |> assign(:editing_role, role)

      {:noreply, socket}
    else
      socket = put_flash(socket, :error, "System roles cannot be edited")
      {:noreply, socket}
    end
  end

  def handle_event("hide_form", _params, socket) do
    socket =
      socket
      |> assign(:show_create_form, false)
      |> assign(:show_edit_form, false)
      |> assign(:create_role_form, nil)
      |> assign(:edit_role_form, nil)
      |> assign(:editing_role, nil)

    {:noreply, socket}
  end

  def handle_event("create_role", %{"role" => role_params}, socket) do
    case Roles.create_role(role_params) do
      {:ok, role} ->
        flash_msg =
          if can_manage_permissions?(socket),
            do: "Role \"#{role.name}\" created. Click Permissions to configure access.",
            else: "Role created successfully"

        socket =
          socket
          |> put_flash(:info, flash_msg)
          |> assign(:show_create_form, false)
          |> assign(:create_role_form, nil)
          |> load_roles()

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :create_role_form, to_form(changeset))}
    end
  end

  def handle_event("update_role", %{"role" => role_params}, socket) do
    editing_role = socket.assigns.editing_role

    if is_nil(editing_role) do
      {:noreply,
       socket
       |> put_flash(:error, "Role no longer exists")
       |> assign(:show_edit_form, false)
       |> assign(:edit_role_form, nil)
       |> assign(:editing_role, nil)}
    else
      case Roles.update_role(editing_role, role_params) do
        {:ok, _role} ->
          socket =
            socket
            |> put_flash(:info, "Role updated successfully")
            |> assign(:show_edit_form, false)
            |> assign(:edit_role_form, nil)
            |> assign(:editing_role, nil)
            |> load_roles()

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply, assign(socket, :edit_role_form, to_form(changeset))}
      end
    end
  end

  # New events for confirmation modal
  def handle_event(
        "request_delete_role",
        %{"role_id" => role_id, "role_name" => role_name},
        socket
      ) do
    delete_confirmation = %{
      show: true,
      role_id: role_id,
      role_name: role_name
    }

    {:noreply, assign(socket, :delete_confirmation, delete_confirmation)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_confirmation, %{show: false})}
  end

  def handle_event("confirm_delete_role", _params, socket) do
    role_id = Map.get(socket.assigns.delete_confirmation, :role_id)

    if is_nil(role_id) do
      {:noreply, assign(socket, :delete_confirmation, %{show: false})}
    else
      # Close modal first
      socket = assign(socket, :delete_confirmation, %{show: false})

      # Execute the deletion
      handle_delete_role(role_id, socket)
    end
  end

  # Keep old handler for backward compatibility
  def handle_event("delete_role", %{"role_id" => role_id}, socket) do
    handle_delete_role(role_id, socket)
  end

  # --- Permission Editor Events ---

  def handle_event("show_permissions_editor", %{"role_id" => role_id_str}, socket) do
    if can_manage_permissions?(socket) do
      role = find_role_by_id(socket.assigns.roles, role_id_str)
      scope = socket.assigns[:phoenix_kit_current_scope]

      with true <- role != nil,
           :ok <- can_edit_role_permissions?(scope, role) do
        grantable = grantable_keys(socket)
        enabled = Permissions.enabled_module_keys()
        # Only show keys that are both grantable AND enabled
        displayable = MapSet.intersection(grantable, enabled)
        current_keys = Permissions.get_permissions_for_role(role.uuid) |> MapSet.new()
        editable_checked = MapSet.intersection(current_keys, displayable)
        # Preserve: keys outside displayable set (not grantable OR disabled modules)
        preserved = MapSet.difference(current_keys, displayable)

        socket =
          socket
          |> assign(:show_permissions_editor, true)
          |> assign(:permissions_role, role)
          |> assign(:permissions_role_keys, editable_checked)
          |> assign(:permissions_grantable_keys, displayable)
          |> assign(:permissions_preserved_keys, preserved)

        {:noreply, socket}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}

        false ->
          {:noreply, put_flash(socket, :error, "Role not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage permissions")}
    end
  end

  def handle_event("hide_permissions_editor", _params, socket) do
    socket =
      socket
      |> assign(:show_permissions_editor, false)
      |> assign(:permissions_role, nil)
      |> assign(:permissions_role_keys, MapSet.new())
      |> assign(:permissions_grantable_keys, MapSet.new())
      |> assign(:permissions_preserved_keys, MapSet.new())

    {:noreply, socket}
  end

  def handle_event("toggle_permission", %{"key" => key}, socket) do
    if can_manage_permissions?(socket) do
      grantable = socket.assigns.permissions_grantable_keys

      if MapSet.member?(grantable, key) do
        keys = socket.assigns.permissions_role_keys

        new_keys =
          if MapSet.member?(keys, key),
            do: MapSet.delete(keys, key),
            else: MapSet.put(keys, key)

        {:noreply, assign(socket, :permissions_role_keys, new_keys)}
      else
        {:noreply, put_flash(socket, :error, "You can only manage permissions you have")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage permissions")}
    end
  end

  def handle_event("grant_all_permissions", _params, socket) do
    if can_manage_permissions?(socket) do
      {:noreply,
       assign(socket, :permissions_role_keys, socket.assigns.permissions_grantable_keys)}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage permissions")}
    end
  end

  def handle_event("revoke_all_permissions", _params, socket) do
    if can_manage_permissions?(socket) do
      {:noreply, assign(socket, :permissions_role_keys, MapSet.new())}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage permissions")}
    end
  end

  def handle_event("save_permissions", _params, socket) do
    role = socket.assigns.permissions_role

    cond do
      is_nil(role) ->
        {:noreply, put_flash(socket, :error, "No role selected")}

      !can_manage_permissions?(socket) ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage permissions")}

      can_edit_role_permissions?(socket.assigns[:phoenix_kit_current_scope], role) != :ok ->
        {:noreply, put_flash(socket, :error, "You cannot edit permissions for this role")}

      true ->
        preserved = socket.assigns.permissions_preserved_keys
        editor_keys = socket.assigns.permissions_role_keys
        final_keys = MapSet.union(preserved, editor_keys) |> MapSet.to_list()

        scope = socket.assigns[:phoenix_kit_current_scope]
        granted_by_id = if scope, do: Scope.user_id(scope), else: nil

        case Permissions.set_permissions(role.id, final_keys, granted_by_id) do
          :ok ->
            socket =
              socket
              |> put_flash(:info, "Permissions updated for #{role.name}")
              |> assign(:show_permissions_editor, false)
              |> assign(:permissions_role, nil)
              |> assign(:permissions_role_keys, MapSet.new())
              |> assign(:permissions_grantable_keys, MapSet.new())
              |> assign(:permissions_preserved_keys, MapSet.new())

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to update permissions")}
        end
    end
  end

  # Keep the old handler for backward compatibility and make it private
  defp handle_delete_role(role_id, socket) when is_binary(role_id) do
    role = find_role_by_id(socket.assigns.roles, role_id)

    if role && !role.is_system_role do
      case Roles.delete_role(role) do
        {:ok, _role} ->
          socket =
            socket
            |> put_flash(:info, "Role deleted successfully")
            |> load_roles()

          {:noreply, socket}

        {:error, :role_in_use} ->
          socket =
            put_flash(socket, :error, "Cannot delete role: it is currently assigned to users")

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to delete role")
          {:noreply, socket}
      end
    else
      socket = put_flash(socket, :error, "System roles cannot be deleted")
      {:noreply, socket}
    end
  end

  defp load_roles(socket) do
    roles = Roles.list_roles()
    scope = socket.assigns[:phoenix_kit_current_scope]

    uneditable_role_uuids =
      roles
      |> Enum.filter(fn role ->
        role.name == "Owner" or can_edit_role_permissions?(scope, role) != :ok
      end)
      |> MapSet.new(fn role -> to_string(role.uuid) end)

    socket
    |> assign(:roles, roles)
    |> assign(:uneditable_role_uuids, uneditable_role_uuids)
  end

  # Load role statistics: count of users per role name
  defp load_role_statistics do
    Roles.list_roles()
    |> Map.new(fn role -> {role.name, Roles.count_users_with_role(role.name)} end)
  end

  # Optimized function using cached statistics
  ## Live Event Handlers

  def handle_info({:role_created, _role}, socket) do
    socket =
      socket
      |> load_roles()
      |> assign(:role_stats, load_role_statistics())

    {:noreply, socket}
  end

  def handle_info({:role_updated, _role}, socket) do
    socket =
      socket
      |> load_roles()
      |> assign(:role_stats, load_role_statistics())

    {:noreply, socket}
  end

  def handle_info({:role_deleted, role}, socket) do
    socket =
      socket
      |> close_modals_for_deleted_role(role)
      |> load_roles()
      |> assign(:role_stats, load_role_statistics())

    {:noreply, socket}
  end

  def handle_info({:stats_updated, _stats}, socket) do
    socket =
      socket
      |> assign(:role_stats, load_role_statistics())

    {:noreply, socket}
  end

  def handle_info({:permission_granted, role_id, _key}, socket) do
    {:noreply, refresh_permissions_if_editing(socket, role_id)}
  end

  def handle_info({:permission_revoked, role_id, _key}, socket) do
    {:noreply, refresh_permissions_if_editing(socket, role_id)}
  end

  def handle_info({:permissions_synced, role_id, _keys}, socket) do
    {:noreply, refresh_permissions_if_editing(socket, role_id)}
  end

  def handle_info({:module_enabled, _key}, socket) do
    {:noreply, refresh_permissions_if_editing_any(socket)}
  end

  def handle_info({:module_disabled, _key}, socket) do
    {:noreply, refresh_permissions_if_editing_any(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp can_manage_permissions?(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    scope && Scope.has_module_access?(scope, "users")
  end

  defp can_edit_role_permissions?(nil, _role), do: {:error, "Not authenticated"}

  defp can_edit_role_permissions?(scope, role) do
    user_roles = Scope.user_roles(scope)

    cond do
      role.name in user_roles ->
        {:error, "You cannot edit permissions for your own role"}

      role.name == "Admin" and not Scope.owner?(scope) ->
        {:error, "Only the Owner can edit Admin permissions"}

      true ->
        :ok
    end
  end

  defp grantable_keys(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.owner?(scope) do
      MapSet.new(Permissions.all_module_keys())
    else
      Scope.accessible_modules(scope)
    end
  end

  defp find_role_by_id(roles, id_str) when is_binary(id_str) do
    Enum.find(roles, &(to_string(&1.uuid) == id_str))
  end

  defp close_modals_for_deleted_role(socket, deleted_role) do
    socket
    |> then(fn s ->
      if s.assigns.show_permissions_editor &&
           s.assigns.permissions_role &&
           s.assigns.permissions_role.id == deleted_role.id do
        s
        |> assign(:show_permissions_editor, false)
        |> assign(:permissions_role, nil)
        |> assign(:permissions_role_keys, MapSet.new())
        |> assign(:permissions_grantable_keys, MapSet.new())
        |> assign(:permissions_preserved_keys, MapSet.new())
        |> put_flash(:info, "Role \"#{deleted_role.name}\" was deleted")
      else
        s
      end
    end)
    |> then(fn s ->
      if s.assigns.editing_role && s.assigns.editing_role.id == deleted_role.id do
        s
        |> assign(:show_edit_form, false)
        |> assign(:edit_role_form, nil)
        |> assign(:editing_role, nil)
        |> put_flash(:info, "Role \"#{deleted_role.name}\" was deleted")
      else
        s
      end
    end)
  end

  defp refresh_permissions_if_editing(socket, role_id) do
    role = socket.assigns[:permissions_role]

    if socket.assigns.show_permissions_editor && role &&
         (role.id == role_id or to_string(role.uuid) == to_string(role_id)) do
      reload_permission_editor_data(socket)
    else
      socket
    end
  end

  defp refresh_permissions_if_editing_any(socket) do
    if socket.assigns.show_permissions_editor && socket.assigns.permissions_role do
      reload_permission_editor_data(socket)
    else
      socket
    end
  end

  defp reload_permission_editor_data(socket) do
    role = socket.assigns.permissions_role
    grantable = grantable_keys(socket)
    enabled = Permissions.enabled_module_keys()
    displayable = MapSet.intersection(grantable, enabled)
    current_keys = Permissions.get_permissions_for_role(role.id) |> MapSet.new()
    editable_checked = MapSet.intersection(current_keys, displayable)
    preserved = MapSet.difference(current_keys, displayable)

    socket
    |> assign(:permissions_grantable_keys, displayable)
    |> assign(:permissions_role_keys, editable_checked)
    |> assign(:permissions_preserved_keys, preserved)
  end
end
