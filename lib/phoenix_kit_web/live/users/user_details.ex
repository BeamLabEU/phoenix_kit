defmodule PhoenixKitWeb.Live.Users.UserDetails do
  @moduledoc """
  LiveView for displaying detailed user information.

  Displays user profile information in a tabbed interface with:
  - Profile tab: Basic info, status, roles, registration details
  - Connections tab: Follower/following/connection stats (if enabled)
  - Notes tab: Admin notes about the user
  """
  use PhoenixKitWeb, :live_view

  # Imported per-LiveView rather than from `PhoenixKitWeb, :live_view`: a host
  # app that defines its own `row_link/1` would get an ambiguous import the
  # moment core wired this one in project-wide.
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  @compile {:no_warn_undefined, PhoenixKitUserConnections}
  # Guarded soft-dependency on the optional CRM module, same shape as the
  # PhoenixKitUserConnections guard above — core cannot hard-depend on it.
  @compile {:no_warn_undefined, [PhoenixKitCRM, PhoenixKitCRM.Contacts]}

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.AdminNote
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitWeb.Users.MultiSession

  @impl true
  def mount(%{"id" => user_uuid}, session, socket) do
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

        # Load connections stats if module is available and enabled
        {connections_enabled, connections_stats} =
          if Code.ensure_loaded?(PhoenixKitUserConnections) and
               PhoenixKitUserConnections.enabled?() do
            {true,
             %{
               followers: PhoenixKitUserConnections.followers_count(user),
               following: PhoenixKitUserConnections.following_count(user),
               connections: PhoenixKitUserConnections.connections_count(user),
               pending: PhoenixKitUserConnections.pending_requests_count(user),
               blocked: length(PhoenixKitUserConnections.list_blocked(user))
             }}
          else
            {false, nil}
          end

        # Root account of this session — who a "sign in as this user" would be
        # judged against. A User struct, so no session token enters the socket.
        impersonation_actor = MultiSession.impersonation_actor(session)

        crm_contact = load_crm_contact(socket, user)

        # Load admin notes
        admin_notes = Auth.list_admin_notes(user)

        # Load date/time format settings once, mirroring the Users list, so
        # Registered/Last Updated/Email Confirmed can show full date+time in
        # the admin's own timezone instead of the date-only
        # UtilsDate.format_datetime_with_user_format/1 (site timezone).
        date_time_settings =
          Settings.get_settings_cached(
            ["date_format", "time_format", "time_zone"],
            %{
              "date_format" => "Y-m-d",
              "time_format" => "H:i",
              "time_zone" => "0"
            }
          )

        geolocation_tracking_enabled =
          Settings.get_boolean_setting("track_registration_geolocation", false)

        # Organization accounts
        org_accounts_enabled =
          Settings.get_boolean_setting("enable_organization_accounts", false)

        organization_members =
          if org_accounts_enabled && user.account_type == "organization" do
            Auth.list_organization_members(user.uuid)
          else
            []
          end

        socket =
          socket
          |> assign(:user, user)
          |> assign(:page_title, user_display_name(user))
          |> assign(:page_section, gettext("Users"))
          |> assign(:page_section_path, Routes.path("/admin/users"))
          |> assign(:project_title, project_title)
          |> assign(:date_time_settings, date_time_settings)
          |> assign(:geolocation_tracking_enabled, geolocation_tracking_enabled)
          |> assign(:active_tab, "profile")
          |> assign(:custom_field_definitions, custom_field_definitions)
          |> assign(:show_delete_modal, false)
          |> assign(:connections_enabled, connections_enabled)
          |> assign(:connections_stats, connections_stats)
          |> assign(:crm_contact, crm_contact)
          |> assign(:impersonation_actor, impersonation_actor)
          |> assign(:admin_notes, admin_notes)
          |> assign(:note_form, to_form(Auth.change_admin_note(%AdminNote{})))
          |> assign(:editing_note_uuid, nil)
          |> assign(:org_accounts_enabled, org_accounts_enabled)
          |> assign(:organization_members, organization_members)
          |> assign(:show_role_modal, false)
          |> assign(:all_roles, Roles.list_roles())
          |> assign(:confirmation_modal, %{show: false})

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("show_delete_modal", _params, socket) do
    # Computed on open, not at mount — several count queries the ordinary
    # page render has no reason to pay for on every visit.
    socket =
      socket
      |> assign(:delete_preview, Auth.preview_user_deletion(socket.assigns.user))
      |> assign(:show_delete_modal, true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("hide_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  # Roles, confirmation, and active-status actions mirror the row menu on the
  # Users list (PhoenixKitWeb.Live.Users.Users) so every action offered there
  # is also available from this page — same context calls, same guard rails
  # (self-modification block, last-Owner protection via Roles.sync_user_roles/3).

  @impl true
  def handle_event("show_role_management", _params, socket) do
    current_user = socket.assigns.phoenix_kit_current_user
    user = socket.assigns.user

    if current_user.uuid == user.uuid do
      {:noreply, put_flash(socket, :error, gettext("Cannot modify your own roles"))}
    else
      {:noreply, assign(socket, :show_role_modal, true)}
    end
  end

  @impl true
  def handle_event("hide_role_management", _params, socket) do
    {:noreply, assign(socket, :show_role_modal, false)}
  end

  @impl true
  def handle_event("sync_user_roles", params, socket) do
    user = socket.assigns.user
    selected_roles = Map.get(params, "roles", %{})
    role_names = Map.values(selected_roles)
    actor = socket.assigns.phoenix_kit_current_user

    case Roles.sync_user_roles(user, role_names, actor: actor) do
      {:ok, %{roles_before: roles_before, roles_after: roles_after}} ->
        added = roles_after -- roles_before
        removed = roles_before -- roles_after

        if added != [] or removed != [] do
          log_roles_updated(actor, user, roles_before, roles_after, added, removed)
        end

        {:noreply,
         socket
         |> put_flash(:info, gettext("User roles updated successfully"))
         |> assign(:show_role_modal, false)
         |> assign(:user, Auth.get_user_with_roles(user.uuid))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_role_error_message(reason))}
    end
  end

  @impl true
  def handle_event(
        "request_status_toggle",
        %{"is_active" => is_active},
        socket
      ) do
    is_active_bool = is_active == "true"

    confirmation_modal = %{
      show: true,
      title: gettext("Confirm Status Change"),
      message:
        if(is_active_bool,
          do: gettext("Are you sure you want to deactivate this user?"),
          else: gettext("Are you sure you want to activate this user?")
        ),
      button_text: if(is_active_bool, do: gettext("Deactivate"), else: gettext("Activate")),
      action: "toggle_user_status"
    }

    {:noreply, assign(socket, :confirmation_modal, confirmation_modal)}
  end

  @impl true
  def handle_event(
        "request_confirmation_toggle",
        %{"is_confirmed" => is_confirmed},
        socket
      ) do
    is_confirmed_bool = is_confirmed == "true"

    confirmation_modal = %{
      show: true,
      title: gettext("Confirm Email Status Change"),
      message:
        if(is_confirmed_bool,
          do: gettext("Are you sure you want to unconfirm this user's email?"),
          else: gettext("Are you sure you want to confirm this user's email?")
        ),
      button_text: if(is_confirmed_bool, do: gettext("Unconfirm"), else: gettext("Confirm")),
      action: "toggle_user_confirmation"
    }

    {:noreply, assign(socket, :confirmation_modal, confirmation_modal)}
  end

  @impl true
  def handle_event("cancel_confirmation", _params, socket) do
    {:noreply, assign(socket, :confirmation_modal, %{show: false})}
  end

  @impl true
  def handle_event("confirm_action", %{"action" => action}, socket) do
    socket = assign(socket, :confirmation_modal, %{show: false})

    case action do
      "toggle_user_status" -> toggle_user_status_safely(socket)
      "toggle_user_confirmation" -> toggle_user_confirmation_safely(socket)
      _ -> {:noreply, socket}
    end
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

      # The rank refusals from `validate_admin_authority_over/2`.
      {:error, reason}
      when reason in [:insufficient_permissions, :target_is_owner, :target_is_staff] ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:error, gettext("You don't have permission to delete this user"))}

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
  def handle_event("edit_note", %{"uuid" => note_uuid}, socket) do
    note = Enum.find(socket.assigns.admin_notes, &(to_string(&1.uuid) == note_uuid))

    if note do
      changeset = Auth.change_admin_note(note)

      {:noreply,
       socket
       |> assign(:editing_note_uuid, note_uuid)
       |> assign(:note_form, to_form(changeset))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_note_uuid, nil)
     |> assign(:note_form, to_form(Auth.change_admin_note(%AdminNote{})))}
  end

  @impl true
  def handle_event("update_note", %{"admin_note" => note_params}, socket) do
    note_uuid = socket.assigns.editing_note_uuid
    note = Enum.find(socket.assigns.admin_notes, &(to_string(&1.uuid) == note_uuid))

    if note do
      case Auth.update_admin_note(note, note_params) do
        {:ok, _note} ->
          admin_notes = Auth.list_admin_notes(socket.assigns.user)

          {:noreply,
           socket
           |> assign(:admin_notes, admin_notes)
           |> assign(:editing_note_uuid, nil)
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
  def handle_event("delete_note", %{"uuid" => note_uuid}, socket) do
    note = Enum.find(socket.assigns.admin_notes, &(to_string(&1.uuid) == note_uuid))

    if note do
      admin = socket.assigns[:phoenix_kit_current_user]

      case Auth.delete_admin_note(note, admin) do
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

  @impl true
  def handle_event("remove_member", %{"uuid" => member_uuid}, socket) do
    # Only a member of THIS organization — the uuid comes from a client event
    # and `remove_from_organization/1` itself has no ownership check.
    case Enum.find(socket.assigns.organization_members, &(&1.uuid == member_uuid)) do
      nil -> {:noreply, socket}
      member -> remove_member(socket, member)
    end
  end

  defp remove_member(socket, member) do
    case Auth.remove_from_organization(member) do
      {:ok, _} ->
        members = Auth.list_organization_members(socket.assigns.user.uuid)

        {:noreply,
         socket
         |> assign(:organization_members, members)
         |> put_flash(:info, gettext("Member removed from organization"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove member"))}
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
          socket = assign(socket, :user, user)

          if socket.assigns.org_accounts_enabled && user.account_type == "organization" do
            assign(socket, :organization_members, Auth.list_organization_members(user.uuid))
          else
            socket
          end
      end
    else
      socket
    end
  end

  defp toggle_user_status_safely(socket) do
    user = socket.assigns.user
    new_status = !user.is_active

    case Auth.update_user_status(user, %{"is_active" => new_status},
           actor: socket.assigns.phoenix_kit_current_user
         ) do
      {:error, :insufficient_permissions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You don't have permission to change this user's status")
         )}

      {:ok, updated_user} ->
        status_text = if new_status, do: "activated", else: "deactivated"
        admin = socket.assigns.phoenix_kit_current_user

        PhoenixKit.Activity.log(%{
          action: "user.status_changed",
          module: "users",
          mode: "manual",
          actor_uuid: admin.uuid,
          resource_type: "user",
          resource_uuid: updated_user.uuid,
          target_uuid: updated_user.uuid,
          metadata: %{"status" => status_text, "actor_role" => "admin"}
        })

        flash_msg =
          if new_status,
            do: gettext("User activated successfully"),
            else: gettext("User deactivated successfully")

        {:noreply,
         socket
         |> put_flash(:info, flash_msg)
         |> assign(:user, Auth.get_user_with_roles(updated_user.uuid))}

      {:error, :cannot_deactivate_last_owner} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot deactivate the last system owner"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update user status"))}
    end
  end

  defp toggle_user_confirmation_safely(socket) do
    user = socket.assigns.user
    admin = socket.assigns.phoenix_kit_current_user

    case Auth.toggle_user_confirmation(user, actor: admin) do
      {:error, :insufficient_permissions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You don't have permission to change this user's confirmation")
         )}

      {:ok, updated_user} ->
        action =
          if updated_user.confirmed_at,
            do: "user.email_confirmed",
            else: "user.email_unconfirmed"

        PhoenixKit.Activity.log(%{
          action: action,
          module: "users",
          mode: "manual",
          actor_uuid: admin.uuid,
          resource_type: "user",
          resource_uuid: updated_user.uuid,
          target_uuid: updated_user.uuid,
          metadata: %{"method" => "manual", "actor_role" => "admin"}
        })

        email_flash_msg =
          if updated_user.confirmed_at,
            do: gettext("User email confirmed successfully"),
            else: gettext("User email unconfirmed successfully")

        {:noreply,
         socket
         |> put_flash(:info, email_flash_msg)
         |> assign(:user, Auth.get_user_with_roles(updated_user.uuid))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update user confirmation status"))}
    end
  end

  defp log_roles_updated(admin, user, current_roles, new_roles, added, removed) do
    metadata =
      %{"actor_role" => "admin"}
      |> maybe_put_role_diff("added", added)
      |> maybe_put_role_diff("removed", removed)
      |> Map.put("roles_from", Enum.join(Enum.sort(current_roles), ", "))
      |> Map.put("roles_to", Enum.join(Enum.sort(new_roles), ", "))

    PhoenixKit.Activity.log(%{
      action: "user.roles_updated",
      module: "users",
      mode: "manual",
      actor_uuid: admin.uuid,
      resource_type: "user",
      resource_uuid: user.uuid,
      target_uuid: user.uuid,
      metadata: metadata
    })
  end

  defp maybe_put_role_diff(map, _key, []), do: map
  defp maybe_put_role_diff(map, key, roles), do: Map.put(map, key, Enum.join(roles, ", "))

  defp format_role_error_message(reason) do
    case reason do
      :cannot_remove_last_owner -> gettext("Cannot remove the last system owner")
      :owner_role_protected -> gettext("Owner role cannot be assigned manually")
      :role_not_found -> gettext("Role not found")
      _ -> gettext("Failed to update user role")
    end
  end

  defp target_is_owner?(user), do: Enum.any?(user.roles || [], &(&1.name == "Owner"))

  # The linked CRM contact for this user, when the optional CRM module is
  # installed and enabled. Guarded like the connections stats in mount/3: core
  # has no hard dependency on phoenix_kit_crm.
  #
  # The viewer's own `crm` permission is part of the guard. Every admin route
  # shares one live_session, so reaching this page only proves the viewer can
  # reach the admin area at all; the CRM contact page is separately gated by
  # `enforce_admin_view_permission/2`. Without the check, a role holding `users`
  # but not `crm` would read a contact's name here and then be bounced back to
  # "/" on clicking through.
  defp load_crm_contact(socket, user) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "crm") &&
         Code.ensure_loaded?(PhoenixKitCRM) && PhoenixKitCRM.enabled?() do
      PhoenixKitCRM.Contacts.get_by_user_uuid(user.uuid)
    end
  end

  # Mirrors PhoenixKitCRM.Schemas.Contact.display_name/1 without reaching into
  # the optional module: `name` is nullable in phoenix_kit_crm_contacts, and a
  # nil there would render the card's only link as empty text.
  defp crm_contact_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp crm_contact_label(%{email: email}) when is_binary(email) and email != "", do: email
  defp crm_contact_label(_contact), do: gettext("Unnamed contact")

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

  # Full date+time (in the admin's own timezone), for the Account Information
  # card where there's room — unlike the Users list's compact date-only
  # columns, and unlike UtilsDate.format_datetime_with_user_format/1 (despite
  # the name, it drops the time, and it shows the site's timezone rather than
  # the admin's own).
  defp format_datetime(nil, _current_user, _date_time_settings), do: "-"

  defp format_datetime(dt, current_user, date_time_settings) do
    date = UtilsDate.format_date_with_user_timezone_cached(dt, current_user, date_time_settings)
    time = UtilsDate.format_time_with_user_timezone_cached(dt, current_user, date_time_settings)
    "#{date} #{time}"
  end

  defp format_location(user) do
    [
      user.registration_city,
      user.registration_region,
      CountryData.country_name(user.registration_country)
    ]
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      location -> location
    end
  end

  defp format_timezone(nil), do: gettext("Not set")

  defp format_timezone(value) when is_binary(value) do
    # One label source, so an admin looking at a user's timezone reads the same
    # text the user picked it by — an IANA identifier now, or the fixed offset
    # an older account still holds.
    TimeZone.label(value)
  end

  defp format_timezone(offset) when is_number(offset), do: format_timezone_offset(offset)

  defp format_timezone_offset(offset) do
    sign = if offset >= 0, do: "+", else: ""

    trimmed =
      (offset * 1.0)
      |> :erlang.float_to_binary(decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    "UTC#{sign}#{trimmed}"
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
      _ -> CustomFields.printable(value)
    end
  end

  defp format_custom_field_value(value, type, field_key)
       when type in ["select", "radio", "checkbox"] do
    CustomFields.get_option_text(field_key, value) || CustomFields.printable(value)
  end

  # `custom_fields` is free-form JSONB, so a value can be a map or a list — the
  # media browser stores `media_expanded_folders` as a list and the etcher stores
  # `etcher_line_params` as a map. `to_string/1` raises Protocol.UndefinedError on
  # a map, which took the whole user page down with a 500 for any user who had
  # ever used those features. `CustomFields.printable/1` is shared with the admin
  # edit form, which has to make the same values safe (issue #780).
  defp format_custom_field_value(value, _type, _field_key), do: CustomFields.printable(value)
end
