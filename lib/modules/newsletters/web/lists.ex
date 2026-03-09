defmodule PhoenixKit.Modules.Mailing.Web.Lists do
  @moduledoc """
  LiveView for managing mailing lists.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Mailing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Mailing.enabled?() do
      lists = Mailing.list_lists()
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "Mailing Lists")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/mailing/lists"))
        |> assign(:lists, lists)
        |> assign(:show_confirm_modal, false)
        |> assign(:confirm_action, nil)
        |> assign(:confirm_target, nil)
        |> assign(:confirm_title, "")
        |> assign(:confirm_message, "")

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Mailing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_event("show_confirm", %{"action" => "delete", "uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :delete)
     |> assign(:confirm_target, uuid)
     |> assign(:confirm_title, "Delete List")
     |> assign(:confirm_message, "This list and all its data will be permanently deleted.")}
  end

  @impl true
  def handle_event("hide_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, false)
     |> assign(:confirm_action, nil)
     |> assign(:confirm_target, nil)}
  end

  @impl true
  def handle_event("confirm_action", _params, socket) do
    socket = assign(socket, :show_confirm_modal, false)

    case socket.assigns.confirm_action do
      :delete ->
        handle_delete(socket, socket.assigns.confirm_target)

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_delete(socket, uuid) do
    list = Mailing.get_list!(uuid)

    case Mailing.delete_list(list) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "List deleted")
         |> assign(:lists, Mailing.list_lists())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cannot delete list")}
    end
  end
end
