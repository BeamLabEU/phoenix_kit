defmodule PhoenixKit.Modules.Billing.Invoice do
  @moduledoc """
  Invoice schema for PhoenixKit Billing system.

  Invoices are generated from orders and sent to customers for payment.
  They include receipt functionality once payment is confirmed.

  ## Schema Fields

  ### Identity & Relations
  - `user_id`: Foreign key to the user
  - `order_id`: Foreign key to the source order (optional)
  - `invoice_number`: Unique invoice identifier (e.g., "INV-2024-0001")
  - `status`: Invoice status workflow

  ### Financial
  - `subtotal`, `tax_amount`, `tax_rate`, `total`: Financial amounts
  - `currency`: ISO 4217 currency code
  - `due_date`: Payment due date

  ### Billing Details
  - `billing_details`: Full snapshot of billing profile
  - `line_items`: Copy of order line items
  - `payment_terms`: Payment terms text
  - `bank_details`: Bank account for payment

  ### Receipt
  - `receipt_number`: Receipt identifier (generated after payment)
  - `receipt_generated_at`: When receipt was generated
  - `receipt_data`: Additional receipt data (PDF URL, etc.)

  ## Status Workflow

  ```
  draft → sent → paid
              ↘
             overdue → paid
              ↘
              void
  ```

  ## Usage Examples

      # Generate invoice from order
      {:ok, invoice} = Billing.create_invoice_from_order(order)

      # Send invoice
      {:ok, invoice} = Billing.send_invoice(invoice)

      # Mark as paid (generates receipt)
      {:ok, invoice} = Billing.mark_invoice_paid(invoice)

      # Get receipt
      receipt = Billing.get_receipt(invoice)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Billing.Order
  alias PhoenixKit.Modules.Billing.Transaction
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_statuses ~w(draft sent paid void overdue)

  schema "phoenix_kit_invoices" do
    field :id, :integer, read_after_writes: true
    field :invoice_number, :string
    field :status, :string, default: "draft"

    # Financial
    field :subtotal, :decimal, default: Decimal.new("0")
    field :tax_amount, :decimal, default: Decimal.new("0")
    field :tax_rate, :decimal, default: Decimal.new("0")
    field :total, :decimal
    field :paid_amount, :decimal, default: Decimal.new("0")
    field :currency, :string, default: "EUR"
    field :due_date, :date

    # Billing details (snapshot)
    field :billing_details, :map, default: %{}
    field :line_items, {:array, :map}, default: []
    field :payment_terms, :string
    field :bank_details, :map, default: %{}
    field :notes, :string

    field :metadata, :map, default: %{}

    # Receipt (integrated)
    field :receipt_number, :string
    field :receipt_generated_at, :utc_datetime
    field :receipt_data, :map, default: %{}

    # Timestamps
    field :sent_at, :utc_datetime
    field :paid_at, :utc_datetime
    field :voided_at, :utc_datetime

    # legacy
    field :user_id, :integer
    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
    # legacy
    field :order_id, :integer
    belongs_to :order, Order, foreign_key: :order_uuid, references: :uuid, type: UUIDv7
    field :subscription_uuid, UUIDv7
    has_many :transactions, Transaction, foreign_key: :invoice_uuid, references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for invoice creation.
  """
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :user_id,
      :user_uuid,
      :order_id,
      :order_uuid,
      :subscription_uuid,
      :invoice_number,
      :status,
      :subtotal,
      :tax_amount,
      :tax_rate,
      :total,
      :paid_amount,
      :currency,
      :due_date,
      :billing_details,
      :line_items,
      :payment_terms,
      :bank_details,
      :notes,
      :metadata,
      :receipt_number,
      :receipt_generated_at,
      :receipt_data,
      :sent_at,
      :paid_at,
      :voided_at
    ])
    |> validate_required([:user_uuid, :total, :currency])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:currency, is: 3)
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> validate_number(:paid_amount, greater_than_or_equal_to: 0)
    |> unique_constraint(:invoice_number)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:order_uuid)
  end

  @doc """
  Changeset for status transitions.
  """
  def status_changeset(invoice, new_status) do
    changeset =
      invoice
      |> change(status: new_status)
      |> validate_status_transition(invoice.status, new_status)

    case new_status do
      "sent" -> put_change(changeset, :sent_at, UtilsDate.utc_now())
      "paid" -> put_change(changeset, :paid_at, UtilsDate.utc_now())
      "void" -> put_change(changeset, :voided_at, UtilsDate.utc_now())
      _ -> changeset
    end
  end

  @doc """
  Changeset for marking invoice as paid and generating receipt.
  """
  def paid_changeset(invoice, receipt_number) do
    now = UtilsDate.utc_now()

    invoice
    |> change(%{
      status: "paid",
      paid_at: now,
      receipt_number: receipt_number,
      receipt_generated_at: now,
      receipt_data: %{
        generated_at: DateTime.to_iso8601(now),
        amount_paid: Decimal.to_string(invoice.total),
        currency: invoice.currency
      }
    })
    |> validate_status_transition(invoice.status, "paid")
  end

  defp validate_status_transition(changeset, from, to) do
    valid_transitions = %{
      "draft" => ~w(sent void),
      "sent" => ~w(paid overdue void),
      "overdue" => ~w(paid void),
      "paid" => ~w(void),
      "void" => []
    }

    allowed = Map.get(valid_transitions, from, [])

    if to in allowed do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{from} to #{to}")
    end
  end

  @doc """
  Creates an invoice from an order.
  """
  def from_order(%Order{} = order, opts \\ []) do
    due_days = Keyword.get(opts, :due_days, 14)
    invoice_number = Keyword.get(opts, :invoice_number)
    bank_details = Keyword.get(opts, :bank_details, %{})
    payment_terms = Keyword.get(opts, :payment_terms)

    %__MODULE__{
      user_id: order.user_id,
      user_uuid: order.user_uuid,
      order_id: order.id,
      order_uuid: order.uuid,
      invoice_number: invoice_number,
      status: "draft",
      subtotal: order.subtotal,
      tax_amount: order.tax_amount,
      tax_rate: order.tax_rate,
      total: order.total,
      currency: order.currency,
      due_date: Date.add(Date.utc_today(), due_days),
      billing_details: order.billing_snapshot,
      line_items: order.line_items,
      payment_terms: payment_terms,
      bank_details: bank_details,
      notes: order.notes
    }
  end

  @doc """
  Checks if invoice can be edited.
  """
  def editable?(%__MODULE__{status: "draft"}), do: true
  def editable?(_), do: false

  @doc """
  Checks if invoice can be sent (first time - changes status to sent).
  """
  def sendable?(%__MODULE__{status: "draft"}), do: true
  def sendable?(_), do: false

  @doc """
  Checks if invoice can be resent (already sent, paid, or overdue).
  """
  def resendable?(%__MODULE__{status: status}) when status in ~w(sent paid overdue), do: true
  def resendable?(_), do: false

  @doc """
  Checks if invoice can be marked as paid.
  """
  def payable?(%__MODULE__{status: status}) when status in ~w(sent overdue), do: true
  def payable?(_), do: false

  @doc """
  Checks if invoice can be voided.
  """
  def voidable?(%__MODULE__{status: status}) when status in ~w(draft sent overdue), do: true
  def voidable?(_), do: false

  @doc """
  Checks if invoice has a receipt.
  """
  def has_receipt?(%__MODULE__{receipt_number: nil}), do: false
  def has_receipt?(%__MODULE__{receipt_number: _}), do: true

  @doc """
  Checks if invoice is overdue.
  """
  def overdue?(%__MODULE__{status: "paid"}), do: false
  def overdue?(%__MODULE__{status: "void"}), do: false
  def overdue?(%__MODULE__{due_date: nil}), do: false

  def overdue?(%__MODULE__{due_date: due_date}) do
    Date.compare(due_date, Date.utc_today()) == :lt
  end

  @doc """
  Returns human-readable status label.
  """
  def status_label("draft"), do: "Draft"
  def status_label("sent"), do: "Sent"
  def status_label("paid"), do: "Paid"
  def status_label("void"), do: "Void"
  def status_label("overdue"), do: "Overdue"
  def status_label(_), do: "Unknown"

  @doc """
  Returns status badge color class.
  """
  def status_color("draft"), do: "badge-neutral"
  def status_color("sent"), do: "badge-info"
  def status_color("paid"), do: "badge-success"
  def status_color("void"), do: "badge-error"
  def status_color("overdue"), do: "badge-warning"
  def status_color(_), do: "badge-ghost"

  @doc """
  Returns the billing name from billing_details snapshot.
  """
  def billing_name(%__MODULE__{billing_details: %{"name" => name}}) when is_binary(name), do: name

  def billing_name(%__MODULE__{billing_details: %{"company_name" => name}}) when is_binary(name),
    do: name

  def billing_name(%__MODULE__{billing_details: %{"first_name" => first, "last_name" => last}}) do
    "#{first} #{last}" |> String.trim()
  end

  def billing_name(_), do: ""

  @doc """
  Returns the remaining amount to be paid.
  """
  def remaining_amount(%__MODULE__{total: total, paid_amount: paid_amount}) do
    Decimal.sub(total, paid_amount)
  end

  @doc """
  Checks if invoice is fully paid (paid_amount >= total).
  """
  def fully_paid?(%__MODULE__{total: total, paid_amount: paid_amount}) do
    Decimal.compare(paid_amount, total) != :lt
  end

  @doc """
  Checks if invoice has any payments (paid_amount > 0).
  """
  def has_payments?(%__MODULE__{paid_amount: paid_amount}) do
    Decimal.positive?(paid_amount)
  end

  @doc """
  Checks if invoice can receive a refund (has payments).
  """
  def refundable?(%__MODULE__{} = invoice) do
    has_payments?(invoice)
  end

  @doc """
  Changeset for updating paid_amount.
  """
  def paid_amount_changeset(invoice, paid_amount) do
    invoice
    |> change(paid_amount: paid_amount)
    |> validate_number(:paid_amount, greater_than_or_equal_to: 0)
  end

  # ============================================
  # PAYMENT METHODS AGGREGATION
  # ============================================

  @doc """
  Returns all unique payment methods used in transactions for this invoice.
  Requires transactions to be preloaded.

  ## Examples

      iex> Invoice.payment_methods(invoice_with_transactions)
      ["bank", "stripe"]

      iex> Invoice.payment_methods(invoice_without_transactions)
      []
  """
  def payment_methods(%__MODULE__{transactions: txns}) when is_list(txns) do
    txns
    |> Enum.map(& &1.payment_method)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def payment_methods(_), do: []

  @doc """
  Returns the primary payment method (most used in positive transactions).
  Useful for display when there are multiple payment methods.
  Requires transactions to be preloaded.

  ## Examples

      iex> Invoice.primary_payment_method(invoice)
      "stripe"

      iex> Invoice.primary_payment_method(invoice_without_transactions)
      nil
  """
  def primary_payment_method(%__MODULE__{transactions: txns}) when is_list(txns) do
    txns
    |> Enum.filter(&Decimal.positive?(&1.amount))
    |> Enum.frequencies_by(& &1.payment_method)
    |> Enum.max_by(fn {_method, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  def primary_payment_method(_), do: nil
end
