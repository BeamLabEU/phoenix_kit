defmodule PhoenixKitWeb.Live.Users.Users do
  @moduledoc """
  User management LiveView for PhoenixKit admin panel.

  Provides comprehensive user management including listing, search, role assignment, and status updates.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.TableColumns
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @per_page 10
  @max_cell_length 20

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)
    # Subscribe to user events for live updates
    if connected?(socket) do
      Events.subscribe_to_users()
      Events.subscribe_to_stats()
    end

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

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

    # Get columns and clean up any deleted custom fields
    selected_columns = TableColumns.get_user_table_columns()
    valid_columns = get_valid_columns(selected_columns)

    # If we filtered out any deleted columns, save the cleaned list
    if length(valid_columns) != length(selected_columns) do
      TableColumns.update_user_table_columns(valid_columns)
    end

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
      |> assign(:confirmation_modal, %{show: false})
      |> assign(:show_column_modal, false)
      |> assign(:page_title, "Users")
      |> assign(:project_title, project_title)
      |> assign(:date_time_settings, date_time_settings)
      |> assign(:current_locale, locale)
      |> assign(:selected_columns, valid_columns)
      |> assign(:available_columns, TableColumns.get_available_columns())
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

  def handle_event("sync_user_roles", params, socket) do
    user = socket.assigns.managing_user
    selected_roles = Map.get(params, "roles", %{})
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

  # New events for confirmation modal
  def handle_event(
        "request_status_toggle",
        %{"user_id" => user_id, "is_active" => is_active},
        socket
      ) do
    is_active_bool = is_active == "true"

    confirmation_modal = %{
      show: true,
      title: "Confirm Status Change",
      message:
        "Are you sure you want to #{if is_active_bool, do: "deactivate", else: "activate"} this user?",
      button_text: if(is_active_bool, do: "Deactivate", else: "Activate"),
      action: "toggle_user_status",
      user_id: user_id
    }

    {:noreply, assign(socket, :confirmation_modal, confirmation_modal)}
  end

  def handle_event(
        "request_confirmation_toggle",
        %{"user_id" => user_id, "is_confirmed" => is_confirmed},
        socket
      ) do
    is_confirmed_bool = is_confirmed == "true"

    confirmation_modal = %{
      show: true,
      title: "Confirm Email Status Change",
      message:
        "Are you sure you want to #{if is_confirmed_bool, do: "unconfirm", else: "confirm"} this user's email?",
      button_text: if(is_confirmed_bool, do: "Unconfirm", else: "Confirm"),
      action: "toggle_user_confirmation",
      user_id: user_id
    }

    {:noreply, assign(socket, :confirmation_modal, confirmation_modal)}
  end

  def handle_event("cancel_confirmation", _params, socket) do
    {:noreply, assign(socket, :confirmation_modal, %{show: false})}
  end

  def handle_event("confirm_action", %{"action" => action, "user_id" => user_id}, socket) do
    # Close modal first
    socket = assign(socket, :confirmation_modal, %{show: false})

    # Execute the confirmed action
    case action do
      "toggle_user_status" ->
        handle_toggle_user_status(%{"user_id" => user_id}, socket)

      "toggle_user_confirmation" ->
        handle_toggle_user_confirmation(%{"user_id" => user_id}, socket)

      _ ->
        {:noreply, socket}
    end
  end

  # Keep old handlers for backward compatibility, but make them delegate to private handlers
  def handle_event("toggle_user_status", %{"user_id" => user_id}, socket) do
    handle_toggle_user_status(%{"user_id" => user_id}, socket)
  end

  def handle_event("toggle_user_confirmation", %{"user_id" => user_id}, socket) do
    handle_toggle_user_confirmation(%{"user_id" => user_id}, socket)
  end

  # Column management events
  def handle_event("show_column_modal", _params, socket) do
    # Initialize temporary selected columns when opening modal
    current_columns = socket.assigns.selected_columns

    socket =
      socket
      |> assign(:show_column_modal, true)
      |> assign(:temp_selected_columns, current_columns)

    {:noreply, socket}
  end

  def handle_event("hide_column_modal", _params, socket) do
    # Clear temporary state when closing modal
    socket =
      socket
      |> assign(:show_column_modal, false)
      |> assign(:temp_selected_columns, nil)

    {:noreply, socket}
  end

  def handle_event("update_table_columns", %{"column_order" => column_order_string}, socket) do
    # Parse the column order string from the form
    column_order =
      column_order_string
      |> String.split(",", trim: true)
      |> Enum.filter(&(&1 != ""))

    # Update the temporary state with the new order and save
    socket =
      socket
      |> assign(:temp_selected_columns, column_order)
      |> save_and_close_modal()

    {:noreply, socket}
  end

  def handle_event("update_table_columns", _params, socket) do
    # Fallback for when column_order is not provided (e.g., form submission without reordering)
    socket =
      socket
      |> save_and_close_modal()

    {:noreply, socket}
  end

  def handle_event("reset_to_defaults", _params, socket) do
    default_columns = TableColumns.get_default_columns()

    # Update temporary state with default columns (all standard fields), don't save yet
    socket =
      socket
      |> assign(:temp_selected_columns, default_columns)

    {:noreply, socket}
  end

  def handle_event("add_column", %{"column_id" => column_id}, socket) do
    temp_selected = socket.assigns.temp_selected_columns || []
    new_selected = temp_selected ++ [column_id]

    socket =
      socket
      |> assign(:temp_selected_columns, new_selected)

    {:noreply, socket}
  end

  def handle_event("remove_column", %{"column_id" => column_id}, socket) do
    temp_selected = socket.assigns.temp_selected_columns || []
    new_selected = Enum.reject(temp_selected, &(&1 == column_id))

    socket =
      socket
      |> assign(:temp_selected_columns, new_selected)

    {:noreply, socket}
  end

  def handle_event("reorder_selected_columns", params, socket) do
    # Get the order from various possible param formats
    new_order =
      case params do
        # SortableGrid component format
        %{"ordered_ids" => order} when is_list(order) ->
          order

        %{"reorder_order" => order_string} when is_binary(order_string) ->
          # Parse comma-separated string from reorder input
          order_string
          |> String.split(",", trim: true)
          |> Enum.filter(&(&1 != ""))

        %{"order" => order} when is_list(order) ->
          order

        %{"column_order" => order_string} when is_binary(order_string) ->
          # Parse comma-separated string from hidden input
          order_string
          |> String.split(",", trim: true)
          |> Enum.filter(&(&1 != ""))

        _ ->
          []
      end

    if new_order == [] do
      {:noreply, socket}
    else
      # Update the temporary state with the new order
      temp_selected = socket.assigns.temp_selected_columns || []

      # Filter and reorder only valid columns from the new order (exclude actions)
      valid_new_order =
        Enum.filter(new_order, fn column_id ->
          column_id in temp_selected and column_id != "actions"
        end)

      # Add any missing columns from the end of the original list (except actions)
      missing_columns =
        Enum.reject(temp_selected, fn column_id ->
          column_id in valid_new_order or column_id == "actions"
        end)

      # Combine: reordered columns + missing columns + actions at end
      final_order = valid_new_order ++ missing_columns ++ ["actions"]

      socket =
        socket
        |> assign(:temp_selected_columns, final_order)

      {:noreply, socket}
    end
  end

  # Helper function to save the current temporary state and close the modal
  defp save_and_close_modal(socket) do
    temp_selected = socket.assigns.temp_selected_columns || []

    case TableColumns.update_user_table_columns(temp_selected) do
      {:ok, _setting} ->
        # Get the properly ordered columns back from TableColumns
        ordered_columns = TableColumns.get_user_table_columns()

        socket
        |> put_flash(:info, "Table columns updated successfully")
        |> assign(:selected_columns, ordered_columns)
        |> assign(:temp_selected_columns, nil)
        |> assign(:show_column_modal, false)

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Failed to update table columns")
        |> assign(:show_column_modal, false)
    end
  end

  # Helper function for template
  def get_available_fields_count(available_columns, selected_columns) do
    standard_available =
      available_columns.standard
      |> Map.keys()
      |> Enum.reject(&(&1 in selected_columns or &1 == "actions"))

    custom_available =
      available_columns.custom
      |> Map.keys()
      |> Enum.reject(&(&1 in selected_columns))

    length(standard_available) + length(custom_available)
  end

  # Keep the original handlers private for internal use
  defp handle_toggle_user_status(%{"user_id" => user_id}, socket) do
    current_user = socket.assigns.phoenix_kit_current_user
    user = Auth.get_user!(user_id)

    if current_user.id == user.id do
      socket = put_flash(socket, :error, "Cannot modify your own status")
      {:noreply, socket}
    else
      toggle_user_status_safely(socket, user)
    end
  end

  defp handle_toggle_user_confirmation(%{"user_id" => user_id}, socket) do
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

  # Optimized function using preloaded roles - used in template conditionals
  def get_primary_role_name_unsafe(user) do
    roles = get_user_roles(user)

    cond do
      "Owner" in roles -> "Owner"
      "Admin" in roles -> "Admin"
      true -> "User"
    end
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

  # Get valid columns only (filters out deleted custom fields)
  def get_valid_columns(columns) do
    Enum.filter(columns, &should_render_column?/1)
  end

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
    truncate_text(user.email, @max_cell_length)
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
    if user.is_active, do: "Active", else: "Inactive"
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
      "email" -> user.email
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

  defp format_boolean_value(true), do: "Yes"
  defp format_boolean_value(false), do: "No"
  defp format_boolean_value("true"), do: "Yes"
  defp format_boolean_value("false"), do: "No"
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

  defp format_checkbox_value(true), do: "Yes"
  defp format_checkbox_value(false), do: "No"
  defp format_checkbox_value("true"), do: "Yes"
  defp format_checkbox_value("false"), do: "No"

  defp format_checkbox_value(list) when is_list(list),
    do: truncate_text(Enum.join(list, ", "), @max_cell_length)

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

  def handle_info({:custom_field_deleted, field_key}, socket) do
    # When a custom field is deleted, refresh available columns and clean up selected columns
    column_id = "custom_#{field_key}"

    # Get fresh available columns (deleted field won't be included)
    available_columns = TableColumns.get_available_columns()

    # Remove the deleted field from selected columns if present
    selected_columns = socket.assigns.selected_columns
    new_selected_columns = Enum.reject(selected_columns, &(&1 == column_id))

    # Only update if the column was actually removed
    socket =
      if length(new_selected_columns) != length(selected_columns) do
        # Save the cleaned column list
        case TableColumns.update_user_table_columns(new_selected_columns) do
          {:ok, _} ->
            socket
            |> assign(:selected_columns, new_selected_columns)
            |> assign(:available_columns, available_columns)

          {:error, _} ->
            # If save fails, at least update the UI
            socket
            |> assign(:selected_columns, new_selected_columns)
            |> assign(:available_columns, available_columns)
        end
      else
        # Field wasn't in selected columns, just refresh available columns
        assign(socket, :available_columns, available_columns)
      end

    {:noreply, socket}
  end

  def handle_info(:custom_fields_changed, socket) do
    # Refresh available columns when fields are added/updated/reordered
    available_columns = TableColumns.get_available_columns()

    socket =
      socket
      |> assign(:available_columns, available_columns)

    {:noreply, socket}
  end
end
