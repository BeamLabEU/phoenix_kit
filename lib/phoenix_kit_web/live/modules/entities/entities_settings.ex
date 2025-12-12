defmodule PhoenixKitWeb.Live.Modules.Entities.EntitiesSettings do
  @moduledoc """
  LiveView for managing entities system settings and configuration.
  Provides interface for enabling/disabling entities module and viewing statistics.
  """

  use PhoenixKitWeb, :live_view
  on_mount PhoenixKitWeb.Live.Modules.Entities.Hooks

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData
  alias PhoenixKit.Entities.Events
  alias PhoenixKit.Entities.Mirror.{Exporter, Importer, Storage}
  alias PhoenixKit.Settings

  def mount(_params, _session, socket) do
    # Set locale for LiveView process

    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load current entities settings
    settings = %{
      entities_enabled: Entities.enabled?(),
      auto_generate_slugs: Settings.get_setting("entities_auto_generate_slugs", "true"),
      default_status: Settings.get_setting("entities_default_status", "draft"),
      require_approval: Settings.get_setting("entities_require_approval", "false"),
      max_entities_per_user: Settings.get_setting("entities_max_per_user", "100"),
      data_retention_days: Settings.get_setting("entities_data_retention_days", "365"),
      enable_revisions: Settings.get_setting("entities_enable_revisions", "false"),
      enable_comments: Settings.get_setting("entities_enable_comments", "false")
    }

    changeset = build_changeset(settings)

    socket =
      socket
      |> assign(:page_title, gettext("Entities Settings"))
      |> assign(:project_title, project_title)
      |> assign(:settings, settings)
      |> assign(:changeset, changeset)
      |> assign(:entities_stats, get_entities_stats())
      # Mirror settings
      |> assign(:mirror_definitions_enabled, Storage.definitions_enabled?())
      |> assign(:mirror_data_enabled, Storage.data_enabled?())
      |> assign(:mirror_path, Storage.root_path())
      |> assign(:export_stats, Storage.get_stats())
      |> assign(:import_preview, nil)
      |> assign(:import_selections, %{})
      |> assign(:import_active_tab, nil)
      |> assign(:show_import_modal, false)
      |> assign(:importing, false)
      |> assign(:exporting, false)

    if connected?(socket) do
      Events.subscribe_to_all_data()
    end

    {:ok, socket}
  end

  def handle_event("validate", %{"settings" => settings_params}, socket) do
    changeset = build_changeset(settings_params, :validate)
    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"settings" => settings_params}, socket) do
    changeset = build_changeset(settings_params, :save)

    if changeset.valid? do
      case save_settings(settings_params) do
        :ok ->
          # Refresh settings and stats
          new_settings = %{
            entities_enabled: Entities.enabled?(),
            auto_generate_slugs: Settings.get_setting("entities_auto_generate_slugs", "true"),
            default_status: Settings.get_setting("entities_default_status", "draft"),
            require_approval: Settings.get_setting("entities_require_approval", "false"),
            max_entities_per_user: Settings.get_setting("entities_max_per_user", "100"),
            data_retention_days: Settings.get_setting("entities_data_retention_days", "365"),
            enable_revisions: Settings.get_setting("entities_enable_revisions", "false"),
            enable_comments: Settings.get_setting("entities_enable_comments", "false")
          }

          socket =
            socket
            |> assign(:settings, new_settings)
            |> assign(:changeset, build_changeset(new_settings))
            |> assign(:entities_stats, get_entities_stats())
            |> put_flash(:info, gettext("Entities settings saved successfully"))

          {:noreply, socket}

        {:error, reason} ->
          socket =
            put_flash(
              socket,
              :error,
              gettext("Failed to save settings: %{reason}", reason: reason)
            )

          {:noreply, socket}
      end
    else
      {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("enable_entities", _params, socket) do
    case Entities.enable_system() do
      {:ok, _setting} ->
        settings = Map.put(socket.assigns.settings, :entities_enabled, true)

        socket =
          socket
          |> assign(:settings, settings)
          |> assign(:changeset, build_changeset(settings))
          |> assign(:entities_stats, get_entities_stats())
          |> put_flash(:info, gettext("Entities system enabled successfully"))

        {:noreply, socket}

      {:error, reason} ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("Failed to enable entities: %{reason}", reason: reason)
          )

        {:noreply, socket}
    end
  end

  def handle_event("disable_entities", _params, socket) do
    case Entities.disable_system() do
      {:ok, _setting} ->
        settings = Map.put(socket.assigns.settings, :entities_enabled, false)

        socket =
          socket
          |> assign(:settings, settings)
          |> assign(:changeset, build_changeset(settings))
          |> assign(:entities_stats, get_entities_stats())
          |> put_flash(:info, gettext("Entities system disabled successfully"))

        {:noreply, socket}

      {:error, reason} ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("Failed to disable entities: %{reason}", reason: reason)
          )

        {:noreply, socket}
    end
  end

  def handle_event("reset_to_defaults", _params, socket) do
    default_settings = %{
      entities_enabled: true,
      auto_generate_slugs: "true",
      default_status: "draft",
      require_approval: "false",
      max_entities_per_user: "unlimited",
      data_retention_days: "365",
      enable_revisions: "false",
      enable_comments: "false"
    }

    changeset = build_changeset(default_settings)

    socket =
      socket
      |> assign(:settings, default_settings)
      |> assign(:changeset, changeset)
      |> put_flash(:info, gettext("Settings reset to defaults (not saved yet)"))

    {:noreply, socket}
  end

  ## Mirror & Export Events

  def handle_event("toggle_mirror_definitions", _params, socket) do
    if socket.assigns.mirror_definitions_enabled do
      Storage.disable_definitions()

      socket =
        socket
        |> assign(:mirror_definitions_enabled, false)
        |> assign(:mirror_data_enabled, false)
        |> put_flash(:info, gettext("Entity definitions mirroring disabled"))

      {:noreply, socket}
    else
      Storage.enable_definitions()

      socket =
        socket
        |> assign(:mirror_definitions_enabled, true)
        |> assign(:exporting, true)

      send(self(), :initial_definitions_export)
      {:noreply, socket}
    end
  end

  def handle_event("toggle_mirror_data", _params, socket) do
    if socket.assigns.mirror_data_enabled do
      Storage.disable_data()

      socket =
        socket
        |> assign(:mirror_data_enabled, false)
        |> put_flash(:info, gettext("Entity data mirroring disabled"))

      {:noreply, socket}
    else
      Storage.enable_data()

      socket =
        socket
        |> assign(:mirror_data_enabled, true)
        |> assign(:exporting, true)

      send(self(), :initial_data_export)
      {:noreply, socket}
    end
  end

  def handle_event("export_now", _params, socket) do
    socket = assign(socket, :exporting, true)
    send(self(), :do_full_export)
    {:noreply, socket}
  end

  def handle_event("show_import_modal", _params, socket) do
    preview = Importer.preview_import()

    # Initialize selections based on preview - default to appropriate action
    selections = build_default_selections(preview)
    first_entity = List.first(preview.entities)

    socket =
      socket
      |> assign(:import_preview, preview)
      |> assign(:import_selections, selections)
      |> assign(:import_active_tab, first_entity && first_entity.name)
      |> assign(:show_import_modal, true)

    {:noreply, socket}
  end

  def handle_event("hide_import_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_import_modal, false)
      |> assign(:import_preview, nil)
      |> assign(:import_selections, %{})
      |> assign(:import_active_tab, nil)

    {:noreply, socket}
  end

  def handle_event("set_import_tab", %{"entity" => entity_name}, socket) do
    {:noreply, assign(socket, :import_active_tab, entity_name)}
  end

  def handle_event(
        "set_definition_action",
        %{"entity" => entity_name, "action" => action},
        socket
      ) do
    action_atom = String.to_existing_atom(action)
    selections = put_in(socket.assigns.import_selections, [entity_name, :definition], action_atom)
    {:noreply, assign(socket, :import_selections, selections)}
  end

  def handle_event(
        "set_record_action",
        %{"entity" => entity_name, "slug" => slug, "action" => action},
        socket
      ) do
    action_atom = String.to_existing_atom(action)
    selections = put_in(socket.assigns.import_selections, [entity_name, :data, slug], action_atom)
    {:noreply, assign(socket, :import_selections, selections)}
  end

  def handle_event(
        "set_all_records_action",
        %{"entity" => entity_name, "action" => action},
        socket
      ) do
    action_atom = String.to_existing_atom(action)

    # Find the entity in preview to get all slugs
    entity = Enum.find(socket.assigns.import_preview.entities, &(&1.name == entity_name))

    if entity do
      new_data_selections =
        entity.data
        |> Enum.map(fn record -> {record.slug, action_atom} end)
        |> Map.new()

      selections =
        put_in(socket.assigns.import_selections, [entity_name, :data], new_data_selections)

      {:noreply, assign(socket, :import_selections, selections)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("do_import_entity", %{"entity" => entity_name}, socket) do
    # Only import selections for the specified entity
    entity_selections = Map.get(socket.assigns.import_selections, entity_name, %{})
    filtered_selections = %{entity_name => entity_selections}

    socket =
      socket
      |> assign(:importing, true)
      |> assign(:show_import_modal, false)

    send(self(), {:do_import, filtered_selections})
    {:noreply, socket}
  end

  def handle_event("do_import", _params, socket) do
    socket =
      socket
      |> assign(:importing, true)
      |> assign(:show_import_modal, false)

    send(self(), {:do_import, socket.assigns.import_selections})
    {:noreply, socket}
  end

  def handle_event("refresh_export_stats", _params, socket) do
    socket =
      socket
      |> assign(:export_stats, Storage.get_stats())

    {:noreply, socket}
  end

  ## Live updates

  def handle_info({event, _entity_id}, socket)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    {:noreply, assign(socket, :entities_stats, get_entities_stats())}
  end

  def handle_info({event, _entity_id, _data_id}, socket)
      when event in [:data_created, :data_updated, :data_deleted] do
    {:noreply, assign(socket, :entities_stats, get_entities_stats())}
  end

  ## Mirror background operations

  def handle_info(:initial_definitions_export, socket) do
    {:ok, results} = Exporter.export_all_entities()
    success_count = Enum.count(results, &match?({:ok, _}, &1))

    socket =
      socket
      |> assign(:exporting, false)
      |> assign(:export_stats, Storage.get_stats())
      |> put_flash(
        :info,
        gettext("Definitions mirroring enabled. Exported %{count} definitions.",
          count: success_count
        )
      )

    {:noreply, socket}
  end

  def handle_info(:initial_data_export, socket) do
    {:ok, results} = Exporter.export_all_data()
    success_count = Enum.count(results, &match?({:ok, _}, &1))

    socket =
      socket
      |> assign(:exporting, false)
      |> assign(:export_stats, Storage.get_stats())
      |> put_flash(
        :info,
        gettext("Data mirroring enabled. Exported %{count} records.", count: success_count)
      )

    {:noreply, socket}
  end

  def handle_info(:do_full_export, socket) do
    {:ok, %{definitions: def_count, data: data_count}} = Exporter.export_all()

    socket =
      socket
      |> assign(:exporting, false)
      |> assign(:export_stats, Storage.get_stats())
      |> put_flash(
        :info,
        gettext("Export complete. %{defs} definitions, %{data} records.",
          defs: def_count,
          data: data_count
        )
      )

    {:noreply, socket}
  end

  def handle_info({:do_import, selections}, socket) do
    {:ok, %{definitions: def_results, data: data_results}} = Importer.import_selected(selections)

    def_created = Enum.count(def_results, &match?({:ok, :created, _}, &1))
    def_updated = Enum.count(def_results, &match?({:ok, :updated, _}, &1))
    def_skipped = Enum.count(def_results, &match?({:ok, :skipped, _}, &1))

    data_created = Enum.count(data_results, &match?({:ok, :created, _}, &1))
    data_updated = Enum.count(data_results, &match?({:ok, :updated, _}, &1))
    data_skipped = Enum.count(data_results, &match?({:ok, :skipped, _}, &1))

    socket =
      socket
      |> assign(:importing, false)
      |> assign(:import_preview, nil)
      |> assign(:import_selections, %{})
      |> assign(:export_stats, Storage.get_stats())
      |> assign(:entities_stats, get_entities_stats())
      |> put_flash(
        :info,
        gettext(
          "Import complete. Definitions: %{dc} created, %{du} updated, %{ds} skipped. Data: %{rc} created, %{ru} updated, %{rs} skipped.",
          dc: def_created,
          du: def_updated,
          ds: def_skipped,
          rc: data_created,
          ru: data_updated,
          rs: data_skipped
        )
      )

    {:noreply, socket}
  end

  # Private Functions

  defp build_changeset(settings, action \\ nil) do
    types = %{
      entities_enabled: :boolean,
      auto_generate_slugs: :string,
      default_status: :string,
      require_approval: :string,
      max_entities_per_user: :string,
      data_retention_days: :string,
      enable_revisions: :string,
      enable_comments: :string
    }

    required = [:auto_generate_slugs, :default_status]

    changeset =
      {settings, types}
      |> Ecto.Changeset.cast(settings, Map.keys(types))
      |> Ecto.Changeset.validate_required(required)
      |> Ecto.Changeset.validate_inclusion(:default_status, ["draft", "published", "archived"])
      |> Ecto.Changeset.validate_inclusion(:auto_generate_slugs, ["true", "false"])
      |> Ecto.Changeset.validate_inclusion(:require_approval, ["true", "false"])
      |> Ecto.Changeset.validate_inclusion(:enable_revisions, ["true", "false"])
      |> Ecto.Changeset.validate_inclusion(:enable_comments, ["true", "false"])
      |> validate_max_entities_per_user()
      |> validate_data_retention_days()

    if action do
      Map.put(changeset, :action, action)
    else
      changeset
    end
  end

  defp validate_max_entities_per_user(changeset) do
    case Ecto.Changeset.get_field(changeset, :max_entities_per_user) do
      "unlimited" ->
        changeset

      value when is_binary(value) ->
        case Integer.parse(value) do
          {num, ""} when num > 0 ->
            changeset

          _ ->
            Ecto.Changeset.add_error(
              changeset,
              :max_entities_per_user,
              gettext("must be 'unlimited' or a positive integer")
            )
        end

      _ ->
        Ecto.Changeset.add_error(
          changeset,
          :max_entities_per_user,
          gettext("must be 'unlimited' or a positive integer")
        )
    end
  end

  defp validate_data_retention_days(changeset) do
    case Ecto.Changeset.get_field(changeset, :data_retention_days) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {num, ""} when num > 0 ->
            changeset

          _ ->
            Ecto.Changeset.add_error(
              changeset,
              :data_retention_days,
              gettext("must be a positive integer")
            )
        end

      _ ->
        Ecto.Changeset.add_error(
          changeset,
          :data_retention_days,
          gettext("must be a positive integer")
        )
    end
  end

  defp save_settings(settings_params) do
    settings_to_save = [
      {"entities_auto_generate_slugs", Map.get(settings_params, "auto_generate_slugs", "true")},
      {"entities_default_status", Map.get(settings_params, "default_status", "draft")},
      {"entities_require_approval", Map.get(settings_params, "require_approval", "false")},
      {"entities_max_per_user", Map.get(settings_params, "max_entities_per_user", "100")},
      {"entities_data_retention_days", Map.get(settings_params, "data_retention_days", "365")},
      {"entities_enable_revisions", Map.get(settings_params, "enable_revisions", "false")},
      {"entities_enable_comments", Map.get(settings_params, "enable_comments", "false")}
    ]

    try do
      Enum.each(settings_to_save, fn {key, value} ->
        Settings.update_setting(key, value)
      end)

      :ok
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp get_entities_stats do
    if Entities.enabled?() do
      entities_stats = Entities.get_system_stats()
      data_stats = EntityData.get_data_stats()

      Map.merge(entities_stats, data_stats)
    else
      %{
        total_entities: 0,
        active_entities: 0,
        total_data_records: 0,
        published_records: 0,
        draft_records: 0,
        archived_records: 0
      }
    end
  end

  # Helper functions for templates

  def setting_status_class(enabled) do
    if enabled, do: "badge-success", else: "badge-error"
  end

  def setting_status_text(enabled) do
    if enabled, do: gettext("Enabled"), else: gettext("Disabled")
  end

  def format_retention_period(days) do
    case Integer.parse(days) do
      {num, ""} when num >= 365 ->
        years = div(num, 365)
        remainder = rem(num, 365)

        if remainder == 0 do
          ngettext("%{count} year", "%{count} years", years, count: years)
        else
          gettext("%{years} year(s), %{days} day(s)", years: years, days: remainder)
        end

      {num, ""} when num >= 30 ->
        months = div(num, 30)
        remainder = rem(num, 30)

        if remainder == 0 do
          ngettext("%{count} month", "%{count} months", months, count: months)
        else
          gettext("%{months} month(s), %{days} day(s)", months: months, days: remainder)
        end

      {num, ""} ->
        ngettext("%{count} day", "%{count} days", num, count: num)

      _ ->
        days
    end
  end

  # Build default import selections based on preview
  # - NEW items default to :overwrite (will create)
  # - IDENTICAL items default to :skip (nothing to do)
  # - CHANGED items default to :skip (safe default)
  defp build_default_selections(%{entities: entities}) do
    entities
    |> Enum.map(fn entity ->
      def_action = default_action_for(entity.definition.action)

      data_selections =
        entity.data
        |> Enum.map(fn record ->
          {record.slug, default_action_for(record.action)}
        end)
        |> Map.new()

      {entity.name, %{definition: def_action, data: data_selections}}
    end)
    |> Map.new()
  end

  defp default_action_for(:create), do: :overwrite
  defp default_action_for(:identical), do: :skip
  defp default_action_for(:conflict), do: :skip
  defp default_action_for(_), do: :skip

  # Helper to get current action for a record from selections
  def get_record_action(selections, entity_name, slug) do
    get_in(selections, [entity_name, :data, slug]) || :skip
  end

  def get_definition_action(selections, entity_name) do
    get_in(selections, [entity_name, :definition]) || :skip
  end
end
