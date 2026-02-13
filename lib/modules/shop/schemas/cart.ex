defmodule PhoenixKit.Modules.Shop.Cart do
  @moduledoc """
  Shopping cart schema with support for guest and authenticated users.

  ## Status Lifecycle

  - `active` - Cart is active and can be modified
  - `merged` - Guest cart was merged into user cart after login
  - `converted` - Cart was converted to an order
  - `abandoned` - Cart was marked as abandoned (no activity)
  - `expired` - Cart expired (past expires_at)

  ## Identity

  Each cart has either `user_id` (for authenticated users) or `session_id` (for guests).
  Guest carts have an `expires_at` timestamp (30 days by default).
  When a guest logs in, their cart is either converted to a user cart or merged
  with an existing user cart.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Modules.Billing.PaymentOption
  alias PhoenixKit.Modules.Shop.CartItem
  alias PhoenixKit.Modules.Shop.ShippingMethod
  alias PhoenixKit.Users.Auth.User

  @statuses ~w(active merged converted abandoned expired)

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_shop_carts" do
    field :id, :integer, read_after_writes: true

    # Identity
    # legacy
    field :user_id, :integer
    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
    field :session_id, :string

    # Status
    field :status, :string, default: "active"

    # Shipping
    # legacy
    field :shipping_method_id, :integer

    belongs_to :shipping_method, ShippingMethod,
      foreign_key: :shipping_method_uuid,
      references: :uuid,
      type: UUIDv7

    field :shipping_country, :string

    # Payment
    # legacy
    field :payment_option_id, :integer

    belongs_to :payment_option, PaymentOption,
      foreign_key: :payment_option_uuid,
      references: :uuid,
      type: UUIDv7

    # Totals (cached)
    field :subtotal, :decimal, default: Decimal.new("0")
    field :shipping_amount, :decimal, default: Decimal.new("0")
    field :tax_amount, :decimal, default: Decimal.new("0")
    field :discount_amount, :decimal, default: Decimal.new("0")
    field :total, :decimal, default: Decimal.new("0")
    field :currency, :string, default: "USD"

    # Discount
    field :discount_code, :string

    # Calculated
    field :total_weight_grams, :integer, default: 0
    field :items_count, :integer, default: 0

    # Metadata
    field :metadata, :map, default: %{}

    # Tracking
    field :expires_at, :utc_datetime
    field :converted_at, :utc_datetime
    # legacy
    field :merged_into_cart_id, :integer
    field :merged_into_cart_uuid, UUIDv7

    has_many :items, CartItem, foreign_key: :cart_uuid, references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for cart creation and updates.
  """
  def changeset(cart, attrs) do
    cart
    |> cast(attrs, [
      :user_id,
      :user_uuid,
      :session_id,
      :status,
      :shipping_method_id,
      :shipping_method_uuid,
      :shipping_country,
      :payment_option_id,
      :payment_option_uuid,
      :subtotal,
      :shipping_amount,
      :tax_amount,
      :discount_amount,
      :total,
      :currency,
      :discount_code,
      :total_weight_grams,
      :items_count,
      :metadata,
      :expires_at,
      :converted_at,
      :merged_into_cart_id,
      :merged_into_cart_uuid
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:currency, is: 3)
    |> validate_length(:shipping_country, max: 2)
    |> validate_identity()
    |> maybe_set_expires_at()
  end

  @doc """
  Changeset for updating cart totals.
  """
  def totals_changeset(cart, attrs) do
    cart
    |> cast(attrs, [
      :subtotal,
      :shipping_amount,
      :tax_amount,
      :discount_amount,
      :total,
      :total_weight_grams,
      :items_count
    ])
  end

  @doc """
  Changeset for setting shipping.
  """
  def shipping_changeset(cart, attrs) do
    cart
    |> cast(attrs, [
      :shipping_method_id,
      :shipping_method_uuid,
      :shipping_country,
      :shipping_amount
    ])
  end

  @doc """
  Changeset for setting payment option.
  """
  def payment_changeset(cart, attrs) do
    cart
    |> cast(attrs, [:payment_option_id, :payment_option_uuid])
  end

  @doc """
  Changeset for status transitions.
  """
  def status_changeset(cart, new_status, extra_attrs \\ %{}) do
    attrs = Map.merge(%{status: new_status}, extra_attrs)

    cart
    |> cast(attrs, [:status, :converted_at, :merged_into_cart_id, :merged_into_cart_uuid])
    |> validate_status_transition(cart.status, new_status)
  end

  @doc """
  Returns true if cart is active.
  """
  def active?(%__MODULE__{status: "active"}), do: true
  def active?(_), do: false

  @doc """
  Returns true if cart is a guest cart (no user_id).
  """
  def guest?(%__MODULE__{user_id: nil, user_uuid: nil}), do: true
  def guest?(%__MODULE__{user_id: nil, user_uuid: uuid}) when not is_nil(uuid), do: false
  def guest?(_), do: false

  @doc """
  Returns true if cart is empty.
  """
  def empty?(%__MODULE__{items_count: 0}), do: true
  def empty?(%__MODULE__{items_count: nil}), do: true
  def empty?(_), do: false

  @doc """
  Returns true if cart can be converted to order.
  """
  def convertible?(%__MODULE__{status: "active", items_count: count}) when count > 0, do: true
  def convertible?(_), do: false

  @doc """
  Returns true if cart has expired.
  """
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Returns list of valid status values.
  """
  def statuses, do: @statuses

  # Private helpers

  defp validate_identity(changeset) do
    user_id = get_field(changeset, :user_id)
    user_uuid = get_field(changeset, :user_uuid)
    session_id = get_field(changeset, :session_id)

    if is_nil(user_id) and is_nil(user_uuid) and is_nil(session_id) do
      add_error(changeset, :base, "Either user_id, user_uuid, or session_id must be set")
    else
      changeset
    end
  end

  defp validate_status_transition(changeset, from, to) do
    valid_transitions = %{
      "active" => ~w(merged converted abandoned expired),
      "merged" => [],
      "converted" => [],
      "abandoned" => ~w(active),
      "expired" => []
    }

    allowed = Map.get(valid_transitions, from, [])

    if to in allowed or from == to do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{from} to #{to}")
    end
  end

  defp maybe_set_expires_at(changeset) do
    user_id = get_field(changeset, :user_id)
    session_id = get_field(changeset, :session_id)
    expires_at = get_field(changeset, :expires_at)

    # Guest carts expire in 30 days
    if is_nil(user_id) and not is_nil(session_id) and is_nil(expires_at) do
      expires = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
      put_change(changeset, :expires_at, expires)
    else
      changeset
    end
  end
end
