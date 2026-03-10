defmodule PhoenixKit.Modules.Newsletters.Web.ListMembers do
  @moduledoc """
  LiveView for managing members of a mailing list.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Newsletters
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => list_uuid}, _session, socket) do
    if Newsletters.enabled?() do
      list = Newsletters.get_list!(list_uuid)
      members = Newsletters.list_members(list_uuid)
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "#{list.name} — Members")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/newsletters/lists/#{list_uuid}/members"))
        |> assign(:list, list)
        |> assign(:members, members)
        |> assign(:status_filter, "")
        |> assign(:search_query, "")
        |> assign(:search_results, [])
        |> assign(:show_confirm_modal, false)
        |> assign(:confirm_action, nil)
        |> assign(:confirm_target, nil)
        |> assign(:confirm_title, "")
        |> assign(:confirm_message, "")

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Newsletters module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_event("show_confirm", %{"action" => action} = params, socket) do
    {title, message} = confirm_text(action)

    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, String.to_existing_atom(action))
     |> assign(:confirm_target, params["uuid"])
     |> assign(:confirm_title, title)
     |> assign(:confirm_message, message)}
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
      :add_all_users -> handle_add_all_users(socket)
      :unsubscribe -> handle_unsubscribe(socket, socket.assigns.confirm_target)
      :remove -> handle_remove(socket, socket.assigns.confirm_target)
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    members = Newsletters.list_members(socket.assigns.list.uuid, %{status: status})

    {:noreply,
     socket
     |> assign(:members, members)
     |> assign(:status_filter, status)}
  end

  @impl true
  def handle_event("search_users", %{"query" => query}, socket) do
    results =
      if String.length(String.trim(query)) >= 2 do
        Auth.search_users(query)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  @impl true
  def handle_event("add_member", %{"user-uuid" => user_uuid}, socket) do
    case Newsletters.subscribe_user(socket.assigns.list.uuid, user_uuid) do
      {:ok, _} ->
        members = reload_members(socket)

        {:noreply,
         socket
         |> put_flash(:info, "Member added")
         |> assign(:members, members)
         |> assign(:search_query, "")
         |> assign(:search_results, [])}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add member")}
    end
  end

  defp handle_add_all_users(socket) do
    %{users: users} = Auth.list_users_paginated(page_size: 1000)

    added =
      Enum.reduce(users, 0, fn user, acc ->
        case Newsletters.subscribe_user(socket.assigns.list.uuid, user.uuid) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    members = reload_members(socket)

    {:noreply,
     socket
     |> put_flash(:info, "Added #{added} users to the list")
     |> assign(:members, members)
     |> assign(:search_query, "")
     |> assign(:search_results, [])}
  end

  defp handle_unsubscribe(socket, member_uuid) do
    member = find_member(socket.assigns.members, member_uuid)

    if member do
      case Newsletters.unsubscribe_user(member.list_uuid, member.user_uuid) do
        {:ok, _} ->
          members = reload_members(socket)

          {:noreply,
           socket
           |> put_flash(:info, "Member unsubscribed")
           |> assign(:members, members)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not unsubscribe member")}
      end
    else
      {:noreply, put_flash(socket, :error, "Member not found")}
    end
  end

  defp handle_remove(socket, member_uuid) do
    member = find_member(socket.assigns.members, member_uuid)

    if member do
      repo = PhoenixKit.RepoHelper.repo()

      case repo.delete(member) do
        {:ok, _} ->
          members = reload_members(socket)

          {:noreply,
           socket
           |> put_flash(:info, "Member removed")
           |> assign(:members, members)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not remove member")}
      end
    else
      {:noreply, put_flash(socket, :error, "Member not found")}
    end
  end

  defp confirm_text("add_all_users"),
    do: {"Add All Users", "All registered users will be subscribed to this list."}

  defp confirm_text("unsubscribe"),
    do: {"Unsubscribe Member", "This member will be unsubscribed from the list."}

  defp confirm_text("remove"),
    do: {"Remove Member", "This member will be permanently removed from the list."}

  defp confirm_text(_), do: {"Confirm", "Are you sure?"}

  defp find_member(members, uuid) do
    Enum.find(members, fn m -> to_string(m.uuid) == uuid end)
  end

  defp reload_members(socket) do
    Newsletters.list_members(socket.assigns.list.uuid, %{status: socket.assigns.status_filter})
  end
end
