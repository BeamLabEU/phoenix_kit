defmodule PhoenixKitWeb.Live.Modules do
  @moduledoc """
  Admin modules management LiveView for PhoenixKit.

  Displays available system modules and their configuration status.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Entities
  alias PhoenixKit.Module.Languages
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Pages
  alias PhoenixKitWeb.Live.Modules.Publishing
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Live.Modules.Blogging

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load module states
    referral_codes_config = ReferralCodes.get_config()
    email_config = PhoenixKit.Emails.get_config()
    languages_config = Languages.get_config()
    entities_config = Entities.get_config()
    pages_enabled = Pages.enabled?()
    blogging_enabled = Blogging.enabled?()
    under_construction_config = Maintenance.get_config()
    storage_config = Storage.get_config()

    socket =
      socket
      |> assign(:page_title, "Modules")
      |> assign(:project_title, project_title)
      |> assign(:referral_codes_enabled, referral_codes_config.enabled)
      |> assign(:referral_codes_required, referral_codes_config.required)
      |> assign(:max_uses_per_code, referral_codes_config.max_uses_per_code)
      |> assign(:max_codes_per_user, referral_codes_config.max_codes_per_user)
      |> assign(:email_enabled, email_config.enabled)
      |> assign(:email_save_body, email_config.save_body)
      |> assign(:email_ses_events, email_config.ses_events)
      |> assign(:email_retention_days, email_config.retention_days)
      |> assign(:languages_enabled, languages_config.enabled)
      |> assign(:languages_count, languages_config.language_count)
      |> assign(:languages_enabled_count, languages_config.enabled_count)
      |> assign(:languages_default, languages_config.default_language)
      |> assign(:entities_enabled, entities_config.enabled)
      |> assign(:entities_count, entities_config.entity_count)
      |> assign(:entities_total_data, entities_config.total_data_count)
      |> assign(:pages_enabled, pages_enabled)
      |> assign(:blogging_enabled, blogging_enabled)
      |> assign(:under_construction_module_enabled, under_construction_config.module_enabled)
      |> assign(:under_construction_enabled, under_construction_config.enabled)
      |> assign(:under_construction_header, under_construction_config.header)
      |> assign(:under_construction_subtext, under_construction_config.subtext)
      |> assign(:storage_enabled, storage_config.module_enabled)
      |> assign(:storage_buckets_count, storage_config.buckets_count)
      |> assign(:storage_active_buckets_count, storage_config.active_buckets_count)
      |> assign(:current_locale, locale)

    {:ok, socket}
  end

  def handle_event("toggle_referral_codes", _params, socket) do
    # Since we're sending "toggle", we just flip the current state
    new_enabled = !socket.assigns.referral_codes_enabled

    result =
      if new_enabled do
        ReferralCodes.enable_system()
      else
        ReferralCodes.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:referral_codes_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Referral codes enabled",
              else: "Referral codes disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_emails", _params, socket) do
    # Toggle email system
    new_enabled = !socket.assigns.email_enabled

    result =
      if new_enabled do
        PhoenixKit.Emails.enable_system()
      else
        PhoenixKit.Emails.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Email system enabled",
              else: "Email system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_languages", _params, socket) do
    # Toggle languages
    new_enabled = !socket.assigns.languages_enabled

    result =
      if new_enabled do
        Languages.enable_system()
      else
        Languages.disable_system()
      end

    case result do
      {:ok, _} ->
        # Reload languages configuration to get fresh data
        languages_config = Languages.get_config()

        socket =
          socket
          |> assign(:languages_enabled, new_enabled)
          |> assign(:languages_count, languages_config.language_count)
          |> assign(:languages_enabled_count, languages_config.enabled_count)
          |> assign(:languages_default, languages_config.default_language)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Languages enabled with default English",
              else: "Languages disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update languages")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_entities", _params, socket) do
    # Toggle entities system
    new_enabled = !socket.assigns.entities_enabled

    result =
      if new_enabled do
        Entities.enable_system()
      else
        Entities.disable_system()
      end

    case result do
      {:ok, _} ->
        # Reload entities configuration to get fresh data
        entities_config = Entities.get_config()

        socket =
          socket
          |> assign(:entities_enabled, new_enabled)
          |> assign(:entities_count, entities_config.entity_count)
          |> assign(:entities_total_data, entities_config.total_data_count)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Entities system enabled",
              else: "Entities system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update entities system")
        {:noreply, socket}
    end
  end

<<<<<<< HEAD
  def handle_event("toggle_blogging", _params, socket) do
    new_enabled = !socket.assigns.blogging_enabled

    result =
      if new_enabled do
        Blogging.enable_system()
      else
        Blogging.disable_system()
=======
  def handle_event("toggle_publishing", _params, socket) do
    new_enabled = !socket.assigns.publishing_enabled

    result =
      if new_enabled do
        Publishing.enable_system()
      else
        Publishing.disable_system()
>>>>>>> 0190178 (Add Publishing module for multi-language timestamped content)
      end

    case result do
      {:ok, _} ->
        socket =
          socket
<<<<<<< HEAD
          |> assign(:blogging_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Blogging module enabled",
              else: "Blogging module disabled"
=======
          |> assign(:publishing_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Publishing module enabled",
              else: "Publishing module disabled"
>>>>>>> 0190178 (Add Publishing module for multi-language timestamped content)
            )
          )

        {:noreply, socket}

      {:error, _reason} ->
<<<<<<< HEAD
        {:noreply, put_flash(socket, :error, "Failed to update blogging module")}
=======
        {:noreply, put_flash(socket, :error, "Failed to update publishing module")}
>>>>>>> 0190178 (Add Publishing module for multi-language timestamped content)
    end
  end

  def handle_event("toggle_pages", _params, socket) do
    # Toggle pages system
    new_enabled = !socket.assigns.pages_enabled

    result =
      if new_enabled do
        Pages.enable_system()
      else
        Pages.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:pages_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Pages module enabled",
              else: "Pages module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update pages module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_under_construction", _params, socket) do
    # Toggle under construction module (settings page access)
    new_module_enabled = !socket.assigns.under_construction_module_enabled

    result =
      if new_module_enabled do
        Maintenance.enable_module()
      else
        Maintenance.disable_module()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:under_construction_module_enabled, new_module_enabled)
          |> put_flash(
            :info,
            if(new_module_enabled,
              do: "Maintenance mode module enabled - configure settings to activate",
              else: "Maintenance mode module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update maintenance mode module")
        {:noreply, socket}
    end
  end
end
