defmodule PhoenixKit.Modules.Tickets.Ticket do
  @moduledoc """
  Schema for support tickets.

  Represents a customer support request with status workflow, assignment,
  and comment threads including internal notes.

  ## Status Flow

  - `open` - New ticket, awaiting assignment or response
  - `in_progress` - Being worked on by support staff
  - `resolved` - Issue resolved, awaiting confirmation
  - `closed` - Ticket closed (resolved or abandoned)

  ## Transitions

  - open -> in_progress (when assigned or work begins)
  - open -> resolved (direct resolution)
  - open -> closed (close without resolution)
  - in_progress -> resolved
  - in_progress -> open (return/unassign)
  - in_progress -> closed
  - resolved -> closed (auto or manual)
  - resolved -> open (reopen by customer)
  - closed -> open (reopen, if allowed)

  ## Fields

  - `user_uuid` - Customer who created the ticket
  - `assigned_to_id` - Support staff handling the ticket
  - `title` - Brief description of the issue
  - `description` - Full details of the issue
  - `status` - open/in_progress/resolved/closed
  - `slug` - URL-friendly identifier
  - `comment_count` - Denormalized counter
  - `metadata` - Flexible JSONB for future extensions
  - `resolved_at` - When ticket was resolved
  - `closed_at` - When ticket was closed

  ## Examples

      # New ticket
      %Ticket{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 42,
        assigned_to_id: nil,
        title: "Cannot login to my account",
        description: "I get an error when trying to login...",
        status: "open",
        slug: "cannot-login-to-my-account",
        comment_count: 0
      }

      # Ticket being worked on
      %Ticket{
        user_id: 42,
        assigned_to_id: 5,
        title: "Payment failed",
        description: "...",
        status: "in_progress",
        comment_count: 3
      }

      # Resolved ticket
      %Ticket{
        user_id: 42,
        assigned_to_id: 5,
        status: "resolved",
        resolved_at: ~U[2025-01-15 14:30:00Z]
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @statuses ["open", "in_progress", "resolved", "closed"]

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          user_uuid: UUIDv7.t(),
          user_id: integer() | nil,
          assigned_to_uuid: UUIDv7.t() | nil,
          assigned_to_id: integer() | nil,
          title: String.t(),
          description: String.t(),
          status: String.t(),
          slug: String.t(),
          comment_count: integer(),
          metadata: map(),
          resolved_at: DateTime.t() | nil,
          closed_at: DateTime.t() | nil,
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          assigned_to: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t() | nil,
          comments:
            [PhoenixKit.Modules.Tickets.TicketComment.t()] | Ecto.Association.NotLoaded.t(),
          attachments:
            [PhoenixKit.Modules.Tickets.TicketAttachment.t()] | Ecto.Association.NotLoaded.t(),
          status_history:
            [PhoenixKit.Modules.Tickets.TicketStatusHistory.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_tickets" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"
    field :slug, :string
    field :comment_count, :integer, default: 0
    field :metadata, :map, default: %{}
    field :resolved_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :assigned_to, PhoenixKit.Users.Auth.User,
      foreign_key: :assigned_to_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer
    field :assigned_to_id, :integer

    has_many :comments, PhoenixKit.Modules.Tickets.TicketComment, foreign_key: :ticket_id
    has_many :attachments, PhoenixKit.Modules.Tickets.TicketAttachment, foreign_key: :ticket_id

    has_many :status_history, PhoenixKit.Modules.Tickets.TicketStatusHistory,
      foreign_key: :ticket_id

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating or updating a ticket.

  ## Required Fields

  - `user_uuid` - Customer who created the ticket
  - `title` - Brief description
  - `description` - Full details
  - `status` - Must be: "open", "in_progress", "resolved", or "closed"

  ## Validation Rules

  - Title max 255 characters
  - Status must be valid
  - Slug auto-generated from title if not provided
  """
  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :user_id,
      :user_uuid,
      :assigned_to_id,
      :assigned_to_uuid,
      :title,
      :description,
      :status,
      :slug,
      :metadata,
      :resolved_at,
      :closed_at
    ])
    |> validate_required([:user_uuid, :title, :description, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, max: 255)
    |> maybe_generate_slug()
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:assigned_to_uuid)
    |> unique_constraint(:slug)
  end

  @doc """
  Returns list of valid statuses.
  """
  def statuses, do: @statuses

  @doc """
  Check if ticket is open.
  """
  def open?(%__MODULE__{status: "open"}), do: true
  def open?(_), do: false

  @doc """
  Check if ticket is in progress.
  """
  def in_progress?(%__MODULE__{status: "in_progress"}), do: true
  def in_progress?(_), do: false

  @doc """
  Check if ticket is resolved.
  """
  def resolved?(%__MODULE__{status: "resolved"}), do: true
  def resolved?(_), do: false

  @doc """
  Check if ticket is closed.
  """
  def closed?(%__MODULE__{status: "closed"}), do: true
  def closed?(_), do: false

  @doc """
  Check if ticket is assigned to someone.
  """
  def assigned?(%__MODULE__{assigned_to_id: nil}), do: false
  def assigned?(%__MODULE__{}), do: true

  @doc """
  Check if ticket can receive comments (not closed).
  """
  def can_comment?(%__MODULE__{status: "closed"}), do: false
  def can_comment?(%__MODULE__{}), do: true

  @doc """
  Valid transitions from current status.
  """
  def valid_transitions("open"), do: ["in_progress", "resolved", "closed"]
  def valid_transitions("in_progress"), do: ["open", "resolved", "closed"]
  def valid_transitions("resolved"), do: ["open", "closed"]
  def valid_transitions("closed"), do: ["open"]
  def valid_transitions(_), do: []

  @doc """
  Check if transition from current to new status is valid.
  """
  def valid_transition?(current_status, new_status) do
    new_status in valid_transitions(current_status)
  end

  # Private Functions

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        title = get_field(changeset, :title)

        if title do
          slug = slugify(title)
          put_change(changeset, :slug, slug)
        else
          changeset
        end

      _slug ->
        changeset
    end
  end

  defp slugify(title) do
    timestamp = System.system_time(:millisecond) |> Integer.to_string() |> String.slice(-6, 6)

    base_slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^\w\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)

    "#{base_slug}-#{timestamp}"
  end
end
