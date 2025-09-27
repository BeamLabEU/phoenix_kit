defmodule PhoenixKitWeb.Live.ModulesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Module.Languages
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings

  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load module states
    referral_codes_config = ReferralCodes.get_config()
    email_config = PhoenixKit.EmailSystem.get_config()
    languages_config = Languages.get_config()

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
              do: "Referral codes system enabled",
              else: "Referral codes system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_emails", _params, socket) do
    # Toggle email system
    new_enabled = !socket.assigns.email_enabled

    result =
      if new_enabled do
        PhoenixKit.EmailSystem.enable_system()
      else
        PhoenixKit.EmailSystem.disable_system()
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
end
