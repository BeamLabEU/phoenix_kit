defmodule PhoenixKitWeb.Live.Users.Roles do
  @moduledoc """
  Role management LiveView for PhoenixKit admin panel.

  Provides interface for viewing and managing user roles and permissions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Role, Roles}

  def mount(_params, _session, socket) do
    # Attach locale hook for automatic locale handling

    # Subscribe to role events for live updates
    if connected?(socket) do
      Events.subscribe_to_roles()
      Events.subscribe_to_stats()
    end

    # Load optimized role statistics once
    role_stats = load_role_statistics()

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:roles, [])
      |> assign(:show_create_form, false)
      |> assign(:show_edit_form, false)
      |> assign(:create_role_form, nil)
      |> assign(:edit_role_form, nil)
      |> assign(:editing_role, nil)
      |> assign(:delete_confirmation, %{show: false})
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

  def handle_event("show_edit_role", %{"role_id" => role_id}, socket) do
    role = Enum.find(socket.assigns.roles, &(&1.id == String.to_integer(role_id)))

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
      {:ok, _role} ->
        socket =
          socket
          |> put_flash(:info, "Role created successfully")
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

  def handle_event("confirm_delete_role", %{"role_id" => role_id}, socket) do
    # Close modal first
    socket = assign(socket, :delete_confirmation, %{show: false})

    # Execute the deletion
    handle_delete_role(role_id, socket)
  end

  # Keep old handler for backward compatibility
  def handle_event("delete_role", %{"role_id" => role_id}, socket) do
    handle_delete_role(role_id, socket)
  end

  # Keep the old handler for backward compatibility and make it private
  defp handle_delete_role(role_id, socket) when is_binary(role_id) do
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
