defmodule PhoenixKit.Modules.Mailing.Web.Broadcasts do
  @moduledoc """
  LiveView for the broadcasts list in the mailing admin panel.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Mailing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Mailing.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "Broadcasts")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/mailing/broadcasts"))
        |> assign(:broadcasts, [])
        |> assign(:status_filter, "")

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Mailing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = params["status"] || ""

    broadcasts = Mailing.list_broadcasts(%{status: status})

    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:broadcasts, broadcasts)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    params = if status == "", do: %{}, else: %{"status" => status}
    query = URI.encode_query(params)

    path =
      if query == "", do: "/admin/mailing/broadcasts", else: "/admin/mailing/broadcasts?#{query}"

    {:noreply, push_patch(socket, to: Routes.path(path))}
  end

  @impl true
  def handle_event("view_broadcast", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/mailing/broadcasts/#{uuid}"))}
  end

  defp status_badge_class(status) do
    case status do
      "draft" -> "badge-ghost"
      "scheduled" -> "badge-info"
      "sending" -> "badge-warning"
      "sent" -> "badge-success"
      "cancelled" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
