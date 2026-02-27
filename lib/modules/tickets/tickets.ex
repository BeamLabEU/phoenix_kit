defmodule PhoenixKit.Modules.Tickets do
  @moduledoc """
  Context for managing support tickets, comments, and attachments.

  Provides complete API for the customer support ticketing system including
  CRUD operations, status workflow, comment threading with internal notes,
  file attachments, and audit trail.

  ## Features

  - **Ticket Management**: Create, update, delete tickets
  - **Status Workflow**: open → in_progress → resolved → closed
  - **Assignment**: Assign tickets to support staff
  - **Comment System**: Public comments and internal notes
  - **File Attachments**: Multiple files per ticket/comment
  - **Audit Trail**: Complete status change history

  ## Status Flow

  - `open` - New ticket, awaiting assignment or response
  - `in_progress` - Being worked on by support staff
  - `resolved` - Issue resolved, awaiting confirmation
  - `closed` - Ticket closed (resolved or abandoned)

  ## Examples

      # Create a ticket
      {:ok, ticket} = Tickets.create_ticket(user_id, %{
        title: "Cannot login",
        description: "I get an error when trying to login..."
      })

      # Assign to support staff
      {:ok, ticket} = Tickets.assign_ticket(ticket, staff_user_id, current_user)

      # Start working on it
      {:ok, ticket} = Tickets.start_progress(ticket, current_user)

      # Add a public comment
      {:ok, comment} = Tickets.create_comment(ticket.uuid, staff_user_id, %{
        content: "We're looking into this issue."
      })

      # Add an internal note (hidden from customer)
      {:ok, note} = Tickets.create_internal_note(ticket.uuid, staff_user_id, %{
        content: "Customer seems frustrated. Need to escalate."
      })

      # Resolve the ticket
      {:ok, ticket} = Tickets.resolve_ticket(ticket, current_user, "Fixed in v2.0.1")
  """

  use PhoenixKit.Module

  import Ecto.Query, warn: false

  alias PhoenixKit.Dashboard.Tab

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  alias PhoenixKit.Modules.Tickets.{
    Events,
    Ticket,
    TicketAttachment,
    TicketComment,
    TicketStatusHistory
  }

  # ============================================================================
  # Module Status
  # ============================================================================

  @impl PhoenixKit.Module
  @doc """
  Checks if the Tickets module is enabled.

  ## Examples

      iex> enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting("tickets_enabled", false)
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the Tickets module.

  ## Examples

      iex> enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    result = Settings.update_boolean_setting_with_module("tickets_enabled", true, "tickets")
    refresh_dashboard_tabs()
    result
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the Tickets module.

  ## Examples

      iex> disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    result = Settings.update_boolean_setting_with_module("tickets_enabled", false, "tickets")
    refresh_dashboard_tabs()
    result
  end

  defp refresh_dashboard_tabs do
    if Code.ensure_loaded?(PhoenixKit.Dashboard.Registry) and
         PhoenixKit.Dashboard.Registry.initialized?() do
      PhoenixKit.Dashboard.Registry.load_defaults()
    end
  end

  @impl PhoenixKit.Module
  @doc """
  Gets the current Tickets module configuration and stats.

  ## Examples

      iex> get_config()
      %{enabled: false, total_tickets: 0, open_tickets: 0, ...}
  """
  def get_config do
    %{
      enabled: enabled?(),
      total_tickets: count_tickets(),
      open_tickets: count_tickets_by_status("open"),
      in_progress_tickets: count_tickets_by_status("in_progress"),
      resolved_tickets: count_tickets_by_status("resolved"),
      closed_tickets: count_tickets_by_status("closed"),
      comments_enabled: Settings.get_boolean_setting("tickets_comments_enabled", true),
      internal_notes_enabled:
        Settings.get_boolean_setting("tickets_internal_notes_enabled", true),
      attachments_enabled: Settings.get_boolean_setting("tickets_attachments_enabled", true),
      allow_reopen: Settings.get_boolean_setting("tickets_allow_reopen", true)
    }
  end

  defp count_tickets do
    repo().aggregate(Ticket, :count, :uuid)
  rescue
    _ -> 0
  end

  defp count_tickets_by_status(status) do
    from(t in Ticket, where: t.status == ^status)
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "tickets"

  @impl PhoenixKit.Module
  def module_name, do: "Tickets"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "tickets",
      label: "Tickets",
      icon: "hero-ticket",
      description: "Support ticket management and customer communication"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_tickets,
        label: "Tickets",
        icon: "hero-ticket",
        path: "tickets",
        priority: 620,
        level: :admin,
        permission: "tickets",
        match: :prefix,
        group: :admin_modules
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_tickets,
        label: "Tickets",
        icon: "hero-ticket",
        path: "tickets",
        priority: 923,
        level: :admin,
        parent: :admin_settings,
        permission: "tickets"
      )
    ]
  end

  @impl PhoenixKit.Module
  def user_dashboard_tabs do
    [
      Tab.new!(
        id: :dashboard_tickets,
        label: "My Tickets",
        icon: "hero-ticket",
        path: "tickets",
        priority: 800,
        match: :prefix,
        group: :account
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitWeb.Routes.TicketsRoutes

  # ============================================================================
  # Ticket CRUD Operations
  # ============================================================================

  @doc """
  Creates a new ticket.

  ## Parameters

  - `user_id` - Customer who created the ticket
  - `attrs` - Ticket attributes (title, description)

  ## Examples

      iex> create_ticket(42, %{title: "Bug report", description: "Something is wrong"})
      {:ok, %Ticket{}}

      iex> create_ticket(42, %{title: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_ticket(user_id, attrs) when is_binary(user_id) do
    create_ticket_with_uuid(user_id, attrs)
  end

  defp create_ticket_with_uuid(user_uuid, attrs) do
    attrs =
      attrs
      |> Map.put("user_uuid", user_uuid)
      |> Map.put("status", "open")

    repo().transaction(fn ->
      case %Ticket{}
           |> Ticket.changeset(attrs)
           |> repo().insert() do
        {:ok, ticket} ->
          create_status_history(ticket.uuid, user_uuid, nil, "open", nil)
          Events.broadcast_ticket_created(ticket)
          ticket

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Updates an existing ticket.

  ## Parameters

  - `ticket` - Ticket struct to update
  - `attrs` - Attributes to update

  ## Examples

      iex> update_ticket(ticket, %{title: "Updated Title"})
      {:ok, %Ticket{}}
  """
  def update_ticket(%Ticket{} = ticket, attrs) do
    ticket
    |> Ticket.changeset(attrs)
    |> repo().update()
    |> case do
      {:ok, updated_ticket} ->
        Events.broadcast_ticket_updated(updated_ticket)
        {:ok, updated_ticket}

      error ->
        error
    end
  end

  @doc """
  Deletes a ticket and all related data.

  ## Parameters

  - `ticket` - Ticket struct to delete

  ## Examples

      iex> delete_ticket(ticket)
      {:ok, %Ticket{}}
  """
  def delete_ticket(%Ticket{} = ticket) do
    repo().delete(ticket)
  end

  @doc """
  Gets a single ticket by ID with optional preloads.

  Raises `Ecto.NoResultsError` if ticket not found.

  ## Parameters

  - `id` - Ticket ID (UUIDv7)
  - `opts` - Options
    - `:preload` - List of associations to preload

  ## Examples

      iex> get_ticket!("018e3c4a-...")
      %Ticket{}

      iex> get_ticket!("018e3c4a-...", preload: [:user, :assigned_to, :comments])
      %Ticket{user: %User{}, assigned_to: %User{}, comments: [...]}
  """
  def get_ticket!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    Ticket
    |> repo().get!(id)
    |> repo().preload(preloads)
  end

  @doc """
  Gets a single ticket by ID. Returns nil if not found.
  """
  def get_ticket(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    case repo().get(Ticket, id) do
      nil -> nil
      ticket -> repo().preload(ticket, preloads)
    end
  end

  @doc """
  Gets a single ticket by slug.

  ## Parameters

  - `slug` - Ticket slug
  - `opts` - Options
    - `:preload` - List of associations to preload

  ## Examples

      iex> get_ticket_by_slug("cannot-login-123456")
      %Ticket{}
  """
  def get_ticket_by_slug(slug, opts \\ []) when is_binary(slug) do
    preloads = Keyword.get(opts, :preload, [])

    Ticket
    |> where([t], t.slug == ^slug)
    |> repo().one()
    |> case do
      nil -> nil
      ticket -> repo().preload(ticket, preloads)
    end
  end

  @doc """
  Lists tickets with optional filtering and pagination.

  ## Parameters

  - `opts` - Options
    - `:user_id` - Filter by customer (ticket creator)
    - `:assigned_to_uuid` - Filter by assigned handler
    - `:status` - Filter by status (open/in_progress/resolved/closed)
    - `:search` - Search in title and description
    - `:page` - Page number (default: 1)
    - `:per_page` - Items per page (default: 20)
    - `:preload` - Associations to preload

  ## Examples

      iex> list_tickets()
      [%Ticket{}, ...]

      iex> list_tickets(status: "open", assigned_to_uuid: nil)
      [%Ticket{}, ...]
  """
  def list_tickets(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    assigned_to_uuid = Keyword.get(opts, :assigned_to_uuid)
    status = Keyword.get(opts, :status)
    search = Keyword.get(opts, :search)
    preloads = Keyword.get(opts, :preload, [])
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    Ticket
    |> maybe_filter_by_user(user_id)
    |> maybe_filter_by_assigned_to(assigned_to_uuid)
    |> maybe_filter_by_status(status)
    |> maybe_search_tickets(search)
    |> order_by([t], desc: t.inserted_at)
    |> paginate(page, per_page)
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Lists unassigned tickets (where assigned_to_uuid is nil).
  """
  def list_unassigned_tickets(opts \\ []) do
    opts = Keyword.put(opts, :assigned_to_uuid, nil)
    list_tickets(opts)
  end

  @doc """
  Lists tickets assigned to a specific handler.
  """
  def list_tickets_assigned_to(handler_id, opts \\ []) when is_binary(handler_id) do
    list_tickets(Keyword.put(opts, :assigned_to_uuid, handler_id))
  end

  @doc """
  Lists tickets created by a specific user.
  """
  def list_user_tickets(user_id, opts \\ []) when is_binary(user_id) do
    list_tickets(Keyword.put(opts, :user_id, user_id))
  end

  # ============================================================================
  # Status Transitions
  # ============================================================================

  @doc """
  Assigns a ticket to a support staff member.

  If the ticket is open, it will be moved to in_progress.

  ## Parameters

  - `ticket` - Ticket to assign
  - `handler_uuid` - UUID of the support staff
  - `changed_by` - User making the change

  ## Examples

      iex> assign_ticket(ticket, handler_uuid, current_user)
      {:ok, %Ticket{assigned_to_uuid: handler_uuid}}
  """
  def assign_ticket(%Ticket{} = ticket, handler_uuid, changed_by)
      when is_binary(handler_uuid) do
    changed_by_uuid = get_user_uuid(changed_by)
    old_assignee_uuid = ticket.assigned_to_uuid

    repo().transaction(fn ->
      attrs = %{assigned_to_uuid: handler_uuid}

      # If ticket is open, move to in_progress
      {attrs, new_status} =
        if ticket.status == "open" do
          {Map.put(attrs, :status, "in_progress"), "in_progress"}
        else
          {attrs, nil}
        end

      case update_ticket(ticket, attrs) do
        {:ok, updated_ticket} ->
          if new_status do
            create_status_history(
              ticket.uuid,
              changed_by_uuid,
              ticket.status,
              new_status,
              "Assigned to handler"
            )
          end

          # Broadcast assignment event
          Events.broadcast_ticket_assigned(updated_ticket, old_assignee_uuid, handler_uuid)

          updated_ticket

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Moves ticket to in_progress status.

  ## Parameters

  - `ticket` - Ticket to update
  - `changed_by` - User making the change

  ## Examples

      iex> start_progress(ticket, current_user)
      {:ok, %Ticket{status: "in_progress"}}
  """
  def start_progress(%Ticket{} = ticket, changed_by) do
    transition_status(ticket, "in_progress", changed_by)
  end

  @doc """
  Resolves a ticket.

  ## Parameters

  - `ticket` - Ticket to resolve
  - `changed_by` - User making the change
  - `reason` - Optional resolution reason

  ## Examples

      iex> resolve_ticket(ticket, current_user, "Fixed in version 2.0.1")
      {:ok, %Ticket{status: "resolved"}}
  """
  def resolve_ticket(%Ticket{} = ticket, changed_by, reason \\ nil) do
    transition_status(ticket, "resolved", changed_by, reason)
  end

  @doc """
  Closes a ticket.

  ## Parameters

  - `ticket` - Ticket to close
  - `changed_by` - User making the change
  - `reason` - Optional close reason

  ## Examples

      iex> close_ticket(ticket, current_user, "No response from customer")
      {:ok, %Ticket{status: "closed"}}
  """
  def close_ticket(%Ticket{} = ticket, changed_by, reason \\ nil) do
    transition_status(ticket, "closed", changed_by, reason)
  end

  @doc """
  Reopens a closed or resolved ticket.

  ## Parameters

  - `ticket` - Ticket to reopen
  - `changed_by` - User making the change
  - `reason` - Optional reopen reason

  ## Examples

      iex> reopen_ticket(ticket, current_user, "Issue still occurring")
      {:ok, %Ticket{status: "open"}}
  """
  def reopen_ticket(%Ticket{} = ticket, changed_by, reason \\ nil) do
    if Settings.get_boolean_setting("tickets_allow_reopen", true) do
      transition_status(ticket, "open", changed_by, reason)
    else
      {:error, :reopen_not_allowed}
    end
  end

  defp transition_status(%Ticket{} = ticket, new_status, changed_by, reason \\ nil) do
    changed_by_id = get_user_uuid(changed_by)
    old_status = ticket.status

    if Ticket.valid_transition?(old_status, new_status) do
      repo().transaction(fn ->
        attrs = %{status: new_status}

        # Set timestamps based on new status
        attrs =
          case new_status do
            "resolved" ->
              Map.put(attrs, :resolved_at, UtilsDate.utc_now())

            "closed" ->
              Map.put(attrs, :closed_at, UtilsDate.utc_now())

            "open" ->
              Map.merge(attrs, %{resolved_at: nil, closed_at: nil})

            _ ->
              attrs
          end

        # Use raw update to avoid double broadcast from update_ticket
        case ticket
             |> Ticket.changeset(attrs)
             |> repo().update() do
          {:ok, updated_ticket} ->
            create_status_history(ticket.uuid, changed_by_id, old_status, new_status, reason)

            # Broadcast status change event
            Events.broadcast_ticket_status_changed(updated_ticket, old_status, new_status)

            updated_ticket

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      end)
    else
      {:error, :invalid_transition}
    end
  end

  defp create_status_history(ticket_uuid, changed_by_uuid, from_status, to_status, reason) do
    %TicketStatusHistory{}
    |> TicketStatusHistory.changeset(%{
      ticket_uuid: ticket_uuid,
      changed_by_uuid: changed_by_uuid,
      from_status: from_status,
      to_status: to_status,
      reason: reason
    })
    |> repo().insert()
  end

  # ============================================================================
  # Comments
  # ============================================================================

  @doc """
  Creates a public comment on a ticket.

  ## Parameters

  - `ticket_id` - ID of the ticket
  - `user_id` - ID of the commenter
  - `attrs` - Comment attributes (content, optional parent_id)

  ## Examples

      iex> create_comment(ticket.uuid, user_id, %{content: "Thanks for looking into this!"})
      {:ok, %TicketComment{}}
  """
  def create_comment(ticket_id, user_id, attrs) when is_binary(user_id) do
    # Accept UUID strings directly
    attrs =
      attrs
      |> ensure_string_keys()
      |> Map.put("ticket_id", ticket_id)
      |> Map.put("user_uuid", user_id)
      |> Map.put("is_internal", false)

    attrs = maybe_calculate_depth(attrs)

    repo().transaction(fn ->
      case %TicketComment{}
           |> TicketComment.changeset(attrs)
           |> repo().insert() do
        {:ok, comment} ->
          increment_comment_count(ticket_id)

          # Load ticket for broadcast
          ticket = repo().get(Ticket, ticket_id)

          # Broadcast comment created event
          Events.broadcast_comment_created(comment, ticket)

          comment

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Creates an internal note on a ticket (visible only to support staff).

  ## Parameters

  - `ticket_id` - ID of the ticket
  - `user_id` - ID of the staff member
  - `attrs` - Note attributes (content)

  ## Examples

      iex> create_internal_note(ticket.uuid, staff_id, %{content: "Customer seems frustrated"})
      {:ok, %TicketComment{is_internal: true}}
  """
  def create_internal_note(ticket_id, user_id, attrs) when is_binary(user_id) do
    # Accept UUID strings directly
    attrs =
      attrs
      |> ensure_string_keys()
      |> Map.put("ticket_id", ticket_id)
      |> Map.put("user_uuid", user_id)
      |> Map.put("is_internal", true)

    attrs = maybe_calculate_depth(attrs)

    %TicketComment{}
    |> TicketComment.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, comment} ->
        # Load ticket for broadcast
        ticket = repo().get(Ticket, ticket_id)

        # Broadcast internal note created event
        Events.broadcast_internal_note_created(comment, ticket)

        {:ok, comment}

      error ->
        error
    end
  end

  @doc """
  Updates a comment.
  """
  def update_comment(%TicketComment{} = comment, attrs) do
    comment
    |> TicketComment.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a comment.
  """
  def delete_comment(%TicketComment{} = comment) do
    repo().transaction(fn ->
      case repo().delete(comment) do
        {:ok, deleted} ->
          unless comment.is_internal do
            decrement_comment_count(comment.ticket_uuid)
          end

          deleted

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Gets a comment by ID.
  """
  def get_comment!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    TicketComment
    |> repo().get!(id)
    |> repo().preload(preloads)
  end

  @doc """
  Lists public comments for a ticket (excludes internal notes).
  """
  def list_public_comments(ticket_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:user])

    from(c in TicketComment,
      where: c.ticket_uuid == ^ticket_id and c.is_internal == false,
      order_by: [asc: c.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Lists all comments for a ticket (includes internal notes).
  For staff use only.
  """
  def list_all_comments(ticket_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:user])

    from(c in TicketComment,
      where: c.ticket_uuid == ^ticket_id,
      order_by: [asc: c.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Lists only internal notes for a ticket.
  """
  def list_internal_notes(ticket_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:user])

    from(c in TicketComment,
      where: c.ticket_uuid == ^ticket_id and c.is_internal == true,
      order_by: [asc: c.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  defp maybe_calculate_depth(attrs) do
    parent_uuid = Map.get(attrs, "parent_uuid") || Map.get(attrs, :parent_uuid)

    if parent_uuid do
      parent = repo().get!(TicketComment, parent_uuid)
      Map.put(attrs, "depth", parent.depth + 1)
    else
      Map.put(attrs, "depth", 0)
    end
  end

  defp increment_comment_count(ticket_id) do
    from(t in Ticket, where: t.uuid == ^ticket_id)
    |> repo().update_all(inc: [comment_count: 1])
  end

  defp decrement_comment_count(ticket_id) do
    from(t in Ticket, where: t.uuid == ^ticket_id)
    |> repo().update_all(inc: [comment_count: -1])
  end

  defp ensure_string_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # ============================================================================
  # Attachments
  # ============================================================================

  @doc """
  Attaches a file to a ticket.

  ## Parameters

  - `ticket_id` - ID of the ticket
  - `file_id` - ID of the uploaded file
  - `opts` - Options
    - `:position` - Display order (default: auto-calculated)
    - `:caption` - Optional caption

  ## Examples

      iex> add_attachment_to_ticket(ticket.uuid, file.uuid, caption: "Error screenshot")
      {:ok, %TicketAttachment{}}
  """
  def add_attachment_to_ticket(ticket_uuid, file_uuid, opts \\ []) do
    position = Keyword.get(opts, :position) || next_ticket_attachment_position(ticket_uuid)
    caption = Keyword.get(opts, :caption)

    %TicketAttachment{}
    |> TicketAttachment.changeset(%{
      ticket_uuid: ticket_uuid,
      file_uuid: file_uuid,
      position: position,
      caption: caption
    })
    |> repo().insert()
  end

  @doc """
  Attaches a file to a comment.
  """
  def add_attachment_to_comment(comment_uuid, file_uuid, opts \\ []) do
    position = Keyword.get(opts, :position) || next_comment_attachment_position(comment_uuid)
    caption = Keyword.get(opts, :caption)

    %TicketAttachment{}
    |> TicketAttachment.changeset(%{
      comment_uuid: comment_uuid,
      file_uuid: file_uuid,
      position: position,
      caption: caption
    })
    |> repo().insert()
  end

  @doc """
  Removes an attachment.
  """
  def remove_attachment(attachment_id) do
    attachment = repo().get!(TicketAttachment, attachment_id)
    repo().delete(attachment)
  end

  @doc """
  Lists attachments for a ticket.
  """
  def list_ticket_attachments(ticket_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:file])

    from(a in TicketAttachment,
      where: a.ticket_uuid == ^ticket_id and is_nil(a.comment_uuid),
      order_by: [asc: a.position]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Lists attachments for a comment.
  """
  def list_comment_attachments(comment_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:file])

    from(a in TicketAttachment,
      where: a.comment_uuid == ^comment_id,
      order_by: [asc: a.position]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  defp next_ticket_attachment_position(ticket_id) do
    from(a in TicketAttachment,
      where: a.ticket_uuid == ^ticket_id and is_nil(a.comment_uuid),
      select: coalesce(max(a.position), 0)
    )
    |> repo().one()
    |> Kernel.+(1)
  end

  defp next_comment_attachment_position(comment_id) do
    from(a in TicketAttachment,
      where: a.comment_uuid == ^comment_id,
      select: coalesce(max(a.position), 0)
    )
    |> repo().one()
    |> Kernel.+(1)
  end

  # ============================================================================
  # Status History
  # ============================================================================

  @doc """
  Gets the status history for a ticket.
  """
  def get_status_history(ticket_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:changed_by])

    from(h in TicketStatusHistory,
      where: h.ticket_uuid == ^ticket_id,
      order_by: [asc: h.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  @doc """
  Gets ticket statistics.
  """
  def get_stats do
    %{
      total: count_tickets(),
      open: count_tickets_by_status("open"),
      in_progress: count_tickets_by_status("in_progress"),
      resolved: count_tickets_by_status("resolved"),
      closed: count_tickets_by_status("closed"),
      unassigned: count_unassigned_tickets()
    }
  end

  defp count_unassigned_tickets do
    from(t in Ticket, where: is_nil(t.assigned_to_uuid) and t.status in ["open", "in_progress"])
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp maybe_filter_by_user(query, nil), do: query

  defp maybe_filter_by_user(query, user_id) when is_binary(user_id) do
    where(query, [t], t.user_uuid == ^user_id)
  end

  defp maybe_filter_by_assigned_to(query, nil), do: query

  defp maybe_filter_by_assigned_to(query, :unassigned) do
    where(query, [t], is_nil(t.assigned_to_uuid))
  end

  defp maybe_filter_by_assigned_to(query, assigned_to_id) when is_binary(assigned_to_id) do
    where(query, [t], t.assigned_to_uuid == ^assigned_to_id)
  end

  defp maybe_filter_by_status(query, nil), do: query

  defp maybe_filter_by_status(query, status) when is_binary(status) do
    where(query, [t], t.status == ^status)
  end

  defp maybe_filter_by_status(query, statuses) when is_list(statuses) do
    where(query, [t], t.status in ^statuses)
  end

  defp maybe_search_tickets(query, nil), do: query
  defp maybe_search_tickets(query, ""), do: query

  defp maybe_search_tickets(query, search) do
    search_pattern = "%#{search}%"
    where(query, [t], ilike(t.title, ^search_pattern) or ilike(t.description, ^search_pattern))
  end

  defp paginate(query, page, per_page) do
    offset = (page - 1) * per_page

    query
    |> limit(^per_page)
    |> offset(^offset)
  end

  defp get_user_uuid(%{uuid: uuid}), do: uuid
  defp get_user_uuid(uuid) when is_binary(uuid), do: uuid
  defp get_user_uuid(_), do: nil

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
