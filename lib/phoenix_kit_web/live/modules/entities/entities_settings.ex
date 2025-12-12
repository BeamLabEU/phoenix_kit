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

  ## Live updates

  def handle_info({event, _entity_id}, socket)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    {:noreply, assign(socket, :entities_stats, get_entities_stats())}
  end

  def handle_info({event, _entity_id, _data_id}, socket)
      when event in [:data_created, :data_updated, :data_deleted] do
    {:noreply, assign(socket, :entities_stats, get_entities_stats())}
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
end
