defmodule PhoenixKitWeb.Live.Users.UsersLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @per_page 10

  def mount(_params, session, socket) do
    # Subscribe to user events for live updates
    if connected?(socket) do
      Events.subscribe_to_users()
      Events.subscribe_to_stats()
    end

    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:search_query, "")
      |> assign(:filter_role, "all")
      |> assign(:show_role_modal, false)
      |> assign(:managing_user, nil)
      |> assign(:user_roles, [])
      |> assign(:all_roles, [])
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Users")
      |> assign(:project_title, project_title)
      |> load_users()
      |> load_stats()

    {:ok, socket}
  end

  def handle_params(%{"action" => "add"} = _params, _url, socket) do
    # Open user registration form for adding new user
    socket = assign(socket, :show_add_user_modal, true)
    {:noreply, socket}
  end

  def handle_params(_params, _url, socket) do
    # Default case - no action specified
    socket = assign(socket, :show_add_user_modal, false)
    {:noreply, socket}
  end

  def handle_event("search", %{"search" => search_query}, socket) do
    socket =
      socket
      |> assign(:search_query, search_query)
      |> assign(:page, 1)
      |> load_users()

    {:noreply, socket}
  end

  def handle_event("filter_by_role", %{"role" => role}, socket) do
    socket =
      socket
      |> assign(:filter_role, role)
      |> assign(:page, 1)
      |> load_users()

    {:noreply, socket}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_users()

    {:noreply, socket}
  end

  def handle_event("show_role_management", %{"user_id" => user_id}, socket) do
    user_id_int = String.to_integer(user_id)
    user = Auth.get_user!(user_id_int)
    current_user = socket.assigns.phoenix_kit_current_user

    # Prevent self-modification for critical operations
    if current_user.id == user.id do
      socket = put_flash(socket, :error, "Cannot modify your own roles")
      {:noreply, socket}
    else
      # Get fresh user with preloaded roles to ensure accurate state
      user_with_roles = Auth.get_user_with_roles(user_id_int)

      user_roles = Roles.get_user_roles(user_with_roles)
      all_roles = Roles.list_roles()

      socket =
        socket
        |> assign(:managing_user, user_with_roles)
        |> assign(:user_roles, user_roles)
        |> assign(:all_roles, all_roles)
        |> assign(:show_role_modal, true)

      {:noreply, socket}
    end
  end

  def handle_event("hide_role_management", _params, socket) do
    socket =
      socket
      |> assign(:managing_user, nil)
      |> assign(:user_roles, [])
      |> assign(:all_roles, [])
      |> assign(:show_role_modal, false)

    {:noreply, socket}
  end

  def handle_event("sync_user_roles", %{"roles" => selected_roles}, socket) do
    user = socket.assigns.managing_user
    role_names = Map.values(selected_roles)

    case Roles.sync_user_roles(user, role_names) do
      {:ok, _assignments} ->
        socket =
          socket
          |> put_flash(:info, "User roles updated successfully")
          |> assign(:show_role_modal, false)
          |> assign(:managing_user, nil)
          |> assign(:user_roles, [])
          |> assign(:all_roles, [])
          |> load_users()
          |> load_stats()

        {:noreply, socket}

      {:error, reason} ->
        error_msg =
          case reason do
            :cannot_remove_last_owner -> "Cannot remove the last system owner"
            :owner_role_protected -> "Owner role cannot be assigned manually"
            _ -> "Failed to update user roles"
          end

        # Refresh the modal data on error to show current state
        user_with_roles = Auth.get_user_with_roles(user.id)
        updated_user_roles = Roles.get_user_roles(user_with_roles)

        socket =
          socket
          |> put_flash(:error, error_msg)
          |> assign(:managing_user, user_with_roles)
          |> assign(:user_roles, updated_user_roles)

        {:noreply, socket}
    end
  end

  def handle_event("quick_toggle_role", %{"user_id" => user_id, "role_name" => role_name}, socket) do
    user = Auth.get_user!(user_id)
    current_user = socket.assigns.phoenix_kit_current_user

    # Prevent self-modification
    if current_user.id == user.id do
      socket = put_flash(socket, :error, "Cannot modify your own roles")
      {:noreply, socket}
    else
      handle_role_toggle_result(toggle_user_role(user, role_name), role_name, socket)
    end
  end

  def handle_event("toggle_user_status", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns.phoenix_kit_current_user
    user = Auth.get_user!(user_id)

    if current_user.id == user.id do
      socket = put_flash(socket, :error, "Cannot modify your own status")
      {:noreply, socket}
    else
      toggle_user_status_safely(socket, user)
    end
  end

  def handle_event("toggle_user_confirmation", %{"user_id" => user_id}, socket) do
    current_user = socket.assigns.phoenix_kit_current_user
    user = Auth.get_user!(user_id)

    if current_user.id == user.id do
      socket = put_flash(socket, :error, "Cannot modify your own confirmation status")
      {:noreply, socket}
    else
      toggle_user_confirmation_safely(socket, user)
    end
  end

  defp toggle_user_status_safely(socket, user) do
    new_status = !user.is_active

    case Auth.update_user_status(user, %{"is_active" => new_status}) do
      {:ok, _user} ->
        status_text = if new_status, do: "activated", else: "deactivated"

        socket =
          socket
          |> put_flash(:info, "User #{status_text} successfully")
          |> load_users()
          |> load_stats()

        {:noreply, socket}

      {:error, :cannot_deactivate_last_owner} ->
        socket = put_flash(socket, :error, "Cannot deactivate the last system owner")
        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update user status")
        {:noreply, socket}
    end
  end

  defp toggle_user_confirmation_safely(socket, user) do
    case Auth.toggle_user_confirmation(user) do
      {:ok, updated_user} ->
        status_text = if updated_user.confirmed_at, do: "confirmed", else: "unconfirmed"

        socket =
          socket
          |> put_flash(:info, "User email #{status_text} successfully")
          |> load_users()
          |> load_stats()

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update user confirmation status")
        {:noreply, socket}
    end
  end

  defp load_users(socket) do
    params = [
      page: socket.assigns.page,
      page_size: socket.assigns.per_page,
      search: socket.assigns.search_query,
      role: socket.assigns.filter_role
    ]

    %{users: users, total_count: total_count, total_pages: total_pages} =
      Auth.list_users_paginated(params)

    # Force refresh by clearing users first, then setting new ones
    # This ensures LiveView doesn't reuse stale user objects with cached roles
    socket
    |> assign(:users, [])
    |> assign(:users, users)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end

  defp load_stats(socket) do
    stats = Roles.get_extended_stats()

    socket
    |> assign(:total_users, stats.total_users)
    |> assign(:total_owners, stats.owner_count)
    |> assign(:total_admins, stats.admin_count)
    |> assign(:total_regular_users, stats.user_count)
    |> assign(:active_users, stats.active_users)
    |> assign(:inactive_users, stats.inactive_users)
    |> assign(:confirmed_users, stats.confirmed_users)
    |> assign(:pending_users, stats.pending_users)
  end

  defp get_user_roles(user) do
    # Use preloaded roles if available
    case Ecto.assoc_loaded?(user.roles) do
      true ->
        # Use preloaded roles directly since inactive assignments are deleted from DB
        user.roles
        |> Enum.map(& &1.name)
        |> Enum.sort()

      false ->
        # Fallback to DB query if roles not preloaded
        Roles.get_user_roles(user)
    end
  end

  defp user_has_role?(user, role_name) do
    role_name in get_user_roles(user)
  end

  defp toggle_user_role(user, role_name) do
    if user_has_role?(user, role_name) do
      case Roles.remove_role(user, role_name) do
        {:ok, _} -> {:ok, :removed}
        {:error, reason} -> {:error, reason}
      end
    else
      case Roles.assign_role(user, role_name) do
        {:ok, _} -> {:ok, :added}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp role_badge_class_for_custom(role_name) do
    case role_name do
      "Owner" -> "badge-error"
      "Admin" -> "badge-warning"
      "User" -> "badge-info"
      _ -> "badge-primary"
    end
  end

  defp handle_role_toggle_result(result, role_name, socket) do
    case result do
      {:ok, action} ->
        action_text = if action == :added, do: "added to", else: "removed from"

        socket =
          socket
          |> put_flash(:info, "Role #{role_name} #{action_text} user successfully")
          |> load_users()
          |> load_stats()

        {:noreply, socket}

      {:error, reason} ->
        error_msg = format_role_error_message(reason)
        socket = put_flash(socket, :error, error_msg)
        {:noreply, socket}
    end
  end

  defp format_role_error_message(reason) do
    case reason do
      :cannot_remove_last_owner -> "Cannot remove the last system owner"
      :owner_role_protected -> "Owner role cannot be assigned manually"
      :role_not_found -> "Role not found"
      _ -> "Failed to update user role"
    end
  end

  defp get_current_path(_socket, _session) do
    # For UsersLive, always return users path
    Routes.path("/admin/users")
  end

  # Optimized function using preloaded roles
  defp user_primary_role(user) do
    roles = get_user_roles(user)

    cond do
      "Owner" in roles -> "Owner"
      "Admin" in roles -> "Admin"
      true -> "User"
    end
  end

  ## Live Event Handlers

  def handle_info({:user_created, _user}, socket) do
    socket =
      socket
      |> load_users()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_updated, _user}, socket) do
    socket =
      socket
      |> load_users()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_role_assigned, _user, _role_name}, socket) do
    socket =
      socket
      |> load_users()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_role_removed, _user, _role_name}, socket) do
    socket =
      socket
      |> load_users()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_roles_synced, _user, _new_roles}, socket) do
    socket =
      socket
      |> load_users()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_confirmed, _user}, socket) do
    socket =
      socket
      |> load_users()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:user_unconfirmed, _user}, socket) do
    socket =
      socket
      |> load_users()
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info({:stats_updated, stats}, socket) do
    socket =
      socket
      |> assign(:total_users, stats.total_users)
      |> assign(:total_owners, stats.owner_count)
      |> assign(:total_admins, stats.admin_count)
      |> assign(:total_regular_users, stats.user_count)
      |> assign(:active_users, stats.active_users)
      |> assign(:inactive_users, stats.inactive_users)
      |> assign(:confirmed_users, stats.confirmed_users)
      |> assign(:pending_users, stats.pending_users)

    {:noreply, socket}
  end
end
