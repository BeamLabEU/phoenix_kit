defmodule PhoenixKit.Modules.Billing.PaymentOption do
  @moduledoc """
  Payment option schema for checkout.

  Represents available payment methods during checkout, including:
  - Offline methods: Cash on Delivery (COD), Bank Transfer
  - Online methods: Stripe, PayPal, Razorpay

  ## Type

  - `offline` - Payment handled outside the system (COD, bank transfer)
  - `online` - Payment processed through a provider (Stripe, PayPal)

  ## Billing Profile Requirement

  Some payment methods (like COD or Bank Transfer) require billing information
  for invoicing purposes. Online card payments typically don't need this as
  the payment provider handles customer details.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(offline online)
  @codes ~w(cod bank_transfer stripe paypal razorpay)

  schema "phoenix_kit_payment_options" do
    field :uuid, Ecto.UUID, read_after_writes: true

    # Identity
    field :name, :string
    field :code, :string
    field :type, :string, default: "offline"

    # Provider (for online payments)
    field :provider, :string

    # Display
    field :description, :string
    field :instructions, :string
    field :icon, :string, default: "hero-banknotes"

    # Configuration
    field :active, :boolean, default: false
    field :position, :integer, default: 0
    field :requires_billing_profile, :boolean, default: true

    # Additional settings
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating and updating payment options.
  """
  def changeset(payment_option, attrs) do
    payment_option
    |> cast(attrs, [
      :name,
      :code,
      :type,
      :provider,
      :description,
      :instructions,
      :icon,
      :active,
      :position,
      :requires_billing_profile,
      :settings
    ])
    |> validate_required([:name, :code, :type])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:code, @codes)
    |> unique_constraint(:code)
    |> validate_provider()
  end

  @doc """
  Returns true if this payment option is an online payment.
  """
  def online?(%__MODULE__{type: "online"}), do: true
  def online?(_), do: false

  @doc """
  Returns true if this payment option is an offline payment.
  """
  def offline?(%__MODULE__{type: "offline"}), do: true
  def offline?(_), do: false

  @doc """
  Returns true if this payment option requires a billing profile.
  """
  def requires_billing?(%__MODULE__{requires_billing_profile: true}), do: true
  def requires_billing?(_), do: false

  @doc """
  Returns list of valid type values.
  """
  def types, do: @types

  @doc """
  Returns list of valid code values.
  """
  def codes, do: @codes

  @doc """
  Returns the icon name for a payment option.
  """
  def icon_name(%__MODULE__{icon: icon}) when is_binary(icon), do: icon
  def icon_name(%__MODULE__{code: "cod"}), do: "hero-banknotes"
  def icon_name(%__MODULE__{code: "bank_transfer"}), do: "hero-building-library"
  def icon_name(%__MODULE__{code: "stripe"}), do: "hero-credit-card"
  def icon_name(%__MODULE__{code: "paypal"}), do: "hero-credit-card"
  def icon_name(%__MODULE__{code: "razorpay"}), do: "hero-credit-card"
  def icon_name(_), do: "hero-credit-card"

  defp validate_provider(changeset) do
    type = get_field(changeset, :type)
    provider = get_field(changeset, :provider)

    if type == "online" and is_nil(provider) do
      add_error(changeset, :provider, "is required for online payment options")
    else
      changeset
    end
  end
end
