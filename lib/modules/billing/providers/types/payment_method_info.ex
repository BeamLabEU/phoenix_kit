defmodule PhoenixKit.Modules.Billing.Providers.Types.PaymentMethodInfo do
  @moduledoc """
  Struct returned by `Provider.get_payment_method_details/1`.

  Named `PaymentMethodInfo` to avoid clash with the `PaymentMethod` Ecto schema.

  ## Fields

  - `id` - Provider-specific payment method identifier
  - `provider` - Provider atom (`:stripe`, `:paypal`, `:razorpay`)
  - `provider_payment_method_id` - Provider's payment method ID
  - `provider_customer_id` - Provider's customer ID (nil if unknown)
  - `type` - Payment method type (e.g., `"card"`, `"paypal"`)
  - `brand` - Card brand (e.g., `"visa"`, `"mastercard"`) or nil
  - `last4` - Last 4 digits of card number or nil
  - `exp_month` - Expiration month or nil
  - `exp_year` - Expiration year or nil
  - `metadata` - Provider-specific metadata
  """

  @enforce_keys [:id, :provider, :provider_payment_method_id]
  defstruct [
    :id,
    :provider,
    :provider_payment_method_id,
    :provider_customer_id,
    :type,
    :brand,
    :last4,
    :exp_month,
    :exp_year,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          provider_payment_method_id: String.t(),
          provider_customer_id: String.t() | nil,
          type: String.t(),
          brand: String.t() | nil,
          last4: String.t() | nil,
          exp_month: integer() | nil,
          exp_year: integer() | nil,
          metadata: map()
        }
end
