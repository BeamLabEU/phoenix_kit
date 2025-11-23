defmodule PhoenixKitWeb.Users.UserForm do
  @moduledoc """
  LiveView for creating and editing users in the admin interface.

  Provides a form for managing user data including email, password, roles,
  and profile information. Supports both creation of new users and editing
  existing users.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Handle locale
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    user_id = params["id"]
    mode = if user_id, do: :edit, else: :new

    # Load custom field definitions
    field_definitions = CustomFields.list_enabled_field_definitions()

    # Load all roles for role management
    all_roles = Roles.list_roles()

    # Load default role for new user creation
    default_role = Settings.get_setting("new_user_default_role", "User")

    # Load timezone options
    setting_options = Settings.get_setting_options()
    timezone_options = [{"Use System Default", nil} | setting_options["time_zone"]]

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:mode, mode)
      |> assign(:user_id, user_id)
      |> assign(:page_title, page_title(mode))
      |> assign(:show_reset_password_modal, false)
      |> assign(:show_password_field, false)
      |> assign(:field_definitions, field_definitions)
      |> assign(:custom_fields_errors, %{})
      |> assign(:all_roles, all_roles)
      |> assign(:pending_roles, [])
      |> assign(:default_role, default_role)
      |> assign(:timezone_options, timezone_options)
      |> assign(:show_media_selector, false)
      |> assign(:pending_avatar_file_id, nil)
      |> assign(:avatar_changed, false)
      |> load_user_data(mode, user_id)
      |> load_form_data()

    {:ok, socket}
  end

  def handle_event("open_media_selector", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, true)}
  end

  def handle_event("validate_user", %{"user" => user_params}, socket) do
    # Filter password from params if password field is not shown
    filtered_params =
      if socket.assigns.mode == :edit and not socket.assigns.show_password_field do
        Map.delete(user_params, "password")
      else
        user_params
      end

    # In edit mode, ensure username is preserved to prevent regeneration from email
    filtered_params =
      if socket.assigns.mode == :edit do
        filtered_params = Map.put_new(filtered_params, "username", socket.assigns.user.username)

        Logger.info(
          "validate_user - user_params username: #{inspect(Map.get(user_params, "username"))}, filtered_params username: #{inspect(Map.get(filtered_params, "username"))}"
        )

        filtered_params
      else
        filtered_params
      end

    changeset =
      case socket.assigns.mode do
        :new ->
          Auth.change_user_registration(%Auth.User{}, filtered_params)

        :edit ->
          Auth.User.profile_changeset(socket.assigns.user, filtered_params, validate_email: false)
      end
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:form_data, filtered_params)
      |> assign(
        :custom_fields_data,
        Map.get(user_params, "custom_fields", socket.assigns.custom_fields_data)
      )

    {:noreply, socket}
  end

  def handle_event("save_user", %{"user" => user_params}, socket) do
    case socket.assigns.mode do
      :new -> create_user(socket, user_params)
      :edit -> update_user(socket, user_params)
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/users"))}
  end

  def handle_event("show_reset_password_modal", _params, socket) do
    socket = assign(socket, :show_reset_password_modal, true)
    {:noreply, socket}
  end

  def handle_event("hide_reset_password_modal", _params, socket) do
    socket = assign(socket, :show_reset_password_modal, false)
    {:noreply, socket}
  end

  def handle_event("admin_reset_password", _params, socket) do
    user = socket.assigns.user

    case Auth.deliver_user_reset_password_instructions(
           user,
           &Routes.url("/users/reset-password/#{&1}")
         ) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Password reset email sent to #{user.email}. The user will receive instructions to reset their password."
          )
          |> assign(:show_reset_password_modal, false)

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          put_flash(socket, :error, "Failed to send password reset email. Please try again.")

        {:noreply, socket}
    end
  end

  def handle_event("toggle_password_field", _params, socket) do
    new_show_password_field = !socket.assigns.show_password_field

    socket =
      socket
      |> assign(:show_password_field, new_show_password_field)
      |> reload_changeset_with_password(new_show_password_field)

    {:noreply, socket}
  end

  def handle_event("open_roles_dropdown", _params, socket) do
    # Initialize pending roles with current user roles when dropdown opens
    socket = assign(socket, :pending_roles, socket.assigns.user_roles)
    {:noreply, socket}
  end

  def handle_event("toggle_role", %{"role" => role_name}, socket) do
    # Toggle role in pending_roles list
    pending_roles = socket.assigns.pending_roles

    new_pending_roles =
      if role_name in pending_roles do
        List.delete(pending_roles, role_name)
      else
        [role_name | pending_roles]
      end

    socket = assign(socket, :pending_roles, new_pending_roles)
    {:noreply, socket}
  end

  def handle_event("apply_roles", _params, socket) do
    user = socket.assigns.user
    current_user = socket.assigns.phoenix_kit_current_user

    # Prevent users from modifying their own roles
    if user.id == current_user.id do
      socket =
        put_flash(socket, :error, "You cannot modify your own roles.")

      {:noreply, socket}
    else
      role_names = socket.assigns.pending_roles

      case Roles.sync_user_roles(user, role_names) do
        {:ok, _assignments} ->
          socket =
            socket
            |> put_flash(:info, "User roles updated successfully.")
            |> assign(:user_roles, Roles.get_user_roles(user))
            |> assign(:pending_roles, [])

          {:noreply, socket}

        {:error, reason} ->
          error_message =
            case reason do
              :owner_role_protected -> "Owner role cannot be manually assigned."
              :cannot_remove_last_owner -> "Cannot remove Owner role from the last Owner."
              _ -> "Failed to update roles. Please try again."
            end

          socket = put_flash(socket, :error, error_message)
          {:noreply, socket}
      end
    end
  end

  def handle_event("sync_user_roles", params, socket) do
    user = socket.assigns.user
    current_user = socket.assigns.phoenix_kit_current_user

    # Prevent users from modifying their own roles
    if user.id == current_user.id do
      socket =
        put_flash(socket, :error, "You cannot modify your own roles.")

      {:noreply, socket}
    else
      # Extract role names from form params
      role_names =
        params
        |> Map.get("roles", %{})
        |> Enum.filter(fn {_key, value} -> value != "false" end)
        |> Enum.map(fn {key, _value} -> key end)

      case Roles.sync_user_roles(user, role_names) do
        {:ok, _assignments} ->
          socket =
            socket
            |> put_flash(:info, "User roles updated successfully.")
            |> assign(:user_roles, Roles.get_user_roles(user))

          {:noreply, socket}

        {:error, reason} ->
          error_message =
            case reason do
              :owner_role_protected -> "Owner role cannot be manually assigned."
              :cannot_remove_last_owner -> "Cannot remove Owner role from the last Owner."
              _ -> "Failed to update roles. Please try again."
            end

          socket = put_flash(socket, :error, error_message)
          {:noreply, socket}
      end
    end
  end

  def handle_event("toggle_user_status", _params, socket) do
    user = socket.assigns.user
    new_status = !user.is_active

    case Auth.update_user_status(user, %{"is_active" => new_status}) do
      {:ok, updated_user} ->
        status_text = if new_status, do: "activated", else: "deactivated"

        socket =
          socket
          |> put_flash(:info, "User #{status_text} successfully.")
          |> assign(:user, updated_user)
          |> reload_changeset_after_status_update(updated_user)

        {:noreply, socket}

      {:error, :cannot_deactivate_last_owner} ->
        socket =
          put_flash(
            socket,
            :error,
            "Cannot deactivate the last Owner. Assign the Owner role to another user first."
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          put_flash(socket, :error, "Failed to update user status. Please try again.")

        {:noreply, socket}
    end
  end

  defp create_user(socket, user_params) do
    ip_address = IpAddress.extract_from_socket(socket)

    case Auth.register_user(user_params, ip_address) do
      {:ok, user} ->
        # Optionally send confirmation email
        case Auth.deliver_user_confirmation_instructions(
               user,
               &Routes.url("/users/confirm/#{&1}")
             ) do
          {:ok, _} -> :ok
          # Continue even if email fails
          {:error, _} -> :ok
        end

        socket =
          socket
          |> put_flash(:info, "User created successfully. Confirmation email sent.")
          |> push_navigate(to: Routes.path("/admin/users"))

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> assign(:form_data, user_params)

        {:noreply, socket}
    end
  end

  defp update_user(socket, user_params) do
    user = socket.assigns.user
    custom_fields_params = Map.get(user_params, "custom_fields", %{})

    # Include pending avatar if it was changed via media selector
    custom_fields_params =
      if socket.assigns[:avatar_changed] && socket.assigns[:pending_avatar_file_id] do
        Map.put(custom_fields_params, "avatar_file_id", socket.assigns.pending_avatar_file_id)
      else
        custom_fields_params
      end

    profile_params = Map.delete(user_params, "custom_fields")

    with :ok <- validate_custom_fields(user, custom_fields_params),
         {:ok, updated_user} <- update_user_profile(socket, user, profile_params),
         {:ok, user_with_fields} <- update_custom_fields(updated_user, custom_fields_params),
         result <- update_user_roles_if_changed(socket, user_with_fields) do
      # Clear avatar change flag after successful update
      socket = socket
               |> assign(:avatar_changed, false)
               |> assign(:pending_avatar_file_id, nil)

      handle_update_result(socket, result)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        handle_profile_update_error(socket, changeset, user_params)

      {:error, :custom_fields, errors} ->
        handle_custom_fields_error(socket, errors, custom_fields_params)

      {:error, :custom_fields_save} ->
        handle_custom_fields_save_error(socket)
    end
  end

  defp validate_custom_fields(_user, custom_fields_params)
       when map_size(custom_fields_params) == 0 do
    :ok
  end

  defp validate_custom_fields(user, custom_fields_params) do
    temp_user = %{user | custom_fields: custom_fields_params}

    case CustomFields.validate_user_custom_fields(temp_user) do
      :ok -> :ok
      {:error, errors} -> {:error, :custom_fields, errors}
    end
  end

  defp update_user_profile(socket, user, profile_params) do
    password_provided =
      socket.assigns.show_password_field &&
        Map.has_key?(profile_params, "password") &&
        profile_params["password"] != nil &&
        String.trim(profile_params["password"]) != ""

    if password_provided do
      update_profile_and_password(socket, user, profile_params)
    else
      cleaned_params = Map.delete(profile_params, "password")
      # Pass validate_email: false to skip uniqueness validation for username/email
      # This allows users to keep their current username without it being regenerated
      update_user_profile_without_validation(user, cleaned_params)
    end
  end

  defp update_user_profile_without_validation(user, attrs) do
    Logger.info(
      "update_user_profile_without_validation - attrs username: #{inspect(Map.get(attrs, "username"))}"
    )

    changeset = Auth.User.profile_changeset(user, attrs, validate_email: false)

    Logger.info(
      "After profile_changeset, changeset changes username: #{inspect(Ecto.Changeset.get_change(changeset, :username))}, field: #{inspect(Ecto.Changeset.get_field(changeset, :username))}"
    )

    case changeset |> PhoenixKit.RepoHelper.repo().update() do
      {:ok, updated_user} ->
        Logger.info("After DB update, saved username: #{inspect(updated_user.username)}")
        Events.broadcast_user_updated(updated_user)
        {:ok, updated_user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp update_custom_fields(user, custom_fields_params)
       when map_size(custom_fields_params) == 0 do
    {:ok, user}
  end

  defp update_custom_fields(user, custom_fields_params) do
    # Use update_user_fields instead of update_user_custom_fields to preserve existing fields (like avatar_file_id)
    case Auth.update_user_fields(user, custom_fields_params) do
      {:ok, updated_user} -> {:ok, updated_user}
      {:error, _changeset} -> {:error, :custom_fields_save}
    end
  end

  defp handle_update_result(socket, {:ok, _result}) do
    # _result could be either the updated user or role assignments (from sync_user_roles)
    # In both cases, we need to reload the user from the database to get the fresh data
    user_id = socket.assigns.user.id
    fresh_user = Auth.get_user!(user_id)

    Logger.info(
      "handle_update_result - fresh_user username from DB: #{inspect(fresh_user.username)}"
    )

    socket =
      socket
      |> assign(:user, fresh_user)
      |> reload_changeset_with_updated_user(fresh_user)
      |> put_flash(:info, "User updated successfully.")
      |> push_navigate(to: Routes.path("/admin/users"))

    {:noreply, socket}
  end

  defp handle_update_result(socket, {:error, reason}) do
    error_message = format_role_update_error(reason)

    socket =
      socket
      |> put_flash(:warning, error_message)
      |> push_navigate(to: Routes.path("/admin/users"))

    {:noreply, socket}
  end

  defp reload_changeset_with_updated_user(socket, updated_user) do
    form_data = socket.assigns.form_data || %{}
    # Ensure username is in form_data to prevent regeneration from email
    form_data = Map.put_new(form_data, "username", updated_user.username)
    # Use profile_changeset for edit mode to avoid username regeneration
    changeset = Auth.User.profile_changeset(updated_user, form_data, validate_email: false)
    assign(socket, :changeset, changeset)
  end

  defp format_role_update_error(:owner_role_protected) do
    "User profile updated but Owner role cannot be manually assigned."
  end

  defp format_role_update_error(:cannot_remove_last_owner) do
    "User profile updated but cannot remove Owner role from the last Owner."
  end

  defp format_role_update_error(_) do
    "User profile updated but roles failed to update."
  end

  defp handle_profile_update_error(socket, changeset, user_params) do
    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:form_data, user_params)
      |> assign(:custom_fields_errors, %{})

    {:noreply, socket}
  end

  defp handle_custom_fields_error(socket, errors, custom_fields_params) do
    socket =
      socket
      |> assign(:custom_fields_errors, errors)
      |> assign(:custom_fields_data, custom_fields_params)
      |> put_flash(:error, "Please fix the custom field errors below.")

    {:noreply, socket}
  end

  defp handle_custom_fields_save_error(socket) do
    socket =
      socket
      |> put_flash(:error, "User profile updated but custom fields failed to save.")
      |> push_navigate(to: Routes.path("/admin/users"))

    {:noreply, socket}
  end

  defp load_user_data(socket, :new, _user_id) do
    socket
    |> assign(:user, %Auth.User{})
    |> assign(:user_roles, [])
  end

  defp load_user_data(socket, :edit, user_id) do
    user = Auth.get_user!(user_id)
    user_roles = Roles.get_user_roles(user)

    socket
    |> assign(:user, user)
    |> assign(:user_roles, user_roles)
    |> assign(:pending_roles, user_roles)
  end

  defp load_form_data(%{assigns: %{mode: :new}} = socket) do
    changeset = Auth.change_user_registration(%Auth.User{}, %{})

    socket
    |> assign(:changeset, changeset)
    |> assign(:form_data, %{
      "email" => "",
      "password" => "",
      "first_name" => "",
      "last_name" => ""
    })
    |> assign(:custom_fields_data, %{})
  end

  defp load_form_data(%{assigns: %{mode: :edit, user: user}} = socket) do
    # For edit mode, use profile_changeset instead of registration_changeset
    # profile_changeset doesn't call maybe_generate_username_from_email like registration_changeset does
    Logger.info("Loading form for user #{user.id}: DB username=#{inspect(user.username)}")

    changeset =
      Auth.User.profile_changeset(user, %{"username" => user.username}, validate_email: false)

    Logger.info(
      "After creating changeset, changeset changes: #{inspect(Ecto.Changeset.get_change(changeset, :username))}, changeset field: #{inspect(Ecto.Changeset.get_field(changeset, :username))}"
    )

    socket
    |> assign(:changeset, changeset)
    |> assign(:form_data, %{
      "email" => user.email || "",
      "username" => user.username || "",
      "first_name" => user.first_name || "",
      "last_name" => user.last_name || "",
      "user_timezone" => user.user_timezone || "0"
    })
    |> assign(:custom_fields_data, user.custom_fields || %{})
  end

  defp page_title(:new), do: "Create User"
  defp page_title(:edit), do: "Edit User"

  defp reload_changeset_with_password(socket, show_password_field) do
    case socket.assigns.mode do
      :new ->
        # For new users, password is always required
        socket

      :edit ->
        # For edit mode, reload changeset to include/exclude password field
        user = socket.assigns.user
        form_data = socket.assigns.form_data || %{}

        # Create changeset with or without password validation
        changeset =
          if show_password_field do
            # Include password in changeset when field is shown
            Auth.change_user_registration(user, form_data)
          else
            # Standard profile changeset when password field is hidden
            Auth.change_user_registration(user, Map.delete(form_data, "password"))
          end

        assign(socket, :changeset, changeset)
    end
  end

  defp reload_changeset_after_status_update(socket, updated_user) do
    form_data = socket.assigns.form_data || %{}
    changeset = Auth.change_user_registration(updated_user, form_data)
    assign(socket, :changeset, changeset)
  end

  defp update_profile_and_password(socket, user, user_params) do
    # First validate profile update
    profile_params = Map.delete(user_params, "password")

    case Auth.update_user_profile(user, profile_params) do
      {:ok, updated_user} ->
        # If profile update succeeded, update password
        password_params = Map.take(user_params, ["password"])

        # Build audit context from socket
        context = build_audit_context(socket)

        case Auth.admin_update_user_password(updated_user, password_params, context) do
          {:ok, final_user} ->
            {:ok, final_user}

          {:error, password_changeset} ->
            # If password update failed, return a combined changeset
            profile_changeset = Auth.change_user_registration(user, user_params)
            combined_changeset = merge_password_errors(profile_changeset, password_changeset)
            {:error, combined_changeset}
        end

      {:error, profile_changeset} ->
        # Profile update failed, return the profile changeset with password field
        {:error, profile_changeset}
    end
  end

  defp build_audit_context(socket) do
    # Get admin user from socket assigns (set by on_mount)
    admin_user = Map.get(socket.assigns, :phoenix_kit_current_user)

    # Get IP address from socket metadata
    ip_address =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> :inet.ntoa(address) |> to_string()
        _ -> nil
      end

    # Get user agent from socket metadata
    user_agent =
      case Phoenix.LiveView.get_connect_info(socket, :user_agent) do
        ua when is_binary(ua) -> ua
        _ -> nil
      end

    %{
      admin_user: admin_user,
      ip_address: ip_address,
      user_agent: user_agent
    }
  end

  defp merge_password_errors(profile_changeset, password_changeset) do
    # Merge password errors into the profile changeset
    password_errors = password_changeset.errors

    Enum.reduce(password_errors, profile_changeset, fn {field, error}, acc ->
      Ecto.Changeset.add_error(acc, field, elem(error, 0), elem(error, 1))
    end)
  end

  defp update_user_roles_if_changed(socket, user) do
    current_user = socket.assigns.phoenix_kit_current_user
    pending_roles = socket.assigns.pending_roles
    current_roles = socket.assigns.user_roles

    # Check if roles have changed
    roles_changed? = Enum.sort(pending_roles) != Enum.sort(current_roles)

    cond do
      # If user is trying to modify their own roles, prevent it
      user.id == current_user.id and roles_changed? ->
        {:error, :cannot_modify_own_roles}

      # If roles haven't changed, skip update
      not roles_changed? ->
        {:ok, user}

      # Roles have changed and it's allowed, update them
      true ->
        Roles.sync_user_roles(user, pending_roles)
    end
  end

  def handle_info({:media_selected, file_ids}, socket) do
    # Get the first selected file ID (single selection mode)
    avatar_file_id = List.first(file_ids)

    # Store avatar selection without saving to database yet
    # Avatar will be saved when "Update User" button is clicked
    socket =
      if avatar_file_id do
        Logger.info("Avatar selected (pending save): #{avatar_file_id}")

        socket
        |> assign(:pending_avatar_file_id, avatar_file_id)
        |> assign(:avatar_changed, true)
        |> assign(:show_media_selector, false)
        |> put_flash(:info, "Avatar selected. Click 'Update User' to save.")
      else
        socket
        |> assign(:show_media_selector, false)
      end

    {:noreply, socket}
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply, assign(socket, :show_media_selector, false)}
  end
end
