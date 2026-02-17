defmodule PhoenixKit.Modules.Billing.Providers.Types.SetupSession do
  @moduledoc """
  Struct returned by `Provider.create_setup_session/2`.

  ## Fields

  - `id` - Provider-specific session identifier
  - `url` - Redirect URL for saving a payment method
  - `provider` - Provider atom (`:stripe`, `:paypal`, `:razorpay`)
  - `metadata` - Provider-specific metadata
  """

  @enforce_keys [:id, :url, :provider]
  defstruct [:id, :url, :provider, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          provider: atom(),
          metadata: map()
        }
end
