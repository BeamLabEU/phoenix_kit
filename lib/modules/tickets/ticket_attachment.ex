defmodule PhoenixKit.Modules.Tickets.TicketAttachment do
  @moduledoc """
  Junction schema for ticket and comment attachments.

  Links tickets or comments to uploaded files (images, documents, etc.)
  with ordering and optional captions. An attachment belongs to either
  a ticket directly OR a comment, but not both.

  ## Fields

  - `ticket_id` - Reference to ticket (if attached to ticket directly)
  - `comment_id` - Reference to comment (if attached to comment)
  - `file_id` - Reference to the uploaded file (PhoenixKit.Storage.File)
  - `position` - Display order (1, 2, 3, etc.)
  - `caption` - Optional caption/alt text

  Note: Either `ticket_id` OR `comment_id` must be set, but not both.

  ## Examples

      # Attachment on ticket itself
      %TicketAttachment{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        comment_id: nil,
        file_id: "018e3c4a-1234-5678-abcd-ef1234567890",
        position: 1,
        caption: "Screenshot of the error"
      }

      # Attachment on a comment
      %TicketAttachment{
        ticket_id: nil,
        comment_id: "018e3c4a-5678-1234-abcd-ef1234567890",
        file_id: "018e3c4a-abcd-efgh-ijkl-mnopqrstuvwx",
        position: 1,
        caption: nil
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          ticket_id: UUIDv7.t() | nil,
          comment_id: UUIDv7.t() | nil,
          file_id: UUIDv7.t(),
          position: integer(),
          caption: String.t() | nil,
          ticket: PhoenixKit.Modules.Tickets.Ticket.t() | Ecto.Association.NotLoaded.t() | nil,
          comment:
            PhoenixKit.Modules.Tickets.TicketComment.t() | Ecto.Association.NotLoaded.t() | nil,
          file: PhoenixKit.Modules.Storage.File.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_ticket_attachments" do
    field :position, :integer
    field :caption, :string

    belongs_to :ticket, PhoenixKit.Modules.Tickets.Ticket, references: :uuid
    belongs_to :comment, PhoenixKit.Modules.Tickets.TicketComment, references: :uuid
    belongs_to :file, PhoenixKit.Modules.Storage.File, references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an attachment.

  ## Required Fields

  - `file_id` - Reference to file
  - `position` - Display order (must be positive)
  - Either `ticket_id` OR `comment_id` (but not both)

  ## Validation Rules

  - Position must be greater than 0
  - Must have exactly one of ticket_id or comment_id
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:ticket_id, :comment_id, :file_id, :position, :caption])
    |> validate_required([:file_id, :position])
    |> validate_number(:position, greater_than: 0)
    |> validate_parent_reference()
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:file_id)
  end

  @doc """
  Check if attachment is attached to a ticket directly.
  """
  def ticket_attachment?(%__MODULE__{ticket_id: ticket_id}) when not is_nil(ticket_id), do: true
  def ticket_attachment?(_), do: false

  @doc """
  Check if attachment is attached to a comment.
  """
  def comment_attachment?(%__MODULE__{comment_id: comment_id}) when not is_nil(comment_id),
    do: true

  def comment_attachment?(_), do: false

  # Private Functions

  defp validate_parent_reference(changeset) do
    ticket_id = get_field(changeset, :ticket_id)
    comment_id = get_field(changeset, :comment_id)

    case {ticket_id, comment_id} do
      {nil, nil} ->
        add_error(changeset, :ticket_id, "either ticket_id or comment_id must be set")

      {id, cid} when not is_nil(id) and not is_nil(cid) ->
        add_error(changeset, :comment_id, "cannot set both ticket_id and comment_id")

      _ ->
        changeset
    end
  end
end
