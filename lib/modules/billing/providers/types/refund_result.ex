defmodule PhoenixKit.Modules.Billing.Providers.Types.RefundResult do
  @moduledoc """
  Struct returned by `Provider.create_refund/3`.

  ## Fields

  - `id` - Provider-specific refund identifier
  - `provider_refund_id` - Provider's refund ID for tracking
  - `amount` - Refunded amount as Decimal or integer (provider-dependent)
  - `status` - Refund status (e.g., `"succeeded"`, `"pending"`)
  - `metadata` - Provider-specific metadata
  """

  @enforce_keys [:id, :status]
  defstruct [:id, :provider_refund_id, :amount, :status, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          provider_refund_id: String.t() | nil,
          amount: Decimal.t() | integer() | nil,
          status: String.t(),
          metadata: map()
        }
end
