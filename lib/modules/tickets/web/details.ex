defmodule PhoenixKit.Modules.Tickets.Web.Details do
  @moduledoc """
  LiveView for displaying ticket details with comments and status management.

  Provides comprehensive ticket detail view including:
  - Full ticket information
  - Status change buttons
  - Public comment thread
  - Internal notes section (for staff)
  - Attachment gallery
  - Status history timeline
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Tickets
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Tickets.enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      if can_access_tickets?(current_user) do
        case Tickets.get_ticket(id, preload: [:user, :assigned_to]) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Ticket not found")
             |> push_navigate(to: Routes.path("/admin/tickets"))}

          ticket ->
            project_title = Settings.get_project_title()

            socket =
              socket
              |> assign(:page_title, "Ticket: #{ticket.title}")
              |> assign(:project_title, project_title)
              |> assign(:ticket, ticket)
              |> assign(:current_user, current_user)
              |> assign(:can_view_internal, can_access_tickets?(current_user))
              |> assign(
                :internal_notes_enabled,
                Settings.get_boolean_setting("tickets_internal_notes_enabled", true)
              )
              |> assign(:comment_form, %{"content" => "", "is_internal" => false})
              |> assign(:show_internal_form, false)
              |> assign(:show_media_selector, false)
              |> assign(
                :attachments_enabled,
                Settings.get_boolean_setting("tickets_attachments_enabled", true)
              )
              |> load_comments()
              |> load_attachments()
              |> load_status_history()

            {:ok, socket}
        end
      else
        {:ok,
         socket
         |> put_flash(:error, "Access denied")
         |> push_navigate(to: Routes.path("/admin"))}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Tickets module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  @impl true
  def handle_event("add_comment", %{"comment" => params}, socket) do
    ticket = socket.assigns.ticket
    current_user = socket.assigns.current_user
    content = Map.get(params, "content", "") |> String.trim()
    is_internal = Map.get(params, "is_internal", "false") == "true"

    if content == "" do
      {:noreply, put_flash(socket, :error, "Comment cannot be empty")}
    else
      result =
        if is_internal do
          Tickets.create_internal_note(ticket.id, current_user.id, %{content: content})
        else
          Tickets.create_comment(ticket.id, current_user.id, %{content: content})
        end

      case result do
        {:ok, _comment} ->
          {:noreply,
           socket
           |> put_flash(:info, if(is_internal, do: "Internal note added", else: "Comment added"))
           |> assign(:comment_form, %{"content" => "", "is_internal" => false})
           |> reload_ticket()
           |> load_comments()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to add comment")}
      end
    end
  end

  @impl true
  def handle_event("toggle_internal_form", _params, socket) do
    {:noreply, assign(socket, :show_internal_form, !socket.assigns.show_internal_form)}
  end

  @impl true
  def handle_event("change_status", %{"status" => new_status}, socket) do
    ticket = socket.assigns.ticket
    current_user = socket.assigns.current_user

    result =
      case new_status do
        "in_progress" -> Tickets.start_progress(ticket, current_user)
        "resolved" -> Tickets.resolve_ticket(ticket, current_user)
        "closed" -> Tickets.close_ticket(ticket, current_user)
        "open" -> Tickets.reopen_ticket(ticket, current_user)
        _ -> {:error, :invalid_status}
      end

    case result do
      {:ok, updated_ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Status updated to #{new_status}")
         |> assign(
           :ticket,
           Tickets.get_ticket!(updated_ticket.id, preload: [:user, :assigned_to])
         )
         |> load_status_history()}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Invalid status transition")}

      {:error, :reopen_not_allowed} ->
        {:noreply, put_flash(socket, :error, "Reopening tickets is not allowed")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  @impl true
  def handle_event("assign_to_me", _params, socket) do
    ticket = socket.assigns.ticket
    current_user = socket.assigns.current_user

    case Tickets.assign_ticket(ticket, current_user.id, current_user) do
      {:ok, updated_ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket assigned to you")
         |> assign(
           :ticket,
           Tickets.get_ticket!(updated_ticket.id, preload: [:user, :assigned_to])
         )
         |> load_status_history()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to assign ticket")}
    end
  end

  @impl true
  def handle_event("delete_comment", %{"id" => comment_id}, socket) do
    case Tickets.get_comment!(comment_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Comment not found")}

      comment ->
        case Tickets.delete_comment(comment) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Comment deleted")
             |> reload_ticket()
             |> load_comments()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete comment")}
        end
    end
  end

  @impl true
  def handle_event("open_media_selector", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, true)}
  end

  @impl true
  def handle_event("close_media_selector", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, false)}
  end

  @impl true
  def handle_event("remove_attachment", %{"id" => attachment_id}, socket) do
    case Tickets.remove_attachment(attachment_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Attachment removed")
         |> load_attachments()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove attachment")}
    end
  end

  @impl true
  def handle_info({:media_selected, file_ids}, socket) do
    ticket = socket.assigns.ticket

    Enum.each(file_ids, fn file_id ->
      Tickets.add_attachment_to_ticket(ticket.id, file_id)
    end)

    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> put_flash(:info, "#{length(file_ids)} file(s) attached")
     |> load_attachments()}
  end

  # Private functions

  defp can_access_tickets?(nil), do: false

  defp can_access_tickets?(user) do
    Roles.user_has_role_owner?(user) or
      Roles.user_has_role_admin?(user) or
      Roles.user_has_role?(user, "SupportAgent")
  end

  defp load_comments(socket) do
    ticket = socket.assigns.ticket

    comments =
      if socket.assigns.can_view_internal do
        Tickets.list_all_comments(ticket.id, preload: [:user])
      else
        Tickets.list_public_comments(ticket.id, preload: [:user])
      end

    public_comments = Enum.filter(comments, &(!&1.is_internal))
    internal_notes = Enum.filter(comments, & &1.is_internal)

    socket
    |> assign(:public_comments, public_comments)
    |> assign(:internal_notes, internal_notes)
  end

  defp load_attachments(socket) do
    ticket = socket.assigns.ticket
    attachments = Tickets.list_ticket_attachments(ticket.id, preload: [:file])
    assign(socket, :attachments, attachments)
  end

  defp load_status_history(socket) do
    ticket = socket.assigns.ticket
    history = Tickets.get_status_history(ticket.id, preload: [:changed_by])
    assign(socket, :status_history, history)
  end

  defp reload_ticket(socket) do
    ticket = Tickets.get_ticket!(socket.assigns.ticket.id, preload: [:user, :assigned_to])
    assign(socket, :ticket, ticket)
  end
end
