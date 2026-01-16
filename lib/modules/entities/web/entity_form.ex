defmodule PhoenixKit.Modules.Entities.Web.EntityForm do
  @moduledoc """
  LiveView for creating and editing entity schemas.
  Provides form interface for defining entity fields, types, and validation rules.
  """

  use PhoenixKitWeb, :live_view
  on_mount PhoenixKit.Modules.Entities.Web.Hooks

  require Logger

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Modules.Entities.Events
  alias PhoenixKit.Modules.Entities.FieldTypes
  alias PhoenixKit.Modules.Entities.Mirror.Exporter
  alias PhoenixKit.Modules.Entities.Mirror.Storage
  alias PhoenixKit.Modules.Entities.Presence
  alias PhoenixKit.Modules.Entities.PresenceHelpers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.HeroIcons
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Slug

  @impl true
  def mount(%{"id" => id} = _params, _session, socket) do
    # Edit mode
    entity = Entities.get_entity!(String.to_integer(id))
    changeset = Entities.change_entity(entity)

    mount_entity_form(socket, entity, changeset, gettext("Edit Entity"))
  end

  def mount(_params, _session, socket) do
    # Create mode
    entity = %Entities{}
    changeset = Entities.change_entity(entity)

    mount_entity_form(socket, entity, changeset, gettext("New Entity"))
  end

  defp mount_entity_form(socket, entity, _changeset, page_title) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get current fields or initialize empty
    current_fields = entity.fields_definition || []

    # Initialize settings if nil
    entity = Map.update!(entity, :settings, fn settings -> settings || %{} end)

    # Regenerate changeset with initialized entity
    changeset = Entities.change_entity(entity)

    form_key =
      case entity.id do
        nil -> nil
        id -> "entity-#{id}"
      end

    live_source = ensure_live_source(socket)

    socket =
      socket
      |> assign(:page_title, page_title)
      |> assign(:project_title, project_title)
      |> assign(:entity, entity)
      |> assign(:changeset, changeset)
      |> assign(:current_user, current_user)
      |> assign(:fields, current_fields)
      |> assign(:field_types, FieldTypes.for_picker())
      |> assign(:show_field_form, false)
      |> assign(:editing_field_index, nil)
      |> assign(:field_form, new_field_form())
      |> assign(:field_error, nil)
      |> assign(:field_key_manually_set, false)
      |> assign(:show_icon_picker, false)
      |> assign(:icon_search, "")
      |> assign(:selected_category, "All")
      |> assign(:icon_categories, ["All" | HeroIcons.list_categories()])
      |> assign(:available_icons, HeroIcons.list_all_icons())
      |> assign(:form_key, form_key)
      |> assign(:live_source, live_source)
      |> assign(:delete_confirm_index, nil)
      |> assign(:has_unsaved_changes, false)
      |> assign(:mirror_path, Storage.root_path())

    socket =
      if connected?(socket) do
        if form_key && entity.id do
          # Track this user in Presence
          {:ok, _ref} =
            PresenceHelpers.track_editing_session(:entity, entity.id, socket, current_user)

          # Subscribe to presence changes and form events
          PresenceHelpers.subscribe_to_editing(:entity, entity.id)
          Events.subscribe_to_entity_form(form_key)

          # Determine our role (owner or spectator)
          socket = assign_editing_role(socket, entity.id)

          # Load spectator state if we're not the owner
          if socket.assigns.readonly? do
            load_spectator_state(socket, entity.id)
          else
            socket
          end
        else
          # New entity (no lock needed) or no form_key
          socket
          |> assign(:lock_owner?, true)
          |> assign(:readonly?, false)
          |> assign(:lock_owner_user, nil)
          |> assign(:spectators, [])
        end
      else
        # Not connected - no lock logic
        socket
        |> assign(:lock_owner?, true)
        |> assign(:readonly?, false)
        |> assign(:lock_owner_user, nil)
        |> assign(:spectators, [])
      end

    {:ok, socket}
  end

  defp assign_editing_role(socket, entity_id) do
    current_user = socket.assigns[:current_user]

    case PresenceHelpers.get_editing_role(:entity, entity_id, socket.id, current_user.id) do
      {:owner, _presences} ->
        # I'm the owner - I can edit (or same user in different tab)
        socket
        |> assign(:lock_owner?, true)
        |> assign(:readonly?, false)
        |> populate_presence_info(:entity, entity_id)

      {:spectator, _owner_meta, _presences} ->
        # Different user is the owner - I'm read-only
        socket
        |> assign(:lock_owner?, false)
        |> assign(:readonly?, true)
        |> populate_presence_info(:entity, entity_id)
    end
  end

  defp load_spectator_state(socket, entity_id) do
    # Owner might have unsaved changes - sync from their Presence metadata
    case PresenceHelpers.get_lock_owner(:entity, entity_id) do
      %{form_state: form_state} when not is_nil(form_state) ->
        # Apply owner's form state
        changeset_params =
          Map.get(form_state, :changeset_params) || Map.get(form_state, "changeset_params")

        fields = Map.get(form_state, :fields) || Map.get(form_state, "fields")

        if changeset_params && fields do
          changeset = Entities.change_entity(socket.assigns.entity, changeset_params)

          socket
          |> assign(:changeset, changeset)
          |> assign(:fields, fields)
          |> assign(:has_unsaved_changes, true)
        else
          socket
        end

      _ ->
        # No form state to sync
        socket
    end
  end

  @impl true
  def handle_event("validate", %{"entities" => entity_params}, socket) do
    if socket.assigns[:lock_owner?] do
      # Get all current data from the changeset (both changes and original data)
      current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)

      # Convert struct to map and merge with incoming params
      existing_data =
        current_data
        |> Map.from_struct()
        |> Map.drop([:__meta__, :creator, :inserted_at, :updated_at])
        |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

      # Merge existing data with new params (new params override existing)
      entity_params = Map.merge(existing_data, entity_params)

      # Auto-generate slug from display_name during creation (but not editing)
      entity_params =
        if is_nil(socket.assigns.entity.id) do
          # Only auto-generate if display_name changed and slug wasn't manually edited
          display_name = entity_params["display_name"] || ""
          current_slug = entity_params["name"] || ""

          # Check if the current slug was auto-generated from the previous display_name
          previous_display_name = existing_data["display_name"] || ""
          auto_generated_slug = generate_slug_from_name(previous_display_name)

          # If slug matches the auto-generated one or is empty, update it
          if current_slug == "" || current_slug == auto_generated_slug do
            Map.put(entity_params, "name", generate_slug_from_name(display_name))
          else
            # User manually edited the slug, don't overwrite it
            entity_params
          end
        else
          # In edit mode, don't auto-generate
          entity_params
        end

      # Add fields_definition to params for validation
      entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

      # Add current settings to params for validation
      entity_params = Map.put(entity_params, "settings", socket.assigns.entity.settings || %{})

      # Add created_by for new entities during validation so changeset can be valid
      entity_params =
        if socket.assigns.entity.id do
          entity_params
        else
          Map.put(entity_params, "created_by", socket.assigns.current_user.id)
        end

      changeset =
        socket.assigns.entity
        |> Entities.change_entity(entity_params)

      socket = assign(socket, :changeset, changeset)

      reply_with_broadcast(socket)
    else
      # Spectator - ignore local changes, wait for broadcasts
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"entities" => entity_params}, socket) do
    if socket.assigns[:lock_owner?] do
      # Add current fields to entity params
      entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

      # Add current settings to entity params
      entity_params = Map.put(entity_params, "settings", socket.assigns.entity.settings || %{})

      # Add created_by for new entities
      entity_params =
        if socket.assigns.entity.id do
          entity_params
        else
          Map.put(entity_params, "created_by", socket.assigns.current_user.id)
        end

      case save_entity(socket, entity_params) do
        {:ok, _entity} ->
          # Presence will automatically clean up when LiveView process terminates
          locale = socket.assigns[:current_locale] || "en"

          socket =
            socket
            |> put_flash(:info, gettext("Entity saved successfully"))
            |> push_navigate(to: Routes.path("/admin/entities", locale: locale))

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          socket = assign(socket, :changeset, changeset)
          reply_with_broadcast(socket)
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}
    end
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Reload entity from database or reset to empty state
      {entity, fields} =
        if socket.assigns.entity.id do
          # Reload from database
          reloaded_entity = Entities.get_entity!(socket.assigns.entity.id)
          {reloaded_entity, reloaded_entity.fields_definition || []}
        else
          # Reset to empty new entity
          {%Entities{}, []}
        end

      changeset = Entities.change_entity(entity)

      socket =
        socket
        |> assign(:entity, entity)
        |> assign(:changeset, changeset)
        |> assign(:fields, fields)
        |> assign(:show_field_form, false)
        |> assign(:editing_field_index, nil)
        |> assign(:field_form, new_field_form())
        |> assign(:field_error, nil)
        |> assign(:show_icon_picker, false)
        |> assign(:delete_confirm_index, nil)
        |> put_flash(:info, gettext("Changes reset to last saved state"))

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot reset - you are spectating"))}
    end
  end

  # Icon Picker Events

  def handle_event("open_icon_picker", _params, socket) do
    socket = assign(socket, :show_icon_picker, true)
    reply_with_broadcast(socket)
  end

  def handle_event("close_icon_picker", _params, socket) do
    socket =
      assign(socket,
        show_icon_picker: false,
        icon_search: "",
        selected_category: "All"
      )

    reply_with_broadcast(socket)
  end

  def handle_event("stop_propagation", _params, socket) do
    # This event does nothing - it just prevents the click from propagating to the backdrop
    {:noreply, socket}
  end

  def handle_event("generate_entity_slug", _params, socket) do
    if socket.assigns[:lock_owner?] do
      changeset = socket.assigns.changeset

      # Get display_name from changeset
      display_name = Ecto.Changeset.get_field(changeset, :display_name) || ""

      # Don't generate if display_name is empty
      if display_name == "" do
        {:noreply, socket}
      else
        # Generate slug from display_name (snake_case)
        slug = generate_slug_from_name(display_name)

        # Update changeset with generated slug while preserving all other data
        changeset = update_changeset_field(socket, %{"name" => slug})

        socket = assign(socket, :changeset, changeset)
        reply_with_broadcast(socket)
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_icon", %{"icon" => icon_name}, socket) do
    if socket.assigns[:lock_owner?] do
      # Update the changeset with the selected icon while preserving all other data
      changeset = update_changeset_field(socket, %{"icon" => icon_name})

      socket =
        socket
        |> assign(:changeset, changeset)
        |> assign(:show_icon_picker, false)
        |> assign(:icon_search, "")
        |> assign(:selected_category, "All")

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_icon", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Clear the icon field while preserving all other data
      changeset = update_changeset_field(socket, %{"icon" => nil})

      socket = assign(socket, :changeset, changeset)
      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_icons", %{"search" => search_term}, socket) do
    filtered_icons =
      if String.trim(search_term) == "" do
        if socket.assigns.selected_category == "All" do
          HeroIcons.list_all_icons()
        else
          HeroIcons.list_icons_by_category()[socket.assigns.selected_category] || []
        end
      else
        HeroIcons.search_icons(search_term)
      end

    socket =
      socket
      |> assign(:icon_search, search_term)
      |> assign(:available_icons, filtered_icons)

    reply_with_broadcast(socket)
  end

  def handle_event("filter_by_category", %{"category" => category}, socket) do
    filtered_icons =
      if category == "All" do
        HeroIcons.list_all_icons()
      else
        HeroIcons.list_icons_by_category()[category] || []
      end

    socket =
      socket
      |> assign(:selected_category, category)
      |> assign(:available_icons, filtered_icons)
      |> assign(:icon_search, "")

    reply_with_broadcast(socket)
  end

  # Field Management Events

  def handle_event("add_field", _params, socket) do
    if socket.assigns[:lock_owner?] do
      socket =
        socket
        |> assign(:show_field_form, true)
        |> assign(:editing_field_index, nil)
        |> assign(:field_form, new_field_form())
        |> assign(:field_key_manually_set, false)
        |> assign(:field_error, nil)
        |> assign(:delete_confirm_index, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("edit_field", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)
      field = Enum.at(socket.assigns.fields, index)

      socket =
        socket
        |> assign(:show_field_form, true)
        |> assign(:editing_field_index, index)
        |> assign(:field_form, normalize_field_form(field) || %{})
        |> assign(:field_key_manually_set, true)
        |> assign(:field_error, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("cancel_field", _params, socket) do
    socket =
      socket
      |> assign(:show_field_form, false)
      |> assign(:editing_field_index, nil)
      |> assign(:field_form, new_field_form())
      |> assign(:field_key_manually_set, false)
      |> assign(:field_error, nil)

    reply_with_broadcast(socket)
  end

  def handle_event("save_field", %{"field" => field_params}, socket) do
    if socket.assigns[:lock_owner?] do
      field_form = socket.assigns.field_form || %{}
      merged_params = Map.merge(field_form, field_params)
      sanitized_options = sanitize_field_options(merged_params)
      merged_params = Map.put(merged_params, "options", sanitized_options)

      with :ok <- validate_field_requirements(merged_params, sanitized_options),
           :ok <-
             validate_unique_field_key(
               merged_params,
               socket.assigns.fields,
               socket.assigns.editing_field_index
             ),
           {:ok, validated_field} <- FieldTypes.validate_field(merged_params) do
        socket = save_validated_field(socket, validated_field)
        reply_with_broadcast(socket)
      else
        {:error, error_message} ->
          socket = assign(socket, :field_error, error_message)
          reply_with_broadcast(socket)
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot save field - you are spectating"))}
    end
  end

  def handle_event("confirm_delete_field", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, :delete_confirm_index, index)}
  end

  def handle_event("cancel_delete_field", _params, socket) do
    {:noreply, assign(socket, :delete_confirm_index, nil)}
  end

  def handle_event("delete_field", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)
      fields = List.delete_at(socket.assigns.fields, index)

      socket =
        socket
        |> assign(:fields, fields)
        |> assign(:delete_confirm_index, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot delete field - you are spectating"))}
    end
  end

  def handle_event("move_field_up", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)

      if index > 0 do
        fields = move_field(socket.assigns.fields, index, index - 1)
        socket = assign(socket, :fields, fields)
        reply_with_broadcast(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_field_down", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)

      if index < length(socket.assigns.fields) - 1 do
        fields = move_field(socket.assigns.fields, index, index + 1)
        socket = assign(socket, :fields, fields)
        reply_with_broadcast(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_field_form", %{"field" => field_params} = params, socket) do
    if socket.assigns[:lock_owner?] do
      target = Map.get(params, "_target", [])
      manual_key? = manual_key_target?(target)

      field_params =
        if manual_key?, do: field_params, else: Map.delete(field_params, "key")

      # Update field form with live changes
      current_form = normalize_field_form(socket.assigns.field_form)

      updated_form =
        current_form
        |> Map.merge(field_params)
        |> maybe_auto_update_field_key(current_form, socket.assigns.field_key_manually_set,
          editing?: socket.assigns.editing_field_index != nil
        )

      socket =
        socket
        |> assign(:field_form, updated_form)
        |> assign(:field_key_manually_set, manual_key? || socket.assigns.field_key_manually_set)
        # Clear error when user makes changes
        |> assign(:field_error, nil)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_option", _params, socket) do
    if socket.assigns[:lock_owner?] do
      current_options = Map.get(socket.assigns.field_form, "options", [])
      updated_options = current_options ++ [""]

      field_form = Map.put(socket.assigns.field_form, "options", updated_options)
      socket = assign(socket, :field_form, field_form)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_option", %{"index" => index}, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)
      current_options = Map.get(socket.assigns.field_form, "options", [])
      updated_options = List.delete_at(current_options, index)

      field_form = Map.put(socket.assigns.field_form, "options", updated_options)
      socket = assign(socket, :field_form, field_form)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_option", %{"index" => index} = params, socket) do
    if socket.assigns[:lock_owner?] do
      index = String.to_integer(index)

      # Extract value from phx-change format: %{"option" => %{"0" => "value"}}
      value =
        case params do
          %{"option" => option_map} when is_map(option_map) ->
            Map.get(option_map, to_string(index), "")

          %{"value" => v} ->
            v

          _ ->
            ""
        end

      current_options = Map.get(socket.assigns.field_form, "options", [])
      updated_options = List.replace_at(current_options, index, value)

      field_form = Map.put(socket.assigns.field_form, "options", updated_options)
      socket = assign(socket, :field_form, field_form)

      reply_with_broadcast(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("generate_field_key", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Get label from field form
      label = Map.get(socket.assigns.field_form, "label", "")

      # Don't generate if label is empty
      if label == "" do
        {:noreply, socket}
      else
        # Generate key from label (snake_case)
        key = generate_slug_from_name(label)

        # Update field form with generated key
        field_form = Map.put(socket.assigns.field_form, "key", key)
        socket = assign(socket, :field_form, field_form)

        reply_with_broadcast(socket)
      end
    else
      {:noreply, socket}
    end
  end

  # Public Form Configuration Events

  def handle_event("toggle_public_form", _params, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}
      current_enabled = Map.get(current_settings, "public_form_enabled", false)

      updated_settings = Map.put(current_settings, "public_form_enabled", !current_enabled)

      # Initialize default fields when enabling
      updated_settings =
        if current_enabled do
          updated_settings
        else
          Map.put(updated_settings, "public_form_fields", [])
        end

      # Update the entity with new settings
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("update_public_form_setting", params, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}

      # Extract the setting name and value from params
      {setting_name, value} =
        cond do
          Map.has_key?(params, "public_form_title") ->
            {"public_form_title", params["public_form_title"]}

          Map.has_key?(params, "public_form_description") ->
            {"public_form_description", params["public_form_description"]}

          Map.has_key?(params, "public_form_submit_text") ->
            {"public_form_submit_text", params["public_form_submit_text"]}

          Map.has_key?(params, "public_form_success_message") ->
            {"public_form_success_message", params["public_form_success_message"]}

          true ->
            {nil, nil}
        end

      if setting_name do
        updated_settings = Map.put(current_settings, setting_name, value)
        updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
        changeset = Entities.change_entity(updated_entity)

        socket =
          socket
          |> assign(:entity, updated_entity)
          |> assign(:changeset, changeset)

        reply_with_broadcast(socket)
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_public_form_field", %{"field" => field_key}, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}
      current_fields = Map.get(current_settings, "public_form_fields", [])

      # Toggle the field in the list
      updated_fields =
        if field_key in current_fields do
          List.delete(current_fields, field_key)
        else
          current_fields ++ [field_key]
        end

      updated_settings = Map.put(current_settings, "public_form_fields", updated_fields)
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("toggle_security_setting", %{"setting" => setting_key}, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}

      # For metadata, default is true (enabled), so we check != false
      current_value =
        if setting_key == "public_form_collect_metadata" do
          Map.get(current_settings, setting_key) != false
        else
          Map.get(current_settings, setting_key, false)
        end

      updated_settings = Map.put(current_settings, setting_key, !current_value)
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("update_security_action", params, socket) do
    if socket.assigns[:lock_owner?] do
      # Extract the setting key and value from params
      # The select sends the setting name in phx-value-setting and value in the form field
      setting_key = params["setting"]
      # The value comes from the select with the same name as the setting
      value = params[setting_key]

      current_settings = socket.assigns.entity.settings || %{}
      updated_settings = Map.put(current_settings, setting_key, value)
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("reset_form_stats", _params, socket) do
    if socket.assigns[:lock_owner?] do
      current_settings = socket.assigns.entity.settings || %{}
      updated_settings = Map.delete(current_settings, "public_form_stats")
      updated_entity = Map.put(socket.assigns.entity, :settings, updated_settings)
      changeset = Entities.change_entity(updated_entity)

      socket =
        socket
        |> assign(:entity, updated_entity)
        |> assign(:changeset, changeset)
        |> put_flash(:info, gettext("Form statistics have been reset"))

      reply_with_broadcast(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  # Backup Settings Events

  def handle_event("toggle_backup_definitions", _params, socket) do
    if socket.assigns[:lock_owner?] do
      entity = socket.assigns.entity
      current_value = Entities.mirror_definitions_enabled?(entity)
      new_value = !current_value

      # When disabling definitions, also disable data sync
      new_settings =
        if new_value do
          %{"mirror_definitions" => true}
        else
          %{"mirror_definitions" => false, "mirror_data" => false}
        end

      case Entities.update_mirror_settings(entity, new_settings) do
        {:ok, updated_entity} ->
          socket =
            socket
            |> assign(:entity, updated_entity)
            |> assign(:changeset, Entities.change_entity(updated_entity))

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update backup settings"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("toggle_backup_data", _params, socket) do
    if socket.assigns[:lock_owner?] do
      entity = socket.assigns.entity
      current_value = Entities.mirror_data_enabled?(entity)
      new_value = !current_value

      case Entities.update_mirror_settings(entity, %{"mirror_data" => new_value}) do
        {:ok, updated_entity} ->
          socket =
            socket
            |> assign(:entity, updated_entity)
            |> assign(:changeset, Entities.change_entity(updated_entity))

          {:noreply, socket}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update backup settings"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot edit - you are spectating"))}
    end
  end

  def handle_event("export_entity_now", _params, socket) do
    if socket.assigns[:lock_owner?] do
      entity = socket.assigns.entity

      message =
        case Exporter.export_entity(entity) do
          {:ok, _path, :with_data} ->
            gettext("Exported %{name} (definition + records)", name: entity.display_name)

          {:ok, _path, :definition_only} ->
            gettext("Exported %{name} (definition only)", name: entity.display_name)

          {:error, _reason} ->
            nil
        end

      socket =
        if message do
          put_flash(socket, :info, message)
        else
          put_flash(socket, :error, gettext("Export failed"))
        end

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot export - you are spectating"))}
    end
  end

  ## Live updates

  @impl true
  def handle_info({:entity_form_change, form_key, payload, source}, socket) do
    cond do
      socket.assigns.form_key == nil ->
        {:noreply, socket}

      form_key != socket.assigns.form_key ->
        {:noreply, socket}

      source == socket.assigns.live_source ->
        {:noreply, socket}

      true ->
        try do
          socket = apply_remote_entity_form_change(socket, payload)
          {:noreply, socket}
        rescue
          e ->
            Logger.error("Failed to apply remote entity form change: #{inspect(e)}")
            {:noreply, socket}
        end
    end
  end

  def handle_info({:entity_created, _}, socket), do: {:noreply, socket}

  def handle_info({:entity_updated, entity_id}, socket) do
    if socket.assigns.entity.id == entity_id do
      entity = Entities.get_entity!(entity_id)
      locale = socket.assigns[:current_locale] || "en"

      # If entity was archived or unpublished, redirect to entities list
      if entity.status != "published" do
        {:noreply,
         socket
         |> put_flash(
           :warning,
           gettext("Entity '%{name}' was %{status} in another session.",
             name: entity.display_name,
             status: entity.status
           )
         )
         |> redirect(to: Routes.path("/admin/entities", locale: locale))}
      else
        socket =
          socket
          |> refresh_entity_state(entity)
          |> put_flash(:info, gettext("Entity updated in another session."))

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:entity_deleted, entity_id}, socket) do
    if socket.assigns.entity.id == entity_id do
      locale = socket.assigns[:current_locale] || "en"

      socket =
        socket
        |> put_flash(:error, gettext("This entity was deleted in another session."))
        |> push_navigate(to: Routes.path("/admin/entities", locale: locale))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    # Someone joined or left - check if our role changed
    if socket.assigns.entity && socket.assigns.entity.id do
      entity_id = socket.assigns.entity.id
      was_owner = socket.assigns[:lock_owner?]

      # Re-evaluate our role
      socket = assign_editing_role(socket, entity_id)

      # If we were promoted from spectator to owner, reload fresh data
      if !was_owner && socket.assigns[:lock_owner?] do
        entity = Entities.get_entity!(entity_id)

        socket
        |> assign(:entity, entity)
        |> assign(:changeset, Entities.change_entity(entity))
        |> assign(:fields, entity.fields_definition || [])
        |> assign(:has_unsaved_changes, false)
        |> then(&{:noreply, &1})
      else
        # Just a presence update (someone joined/left as spectator)
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Helper Functions

  defp reply_with_broadcast(socket) do
    {:noreply, broadcast_entity_form_state(socket)}
  end

  defp broadcast_entity_form_state(socket, extra \\ %{}) do
    socket =
      if connected?(socket) && socket.assigns[:form_key] && socket.assigns.entity.id &&
           socket.assigns[:lock_owner?] do
        entity_id = socket.assigns.entity.id
        topic = PresenceHelpers.editing_topic(:entity, entity_id)

        payload =
          %{
            changeset_params: extract_entity_changeset_params(socket.assigns.changeset),
            fields: socket.assigns.fields
          }
          |> Map.merge(extra)

        # Update Presence metadata with form state (for spectators to sync)
        Presence.update(self(), topic, socket.id, fn meta ->
          Map.put(meta, :form_state, payload)
        end)

        # Also broadcast for real-time sync to spectators
        Events.broadcast_entity_form_change(socket.assigns.form_key, payload,
          source: socket.assigns.live_source
        )

        socket
      else
        socket
      end

    # Mark that we have unsaved changes
    assign(socket, :has_unsaved_changes, true)
  end

  defp apply_remote_entity_form_change(socket, payload) do
    changeset_params =
      Map.get(payload, :changeset_params) ||
        Map.get(payload, "changeset_params") ||
        extract_entity_changeset_params(socket.assigns.changeset)

    fields = Map.get(payload, :fields) || Map.get(payload, "fields") || socket.assigns.fields

    entity_params =
      changeset_params
      |> Map.put("fields_definition", fields)

    changeset =
      socket.assigns.entity
      |> Entities.change_entity(entity_params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:fields, fields)
    |> assign(:changeset, changeset)
    |> assign(:delete_confirm_index, nil)
    |> assign(:has_unsaved_changes, true)

    # Note: UI-only state (show_icon_picker, icon_search, selected_category,
    # show_field_form, editing_field_index, field_form, field_error, delete_confirm_index)
    # is not synced from remote changes to keep modal and form state local to each user
  end

  defp extract_entity_changeset_params(changeset) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.from_struct()
    |> Map.drop([
      :__meta__,
      :creator,
      :entity_data,
      :fields_definition,
      :inserted_at,
      :updated_at
    ])
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp refresh_entity_state(socket, entity) do
    fields = entity.fields_definition || []

    params =
      socket.assigns.changeset
      |> extract_entity_changeset_params()
      |> Map.put("fields_definition", fields)

    changeset =
      entity
      |> Entities.change_entity(params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:entity, entity)
    |> assign(:fields, fields)
    |> assign(:changeset, changeset)
    |> maybe_update_available_icons()
  end

  defp maybe_update_available_icons(socket) do
    icons =
      cond do
        socket.assigns.icon_search && String.trim(socket.assigns.icon_search) != "" ->
          HeroIcons.search_icons(socket.assigns.icon_search)

        socket.assigns.selected_category == "All" ->
          HeroIcons.list_all_icons()

        true ->
          HeroIcons.list_icons_by_category()[socket.assigns.selected_category] || []
      end

    assign(socket, :available_icons, icons)
  end

  defp sanitize_field_options(params) do
    params
    |> Map.get("options", [])
    |> Enum.reject(&(&1 in [nil, ""] || String.trim(to_string(&1)) == ""))
  end

  defp validate_field_requirements(params, sanitized_options) do
    field_type = params["type"]

    cond do
      field_type in ["select", "radio", "checkbox"] and sanitized_options == [] ->
        {:error, gettext("Field type '%{type}' requires at least one option", type: field_type)}

      field_type == "relation" and params["target_entity"] in [nil, ""] ->
        {:error, gettext("Relation field requires a target entity")}

      true ->
        :ok
    end
  end

  defp save_validated_field(socket, validated_field) do
    fields =
      case socket.assigns.editing_field_index do
        nil -> socket.assigns.fields ++ [validated_field]
        index -> List.replace_at(socket.assigns.fields, index, validated_field)
      end

    socket
    |> assign(:fields, fields)
    |> assign(:show_field_form, false)
    |> assign(:editing_field_index, nil)
    |> assign(:field_form, new_field_form())
    |> assign(:field_error, nil)
  end

  defp save_entity(socket, entity_params) do
    if socket.assigns.entity.id do
      # Reload entity from database to ensure Ecto detects all changes
      # (socket.assigns.entity may have in-memory modifications that mask changes)
      fresh_entity = Entities.get_entity!(socket.assigns.entity.id)
      Entities.update_entity(fresh_entity, entity_params)
    else
      Entities.create_entity(entity_params)
    end
  end

  defp move_field(fields, from_index, to_index) do
    field = Enum.at(fields, from_index)

    fields
    |> List.delete_at(from_index)
    |> List.insert_at(to_index, field)
  end

  defp validate_unique_field_key(field_params, existing_fields, editing_index) do
    new_key = field_params["key"]

    duplicate? =
      existing_fields
      |> Enum.with_index()
      |> Enum.any?(fn {field, index} ->
        field["key"] == new_key && index != editing_index
      end)

    if duplicate? do
      {:error,
       gettext("Field key '%{key}' already exists. Please use a unique key.", key: new_key)}
    else
      :ok
    end
  end

  defp update_changeset_field(socket, new_params) do
    # Get all current data from the changeset (both changes and original data)
    current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)

    # Convert struct to map
    existing_data =
      current_data
      |> Map.from_struct()
      |> Map.drop([:__meta__, :creator, :inserted_at, :updated_at])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    # Merge existing data with new params (new params override existing)
    entity_params = Map.merge(existing_data, new_params)

    # Add fields_definition
    entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

    # Add created_by for new entities
    entity_params =
      if socket.assigns.entity.id do
        entity_params
      else
        Map.put(entity_params, "created_by", socket.assigns.current_user.id)
      end

    socket.assigns.entity
    |> Entities.change_entity(entity_params)
    |> Map.put(:action, :validate)
  end

  # Template Helper Functions

  def field_type_label("text"), do: gettext("Text")
  def field_type_label("textarea"), do: gettext("Text Area")
  def field_type_label("email"), do: gettext("Email")
  def field_type_label("url"), do: gettext("URL")
  def field_type_label("rich_text"), do: gettext("Rich Text Editor")
  def field_type_label("number"), do: gettext("Number")
  def field_type_label("boolean"), do: gettext("Boolean")
  def field_type_label("date"), do: gettext("Date")
  def field_type_label("select"), do: gettext("Select Dropdown")
  def field_type_label("radio"), do: gettext("Radio Buttons")
  def field_type_label("checkbox"), do: gettext("Checkboxes")

  def field_type_label(type_name) do
    case FieldTypes.get_type(type_name) do
      nil -> type_name
      type_info -> type_info.label
    end
  end

  def field_category_label(:basic), do: gettext("Basic")
  def field_category_label(:numeric), do: gettext("Numeric")
  def field_category_label(:boolean), do: gettext("Boolean")
  def field_category_label(:datetime), do: gettext("Date & Time")
  def field_category_label(:choice), do: gettext("Choice")
  def field_category_label(other), do: to_string(other)

  def field_type_icon(type_name) do
    case FieldTypes.get_type(type_name) do
      nil -> "hero-question-mark-circle"
      type_info -> type_info.icon
    end
  end

  def requires_options?(type_name) do
    FieldTypes.requires_options?(type_name)
  end

  def icon_category_label("All"), do: gettext("All")
  def icon_category_label("General"), do: gettext("General")
  def icon_category_label("Content"), do: gettext("Content")
  def icon_category_label("Actions"), do: gettext("Actions")
  def icon_category_label("Navigation"), do: gettext("Navigation")
  def icon_category_label("Communication"), do: gettext("Communication")
  def icon_category_label("Users"), do: gettext("Users")
  def icon_category_label("Business"), do: gettext("Business")
  def icon_category_label("Interface"), do: gettext("Interface")
  def icon_category_label("Tech"), do: gettext("Tech")
  def icon_category_label("Status"), do: gettext("Status")
  def icon_category_label(category), do: category

  def format_stats_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} ->
        PhoenixKit.Utils.Date.format_datetime_with_user_format(datetime)

      _ ->
        iso_string
    end
  end

  def format_stats_datetime(_), do: "-"

  defp ensure_live_source(socket) do
    socket.assigns[:live_source] ||
      (socket.id ||
         "entities-form-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false))
  end

  defp generate_slug_from_name(name) when is_binary(name),
    do: Slug.slugify(name, separator: "_")

  defp generate_slug_from_name(_), do: ""

  defp new_field_form do
    %{
      "type" => "text",
      "key" => "",
      "label" => "",
      "required" => false,
      "default" => "",
      "options" => []
    }
  end

  defp normalize_field_form(nil), do: new_field_form()

  defp normalize_field_form(field) when is_map(field) do
    Enum.reduce(field, %{}, fn {key, value}, acc ->
      cond do
        is_binary(key) -> Map.put(acc, key, value)
        is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        true -> acc
      end
    end)
  end

  defp maybe_auto_update_field_key(updated_form, previous_form, manual?, opts) do
    if manual? || Keyword.get(opts, :editing?, false) do
      updated_form
    else
      auto_update_field_key(updated_form, previous_form)
    end
  end

  defp auto_update_field_key(updated_form, previous_form) do
    label = fetch_form_value(updated_form, "label") || ""
    current_key = fetch_form_value(updated_form, "key") || ""
    previous_label = fetch_form_value(previous_form, "label") || ""
    auto_generated_key = generate_slug_from_name(previous_label)

    if label != "" && (current_key == "" || current_key == auto_generated_key) do
      Map.put(updated_form, "key", generate_slug_from_name(label))
    else
      updated_form
    end
  end

  defp fetch_form_value(form, key) do
    Map.get(form, key) ||
      case key do
        "label" -> Map.get(form, :label)
        "key" -> Map.get(form, :key)
        "type" -> Map.get(form, :type)
        _ -> nil
      end
  end

  defp manual_key_target?(["field", "key"]), do: true
  defp manual_key_target?(_), do: false

  defp populate_presence_info(socket, type, id) do
    # Get all presences sorted by joined_at (FIFO order)
    presences = PresenceHelpers.get_sorted_presences(type, id)

    # Extract owner (first in list) and spectators (rest of list)
    {lock_owner_user, lock_info, spectators} =
      case presences do
        [] ->
          {nil, nil, []}

        [{owner_socket_id, owner_meta} | spectator_list] ->
          # Build owner info - IMPORTANT: use socket_id from KEY not phx_ref
          lock_info = %{
            socket_id: owner_socket_id,
            user_id: owner_meta.user_id
          }

          # Map spectators to expected format with correct socket IDs
          spectators =
            Enum.map(spectator_list, fn {spectator_socket_id, meta} ->
              %{
                socket_id: spectator_socket_id,
                user: meta.user,
                user_id: meta.user_id
              }
            end)

          {owner_meta.user, lock_info, spectators}
      end

    socket
    |> assign(:lock_owner_user, lock_owner_user)
    |> assign(:lock_info, lock_info)
    |> assign(:spectators, spectators)
  end
end
