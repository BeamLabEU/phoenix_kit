defmodule PhoenixKit.Modules.ReferralCodes.Web.List do
  @moduledoc """
  User referral codes management LiveView for PhoenixKit admin panel.

  Displays and manages referral codes associated with users.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.ReferralCodes
  alias PhoenixKit.Settings

  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load referral codes and stats
    codes = ReferralCodes.list_codes()
    system_stats = ReferralCodes.get_system_stats()
    config = ReferralCodes.get_config()

    socket =
      socket
      |> assign(:page_title, "Referral Codes")
      |> assign(:project_title, project_title)
      |> assign(:codes, codes)
      |> assign(:system_stats, system_stats)
      |> assign(:config, config)

    {:ok, socket}
  end

  def handle_event("delete_code", %{"id" => id}, socket) do
    code = ReferralCodes.get_code!(String.to_integer(id))

    case ReferralCodes.delete_code(code) do
      {:ok, _code} ->
        socket =
          socket
          |> put_flash(:info, "Referral code deleted successfully")
          |> assign(:codes, ReferralCodes.list_codes())
          |> assign(:system_stats, ReferralCodes.get_system_stats())

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete referral code")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_code_status", %{"id" => id}, socket) do
    code = ReferralCodes.get_code!(String.to_integer(id))
    new_status = !code.status

    case ReferralCodes.update_code(code, %{status: new_status}) do
      {:ok, _code} ->
        status_text = if new_status, do: "activated", else: "deactivated"

        socket =
          socket
          |> put_flash(:info, "Referral code #{status_text}")
          |> assign(:codes, ReferralCodes.list_codes())
          |> assign(:system_stats, ReferralCodes.get_system_stats())

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral code status")
        {:noreply, socket}
    end
  end
end
