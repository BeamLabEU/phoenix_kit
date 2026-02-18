defmodule PhoenixKit.Modules.Entities.Web.DataForm do
  @moduledoc """
  LiveView for creating and editing entity data records.
  Provides dynamic form interface based on entity schema definition.
  """

  use PhoenixKitWeb, :live_view
  on_mount PhoenixKit.Modules.Entities.Web.Hooks

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Modules.Entities.EntityData
  alias PhoenixKit.Modules.Entities.Events
  alias PhoenixKit.Modules.Entities.FormBuilder
  alias PhoenixKit.Modules.Entities.Multilang
  alias PhoenixKit.Modules.Entities.Presence
  alias PhoenixKit.Modules.Entities.PresenceHelpers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Slug

  @impl true
  def mount(%{"entity_slug" => entity_slug, "id" => id} = params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Edit mode with slug
    entity = Entities.get_entity_by_name(entity_slug)
    data_record = EntityData.get!(id)
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("Edit Data"), locale)
  end

  def mount(%{"entity_id" => entity_id, "id" => id} = params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Edit mode with ID (backwards compat)
    entity = Entities.get_entity!(entity_id)
    data_record = EntityData.get!(id)
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("Edit Data"), locale)
  end

  def mount(%{"entity_slug" => entity_slug} = params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Create mode with slug
    entity = Entities.get_entity_by_name(entity_slug)
    data_record = %EntityData{entity_id: entity.id, entity_uuid: entity.uuid}
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("New Data"), locale)
  end

  def mount(%{"entity_id" => entity_id} = params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Create mode with ID (backwards compat)
    entity = Entities.get_entity!(entity_id)
    data_record = %EntityData{entity_id: entity.id, entity_uuid: entity.uuid}
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("New Data"), locale)
  end

  defp mount_data_form(socket, entity, data_record, changeset, page_title, locale) do
    project_title = Settings.get_project_title()
    current_user = socket.assigns[:phoenix_kit_current_user]

    # For new records, set default status to "published" to avoid validation errors
    changeset =
      if is_nil(data_record.id) do
        Ecto.Changeset.put_change(changeset, :status, "published")
      else
        changeset
      end

    form_record_key =
      case data_record.id do
        nil -> {:new, entity.name}
        id -> id
      end

    live_source = ensure_live_source(socket)

    # Multilang state (driven by Languages module globally)
    multilang_enabled = Multilang.enabled?()
    primary_language = if multilang_enabled, do: Multilang.primary_language(), else: nil
    language_tabs = Multilang.build_language_tabs()

    # Lazy re-key: if global primary changed since this record was saved,
    # restructure data around the new primary language.
    # Also seed _title into JSONB data for backwards compat.
    changeset =
      if multilang_enabled and data_record.id do
        changeset
        |> rekey_data_on_mount()
        |> seed_title_in_data(data_record)
      else
        changeset
      end

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, page_title)
      |> assign(:project_title, project_title)
      |> assign(:entity, entity)
      |> assign(:data_record, data_record)
      |> assign(:changeset, changeset)
      |> assign(:current_user, current_user)
      |> assign(:form_record_key, form_record_key)
      |> assign(:form_record_topic_key, normalize_record_key(form_record_key))
      |> assign(:live_source, live_source)
      |> assign(:has_unsaved_changes, false)
      |> assign(:multilang_enabled, multilang_enabled)
      |> assign(:primary_language, primary_language)
      |> assign(:current_lang, primary_language)
      |> assign(:language_tabs, language_tabs)

    socket =
      if connected?(socket) do
        Events.subscribe_to_entity_data(entity.id)
        Events.subscribe_to_data_form(entity.id, form_record_key)

        socket =
          if data_record.id do
            # Track this user in Presence
            {:ok, _ref} =
              PresenceHelpers.track_editing_session(:data, data_record.id, socket, current_user)

            # Subscribe to presence changes
            PresenceHelpers.subscribe_to_editing(:data, data_record.id)

            # Determine our role (owner or spectator)
            socket = assign_editing_role(socket, data_record.id)

            # Load spectator state if we're not the owner
            if socket.assigns.readonly? do
              load_spectator_state(socket, data_record.id)
            else
              socket
            end
          else
            # New record - no lock needed
            socket
            |> assign(:lock_owner?, true)
            |> assign(:readonly?, false)
            |> assign(:lock_owner_user, nil)
            |> assign(:spectators, [])
          end

        socket
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

  defp assign_editing_role(socket, data_id) do
    current_user = socket.assigns[:current_user]

    case PresenceHelpers.get_editing_role(:data, data_id, socket.id, current_user.id) do
      {:owner, _presences} ->
        # I'm the owner - I can edit (or same user in different tab)
        socket
        |> assign(:lock_owner?, true)
        |> assign(:readonly?, false)
        |> populate_presence_info(:data, data_id)

      {:spectator, _owner_meta, _presences} ->
        # Different user is the owner - I'm read-only
        socket
        |> assign(:lock_owner?, false)
        |> assign(:readonly?, true)
        |> populate_presence_info(:data, data_id)
    end
  end

  defp load_spectator_state(socket, data_id) do
    # Owner might have unsaved changes - sync from their Presence metadata
    case PresenceHelpers.get_lock_owner(:data, data_id) do
      %{form_state: form_state} when not is_nil(form_state) ->
        # Apply owner's form state
        params = Map.get(form_state, :params) || Map.get(form_state, "params")

        if params do
          socket
          |> apply_remote_data_params(params)
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
  def terminate(_reason, _socket) do
    :ok
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    enabled = Multilang.enabled_languages()

    if lang_code in enabled do
      {:noreply, assign(socket, :current_lang, lang_code)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", %{"phoenix_kit_entity_data" => data_params}, socket) do
    if socket.assigns[:lock_owner?] do
      entity_id = socket.assigns.entity.id
      record_id = socket.assigns.data_record.id
      form_data = Map.get(data_params, "data", %{})

      data_params =
        if socket.assigns.data_record.id do
          data_params
        else
          data_params
          |> Map.put("created_by", socket.assigns.current_user.id)
          |> Map.put("created_by_uuid", socket.assigns.current_user.uuid)
        end

      data_params =
        if is_nil(record_id) do
          # Always use the primary language title for slug generation
          current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)
          previous_title = current_data.title || ""

          title =
            if data_params["title"] do
              data_params["title"]
            else
              # On secondary language tab, title param is absent — keep the existing title
              previous_title
            end

          current_slug = data_params["slug"] || ""
          auto_generated_slug = auto_generate_entity_slug(entity_id, record_id, previous_title)

          if current_slug == "" || current_slug == auto_generated_slug do
            Map.put(data_params, "slug", auto_generate_entity_slug(entity_id, record_id, title))
          else
            data_params
          end
        else
          data_params
        end

      current_lang = socket.assigns[:current_lang]

      # Inject _title into form data so it flows through merge_multilang_data
      form_data =
        inject_title_into_form_data(form_data, data_params, current_lang, socket.assigns)

      # On secondary language tabs, preserve primary-language fields that aren't in the form
      data_params = preserve_primary_fields(data_params, socket.assigns.changeset)

      case FormBuilder.validate_data(socket.assigns.entity, form_data, current_lang) do
        {:ok, validated_data} ->
          validated_data =
            inject_title_into_form_data(
              validated_data,
              data_params,
              current_lang,
              socket.assigns
            )

          final_data = merge_multilang_data(socket.assigns, current_lang, validated_data)
          params = Map.put(data_params, "data", final_data)

          changeset =
            socket.assigns.data_record
            |> EntityData.change(params)
            |> Map.put(:action, :validate)

          socket =
            socket
            |> assign(:changeset, changeset)
            |> broadcast_data_form_state(params)

          {:noreply, socket}

        {:error, errors} ->
          # Preserve full multilang data in both changeset and broadcast
          error_data = merge_multilang_data(socket.assigns, current_lang, form_data)
          error_params = Map.put(data_params, "data", error_data)

          changeset =
            socket.assigns.data_record
            |> EntityData.change(error_params)
            |> add_form_errors(errors)
            |> Map.put(:action, :validate)

          socket =
            socket
            |> assign(:changeset, changeset)
            |> broadcast_data_form_state(error_params)

          {:noreply, socket}
      end
    else
      # Spectator - ignore local changes, wait for broadcasts
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"phoenix_kit_entity_data" => data_params}, socket) do
    if socket.assigns[:lock_owner?] do
      # Extract the data field from params
      form_data = Map.get(data_params, "data", %{})

      current_lang = socket.assigns[:current_lang]

      # Inject _title into form data so it flows through merge_multilang_data
      form_data =
        inject_title_into_form_data(form_data, data_params, current_lang, socket.assigns)

      # On secondary language tabs, preserve primary-language fields that aren't in the form
      data_params = preserve_primary_fields(data_params, socket.assigns.changeset)

      # Strip lang_title — it's only used by inject_title_into_form_data, not a schema field
      data_params = Map.delete(data_params, "lang_title")

      # Validate the form data against entity field definitions
      case FormBuilder.validate_data(socket.assigns.entity, form_data, current_lang) do
        {:ok, validated_data} ->
          validated_data =
            inject_title_into_form_data(
              validated_data,
              data_params,
              current_lang,
              socket.assigns
            )

          final_data = merge_multilang_data(socket.assigns, current_lang, validated_data)

          # Add metadata to params
          params =
            data_params
            |> Map.put("data", final_data)
            |> maybe_add_creator_id(socket.assigns.current_user, socket.assigns.data_record)

          case save_data_record(socket, params) do
            {:ok, _data_record} ->
              # Presence will automatically clean up when LiveView process terminates
              # Redirect to entity-specific data navigator after successful creation/update
              entity_name = socket.assigns.entity.name

              socket =
                socket
                |> put_flash(:info, gettext("Data record saved successfully"))
                |> push_navigate(
                  to:
                    Routes.path("/admin/entities/#{entity_name}/data",
                      locale: socket.assigns.current_locale_base
                    )
                )

              {:noreply, socket}

            {:error, %Ecto.Changeset{} = changeset} ->
              socket =
                socket
                |> assign(:changeset, changeset)
                |> broadcast_data_form_state(params)

              {:noreply, socket}
          end

        {:error, errors} ->
          # Preserve full multilang data in both changeset and broadcast
          error_data = merge_multilang_data(socket.assigns, current_lang, form_data)
          error_params = Map.put(data_params, "data", error_data)

          changeset =
            socket.assigns.data_record
            |> EntityData.change(error_params)
            |> add_form_errors(errors)

          error_list =
            Enum.map_join(errors, "; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

          socket =
            socket
            |> assign(:changeset, changeset)
            |> put_flash(
              :error,
              gettext("Field validation errors: %{errors}", errors: error_list)
            )
            |> broadcast_data_form_state(error_params)

          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}
    end
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns[:lock_owner?] do
      # Reload data record from database or reset to empty state
      {data_record, changeset} =
        if socket.assigns.data_record.id do
          # Reload from database
          reloaded_data = EntityData.get_data!(socket.assigns.data_record.id)
          {reloaded_data, EntityData.change(reloaded_data)}
        else
          # Reset to empty new data record
          empty_data = %EntityData{
            entity_id: socket.assigns.entity.id,
            entity_uuid: socket.assigns.entity.uuid
          }

          changeset =
            empty_data
            |> EntityData.change()
            |> Ecto.Changeset.put_change(:status, "published")

          {empty_data, changeset}
        end

      socket =
        socket
        |> assign(:data_record, data_record)
        |> assign(:changeset, changeset)
        |> put_flash(:info, gettext("Changes reset to last saved state"))
        |> broadcast_data_form_state(extract_changeset_params(changeset))

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("Cannot reset - you are spectating"))}
    end
  end

  def handle_event("generate_slug", _params, socket) do
    if socket.assigns[:lock_owner?] do
      changeset = socket.assigns.changeset
      entity_id = socket.assigns.entity.id
      record_id = socket.assigns.data_record.id

      # Get title from changeset (includes both changes and original data)
      title = Ecto.Changeset.get_field(changeset, :title) || ""

      # Don't generate if title is empty
      if title == "" do
        {:noreply, socket}
      else
        # Generate slug from title using shared utility
        slug = auto_generate_entity_slug(entity_id, record_id, title)

        # Get ALL current field values from the changeset
        # This includes both changed values and original struct values
        entity_id = Ecto.Changeset.get_field(changeset, :entity_id)
        status = Ecto.Changeset.get_field(changeset, :status) || "draft"
        data = Ecto.Changeset.get_field(changeset, :data) || %{}
        created_by = Ecto.Changeset.get_field(changeset, :created_by)

        # Build complete params map with ALL required fields
        params = %{
          "entity_id" => entity_id,
          "title" => title,
          "slug" => slug,
          "status" => status,
          "data" => data,
          "created_by" => created_by
        }

        # Update changeset with generated slug while preserving all other fields
        changeset =
          socket.assigns.data_record
          |> EntityData.change(params)
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:changeset, changeset)
          |> broadcast_data_form_state(params)

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  ## Live updates

  @impl true
  def handle_info({:data_form_change, entity_id, record_key, payload, source}, socket) do
    cond do
      source == socket.assigns.live_source ->
        {:noreply, socket}

      entity_id != socket.assigns.entity.id ->
        {:noreply, socket}

      normalize_record_key(record_key) != socket.assigns.form_record_topic_key ->
        {:noreply, socket}

      true ->
        params = Map.get(payload, :params) || Map.get(payload, "params") || %{}

        socket =
          socket
          |> apply_remote_data_params(params)

        {:noreply, socket}
    end
  end

  def handle_info({:data_updated, entity_id, data_id}, socket) do
    cond do
      entity_id != socket.assigns.entity.id ->
        {:noreply, socket}

      socket.assigns.data_record.id != data_id ->
        {:noreply, socket}

      true ->
        data_record = EntityData.get_data!(data_id)
        changeset = EntityData.change(data_record)

        socket =
          socket
          |> assign(:data_record, data_record)
          |> assign(:form_record_key, data_record.id)
          |> assign(:form_record_topic_key, normalize_record_key(data_record.id))
          |> assign(:changeset, changeset)
          |> put_flash(
            :info,
            gettext("Record updated in another session. Showing latest changes.")
          )

        {:noreply, socket}
    end
  end

  def handle_info({:data_deleted, entity_id, data_id}, socket) do
    cond do
      entity_id != socket.assigns.entity.id ->
        {:noreply, socket}

      socket.assigns.data_record.id != data_id ->
        {:noreply, socket}

      true ->
        socket =
          socket
          |> put_flash(:error, gettext("This record was removed in another session."))
          |> push_navigate(
            to:
              Routes.path("/admin/entities/#{socket.assigns.entity.name}/data",
                locale: socket.assigns.current_locale_base
              )
          )

        {:noreply, socket}
    end
  end

  def handle_info({:entity_created, _}, socket), do: {:noreply, socket}

  def handle_info({:entity_updated, entity_id}, socket) do
    if entity_id == socket.assigns.entity.id do
      entity = Entities.get_entity!(entity_id)

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
         |> redirect(
           to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base)
         )}
      else
        socket =
          socket
          |> refresh_entity_assignment(entity)
          |> put_flash(:info, gettext("Entity schema updated. Form revalidated."))

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:entity_deleted, entity_id}, socket) do
    if entity_id == socket.assigns.entity.id do
      socket =
        socket
        |> put_flash(:error, gettext("Entity was deleted in another session."))
        |> push_navigate(
          to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base)
        )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    # Someone joined or left - check if our role changed
    if socket.assigns.data_record && socket.assigns.data_record.id do
      data_id = socket.assigns.data_record.id
      was_owner = socket.assigns[:lock_owner?]

      # Re-evaluate our role
      socket = assign_editing_role(socket, data_id)

      # If we were promoted from spectator to owner, reload fresh data
      if !was_owner && socket.assigns[:lock_owner?] do
        data_record = EntityData.get_data!(data_id)

        socket
        |> assign(:data_record, data_record)
        |> assign(:changeset, EntityData.change(data_record))
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

  # ── Lazy re-keying helpers (primary language change) ────────

  # Re-keys JSONB data in changeset if embedded primary != global primary.
  defp rekey_data_on_mount(changeset) do
    current_data = Ecto.Changeset.get_field(changeset, :data)
    rekeyed = Multilang.maybe_rekey_data(current_data)

    if rekeyed != current_data do
      Ecto.Changeset.put_change(changeset, :data, rekeyed)
    else
      changeset
    end
  end

  # Seeds `_title` into the JSONB data column for existing records on mount.
  # Handles backwards compat: migrates from metadata["translations"] to data[lang]["_title"].
  defp seed_title_in_data(changeset, data_record) do
    data = Ecto.Changeset.get_field(changeset, :data) || %{}

    if Multilang.multilang_data?(data) do
      primary = data["_primary_language"]
      primary_data = Map.get(data, primary, %{})

      if Map.has_key?(primary_data, "_title") do
        changeset
      else
        title = Ecto.Changeset.get_field(changeset, :title)
        do_seed_title(changeset, data, data_record, primary, primary_data, title)
      end
    else
      changeset
    end
  end

  defp do_seed_title(changeset, data, data_record, primary, primary_data, title) do
    # Seed primary _title from the title column
    updated_primary = Map.put(primary_data, "_title", title || "")
    data = Map.put(data, primary, updated_primary)

    # Migrate secondary titles from metadata["translations"]
    metadata = Ecto.Changeset.get_field(changeset, :metadata) || %{}
    {data, metadata} = migrate_title_translations(data, metadata, title)

    changeset = Ecto.Changeset.put_change(changeset, :data, data)

    # Update title column if primary was rekeyed
    changeset = maybe_sync_rekeyed_title(changeset, data, data_record, primary, title)

    if metadata != (Ecto.Changeset.get_field(changeset, :metadata) || %{}) do
      Ecto.Changeset.put_change(changeset, :metadata, metadata)
    else
      changeset
    end
  end

  defp migrate_title_translations(data, metadata, primary_title) do
    translations = metadata["translations"] || %{}

    Enum.reduce(translations, {data, metadata}, fn
      {lang_code, %{"title" => lang_title}}, {d, m}
      when is_binary(lang_title) and lang_title != "" ->
        d = put_secondary_title(d, lang_code, lang_title, primary_title)
        m = clean_title_translation(m, lang_code)
        {d, m}

      _, acc ->
        acc
    end)
  end

  defp put_secondary_title(data, _lang_code, lang_title, primary_title)
       when lang_title == primary_title,
       do: data

  defp put_secondary_title(data, lang_code, lang_title, _primary_title) do
    lang_data = Map.get(data, lang_code, %{})
    Map.put(data, lang_code, Map.put(lang_data, "_title", lang_title))
  end

  defp clean_title_translation(metadata, lang_code) do
    cleaned = metadata |> Map.get("translations", %{}) |> Map.delete(lang_code)

    if map_size(cleaned) == 0,
      do: Map.delete(metadata, "translations"),
      else: Map.put(metadata, "translations", cleaned)
  end

  defp maybe_sync_rekeyed_title(changeset, data, data_record, primary, title) do
    old_embedded = get_in(data_record.data || %{}, ["_primary_language"])

    if old_embedded && old_embedded != primary do
      new_title = get_in(data, [primary, "_title"])

      if is_binary(new_title) and new_title != "" and new_title != title do
        Ecto.Changeset.put_change(changeset, :title, new_title)
      else
        changeset
      end
    else
      changeset
    end
  end

  # Helper Functions

  defp merge_multilang_data(assigns, lang_code, validated_data) do
    existing_data = Ecto.Changeset.get_field(assigns.changeset, :data) || %{}

    cond do
      # Multilang enabled — use language-aware merge
      assigns[:multilang_enabled] == true ->
        Multilang.put_language_data(existing_data, lang_code, validated_data)

      # Multilang disabled but data has multilang structure — preserve it
      # (prevents translation loss if Languages module is temporarily disabled)
      Multilang.multilang_data?(existing_data) ->
        Multilang.put_language_data(existing_data, lang_code, validated_data)

      # Flat data, no multilang — pass through as-is
      true ->
        validated_data
    end
  end

  # When on a secondary language tab, preserve primary-language DB fields.
  # Title on secondary tab goes to JSONB _title via inject_title_into_form_data;
  # the DB title column must keep the primary language value.
  @preserve_fields %{"title" => :title, "slug" => :slug, "status" => :status}

  defp preserve_primary_fields(data_params, changeset) do
    Enum.reduce(@preserve_fields, data_params, fn {str_key, atom_key}, acc ->
      if Map.has_key?(acc, str_key) do
        acc
      else
        value = Ecto.Changeset.get_field(changeset, atom_key)
        if value, do: Map.put(acc, str_key, value), else: acc
      end
    end)
  end

  # Injects _title into form data map so it flows through merge_multilang_data/3.
  # On primary tab: _title comes from data_params["title"] (the DB column field).
  # On secondary tab: _title comes from data_params["lang_title"] (separate input).
  defp inject_title_into_form_data(form_data, data_params, current_lang, assigns) do
    if assigns[:multilang_enabled] == true do
      primary = assigns[:primary_language]

      title =
        if current_lang == primary do
          data_params["title"]
        else
          data_params["lang_title"]
        end

      if is_binary(title) do
        Map.put(form_data, "_title", title)
      else
        # No title submitted — preserve existing _title from JSONB data
        existing_data = Ecto.Changeset.get_field(assigns.changeset, :data) || %{}

        case Multilang.get_raw_language_data(existing_data, current_lang) do
          %{"_title" => existing_title} -> Map.put(form_data, "_title", existing_title)
          _ -> form_data
        end
      end
    else
      form_data
    end
  end

  defp broadcast_data_form_state(socket, params) when is_map(params) do
    socket =
      if connected?(socket) &&
           socket.assigns[:form_record_key] &&
           socket.assigns[:entity] &&
           socket.assigns.data_record.id &&
           socket.assigns[:lock_owner?] do
        data_id = socket.assigns.data_record.id
        topic = PresenceHelpers.editing_topic(:data, data_id)

        payload = %{params: params}

        # Update Presence metadata with form state (for spectators to sync)
        Presence.update(self(), topic, socket.id, fn meta ->
          Map.put(meta, :form_state, payload)
        end)

        # Also broadcast for real-time sync to spectators
        Events.broadcast_data_form_change(
          socket.assigns.entity.id,
          socket.assigns.form_record_key,
          payload,
          source: socket.assigns.live_source
        )

        socket
      else
        socket
      end

    # Mark that we have unsaved changes
    assign(socket, :has_unsaved_changes, true)
  end

  defp apply_remote_data_params(socket, params) when is_map(params) do
    # Build the changeset WITHOUT enforcing validations yet
    # This ensures we capture the exact remote state, even invalid values
    changeset =
      socket.assigns.data_record
      |> Ecto.Changeset.cast(params, [
        :entity_id,
        :title,
        :slug,
        :status,
        :data,
        :metadata,
        :created_by
      ])
      |> Map.put(:action, :validate)

    # Apply changes to get the updated record with remote values
    updated_record = Ecto.Changeset.apply_changes(changeset)

    # Now create a validated changeset for display
    # This will show validation errors but preserve the remote values
    validated_changeset = EntityData.change(updated_record)

    socket
    |> assign(:data_record, updated_record)
    |> assign(:changeset, validated_changeset)
    |> assign(:has_unsaved_changes, true)
  end

  defp refresh_entity_assignment(socket, entity) do
    params = extract_changeset_params(socket.assigns.changeset)

    data_record = %{
      socket.assigns.data_record
      | entity: entity,
        entity_id: entity.id,
        entity_uuid: entity.uuid
    }

    changeset =
      data_record
      |> EntityData.change(params)
      |> Map.put(:action, :validate)

    # Refresh multilang assigns (driven by Languages module globally)
    multilang_enabled = Multilang.enabled?()
    primary_language = if multilang_enabled, do: Multilang.primary_language(), else: nil
    language_tabs = Multilang.build_language_tabs()

    current_lang = socket.assigns[:current_lang]
    enabled_langs = Multilang.enabled_languages()

    # Reset current_lang when multilang is disabled or language was removed
    current_lang =
      cond do
        not multilang_enabled -> nil
        current_lang not in enabled_langs -> primary_language
        true -> current_lang
      end

    socket
    |> assign(:entity, entity)
    |> assign(:data_record, data_record)
    |> assign(:changeset, changeset)
    |> assign(:multilang_enabled, multilang_enabled)
    |> assign(:primary_language, primary_language)
    |> assign(:current_lang, current_lang)
    |> assign(:language_tabs, language_tabs)
  end

  defp extract_changeset_params(changeset) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.from_struct()
    |> Map.take([:entity_id, :title, :slug, :status, :data, :metadata, :created_by])
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp save_data_record(socket, data_params) do
    if socket.assigns.data_record.id do
      EntityData.update(socket.assigns.data_record, data_params)
    else
      EntityData.create(data_params)
    end
  end

  defp maybe_add_creator_id(params, current_user, data_record) do
    if data_record.id do
      # Editing existing record - don't change creator
      params
    else
      # Creating new record - set creator
      params
      |> Map.put("created_by", current_user.id)
      |> Map.put("created_by_uuid", current_user.uuid)
    end
  end

  defp add_form_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn {field_key, field_errors}, acc ->
      Enum.reduce(field_errors, acc, fn error, inner_acc ->
        Ecto.Changeset.add_error(inner_acc, :data, "#{field_key}: #{error}")
      end)
    end)
  end

  defp ensure_live_source(socket) do
    socket.assigns[:live_source] ||
      (socket.id ||
         "entities-data-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false))
  end

  defp normalize_record_key({:new, key}) when is_atom(key), do: "new-#{Atom.to_string(key)}"
  defp normalize_record_key({:new, key}) when is_binary(key), do: "new-#{key}"
  defp normalize_record_key({:new, key}), do: "new-#{to_string(key)}"
  defp normalize_record_key(key) when is_integer(key), do: Integer.to_string(key)
  defp normalize_record_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_record_key(key) when is_binary(key), do: key
  defp normalize_record_key(key), do: to_string(key)

  defp auto_generate_entity_slug(_entity_id, _record_id, title) when title in [nil, ""], do: ""

  defp auto_generate_entity_slug(entity_id, current_record_id, title) do
    title
    |> Slug.slugify()
    |> Slug.ensure_unique(&slug_taken_by_other?(entity_id, &1, current_record_id))
  end

  defp slug_taken_by_other?(_entity_id, "", _current_record_id), do: false

  defp slug_taken_by_other?(entity_id, candidate, current_record_id) do
    case EntityData.get_by_slug(entity_id, candidate) do
      nil ->
        false

      %EntityData{id: id} ->
        is_nil(current_record_id) || id != current_record_id
    end
  end

  defp populate_presence_info(socket, type, id) do
    # Get all presences sorted by joined_at (FIFO order)
    presences = PresenceHelpers.get_sorted_presences(type, id)

    # Extract owner (first in list) and spectators (rest of list)
    {lock_owner_user, lock_info, spectators} =
      case presences do
        [] ->
          {nil, nil, []}

        [{owner_socket_id, owner_meta} | spectator_list] ->
          # Build owner info
          lock_info = %{
            socket_id: owner_socket_id,
            user_id: owner_meta.user_id
          }

          # Map spectators to expected format
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
