defmodule PhoenixKitWeb.Live.Tickets.Details do
  @moduledoc """
  LiveView for displaying ticket details to the ticket owner.

  Users can view their own tickets, see public comments (not internal notes),
  and add new comments with optional attachments.

  Security:
  - Users can only view their own tickets (user_id check)
  - Internal notes (is_internal: true) are hidden from users
  - Users cannot change ticket status
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Tickets
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Tickets.enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      case Tickets.get_ticket(id, preload: [:user, :assigned_to]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, gettext("Ticket not found"))
           |> push_navigate(to: Routes.path("/dashboard/tickets"))}

        ticket ->
          # Security: Verify user owns this ticket
          if ticket.user_id != current_user.id do
            {:ok,
             socket
             |> put_flash(:error, gettext("Access denied"))
             |> push_navigate(to: Routes.path("/dashboard/tickets"))}
          else
            attachments_enabled =
              Settings.get_boolean_setting("tickets_attachments_enabled", true)

            socket =
              socket
              |> assign(:page_title, ticket.title)
              |> assign(:ticket, ticket)
              |> assign(:current_user, current_user)
              |> assign(:comment_content, "")
              |> assign(:attachments_enabled, attachments_enabled)
              |> assign(:pending_comment_file_ids, [])
              |> assign(:pending_comment_files, [])
              |> load_public_comments()
              |> load_attachments()
              |> maybe_allow_comment_upload(attachments_enabled)

            {:ok, socket}
          end
      end
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Tickets module is not enabled"))
       |> push_navigate(to: Routes.path("/dashboard"))}
    end
  end

  defp maybe_allow_comment_upload(socket, true) do
    allow_upload(socket, :comment_attachments,
      accept: ~w(.jpg .jpeg .png .gif .webp .pdf .doc .docx .txt),
      max_entries: 3,
      max_file_size: 10_000_000,
      auto_upload: true
    )
  end

  defp maybe_allow_comment_upload(socket, false), do: socket

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  @impl true
  def handle_event("add_comment", %{"comment" => params}, socket) do
    ticket = socket.assigns.ticket
    current_user = socket.assigns.current_user
    content = Map.get(params, "content", "") |> String.trim()

    if content == "" do
      {:noreply, put_flash(socket, :error, gettext("Comment cannot be empty"))}
    else
      # Process any pending uploads first
      socket = process_comment_uploads(socket)
      pending_file_ids = socket.assigns.pending_comment_file_ids

      # Users can only add public comments (is_internal is always false)
      case Tickets.create_comment(ticket.id, current_user.id, %{content: content}) do
        {:ok, comment} ->
          # Attach any pending files to the comment
          Enum.each(pending_file_ids, fn file_id ->
            Tickets.add_attachment_to_comment(comment.id, file_id)
          end)

          {:noreply,
           socket
           |> put_flash(:info, gettext("Comment added"))
           |> assign(:comment_content, "")
           |> assign(:pending_comment_file_ids, [])
           |> assign(:pending_comment_files, [])
           |> reload_ticket()
           |> load_public_comments()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to add comment"))}
      end
    end
  end

  @impl true
  def handle_event("validate", _params, socket) do
    # Handle file upload validation
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :comment_attachments, ref)}
  end

  @impl true
  def handle_event("remove_pending_comment_file", %{"id" => file_id}, socket) do
    pending_file_ids = Enum.reject(socket.assigns.pending_comment_file_ids, &(&1 == file_id))
    pending_files = Enum.reject(socket.assigns.pending_comment_files, &(&1.id == file_id))

    {:noreply,
     socket
     |> assign(:pending_comment_file_ids, pending_file_ids)
     |> assign(:pending_comment_files, pending_files)}
  end

  # Private functions

  defp load_public_comments(socket) do
    ticket = socket.assigns.ticket
    # Only load public comments - exclude internal notes
    comments = Tickets.list_public_comments(ticket.id, preload: [:user])
    assign(socket, :comments, comments)
  end

  defp load_attachments(socket) do
    ticket = socket.assigns.ticket
    attachments = Tickets.list_ticket_attachments(ticket.id, preload: [:file])
    assign(socket, :attachments, attachments)
  end

  defp reload_ticket(socket) do
    ticket = Tickets.get_ticket!(socket.assigns.ticket.id, preload: [:user, :assigned_to])
    assign(socket, :ticket, ticket)
  end

  defp process_comment_uploads(socket) do
    if socket.assigns.attachments_enabled and
         Map.has_key?(socket.assigns, :uploads) and
         socket.assigns.uploads.comment_attachments.entries != [] do
      do_process_comment_uploads(socket)
    else
      socket
    end
  end

  defp do_process_comment_uploads(socket) do
    current_user = socket.assigns.current_user

    uploaded_files =
      consume_uploaded_entries(socket, :comment_attachments, fn %{path: path}, entry ->
        ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
        user_id = current_user.id

        {:ok, _stat} = File.stat(path)
        file_hash = Auth.calculate_file_hash(path)

        case Storage.store_file_in_buckets(
               path,
               "document",
               user_id,
               file_hash,
               ext,
               entry.client_name
             ) do
          {:ok, file, :duplicate} ->
            Logger.info("Comment attachment is duplicate with ID: #{file.id}")
            {:ok, file}

          {:ok, file} ->
            Logger.info("Comment attachment stored with ID: #{file.id}")
            {:ok, file}

          {:error, reason} ->
            Logger.error("Storage Error: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    # Extract successful uploads
    new_files =
      uploaded_files
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, file} -> file end)

    new_file_ids = Enum.map(new_files, & &1.id)

    socket
    |> assign(:pending_comment_file_ids, socket.assigns.pending_comment_file_ids ++ new_file_ids)
    |> assign(:pending_comment_files, socket.assigns.pending_comment_files ++ new_files)
  end
end
