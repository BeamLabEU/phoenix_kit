defmodule PhoenixKit.Modules.Tickets.Web.New do
  @moduledoc """
  LiveView for creating new support tickets from admin panel.

  Admins can create tickets on behalf of users with title, description,
  priority, and optional file attachments.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Tickets
  alias PhoenixKit.Modules.Tickets.Ticket
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Tickets.enabled?() do
      current_user = socket.assigns[:phoenix_kit_current_user]

      ticket = %Ticket{}
      changeset = Ticket.changeset(ticket, %{})

      attachments_enabled =
        Settings.get_boolean_setting("tickets_attachments_enabled", true)

      socket =
        socket
        |> assign(:page_title, gettext("New Ticket"))
        |> assign(:current_user, current_user)
        |> assign(:ticket, ticket)
        |> assign(:form, to_form(changeset))
        |> assign(:pending_file_ids, [])
        |> assign(:pending_files, [])
        |> assign(:attachments_enabled, attachments_enabled)
        |> assign(:upload_errors, [])
        |> maybe_allow_upload(attachments_enabled)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Tickets module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  defp maybe_allow_upload(socket, true) do
    allow_upload(socket, :attachments,
      accept: ~w(.jpg .jpeg .png .gif .webp .pdf .doc .docx .txt),
      max_entries: 5,
      max_file_size: 10_000_000,
      auto_upload: true
    )
  end

  defp maybe_allow_upload(socket, false), do: socket

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
  def handle_event("validate", _params, socket) do
    # Handle file upload validation (when only files change)
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"ticket" => params}, socket) do
    current_user = socket.assigns.current_user

    # First, process any pending uploads
    socket = process_pending_uploads(socket)
    pending_file_ids = socket.assigns.pending_file_ids

    # Determine the user_id for the ticket
    # If admin is creating for a specific user, use that user_id
    # Otherwise use admin's own id
    user_id =
      case params["user_id"] do
        nil -> current_user.id
        "" -> current_user.id
        id -> String.to_integer(id)
      end

    # Merge the determined user_id into params
    params = Map.put(params, "user_id", user_id)

    case Tickets.create_ticket(user_id, params) do
      {:ok, ticket} ->
        # Attach pending files to the newly created ticket
        Enum.each(pending_file_ids, fn file_id ->
          Tickets.add_attachment_to_ticket(ticket.id, file_id)
        end)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Ticket created successfully"))
         |> push_navigate(to: Routes.path("/admin/tickets/#{ticket.id}"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  @impl true
  def handle_event("remove_pending_file", %{"id" => file_id}, socket) do
    pending_file_ids = Enum.reject(socket.assigns.pending_file_ids, &(&1 == file_id))
    pending_files = Enum.reject(socket.assigns.pending_files, &(&1.id == file_id))

    {:noreply,
     socket
     |> assign(:pending_file_ids, pending_file_ids)
     |> assign(:pending_files, pending_files)}
  end

  defp process_pending_uploads(socket) do
    if socket.assigns.attachments_enabled and
         Map.has_key?(socket.assigns, :uploads) and
         socket.assigns.uploads.attachments.entries != [] do
      do_process_uploads(socket)
    else
      socket
    end
  end

  defp do_process_uploads(socket) do
    current_user = socket.assigns.current_user

    uploaded_files =
      consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
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
            Logger.info("Ticket attachment is duplicate with ID: #{file.id}")
            {:ok, file}

          {:ok, file} ->
            Logger.info("Ticket attachment stored with ID: #{file.id}")
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
    |> assign(:pending_file_ids, socket.assigns.pending_file_ids ++ new_file_ids)
    |> assign(:pending_files, socket.assigns.pending_files ++ new_files)
  end
end
