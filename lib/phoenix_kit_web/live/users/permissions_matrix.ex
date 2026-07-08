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
      |> assign(:page_title, gettext("Permissions"))
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

  def handle_info({:permission_granted, _role_uuid, _key}, socket) do
    {:noreply, refresh_matrix(socket)}
  end

  def handle_info({:permission_revoked, _role_uuid, _key}, socket) do
    {:noreply, refresh_matrix(socket)}
  end

  def handle_info({:permissions_synced, _role_uuid, _keys}, socket) do
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

  def handle_event("toggle_permission", %{"role_uuid" => role_uuid, "key" => key}, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    with role when not is_nil(role) <-
           Enum.find(socket.assigns.roles, &(to_string(&1.uuid) == role_uuid)),
         :ok <- Permissions.can_edit_role_permissions?(scope, role),
         true <- scope != nil && Scope.has_module_access?(scope, "users") do
      grantable =
        if Scope.owner?(scope),
          do: MapSet.new(Permissions.all_module_keys()),
          else: Scope.accessible_modules(scope)

      # Granting a sub-permission auto-grants its base key, so the editor
      # must hold every key the toggle implies — not just the clicked one.
      # Otherwise an editor holding only "calendar.view_others" could smuggle
      # in a "calendar" base grant they don't hold themselves.
      if MapSet.subset?(Permissions.expand_with_parents([key]), grantable) do
        toggle_role_permission(socket, role, key, scope)
      else
        {:noreply, put_flash(socket, :error, gettext("You can only manage permissions you have"))}
      end
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, permission_error_message(reason))}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("Role not found"))}

      false ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to manage permissions"))}
    end
  end

  # --- Helpers ---

  defp toggle_role_permission(socket, role, key, scope) do
    granted_by_uuid = Scope.user_uuid(scope)
    role_uuid = to_string(role.uuid)
    role_keys = Map.get(socket.assigns.matrix, role_uuid, MapSet.new())
    label = Permissions.module_label(key)

    if MapSet.member?(role_keys, key) do
      case Permissions.revoke_permission(role_uuid, key) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Revoked %{label} from %{role_name}",
               label: label,
               role_name: role.name
             )
           )
           |> refresh_matrix()}

        {:error, _reason} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("Failed to revoke %{label} from %{role_name}",
               label: label,
               role_name: role.name
             )
           )
           |> refresh_matrix()}
      end
    else
      case Permissions.grant_permission(role_uuid, key, granted_by_uuid) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Granted %{label} to %{role_name}",
               label: label,
               role_name: role.name
             )
           )
           |> refresh_matrix()}

        {:error, _reason} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("Failed to grant %{label} to %{role_name}",
               label: label,
               role_name: role.name
             )
           )
           |> refresh_matrix()}
      end
    end
  end

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

    # Sub-permissions render as indented rows under their (enabled) module row
    sub_permissions =
      enabled_feature_keys
      |> Enum.map(&{&1, Permissions.sub_permissions_for(&1)})
      |> Enum.reject(fn {_key, subs} -> subs == [] end)
      |> Map.new()

    enabled_sub_keys =
      sub_permissions |> Map.values() |> List.flatten() |> Enum.map(& &1.key)

    core_keys = Permissions.core_section_keys()
    custom_keys = Permissions.custom_keys()

    visible_keys =
      MapSet.new(core_keys ++ enabled_feature_keys ++ enabled_sub_keys ++ custom_keys)

    # Determine which roles can't be edited by the current user
    scope = socket.assigns[:phoenix_kit_current_scope]

    uneditable_role_uuids =
      sorted_roles
      |> Enum.filter(fn role ->
        role.name == "Owner" or Permissions.can_edit_role_permissions?(scope, role) != :ok
      end)
      |> MapSet.new(fn role -> to_string(role.uuid) end)

    socket
    |> assign(:roles, sorted_roles)
    |> assign(:matrix, matrix)
    |> assign(:core_keys, core_keys)
    |> assign(:feature_keys, enabled_feature_keys)
    |> assign(:sub_permissions, sub_permissions)
    |> assign(:custom_keys, custom_keys)
    |> assign(:visible_keys, visible_keys)
    |> assign(:uneditable_role_uuids, uneditable_role_uuids)
  end

  # Refresh matrix data only, keep existing role order stable
  defp refresh_matrix(socket) do
    matrix = Permissions.get_permissions_matrix()
    assign(socket, :matrix, matrix)
  end

  # --- Template Components ---

  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :sub, :boolean, default: false
  attr :roles, :list, required: true
  attr :matrix, :map, required: true
  attr :uneditable_role_uuids, :any, required: true

  # One matrix row: label cell + a toggle/read-only cell per role.
  # `sub` renders the indented variant used for sub-permission keys.
  defp permission_row(assigns) do
    ~H"""
    <tr>
      <td class={[
        "sticky left-0 z-[1] whitespace-nowrap",
        (@sub && "pl-8 text-sm text-base-content/80") || "font-medium"
      ]}>
        <.icon
          :if={@sub}
          name="hero-arrow-turn-down-right"
          class="w-3.5 h-3.5 text-base-content/40 mr-1"
        />{@label}
      </td>
      <td :for={role <- @roles} class="text-center">
        <%= if role.name == "Owner" do %>
          <span class="badge badge-sm badge-primary badge-outline">
            {gettext("always")}
          </span>
        <% else %>
          <%= if MapSet.member?(@uneditable_role_uuids, to_string(role.uuid)) do %>
            <%!-- Read-only: user's own role or Admin (non-Owner) --%>
            <%= if granted?(@matrix, role, @key) do %>
              <.icon name="hero-check-circle" class="w-5 h-5 text-success/50" />
            <% else %>
              <.icon name="hero-x-circle" class="w-5 h-5 text-base-content/10" />
            <% end %>
          <% else %>
            <button
              phx-click="toggle_permission"
              phx-value-role_uuid={role.uuid}
              phx-value-key={@key}
              class="cursor-pointer hover:opacity-70 transition-opacity"
            >
              <%= if granted?(@matrix, role, @key) do %>
                <.icon name="hero-check-circle" class="w-5 h-5 text-success" />
              <% else %>
                <.icon name="hero-x-circle" class="w-5 h-5 text-base-content/20" />
              <% end %>
            </button>
          <% end %>
        <% end %>
      </td>
    </tr>
    """
  end

  defp granted?(matrix, role, key) do
    Map.get(matrix, to_string(role.uuid), MapSet.new()) |> MapSet.member?(key)
  end

  defp permission_error_message(:not_authenticated), do: gettext("Not authenticated")

  defp permission_error_message(:owner_immutable),
    do: gettext("Owner role always has full access and cannot be modified")

  defp permission_error_message(:self_role),
    do: gettext("You cannot edit permissions for your own role")

  defp permission_error_message(:admin_owner_only),
    do: gettext("Only the Owner can edit Admin permissions")

  defp permission_error_message(_), do: gettext("Permission denied")
end
