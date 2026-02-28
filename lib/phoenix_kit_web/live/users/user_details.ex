defmodule PhoenixKitWeb.Live.Users.UserDetails do
  @moduledoc """
  LiveView for displaying detailed user information.

  Displays user profile information in a tabbed interface with:
  - Profile tab: Basic info, status, roles, registration details
  - Connections tab: Follower/following/connection stats (if enabled)
  - Notes tab: Admin notes about the user
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Modules.Connections
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.AdminNote
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => user_uuid}, _session, socket) do
    project_title = Settings.get_project_title()

    user = Auth.get_user_with_roles(user_uuid)

    case user do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("User not found"))
         |> push_navigate(to: Routes.path("/admin/users"))}

      user ->
        if connected?(socket), do: Events.subscribe_to_users()

        custom_field_definitions = CustomFields.list_field_definitions()

        # Load connections stats if module is enabled
        connections_enabled = Connections.enabled?()

        connections_stats =
          if connections_enabled do
            %{
              followers: Connections.followers_count(user),
              following: Connections.following_count(user),
              connections: Connections.connections_count(user),
              pending: Connections.pending_requests_count(user),
              blocked: length(Connections.list_blocked(user))
            }
          else
            nil
          end

        # Load admin notes
        admin_notes = Auth.list_admin_notes(user)

        socket =
          socket
          |> assign(:user, user)
          |> assign(:page_title, user_display_name(user))
          |> assign(:project_title, project_title)
          |> assign(:active_tab, "profile")
          |> assign(:custom_field_definitions, custom_field_definitions)
          |> assign(:show_delete_modal, false)
          |> assign(:connections_enabled, connections_enabled)
          |> assign(:connections_stats, connections_stats)
          |> assign(:admin_notes, admin_notes)
          |> assign(:note_form, to_form(Auth.change_admin_note(%AdminNote{})))
          |> assign(:editing_note_id, nil)

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("show_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  @impl true
  def handle_event("hide_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  @impl true
  def handle_event("delete_user", _params, socket) do
    user = socket.assigns.user
    current_user = socket.assigns.phoenix_kit_current_scope.user

    opts = %{
      current_user: current_user,
      ip_address: socket.assigns[:ip_address],
      user_agent: socket.assigns[:user_agent]
    }

    case Auth.delete_user(user, opts) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:info, gettext("User deleted successfully"))
         |> push_navigate(to: Routes.path("/admin/users"))}

      {:error, :cannot_delete_self} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:error, gettext("Cannot delete your own account"))}

      {:error, :cannot_delete_last_owner} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:error, gettext("Cannot delete the last system owner"))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:error, gettext("Failed to delete user"))}
    end
  end

  # Admin Notes Events

  @impl true
  def handle_event("add_note", %{"admin_note" => note_params}, socket) do
    current_user = socket.assigns.phoenix_kit_current_scope.user
    user = socket.assigns.user

    case Auth.create_admin_note(user, current_user, note_params) do
      {:ok, _note} ->
        admin_notes = Auth.list_admin_notes(user)

        {:noreply,
         socket
         |> assign(:admin_notes, admin_notes)
         |> assign(:note_form, to_form(Auth.change_admin_note(%AdminNote{})))
         |> put_flash(:info, gettext("Note added successfully"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :note_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit_note", %{"uuid" => note_id}, socket) do
    note = Enum.find(socket.assigns.admin_notes, &(to_string(&1.uuid) == note_id))

    if note do
      changeset = Auth.change_admin_note(note)

      {:noreply,
       socket
       |> assign(:editing_note_id, note_id)
       |> assign(:note_form, to_form(changeset))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_note_id, nil)
     |> assign(:note_form, to_form(Auth.change_admin_note(%AdminNote{})))}
  end

  @impl true
  def handle_event("update_note", %{"admin_note" => note_params}, socket) do
    note_id = socket.assigns.editing_note_id
    note = Enum.find(socket.assigns.admin_notes, &(to_string(&1.uuid) == note_id))

    if note do
      case Auth.update_admin_note(note, note_params) do
        {:ok, _note} ->
          admin_notes = Auth.list_admin_notes(socket.assigns.user)

          {:noreply,
           socket
           |> assign(:admin_notes, admin_notes)
           |> assign(:editing_note_id, nil)
           |> assign(:note_form, to_form(Auth.change_admin_note(%AdminNote{})))
           |> put_flash(:info, gettext("Note updated successfully"))}

        {:error, changeset} ->
          {:noreply, assign(socket, :note_form, to_form(changeset))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_note", %{"uuid" => note_id}, socket) do
    note = Enum.find(socket.assigns.admin_notes, &(to_string(&1.uuid) == note_id))

    if note do
      case Auth.delete_admin_note(note) do
        {:ok, _} ->
          admin_notes = Auth.list_admin_notes(socket.assigns.user)

          {:noreply,
           socket
           |> assign(:admin_notes, admin_notes)
           |> put_flash(:info, gettext("Note deleted successfully"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete note"))}
      end
    else
      {:noreply, socket}
    end
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:user_updated, user}, socket) do
    {:noreply, maybe_refresh_user(socket, user)}
  end

  @impl true
  def handle_info({:user_role_assigned, user, _role}, socket) do
    {:noreply, maybe_refresh_user(socket, user)}
  end

  @impl true
  def handle_info({:user_role_removed, user, _role}, socket) do
    {:noreply, maybe_refresh_user(socket, user)}
  end

  @impl true
  def handle_info({:user_roles_synced, user, _roles}, socket) do
    {:noreply, maybe_refresh_user(socket, user)}
  end

  @impl true
  def handle_info({:user_confirmed, user}, socket) do
    {:noreply, maybe_refresh_user(socket, user)}
  end

  @impl true
  def handle_info({:user_unconfirmed, user}, socket) do
    {:noreply, maybe_refresh_user(socket, user)}
  end

  @impl true
  def handle_info({:user_deleted, user}, socket) do
    if user.uuid == socket.assigns.user.uuid do
      {:noreply,
       socket
       |> put_flash(:info, gettext("This user has been deleted"))
       |> push_navigate(to: Routes.path("/admin/users"))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:user_created, _user}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp maybe_refresh_user(socket, event_user) do
    if event_user.uuid == socket.assigns.user.uuid do
      case Auth.get_user_with_roles(event_user.uuid) do
        nil ->
          socket
          |> put_flash(:info, gettext("This user has been deleted"))
          |> push_navigate(to: Routes.path("/admin/users"))

        user ->
          assign(socket, :user, user)
      end
    else
      socket
    end
  end

  defp user_display_name(user) do
    cond do
      user.first_name && user.last_name ->
        "#{user.first_name} #{user.last_name}"

      user.first_name ->
        user.first_name

      user.username ->
        user.username

      true ->
        user.email
    end
  end

  defp format_location(user) do
    [user.registration_city, user.registration_region, user.registration_country]
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      location -> location
    end
  end

  defp format_timezone(nil), do: "Not set"

  defp format_timezone(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {num, _} -> format_timezone_offset(num)
      :error -> offset
    end
  end

  defp format_timezone(offset) when is_integer(offset), do: format_timezone_offset(offset)

  defp format_timezone_offset(offset) do
    sign = if offset >= 0, do: "+", else: ""
    "UTC#{sign}#{offset}"
  end

  defp get_custom_field_value(user, field_key) do
    case user.custom_fields do
      nil -> nil
      fields -> Map.get(fields, field_key)
    end
  end

  defp format_custom_field_value(nil, _type, _field_key), do: "-"
  defp format_custom_field_value("", _type, _field_key), do: "-"

  defp format_custom_field_value(value, "boolean", _field_key) do
    case value do
      true -> gettext("Yes")
      "true" -> gettext("Yes")
      false -> gettext("No")
      "false" -> gettext("No")
      _ -> to_string(value)
    end
  end

  defp format_custom_field_value(value, type, field_key)
       when type in ["select", "radio", "checkbox"] do
    CustomFields.get_option_text(field_key, value) || to_string(value)
  end

  defp format_custom_field_value(value, _type, _field_key), do: to_string(value)
end
