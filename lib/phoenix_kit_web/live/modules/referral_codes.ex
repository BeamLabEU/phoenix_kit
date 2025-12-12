defmodule PhoenixKitWeb.Live.Modules.ReferralCodes do
  @moduledoc """
  Referral codes module settings LiveView for PhoenixKit admin panel.

  Provides module-level configuration and management for the referral codes system.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings

  def mount(_params, _session, socket) do
    # Attach locale hook for automatic locale handling

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load referral codes configuration
    referral_codes_config = ReferralCodes.get_config()

    socket =
      socket
      |> assign(:page_title, "Referral Codes")
      |> assign(:project_title, project_title)
      |> assign(:referral_codes_enabled, referral_codes_config.enabled)
      |> assign(:referral_codes_required, referral_codes_config.required)
      |> assign(:max_uses_per_code, referral_codes_config.max_uses_per_code)
      |> assign(:max_codes_per_user, referral_codes_config.max_codes_per_user)

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

  def handle_event("toggle_referral_codes_required", _params, socket) do
    # Since we're sending "toggle", we just flip the current state
    new_required = !socket.assigns.referral_codes_required

    result = ReferralCodes.set_required(new_required)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:referral_codes_required, new_required)
          |> put_flash(
            :info,
            if(new_required,
              do: "Referral codes are now required",
              else: "Referral codes are now optional"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes requirement setting")
        {:noreply, socket}
    end
  end

  def handle_event("update_max_uses_per_code", %{"max_uses_per_code" => value}, socket) do
    case Integer.parse(value) do
      {max_uses, _} when max_uses > 0 and max_uses <= 10_000 ->
        case ReferralCodes.set_max_uses_per_code(max_uses) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:max_uses_per_code, max_uses)
              |> put_flash(:info, "Maximum uses per code updated to #{max_uses}")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update maximum uses per code")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 10,000")
        {:noreply, socket}
    end
  end

  def handle_event("update_max_codes_per_user", %{"max_codes_per_user" => value}, socket) do
    case Integer.parse(value) do
      {max_codes, _} when max_codes > 0 and max_codes <= 1000 ->
        case ReferralCodes.set_max_codes_per_user(max_codes) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:max_codes_per_user, max_codes)
              |> put_flash(:info, "Maximum codes per user updated to #{max_codes}")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update maximum codes per user")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 1,000")
        {:noreply, socket}
    end
  end
end
