defmodule PhoenixKit.Billing.Transaction do
  @moduledoc """
  Schema for payment transactions.

  Transactions record actual payments and refunds for invoices.
  - Positive amount = payment
  - Negative amount = refund

  Transactions are created when:
  - Admin marks invoice as paid (creates payment transaction)
  - Admin issues a refund (creates refund transaction)

  There are no pending/failed statuses - a transaction is only recorded
  when the payment/refund has actually occurred.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Billing.Invoice
  alias PhoenixKit.Users.Auth.User

  @payment_methods ~w(bank stripe paypal razorpay)

  schema "phoenix_kit_transactions" do
    field :uuid, Ecto.UUID
    field :transaction_number, :string
    field :amount, :decimal
    field :currency, :string, default: "EUR"
    field :payment_method, :string, default: "bank"
    field :description, :string
    field :metadata, :map, default: %{}

    # For future payment provider integrations
    field :provider_transaction_id, :string
    field :provider_data, :map, default: %{}

    belongs_to :invoice, Invoice
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for a transaction.
  """
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :transaction_number,
      :amount,
      :currency,
      :payment_method,
      :description,
      :metadata,
      :provider_transaction_id,
      :provider_data,
      :invoice_id,
      :user_id
    ])
    |> validate_required([
      :transaction_number,
      :amount,
      :currency,
      :payment_method,
      :invoice_id,
      :user_id
    ])
    |> validate_inclusion(:payment_method, @payment_methods)
    |> validate_number(:amount, not_equal_to: 0)
    |> unique_constraint(:transaction_number)
    |> foreign_key_constraint(:invoice_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Returns true if this transaction is a payment (positive amount).
  """
  def payment?(%__MODULE__{amount: amount}) do
    Decimal.positive?(amount)
  end

  @doc """
  Returns true if this transaction is a refund (negative amount).
  """
  def refund?(%__MODULE__{amount: amount}) do
    Decimal.negative?(amount)
  end

  @doc """
  Returns the transaction type as a string.
  """
  def type(%__MODULE__{} = transaction) do
    if payment?(transaction), do: "payment", else: "refund"
  end

  @doc """
  Returns the absolute amount (always positive).
  """
  def absolute_amount(%__MODULE__{amount: amount}) do
    Decimal.abs(amount)
  end

  @doc """
  Returns the list of valid payment methods.
  """
  def payment_methods, do: @payment_methods
end
