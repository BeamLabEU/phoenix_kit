defmodule PhoenixKitWeb.Live.Users.Users do
  @moduledoc """
  User management LiveView for PhoenixKit admin panel.

  Provides comprehensive user management including listing, search, role assignment, and status updates.
  """
  use PhoenixKitWeb, :live_view

  # Search, role/type filters and page live in the query string, so a filtered
  # list is a real URL: shareable, reload-proof, and Back returns to the
  # previous query instead of leaving the page. `role` and `account_type`
  # default to "all", which is therefore what gets omitted from the URL.
  use PhoenixKitWeb.Live.UrlState,
    params: [
      search_query: [default: "", url_key: "q", alias: "search"],
      filter_role: [default: "all", url_key: "role"],
      filter_account_type: [default: "all", url_key: "account_type"],
      # Deep-linked from the admin dashboard's user cards, so each number there
      # opens the list behind it. Values mirror the predicates
      # `Roles.get_extended_stats/0` counts with.
      filter_status: [default: "all", url_key: "status"],
      filter_confirmation: [default: "all", url_key: "confirmation"],
      page: [default: 1, cast: :integer, min: 1],
      # Rows per page, picked with <.page_size_selector>. Allowlisted rather
      # than bounded: an arbitrary integer out of the URL is a LIMIT clause.
      per_page: [default: 10, cast: :integer, in: [10, 25, 50, 100]],
      # The selector's "Auto" mode (pilot on this tab only): the client
      # measures the viewport and pushes the per_page that fits. Only the
      # flag lives here — the size it resolved to is `per_page` as usual, so
      # the URL stays fully self-describing.
      auto_fit: [default: false, cast: :boolean, url_key: "fit"]
    ]

  # Imported per-LiveView rather than from `PhoenixKitWeb, :live_view`: a host
  # app that defines its own `row_link/1` would get an ambiguous import the
  # moment core wired this one in project-wide.
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.{CustomFields, Roles, TableColumns}
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.TableColumns, as: ColumnPrefs
  alias PhoenixKitWeb.Users.MultiSession

  @max_cell_length 20

  # Per-admin grid/list preference for the users table, persisted in the
  # current user's custom_fields (mirrors the media browser's view toggle).
  @view_mode_key "users_view_mode"

  def mount(_params, session, socket) do
    # Who a "sign in as this user" from this page would be judged against: the
    # session's ROOT account, not whichever account is currently active. Held
    # as a User struct, so no session token lands in the socket.
    impersonation_actor = MultiSession.impersonation_actor(session)

    # Subscribe to user events for live updates
    if connected?(socket) do
      Events.subscribe_to_users()
      Events.subscribe_to_stats()
      # A custom field added or deleted changes the columns offered.
      CustomFields.Events.subscribe()
    end

    # Get project title from settings
    project_title = Settings.get_project_title()

    # Load date/time format settings once for performance optimization
    # Use batch cached call for maximum efficiency
    date_time_settings =
      Settings.get_settings_cached(
        ["date_format", "time_format", "time_zone"],
        %{
          "date_format" => "Y-m-d",
          "time_format" => "H:i",
          "time_zone" => "0"
        }
      )

    # :page, :per_page, :search_query, :filter_role and :filter_account_type
    # are assigned from the query string by UrlState before mount/3 runs —
    # re-assigning them here would overwrite a shared link's state with the
    # defaults.
    socket =
      socket
      |> assign(:impersonation_actor, impersonation_actor)
      # The rank predicates in the row menu ask the actor's roles once per row.
      # The plug-supplied `@phoenix_kit_current_user` carries no `:roles`
      # preload, so each of those questions is a query; loading the actor once
      # here answers all of them from memory. See `Auth.can_manage_user_status?/2`.
      |> assign(:actor_with_roles, actor_with_roles(socket))
      |> assign(:show_search, socket.assigns.search_query != "")
      |> assign(:view_mode, load_user_view_mode(socket.assigns[:phoenix_kit_current_user]))
      |> assign(
        :org_accounts_enabled,
        Settings.get_boolean_setting("enable_organization_accounts", false)
      )
      |> assign(
        :geolocation_tracking_enabled,
        Settings.get_boolean_setting("track_registration_geolocation", false)
      )
      |> assign(:show_role_modal, false)
      |> assign(:managing_user, nil)
      |> assign(:user_roles, [])
      |> assign(:all_roles, [])
      |> assign(:manageable_roles, [])
      |> assign(:confirmation_modal, %{show: false})
      |> assign(:show_column_modal, false)
      |> assign(:page_title, gettext("Users"))
      |> assign(:project_title, project_title)
      |> assign(:date_time_settings, date_time_settings)
      |> assign_columns()
      |> load_stats()

    {:ok, socket}
  end

  # Falls back to the plug-supplied struct if the actor cannot be re-read, so a
  # missing preload degrades to the queried path rather than to no actor.
  defp actor_with_roles(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} = current_user -> Auth.get_user_with_roles(uuid) || current_user
      other -> other
    end
  end

  # The list is loaded here rather than in mount/3: UrlState calls this after
  # mount and on every change to the query string, so one code path serves the
  # first render, a shared link, and the Back button alike.
  #
  # Deliberately not annotated with @impl — a single @impl anywhere in a module
  # makes Elixir demand it on every other callback too, and this LiveView's
  # mount/handle_event/handle_params/handle_info carry none.
  def handle_url_state(_state, socket), do: load_users(socket)

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

  # `replace: true` — the box is debounced, so a typed-out query would otherwise
  # leave one history entry per pause and Back would walk the search string
  # backwards instead of leaving the page.
  def handle_event("search", %{"search" => search_query}, socket) do
    {:noreply, push_url_state(socket, [search_query: search_query], replace: true)}
  end

  # Toggle the collapsed search row open/closed (mirrors the media browser).
  def handle_event("toggle_search", _params, socket) do
    {:noreply, assign(socket, :show_search, !socket.assigns.show_search)}
  end

  # Clear the query and close the search row (the ✕ button). Clearing is a
  # deliberate action, so it earns a real history entry.
  def handle_event("clear_search", _params, socket) do
    socket =
      socket
      |> assign(:show_search, false)
      |> push_url_state(search_query: "")

    {:noreply, socket}
  end

  # Collapse the search row on blur, but only while it is empty.
  def handle_event("close_search_if_empty", _params, socket) do
    {:noreply, assign(socket, :show_search, socket.assigns.search_query != "")}
  end

  # Switch between the table and card views, persisting the choice on the
  # current user so it survives reloads (mirrors the media browser).
  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ["card", "table"] do
    user = persist_user_view_mode(socket.assigns[:phoenix_kit_current_user], mode)

    {:noreply,
     socket
     |> assign(:phoenix_kit_current_user, user)
     |> assign(:view_mode, mode)}
  end

  def handle_event("filter_by_role", %{"role" => role}, socket) do
    {:noreply, push_url_state(socket, filter_role: role)}
  end

  def handle_event("filter_by_account_type", %{"account_type" => account_type}, socket) do
    {:noreply, push_url_state(socket, filter_account_type: account_type)}
  end

  def handle_event("filter_by_status", %{"status" => status}, socket) do
    {:noreply, push_url_state(socket, filter_status: status)}
  end

  def handle_event("filter_by_confirmation", %{"confirmation" => confirmation}, socket) do
    {:noreply, push_url_state(socket, filter_confirmation: confirmation)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, reset_url_state(socket)}
  end

  # Picking "Auto" only raises the flag; the PageSizeAutoFit hook then
  # measures and pushes the size it fits, tagged `auto: "1"` so the flag
  # survives. A number picked by hand lowers it. Either way `push_url_state`
  # resets the page: page 7 of 10 rows is not page 7 of 100.
  def handle_event("change_per_page", %{"per_page" => "auto"}, socket) do
    {:noreply, push_url_state(socket, auto_fit: true)}
  end

  def handle_event("change_per_page", %{"per_page" => per_page} = params, socket) do
    case {Integer.parse(per_page), Map.has_key?(params, "auto")} do
      {{per_page, ""}, true} ->
        {:noreply, push_url_state(socket, per_page: per_page)}

      {{per_page, ""}, false} ->
        {:noreply, push_url_state(socket, per_page: per_page, auto_fit: false)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_role_management", %{"user_uuid" => user_uuid}, socket) do
    user = Auth.get_user!(user_uuid)
    current_user = socket.assigns.phoenix_kit_current_user

    # Prevent self-modification for critical operations
    if current_user.uuid == user.uuid do
      socket = put_flash(socket, :error, gettext("Cannot modify your own roles"))
      {:noreply, socket}
    else
      # Get fresh user with preloaded roles to ensure accurate state
      user_with_roles = Auth.get_user_with_roles(user.uuid)

      user_roles = Roles.get_user_roles(user_with_roles)
      all_roles = Roles.list_roles()

      socket =
        socket
        |> assign(:managing_user, user_with_roles)
        |> assign(:user_roles, user_roles)
        |> assign(:all_roles, all_roles)
        # The roles this admin may give or take away (`Roles.can_manage_role?/2`);
        # the rest render locked. The context checks again on save.
        |> assign(:manageable_roles, Roles.manageable_role_names(current_user))
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

  def handle_event("sync_user_roles", params, socket) do
    user = socket.assigns.managing_user
    selected_roles = Map.get(params, "roles", %{})
    role_names = Map.values(selected_roles)
    actor = socket.assigns.phoenix_kit_current_user

    case Roles.sync_user_roles(user, role_names, actor: actor) do
      {:ok, %{roles_before: roles_before, roles_after: roles_after} = result} ->
        admin = socket.assigns.phoenix_kit_current_user

        # Audit the exact delta this transaction applied — the context captures
        # before/after inside the transaction and silently drops changes the
        # actor isn't authorized to make (and preserves the last Owner), so the
        # applied delta can differ from what was submitted.
        added = roles_after -- roles_before
        removed = roles_before -- roles_after

        if added != [] or removed != [] do
          log_roles_updated(admin, user, roles_before, roles_after, added, removed)
        end

        case Map.get(result, :refused, []) do
          [] ->
            socket =
              socket
              |> put_flash(:info, gettext("User roles updated successfully"))
              |> assign(:show_role_modal, false)
              |> assign(:managing_user, nil)
              |> assign(:user_roles, [])
              |> assign(:all_roles, [])
              |> load_users()
              |> load_stats()

            {:noreply, socket}

          refused ->
            # Part of the request was not allowed: say which, and keep the
            # modal open on the real state.
            {:noreply,
             socket
             |> put_flash(:error, refused_roles_message(refused))
             |> assign(:managing_user, Auth.get_user_with_roles(user.uuid))
             |> assign(:user_roles, roles_after)
             |> load_users()}
        end

      {:error, reason} ->
        error_msg =
          case reason do
            :cannot_remove_last_owner -> gettext("Cannot remove the last system owner")
            :owner_role_protected -> gettext("Owner role cannot be assigned manually")
            :cannot_modify_own_roles -> gettext("Cannot modify your own roles")
            _ -> gettext("Failed to update user roles")
          end

        # Refresh the modal data on error to show current state
        user_with_roles = Auth.get_user_with_roles(user.uuid)
        updated_user_roles = Roles.get_user_roles(user_with_roles)

        socket =
          socket
          |> put_flash(:error, error_msg)
          |> assign(:managing_user, user_with_roles)
          |> assign(:user_roles, updated_user_roles)

        {:noreply, socket}
    end
  end

  def handle_event(
        "quick_toggle_role",
        %{"user_uuid" => user_uuid, "role_name" => role_name},
        socket
      ) do
    user = Auth.get_user!(user_uuid)
    current_user = socket.assigns.phoenix_kit_current_user

    # Prevent self-modification
    if current_user.uuid == user.uuid do
      socket = put_flash(socket, :error, gettext("Cannot modify your own roles"))
      {:noreply, socket}
    else
      handle_role_toggle_result(
        toggle_user_role(user, role_name, current_user),
        role_name,
        socket
      )
    end
  end

  # New events for confirmation modal
  def handle_event(
        "request_status_toggle",
        %{"user_uuid" => user_uuid, "is_active" => is_active},
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
      action: "toggle_user_status",
      user_uuid: user_uuid
    }

    {:noreply, assign(socket, :confirmation_modal, confirmation_modal)}
  end

  def handle_event(
        "request_confirmation_toggle",
        %{"user_uuid" => user_uuid, "is_confirmed" => is_confirmed},
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
      action: "toggle_user_confirmation",
      user_uuid: user_uuid
    }

    {:noreply, assign(socket, :confirmation_modal, confirmation_modal)}
  end

  def handle_event("cancel_confirmation", _params, socket) do
    {:noreply, assign(socket, :confirmation_modal, %{show: false})}
  end

  def handle_event("confirm_action", %{"action" => action, "user_uuid" => user_uuid}, socket) do
    # Close modal first
    socket = assign(socket, :confirmation_modal, %{show: false})

    # Execute the confirmed action
    case action do
      "toggle_user_status" ->
        handle_toggle_user_status(%{"user_uuid" => user_uuid}, socket)

      "toggle_user_confirmation" ->
        handle_toggle_user_confirmation(%{"user_uuid" => user_uuid}, socket)

      _ ->
        {:noreply, socket}
    end
  end

  # Keep old handlers for backward compatibility, but make them delegate to private handlers
  def handle_event("toggle_user_status", %{"user_uuid" => user_uuid}, socket) do
    handle_toggle_user_status(%{"user_uuid" => user_uuid}, socket)
  end

  def handle_event("toggle_user_confirmation", %{"user_uuid" => user_uuid}, socket) do
    handle_toggle_user_confirmation(%{"user_uuid" => user_uuid}, socket)
  end

  # Columns: each admin's own, saved as they change (the live modal has no
  # Apply step). The site-wide `user_table_columns` setting is the default
  # for an admin who has not chosen.
  def handle_event("show_column_modal", _params, socket),
    do: {:noreply, assign(socket, :show_column_modal, true)}

  def handle_event("hide_column_modal", _params, socket),
    do: {:noreply, assign(socket, :show_column_modal, false)}

  def handle_event(event, params, socket)
      when event in ~w(add_column remove_column reorder_columns reset_columns) do
    socket =
      ColumnPrefs.handle_event(event, params, socket, socket.assigns.column_spec, :columns)

    {:noreply, assign(socket, :selected_columns, socket.assigns.columns ++ ["actions"])}
  end

  # Keep the original handlers private for internal use
  defp handle_toggle_user_status(%{"user_uuid" => user_uuid}, socket) do
    current_user = socket.assigns.phoenix_kit_current_user
    user = Auth.get_user!(user_uuid)

    if current_user.uuid == user.uuid do
      socket = put_flash(socket, :error, gettext("Cannot modify your own status"))
      {:noreply, socket}
    else
      toggle_user_status_safely(socket, user)
    end
  end

  defp handle_toggle_user_confirmation(%{"user_uuid" => user_uuid}, socket) do
    current_user = socket.assigns.phoenix_kit_current_user
    user = Auth.get_user!(user_uuid)

    if current_user.uuid == user.uuid do
      socket = put_flash(socket, :error, gettext("Cannot modify your own confirmation status"))
      {:noreply, socket}
    else
      toggle_user_confirmation_safely(socket, user)
    end
  end

  defp toggle_user_status_safely(socket, user) do
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

        socket =
          socket
          |> put_flash(:info, flash_msg)
          |> load_users()
          |> load_stats()

        {:noreply, socket}

      {:error, :cannot_deactivate_last_owner} ->
        socket = put_flash(socket, :error, gettext("Cannot deactivate the last system owner"))
        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update user status"))
        {:noreply, socket}
    end
  end

  defp toggle_user_confirmation_safely(socket, user) do
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

        socket =
          socket
          |> put_flash(:info, email_flash_msg)
          |> load_users()
          |> load_stats()

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update user confirmation status"))
        {:noreply, socket}
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

  defp load_users(socket) do
    params = [
      page: socket.assigns.page,
      page_size: socket.assigns.per_page,
      search: socket.assigns.search_query,
      role: socket.assigns.filter_role,
      account_type: socket.assigns.filter_account_type,
      status: socket.assigns.filter_status,
      confirmation: socket.assigns.filter_confirmation
    ]

    %{users: users, total_count: total_count, total_pages: total_pages} =
      Auth.list_users_paginated(params)

    # Force refresh by clearing users first, then setting new ones
    # This ensures LiveView doesn't reuse stale user objects with cached roles
    socket
    |> assign(:users, [])
    |> assign(:users, users)
    |> assign(
      :impersonable_uuids,
      MultiSession.impersonable_uuids(socket.assigns[:impersonation_actor], users)
    )
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

  # Read the per-user table/card preference from custom_fields, defaulting to
  # "table". Tolerant of a missing/garbage value.
  defp load_user_view_mode(%User{} = user) do
    case Auth.get_user_field(user, @view_mode_key) do
      mode when mode in ["card", "table"] -> mode
      _ -> "table"
    end
  end

  defp load_user_view_mode(_), do: "table"

  # Persist the preference into a freshly-read custom_fields copy so a
  # concurrent change elsewhere isn't clobbered. Returns the updated user (or
  # the original on no-user / error) for the caller to re-assign.
  defp persist_user_view_mode(%{uuid: uuid} = user, mode) when is_binary(uuid) do
    fresh = Auth.get_user(uuid) || user
    merged = Map.put(fresh.custom_fields || %{}, @view_mode_key, mode)

    # Internal view preference: skip the custom-field-definition registration
    # (so it never surfaces in the column customizer) and the profile-update
    # broadcast (so toggling the view doesn't reload the list for every admin).
    case Auth.update_user_custom_fields(fresh, merged,
           ensure_definitions: false,
           broadcast: false
         ) do
      {:ok, updated} -> updated
      {:error, _} -> user
    end
  end

  defp persist_user_view_mode(user, _mode), do: user

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

  # Route through sync_user_roles/3 so the quick toggle enforces the SAME actor
  # authorization + last-Owner guard as the full role modal — a `users`-permission
  # holder can't use this shortcut to grant Owner/Admin or wipe the last Owner.
  # Unauthorized system-role changes are silently dropped by the context, so we
  # re-read the actual role set to report what truly happened.
  defp toggle_user_role(user, role_name, actor) do
    had_role? = user_has_role?(user, role_name)

    desired_roles =
      if had_role?,
        do: get_user_roles(user) -- [role_name],
        else: [role_name | get_user_roles(user)]

    case Roles.sync_user_roles(user, desired_roles, actor: actor) do
      {:ok, %{roles_after: roles_after}} ->
        now_has? = role_name in roles_after

        cond do
          now_has? and not had_role? -> {:ok, :added}
          not now_has? and had_role? -> {:ok, :removed}
          true -> {:ok, :unchanged}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_role_toggle_result(result, role_name, socket) do
    case result do
      {:ok, :unchanged} ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("You are not allowed to change the %{role} role", role: role_name)
          )

        {:noreply, socket}

      {:ok, action} ->
        role_flash_msg =
          if action == :added,
            do: gettext("Role %{role} added to user successfully", role: role_name),
            else: gettext("Role %{role} removed from user successfully", role: role_name)

        socket =
          socket
          |> put_flash(:info, role_flash_msg)
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
      :cannot_remove_last_owner -> gettext("Cannot remove the last system owner")
      :owner_role_protected -> gettext("Owner role cannot be assigned manually")
      :role_not_found -> gettext("Role not found")
      :cannot_modify_own_roles -> gettext("Cannot modify your own roles")
      _ -> gettext("Failed to update user role")
    end
  end

  defp refused_roles_message(refused) do
    gettext(
      "Not changed — you can only give or take away roles whose permissions you hold: %{roles}",
      roles: Enum.join(refused, ", ")
    )
  end

  # Optimized function using preloaded roles - used in template conditionals
  def get_primary_role_name_unsafe(user) do
    roles = get_user_roles(user)

    cond do
      "Owner" in roles -> "Owner"
      "Admin" in roles -> "Admin"
      true -> "User"
    end
  end

  # Card view helpers

  def build_card_fields(
        user,
        selected_columns,
        current_user,
        date_time_settings,
        geolocation_tracking_enabled
      ) do
    selected_columns
    |> Enum.reject(&(&1 in ["email", "actions"]))
    |> Enum.filter(&should_render_column?/1)
    |> Enum.map(fn column_id ->
      label = render_column_header(column_id) || column_id

      value =
        build_card_field_value(
          user,
          column_id,
          current_user,
          date_time_settings,
          geolocation_tracking_enabled
        )

      %{label: label, value: value}
    end)
  end

  defp build_card_field_value(
         user,
         column_id,
         current_user,
         date_time_settings,
         geolocation_tracking_enabled
       ) do
    case column_id do
      "full_name" -> card_full_name(user)
      "role" -> card_roles(user)
      "status" -> card_status(user)
      "registered" -> card_datetime(user.inserted_at, current_user, date_time_settings)
      "last_confirmed" -> card_confirmed_at(user.confirmed_at, current_user, date_time_settings)
      "location" -> card_location(user, geolocation_tracking_enabled)
      _ -> render_column_cell(user, column_id, current_user, date_time_settings)
    end
  end

  defp card_full_name(user) do
    case User.full_name(user) do
      nil -> "-"
      "" -> "-"
      name -> name
    end
  end

  defp card_roles(user) do
    roles = get_user_roles(user)
    if Enum.empty?(roles), do: gettext("No roles"), else: Enum.join(roles, ", ")
  end

  defp card_status(user) do
    confirmation =
      if user.confirmed_at, do: gettext("Email Confirmed"), else: gettext("Email Pending")

    active = if user.is_active, do: gettext("Active"), else: gettext("Inactive")
    "#{confirmation} / #{active}"
  end

  defp card_datetime(nil, _current_user, _date_time_settings), do: "-"

  defp card_datetime(dt, current_user, date_time_settings) do
    date = UtilsDate.format_date_with_user_timezone_cached(dt, current_user, date_time_settings)
    time = UtilsDate.format_time_with_user_timezone_cached(dt, current_user, date_time_settings)
    "#{date} #{time}"
  end

  defp card_confirmed_at(nil, _current_user, _date_time_settings), do: gettext("Never")

  defp card_confirmed_at(dt, current_user, date_time_settings) do
    date = UtilsDate.format_date_with_user_timezone_cached(dt, current_user, date_time_settings)
    time = UtilsDate.format_time_with_user_timezone_cached(dt, current_user, date_time_settings)
    "#{date} #{time}"
  end

  defp card_location(_user, false), do: gettext("Tracking disabled")

  defp card_location(user, true) do
    parts =
      [
        CountryData.country_name(user.registration_country),
        user.registration_region,
        user.registration_city
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    if Enum.empty?(parts), do: "-", else: Enum.join(parts, " · ")
  end

  # Column rendering helpers
  def render_column_header(column_id) do
    case TableColumns.get_column_metadata(column_id) do
      %{label: label} -> label
      # Return nil for deleted custom fields
      nil -> nil
      _ -> String.capitalize(String.replace(column_id, "_", " "))
    end
  end

  # Helper to check if column should be rendered (filters out deleted custom fields)
  def should_render_column?(column_id) do
    # Always render "actions" column
    column_id == "actions" || TableColumns.get_column_metadata(column_id) != nil
  end

  # Per-column responsive class for the table view. On mobile (table-fixed)
  # only the email + actions columns are shown — the rest collapse — so the
  # list reads as a compact row (avatar/email/name + a `…` menu) like the
  # media browser. The actions column is pinned narrow and right-aligned at all
  # sizes so the `…` menu always sits at the far-right edge (with the cell's
  # padding) instead of drifting into a wide auto-width cell when columns are
  # hidden.
  def mobile_col_class("actions"), do: "w-12 text-right"
  def mobile_col_class("email"), do: ""
  def mobile_col_class(_), do: "hidden md:table-cell"

  # Text truncation helper - limits display to max_length characters with ellipsis
  defp truncate_text(nil, _max_length), do: "-"
  defp truncate_text("", _max_length), do: "-"

  defp truncate_text(text, max_length) when is_binary(text) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length) <> "..."
    end
  end

  # `custom_fields` is free-form JSONB, so a custom-field column can hold a map
  # or a list. `to_string/1` raises `Protocol.UndefinedError` on a map — a 500 on
  # the whole users list for anyone with that column switched on — and silently
  # concatenates a list into one unreadable run. Same treatment as the edit form
  # and the user page (issue #780).
  defp truncate_text(value, max_length) when is_map(value) or is_list(value) do
    truncate_text(CustomFields.printable(value), max_length)
  end

  defp truncate_text(value, max_length) do
    truncate_text(to_string(value), max_length)
  end

  def render_column_cell(user, column_id, current_user, date_time_settings) do
    case TableColumns.get_column_metadata(column_id) do
      %{type: type} = metadata ->
        render_cell_by_type(type, metadata, user, column_id, current_user, date_time_settings)

      _ ->
        render_default_cell(user, column_id)
    end
  end

  defp render_cell_by_type(
         :email,
         _metadata,
         user,
         _column_id,
         _current_user,
         _date_time_settings
       ) do
    truncate_text(User.delivery_email(user) || "", @max_cell_length)
  end

  defp render_cell_by_type(
         :string,
         _metadata,
         user,
         column_id,
         _current_user,
         _date_time_settings
       ) do
    render_string_cell(user, column_id)
  end

  defp render_cell_by_type(
         :composite,
         _metadata,
         user,
         column_id,
         _current_user,
         _date_time_settings
       ) do
    render_composite_cell(user, column_id)
  end

  defp render_cell_by_type(
         :roles,
         _metadata,
         user,
         _column_id,
         _current_user,
         _date_time_settings
       ) do
    get_primary_role_name_unsafe(user)
  end

  defp render_cell_by_type(
         :status,
         _metadata,
         user,
         _column_id,
         _current_user,
         _date_time_settings
       ) do
    if user.is_active, do: gettext("Active"), else: gettext("Inactive")
  end

  defp render_cell_by_type(
         :datetime,
         _metadata,
         user,
         column_id,
         current_user,
         date_time_settings
       ) do
    render_datetime_cell(user, column_id, current_user, date_time_settings)
  end

  defp render_cell_by_type(
         :location,
         _metadata,
         user,
         column_id,
         _current_user,
         _date_time_settings
       ) do
    render_location_cell(user, column_id)
  end

  defp render_cell_by_type(
         :custom_field,
         %{field_type: field_type},
         user,
         column_id,
         _current_user,
         _date_time_settings
       ) do
    render_custom_field_cell(user, column_id, field_type)
  end

  defp render_cell_by_type(_type, _metadata, user, column_id, _current_user, _date_time_settings) do
    render_default_cell(user, column_id)
  end

  defp render_string_cell(user, column_id) do
    field = get_user_field(user, column_id)
    if field, do: truncate_text(field, @max_cell_length), else: "-"
  end

  defp render_composite_cell(user, "full_name") do
    truncate_text(User.full_name(user), @max_cell_length)
  end

  defp render_composite_cell(_user, _column_id), do: "-"

  defp render_datetime_cell(user, column_id, current_user, date_time_settings) do
    field = get_user_field(user, column_id)

    if field do
      formatted =
        UtilsDate.format_datetime_with_user_timezone_cached(
          field,
          current_user,
          date_time_settings
        )

      truncate_text(formatted, @max_cell_length)
    else
      "-"
    end
  end

  defp render_location_cell(user, column_id) do
    field = get_user_field(user, column_id)
    if field && field != "", do: truncate_text(field, @max_cell_length), else: "-"
  end

  defp render_default_cell(user, column_id) do
    field = get_user_field(user, column_id)
    if field, do: truncate_text(field, @max_cell_length), else: "-"
  end

  defp get_user_field(user, column_id) do
    case column_id do
      "username" -> user.username
      "email" -> User.delivery_email(user)
      "first_name" -> user.first_name
      "last_name" -> user.last_name
      "inserted_at" -> user.inserted_at
      "confirmed_at" -> user.confirmed_at
      "registration_country" -> user.registration_country
      _ -> "-"
    end
  end

  defp render_custom_field_cell(user, column_id, field_type) do
    # Extract field key from column_id (e.g., "custom_phone" -> "phone")
    field_key = String.replace_prefix(column_id, "custom_", "")

    case get_custom_field_value(user, field_key) do
      nil -> "-"
      value -> format_custom_field_value(value, field_type)
    end
  end

  defp get_custom_field_value(user, field_key) do
    case user.custom_fields do
      %{} = custom_fields -> Map.get(custom_fields, field_key)
      _ -> nil
    end
  end

  defp format_custom_field_value(value, "boolean"), do: format_boolean_value(value)
  defp format_custom_field_value(value, "number"), do: format_number_value(value)
  defp format_custom_field_value(value, "date"), do: format_date_value(value)
  defp format_custom_field_value(value, "datetime"), do: format_datetime_value(value)
  defp format_custom_field_value(value, "select"), do: truncate_text(value, @max_cell_length)
  defp format_custom_field_value(value, "radio"), do: truncate_text(value, @max_cell_length)
  defp format_custom_field_value(value, "checkbox"), do: format_checkbox_value(value)
  defp format_custom_field_value(value, _), do: format_default_value(value)

  defp format_boolean_value(true), do: gettext("Yes")
  defp format_boolean_value(false), do: gettext("No")
  defp format_boolean_value("true"), do: gettext("Yes")
  defp format_boolean_value("false"), do: gettext("No")
  defp format_boolean_value(_), do: "-"

  defp format_number_value(value) when is_number(value) or is_binary(value),
    do: truncate_text(value, @max_cell_length)

  defp format_number_value(_), do: "-"

  defp format_date_value(%Date{} = date),
    do: truncate_text(Date.to_string(date), @max_cell_length)

  defp format_date_value(string) when is_binary(string),
    do: truncate_text(string, @max_cell_length)

  defp format_date_value(_), do: "-"

  defp format_datetime_value(%DateTime{} = dt),
    do: truncate_text(DateTime.to_string(dt), @max_cell_length)

  defp format_datetime_value(string) when is_binary(string),
    do: truncate_text(string, @max_cell_length)

  defp format_datetime_value(_), do: "-"

  defp format_checkbox_value(true), do: gettext("Yes")
  defp format_checkbox_value(false), do: gettext("No")
  defp format_checkbox_value("true"), do: gettext("Yes")
  defp format_checkbox_value("false"), do: gettext("No")

  defp format_checkbox_value(list) when is_list(list),
    do: truncate_text(CustomFields.printable(list), @max_cell_length)

  defp format_checkbox_value(value), do: truncate_text(value, @max_cell_length)

  defp format_default_value(value) when not is_nil(value) and value != "",
    do: truncate_text(value, @max_cell_length)

  defp format_default_value(_), do: "-"

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

  def handle_info({:user_deleted, deleted_user}, socket) do
    # Remove the deleted user from the list
    users = Enum.reject(socket.assigns.users, fn u -> u.uuid == deleted_user.uuid end)

    socket =
      socket
      |> assign(:users, users)
      |> assign(:total_count, socket.assigns.total_count - 1)
      |> load_stats()
      |> put_flash(:info, gettext("User deleted successfully"))

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

  # A custom field added, changed or deleted changes what the table offers;
  # the admin's saved choice is read again, never rewritten here (a deleted
  # field's column simply stops showing).
  def handle_info({:custom_field_deleted, _field_key}, socket),
    do: {:noreply, assign_columns(socket)}

  def handle_info(:custom_fields_changed, socket), do: {:noreply, assign_columns(socket)}

  defp assign_columns(socket) do
    spec = TableColumns.columns_spec()
    columns = ColumnPrefs.load(Actor.uuid(socket), spec)

    socket
    |> assign(:column_spec, spec)
    |> assign(:columns, columns)
    |> assign(:selected_columns, columns ++ ["actions"])
  end
end
