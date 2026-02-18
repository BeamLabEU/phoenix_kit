defmodule PhoenixKit.Modules.Billing.Web.InvoiceDetail.Helpers do
  @moduledoc """
  Helper functions for the invoice detail LiveView.

  Contains timeline building, history parsing, formatting,
  and other template-callable utilities.
  """

  alias PhoenixKit.Modules.Billing.Web.InvoiceDetail.TimelineEvent

  @doc """
  Gets the default email address from invoice billing details or user.
  """
  def get_default_email(invoice) do
    cond do
      invoice.billing_details["email"] -> invoice.billing_details["email"]
      invoice.user -> invoice.user.email
      true -> ""
    end
  end

  @doc """
  Gets send history from invoice metadata.
  """
  def get_send_history(invoice) do
    case invoice.metadata do
      %{"send_history" => history} when is_list(history) -> history
      _ -> []
    end
  end

  @doc """
  Gets receipt send history from invoice receipt_data.
  """
  def get_receipt_send_history(invoice) do
    case invoice.receipt_data do
      %{"send_history" => history} when is_list(history) -> history
      _ -> []
    end
  end

  @doc """
  Gets credit note send history from transaction metadata.
  """
  def get_credit_note_send_history(transaction) do
    case transaction.metadata do
      %{"credit_note_send_history" => history} when is_list(history) -> history
      _ -> []
    end
  end

  @doc """
  Parses ISO8601 datetime string to DateTime.
  """
  def parse_datetime(nil), do: nil

  def parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  def parse_datetime(datetime), do: datetime

  @doc """
  Builds a sorted timeline of all invoice events.
  Returns a list of `%TimelineEvent{}` structs sorted by datetime.
  """
  def build_timeline_events(invoice, transactions) do
    events = []

    # 1. Created event
    events = [%TimelineEvent{type: :created, datetime: invoice.inserted_at} | events]

    # 2. Invoice sent events
    invoice_sends =
      get_send_history(invoice)
      |> Enum.map(fn entry ->
        %TimelineEvent{
          type: :invoice_sent,
          datetime: parse_datetime(entry["sent_at"]),
          data: entry
        }
      end)

    events = events ++ invoice_sends

    # Fallback for old invoices without send_history
    events =
      if invoice.sent_at && Enum.empty?(get_send_history(invoice)) do
        [%TimelineEvent{type: :invoice_sent_legacy, datetime: invoice.sent_at} | events]
      else
        events
      end

    # 3. Payment transactions (positive amounts)
    payment_events =
      transactions
      |> Enum.filter(&Decimal.positive?(&1.amount))
      |> Enum.map(fn txn ->
        %TimelineEvent{type: :payment, datetime: txn.inserted_at, data: txn}
      end)

    events = events ++ payment_events

    # 4. Paid event (when fully paid)
    events =
      if invoice.paid_at do
        [%TimelineEvent{type: :paid, datetime: invoice.paid_at} | events]
      else
        events
      end

    # 5. Receipt generated
    events =
      if invoice.receipt_number do
        [
          %TimelineEvent{
            type: :receipt_generated,
            datetime: invoice.receipt_generated_at,
            data: invoice.receipt_number
          }
          | events
        ]
      else
        events
      end

    # 6. Receipt sent events
    receipt_sends =
      get_receipt_send_history(invoice)
      |> Enum.map(fn entry ->
        %TimelineEvent{
          type: :receipt_sent,
          datetime: parse_datetime(entry["sent_at"]),
          data: entry
        }
      end)

    events = events ++ receipt_sends

    # 7. Refund transactions and their credit note sends
    refund_events =
      transactions
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.flat_map(fn txn ->
        # Refund event itself
        refund_event = %TimelineEvent{type: :refund, datetime: txn.inserted_at, data: txn}

        # Credit note send events for this refund
        credit_note_sends =
          get_credit_note_send_history(txn)
          |> Enum.map(fn entry ->
            %TimelineEvent{
              type: :credit_note_sent,
              datetime: parse_datetime(entry["sent_at"]),
              data: Map.put(entry, "transaction", txn)
            }
          end)

        [refund_event | credit_note_sends]
      end)

    events = events ++ refund_events

    # 8. Voided event
    events =
      if invoice.voided_at do
        [%TimelineEvent{type: :voided, datetime: invoice.voided_at} | events]
      else
        events
      end

    # Sort by datetime (nil datetimes go to the end)
    events
    |> Enum.sort_by(
      fn event ->
        case event.datetime do
          nil -> {1, 0}
          dt -> {0, DateTime.to_unix(dt, :microsecond)}
        end
      end,
      :asc
    )
  end

  @doc """
  Checks if invoice is fully refunded.
  """
  def fully_refunded?(invoice, transactions) do
    total_refunded =
      transactions
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      |> Decimal.abs()

    Decimal.gt?(total_refunded, Decimal.new(0)) &&
      Decimal.gte?(total_refunded, invoice.total)
  end

  @doc """
  Formats payment method name for display.
  """
  def format_payment_method_name("bank"), do: "Bank Transfer"
  def format_payment_method_name("stripe"), do: "Stripe"
  def format_payment_method_name("paypal"), do: "PayPal"
  def format_payment_method_name("razorpay"), do: "Razorpay"
  def format_payment_method_name(other) when is_binary(other), do: String.capitalize(other)
  def format_payment_method_name(_), do: "Unknown"
end
