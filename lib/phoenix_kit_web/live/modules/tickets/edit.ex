defmodule PhoenixKitWeb.Live.Modules.Tickets.Edit do
  @moduledoc """
  LiveView for creating and editing support tickets.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Tickets
  alias PhoenixKit.Tickets.Ticket
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    if Tickets.enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      if can_access_tickets?(current_user) do
        socket = load_ticket_or_new(socket, params, current_user)
        {:ok, socket}
      else
        {:ok,
         socket
         |> put_flash(:error, "Access denied")
         |> push_navigate(to: Routes.path("/admin/dashboard"))}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Tickets module is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  defp load_ticket_or_new(socket, %{"id" => id}, current_user) do
    case Tickets.get_ticket(id, preload: [:user, :assigned_to]) do
      nil ->
        socket
        |> put_flash(:error, "Ticket not found")
        |> push_navigate(to: Routes.path("/admin/tickets"))

      ticket ->
        changeset = Ticket.changeset(ticket, %{})
        project_title = Settings.get_setting("project_title", "PhoenixKit")

        socket
        |> assign(:page_title, "Edit Ticket")
        |> assign(:project_title, project_title)
        |> assign(:ticket, ticket)
        |> assign(:changeset, changeset)
        |> assign(:form, to_form(changeset))
        |> assign(:current_user, current_user)
        |> assign(:staff_users, list_support_staff())
        |> assign(:action, :edit)
    end
  end

  defp load_ticket_or_new(socket, _params, current_user) do
    ticket = %Ticket{user_id: current_user.id}
    changeset = Ticket.changeset(ticket, %{})
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket
    |> assign(:page_title, "New Ticket")
    |> assign(:project_title, project_title)
    |> assign(:ticket, ticket)
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
    |> assign(:current_user, current_user)
    |> assign(:all_users, list_all_users())
    |> assign(:action, :new)
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  @impl true
  def handle_event("validate", %{"ticket" => params}, socket) do
    changeset =
      socket.assigns.ticket
      |> Ticket.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"ticket" => params}, socket) do
    save_ticket(socket, socket.assigns.action, params)
  end

  defp save_ticket(socket, :new, params) do
    current_user = socket.assigns.current_user

    # Use the selected user or default to current user
    user_id =
      case Map.get(params, "user_id") do
        nil -> current_user.id
        "" -> current_user.id
        id -> String.to_integer(id)
      end

    case Tickets.create_ticket(user_id, params) do
      {:ok, ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket created successfully")
         |> push_navigate(to: Routes.path("/admin/tickets/#{ticket.id}"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_ticket(socket, :edit, params) do
    case Tickets.update_ticket(socket.assigns.ticket, params) do
      {:ok, ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket updated successfully")
         |> push_navigate(to: Routes.path("/admin/tickets/#{ticket.id}"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp can_access_tickets?(nil), do: false

  defp can_access_tickets?(user) do
    Roles.user_has_role_owner?(user) or
      Roles.user_has_role_admin?(user) or
      Roles.user_has_role?(user, "SupportAgent")
  end

  defp list_all_users do
    # Get all users for customer selection
    %{users: users} = Auth.list_users_paginated(page: 1, page_size: 1000)
    users
  rescue
    _ -> []
  end

  defp list_support_staff do
    # Get users who can handle tickets (for assignment)
    %{users: users} = Auth.list_users_paginated(page: 1, page_size: 1000)

    Enum.filter(users, fn user ->
      Roles.user_has_role_owner?(user) or
        Roles.user_has_role_admin?(user) or
        Roles.user_has_role?(user, "SupportAgent")
    end)
  rescue
    _ -> []
  end
end
