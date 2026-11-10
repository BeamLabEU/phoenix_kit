defmodule PhoenixKitWeb.Live.Settings.Users do
  @moduledoc """
  User-related settings management LiveView for PhoenixKit.

  Consolidates user configuration including:
  - Registration settings
  - New user defaults (role and status)
  - Custom user fields management
  - The shape avatars are drawn in (`PhoenixKit.Users.AvatarShape`)
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.AvatarShape
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.CustomFields.Events, as: CustomFieldsEvents
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Components.ProfileSettingsTabs
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    # Load current settings. S007: this page never renders the OAuth login
    # secrets or AWS keys, so it has no reason to hold their real values in
    # socket state — list_public_settings/0 (an explicit allow list) leaves
    # them out entirely rather than loading and merely not rendering them.
    current_settings = Settings.list_public_settings()
    defaults = Settings.get_defaults()
    setting_options = Settings.get_setting_options()

    # Merge defaults with current settings, then take only the public keys
    # again — defaults still lists the restricted ones (harmless placeholder
    # values), and the merge must not reintroduce them.
    merged_settings =
      Map.merge(defaults, current_settings)
      |> Map.take(Settings.public_setting_keys())

    # Load custom fields
    field_definitions = CustomFields.list_field_definitions()

    # Create form changeset
    changeset = Settings.change_settings(merged_settings)

    socket =
      socket
      |> assign(:page_title, gettext("Users"))
      |> assign(
        :page_subtitle,
        gettext("Manage user registration, defaults, and custom fields")
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:settings, merged_settings)
      |> assign(:saved_settings, merged_settings)
      |> assign(:setting_options, setting_options)
      |> assign(:can_security?, Scope.can?(scope, "settings.security"))
      |> assign(
        :default_role_options,
        default_role_options(scope, setting_options, merged_settings)
      )
      |> assign(:registration_account_type_options, registration_account_type_options())
      |> assign(:role_switcher_custom_roles, role_switcher_custom_roles())
      |> assign(:role_switcher_location_options, role_switcher_options(:location))
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(
        :project_title,
        merged_settings["project_title"] || PhoenixKit.Config.get(:project_title, "PhoenixKit")
      )
      |> assign(:field_definitions, field_definitions)
      |> assign(:editing_field, nil)
      |> assign(:show_field_form, false)
      # Options management for select/radio/checkbox fields
      |> assign(:field_form_type, "text")
      |> assign(:field_form_options, [])
      |> assign(:new_option_value, "")
      |> assign(:profile_hideable_sections, ProfileSettingsTabs.hideable_sections())
      |> assign(:profile_hidden_sections, ProfileSettingsTabs.hidden_sections())
      |> assign(:profile_toggle_rev, 0)
      |> assign(:avatar_shapes, AvatarShape.all())
      |> assign(:avatar_shape, AvatarShape.current())

    {:ok, socket}
  end

  # The tab lives in the URL (`?tab=sessions`); see `UrlTabs`.
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :active_tab, UrlTabs.active(params, tabs()))}
  end

  defp tabs do
    [
      %{id: "registration", label: gettext("Registration"), icon: "hero-user-plus"},
      %{id: "sessions", label: gettext("Sessions"), icon: "hero-shield-check"},
      %{
        id: "redirects",
        label: gettext("Post-Login Redirects"),
        icon: "hero-arrow-right-circle"
      },
      %{id: "defaults", label: gettext("New User Defaults"), icon: "hero-user-circle"},
      %{id: "roles", label: gettext("Roles"), icon: "hero-identification"},
      %{id: "fields", label: gettext("Custom User Fields"), icon: "hero-list-bullet"},
      %{id: "profile_page", label: gettext("Profile Page"), icon: "hero-identification"},
      %{id: "avatars", label: gettext("Avatars"), icon: "hero-user-circle"}
    ]
  end

  # Saved at once, like the profile page's switches.
  def handle_event("set_avatar_shape", %{"shape" => shape}, socket) do
    case AvatarShape.put(shape, actor_uuid: Actor.uuid(socket), source: "settings") do
      :ok ->
        {:noreply, assign(socket, :avatar_shape, shape)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save that change."))}
    end
  end

  def handle_event("toggle_profile_section", %{"section" => name}, socket) do
    case Enum.find(ProfileSettingsTabs.hideable_sections(), &(Atom.to_string(&1) == name)) do
      nil ->
        {:noreply, socket}

      section ->
        hidden? = section not in socket.assigns.profile_hidden_sections

        case ProfileSettingsTabs.set_section_hidden(section, hidden?,
               actor_uuid: Actor.uuid(socket),
               source: "settings"
             ) do
          :ok ->
            {:noreply,
             assign(socket, :profile_hidden_sections, ProfileSettingsTabs.hidden_sections())}

          # The browser already flipped the switch; bumping the revision in
          # the switches' ids re-renders them from the server's state.
          {:error, _} ->
            {:noreply,
             socket
             |> update(:profile_toggle_rev, &(&1 + 1))
             |> put_flash(:error, gettext("Could not save that change."))}
        end
    end
  end

  def handle_event("validate_settings", %{"settings" => settings_params}, socket) do
    settings_params = normalize_settings_params(settings_params)
    changeset = Settings.validate_settings(settings_params)

    socket =
      socket
      # Params carry only what the form actually rendered, and this page has
      # fields behind conditionals (the account-type picker appears once
      # organization accounts are ticked). Assigning the bare params would drop
      # every key that was not on screen, so the field renders empty and its
      # dirty hint claims an unsaved change against a value nobody touched.
      # Submitted values still win; the merge only fills the gaps.
      |> assign(:settings, Map.merge(socket.assigns.saved_settings, settings_params))
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save_settings", %{"settings" => settings_params}, socket) do
    settings_params = normalize_settings_params(settings_params)
    socket = assign(socket, :saving, true)

    case Settings.update_settings(settings_params,
           actor_uuid: Actor.uuid(socket),
           source: "settings",
           scope: socket.assigns[:phoenix_kit_current_scope]
         ) do
      {:ok, updated_settings} ->
        # Keys the save left alone (`settings.security` ones, for a holder
        # without it) keep their values on screen.
        updated_settings = Map.merge(socket.assigns.saved_settings, updated_settings)
        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:saving, false)
          |> put_flash(:info, gettext("User settings updated successfully"))

        {:noreply, socket}

      {:error, errors} ->
        error_msg = format_error_message(errors)

        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, error_msg)

        {:noreply, socket}
    end
  end

  # Custom Fields Events

  def handle_event("show_add_field_form", _params, socket) do
    socket =
      socket
      |> assign(:show_field_form, true)
      |> assign(:editing_field, nil)
      |> assign(:field_form_type, "text")
      |> assign(:field_form_options, [])
      |> assign(:new_option_value, "")

    {:noreply, socket}
  end

  def handle_event("show_edit_field_form", %{"key" => key}, socket) do
    field = CustomFields.get_field_definition(key)

    socket =
      socket
      |> assign(:show_field_form, true)
      |> assign(:editing_field, field)
      |> assign(:field_form_type, (field && field["type"]) || "text")
      |> assign(:field_form_options, (field && field["options"]) || [])
      |> assign(:new_option_value, "")

    {:noreply, socket}
  end

  def handle_event("hide_field_form", _params, socket) do
    socket =
      socket
      |> assign(:show_field_form, false)
      |> assign(:editing_field, nil)
      |> assign(:field_form_type, "text")
      |> assign(:field_form_options, [])
      |> assign(:new_option_value, "")

    {:noreply, socket}
  end

  def handle_event("save_field", %{"field" => field_params}, socket) do
    # Include options from socket assigns for select/radio/checkbox types
    field_params =
      if socket.assigns.field_form_type in ~w(select radio checkbox) do
        Map.put(field_params, "options", socket.assigns.field_form_options)
      else
        field_params
      end

    result =
      if socket.assigns.editing_field do
        # Update existing field
        key = socket.assigns.editing_field["key"]
        CustomFields.update_field_definition(key, field_params)
      else
        # Add new field
        CustomFields.add_field_definition(field_params)
      end

    case result do
      {:ok, _setting} ->
        field_definitions = CustomFields.list_field_definitions()

        socket =
          socket
          |> assign(:field_definitions, field_definitions)
          |> assign(:show_field_form, false)
          |> assign(:editing_field, nil)
          |> assign(:field_form_type, "text")
          |> assign(:field_form_options, [])
          |> assign(:new_option_value, "")
          |> put_flash(:info, gettext("Custom field saved successfully"))

        {:noreply, socket}

      {:error, message} when is_binary(message) ->
        socket = put_flash(socket, :error, message)
        {:noreply, socket}

      {:error, changeset} ->
        # Handle Ecto changeset errors with detailed messages
        error_msg =
          case changeset do
            %Ecto.Changeset{} -> format_error_message(changeset)
            _ -> gettext("Failed to save custom field")
          end

        socket = put_flash(socket, :error, error_msg)
        {:noreply, socket}
    end
  end

  # Options management for select/radio/checkbox fields

  def handle_event("field_type_changed", %{"field" => %{"type" => type}}, socket) do
    {:noreply, assign(socket, :field_form_type, type)}
  end

  def handle_event("update_new_option", %{"key" => "Enter", "value" => value}, socket) do
    # Enter key pressed - add the option
    trimmed = String.trim(value || "")

    if trimmed != "" and trimmed not in socket.assigns.field_form_options do
      socket =
        socket
        |> assign(:field_form_options, socket.assigns.field_form_options ++ [trimmed])
        |> assign(:new_option_value, "")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_new_option", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_option_value, value)}
  end

  def handle_event("add_field_option", _params, socket) do
    value = socket.assigns.new_option_value
    trimmed = String.trim(value || "")

    if trimmed != "" and trimmed not in socket.assigns.field_form_options do
      socket =
        socket
        |> assign(:field_form_options, socket.assigns.field_form_options ++ [trimmed])
        |> assign(:new_option_value, "")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_field_option", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    options = List.delete_at(socket.assigns.field_form_options, index)
    {:noreply, assign(socket, :field_form_options, options)}
  end

  def handle_event("delete_field", %{"key" => key}, socket) do
    case CustomFields.delete_field_definition(key) do
      {:ok, _setting} ->
        # Broadcast field deletion to other LiveViews (e.g., users table)
        CustomFieldsEvents.broadcast_field_deleted(key)

        field_definitions = CustomFields.list_field_definitions()

        socket =
          socket
          |> assign(:field_definitions, field_definitions)
          |> put_flash(:info, gettext("Custom field deleted successfully"))

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to delete custom field"))
        {:noreply, socket}
    end
  end

  def handle_event("toggle_field_enabled", %{"key" => key}, socket) do
    field = CustomFields.get_field_definition(key)

    if field do
      new_enabled = !field["enabled"]

      case CustomFields.update_field_definition(key, %{"enabled" => new_enabled}) do
        {:ok, _setting} ->
          field_definitions = CustomFields.list_field_definitions()

          socket =
            socket
            |> assign(:field_definitions, field_definitions)
            |> put_flash(
              :info,
              if(new_enabled,
                do: gettext("Field '%{label}' enabled", label: field["label"]),
                else: gettext("Field '%{label}' disabled", label: field["label"])
              )
            )

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, gettext("Failed to update field"))
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Field not found"))}
    end
  end

  # Helper functions

  defp format_error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join(", ")
  end

  def get_option_label(value, options) do
    Settings.get_option_label(value, options)
  end

  # Values come from the context (single source, shared with the changeset
  # allowlist); the labels are translated HERE. `gettext/1` needs a literal
  # msgid to extract, so each value gets its own clause — the same arrangement
  # as `PhoenixKitWeb.Components.Core.AdminLabel.preset_text/1`, and
  # `registration_account_type_test.exs` fails if a value ever loses one.
  defp registration_account_type_options do
    Enum.map(Settings.registration_account_type_options(), fn {_msgid, value} ->
      {registration_account_type_label(value), value}
    end)
  end

  @doc false
  def registration_account_type_label("choice"), do: gettext("Visitor chooses")
  def registration_account_type_label("person"), do: gettext("Personal accounts only")
  def registration_account_type_label("organization"), do: gettext("Organization accounts only")

  # Not reachable through the context list; kept so a value added there without
  # a clause degrades to a raw label instead of crashing the settings page.
  def registration_account_type_label(value), do: value

  # The always-on roles arrive as a list of checkbox values, plus the hidden ""
  # that makes unticking every box submit the key at all. The setting stores
  # one comma-separated string of role uuids (`ActiveRole.parse_always_on/1`).
  defp normalize_settings_params(%{"role_switcher_always_on_roles" => roles} = params)
       when is_list(roles) do
    joined = roles |> Enum.reject(&(&1 in ["", nil])) |> Enum.uniq() |> Enum.join(",")
    Map.put(params, "role_switcher_always_on_roles", joined)
  end

  defp normalize_settings_params(params), do: params

  # The custom roles an operator may mark always-on. Owner and Admin are always
  # switchable and User always applies, so the three system roles are not
  # offered.
  defp role_switcher_custom_roles do
    system = Role.system_roles()

    Roles.list_roles()
    |> Enum.reject(&(&1.name in [system.owner, system.admin, system.user]))
    |> Enum.sort_by(& &1.name)
  end

  defp role_switcher_options(:location),
    do: Enum.map(~w(menu header), &{role_switcher_location_label(&1), &1})

  @doc false
  def role_switcher_location_label("menu"), do: gettext("Account menu")
  def role_switcher_location_label("header"), do: gettext("Header (account menu on phones)")
  def role_switcher_location_label(value), do: value

  @doc false
  def always_on_role?(settings, role_uuid),
    do: role_uuid in ActiveRole.parse_always_on(settings["role_switcher_always_on_roles"])

  defp profile_section_label(:google_email), do: gettext("Google email address")
  defp profile_section_label(:custom_fields), do: gettext("Custom fields")
  defp profile_section_label(:email), do: gettext("Change email")
  defp profile_section_label(:start_page), do: gettext("Start page")
  defp profile_section_label(:etcher), do: gettext("Annotation tools reset")
  defp profile_section_label(:password), do: gettext("Password")
  defp profile_section_label(:oauth), do: gettext("Connected sign-in accounts")
  defp profile_section_label(:passkeys), do: gettext("Passkeys")
  defp profile_section_label(:sessions), do: gettext("Sessions")
  defp profile_section_label(:notifications), do: gettext("Notifications")

  # The default-role picker offers the roles this person may hand out
  # (`Roles.can_manage_role?/2`; the save checks it again), plus the saved one
  # so the select shows what is set.
  defp default_role_options(scope, setting_options, settings) do
    manageable = MapSet.new(Roles.manageable_role_names(scope))
    saved = settings["new_user_default_role"]

    Enum.filter(setting_options["new_user_default_role"] || [], fn {_label, name} ->
      name == saved or MapSet.member?(manageable, name)
    end)
  end
end
