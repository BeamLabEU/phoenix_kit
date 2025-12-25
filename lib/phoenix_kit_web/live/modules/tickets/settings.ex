defmodule PhoenixKitWeb.Live.Modules.Tickets.Settings do
  @moduledoc """
  LiveView for configuring the Tickets module settings.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Tickets
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    if can_access_settings?(current_user) do
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:page_title, "Tickets Settings")
        |> assign(:project_title, project_title)
        |> assign(:current_user, current_user)
        |> load_settings()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Access denied")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  @impl true
  def handle_event("toggle_enabled", _params, socket) do
    new_value = !socket.assigns.enabled

    result =
      if new_value do
        Tickets.enable_system()
      else
        Tickets.disable_system()
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, if(new_value, do: "Tickets enabled", else: "Tickets disabled"))
         |> assign(:enabled, new_value)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update setting")}
    end
  end

  @impl true
  def handle_event("toggle_internal_notes", _params, socket) do
    toggle_boolean_setting(
      socket,
      "tickets_internal_notes_enabled",
      :internal_notes_enabled,
      "Internal notes"
    )
  end

  @impl true
  def handle_event("toggle_attachments", _params, socket) do
    toggle_boolean_setting(
      socket,
      "tickets_attachments_enabled",
      :attachments_enabled,
      "Attachments"
    )
  end

  @impl true
  def handle_event("toggle_allow_reopen", _params, socket) do
    toggle_boolean_setting(socket, "tickets_allow_reopen", :allow_reopen, "Allow reopen")
  end

  @impl true
  def handle_event("update_per_page", %{"per_page" => value}, socket) do
    case Settings.update_setting("tickets_per_page", value) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Per page setting updated")
         |> assign(:per_page, String.to_integer(value))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update setting")}
    end
  end

  defp toggle_boolean_setting(socket, key, assign_key, label) do
    current_value = Map.get(socket.assigns, assign_key)
    new_value = !current_value

    case Settings.update_setting(key, to_string(new_value)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{label} #{if new_value, do: "enabled", else: "disabled"}")
         |> assign(assign_key, new_value)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update setting")}
    end
  end

  defp can_access_settings?(nil), do: false

  defp can_access_settings?(user) do
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end

  defp load_settings(socket) do
    socket
    |> assign(:enabled, Tickets.enabled?())
    |> assign(:per_page, Settings.get_setting("tickets_per_page", "20") |> String.to_integer())
    |> assign(
      :internal_notes_enabled,
      Settings.get_boolean_setting("tickets_internal_notes_enabled", true)
    )
    |> assign(
      :attachments_enabled,
      Settings.get_boolean_setting("tickets_attachments_enabled", true)
    )
    |> assign(:allow_reopen, Settings.get_boolean_setting("tickets_allow_reopen", true))
    |> assign(:stats, Tickets.get_stats())
  end
end
