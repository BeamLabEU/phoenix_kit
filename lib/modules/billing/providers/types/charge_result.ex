defmodule PhoenixKit.Modules.Billing.Providers.Types.ChargeResult do
  @moduledoc """
  Struct returned by `Provider.charge_payment_method/3`.

  ## Fields

  - `id` - Provider-specific charge/payment identifier
  - `provider_transaction_id` - Provider's transaction ID for tracking
  - `amount` - Charged amount as Decimal
  - `currency` - Currency code (e.g., `"EUR"`, `"USD"`)
  - `status` - Charge status (e.g., `"succeeded"`)
  - `metadata` - Provider-specific metadata
  """

  @enforce_keys [:id, :status]
  defstruct [:id, :provider_transaction_id, :amount, :currency, :status, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          provider_transaction_id: String.t() | nil,
          amount: Decimal.t() | nil,
          currency: String.t() | nil,
          status: String.t(),
          metadata: map()
        }
end
