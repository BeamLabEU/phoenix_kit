defmodule PhoenixKitWeb.Live.Users.RolesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Role, Roles}
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    # Subscribe to role events for live updates
    if connected?(socket) do
      Events.subscribe_to_roles()
      Events.subscribe_to_stats()
    end

    # Get current path for navigation
    current_path = get_current_path()

    # Load optimized role statistics once
    role_stats = load_role_statistics()

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:roles, [])
      |> assign(:editing_role, nil)
      |> assign(:show_form, false)
      |> assign(:form_data, %{"name" => "", "description" => ""})
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Roles")
      |> assign(:role_stats, role_stats)
      |> assign(:project_title, project_title)
      |> load_roles()

    {:ok, socket}
  end

  defp get_current_path do
    # For RolesLive, always return roles path
    Routes.path("/admin/users/roles")
  end

  def handle_event("show_create_form", _params, socket) do
    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:editing_role, nil)
      |> assign(:form_data, %{"name" => "", "description" => ""})

    {:noreply, socket}
  end

  def handle_event("hide_form", _params, socket) do
    socket =
      socket
      |> assign(:show_form, false)
      |> assign(:editing_role, nil)
      |> assign(:form_data, %{"name" => "", "description" => ""})

    {:noreply, socket}
  end

  def handle_event("edit_role", %{"role_id" => role_id}, socket) do
    role = Enum.find(socket.assigns.roles, &(&1.id == String.to_integer(role_id)))

    if role && !role.is_system_role do
      socket =
        socket
        |> assign(:show_form, true)
        |> assign(:editing_role, role)
        |> assign(:form_data, %{"name" => role.name, "description" => role.description || ""})

      {:noreply, socket}
    else
      socket = put_flash(socket, :error, "System roles cannot be edited")
      {:noreply, socket}
    end
  end

  def handle_event("create_role", %{"role" => role_params}, socket) do
    case Roles.create_role(role_params) do
      {:ok, _role} ->
        socket =
          socket
          |> put_flash(:info, "Role created successfully")
          |> assign(:show_form, false)
          |> assign(:form_data, %{"name" => "", "description" => ""})
          |> load_roles()

        {:noreply, socket}

      {:error, changeset} ->
        errors = extract_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to create role: #{errors}")
        {:noreply, socket}
    end
  end

  def handle_event("update_role", %{"role" => role_params}, socket) do
    editing_role = socket.assigns.editing_role

    case Roles.update_role(editing_role, role_params) do
      {:ok, _role} ->
        socket =
          socket
          |> put_flash(:info, "Role updated successfully")
          |> assign(:show_form, false)
          |> assign(:editing_role, nil)
          |> assign(:form_data, %{"name" => "", "description" => ""})
          |> load_roles()

        {:noreply, socket}

      {:error, changeset} ->
        errors = extract_changeset_errors(changeset)
        socket = put_flash(socket, :error, "Failed to update role: #{errors}")
        {:noreply, socket}
    end
  end

  def handle_event("delete_role", %{"role_id" => role_id}, socket) do
    role = Enum.find(socket.assigns.roles, &(&1.id == String.to_integer(role_id)))

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
    assign(socket, :roles, roles)
  end

  defp extract_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end

  defp role_badge_class(%Role{is_system_role: true, name: "Owner"}), do: "badge-error"
  defp role_badge_class(%Role{is_system_role: true, name: "Admin"}), do: "badge-warning"
  defp role_badge_class(%Role{is_system_role: true, name: "User"}), do: "badge-info"
  defp role_badge_class(%Role{is_system_role: true}), do: "badge-accent"
  defp role_badge_class(%Role{is_system_role: false}), do: "badge-primary"

  # Load role statistics using optimized extended stats
  defp load_role_statistics do
    stats = Roles.get_extended_stats()

    # Create lookup map for fast role count access
    %{
      "Owner" => stats.owner_count,
      "Admin" => stats.admin_count,
      "User" => stats.user_count
    }
  end

  # Optimized function using cached statistics
  defp users_count_for_role(role, role_stats) do
    # Use cached stats for system roles, fallback to DB query for custom roles
    case role_stats[role.name] do
      nil ->
        # Custom role - query database (only for non-system roles)
        Roles.count_users_with_role(role.name)

      count ->
        # System role - use cached count
        count
    end
  end

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

  def handle_info({:role_deleted, _role}, socket) do
    socket =
      socket
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
end
