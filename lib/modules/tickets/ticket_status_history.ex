defmodule PhoenixKit.Modules.Tickets.TicketStatusHistory do
  @moduledoc """
  Schema for ticket status change audit trail.

  Records every status transition for a ticket, including who made
  the change and an optional reason. Used for auditing and tracking
  ticket lifecycle.

  ## Fields

  - `ticket_uuid` - Reference to the ticket
  - `changed_by_uuid` - User who made the status change
  - `from_status` - Previous status (nil for initial creation)
  - `to_status` - New status
  - `reason` - Optional explanation for the change

  ## Examples

      # Ticket created
      %TicketStatusHistory{
        ticket_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        from_status: nil,
        to_status: "open",
        reason: nil
      }

      # Ticket assigned and moved to in_progress
      %TicketStatusHistory{
        ticket_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        from_status: "open",
        to_status: "in_progress",
        reason: "Assigned to support team"
      }

      # Ticket resolved
      %TicketStatusHistory{
        ticket_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        from_status: "in_progress",
        to_status: "resolved",
        reason: "Issue fixed in version 2.0.1"
      }

      # Ticket reopened
      %TicketStatusHistory{
        ticket_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        changed_by_uuid: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        from_status: "resolved",
        to_status: "open",
        reason: "Issue still occurring after update"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          ticket_uuid: UUIDv7.t(),
          changed_by_uuid: UUIDv7.t(),
          from_status: String.t() | nil,
          to_status: String.t(),
          reason: String.t() | nil,
          ticket: PhoenixKit.Modules.Tickets.Ticket.t() | Ecto.Association.NotLoaded.t(),
          changed_by: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_ticket_status_history" do
    field :from_status, :string
    field :to_status, :string
    field :reason, :string

    belongs_to :ticket, PhoenixKit.Modules.Tickets.Ticket,
      foreign_key: :ticket_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :changed_by, PhoenixKit.Users.Auth.User,
      foreign_key: :changed_by_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for creating a status history entry.

  ## Required Fields

  - `ticket_uuid` - Reference to ticket
  - `changed_by_uuid` - User who made the change
  - `to_status` - New status

  Note: `from_status` is optional (nil for ticket creation).
  """
  def changeset(history, attrs) do
    history
    |> cast(attrs, [
      :ticket_uuid,
      :changed_by_uuid,
      :from_status,
      :to_status,
      :reason
    ])
    |> validate_required([:ticket_uuid, :changed_by_uuid, :to_status])
    |> validate_length(:reason, max: 1000)
    |> foreign_key_constraint(:ticket_uuid)
    |> foreign_key_constraint(:changed_by_uuid)
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
