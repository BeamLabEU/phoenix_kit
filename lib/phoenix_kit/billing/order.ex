defmodule PhoenixKit.Billing.Order do
  @moduledoc """
  Order schema for PhoenixKit Billing system.

  Manages orders with line items, amounts, and billing information.
  Orders serve as the primary document for tracking what users purchased.

  ## Schema Fields

  ### Identity & Relations
  - `user_id`: Foreign key to the user who placed the order
  - `billing_profile_id`: Foreign key to the billing profile used
  - `order_number`: Unique order identifier (e.g., "ORD-2024-0001")
  - `status`: Order status workflow

  ### Payment
  - `payment_method`: Payment method (Phase 1: "bank" only)
  - `currency`: ISO 4217 currency code

  ### Line Items
  - `line_items`: JSONB array of items purchased

  ### Financial
  - `subtotal`: Sum of line items before tax/discount
  - `tax_amount`: Calculated tax amount
  - `tax_rate`: Applied tax rate (0.20 = 20%)
  - `discount_amount`: Discount applied
  - `discount_code`: Coupon/referral code used
  - `total`: Final amount to be paid

  ### Snapshots & Notes
  - `billing_snapshot`: Copy of billing profile at order time
  - `notes`: Customer-visible notes
  - `internal_notes`: Admin-only notes

  ## Status Workflow

  ```
  draft → pending → confirmed → paid
                 ↘         ↘
               cancelled   refunded
  ```

  ## Line Item Structure

  ```json
  [
    {
      "name": "Pro Plan - Monthly",
      "description": "Professional subscription plan",
      "quantity": 1,
      "unit_price": "99.00",
      "total": "99.00",
      "sku": "PLAN-PRO-M"
    }
  ]
  ```

  ## Usage Examples

      # Create an order
      {:ok, order} = Billing.create_order(user, %{
        billing_profile_id: profile.id,
        currency: "EUR",
        line_items: [
          %{name: "Pro Plan", quantity: 1, unit_price: "99.00", total: "99.00"}
        ],
        subtotal: "99.00",
        total: "99.00"
      })

      # Confirm order
      {:ok, order} = Billing.confirm_order(order)

      # Mark as paid
      {:ok, order} = Billing.mark_order_paid(order)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Billing.BillingProfile
  alias PhoenixKit.Users.Auth.User

  @primary_key {:id, :id, autogenerate: true}
  @valid_statuses ~w(draft pending confirmed paid cancelled refunded)
  @valid_payment_methods ~w(bank stripe paypal razorpay)

  schema "phoenix_kit_orders" do
    field :order_number, :string
    field :status, :string, default: "draft"
    field :payment_method, :string, default: "bank"

    # Line items (JSONB)
    field :line_items, {:array, :map}, default: []

    # Financial
    field :subtotal, :decimal, default: Decimal.new("0")
    field :tax_amount, :decimal, default: Decimal.new("0")
    field :tax_rate, :decimal, default: Decimal.new("0")
    field :discount_amount, :decimal, default: Decimal.new("0")
    field :discount_code, :string
    field :total, :decimal
    field :currency, :string, default: "EUR"

    # Snapshots
    field :billing_snapshot, :map, default: %{}

    # Notes
    field :notes, :string
    field :internal_notes, :string

    field :metadata, :map, default: %{}

    # Timestamps
    field :confirmed_at, :utc_datetime_usec
    field :paid_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :billing_profile, BillingProfile

    has_many :invoices, PhoenixKit.Billing.Invoice

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for order creation.
  """
  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :user_id,
      :billing_profile_id,
      :order_number,
      :status,
      :payment_method,
      :line_items,
      :subtotal,
      :tax_amount,
      :tax_rate,
      :discount_amount,
      :discount_code,
      :total,
      :currency,
      :billing_snapshot,
      :notes,
      :internal_notes,
      :metadata,
      :confirmed_at,
      :paid_at,
      :cancelled_at
    ])
    |> validate_required([:user_id, :total, :currency])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:payment_method, @valid_payment_methods)
    |> validate_length(:currency, is: 3)
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> validate_number(:subtotal, greater_than_or_equal_to: 0)
    |> validate_number(:tax_amount, greater_than_or_equal_to: 0)
    |> validate_number(:discount_amount, greater_than_or_equal_to: 0)
    |> validate_line_items()
    |> maybe_generate_order_number()
    |> unique_constraint(:order_number)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:billing_profile_id)
  end

  @doc """
  Changeset for status transitions.
  """
  def status_changeset(order, new_status) do
    changeset =
      order
      |> change(status: new_status)
      |> validate_status_transition(order.status, new_status)

    case new_status do
      "confirmed" -> put_change(changeset, :confirmed_at, DateTime.utc_now())
      "paid" -> put_change(changeset, :paid_at, DateTime.utc_now())
      "cancelled" -> put_change(changeset, :cancelled_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp validate_status_transition(changeset, from, to) do
    valid_transitions = %{
      "draft" => ~w(pending confirmed cancelled),
      "pending" => ~w(confirmed cancelled),
      "confirmed" => ~w(paid cancelled refunded),
      "paid" => ~w(refunded),
      "cancelled" => [],
      "refunded" => []
    }

    allowed = Map.get(valid_transitions, from, [])

    if to in allowed do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{from} to #{to}")
    end
  end

  defp validate_line_items(changeset) do
    items = get_field(changeset, :line_items) || []

    errors =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, idx} ->
        cond do
          not is_map(item) ->
            ["Item #{idx + 1}: must be a map"]

          not Map.has_key?(item, "name") and not Map.has_key?(item, :name) ->
            ["Item #{idx + 1}: missing name"]

          true ->
            []
        end
      end)

    if errors == [] do
      changeset
    else
      add_error(changeset, :line_items, Enum.join(errors, "; "))
    end
  end

  defp maybe_generate_order_number(changeset) do
    if get_field(changeset, :order_number) do
      changeset
    else
      # Will be set by context with proper prefix from settings
      changeset
    end
  end

  @doc """
  Calculates totals from line items.

  Returns `{subtotal, tax_amount, total}` as Decimals.
  """
  def calculate_totals(line_items, tax_rate \\ Decimal.new("0"), discount \\ Decimal.new("0")) do
    subtotal =
      line_items
      |> Enum.reduce(Decimal.new("0"), fn item, acc ->
        item_total =
          item
          |> Map.get("total", Map.get(item, :total, "0"))
          |> to_decimal()

        Decimal.add(acc, item_total)
      end)

    taxable = Decimal.sub(subtotal, discount)
    tax_amount = Decimal.mult(taxable, tax_rate) |> Decimal.round(2)
    total = Decimal.add(taxable, tax_amount)

    {subtotal, tax_amount, total}
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  @doc """
  Checks if order can be edited (is in draft or pending status).
  """
  def editable?(%__MODULE__{status: status}) when status in ~w(draft pending), do: true
  def editable?(_), do: false

  @doc """
  Checks if order can be cancelled.
  """
  def cancellable?(%__MODULE__{status: status}) when status in ~w(draft pending confirmed),
    do: true

  def cancellable?(_), do: false

  @doc """
  Checks if order can be marked as paid.
  """
  def payable?(%__MODULE__{status: "confirmed"}), do: true
  def payable?(_), do: false

  @doc """
  Returns human-readable status label.
  """
  def status_label("draft"), do: "Draft"
  def status_label("pending"), do: "Pending"
  def status_label("confirmed"), do: "Confirmed"
  def status_label("paid"), do: "Paid"
  def status_label("cancelled"), do: "Cancelled"
  def status_label("refunded"), do: "Refunded"
  def status_label(_), do: "Unknown"

  @doc """
  Returns status badge color class.
  """
  def status_color("draft"), do: "badge-neutral"
  def status_color("pending"), do: "badge-warning"
  def status_color("confirmed"), do: "badge-info"
  def status_color("paid"), do: "badge-success"
  def status_color("cancelled"), do: "badge-error"
  def status_color("refunded"), do: "badge-secondary"
  def status_color(_), do: "badge-ghost"
end
