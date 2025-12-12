defmodule PhoenixKitWeb.Live.Settings.Users do
  @moduledoc """
  User-related settings management LiveView for PhoenixKit.

  Consolidates user configuration including:
  - Registration settings
  - New user defaults (role and status)
  - Custom user fields management
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.CustomFields.Events, as: CustomFieldsEvents

  def mount(_params, _session, socket) do
    # Set locale for LiveView process

    # Load current settings
    current_settings = Settings.list_all_settings()
    defaults = Settings.get_defaults()
    setting_options = Settings.get_setting_options()

    # Merge defaults with current settings
    merged_settings = Map.merge(defaults, current_settings)

    # Load custom fields
    field_definitions = CustomFields.list_field_definitions()

    # Create form changeset
    changeset = Settings.change_settings(merged_settings)

    socket =
      socket
      |> assign(:page_title, "User Settings")
      |> assign(:settings, merged_settings)
      |> assign(:saved_settings, merged_settings)
      |> assign(:setting_options, setting_options)
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(:project_title, merged_settings["project_title"] || "PhoenixKit")
      |> assign(:field_definitions, field_definitions)
      |> assign(:editing_field, nil)
      |> assign(:show_field_form, false)

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("validate_settings", %{"settings" => settings_params}, socket) do
    changeset = Settings.validate_settings(settings_params)

    socket =
      socket
      |> assign(:settings, settings_params)
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save_settings", %{"settings" => settings_params}, socket) do
    socket = assign(socket, :saving, true)

    case Settings.update_settings(settings_params) do
      {:ok, updated_settings} ->
        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:saving, false)
          |> put_flash(:info, "User settings updated successfully")

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

    {:noreply, socket}
  end

  def handle_event("show_edit_field_form", %{"key" => key}, socket) do
    field = CustomFields.get_field_definition(key)

    socket =
      socket
      |> assign(:show_field_form, true)
      |> assign(:editing_field, field)

    {:noreply, socket}
  end

  def handle_event("hide_field_form", _params, socket) do
    socket =
      socket
      |> assign(:show_field_form, false)
      |> assign(:editing_field, nil)

    {:noreply, socket}
  end

  def handle_event("save_field", %{"field" => field_params}, socket) do
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
          |> put_flash(:info, "Custom field saved successfully")

        {:noreply, socket}

      {:error, message} when is_binary(message) ->
        socket = put_flash(socket, :error, message)
        {:noreply, socket}

      {:error, changeset} ->
        # Handle Ecto changeset errors with detailed messages
        error_msg =
          case changeset do
            %Ecto.Changeset{} -> format_error_message(changeset)
            _ -> "Failed to save custom field"
          end

        socket = put_flash(socket, :error, error_msg)
        {:noreply, socket}
    end
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
          |> put_flash(:info, "Custom field deleted successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete custom field")
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
                do: "Field '#{field["label"]}' enabled",
                else: "Field '#{field["label"]}' disabled"
              )
            )

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to update field")
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Field not found")}
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
end
