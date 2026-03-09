defmodule PhoenixKit.Modules.Mailing.Web.ListEditor do
  @moduledoc """
  LiveView for creating and editing mailing lists.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Mailing
  alias PhoenixKit.Modules.Mailing.List
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Mailing.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:list, nil)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Mailing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    list = Mailing.get_list!(id)

    {:noreply,
     socket
     |> assign(:page_title, "Edit List: #{list.name}")
     |> assign(:url_path, Routes.path("/admin/mailing/lists/#{id}/edit"))
     |> assign(:list, list)
     |> assign(:form, to_form(List.changeset(list, %{})))}
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:error, "List not found")
       |> push_navigate(to: Routes.path("/admin/mailing/lists"))}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "New List")
     |> assign(:url_path, Routes.path("/admin/mailing/lists/new"))
     |> assign(:list, nil)
     |> assign(:form, to_form(List.changeset(%List{}, %{})))}
  end

  @impl true
  def handle_event("validate", %{"list" => params}, socket) do
    target = socket.assigns.list || %List{}
    changeset = List.changeset(target, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"list" => params}, socket) do
    result =
      case socket.assigns.list do
        nil -> Mailing.create_list(params)
        list -> Mailing.update_list(list, params)
      end

    case result do
      {:ok, _list} ->
        {:noreply,
         socket
         |> put_flash(:info, "List saved successfully")
         |> push_navigate(to: Routes.path("/admin/mailing/lists"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
