defmodule PhoenixKit.Modules.Tickets.TicketComment do
  @moduledoc """
  Schema for ticket comments with internal notes support.

  Supports nested comment threads (like PostComment) with self-referencing
  parent/child relationships. The `is_internal` flag distinguishes between
  public comments (visible to customer) and internal notes (staff only).

  ## Comment Types

  - **Public comments** (`is_internal: false`) - Visible to customer and staff
  - **Internal notes** (`is_internal: true`) - Visible only to support staff

  ## Fields

  - `ticket_id` - Reference to the ticket
  - `user_id` - Reference to the commenter
  - `parent_id` - Reference to parent comment (nil for top-level)
  - `content` - Comment text
  - `is_internal` - True for internal notes, false for public comments
  - `depth` - Nesting level (0=top, 1=reply, 2=reply-to-reply, etc.)

  ## Examples

      # Public comment from support
      %TicketComment{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 5,
        parent_id: nil,
        content: "Thank you for contacting us. We're looking into this.",
        is_internal: false,
        depth: 0
      }

      # Internal note (hidden from customer)
      %TicketComment{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 5,
        parent_id: nil,
        content: "Customer seems frustrated. Need to escalate to senior support.",
        is_internal: true,
        depth: 0
      }

      # Customer reply
      %TicketComment{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 42,
        parent_id: "018e3c4a-1234-5678-abcd-ef1234567890",
        content: "Thanks, I've tried that but it still doesn't work.",
        is_internal: false,
        depth: 1
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          ticket_id: UUIDv7.t(),
          user_id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          parent_id: UUIDv7.t() | nil,
          content: String.t(),
          is_internal: boolean(),
          depth: integer(),
          ticket: PhoenixKit.Modules.Tickets.Ticket.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          parent: t() | Ecto.Association.NotLoaded.t() | nil,
          children: [t()] | Ecto.Association.NotLoaded.t(),
          attachments:
            [PhoenixKit.Modules.Tickets.TicketAttachment.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_ticket_comments" do
    field :content, :string
    field :is_internal, :boolean, default: false
    field :depth, :integer, default: 0

    belongs_to :ticket, PhoenixKit.Modules.Tickets.Ticket, references: :uuid, type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer
    belongs_to :parent, __MODULE__, references: :uuid, type: UUIDv7

    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :attachments, PhoenixKit.Modules.Tickets.TicketAttachment, foreign_key: :comment_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a comment.

  ## Required Fields

  - `ticket_id` - Reference to ticket
  - `user_id` - Reference to commenter
  - `content` - Comment text

  ## Validation Rules

  - Content must be 1-10000 characters
  - is_internal defaults to false
  - Depth automatically calculated from parent
  """
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:ticket_id, :user_id, :user_uuid, :parent_id, :content, :is_internal, :depth])
    |> validate_required([:ticket_id, :user_uuid, :content])
    |> validate_length(:content, min: 1, max: 10_000)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:parent_id)
  end

  @doc """
  Check if comment is an internal note.
  """
  def internal?(%__MODULE__{is_internal: true}), do: true
  def internal?(_), do: false

  @doc """
  Check if comment is public (visible to customer).
  """
  def public?(%__MODULE__{is_internal: false}), do: true
  def public?(_), do: false

  @doc """
  Check if comment is a reply (has parent).
  """
  def reply?(%__MODULE__{parent_id: nil}), do: false
  def reply?(%__MODULE__{}), do: true

  @doc """
  Check if comment is top-level (no parent).
  """
  def top_level?(%__MODULE__{parent_id: nil}), do: true
  def top_level?(%__MODULE__{}), do: false
end
