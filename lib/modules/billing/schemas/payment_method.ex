defmodule PhoenixKit.Modules.Billing.PaymentMethod do
  @moduledoc """
  Schema for saved payment methods (cards, bank accounts, wallets).

  Payment methods are saved via provider setup sessions and can be
  used for recurring payments without requiring user interaction.

  ## Provider Integration

  Each provider stores payment method tokens:
  - **Stripe**: `pm_*` payment method IDs + `cus_*` customer IDs
  - **PayPal**: Billing agreement IDs
  - **Razorpay**: Token IDs + customer IDs

  ## Security

  - No raw card data is ever stored
  - Only tokenized references from providers
  - Tokens are provider-specific and non-transferable

  ## Lifecycle

  - Created via setup session (hosted checkout for saving card)
  - Can be set as default for user
  - Can be used for subscription renewals
  - Can be removed (deletes token from provider)
  - Automatically marked expired based on exp_month/exp_year
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(card bank_account wallet paypal)
  @statuses ~w(active expired removed failed)

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_payment_methods" do
    field :id, :integer, read_after_writes: true
    field :provider, :string
    field :provider_payment_method_id, :string
    field :provider_customer_id, :string

    # Type and display info
    field :type, :string, default: "card"
    field :brand, :string
    field :last4, :string
    field :exp_month, :integer
    field :exp_year, :integer

    # Status
    field :is_default, :boolean, default: false
    field :status, :string, default: "active"

    # Metadata
    field :label, :string
    field :metadata, :map, default: %{}

    # Association
    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a payment method.
  """
  def changeset(payment_method, attrs) do
    payment_method
    |> cast(attrs, [
      :provider,
      :provider_payment_method_id,
      :provider_customer_id,
      :type,
      :brand,
      :last4,
      :exp_month,
      :exp_year,
      :is_default,
      :status,
      :label,
      :metadata,
      :user_uuid
    ])
    |> validate_required([:provider, :provider_payment_method_id, :user_uuid])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:exp_month, greater_than: 0, less_than_or_equal_to: 12)
    |> validate_number(:exp_year, greater_than_or_equal_to: 2020)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:provider, :provider_payment_method_id],
      name: :phoenix_kit_payment_methods_provider_pm_id_index
    )
  end

  @doc """
  Changeset for setting as default payment method.
  """
  def set_default_changeset(payment_method) do
    payment_method
    |> change(%{is_default: true})
  end

  @doc """
  Changeset for marking as removed.
  """
  def remove_changeset(payment_method) do
    payment_method
    |> change(%{status: "removed"})
  end

  @doc """
  Changeset for marking as expired.
  """
  def expire_changeset(payment_method) do
    payment_method
    |> change(%{status: "expired"})
  end

  # ============================================
  # Status Helpers
  # ============================================

  @doc """
  Returns true if the payment method is usable for charges.
  """
  def usable?(%__MODULE__{status: "active"} = pm) do
    not expired?(pm)
  end

  def usable?(_), do: false

  @doc """
  Returns true if the card has expired based on exp_month/exp_year.
  """
  def expired?(%__MODULE__{exp_month: nil}), do: false
  def expired?(%__MODULE__{exp_year: nil}), do: false

  def expired?(%__MODULE__{exp_month: month, exp_year: year}) do
    now = Date.utc_today()
    current_year = now.year
    current_month = now.month

    year < current_year or (year == current_year and month < current_month)
  end

  @doc """
  Returns a display string for the payment method (e.g., "Visa **** 4242").
  """
  def display_name(%__MODULE__{type: "card", brand: brand, last4: last4})
      when not is_nil(brand) and not is_nil(last4) do
    brand_name = String.capitalize(brand || "Card")
    "#{brand_name} **** #{last4}"
  end

  def display_name(%__MODULE__{type: "paypal"}) do
    "PayPal"
  end

  def display_name(%__MODULE__{type: "bank_account", last4: last4}) when not is_nil(last4) do
    "Bank Account **** #{last4}"
  end

  def display_name(%__MODULE__{type: _type, label: label}) when not is_nil(label) do
    label
  end

  def display_name(%__MODULE__{type: type}) do
    String.capitalize(type)
  end

  @doc """
  Returns expiration string (e.g., "12/25").
  """
  def expiration_string(%__MODULE__{exp_month: nil}), do: nil
  def expiration_string(%__MODULE__{exp_year: nil}), do: nil

  def expiration_string(%__MODULE__{exp_month: month, exp_year: year}) do
    month_str = String.pad_leading(to_string(month), 2, "0")
    year_str = String.slice(to_string(year), -2, 2)
    "#{month_str}/#{year_str}"
  end

  @doc """
  Returns the icon class for the card brand (for UI display).
  """
  def brand_icon(%__MODULE__{brand: brand}) do
    case String.downcase(brand || "") do
      "visa" -> "fa-cc-visa"
      "mastercard" -> "fa-cc-mastercard"
      "amex" -> "fa-cc-amex"
      "discover" -> "fa-cc-discover"
      "diners" -> "fa-cc-diners-club"
      "jcb" -> "fa-cc-jcb"
      _ -> "fa-credit-card"
    end
  end
end
