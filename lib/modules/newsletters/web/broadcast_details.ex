defmodule PhoenixKit.Modules.Newsletters.Web.BroadcastDetails do
  @moduledoc """
  LiveView for viewing broadcast details and delivery statistics.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Newsletters
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Newsletters.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:broadcast_id, id)
        |> assign(:project_title, project_title)
        |> assign(:broadcast, nil)
        |> assign(:deliveries, [])
        |> assign(:delivery_stats, %{})
        |> assign(:loading, true)
        |> assign(:show_confirm_modal, false)
        |> assign(:confirm_action, nil)
        |> assign(:confirm_target, nil)
        |> assign(:confirm_title, "")
        |> assign(:confirm_message, "")
        |> load_broadcast_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Newsletters module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_event("show_confirm", %{"action" => "cancel_broadcast"}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :cancel_broadcast)
     |> assign(:confirm_title, "Cancel Broadcast")
     |> assign(:confirm_message, "This will stop any remaining deliveries for this broadcast.")}
  end

  @impl true
  def handle_event("hide_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, false)
     |> assign(:confirm_action, nil)}
  end

  @impl true
  def handle_event("confirm_action", _params, socket) do
    socket = assign(socket, :show_confirm_modal, false)

    case socket.assigns.confirm_action do
      :cancel_broadcast ->
        case Newsletters.update_broadcast(socket.assigns.broadcast, %{status: "cancelled"}) do
          {:ok, broadcast} ->
            {:noreply,
             socket
             |> assign(:broadcast, broadcast)
             |> put_flash(:info, "Broadcast cancelled")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to cancel broadcast")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_broadcast_data()}
  end

  # --- Private ---

  defp load_broadcast_data(socket) do
    id = socket.assigns.broadcast_id

    try do
      broadcast = Newsletters.get_broadcast!(id)
      deliveries = Newsletters.list_deliveries(id)
      stats = Newsletters.get_delivery_stats(id)

      socket
      |> assign(:broadcast, broadcast)
      |> assign(:deliveries, deliveries)
      |> assign(:delivery_stats, stats)
      |> assign(:loading, false)
      |> assign(:page_title, broadcast.subject)
      |> assign(:url_path, Routes.path("/admin/newsletters/broadcasts/#{id}"))
    rescue
      Ecto.NoResultsError ->
        socket
        |> assign(:loading, false)
        |> put_flash(:error, "Broadcast not found")
        |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))
    end
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

  defp delivery_badge_class(status) do
    case status do
      "pending" -> "badge-ghost"
      "sent" -> "badge-info"
      "delivered" -> "badge-success"
      "opened" -> "badge-primary"
      "bounced" -> "badge-warning"
      "failed" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp stat_value(stats, key) do
    Map.get(stats, key, 0)
  end
end
