defmodule PhoenixKit.Tickets.TicketStatusHistory do
  @moduledoc """
  Schema for ticket status change audit trail.

  Records every status transition for a ticket, including who made
  the change and an optional reason. Used for auditing and tracking
  ticket lifecycle.

  ## Fields

  - `ticket_id` - Reference to the ticket
  - `changed_by_id` - User who made the status change
  - `from_status` - Previous status (nil for initial creation)
  - `to_status` - New status
  - `reason` - Optional explanation for the change

  ## Examples

      # Ticket created
      %TicketStatusHistory{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_id: 42,
        from_status: nil,
        to_status: "open",
        reason: nil
      }

      # Ticket assigned and moved to in_progress
      %TicketStatusHistory{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_id: 5,
        from_status: "open",
        to_status: "in_progress",
        reason: "Assigned to support team"
      }

      # Ticket resolved
      %TicketStatusHistory{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_id: 5,
        from_status: "in_progress",
        to_status: "resolved",
        reason: "Issue fixed in version 2.0.1"
      }

      # Ticket reopened
      %TicketStatusHistory{
        ticket_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_id: 42,
        from_status: "resolved",
        to_status: "open",
        reason: "Issue still occurring after update"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          ticket_id: UUIDv7.t(),
          changed_by_id: integer(),
          from_status: String.t() | nil,
          to_status: String.t(),
          reason: String.t() | nil,
          ticket: PhoenixKit.Tickets.Ticket.t() | Ecto.Association.NotLoaded.t(),
          changed_by: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_ticket_status_history" do
    field :from_status, :string
    field :to_status, :string
    field :reason, :string

    belongs_to :ticket, PhoenixKit.Tickets.Ticket, type: UUIDv7
    belongs_to :changed_by, PhoenixKit.Users.Auth.User, type: :integer

    timestamps(type: :naive_datetime, updated_at: false)
  end

  @doc """
  Changeset for creating a status history entry.

  ## Required Fields

  - `ticket_id` - Reference to ticket
  - `changed_by_id` - User who made the change
  - `to_status` - New status

  Note: `from_status` is optional (nil for ticket creation).
  """
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:ticket_id, :changed_by_id, :from_status, :to_status, :reason])
    |> validate_required([:ticket_id, :changed_by_id, :to_status])
    |> validate_length(:reason, max: 1000)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:changed_by_id)
  end

  @doc """
  Check if this is the initial creation record.
  """
  def creation?(%__MODULE__{from_status: nil}), do: true
  def creation?(_), do: false

  @doc """
  Check if this is a reopen transition.
  """
  def reopen?(%__MODULE__{to_status: "open", from_status: from})
      when from in ["resolved", "closed"],
      do: true

  def reopen?(_), do: false

  @doc """
  Check if this is a resolution transition.
  """
  def resolution?(%__MODULE__{to_status: "resolved"}), do: true
  def resolution?(_), do: false

  @doc """
  Check if this is a close transition.
  """
  def close?(%__MODULE__{to_status: "closed"}), do: true
  def close?(_), do: false
end
