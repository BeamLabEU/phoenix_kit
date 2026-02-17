defmodule PhoenixKit.Modules.Billing.Web.InvoiceDetail.TimelineEvent do
  @moduledoc """
  Struct representing a single event in the invoice timeline.

  ## Fields

  - `type` - Event type atom (`:created`, `:invoice_sent`, `:payment`, `:paid`,
    `:receipt_generated`, `:receipt_sent`, `:refund`, `:credit_note_sent`, `:voided`,
    `:invoice_sent_legacy`)
  - `datetime` - When the event occurred
  - `data` - Event-specific payload (transaction, send history entry, receipt number, or nil)
  """

  @enforce_keys [:type]
  defstruct [:type, :datetime, :data]

  @type event_type ::
          :created
          | :invoice_sent
          | :invoice_sent_legacy
          | :payment
          | :paid
          | :receipt_generated
          | :receipt_sent
          | :refund
          | :credit_note_sent
          | :voided

  @type t :: %__MODULE__{
          type: event_type(),
          datetime: DateTime.t() | NaiveDateTime.t() | nil,
          data: term()
        }
end
