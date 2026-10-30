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
  alias PhoenixKit.Users.FormatCountry
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations.Actor, as: OrganizationActor
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes

  def mount(params, session, socket) do
    user_uuid = params["id"]
    mode = if user_uuid, do: :edit, else: :new

    # Where "Update User"/"Cancel" should navigate back to: the page the
    # admin actually came from (the list, or a specific user's detail page),
    # not always the list. `return_to` is a whitelisted token (not a raw
    # path) so there's no open-redirect surface to worry about.
    return_to = resolve_return_to(params["return_to"], user_uuid)

    # Extract IP and user agent during mount (connect_info is only available here)
    registration_ip = IpAddress.extract_from_socket(socket)

    user_agent =
      case Phoenix.LiveView.get_connect_info(socket, :user_agent) do
        ua when is_binary(ua) -> ua
        _ -> nil
      end

    # Load custom field definitions
    field_definitions = CustomFields.list_enabled_field_definitions()

    # Load all roles for role management
    all_roles = Roles.list_roles()

    # Load default role for new user creation
    default_role = Settings.effective_new_user_default_role()

    # Load timezone options — timezone_options/0 directly, not
    # get_setting_options/0: this form already loads all_roles above for
    # its own role-management UI, so building the whole options map here
    # too would query roles a second time for nothing.
    timezone_options = [{"Use System Default", nil} | Settings.timezone_options()]

    # Organization accounts
    org_accounts_enabled =
      Settings.get_setting("enable_organization_accounts", "false") == "true"

    organizations = if org_accounts_enabled, do: Auth.list_organizations(), else: []

    socket =
      socket
      |> assign(
        :manager_actor,
        case OrganizationActor.from_session(session) do
          {:ok, actor} -> actor
          _ -> nil
        end
      )
      |> assign(:mode, mode)
      |> assign(:user_uuid, user_uuid)
      |> assign(:return_to, return_to)
      |> assign(:page_title, page_title(mode))
      |> assign(:show_reset_password_modal, false)
      |> assign(:show_password_field, false)
      |> assign(:field_definitions, field_definitions)
      |> assign(:custom_fields_errors, %{})
      |> assign(:all_roles, all_roles)
      |> assign(:pending_roles, [])
      |> assign(:default_role, default_role)
      |> assign(:timezone_options, timezone_options)
      |> assign(:country_options, CountryData.countries_for_select())
      |> assign(:show_media_selector, false)
      |> assign(:pending_avatar_file_uuid, nil)
      |> assign(:avatar_changed, false)
      |> assign(:registration_ip, registration_ip)
      |> assign(:org_accounts_enabled, org_accounts_enabled)
      |> assign(:organizations, organizations)
      |> assign(:current_account_type, "person")
      |> assign(:user_agent, user_agent)
      |> assign(:page_section, gettext("Users"))
      |> assign(:page_section_path, Routes.path("/admin/users"))
      |> load_user_data(mode, user_uuid)
      |> assign_credential_authority()
      # Resolved when the selector opens — the host hook may create a folder.
      |> assign(:avatar_scope_folder, nil)
      |> load_form_data()
      |> maybe_set_edit_page_title()

    {:ok, socket}
  end

  defp assign_avatar_scope_folder(socket) do
    actor_uuid =
      socket.assigns[:phoenix_kit_current_user] && socket.assigns.phoenix_kit_current_user.uuid

    assign(
      socket,
      :avatar_scope_folder,
      PhoenixKit.UploadsParentFolder.resolve(:avatar, actor_uuid, socket.assigns[:user])
    )
  end

  # Whether this actor may set a password for, mail a reset link to, or change
  # the email address of the record being edited. Holding the `users` permission
  # gets you onto this page; it does not get you another actor's credentials.
  # Creating a user is unconditional — a record that does not exist yet cannot
  # outrank anyone.
  defp assign_credential_authority(%{assigns: %{mode: :new}} = socket) do
    socket
    |> assign(:can_manage_credentials, true)
    |> assign(:can_manage_status, true)
  end

  defp assign_credential_authority(socket) do
    target = socket.assigns.user
    actor = socket.assigns[:phoenix_kit_current_user]

    socket
    |> assign(:can_manage_credentials, Auth.can_manage_user_credentials?(target, actor))
    |> assign(:can_manage_status, Auth.can_manage_user_status?(target, actor))
  end

  # :new keeps the generic "Create User" title (no record to name yet); :edit
  # names the record being edited so the layout breadcrumb reads
  # "Users / Edit <name>" instead of the context-free "Users / Edit User".
  defp maybe_set_edit_page_title(%{assigns: %{mode: :edit, user: user}} = socket) do
    assign(socket, :page_title, gettext("Edit %{name}", name: user_display_name(user)))
  end

  defp maybe_set_edit_page_title(socket), do: socket

  defp user_display_name(user) do
    cond do
      user.first_name && user.last_name -> "#{user.first_name} #{user.last_name}"
      user.first_name -> user.first_name
      user.username -> user.username
      true -> user.email
    end
  end

  # `return_to` is a whitelisted token from the query string, not a raw path
  # — never interpolate an arbitrary caller-supplied path here.
  defp resolve_return_to("view", user_uuid) when is_binary(user_uuid) do
    Routes.path("/admin/users/view/#{user_uuid}")
  end

  defp resolve_return_to(_return_to, _user_uuid), do: Routes.path("/admin/users")

  def handle_event("open_media_selector", _params, socket) do
    {:noreply,
     socket
     |> assign_avatar_scope_folder()
     |> assign(:show_media_selector, true)}
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

    account_type =
      Map.get(filtered_params, "account_type", socket.assigns.current_account_type)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:form_data, filtered_params)
      |> assign(:current_account_type, account_type)
      |> assign(
        :custom_fields_data,
        merge_custom_fields_data(socket.assigns.custom_fields_data, user_params["custom_fields"])
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
    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  def handle_event("show_reset_password_modal", _params, socket) do
    if socket.assigns.can_manage_credentials do
      {:noreply, assign(socket, :show_reset_password_modal, true)}
    else
      {:noreply, deny_credential_action(socket)}
    end
  end

  def handle_event("hide_reset_password_modal", _params, socket) do
    socket = assign(socket, :show_reset_password_modal, false)
    {:noreply, socket}
  end

  def handle_event("admin_reset_password", _params, socket) do
    if socket.assigns.can_manage_credentials do
      do_admin_reset_password(socket)
    else
      {:noreply, deny_credential_action(socket)}
    end
  end

  def handle_event("toggle_password_field", _params, socket) do
    if socket.assigns.can_manage_credentials do
      new_show_password_field = !socket.assigns.show_password_field

      socket =
        socket
        |> assign(:show_password_field, new_show_password_field)
        |> reload_changeset_with_password(new_show_password_field)

      {:noreply, socket}
    else
      {:noreply, deny_credential_action(socket)}
    end
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
    if user.uuid == current_user.uuid do
      socket =
        put_flash(socket, :error, "You cannot modify your own roles.")

      {:noreply, socket}
    else
      role_names = socket.assigns.pending_roles

      case Roles.sync_user_roles(user, role_names, actor: current_user) do
        {:ok, %{refused: [_ | _] = refused}} ->
          {:noreply,
           socket
           |> put_flash(:error, roles_refused_message(refused))
           |> assign(:user_roles, Roles.get_user_roles(user))}

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
    if user.uuid == current_user.uuid do
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

      case Roles.sync_user_roles(user, role_names, actor: current_user) do
        {:ok, %{refused: [_ | _] = refused}} ->
          {:noreply,
           socket
           |> put_flash(:error, roles_refused_message(refused))
           |> assign(:user_roles, Roles.get_user_roles(user))}

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

  def handle_event("add_member", %{"member_uuid" => member_uuid}, socket) do
    case Auth.set_organization(Auth.get_user!(member_uuid), socket.assigns.user.uuid) do
      {:ok, _} ->
        socket =
          socket
          |> assign(
            :organization_members,
            Auth.list_organization_members(socket.assigns.user.uuid)
          )
          |> assign(
            :available_members,
            Auth.list_available_members_for_organization(socket.assigns.user.uuid)
          )
          |> put_flash(:info, gettext("Member added to organization"))

        {:noreply, socket}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add member"))}
    end
  end

  def handle_event("remove_member", %{"uuid" => member_uuid}, socket) do
    member = Auth.get_user!(member_uuid)

    case Auth.remove_from_organization(member) do
      {:ok, _} ->
        socket =
          socket
          |> assign(
            :organization_members,
            Auth.list_organization_members(socket.assigns.user.uuid)
          )
          |> assign(
            :available_members,
            Auth.list_available_members_for_organization(socket.assigns.user.uuid)
          )
          |> put_flash(:info, gettext("Member removed from organization"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove member"))}
    end
  end

  def handle_event("invite_member", %{"email" => email}, socket) do
    organization = socket.assigns.user
    invited_by = socket.assigns.phoenix_kit_current_user
    email = String.trim(email)

    case Invitations.create_invitation(organization, email, invited_by) do
      {:ok, _invitation, _encoded_token} ->
        socket =
          socket
          |> assign(:pending_invitations, Invitations.list_invitations(organization.uuid))
          |> put_flash(:info, gettext("Invitation sent to %{email}", email: email))

        {:noreply, socket}

      {:error, :self_invite} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot invite yourself"))}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to send invitation"))}
    end
  end

  def handle_event("cancel_invitation", %{"uuid" => uuid}, socket) do
    case Invitations.cancel_invitation(
           socket.assigns.manager_actor,
           socket.assigns.user.uuid,
           uuid
         ) do
      {:ok, _} ->
        organization = socket.assigns.user

        socket =
          socket
          |> assign(:pending_invitations, Invitations.list_invitations(organization.uuid))
          |> put_flash(:info, gettext("Invitation cancelled"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to cancel invitation"))}
    end
  end

  def handle_event("toggle_user_status", _params, socket) do
    if socket.assigns.can_manage_status do
      do_toggle_user_status(socket)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("You don't have permission to change this user's status")
       )}
    end
  end

  defp do_toggle_user_status(socket) do
    user = socket.assigns.user
    new_status = !user.is_active

    case Auth.update_user_status(user, %{"is_active" => new_status},
           actor: socket.assigns[:phoenix_kit_current_user]
         ) do
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

  defp do_admin_reset_password(socket) do
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

  # One refusal for every credential action. The template hides these controls,
  # but a LiveView event is a websocket message the client composes itself, so
  # hiding is presentation and this is the control.
  defp deny_credential_action(socket) do
    put_flash(
      socket,
      :error,
      gettext("You don't have permission to manage this user's credentials")
    )
  end

  # Everything after the insert is best effort. The row is committed the moment
  # `admin_create_user/2` returns, so a raise from the confirmation mailer (the
  # one unguarded step) killed this LiveView AFTER the user existed: the page
  # remounted, form recovery refilled every field, and a second "Create User"
  # was told the email was taken. Nothing past the insert may take the navigation away.
  defp create_user(socket, user_params) do
    admin_user = socket.assigns[:phoenix_kit_current_user]

    case Auth.admin_create_user(user_params, admin_user) do
      {:ok, user} ->
        email_result = send_confirmation_email(user)
        log_user_created(user, admin_user)

        socket =
          socket
          |> put_flash(email_result_flash_kind(email_result), created_flash(email_result))
          |> push_navigate(to: Routes.path("/admin/users/view/#{user.uuid}"))

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> assign(:form_data, user_params)

        {:noreply, socket}
    end
  end

  defp send_confirmation_email(user) do
    case Auth.deliver_user_confirmation_instructions(
           user,
           &Routes.url("/users/confirm/#{&1}")
         ) do
      {:ok, _} ->
        :sent

      {:error, reason} ->
        Logger.warning(
          "PhoenixKit: admin-created user #{user.uuid} got no confirmation email: #{inspect(reason)}"
        )

        :failed
    end
  rescue
    error ->
      Logger.error(
        "PhoenixKit: confirmation email for admin-created user #{user.uuid} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :failed
  catch
    :exit, reason ->
      Logger.error(
        "PhoenixKit: confirmation email for admin-created user #{user.uuid} exited: #{inspect(reason)}"
      )

      :failed
  end

  # `Activity.log/1` rescues and catches exits itself.
  defp log_user_created(user, admin_user) do
    PhoenixKit.Activity.log(%{
      action: "user.created",
      module: "users",
      mode: "manual",
      actor_uuid: admin_user.uuid,
      resource_type: "user",
      resource_uuid: user.uuid,
      target_uuid: user.uuid,
      metadata: %{"method" => "manual", "actor_role" => "admin"}
    })
  end

  defp email_result_flash_kind(:sent), do: :info
  defp email_result_flash_kind(:failed), do: :warning

  defp created_flash(:sent), do: gettext("User created. A confirmation email was sent.")

  defp created_flash(:failed),
    do: gettext("User created, but the confirmation email could not be sent.")

  defp update_user(socket, user_params) do
    user = socket.assigns.user

    # Dropped unconditionally, not only when the actor is out of rank. The form
    # renders a real input for every one of these, so a `custom_fields` entry
    # carrying one is never a legitimate submission from this page — and an
    # unconditional filter cannot go stale the way an authority assign computed
    # at mount can.
    #
    # Without this, the credential rank rule was bypassable end to end: the
    # `Map.drop` in `update_user_profile/3` guards `profile_params`, and
    # `custom_fields` went straight to `Auth.update_user_fields/2`, which wrote
    # `:email` into the schema with no confirmation-token flow. An actor holding
    # only the `users` permission could point an Owner's address at their own
    # inbox and then take the account through the public password-reset page.
    custom_fields_params =
      user_params
      |> Map.get("custom_fields", %{})
      |> drop_schema_identity_fields(socket)

    # Include pending avatar if it was changed via media selector
    custom_fields_params =
      if socket.assigns[:avatar_changed] && socket.assigns[:pending_avatar_file_uuid] do
        Map.put(custom_fields_params, "avatar_file_uuid", socket.assigns.pending_avatar_file_uuid)
      else
        custom_fields_params
      end

    profile_params = Map.delete(user_params, "custom_fields")

    avatar_changed? = socket.assigns[:avatar_changed] == true
    avatar_file_uuid = socket.assigns[:pending_avatar_file_uuid]

    with :ok <- validate_custom_fields(user, custom_fields_params),
         {:ok, updated_user} <- update_user_profile(socket, user, profile_params),
         {:ok, user_with_fields} <- update_custom_fields(updated_user, custom_fields_params),
         {:ok, user_with_account_type} <-
           update_account_type_fields(user_with_fields, user_params),
         result <- update_user_roles_if_changed(socket, user_with_account_type) do
      # Log avatar change if it happened
      if avatar_changed? && avatar_file_uuid do
        admin = socket.assigns[:phoenix_kit_current_user]

        PhoenixKit.Activity.log(%{
          action: "user.avatar_changed",
          module: "users",
          mode: "manual",
          actor_uuid: admin && admin.uuid,
          resource_type: "user",
          resource_uuid: user_with_account_type.uuid,
          target_uuid: user_with_account_type.uuid,
          metadata: %{
            "avatar_from" => get_in(user.custom_fields, ["avatar_file_uuid"]) || "",
            "avatar_to" => avatar_file_uuid,
            "actor_role" => "admin"
          }
        })
      end

      # Clear avatar change flag after successful update
      socket =
        socket
        |> assign(:avatar_changed, false)
        |> assign(:pending_avatar_file_uuid, nil)

      # The credential fields were dropped for lack of rank while this
      # submission actually asked to change one. The rest of the save is
      # committed — that is the established behaviour and a test pins it — so
      # the only thing wrong was the screen saying "User updated successfully"
      # about a password that had not moved. The user it belonged to then
      # could not sign in with it and nobody had been told why.
      #
      # The cheap comparison goes first: `credential_authority_now/2` is a
      # database read, and an ordinary save asks for no credential change.
      credentials_refused? =
        credential_change_attempted?(user, profile_params) and
          not credential_authority_now(socket, user)

      handle_update_result(socket, result, credentials_refused?)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        handle_profile_update_error(socket, changeset, user_params)

      {:error, :custom_fields, errors} ->
        handle_custom_fields_error(socket, errors, custom_fields_params)

      {:error, :custom_fields_save} ->
        handle_custom_fields_save_error(socket)

      # Without this clause the `with` raises `WithClauseError`: the atom matches
      # neither the changeset clause above nor the binary one below.
      {:error, :insufficient_permissions} ->
        {:noreply, deny_credential_action(socket)}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp validate_custom_fields(_user, custom_fields_params)
       when map_size(custom_fields_params) == 0 do
    :ok
  end

  defp validate_custom_fields(user, custom_fields_params) do
    # Validate what will actually be STORED, not just what was submitted:
    # `update_custom_fields/2` merges through `Auth.update_user_fields/2`, so a
    # key absent from the submission keeps its stored value. Validating the
    # submission alone made every enabled definition that the form does not
    # render an input for look empty — which, for a `required` one, blocked
    # every save on the page with "Field is required" for a field nobody could
    # fill in. The form stopped submitting exactly such a key when its value is
    # a map or a list (issue #780).
    merged = Map.merge(user.custom_fields || %{}, custom_fields_params)
    temp_user = %{user | custom_fields: merged}

    case CustomFields.validate_user_custom_fields(temp_user) do
      :ok -> :ok
      {:error, errors} -> {:error, :custom_fields, errors}
    end
  end

  defp update_user_profile(socket, user, profile_params) do
    # Defence in depth at the write path. The events above already refuse, but
    # `email` is an ordinary field of this form and owning the address a reset
    # link is delivered to takes an account just as surely as setting the
    # password does — so an actor who may not manage this record's credentials
    # gets both fields dropped here, whatever the params say.
    #
    # Asked again here rather than read off `@can_manage_credentials`, which is
    # computed once in `mount/3`. The context re-evaluates the same rule when the
    # password is written, so a stale assign made the two disagree: the form
    # would write the credential fields on the strength of the old answer and
    # then take a refusal from the context, leaving a partial write behind — and
    # the refusal arrived as `{:error, :insufficient_permissions}`, which the
    # clause below expects to be a changeset. The assign stays as the UI's
    # answer; the write path asks for a fresh one.
    authority? = credential_authority_now(socket, user)

    # Dropping them and carrying on is right for a save that only LOOKS like it
    # touches credentials — the form submits `email` and `username` on every
    # save, unchanged — but it was also what happened when an actor really did
    # type a new password for an account out of their rank: the field was
    # discarded, the profile update went through, and the page said "User
    # updated successfully." The password had not changed, so the person it
    # belonged to could not sign in with it, and nothing on screen said why.
    #
    # An actual attempt is now refused out loud; an untouched field is still
    # dropped in silence, because nothing was asked for.
    write_profile(socket, user, credential_params(profile_params, authority?))
  end

  # `username` goes with the other two: it is the second thing
  # `get_user_by_email_or_username_and_password/3` accepts, so rewriting it
  # takes away a sign-in route from an account the actor may not manage.
  @credential_fields ~w(password email username)

  defp credential_params(profile_params, true), do: profile_params
  defp credential_params(profile_params, false), do: Map.drop(profile_params, @credential_fields)

  # Did this submission ask for a credential CHANGE, as opposed to echoing back
  # what is already stored?
  defp credential_change_attempted?(user, params) do
    submitted_password?(params) or
      rewrites?(params, "email", user.email) or
      rewrites?(params, "username", user.username)
  end

  defp submitted_password?(params) do
    case params["password"] do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp rewrites?(params, key, current) do
    case params[key] do
      value when is_binary(value) -> String.trim(value) != to_string(current || "")
      _ -> false
    end
  end

  defp write_profile(socket, user, profile_params) do
    password_provided =
      socket.assigns.show_password_field &&
        Map.has_key?(profile_params, "password") &&
        profile_params["password"] != nil &&
        String.trim(profile_params["password"]) != ""

    result =
      if password_provided do
        update_profile_and_password(socket, user, profile_params)
      else
        cleaned_params = Map.delete(profile_params, "password")
        update_user_profile_without_validation(user, cleaned_params)
      end

    case result do
      {:ok, updated_user} ->
        admin = socket.assigns[:phoenix_kit_current_user]

        # An admin editing their own record reads dates by it from the next render.
        if admin && admin.uuid == updated_user.uuid, do: FormatCountry.put_viewer(updated_user)

        # Build a changeset from old→new to detect what changed
        # Dynamically compare all profile fields instead of hardcoding
        profile_fields =
          ~w(email google_email username first_name last_name user_timezone country)a

        new_values =
          profile_fields
          |> Enum.map(fn field -> {field, Map.get(updated_user, field)} end)
          |> Map.new()

        changeset = Ecto.Changeset.change(user, new_values)

        PhoenixKit.Activity.log_user_change("user.profile_updated", user, changeset,
          actor_uuid: admin && admin.uuid,
          target_uuid: user.uuid,
          mode: "manual",
          actor_role: "admin"
        )

        {:ok, updated_user}

      error ->
        error
    end
  end

  defp update_user_profile_without_validation(user, attrs) do
    changeset = Auth.User.profile_changeset(user, attrs, validate_email: false)

    case changeset |> PhoenixKit.RepoHelper.repo().update() do
      {:ok, updated_user} ->
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
    # Use update_user_fields instead of update_user_custom_fields to preserve existing fields (like avatar_file_uuid)
    case Auth.update_user_fields(user, custom_fields_params) do
      {:ok, updated_user} -> {:ok, updated_user}
      {:error, _changeset} -> {:error, :custom_fields_save}
    end
  end

  # Names that `Auth.update_user_fields/2` routes OUT of `custom_fields` and
  # into the schema: it resolves each key with `String.to_existing_atom/1` and
  # writes the value through `profile_changeset` when the name matches one of
  # these. Read from the context rather than restated here — a copy would go
  # stale the next time a profile field is added there, and silently, since the
  # only symptom is that one field becoming writable through `custom_fields`
  # again.
  defp schema_identity_fields do
    Enum.map(Auth.updatable_profile_fields(), &Atom.to_string/1)
  end

  # Params arrive string-keyed from the wire; a non-map (a client sending
  # `custom_fields=1`) is passed through untouched so the existing validation
  # rejects it, rather than crashing here.
  defp drop_schema_identity_fields(params, socket) when is_map(params) do
    fields = schema_identity_fields()

    case Map.take(params, fields) do
      empty when map_size(empty) == 0 ->
        params

      dropped ->
        # Logged for the same reason the context logs its refusal: this page
        # renders a real input for every one of these names, so a `custom_fields`
        # entry carrying one cannot be produced by the form and is a client
        # composing its own payload. Dropping it silently is correct; dropping it
        # invisibly leaves the one signal an operator would want.
        actor = socket.assigns[:phoenix_kit_current_user]

        Logger.warning(
          "PhoenixKit: dropped schema identity fields #{inspect(Map.keys(dropped))} " <>
            "from custom_fields for #{socket.assigns.user.uuid} " <>
            "submitted by #{(actor && actor.uuid) || "an unauthenticated caller"}"
        )

        Map.drop(params, fields)
    end
  end

  defp drop_schema_identity_fields(params, _socket), do: params

  defp update_account_type_fields(user, user_params) do
    account_type = Map.get(user_params, "account_type")

    if account_type do
      org_uuid = Map.get(user_params, "organization_uuid")
      org_uuid = if org_uuid == "" or is_nil(org_uuid), do: nil, else: org_uuid

      attrs = %{
        "account_type" => account_type,
        "organization_name" => Map.get(user_params, "organization_name"),
        "organization_uuid" => org_uuid
      }

      Auth.change_account_type(user, attrs)
    else
      {:ok, user}
    end
  end

  defp handle_update_result(socket, {:ok, _result} = result, true) do
    {:noreply, socket} = handle_update_result(socket, result, false)

    {:noreply,
     socket
     |> Phoenix.LiveView.clear_flash(:info)
     |> put_flash(
       :error,
       gettext(
         "Saved, but the password, email and username were not changed — you don't have permission to manage this user's credentials."
       )
     )}
  end

  defp handle_update_result(socket, {:ok, %{refused: [_ | _] = refused}}, _refused) do
    fresh_user = Auth.get_user!(socket.assigns.user.uuid)

    {:noreply,
     socket
     |> assign(:user, fresh_user)
     |> reload_changeset_with_updated_user(fresh_user)
     |> put_flash(:warning, roles_refused_message(refused))
     |> push_navigate(to: socket.assigns.return_to)}
  end

  defp handle_update_result(socket, {:ok, _result}, _refused) do
    # _result could be either the updated user or role assignments (from sync_user_roles)
    # In both cases, we need to reload the user from the database to get the fresh data
    user_uuid = socket.assigns.user.uuid
    fresh_user = Auth.get_user!(user_uuid)

    socket =
      socket
      |> assign(:user, fresh_user)
      |> reload_changeset_with_updated_user(fresh_user)
      |> put_flash(:info, "User updated successfully.")
      |> push_navigate(to: socket.assigns.return_to)

    {:noreply, socket}
  end

  defp handle_update_result(socket, {:error, reason}, _refused) do
    error_message = format_role_update_error(reason)

    socket =
      socket
      |> put_flash(:warning, error_message)
      |> push_navigate(to: socket.assigns.return_to)

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

  defp format_role_update_error(:cannot_modify_own_roles) do
    gettext("Cannot modify your own roles")
  end

  defp format_role_update_error(_) do
    "User profile updated but roles failed to update."
  end

  defp roles_refused_message(refused) do
    gettext(
      "Not changed — you can only give or take away roles whose permissions you hold: %{roles}",
      roles: Enum.join(refused, ", ")
    )
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
      |> assign(
        :custom_fields_data,
        merge_custom_fields_data(socket.assigns.custom_fields_data, custom_fields_params)
      )
      |> put_flash(:error, "Please fix the custom field errors below.")

    {:noreply, socket}
  end

  # Submitted params are MERGED over what is already displayed, never swapped
  # in wholesale. A field definition whose stored value is a map or a list
  # renders read-only and without a `name` (see the template), so it is absent
  # from every submission — replacing the assign would blank it out of the page
  # on the first keystroke. Merging also mirrors what the save path does to the
  # column itself: `Auth.update_user_fields/2` merges, so an unsubmitted key
  # keeps its stored value (issue #780).
  defp merge_custom_fields_data(existing, params) when is_map(params) do
    Map.merge(existing || %{}, params)
  end

  defp merge_custom_fields_data(existing, _params), do: existing || %{}

  defp handle_custom_fields_save_error(socket) do
    socket =
      socket
      |> put_flash(:error, "User profile updated but custom fields failed to save.")
      |> push_navigate(to: socket.assigns.return_to)

    {:noreply, socket}
  end

  defp load_user_data(socket, :new, _user_uuid) do
    socket
    |> assign(:user, %Auth.User{})
    |> assign(:user_roles, [])
    |> assign(:organization_members, [])
    |> assign(:available_members, [])
    |> assign(:pending_invitations, [])
  end

  defp load_user_data(socket, :edit, user_uuid) do
    user = Auth.get_user!(user_uuid)
    user_roles = Roles.get_user_roles(user)

    # Load organization members if this is an organization account
    organization_members =
      if socket.assigns.org_accounts_enabled && user.account_type == "organization" do
        Auth.list_organization_members(user.uuid)
      else
        []
      end

    # Load all users for add-member dropdown (persons without an org)
    available_members =
      if socket.assigns.org_accounts_enabled && user.account_type == "organization" do
        Auth.list_available_members_for_organization(user.uuid)
      else
        []
      end

    # Load pending invitations for organization accounts
    pending_invitations =
      if socket.assigns.org_accounts_enabled && user.account_type == "organization" do
        Invitations.list_invitations(user.uuid)
      else
        []
      end

    socket
    |> assign(:user, user)
    |> assign(:user_roles, user_roles)
    |> assign(:pending_roles, user_roles)
    |> assign(:organization_members, organization_members)
    |> assign(:available_members, available_members)
    |> assign(:pending_invitations, pending_invitations)
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
    changeset =
      Auth.User.profile_changeset(user, %{"username" => user.username}, validate_email: false)

    account_type = user.account_type || "person"

    socket
    |> assign(:changeset, changeset)
    |> assign(:current_account_type, account_type)
    |> assign(:form_data, %{
      "email" => user.email || "",
      "google_email" => user.google_email || "",
      "username" => user.username || "",
      "first_name" => user.first_name || "",
      "last_name" => user.last_name || "",
      "user_timezone" => user.user_timezone || "0",
      "account_type" => account_type,
      "organization_name" => user.organization_name || "",
      "organization_uuid" => (user.organization_uuid && to_string(user.organization_uuid)) || ""
    })
    |> assign(:custom_fields_data, user.custom_fields || %{})
  end

  defp page_title(:new), do: gettext("Create User")
  defp page_title(:edit), do: gettext("Edit User")

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

  # The rule itself stays in the context — this only re-asks it at write time
  # instead of reading `@can_manage_credentials`, which is computed once in
  # `mount/3` and can be minutes old by the time the form is submitted.
  #
  # Note what is and is not load-bearing here. `Auth.get_user!/1` does NOT
  # preload `:roles`, so the mounted struct's association is `NotLoaded`,
  # `Auth.has_system_role?/2` takes its querying clause, and
  # `Roles.user_has_role?/2` keys on `user.uuid` alone — the rank half of the
  # answer is therefore already fresh whichever struct is passed, and the same
  # holds for the actor. What the reload buys is the rest: a target deleted
  # since mount answers `false` here instead of being written, and the check
  # keeps its meaning if `load_user_data/3` ever starts preloading `:roles`
  # (at which point the mounted struct WOULD freeze the answer at mount).
  defp credential_authority_now(socket, user) do
    case Auth.get_user(user.uuid) do
      %Auth.User{} = fresh ->
        Auth.can_manage_user_credentials?(fresh, socket.assigns[:phoenix_kit_current_user])

      _ ->
        false
    end
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

          # The context refuses with an atom, not a changeset. Passed straight
          # through, because `merge_password_errors/2` below would call `.errors`
          # on it and take the LiveView down with a `BadMapError`. Reaching this
          # clause means the fresh authority check above and the context's own
          # disagreed, which should not happen — but a crash is a poor way to
          # find that out.
          {:error, :insufficient_permissions} ->
            {:error, :insufficient_permissions}

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

  defp build_audit_context(socket) do
    %{
      admin_user: socket.assigns[:phoenix_kit_current_user],
      ip_address: socket.assigns[:registration_ip],
      user_agent: socket.assigns[:user_agent]
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
      user.uuid == current_user.uuid and roles_changed? ->
        {:error, :cannot_modify_own_roles}

      # If roles haven't changed, skip update
      not roles_changed? ->
        {:ok, user}

      # Roles have changed and it's allowed, update them
      true ->
        case Roles.sync_user_roles(user, pending_roles, actor: current_user) do
          {:ok, %{roles_before: roles_before, roles_after: roles_after}} = result ->
            # Audit the exact delta the transaction applied (before/after captured
            # inside it), not the submitted set — the context silently drops
            # changes the actor isn't authorized to make. Skip the log when
            # nothing actually changed (e.g. a fully-rejected submission),
            # mirroring the LiveView role modal.
            added = roles_after -- roles_before
            removed = roles_before -- roles_after

            if added != [] or removed != [] do
              log_roles_updated(current_user, user, roles_before, roles_after, added, removed)
            end

            result

          error ->
            error
        end
    end
  end

  def handle_info({:media_selected, file_uuids}, socket) do
    # Get the first selected file UUID (single selection mode)
    avatar_file_uuid = List.first(file_uuids)

    # Store avatar selection without saving to database yet
    # Avatar will be saved when "Update User" button is clicked
    socket =
      if avatar_file_uuid do
        Logger.info("Avatar selected (pending save): #{avatar_file_uuid}")

        socket
        |> assign(:pending_avatar_file_uuid, avatar_file_uuid)
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
